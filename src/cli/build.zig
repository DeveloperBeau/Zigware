const std = @import("std");
const proc = @import("proc.zig");
const dev = @import("dev.zig");
const csp = @import("csp.zig");
const assets_embed = @import("assetsEmbed.zig");
const Manifest = @import("zigware_manifest").Manifest;
const package = @import("package");
const diag = @import("diagnostics");

const log = diag.scoped("build");

// Canonical handoff types live in the package module; re-export so existing
// build.Artifacts / build.Arch references keep resolving to the one true type.
pub const Artifacts = package.Artifacts;
pub const Arch = package.Arch;

pub const BuildOptions = struct {
    manifest: *const Manifest,
    optimize: std.builtin.OptimizeMode = .ReleaseSafe, // NOT ReleaseFast; src/main.zig comptime-bans it
    out_dir: []const u8,
    builder: dev.BuildRunner,
    proc: proc.Spawner,
    target: ?[]const u8 = null,
};

/// Subdirectory under out_dir that holds the CSP-transformed copy of index.html.
/// The generated asset_table.zig points index.html's @embedFile at this staged copy
/// (so the embedded bytes are the transformed HTML, never the raw dist file).
const staged_dir = "staged";
const asset_table_name = "asset_table.zig";
const build_fragment_name = "assets.build.zig";

/// build orchestrator: frontend.build -> asset embed -> CSP inject -> release compile.
///
/// Operates relative to the process cwd (the scaffolded project root). It reads the
/// frontend dist named by the manifest, computes the strict CSP with this build's own
/// script hashes, injects it into index.html, and stages the TRANSFORMED index.html so
/// the generated asset_table.zig embeds the injected bytes rather than the raw file. The
/// release compile then runs through the injected BuildRunner at `.ReleaseSafe`.
///
/// Returns the gpa-owned path to the compiled release binary (the conventional install
/// location). The Manifest->Artifacts mapping moved to the packaging module: `main`
/// hands this path to `package()`, which adapts the manifest and fills the canonical
/// `Artifacts`. The caller frees the returned slice.
pub fn run(io: std.Io, gpa: std.mem.Allocator, opts: BuildOptions) anyerror![]const u8 {
    const manifest = opts.manifest;

    // (1) frontend.build, if declared: spawn + wait. Never killed (not a dev child);
    // any non-zero exit is fatal before_command_failed.
    if (manifest.frontend.build) |cmd| {
        var child = try opts.proc.spawn(io, gpa, .{
            .argv = &.{ "/bin/sh", "-c", cmd },
            .inherit_stdio = true,
        });
        const term = try opts.proc.wait(io, &child);
        switch (term) {
            .exited => |code| if (code != 0) return error.before_command_failed,
            .signal, .unknown => return error.before_command_failed,
        }
    }

    // (2) Walk outDir. walk maps a missing dir to frontend_dist_missing and any
    // escaping entry to asset_outside_dist; both propagate as the CliError of the same name.
    const dist_dir = manifest.frontend.outDir;
    var walked = try assets_embed.walk(io, gpa, dist_dir);
    defer walked.deinit();

    const cwd = std.Io.Dir.cwd();

    // (3) Read index.html, gather every script to hash: each `.js` entry's file bytes plus
    // each inline <script>…</script> body in index.html. Compute hashes, build the strict
    // CSP, inject it into the index.html bytes.
    const index_entry = findIndex(walked.entries) orelse return error.frontend_dist_missing;

    var dist = cwd.openDir(io, dist_dir, .{}) catch return error.frontend_dist_missing;
    defer dist.close(io);

    const index_html = try dist.readFileAlloc(io, index_entry.import_name, gpa, .limited(16 * 1024 * 1024));
    defer gpa.free(index_html);

    // Collect script byte-slices (owned transiently) to feed scriptHashes.
    var scripts: std.ArrayList([]const u8) = .empty;
    defer {
        for (scripts.items) |s| gpa.free(s);
        scripts.deinit(gpa);
    }

    // Every .js entry contributes its file bytes.
    for (walked.entries) |e| {
        if (std.mem.endsWith(u8, e.import_name, ".js")) {
            const bytes = try dist.readFileAlloc(io, e.import_name, gpa, .limited(16 * 1024 * 1024));
            try scripts.append(gpa, bytes);
        }
    }
    // Every inline <script>…</script> body in index.html contributes its body bytes.
    try collectInlineScripts(gpa, &scripts, index_html);

    const hashes = try csp.scriptHashes(gpa, scripts.items);
    defer {
        for (hashes) |h| gpa.free(h.b64);
        gpa.free(hashes);
    }

    const policy = try csp.buildCsp(gpa, hashes, manifest);
    defer gpa.free(policy);

    const transformed = try csp.injectIntoHtml(gpa, index_html, policy);
    defer gpa.free(transformed);

    // (4) Stage the transformed index.html under out_dir/staged and emit the build fragment
    // + asset_table.zig. The index.html entry's import_name is rewritten to point at the
    // staged copy so its @embedFile sees the CSP-injected bytes; every other entry keeps its
    // dist-relative import_name.
    var out = try ensureDir(io, opts.out_dir);
    defer out.close(io);

    try out.createDirPath(io, staged_dir);

    // Stage EVERY frontend asset into the staged dir, colocated with the
    // asset_table.zig emitted below so its `@embedFile(import_name)` names resolve
    // by path. index.html is the CSP-injected copy; all other assets are copied
    // from outDir verbatim.
    for (walked.entries) |e| {
        const dest = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ staged_dir, e.import_name });
        defer gpa.free(dest);
        if (std.fs.path.dirnamePosix(dest)) |parent| try out.createDirPath(io, parent);
        if (std.mem.eql(u8, e.serve_path, index_entry.serve_path)) {
            try out.writeFile(io, .{ .sub_path = dest, .data = transformed });
        } else {
            const bytes = try dist.readFileAlloc(io, e.import_name, gpa, .limited(16 * 1024 * 1024));
            defer gpa.free(bytes);
            try out.writeFile(io, .{ .sub_path = dest, .data = bytes });
        }
    }

    // Emit asset_table.zig INTO the staged dir (colocated). The scaffold build
    // wires it via -Dasset_table, shadowing the framework's default table.
    const staged_table_rel = staged_dir ++ "/" ++ asset_table_name;
    try writeEmitted(io, gpa, out, staged_table_rel, walked.entries, assets_embed.emitAssetTable);

    // Path passed to the scaffold build (relative to the build cwd, like out_dir).
    const asset_table_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ opts.out_dir, staged_table_rel });
    defer gpa.free(asset_table_path);

    // (5) Release compile through the injected runner. ReleaseSafe ONLY (main.zig bans
    // ReleaseFast/ReleaseSmall). A non-ok result is fatal zig_build_failed; the captured
    // compiler stderr is printed verbatim and the buffer freed.
    const result = try opts.builder.build(io, gpa, .{ .optimize = opts.optimize, .dev = false, .asset_table = asset_table_path, .target = opts.target });
    defer gpa.free(result.stderr);
    if (!result.ok) {
        if (result.stderr.len > 0) log.err("release build failed", &.{diag.str("stderr", result.stderr)});
        return error.zig_build_failed;
    }

    // (6) Return the release binary path: the conventional install location for the
    // scaffold's release exe (zig-out/bin/<productName>). The packaging step consumes it
    // and fills the canonical Artifacts from the manifest.
    return std.fmt.allocPrint(gpa, "zig-out/bin/{s}", .{manifest.productName});
}

/// Find the index.html entry (serve_path "/index.html") in the walk result.
fn findIndex(entries: []const assets_embed.Entry) ?assets_embed.Entry {
    for (entries) |e| {
        if (std.mem.eql(u8, e.serve_path, "/index.html")) return e;
    }
    return null;
}

/// Open out_dir, creating it (and any parents) if absent.
fn ensureDir(io: std.Io, path: []const u8) !std.Io.Dir {
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, path) catch {};
    return cwd.openDir(io, path, .{});
}

/// Run an emitter (emitAssetTable / emitBuildFragment) over `entries` into a fresh
/// allocating writer, then write the result to `name` under `dir`.
fn writeEmitted(
    io: std.Io,
    gpa: std.mem.Allocator,
    dir: std.Io.Dir,
    name: []const u8,
    entries: []const assets_embed.Entry,
    comptime emit: fn (*std.Io.Writer, []const assets_embed.Entry) anyerror!void,
) !void {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try emit(&aw.writer, entries);
    try dir.writeFile(io, .{ .sub_path = name, .data = aw.writer.buffered() });
}

/// Append each inline `<script>…</script>` BODY (the bytes between the tags, excluding a
/// `<script src=…>` external reference) to `scripts`. Each appended slice is a fresh dupe
/// owned by the caller. A `<script>` carrying a `src=` attribute references an external
/// file (covered by its own .js entry, or not own-origin) and contributes no inline
/// body, so it is skipped.
fn collectInlineScripts(gpa: std.mem.Allocator, scripts: *std.ArrayList([]const u8), html: []const u8) !void {
    var i: usize = 0;
    while (i < html.len) {
        const open_rel = ciIndexFrom(html, i, "<script") orelse break;
        // End of the opening tag.
        const tag_close_rel = std.mem.indexOfScalarPos(u8, html, open_rel, '>') orelse break;
        const open_tag = html[open_rel .. tag_close_rel + 1];
        const body_start = tag_close_rel + 1;

        // Find the matching </script>.
        const close_rel = ciIndexFrom(html, body_start, "</script") orelse break;
        const body = html[body_start..close_rel];

        // Skip external references (src=…) and empty bodies; hash only inline bodies.
        if (ciContains(open_tag, "src=") == false and body.len > 0) {
            try scripts.append(gpa, try gpa.dupe(u8, body));
        }

        // Advance past this close tag's '>'.
        const after_close = std.mem.indexOfScalarPos(u8, html, close_rel, '>') orelse break;
        i = after_close + 1;
    }
}

/// Case-insensitive substring search starting at `from`; returns absolute index or null.
fn ciIndexFrom(haystack: []const u8, from: usize, needle: []const u8) ?usize {
    if (needle.len == 0) return from;
    if (from >= haystack.len) return null;
    var i: usize = from;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

fn ciContains(haystack: []const u8, needle: []const u8) bool {
    return ciIndexFrom(haystack, 0, needle) != null;
}

// ─────────────────────────── tests ───────────────────────────

const testing = std.testing;

/// Records the optimize/dev mode of each build call and returns a canned ok result with an
/// owned (possibly empty) stderr copy so the seam frees exercise real allocator bookkeeping.
const FakeBuilder = struct {
    ok: bool = true,
    stderr_text: []const u8 = "",
    last_optimize: ?std.builtin.OptimizeMode = null,
    last_dev: ?bool = null,
    builds: usize = 0,
    gpa: std.mem.Allocator,

    fn make(self: *FakeBuilder) dev.BuildRunner {
        return .{ .ptr = self, .vtable = &vtable };
    }
    const vtable: dev.BuildRunner.VTable = .{ .build = build };
    fn build(ptr: *anyopaque, _: std.Io, gpa: std.mem.Allocator, spec: dev.BuildSpec) anyerror!dev.BuildResult {
        const self: *FakeBuilder = @ptrCast(@alignCast(ptr));
        self.last_optimize = spec.optimize;
        self.last_dev = spec.dev;
        self.builds += 1;
        const buf = try gpa.alloc(u8, self.stderr_text.len);
        @memcpy(buf, self.stderr_text);
        return .{ .ok = self.ok, .stderr = buf };
    }
};

/// Records every frontend.build spawn (argv joined) and the canned exit code each wait
/// returns. Never asked to kill.
const FakeSpawner = struct {
    exit_code: u8 = 0,
    spawns: usize = 0,
    waits: usize = 0,

    fn make(self: *FakeSpawner) proc.Spawner {
        return .{ .ptr = self, .vtable = &vtable };
    }
    const vtable: proc.Spawner.VTable = .{ .spawn = spawn, .wait = wait, .kill = kill };
    fn spawn(ptr: *anyopaque, _: std.Io, _: std.mem.Allocator, _: proc.ChildSpec) anyerror!proc.Child {
        const self: *FakeSpawner = @ptrCast(@alignCast(ptr));
        self.spawns += 1;
        var inner: std.process.Child = undefined;
        inner.id = 7;
        return .{ .inner = inner };
    }
    fn wait(ptr: *anyopaque, _: std.Io, _: *proc.Child) anyerror!proc.Term {
        const self: *FakeSpawner = @ptrCast(@alignCast(ptr));
        self.waits += 1;
        return .{ .exited = self.exit_code };
    }
    fn kill(_: *anyopaque, _: std.Io, _: *proc.Child) anyerror!void {
        return; // never used by the build verb
    }
};

fn testManifest() Manifest {
    return .{ .identifier = "com.example.app", .productName = "Example", .version = "0.1.0" };
}

/// Write a `dist/index.html` fixture under `dir`. The tests pass ABSOLUTE paths for
/// outDir/out_dir (run() opens them through Dir.cwd, which accepts absolute paths)
/// so no process-global chdir is needed and the tests stay parallel-safe.
fn fixtureWithIndex(io: std.Io, dir: std.Io.Dir, index_html: []const u8) !void {
    try dir.createDirPath(io, "dist");
    try dir.writeFile(io, .{ .sub_path = "dist/index.html", .data = index_html });
}

/// Absolute path `<tmp realpath>/<sub>` into `buf`. Used to hand run() absolute
/// outDir/out_dir so it resolves them without a chdir.
fn absUnder(io: std.Io, dir: std.Io.Dir, buf: []u8, sub: []const u8) ![]const u8 {
    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try dir.realPath(io, &base_buf)];
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ base, sub });
}

test "build: asset_table embeds the CSP-injected index.html, hashes present, no eval path" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // A dist with an inline <script> AND an external .js so BOTH hash sources are exercised.
    const html =
        "<html><head><title>x</title></head><body>" ++
        "<script>console.log('hi')</script>" ++
        "<script src=\"app.js\"></script></body></html>";
    try fixtureWithIndex(io, tmp.dir, html);
    try tmp.dir.writeFile(io, .{ .sub_path = "dist/app.js", .data = "export const x = 1;" });
    try tmp.dir.createDirPath(io, "out");

    var dist_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var out_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dist = try absUnder(io, tmp.dir, &dist_buf, "dist");
    const out = try absUnder(io, tmp.dir, &out_buf, "out");

    var builder = FakeBuilder{ .gpa = testing.allocator };
    var spawner = FakeSpawner{};
    var manifest = testManifest();
    manifest.frontend.outDir = dist;

    const binary_path = try run(io, testing.allocator, .{
        .manifest = &manifest,
        .out_dir = out,
        .builder = builder.make(),
        .proc = spawner.make(),
    });
    defer testing.allocator.free(binary_path);

    // The generated asset_table.zig is emitted INTO the staged dir, colocated with
    // every staged asset, so its @embedFile names are dist-relative (resolved from
    // the table's own directory) rather than prefixed with "staged/".
    const table = try tmp.dir.readFileAlloc(io, "out/staged/asset_table.zig", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(table);
    try testing.expect(std.mem.indexOf(u8, table, "@embedFile(\"index.html\")") != null);
    try testing.expect(std.mem.indexOf(u8, table, "@embedFile(\"app.js\")") != null);

    // The staged index.html carries a CSP meta with the strict policy and the computed
    // script hashes (one for the inline body, one for the .js file).
    const staged = try tmp.dir.readFileAlloc(io, "out/staged/index.html", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(staged);
    try testing.expect(std.mem.indexOf(u8, staged, "Content-Security-Policy") != null);
    try testing.expect(std.mem.indexOf(u8, staged, "'sha256-") != null);

    // No eval path: the strict policy never emits unsafe-eval, and no dev-client string is
    // injected by a default (allowEval off) build.
    try testing.expect(std.mem.indexOf(u8, staged, "unsafe-eval") == null);
    try testing.expect(std.mem.indexOf(u8, staged, "ZIGWARE_DEV") == null);

    // The release compile ran at ReleaseSafe, not ReleaseFast, with dev=false.
    try testing.expectEqual(std.builtin.OptimizeMode.ReleaseSafe, builder.last_optimize.?);
    try testing.expectEqual(false, builder.last_dev.?);

    // run now returns the release binary path; Artifacts population (app name, bundle id,
    // icon/signing fields) is covered by the package() pipeline + configFromManifest tests.
    try testing.expect(std.mem.endsWith(u8, binary_path, "/Example"));
}

test "build: hash count matches inline + external scripts (two hashes)" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const html =
        "<html><head></head><body>" ++
        "<script>alert(1)</script></body></html>";
    try fixtureWithIndex(io, tmp.dir, html);
    try tmp.dir.writeFile(io, .{ .sub_path = "dist/main.js", .data = "var y = 2;" });
    try tmp.dir.createDirPath(io, "out");

    var dist_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var out_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dist = try absUnder(io, tmp.dir, &dist_buf, "dist");
    const out = try absUnder(io, tmp.dir, &out_buf, "out");

    var builder = FakeBuilder{ .gpa = testing.allocator };
    var spawner = FakeSpawner{};
    var manifest = testManifest();
    manifest.frontend.outDir = dist;

    const binary_path = try run(io, testing.allocator, .{
        .manifest = &manifest,
        .out_dir = out,
        .builder = builder.make(),
        .proc = spawner.make(),
    });
    defer testing.allocator.free(binary_path);

    const staged = try tmp.dir.readFileAlloc(io, "out/staged/index.html", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(staged);

    // Exactly two 'sha256-' sources: one for the inline body, one for main.js.
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, staged, "'sha256-"));
}

test "build: missing frontend dist errors frontend_dist_missing" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "out"); // no dist/

    var dist_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var out_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dist = try absUnder(io, tmp.dir, &dist_buf, "dist");
    const out = try absUnder(io, tmp.dir, &out_buf, "out");

    var builder = FakeBuilder{ .gpa = testing.allocator };
    var spawner = FakeSpawner{};
    var manifest = testManifest();
    manifest.frontend.outDir = dist;

    try testing.expectError(error.frontend_dist_missing, run(io, testing.allocator, .{
        .manifest = &manifest,
        .out_dir = out,
        .builder = builder.make(),
        .proc = spawner.make(),
    }));
    try testing.expectEqual(@as(usize, 0), builder.builds); // never reached the compile
}

test "build: escaping symlink in dist errors asset_outside_dist" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try fixtureWithIndex(io, tmp.dir, "<html><head></head><body></body></html>");
    // A symlink whose target escapes the dist; skip if the host refuses symlinks.
    tmp.dir.symLink(io, "/etc/passwd", "dist/escape", .{}) catch return;
    try tmp.dir.createDirPath(io, "out");

    var dist_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var out_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dist = try absUnder(io, tmp.dir, &dist_buf, "dist");
    const out = try absUnder(io, tmp.dir, &out_buf, "out");

    var builder = FakeBuilder{ .gpa = testing.allocator };
    var spawner = FakeSpawner{};
    var manifest = testManifest();
    manifest.frontend.outDir = dist;

    try testing.expectError(error.asset_outside_dist, run(io, testing.allocator, .{
        .manifest = &manifest,
        .out_dir = out,
        .builder = builder.make(),
        .proc = spawner.make(),
    }));
}

test "build: frontend.build non-zero exit is fatal before_command_failed" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try fixtureWithIndex(io, tmp.dir, "<html><head></head><body></body></html>");
    try tmp.dir.createDirPath(io, "out");

    var dist_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var out_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dist = try absUnder(io, tmp.dir, &dist_buf, "dist");
    const out = try absUnder(io, tmp.dir, &out_buf, "out");

    var builder = FakeBuilder{ .gpa = testing.allocator };
    var spawner = FakeSpawner{ .exit_code = 1 };
    var manifest = testManifest();
    manifest.frontend.outDir = dist;
    manifest.frontend.build = "exit 1";

    try testing.expectError(error.before_command_failed, run(io, testing.allocator, .{
        .manifest = &manifest,
        .out_dir = out,
        .builder = builder.make(),
        .proc = spawner.make(),
    }));
    try testing.expectEqual(@as(usize, 1), spawner.spawns);
    try testing.expectEqual(@as(usize, 1), spawner.waits);
    try testing.expectEqual(@as(usize, 0), builder.builds); // fatal before the compile
}

test "build: frontend.build success then build proceeds" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try fixtureWithIndex(io, tmp.dir, "<html><head></head><body></body></html>");
    try tmp.dir.createDirPath(io, "out");

    var dist_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var out_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dist = try absUnder(io, tmp.dir, &dist_buf, "dist");
    const out = try absUnder(io, tmp.dir, &out_buf, "out");

    var builder = FakeBuilder{ .gpa = testing.allocator };
    var spawner = FakeSpawner{ .exit_code = 0 };
    var manifest = testManifest();
    manifest.frontend.outDir = dist;
    manifest.frontend.build = "true";

    const binary_path = try run(io, testing.allocator, .{
        .manifest = &manifest,
        .out_dir = out,
        .builder = builder.make(),
        .proc = spawner.make(),
    });
    defer testing.allocator.free(binary_path);

    try testing.expectEqual(@as(usize, 1), spawner.spawns);
    try testing.expectEqual(@as(usize, 1), builder.builds);
}

test "build: failed release compile errors zig_build_failed" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try fixtureWithIndex(io, tmp.dir, "<html><head></head><body></body></html>");
    try tmp.dir.createDirPath(io, "out");

    var dist_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var out_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dist = try absUnder(io, tmp.dir, &dist_buf, "dist");
    const out = try absUnder(io, tmp.dir, &out_buf, "out");

    var builder = FakeBuilder{ .ok = false, .stderr_text = "compile error", .gpa = testing.allocator };
    var spawner = FakeSpawner{};
    var manifest = testManifest();
    manifest.frontend.outDir = dist;

    try testing.expectError(error.zig_build_failed, run(io, testing.allocator, .{
        .manifest = &manifest,
        .out_dir = out,
        .builder = builder.make(),
        .proc = spawner.make(),
    }));
}

// The former "icon and macos signing/entitlements map into Artifacts" test was removed:
// build.run no longer produces an Artifacts, so that mapping now lives in (and is tested
// by) the packaging module's configFromManifest adapter.
