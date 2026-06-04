const std = @import("std");
const config = @import("config.zig");
const diagnostics = @import("diagnostics.zig");
const runner_mod = @import("runner.zig");

const PackageConfig = config.PackageConfig;
const BundleError = diagnostics.BundleError;
const Diagnostic = diagnostics.Diagnostic;
const Runner = runner_mod.Runner;

// ---------------------------------------------------------------------------
// plistEscape — THE injection boundary for config bytes into the Info.plist.
// Mirrors `protocol.jsString`: a single writer-based switch that is the only
// path from arbitrary config bytes into a plist string position. Every value
// `writeInfoPlist` emits goes through here; only the two hardcoded constant
// values (`APPL`, `true`) bypass it.
// ---------------------------------------------------------------------------

/// Escape `s` so it cannot inject plist structure. Emits XML entities for the
/// five significant characters and numeric character references for every
/// control byte (< 0x20) and for U+2028 / U+2029 (valid UTF-8 but line-break
/// hazards). No other byte is rewritten.
pub fn plistEscape(w: *std.Io.Writer, s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const b = s[i];
        switch (b) {
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            '&' => try w.writeAll("&amp;"),
            '"' => try w.writeAll("&quot;"),
            '\'' => try w.writeAll("&#39;"),
            else => {
                if (b < 0x20) {
                    try w.print("&#x{x};", .{b});
                } else if (b == 0xE2 and i + 2 < s.len and s[i + 1] == 0x80 and
                    (s[i + 2] == 0xA8 or s[i + 2] == 0xA9))
                {
                    // U+2028 LINE SEPARATOR / U+2029 PARAGRAPH SEPARATOR.
                    try w.writeAll(if (s[i + 2] == 0xA8) "&#x2028;" else "&#x2029;");
                    i += 2; // loop bump consumes the third byte
                } else {
                    try w.writeByte(b);
                }
            },
        }
    }
}

// ---------------------------------------------------------------------------
// writeInfoPlist — build the Info.plist XML, routing EVERY config-sourced value
// through plistEscape. The only raw values are the two compile-time constants
// CFBundlePackageType=APPL and NSHighResolutionCapable=true.
// ---------------------------------------------------------------------------

/// Emit a `<key>k</key><string>escaped(v)</string>` pair (two-space indent;
/// the golden test mirrors this exactly).
fn plistStringKey(w: *std.Io.Writer, key: []const u8, value: []const u8) !void {
    try w.print("  <key>{s}</key>\n  <string>", .{key});
    try plistEscape(w, value);
    try w.writeAll("</string>\n");
}

/// Build the Info.plist for `cfg`. Returns gpa-owned bytes; the caller frees.
/// `cfg.displayName` names CFBundleName, CFBundleDisplayName, and (critically)
/// CFBundleExecutable — it MUST match the executable filename `assembleBundle`
/// writes under Contents/MacOS or the bundle will not launch.
pub fn writeInfoPlist(gpa: std.mem.Allocator, cfg: PackageConfig) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;

    try w.writeAll(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\
    );

    // Constant package type (raw — not config-sourced).
    try w.writeAll("  <key>CFBundlePackageType</key>\n  <string>APPL</string>\n");

    try plistStringKey(w, "CFBundleIdentifier", cfg.identifier);
    try plistStringKey(w, "CFBundleName", cfg.displayName);
    try plistStringKey(w, "CFBundleDisplayName", cfg.displayName);
    try plistStringKey(w, "CFBundleExecutable", cfg.displayName);
    try plistStringKey(w, "CFBundleShortVersionString", cfg.version);
    try plistStringKey(w, "CFBundleVersion", cfg.bundleVersion);
    // User-controlled free-text manifest value — escaped like every other.
    try plistStringKey(w, "LSMinimumSystemVersion", cfg.minimumSystemVersion);

    if (cfg.category) |category| {
        try plistStringKey(w, "LSApplicationCategoryType", category);
    }
    if (cfg.copyright) |copyright| {
        try plistStringKey(w, "NSHumanReadableCopyright", copyright);
    }
    if (cfg.icon) |_| {
        // The icon FILE is always written as Resources/icon.icns; the plist
        // references the basename without the extension per the .icns convention.
        try plistStringKey(w, "CFBundleIconFile", "icon");
    }

    // Constant boolean (raw — not config-sourced).
    try w.writeAll("  <key>NSHighResolutionCapable</key>\n  <true/>\n");

    try w.writeAll(
        \\</dict>
        \\</plist>
        \\
    );

    return aw.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// assembleBundle — lay out the .app, write the plist, copy the binary, resolve
// the icon. Every filesystem call is catch-and-mapped into BundleError's pure
// domain variants (never `try`-propagated — the raw std FS errors are not
// members of BundleError).
// ---------------------------------------------------------------------------

/// Assemble `<displayName>.app` under `out_dir`. Returns the gpa-owned `.app`
/// path. On the icon-conversion failure path a gpa-duped Diagnostic is written
/// through `diag` BEFORE the captured RunResult is freed, then the typed
/// BundleError is returned (Zig error values carry no payload).
pub fn assembleBundle(
    io: std.Io,
    gpa: std.mem.Allocator,
    runner: *Runner,
    cfg: PackageConfig,
    binaries: []const []const u8,
    out_dir: []const u8,
    diag: *?Diagnostic,
) BundleError![]const u8 {
    const cwd = std.Io.Dir.cwd();

    // .app layout: <out_dir>/<displayName>.app/Contents/{MacOS,Resources}
    const app_rel = std.fmt.allocPrint(gpa, "{s}/{s}.app", .{ out_dir, cfg.displayName }) catch
        return error.OutOfMemory;
    errdefer gpa.free(app_rel);

    const macos_dir = std.fmt.allocPrint(gpa, "{s}/Contents/MacOS", .{app_rel}) catch
        return error.OutOfMemory;
    defer gpa.free(macos_dir);
    const resources_dir = std.fmt.allocPrint(gpa, "{s}/Contents/Resources", .{app_rel}) catch
        return error.OutOfMemory;
    defer gpa.free(resources_dir);

    // The std FS error sets do NOT include OutOfMemory, so map every member to
    // the matching pure-domain BundleError variant (mirrors Task 4's RunError
    // mapping). A bare `try` would be an error-set mismatch and not compile.
    cwd.createDirPath(io, macos_dir) catch return error.CreateDirPathFailed;
    cwd.createDirPath(io, resources_dir) catch return error.CreateDirPathFailed;

    // Copy the binary to Contents/MacOS/<displayName>, executable.
    const exe_dest = std.fmt.allocPrint(gpa, "{s}/{s}", .{ macos_dir, cfg.displayName }) catch
        return error.OutOfMemory;
    defer gpa.free(exe_dest);
    cwd.copyFile(binaries[0], cwd, exe_dest, io, .{
        .permissions = .executable_file,
        .make_path = true,
    }) catch return error.BinaryCopyFailed;

    // Write Info.plist. The Allocating writer's only real failure is OOM; any
    // other writer error maps to the plist-write domain variant.
    const plist_bytes = writeInfoPlist(gpa, cfg) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.PlistWriteFailed,
    };
    defer gpa.free(plist_bytes);
    const plist_rel = std.fmt.allocPrint(gpa, "{s}/Contents/Info.plist", .{app_rel}) catch
        return error.OutOfMemory;
    defer gpa.free(plist_rel);
    cwd.writeFile(io, .{ .sub_path = plist_rel, .data = plist_bytes }) catch return error.PlistWriteFailed;

    // Resolve the icon: .icns is copied verbatim; .png is converted via iconutil
    // through the runner. The plist always references Resources/icon.icns.
    if (cfg.icon) |icon_path| {
        try resolveIcon(io, gpa, runner, icon_path, resources_dir, diag);
    }

    return app_rel;
}

/// Place the icon at `<resources_dir>/icon.icns`. A `.icns` source is copied;
/// any other source (treated as a `.png`) is converted with `iconutil`. A
/// non-zero iconutil exit writes a gpa-duped Diagnostic through `diag` (its
/// detail is a copy of the captured stderr, taken BEFORE the RunResult is freed)
/// and returns `error.IconConvertFailed`.
fn resolveIcon(
    io: std.Io,
    gpa: std.mem.Allocator,
    runner: *Runner,
    icon_path: []const u8,
    resources_dir: []const u8,
    diag: *?Diagnostic,
) BundleError!void {
    const dest = std.fmt.allocPrint(gpa, "{s}/icon.icns", .{resources_dir}) catch
        return error.OutOfMemory;
    defer gpa.free(dest);

    if (std.mem.endsWith(u8, icon_path, ".icns")) {
        std.Io.Dir.cwd().copyFile(icon_path, std.Io.Dir.cwd(), dest, io, .{
            .make_path = true,
        }) catch return error.IconConvertFailed;
        return;
    }

    // .png (or any non-.icns): convert through iconutil. The icon_path reaches
    // an argv slot — its leading-`-` rejection is enforced by validateConfig.
    const argv = [_][]const u8{ "iconutil", "-c", "icns", "-o", dest, icon_path };
    const result = runner.run(io, gpa, &argv) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.IconConvertFailed,
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    if (!termOk(result.term)) {
        // Dupe the stderr into the Diagnostic BEFORE the RunResult is freed.
        const detail = gpa.dupe(u8, result.stderr) catch return error.OutOfMemory;
        diag.* = .{
            .code = .unknown_tool_failure,
            .title = "Packaging tool failed",
            .detail = detail,
            .remediation = "An unmapped tool failure occurred. Inspect the captured output above and re-run.",
        };
        return error.IconConvertFailed;
    }
}

/// True only for a clean `exited == 0` termination.
fn termOk(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |c| c == 0,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// Tests (TDD: written before the implementation above).
// ---------------------------------------------------------------------------

const testing = std.testing;

fn fullCfg() PackageConfig {
    return .{
        .identifier = "com.example.app",
        .version = "1.2.3",
        .displayName = "Example",
        .bundleVersion = "9.9.9",
        .category = "public.app-category.utilities",
        .copyright = "(c) 2026 Example",
        .icon = "assets/icon.png",
        .minimumSystemVersion = "12.0",
        .macos = .{},
        .dmg = .{},
    };
}

fn minimalCfg() PackageConfig {
    return .{
        .identifier = "com.example.app",
        .version = "1.0.0",
        .displayName = "App",
        .bundleVersion = "1.0.0",
        .category = null,
        .copyright = null,
        .icon = null,
        .minimumSystemVersion = "11.0",
        .macos = .{},
        .dmg = .{},
    };
}

test "writeInfoPlist golden for an all-present config" {
    const gpa = testing.allocator;
    const out = try writeInfoPlist(gpa, fullCfg());
    defer gpa.free(out);

    const expected =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\  <key>CFBundlePackageType</key>
        \\  <string>APPL</string>
        \\  <key>CFBundleIdentifier</key>
        \\  <string>com.example.app</string>
        \\  <key>CFBundleName</key>
        \\  <string>Example</string>
        \\  <key>CFBundleDisplayName</key>
        \\  <string>Example</string>
        \\  <key>CFBundleExecutable</key>
        \\  <string>Example</string>
        \\  <key>CFBundleShortVersionString</key>
        \\  <string>1.2.3</string>
        \\  <key>CFBundleVersion</key>
        \\  <string>9.9.9</string>
        \\  <key>LSMinimumSystemVersion</key>
        \\  <string>12.0</string>
        \\  <key>LSApplicationCategoryType</key>
        \\  <string>public.app-category.utilities</string>
        \\  <key>NSHumanReadableCopyright</key>
        \\  <string>(c) 2026 Example</string>
        \\  <key>CFBundleIconFile</key>
        \\  <string>icon</string>
        \\  <key>NSHighResolutionCapable</key>
        \\  <true/>
        \\</dict>
        \\</plist>
        \\
    ;
    try testing.expectEqualStrings(expected, out);
}

test "writeInfoPlist omits optional keys when category/copyright/icon are null" {
    const gpa = testing.allocator;
    const out = try writeInfoPlist(gpa, minimalCfg());
    defer gpa.free(out);

    // The omit-when-null branches must drop the WHOLE key, not emit an empty value.
    try testing.expect(std.mem.indexOf(u8, out, "LSApplicationCategoryType") == null);
    try testing.expect(std.mem.indexOf(u8, out, "NSHumanReadableCopyright") == null);
    try testing.expect(std.mem.indexOf(u8, out, "CFBundleIconFile") == null);
    // The required keys are still present.
    try testing.expect(std.mem.indexOf(u8, out, "CFBundleIdentifier") != null);
    try testing.expect(std.mem.indexOf(u8, out, "CFBundleExecutable") != null);
    try testing.expect(std.mem.indexOf(u8, out, "LSMinimumSystemVersion") != null);
}

test "writeInfoPlist escapes a hostile displayName so no element is injected" {
    const gpa = testing.allocator;
    var cfg = minimalCfg();
    cfg.displayName = "Evil</string><key>LSEnvironment</key><dict/><string>x";
    const out = try writeInfoPlist(gpa, cfg);
    defer gpa.free(out);

    // The injected literal close-tag must not survive raw.
    try testing.expect(std.mem.indexOf(u8, out, "</string><key>LSEnvironment</key>") == null);
    // It survives only as escaped entities.
    try testing.expect(std.mem.indexOf(u8, out, "&lt;/string&gt;") != null);
}

test "writeInfoPlist escapes a hostile minimumSystemVersion (the free-text manifest value)" {
    const gpa = testing.allocator;
    var cfg = minimalCfg();
    cfg.minimumSystemVersion = "11.0</string><key>LSEnvironment</key><dict/><string>";
    const out = try writeInfoPlist(gpa, cfg);
    defer gpa.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "</string><key>LSEnvironment</key>") == null);
}

// ── plistEscape hostile corpus ───────────────────────────────────────────────

test "plistEscape neutralises the hostile corpus" {
    const gpa = testing.allocator;
    const cases = [_][]const u8{
        "<",
        "&",
        "]]>",
        "</string>",
        "\"",
        "'",
        ">",
        "\u{2028}\u{2029}",
        "\x00\x01\x08\x0b\x1f",
        "</string><key>LSEnvironment</key><string>/bin/sh",
    };
    for (cases) |cs| {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        try plistEscape(&aw.writer, cs);
        try assertSafePlistText(aw.writer.buffered());
    }
}

// ── Fuzz: plistEscape output is always injection-safe ────────────────────────

test "fuzz: plistEscape never emits an injectable plist element (native body)" {
    try testing.fuzz({}, fuzzPlistEscape, .{});
}

test "fuzz: plistEscape never emits an injectable plist element (manual >= 10000 iterations)" {
    var prng = std.Random.DefaultPrng.init(testing.random_seed);
    const rand = prng.random();
    var iter: usize = 0;
    while (iter < 10_000) : (iter += 1) {
        var buf: [256]u8 = undefined;
        const n = rand.intRangeAtMost(usize, 0, buf.len);
        for (buf[0..n]) |*c| c.* = rand.int(u8);
        try checkPlistEscapeInvariant(buf[0..n]);
    }
}

fn fuzzPlistEscape(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [256]u8 = undefined;
    const n = smith.slice(&buf);
    try checkPlistEscapeInvariant(buf[0..n]);
}

/// Escape `input` and assert the output is structurally injection-safe.
fn checkPlistEscapeInvariant(input: []const u8) !void {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try plistEscape(&aw.writer, input);
    try assertSafePlistText(aw.writer.buffered());
}

/// Oracle: re-scan escaped plist text and fail if any byte could break out of a
/// plist string position. At least as wide as plistEscape's contract (mirrors
/// the RawControlChar/RawLineSeparator checks in protocol.assertSafeJsLiteral):
///   • no raw `<` `>` `"` `'` (all escaped to entities)
///   • no raw `&` except as the start of a well-formed entity
///   • no raw control byte (< 0x20)
///   • no raw U+2028 / U+2029
pub fn assertSafePlistText(out: []const u8) !void {
    var i: usize = 0;
    while (i < out.len) {
        const b = out[i];
        switch (b) {
            '<' => return error.RawLessThan,
            '>' => return error.RawGreaterThan,
            '"' => return error.RawQuote,
            '\'' => return error.RawApostrophe,
            '&' => {
                // Must begin a well-formed entity terminated by ';'.
                const rest = out[i..];
                const semi = std.mem.indexOfScalar(u8, rest, ';') orelse
                    return error.UnterminatedEntity;
                const ent = rest[1..semi]; // between '&' and ';'
                if (!validEntityBody(ent)) return error.MalformedEntity;
                i += semi + 1; // skip past ';'
            },
            else => {
                if (b < 0x20) return error.RawControlChar;
                if (b == 0xE2 and i + 2 < out.len and out[i + 1] == 0x80 and
                    (out[i + 2] == 0xA8 or out[i + 2] == 0xA9))
                {
                    return error.RawLineSeparator;
                }
                i += 1;
            },
        }
    }
}

/// True for the named entities plistEscape emits plus decimal/hex numeric refs.
fn validEntityBody(ent: []const u8) bool {
    if (std.mem.eql(u8, ent, "lt")) return true;
    if (std.mem.eql(u8, ent, "gt")) return true;
    if (std.mem.eql(u8, ent, "amp")) return true;
    if (std.mem.eql(u8, ent, "quot")) return true;
    if (std.mem.eql(u8, ent, "#39")) return true;
    if (ent.len >= 2 and ent[0] == '#' and (ent[1] == 'x' or ent[1] == 'X')) {
        const hex = ent[2..];
        if (hex.len == 0) return false;
        for (hex) |c| if (!std.ascii.isHex(c)) return false;
        return true;
    }
    if (ent.len >= 1 and ent[0] == '#') {
        const dec = ent[1..];
        if (dec.len == 0) return false;
        for (dec) |c| if (!std.ascii.isDigit(c)) return false;
        return true;
    }
    return false;
}

// ── assembleBundle ───────────────────────────────────────────────────────────

test "assembleBundle lays out the app, copies the executable, and writes the plist" {
    const io = testing.io;
    const gpa = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp.dir.realPath(io, &base_buf)];

    // A real dummy source binary to copy.
    const bin_path = try std.fmt.allocPrint(gpa, "{s}/server", .{base});
    defer gpa.free(bin_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = bin_path, .data = "#!/bin/sh\necho hi\n" });

    const out_dir = try std.fmt.allocPrint(gpa, "{s}/out", .{base});
    defer gpa.free(out_dir);

    var fr = runner_mod.FakeRunner.init(gpa);
    defer fr.deinit();
    var runner = fr.runner();

    var diag: ?Diagnostic = null;
    const cfg = minimalCfg(); // no icon → runner is never invoked
    const app_path = try assembleBundle(io, gpa, &runner, cfg, &.{bin_path}, out_dir, &diag);
    defer gpa.free(app_path);

    try testing.expect(std.mem.endsWith(u8, app_path, "App.app"));
    try testing.expect(diag == null);

    // The executable exists at Contents/MacOS/App with the binary's bytes.
    const exe_rel = try std.fmt.allocPrint(gpa, "{s}/Contents/MacOS/App", .{app_path});
    defer gpa.free(exe_rel);
    const exe_bytes = try std.Io.Dir.cwd().readFileAlloc(io, exe_rel, gpa, .limited(4096));
    defer gpa.free(exe_bytes);
    try testing.expectEqualStrings("#!/bin/sh\necho hi\n", exe_bytes);

    // The plist exists and names the executable consistently.
    const plist_rel = try std.fmt.allocPrint(gpa, "{s}/Contents/Info.plist", .{app_path});
    defer gpa.free(plist_rel);
    const plist_bytes = try std.Io.Dir.cwd().readFileAlloc(io, plist_rel, gpa, .limited(64 * 1024));
    defer gpa.free(plist_bytes);
    try testing.expect(std.mem.indexOf(u8, plist_bytes, "<string>App</string>") != null);
}

test "assembleBundle copies an .icns icon verbatim into Resources" {
    const io = testing.io;
    const gpa = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp.dir.realPath(io, &base_buf)];

    const bin_path = try std.fmt.allocPrint(gpa, "{s}/server", .{base});
    defer gpa.free(bin_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = bin_path, .data = "bin" });

    const icon_path = try std.fmt.allocPrint(gpa, "{s}/app.icns", .{base});
    defer gpa.free(icon_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = icon_path, .data = "ICNSDATA" });

    const out_dir = try std.fmt.allocPrint(gpa, "{s}/out", .{base});
    defer gpa.free(out_dir);

    var fr = runner_mod.FakeRunner.init(gpa);
    defer fr.deinit();
    var runner = fr.runner();

    var diag: ?Diagnostic = null;
    var cfg = minimalCfg();
    cfg.icon = icon_path;
    const app_path = try assembleBundle(io, gpa, &runner, cfg, &.{bin_path}, out_dir, &diag);
    defer gpa.free(app_path);

    // .icns is copied verbatim; iconutil is never run.
    try testing.expectEqual(@as(usize, 0), fr.argv_log.items.len);

    const icns_rel = try std.fmt.allocPrint(gpa, "{s}/Contents/Resources/icon.icns", .{app_path});
    defer gpa.free(icns_rel);
    const icns_bytes = try std.Io.Dir.cwd().readFileAlloc(io, icns_rel, gpa, .limited(4096));
    defer gpa.free(icns_bytes);
    try testing.expectEqualStrings("ICNSDATA", icns_bytes);
}

test "assembleBundle runs iconutil for a .png icon" {
    const io = testing.io;
    const gpa = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp.dir.realPath(io, &base_buf)];

    const bin_path = try std.fmt.allocPrint(gpa, "{s}/server", .{base});
    defer gpa.free(bin_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = bin_path, .data = "bin" });

    const out_dir = try std.fmt.allocPrint(gpa, "{s}/out", .{base});
    defer gpa.free(out_dir);

    var fr = runner_mod.FakeRunner.init(gpa);
    defer fr.deinit();
    try fr.push(.{ .term = .{ .exited = 0 }, .stdout = "", .stderr = "" });
    var runner = fr.runner();

    var diag: ?Diagnostic = null;
    var cfg = minimalCfg();
    cfg.icon = "assets/icon.png";
    const app_path = try assembleBundle(io, gpa, &runner, cfg, &.{bin_path}, out_dir, &diag);
    defer gpa.free(app_path);

    try testing.expect(diag == null);
    try testing.expectEqual(@as(usize, 1), fr.argv_log.items.len);
    try testing.expectEqualStrings("iconutil", fr.argv_log.items[0][0]);
    // The source .png reaches the argv tail.
    const argv = fr.argv_log.items[0];
    try testing.expectEqualStrings("assets/icon.png", argv[argv.len - 1]);
}

test "assembleBundle surfaces an iconutil failure as a populated diagnostic" {
    const io = testing.io;
    const gpa = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp.dir.realPath(io, &base_buf)];

    const bin_path = try std.fmt.allocPrint(gpa, "{s}/server", .{base});
    defer gpa.free(bin_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = bin_path, .data = "bin" });

    const out_dir = try std.fmt.allocPrint(gpa, "{s}/out", .{base});
    defer gpa.free(out_dir);

    var fr = runner_mod.FakeRunner.init(gpa);
    defer fr.deinit();
    try fr.push(.{ .term = .{ .exited = 1 }, .stdout = "", .stderr = "iconutil: bad png" });
    var runner = fr.runner();

    var diag: ?Diagnostic = null;
    var cfg = minimalCfg();
    cfg.icon = "assets/icon.png";
    const r = assembleBundle(io, gpa, &runner, cfg, &.{bin_path}, out_dir, &diag);
    try testing.expectError(error.IconConvertFailed, r);

    // The diagnostic is populated with the captured stderr (gpa-owned).
    try testing.expect(diag != null);
    try testing.expectEqual(diagnostics.Code.unknown_tool_failure, diag.?.code);
    try testing.expectEqualStrings("iconutil: bad png", diag.?.detail);
    gpa.free(diag.?.detail);
}
