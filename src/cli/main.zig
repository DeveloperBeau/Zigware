const std = @import("std");
const builtin = @import("builtin");

const proc = @import("proc.zig");
const watch = @import("watch.zig");
const devserver = @import("devserver.zig");
const dev = @import("dev.zig");
const build_verb = @import("build.zig");
const init_verb = @import("init.zig");

// `zigware_manifest` is rooted at src/manifest/parse.zig, so the parser surface
// (parseAtBuild, freeManifest, Diagnostics, LoadError) and the Manifest type all
// resolve through this single named import. No src/cli/* file path-imports the
// manifest sources directly (double-membership prohibition).
const parse = @import("zigware_manifest");

pub const CliError = error{
    manifest_not_found,
    manifest_invalid,
    before_command_failed,
    dev_url_timeout,
    zig_build_failed,
    frontend_dist_missing,
    asset_outside_dist,
    csp_conflict,
    init_dir_not_empty,
    bad_usage,
    OutOfMemory,
};

pub const Cmd = enum { init, dev, build, help, version };

fn parseCmd(s: []const u8) ?Cmd {
    return std.meta.stringToEnum(Cmd, s);
}

/// Maps argv[1] to a verb and dispatches.
pub fn dispatch(io: std.Io, gpa: std.mem.Allocator, args: []const []const u8) CliError!void {
    if (args.len < 2) return printHelp();
    const cmd = parseCmd(args[1]) orelse return CliError.bad_usage;
    switch (cmd) {
        .help => return printHelp(),
        .version => return printVersion(),
        .init => return runInit(io, gpa, args[2..]),
        .dev => return runDev(io, gpa),
        .build => return runBuild(io, gpa),
    }
}

fn printHelp() CliError!void {
    std.debug.print(
        \\zigware <command>
        \\  init <dir>    scaffold a new project
        \\  dev           run the dev loop
        \\  build         produce a release binary + artifact manifest
        \\  version       print the version
        \\  help          print this help
        \\
    , .{});
}

fn printVersion() CliError!void {
    std.debug.print("zigware 0.1.0\n", .{});
}

// ─────────────────────────── init verb ───────────────────────────

/// Parse `zigware init <dir> [--template <t>] [--force] [--name <n>]` and scaffold.
/// The template defaults to vanilla when no `--template` flag is given (no interactive
/// picker: a stdin prompt would not be headless-testable and the plan permits defaulting).
/// `--name` defaults to the directory's basename.
fn runInit(io: std.Io, gpa: std.mem.Allocator, rest: []const []const u8) CliError!void {
    var dir: ?[]const u8 = null;
    var template: init_verb.Template = .vanilla;
    var force = false;
    var name: ?[]const u8 = null;

    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (std.mem.eql(u8, a, "--force")) {
            force = true;
        } else if (std.mem.eql(u8, a, "--template")) {
            i += 1;
            if (i >= rest.len) return CliError.bad_usage;
            template = std.meta.stringToEnum(init_verb.Template, rest[i]) orelse return CliError.bad_usage;
        } else if (std.mem.eql(u8, a, "--name")) {
            i += 1;
            if (i >= rest.len) return CliError.bad_usage;
            name = rest[i];
        } else if (std.mem.startsWith(u8, a, "--")) {
            return CliError.bad_usage;
        } else if (dir == null) {
            dir = a;
        } else {
            return CliError.bad_usage;
        }
    }

    const target_dir = dir orelse return CliError.bad_usage;
    const project_name = name orelse std.fs.path.basename(target_dir);

    init_verb.run(io, gpa, .{
        .dir = target_dir,
        .name = project_name,
        .template = template,
        .force = force,
    }) catch |err| return mapVerbError(err);
}

// ─────────────────────────── dev verb ───────────────────────────

/// Watch roots for the polling watcher: the source tree plus the manifest file.
const dev_watch_roots = [_][]const u8{ "src", "zigware.zon" };
const dev_watch_interval_ms: u32 = 250;

/// File-scope probe wrapper matching the `UrlProbe` signature (no opts param): production
/// wires this into `DevContext.wait_for_url`; it forwards to devserver.waitForUrl with the
/// default WaitOptions while threading the shutdown flag through.
fn devserverProbe(io: std.Io, gpa: std.mem.Allocator, url: []const u8, shutdown: *std.atomic.Value(bool)) anyerror!void {
    return devserver.waitForUrl(io, gpa, url, .{}, shutdown);
}

/// `zigware dev`: read the project manifest, install cooperative SIGINT, and run the dev
/// loop. dev == Debug build, so the manifest is validated under .Debug (release rejects
/// the debug-inspector fuse; a dev manifest that enables it must validate here).
fn runDev(io: std.Io, gpa: std.mem.Allocator) CliError!void {
    const manifest = readManifest(io, gpa, .Debug) catch |err| return mapVerbError(err);
    var m = manifest;
    defer parse.freeManifest(gpa, m);

    // Construct the shutdown flag FIRST so installSigint and the watcher both reference the
    // same live flag; the `defer uninstall` disarms the handler before the flag leaves scope.
    var shutdown = std.atomic.Value(bool).init(false);
    installSigint(&shutdown);
    defer uninstallSigint();

    const watcher = watch.polling(gpa, &dev_watch_roots, dev_watch_interval_ms, &shutdown) catch |err| return mapVerbError(err);

    var runner = SystemBuildRunner{};
    var ctx = dev.DevContext{
        .io = io,
        .gpa = gpa,
        .manifest = &m,
        .proc = proc.system(),
        .watcher = watcher,
        .builder = runner.make(),
        .wait_for_url = devserverProbe,
        .shutdown = &shutdown,
    };

    dev.run(&ctx) catch |err| return mapVerbError(err);
}

// ─────────────────────────── build verb ───────────────────────────

/// `zigware build`: read the project manifest (validated under .ReleaseSafe, the shipped
/// release mode), then run the build orchestrator. No SIGINT install — build has no
/// long-lived child loop to interrupt.
fn runBuild(io: std.Io, gpa: std.mem.Allocator) CliError!void {
    const manifest = readManifest(io, gpa, .ReleaseSafe) catch |err| return mapVerbError(err);
    var m = manifest;
    defer parse.freeManifest(gpa, m);

    var runner = SystemBuildRunner{};
    const arts = build_verb.run(io, gpa, .{
        .manifest = &m,
        .optimize = .ReleaseSafe,
        .out_dir = "zig-out",
        .builder = runner.make(),
        .proc = proc.system(),
    }) catch |err| return mapVerbError(err);
    defer gpa.free(arts.binary_path);

    std.debug.print("built {s} ({s}) -> {s}\n", .{ arts.app_name, arts.version, arts.binary_path });
}

// ─────────────────────────── manifest read ───────────────────────────

/// Read the END-USER's zigware.zon from the process cwd (the scaffolded project root) via
/// D's disk reader. The returned Manifest is allocator-OWNED and must be freed with
/// freeManifest — this is NOT parse.embedded() (which would return Zigware's OWN baked-in
/// manifest). Load errors are mapped to the CLI's structured variants.
fn readManifest(io: std.Io, gpa: std.mem.Allocator, optimize: std.builtin.OptimizeMode) CliError!parse.Manifest {
    var diag: parse.Diagnostics = .{};
    defer diag.deinit(gpa);

    const root_dir = std.Io.Dir.cwd();
    const result = parse.parseAtBuild(gpa, io, root_dir, builtin.target.os.tag, optimize, &diag);

    // Surface every diagnostic (errors that pin the bad key on a ValidationFailed, plus
    // warnings such as dev_url_without_command on the success path). Without this, the
    // "see the diagnostics above" message refers to output that was never emitted.
    printDiagnostics(&diag);

    return result catch |err| switch (err) {
        error.FileNotFound => CliError.manifest_not_found,
        error.ParseFailed, error.ValidationFailed => CliError.manifest_invalid,
        error.OutOfMemory => CliError.OutOfMemory,
    };
}

/// Print each collected manifest diagnostic to stderr, tagging error vs warning and
/// appending the offending key/path when D supplied one.
fn printDiagnostics(diag: *const parse.Diagnostics) void {
    for (diag.items.items) |d| {
        const tag = if (d.is_error) "error" else "warning";
        if (d.path) |p| {
            std.debug.print("zigware.zon {s}: {s} ({s})\n", .{ tag, d.message, p });
        } else {
            std.debug.print("zigware.zon {s}: {s}\n", .{ tag, d.message });
        }
    }
}

/// Narrow an arbitrary verb `anyerror` to the structured `CliError` contract. The leaves
/// return their failures as `error.<cli_error_name>` (e.g. error.before_command_failed),
/// so the common cases map by name. An unexpected infrastructure error (a spawn or I/O
/// failure) is NOT a usage mistake, so it is printed by its real name before collapsing
/// onto the bad_usage exit code rather than being silently mislabeled "bad usage".
fn mapVerbError(err: anyerror) CliError {
    return switch (err) {
        error.manifest_not_found => CliError.manifest_not_found,
        error.manifest_invalid => CliError.manifest_invalid,
        error.before_command_failed => CliError.before_command_failed,
        error.dev_url_timeout => CliError.dev_url_timeout,
        error.zig_build_failed => CliError.zig_build_failed,
        error.frontend_dist_missing => CliError.frontend_dist_missing,
        error.asset_outside_dist => CliError.asset_outside_dist,
        error.csp_conflict => CliError.csp_conflict,
        error.init_dir_not_empty => CliError.init_dir_not_empty,
        error.OutOfMemory => CliError.OutOfMemory,
        else => {
            std.debug.print("zigware: internal error: {s}\n", .{@errorName(err)});
            return CliError.bad_usage;
        },
    };
}

// ─────────────────────────── real BuildRunner ───────────────────────────

/// Production BuildRunner over `std.process.run` (which spawns, collects stdout/stderr, and
/// reaps the child itself — no separate kill/wait needed). It maps the run result's term to
/// the seam's `ok` bool and transfers ONLY stderr into BuildResult; the captured stdout is
/// freed here (a leaked compiler-stdout buffer per dev rebuild would accumulate across the
/// long-lived dev loop).
const SystemBuildRunner = struct {
    fn make(self: *SystemBuildRunner) dev.BuildRunner {
        return .{ .ptr = self, .vtable = &vtable };
    }
    const vtable: dev.BuildRunner.VTable = .{ .build = build };

    fn build(_: *anyopaque, io: std.Io, gpa: std.mem.Allocator, spec: dev.BuildSpec) anyerror!dev.BuildResult {
        // ReleaseSafe uses the repo's `-Drelease=true` flag (NOT -Doptimize); Debug omits it.
        const argv: []const []const u8 = switch (spec.optimize) {
            .Debug => &.{ "zig", "build" },
            else => &.{ "zig", "build", "-Drelease=true" },
        };

        const result = try std.process.run(gpa, io, .{ .argv = argv });
        // stderr is transferred into BuildResult; stdout is discarded here so it never leaks.
        defer gpa.free(result.stdout);

        const ok = switch (result.term) {
            .exited => |code| code == 0,
            else => false,
        };
        return .{ .ok = ok, .stderr = result.stderr };
    }
};

// ─────────────────────────── CliError → exit code + message ───────────────────────────

/// Pure mapping from a CliError to a DISTINCT process exit code. Factored out of `main` so
/// the user-facing error contract is unit-testable without running the binary. Every variant
/// gets its own code; the exhaustive switch makes a future variant a compile error here
/// rather than a silent collapse onto an existing code.
fn exitCodeFor(err: CliError) u8 {
    return switch (err) {
        CliError.manifest_not_found => 2,
        CliError.manifest_invalid => 3,
        CliError.before_command_failed => 4,
        CliError.dev_url_timeout => 5,
        CliError.zig_build_failed => 6,
        CliError.frontend_dist_missing => 7,
        CliError.asset_outside_dist => 8,
        CliError.csp_conflict => 9,
        CliError.init_dir_not_empty => 10,
        CliError.bad_usage => 11,
        CliError.OutOfMemory => 12,
    };
}

/// A human-readable stderr line for each CliError — never a bare "command failed". The
/// compiler/child stderr itself is printed verbatim at the point of failure (dev.run /
/// build.run); this is the one-line summary the top-level catch emits.
fn messageFor(err: CliError) []const u8 {
    return switch (err) {
        CliError.manifest_not_found => "zigware.zon not found in the current directory",
        CliError.manifest_invalid => "zigware.zon is invalid (see the diagnostics above)",
        CliError.before_command_failed => "a before-command exited non-zero",
        CliError.dev_url_timeout => "timed out waiting for the dev server URL",
        CliError.zig_build_failed => "zig build failed (compiler output above)",
        CliError.frontend_dist_missing => "the frontend dist directory was not found",
        CliError.asset_outside_dist => "an asset resolves outside the frontend dist directory",
        CliError.csp_conflict => "the index.html already declares a conflicting Content-Security-Policy",
        CliError.init_dir_not_empty => "the target directory is not empty (use --force to overwrite)",
        CliError.bad_usage => "bad usage (run `zigware help`)",
        CliError.OutOfMemory => "out of memory",
    };
}

// ─────────────────────────── cooperative SIGINT shutdown ───────────────────────────
//
// The SIGINT handler runs with no userdata and a fixed C signature, so the shutdown
// flag it must flip is reached through a file-scope pointer the install routine stores.
// The dev dispatch constructs the flag on its stack, installs the handler pointed at it,
// and `defer`s uninstall so the handler is disarmed and `g_shutdown` nulled before the
// flag leaves scope — a late SIGINT after the dev frame unwinds then finds a null pointer
// instead of storing through freed stack.

var g_shutdown: ?*std.atomic.Value(bool) = null;

fn onSigint(_: std.posix.SIG) callconv(.c) void {
    if (g_shutdown) |s| s.store(true, .seq_cst);
}

fn installSigint(flag: *std.atomic.Value(bool)) void {
    g_shutdown = flag;
    var act: std.posix.Sigaction = .{
        .handler = .{ .handler = onSigint },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
}

/// Disarm the handler before the pointed-at `shutdown` flag leaves scope. The `dev`
/// dispatch MUST call this (via `defer`) so a SIGINT delivered after the dev frame
/// unwinds does not store through a dangling stack pointer (use-after-free).
fn uninstallSigint() void {
    g_shutdown = null;
    var act: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
}

/// 0.16 has NO global argv accessor (`std.process.argsAlloc`/`argsFree` and a global
/// `std.process.args` do NOT exist). Argv is reachable ONLY from the `std.process.Init`
/// parameter to main (start.zig callMain dispatches on `std.process.Init.Minimal`); a
/// zero-param `pub fn main() !void` cannot obtain argv. Source EVERYTHING from `init`:
/// args, allocator, io, and (B1's env-merge needs it) the process environ.
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    // Use init.io directly: it already carries the REAL process environ, so spawned
    // children (npm/zig/the BuildRunner) inherit PATH. Building a fresh
    // `std.Io.Threaded.init(gpa, .{})` would default `environ` to `.empty`, spawning
    // children with NO environment (broken npm/zig) — do NOT construct one.
    const io = init.io;

    // toSlice yields []const [:0]const u8; dispatch wants []const []const u8. The
    // element type ([:0]const u8 -> []const u8) does not coerce through the outer
    // slice, so widen element-wise here. dispatch's signature is locked.
    const argv = try init.minimal.args.toSlice(arena);
    const args = try arena.alloc([]const u8, argv.len);
    for (argv, 0..) |a, i| args[i] = a;

    dispatch(io, gpa, args) catch |err| {
        std.debug.print("zigware: {s}\n", .{messageFor(err)});
        std.process.exit(exitCodeFor(err));
    };
}

// ─────────────────────────── tests ───────────────────────────

const testing = std.testing;

test "installSigint stores into the flag and uninstall nulls the pointer" {
    // No real signal is delivered: drive the handler logic directly by simulating the
    // store the handler would perform, then assert uninstall disarms it so a late store
    // cannot dangle.
    var flag = std.atomic.Value(bool).init(false);

    installSigint(&flag);
    try testing.expect(g_shutdown != null);

    // Stand in for the kernel-delivered SIGINT: the handler's only effect is this store.
    g_shutdown.?.store(true, .seq_cst);
    try testing.expect(flag.load(.seq_cst));

    uninstallSigint();
    try testing.expect(g_shutdown == null);
}

test "exitCodeFor gives every CliError a distinct, nonzero code and a non-empty message" {
    // Enumerate the error set reflectively so a future CliError variant cannot silently
    // collapse onto an existing exit code or skip the user-facing message contract.
    const variants = @typeInfo(CliError).error_set.?;

    // Track every code seen to assert pairwise distinctness, and assert the exact frozen
    // value per named variant so a reordering cannot quietly renumber the contract.
    var seen = [_]bool{false} ** 256;
    inline for (variants) |v| {
        const err = @field(CliError, v.name);
        const code = exitCodeFor(err);
        try testing.expect(code != 0); // 0 is reserved for success
        try testing.expect(!seen[code]); // distinct across all variants
        seen[code] = true;
        try testing.expect(messageFor(err).len > 0); // never a bare/empty message
    }

    // Freeze the exact contract values.
    try testing.expectEqual(@as(u8, 2), exitCodeFor(CliError.manifest_not_found));
    try testing.expectEqual(@as(u8, 3), exitCodeFor(CliError.manifest_invalid));
    try testing.expectEqual(@as(u8, 4), exitCodeFor(CliError.before_command_failed));
    try testing.expectEqual(@as(u8, 5), exitCodeFor(CliError.dev_url_timeout));
    try testing.expectEqual(@as(u8, 6), exitCodeFor(CliError.zig_build_failed));
    try testing.expectEqual(@as(u8, 7), exitCodeFor(CliError.frontend_dist_missing));
    try testing.expectEqual(@as(u8, 8), exitCodeFor(CliError.asset_outside_dist));
    try testing.expectEqual(@as(u8, 9), exitCodeFor(CliError.csp_conflict));
    try testing.expectEqual(@as(u8, 10), exitCodeFor(CliError.init_dir_not_empty));
    try testing.expectEqual(@as(u8, 11), exitCodeFor(CliError.bad_usage));
    try testing.expectEqual(@as(u8, 12), exitCodeFor(CliError.OutOfMemory));
}
