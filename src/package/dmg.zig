const std = @import("std");
const config = @import("configuration.zig");
const diagnostics = @import("diagnostics.zig");
const runner_mod = @import("runner.zig");

const PackageConfig = config.PackageConfig;
const Credentials = config.Credentials;
const DmgError = diagnostics.DmgError;
const Diagnostic = diagnostics.Diagnostic;
const Runner = runner_mod.Runner;

const sign_mod = @import("sign.zig");
const notarize_mod = @import("notarize.zig");

// ---------------------------------------------------------------------------
// buildDmgArgv is the pure hdiutil argv builder. Returns a gpa-owned slice of
// gpa-owned strings; the caller frees each element then the slice. v0.1.0 ships
// a plain compressed (UDZO) HFS+ image with no background art. `volname` reaches
// an argv slot and is leading-`-`-checked by `validateConfig` (Locked decision #7).
// ---------------------------------------------------------------------------

pub fn buildDmgArgv(
    gpa: std.mem.Allocator,
    volname: []const u8,
    staging: []const u8,
    out_path: []const u8,
) std.mem.Allocator.Error![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (args.items) |a| gpa.free(a);
        args.deinit(gpa);
    }

    try appendDup(gpa, &args, "hdiutil");
    try appendDup(gpa, &args, "create");
    try appendDup(gpa, &args, "-volname");
    try appendDup(gpa, &args, volname);
    try appendDup(gpa, &args, "-srcfolder");
    try appendDup(gpa, &args, staging);
    try appendDup(gpa, &args, "-ov");
    try appendDup(gpa, &args, "-format");
    try appendDup(gpa, &args, "UDZO");
    try appendDup(gpa, &args, "-fs");
    try appendDup(gpa, &args, "HFS+");
    try appendDup(gpa, &args, out_path);

    return try args.toOwnedSlice(gpa);
}

/// Dupe `s` into gpa and append it; the ArrayList owns the element on success.
fn appendDup(gpa: std.mem.Allocator, args: *std.ArrayList([]const u8), s: []const u8) std.mem.Allocator.Error!void {
    const dup = try gpa.dupe(u8, s);
    errdefer gpa.free(dup);
    try args.append(gpa, dup);
}

/// Free a gpa-owned argv (each element, then the backing slice).
fn freeArgvOwned(gpa: std.mem.Allocator, argv: []const []const u8) void {
    for (argv) |a| gpa.free(a);
    gpa.free(argv);
}

// ---------------------------------------------------------------------------
// makeDmg stages the `.app` + an `/Applications` symlink, builds the dmg via
// hdiutil, then re-enter sign + notarize ON THE DMG.
//
// `signing_identity` is the RESOLVED identity (env-overridden value) that
// `package()` carries, not `cfg.macos.signingIdentity`, so the env override
// applies to dmg signing too. It is forwarded into the internal `sign` call.
// `creds` is the notary union, forwarded into the internal `notarize` call.
//
// Skip-lane gating (no skip params on this signature, parallel to `package()`'s
// `ResolvedCredentials` split): the internal `sign` runs only when
// `signing_identity != null`; the internal `notarize` runs only when `creds` is
// not `.none` (notarize treats `.none` as unreachable, so the gate is mandatory).
// This yields the pinned sequences: skip_sign (identity null, creds .none) →
// hdiutil only; skip_notarize (identity set, creds .none) → hdiutil + codesign
// but no notarytool/stapler.
//
// Every filesystem call is catch-and-mapped into `DmgError` (which has NO FS
// variant): OOM → OutOfMemory, else → HdiutilFailed. A non-zero hdiutil exit
// writes a gpa-duped Diagnostic through `diag` (its detail copied BEFORE the
// RunResult is freed) and returns `error.HdiutilFailed` BEFORE any dmg
// sign/notarize. The POST-staple `spctl --assess` on the dmg is NOT here; it is
// `package()`'s (the staple ticket exists only at that layer).
// ---------------------------------------------------------------------------

pub fn makeDmg(
    io: std.Io,
    gpa: std.mem.Allocator,
    runner: *Runner,
    app_bundle: []const u8,
    signing_identity: ?[]const u8,
    creds: Credentials,
    cfg: PackageConfig,
    out_dir: []const u8,
    diag: *?Diagnostic,
) DmgError![]const u8 {
    const cwd = std.Io.Dir.cwd();

    // 1) Fresh staging dir: <out_dir>/dmg-staging. The `.app` tree is copied in
    //    (a freshly-stapled bundle must not be moved out of where the success
    //    line reports it) plus an `/Applications` symlink so the user can drag.
    const staging = std.fmt.allocPrint(gpa, "{s}/dmg-staging", .{out_dir}) catch
        return error.OutOfMemory;
    defer gpa.free(staging);
    cwd.createDirPath(io, staging) catch return error.HdiutilFailed;

    // Copy the `.app` directory tree into the staging dir under its basename.
    const app_basename = std.fs.path.basename(app_bundle);
    const staged_app = std.fmt.allocPrint(gpa, "{s}/{s}", .{ staging, app_basename }) catch
        return error.OutOfMemory;
    defer gpa.free(staged_app);
    copyTree(io, gpa, cwd, app_bundle, staged_app) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.HdiutilFailed,
    };

    // The drag-to-install `/Applications` symlink. `PathAlreadyExists` is benign
    // (a re-run over a populated staging dir); any other error maps to HdiutilFailed.
    const apps_link = std.fmt.allocPrint(gpa, "{s}/Applications", .{staging}) catch
        return error.OutOfMemory;
    defer gpa.free(apps_link);
    cwd.symLink(io, "/Applications", apps_link, .{ .is_directory = true }) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return error.HdiutilFailed,
    };

    // 2) hdiutil create. The dmg lands at <out_dir>/<volname>.dmg.
    const dmg_path = std.fmt.allocPrint(gpa, "{s}/{s}.dmg", .{ out_dir, cfg.dmg.volname }) catch
        return error.OutOfMemory;
    errdefer gpa.free(dmg_path);

    const dmg_argv = try buildDmgArgv(gpa, cfg.dmg.volname, staging, dmg_path);
    defer freeArgvOwned(gpa, dmg_argv);
    {
        const result = runner.run(io, gpa, dmg_argv) catch |e| return mapRunError(e);
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        if (!termOk(result.term)) {
            // Dupe the stderr into the Diagnostic BEFORE the RunResult is freed,
            // and return BEFORE any dmg sign/notarize. There is no `hdiutil_failed`
            // Code, so the catch-all unknown_tool_failure carries the raw output.
            const detail = gpa.dupe(u8, result.stderr) catch return error.OutOfMemory;
            diag.* = diagnostics.diagnose(.unknown_tool_failure, detail);
            return error.HdiutilFailed;
        }
    }

    // 3) Re-sign the dmg (only with a resolved identity; the skip_sign lane
    //    passes null and the dmg stays unsigned). `skip_sign = false` here: the
    //    null-identity skip is expressed by NOT calling sign at all, so a genuine
    //    missing identity inside the call would still be a hard error.
    if (signing_identity != null) {
        try sign_mod.sign(io, gpa, runner, dmg_path, signing_identity, cfg, false, diag);
    }

    // 4) Re-notarize + staple the dmg (only with notary creds; the
    //    skip_notarize lane passes `.none`, and notarize treats `.none` as a
    //    caller bug, so the gate here is mandatory).
    switch (creds) {
        .none => {},
        else => try notarize_mod.notarize(io, gpa, runner, dmg_path, creds, diag),
    }

    return dmg_path;
}

/// Recursively copy the directory tree at `src` to `dest` (dest created fresh).
/// Mirrors bundle.zig's single-file copy but walks the source: directories become
/// `createDirPath`, files become `copyFile` (preserving the executable bit), and
/// symlinks are re-created with `symLink`. The `.app` produced by `assembleBundle`
/// contains only dirs + files, but symlinks are handled for robustness.
fn copyTree(io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir, src: []const u8, dest: []const u8) !void {
    dir.createDirPath(io, dest) catch return error.CopyFailed;

    var src_dir = dir.openDir(io, src, .{ .iterate = true }) catch return error.CopyFailed;
    defer src_dir.close(io);

    var walker = src_dir.walk(gpa) catch return error.OutOfMemory;
    defer walker.deinit();

    while (walker.next(io) catch return error.CopyFailed) |entry| {
        const dest_path = std.fmt.allocPrint(gpa, "{s}/{s}", .{ dest, entry.path }) catch
            return error.OutOfMemory;
        defer gpa.free(dest_path);
        switch (entry.kind) {
            .directory => dir.createDirPath(io, dest_path) catch return error.CopyFailed,
            .sym_link => {
                var link_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                const n = entry.dir.readLink(io, entry.basename, &link_buf) catch
                    return error.CopyFailed;
                dir.symLink(io, link_buf[0..n], dest_path, .{}) catch |e| switch (e) {
                    error.PathAlreadyExists => {},
                    else => return error.CopyFailed,
                };
            },
            else => {
                const src_path = std.fmt.allocPrint(gpa, "{s}/{s}", .{ src, entry.path }) catch
                    return error.OutOfMemory;
                defer gpa.free(src_path);
                dir.copyFile(src_path, dir, dest_path, io, .{ .make_path = true }) catch
                    return error.CopyFailed;
            },
        }
    }
}

/// Map a runner failure (spawn/timeout/truncation/OOM) to a DmgError. OOM
/// propagates as itself; everything else collapses to RunFailed.
fn mapRunError(e: runner_mod.RunError) DmgError {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.RunFailed,
    };
}

/// True only for a clean `exited == 0` termination.
fn termOk(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |c| c == 0,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// Tests (TDD step 1: written before the implementation below).
// ---------------------------------------------------------------------------

const testing = std.testing;

fn baseCfg() PackageConfig {
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
        .dmg = .{ .volname = "MyApp" },
    };
}

fn freeArgv(gpa: std.mem.Allocator, argv: []const []const u8) void {
    for (argv) |a| gpa.free(a);
    gpa.free(argv);
}

/// Build a minimal real `.app` directory tree (Contents/MacOS/<exe> + Info.plist)
/// under `base`, returning the gpa-owned absolute `.app` path. The dmg-staging path
/// is exercised against the real filesystem (only the four CLI tools are faked).
fn makeFixtureApp(io: std.Io, gpa: std.mem.Allocator, base: []const u8) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    const app = try std.fmt.allocPrint(gpa, "{s}/App.app", .{base});
    errdefer gpa.free(app);
    const macos = try std.fmt.allocPrint(gpa, "{s}/Contents/MacOS", .{app});
    defer gpa.free(macos);
    try cwd.createDirPath(io, macos);
    const exe = try std.fmt.allocPrint(gpa, "{s}/App", .{macos});
    defer gpa.free(exe);
    try cwd.writeFile(io, .{ .sub_path = exe, .data = "#!/bin/sh\necho hi\n" });
    const plist = try std.fmt.allocPrint(gpa, "{s}/Contents/Info.plist", .{app});
    defer gpa.free(plist);
    try cwd.writeFile(io, .{ .sub_path = plist, .data = "<plist/>\n" });
    return app;
}

fn tmpBase(io: std.Io, tmp: *std.testing.TmpDir, buf: []u8) ![]const u8 {
    return buf[0..try tmp.dir.realPath(io, buf)];
}

// ── buildDmgArgv (pure) ──────────────────────────────────────────────────────

test "buildDmgArgv emits the UDZO hdiutil create invocation" {
    const gpa = testing.allocator;
    const argv = try buildDmgArgv(gpa, "MyApp", "/tmp/stage", "/tmp/out/MyApp.dmg");
    defer freeArgv(gpa, argv);

    const expected = [_][]const u8{
        "hdiutil",    "create",
        "-volname",   "MyApp",
        "-srcfolder", "/tmp/stage",
        "-ov",        "-format",
        "UDZO",       "-fs",
        "HFS+",       "/tmp/out/MyApp.dmg",
    };
    try testing.expectEqual(expected.len, argv.len);
    for (expected, argv) |e, a| try testing.expectEqualStrings(e, a);
}

// ── makeDmg over a FakeRunner + a real staging tree ──────────────────────────

test "makeDmg stages the app, runs hdiutil, then re-signs and re-notarizes the dmg" {
    const io = testing.io;
    const gpa = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = try tmpBase(io, &tmp, &base_buf);

    const app = try makeFixtureApp(io, gpa, base);
    defer gpa.free(app);
    const out_dir = try std.fmt.allocPrint(gpa, "{s}/out", .{base});
    defer gpa.free(out_dir);
    try std.Io.Dir.cwd().createDirPath(io, out_dir);

    var fr = runner_mod.FakeRunner.init(gpa);
    defer fr.deinit();
    // hdiutil, then dmg sign (codesign + verify + spctl), then dmg notarize
    // (notarytool submit + stapler staple).
    try fr.push(.{ .term = .{ .exited = 0 }, .stdout = "", .stderr = "" }); // hdiutil
    try fr.push(.{ .term = .{ .exited = 0 }, .stdout = "", .stderr = "" }); // codesign(.dmg)
    try fr.push(.{ .term = .{ .exited = 0 }, .stdout = "", .stderr = "" }); // verify(.dmg)
    try fr.push(.{ .term = .{ .exited = 0 }, .stdout = "", .stderr = "" }); // spctl(pre-staple,.dmg)
    try fr.push(.{ .term = .{ .exited = 0 }, .stdout = "{\"status\":\"Accepted\",\"id\":\"x\"}", .stderr = "" }); // notarytool submit
    try fr.push(.{ .term = .{ .exited = 0 }, .stdout = "", .stderr = "" }); // stapler staple
    var runner = fr.runner();

    const creds: Credentials = .{ .apple_id = .{ .apple_id = "a@b.c", .password = "pw", .team_id = "TEAM" } };
    var diag: ?Diagnostic = null;
    const dmg = try makeDmg(io, gpa, &runner, app, "Developer ID Application: Acme", creds, baseCfg(), out_dir, &diag);
    defer gpa.free(dmg);

    try testing.expect(diag == null);
    try testing.expect(std.mem.endsWith(u8, dmg, "MyApp.dmg"));

    // Order: hdiutil first, then codesign on the dmg, then notarytool, then stapler.
    try testing.expectEqual(@as(usize, 6), fr.argv_log.items.len);
    try testing.expectEqualStrings("hdiutil", fr.argv_log.items[0][0]);
    try testing.expectEqualStrings("MyApp", fr.argv_log.items[0][3]); // -volname value
    try testing.expectEqualStrings("codesign", fr.argv_log.items[1][0]);
    try testing.expectEqualStrings("codesign", fr.argv_log.items[2][0]); // --verify
    try testing.expectEqualStrings("spctl", fr.argv_log.items[3][0]);
    try testing.expectEqualStrings("xcrun", fr.argv_log.items[4][0]);
    try testing.expectEqualStrings("notarytool", fr.argv_log.items[4][1]);
    try testing.expectEqualStrings("xcrun", fr.argv_log.items[5][0]);
    try testing.expectEqualStrings("stapler", fr.argv_log.items[5][1]);
}

test "makeDmg's dmg codesign carries the resolved signing identity, not cfg.macos.signingIdentity" {
    const io = testing.io;
    const gpa = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = try tmpBase(io, &tmp, &base_buf);

    const app = try makeFixtureApp(io, gpa, base);
    defer gpa.free(app);
    const out_dir = try std.fmt.allocPrint(gpa, "{s}/out", .{base});
    defer gpa.free(out_dir);
    try std.Io.Dir.cwd().createDirPath(io, out_dir);

    var fr = runner_mod.FakeRunner.init(gpa);
    defer fr.deinit();
    try fr.push(.{ .term = .{ .exited = 0 }, .stdout = "", .stderr = "" }); // hdiutil
    try fr.push(.{ .term = .{ .exited = 0 }, .stdout = "", .stderr = "" }); // codesign(.dmg)
    try fr.push(.{ .term = .{ .exited = 0 }, .stdout = "", .stderr = "" }); // verify(.dmg)
    try fr.push(.{ .term = .{ .exited = 0 }, .stdout = "", .stderr = "" }); // spctl(.dmg)
    try fr.push(.{ .term = .{ .exited = 0 }, .stdout = "{\"status\":\"Accepted\",\"id\":\"x\"}", .stderr = "" }); // notarytool
    try fr.push(.{ .term = .{ .exited = 0 }, .stdout = "", .stderr = "" }); // stapler
    var runner = fr.runner();

    var cfg = baseCfg();
    cfg.macos.signingIdentity = "Developer ID Application: SHOULD-NOT-BE-USED";
    const resolved = "Developer ID Application: RESOLVED (TEAM)";
    const creds: Credentials = .{ .apple_id = .{ .apple_id = "a@b.c", .password = "pw", .team_id = "TEAM" } };
    var diag: ?Diagnostic = null;
    const dmg = try makeDmg(io, gpa, &runner, app, resolved, creds, cfg, out_dir, &diag);
    defer gpa.free(dmg);

    // The dmg codesign argv's --sign value is the resolved identity (env override),
    // never cfg.macos.signingIdentity.
    const codesign_argv = fr.argv_log.items[1];
    var saw_resolved = false;
    for (codesign_argv) |a| {
        if (std.mem.eql(u8, a, resolved)) saw_resolved = true;
        try testing.expect(!std.mem.eql(u8, a, "Developer ID Application: SHOULD-NOT-BE-USED"));
    }
    try testing.expect(saw_resolved);
}

test "makeDmg returns HdiutilFailed before any dmg sign or notarize on a non-zero hdiutil exit" {
    const io = testing.io;
    const gpa = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = try tmpBase(io, &tmp, &base_buf);

    const app = try makeFixtureApp(io, gpa, base);
    defer gpa.free(app);
    const out_dir = try std.fmt.allocPrint(gpa, "{s}/out", .{base});
    defer gpa.free(out_dir);
    try std.Io.Dir.cwd().createDirPath(io, out_dir);

    var fr = runner_mod.FakeRunner.init(gpa);
    defer fr.deinit();
    try fr.push(.{ .term = .{ .exited = 1 }, .stdout = "", .stderr = "hdiutil: create failed" }); // hdiutil FAIL
    var runner = fr.runner();

    const creds: Credentials = .{ .apple_id = .{ .apple_id = "a@b.c", .password = "pw", .team_id = "TEAM" } };
    var diag: ?Diagnostic = null;
    const r = makeDmg(io, gpa, &runner, app, "Developer ID Application: Acme", creds, baseCfg(), out_dir, &diag);
    try testing.expectError(error.HdiutilFailed, r);

    // No dmg sign/notarize attempted after the hdiutil failure.
    try testing.expectEqual(@as(usize, 1), fr.argv_log.items.len);
    try testing.expect(diag != null);
    try testing.expectEqual(diagnostics.Code.unknown_tool_failure, diag.?.code);
    try testing.expectEqualStrings("hdiutil: create failed", diag.?.detail);
    gpa.free(diag.?.detail);
}

test "makeDmg with a null signing identity (skip_sign lane) builds an unsigned dmg" {
    const io = testing.io;
    const gpa = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = try tmpBase(io, &tmp, &base_buf);

    const app = try makeFixtureApp(io, gpa, base);
    defer gpa.free(app);
    const out_dir = try std.fmt.allocPrint(gpa, "{s}/out", .{base});
    defer gpa.free(out_dir);
    try std.Io.Dir.cwd().createDirPath(io, out_dir);

    var fr = runner_mod.FakeRunner.init(gpa);
    defer fr.deinit();
    try fr.push(.{ .term = .{ .exited = 0 }, .stdout = "", .stderr = "" }); // hdiutil only
    var runner = fr.runner();

    var diag: ?Diagnostic = null;
    const dmg = try makeDmg(io, gpa, &runner, app, null, .none, baseCfg(), out_dir, &diag);
    defer gpa.free(dmg);

    try testing.expect(diag == null);
    // No codesign/notarytool/stapler: only hdiutil.
    try testing.expectEqual(@as(usize, 1), fr.argv_log.items.len);
    try testing.expectEqualStrings("hdiutil", fr.argv_log.items[0][0]);
}

test "makeDmg with a signing identity but no notary creds signs but does not notarize" {
    const io = testing.io;
    const gpa = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = try tmpBase(io, &tmp, &base_buf);

    const app = try makeFixtureApp(io, gpa, base);
    defer gpa.free(app);
    const out_dir = try std.fmt.allocPrint(gpa, "{s}/out", .{base});
    defer gpa.free(out_dir);
    try std.Io.Dir.cwd().createDirPath(io, out_dir);

    var fr = runner_mod.FakeRunner.init(gpa);
    defer fr.deinit();
    try fr.push(.{ .term = .{ .exited = 0 }, .stdout = "", .stderr = "" }); // hdiutil
    try fr.push(.{ .term = .{ .exited = 0 }, .stdout = "", .stderr = "" }); // codesign(.dmg)
    try fr.push(.{ .term = .{ .exited = 0 }, .stdout = "", .stderr = "" }); // verify(.dmg)
    try fr.push(.{ .term = .{ .exited = 0 }, .stdout = "", .stderr = "" }); // spctl(.dmg)
    var runner = fr.runner();

    // notarize disabled so the ad-hoc-vs-real check in sign() is satisfied; the
    // .none creds mean makeDmg never re-enters notarize on the dmg.
    var cfg = baseCfg();
    cfg.macos.notarize = false;
    var diag: ?Diagnostic = null;
    const dmg = try makeDmg(io, gpa, &runner, app, "Developer ID Application: Acme", .none, cfg, out_dir, &diag);
    defer gpa.free(dmg);

    try testing.expect(diag == null);
    // hdiutil + codesign + verify + spctl, but NO notarytool/stapler.
    try testing.expectEqual(@as(usize, 4), fr.argv_log.items.len);
    try testing.expectEqualStrings("hdiutil", fr.argv_log.items[0][0]);
    try testing.expectEqualStrings("codesign", fr.argv_log.items[1][0]);
    for (fr.argv_log.items) |logged| {
        try testing.expect(!std.mem.eql(u8, logged[0], "xcrun"));
    }
}

test "makeDmg copies the app into the dmg staging tree" {
    const io = testing.io;
    const gpa = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = try tmpBase(io, &tmp, &base_buf);

    const app = try makeFixtureApp(io, gpa, base);
    defer gpa.free(app);
    const out_dir = try std.fmt.allocPrint(gpa, "{s}/out", .{base});
    defer gpa.free(out_dir);
    try std.Io.Dir.cwd().createDirPath(io, out_dir);

    var fr = runner_mod.FakeRunner.init(gpa);
    defer fr.deinit();
    try fr.push(.{ .term = .{ .exited = 0 }, .stdout = "", .stderr = "" }); // hdiutil only
    var runner = fr.runner();

    var diag: ?Diagnostic = null;
    const dmg = try makeDmg(io, gpa, &runner, app, null, .none, baseCfg(), out_dir, &diag);
    defer gpa.free(dmg);

    // The hdiutil -srcfolder staging dir holds App.app/Contents/MacOS/App with the
    // copied bytes (the fixture binary), proving the tree copy ran.
    const staging = fr.argv_log.items[0][5]; // -srcfolder value
    const staged_exe = try std.fmt.allocPrint(gpa, "{s}/App.app/Contents/MacOS/App", .{staging});
    defer gpa.free(staged_exe);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, staged_exe, gpa, .limited(4096));
    defer gpa.free(bytes);
    try testing.expectEqualStrings("#!/bin/sh\necho hi\n", bytes);

    // And the /Applications symlink is present in the staging tree.
    const apps_link = try std.fmt.allocPrint(gpa, "{s}/Applications", .{staging});
    defer gpa.free(apps_link);
    try std.Io.Dir.cwd().access(io, apps_link, .{});
}
