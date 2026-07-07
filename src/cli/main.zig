const std = @import("std");
const builtin = @import("builtin");

const proc = @import("proc.zig");
const watch = @import("watch.zig");
const devserver = @import("devserver.zig");
const dev = @import("dev.zig");
const build_verb = @import("build.zig");
const init_verb = @import("init.zig");
const package = @import("package");

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
    package_failed,
    OutOfMemory,
};

pub const Cmd = enum { init, dev, build, help, version };

fn parseCmd(s: []const u8) ?Cmd {
    return std.meta.stringToEnum(Cmd, s);
}

/// Maps argv[1] to a verb and dispatches.
pub fn dispatch(io: std.Io, gpa: std.mem.Allocator, args: []const []const u8, framework_env: ?[]const u8) CliError!void {
    if (args.len < 2) return printHelp();
    const cmd = parseCmd(args[1]) orelse return CliError.bad_usage;
    switch (cmd) {
        .help => return printHelp(),
        .version => return printVersion(),
        .init => return runInit(io, gpa, args[2..], framework_env),
        .dev => return runDev(io, gpa),
        .build => return runBuild(io, gpa, args[2..]),
    }
}

fn printHelp() CliError!void {
    std.debug.print(
        \\zigware <command>
        \\  init <dir>    scaffold a new project
        \\  dev           run the dev loop
        \\  build [--arch <arm64|x86_64|universal>] [--sign] [--notarize]
        \\                produce a release binary + macOS .app/.dmg (host arch and
        \\                unsigned by default; --arch selects the target, --sign/
        \\                --notarize use your own Apple credentials)
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
fn runInit(io: std.Io, gpa: std.mem.Allocator, rest: []const []const u8, framework_env: ?[]const u8) CliError!void {
    var dir: ?[]const u8 = null;
    var template: init_verb.Template = .vanilla;
    var force = false;
    var name: ?[]const u8 = null;
    var framework_path: ?[]const u8 = null;

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
        } else if (std.mem.eql(u8, a, "--framework-path")) {
            i += 1;
            if (i >= rest.len) return CliError.bad_usage;
            framework_path = rest[i];
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

    // Pre-release: the scaffold declares the framework as a path dependency. The
    // path comes from --framework-path or the ZIGWARE_FRAMEWORK_PATH env var.
    const fw_raw = framework_path orelse framework_env orelse {
        std.debug.print(
            "zigware init: the framework path is required.\n  pass --framework-path <path-to-zigware-checkout> or set ZIGWARE_FRAMEWORK_PATH\n",
            .{},
        );
        return CliError.bad_usage;
    };
    // Resolve to an absolute path so init can compute the scaffold-relative dep path.
    var fw_dir = std.Io.Dir.cwd().openDir(io, fw_raw, .{}) catch {
        std.debug.print("zigware init: framework path not found: {s}\n", .{fw_raw});
        return CliError.bad_usage;
    };
    defer fw_dir.close(io);
    var fw_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const fw_n = fw_dir.realPath(io, &fw_buf) catch return CliError.bad_usage;
    const fw_abs = fw_buf[0..fw_n];

    init_verb.run(io, gpa, .{
        .dir = target_dir,
        .name = project_name,
        .template = template,
        .force = force,
        .framework_path = fw_abs,
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

const Arch = enum { host, arm64, x86_64, universal };
const BuildFlags = struct { skip_sign: bool, skip_notarize: bool, arch: Arch, target: ?[]const u8 };

/// The Zig target triple for a single-arch selection; null for host and for
/// universal (universal is compiled as two single-arch slices in Task 4).
fn archTriple(arch: Arch) ?[]const u8 {
    return switch (arch) {
        .host, .universal => null,
        .arm64 => "aarch64-macos",
        .x86_64 => "x86_64-macos",
    };
}

/// Parse the `build` verb flags. Default is UNSIGNED (both skips true): the base
/// case needs no Apple credentials. `--sign` opts into signing; `--notarize`
/// opts into notarization and implies signing (an unsigned bundle cannot be
/// notarized). `--arch` selects the target architecture (arm64/x86_64/universal);
/// default is host. `--arch universal` compiles both slices and lipos them.
fn parseBuildFlags(rest: []const []const u8) CliError!BuildFlags {
    var sign = false;
    var notarize = false;
    var arch: Arch = .host;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (std.mem.eql(u8, a, "--sign")) {
            sign = true;
        } else if (std.mem.eql(u8, a, "--notarize")) {
            notarize = true;
            sign = true; // notarization requires a signed bundle
        } else if (std.mem.eql(u8, a, "--arch")) {
            i += 1;
            if (i >= rest.len) return CliError.bad_usage;
            // `universal` compiles both slices and lipos them; arm64/x86_64 each
            // compile a single cross target. Anything else is a usage error.
            arch = if (std.mem.eql(u8, rest[i], "arm64")) .arm64 else if (std.mem.eql(u8, rest[i], "x86_64")) .x86_64 else if (std.mem.eql(u8, rest[i], "universal")) .universal else return CliError.bad_usage;
        } else {
            return CliError.bad_usage;
        }
    }
    return .{ .skip_sign = !sign, .skip_notarize = !notarize, .arch = arch, .target = archTriple(arch) };
}

/// `zigware build`: read the project manifest (validated under .ReleaseSafe, the shipped
/// release mode), then run the build orchestrator. No SIGINT install. Build has no
/// long-lived child loop to interrupt.
fn runBuild(io: std.Io, gpa: std.mem.Allocator, rest: []const []const u8) CliError!void {
    const flags = try parseBuildFlags(rest);

    const manifest = readManifest(io, gpa, .ReleaseSafe) catch |err| return mapVerbError(err);
    var m = manifest;
    defer parse.freeManifest(gpa, m);

    // Default is an UNSIGNED bundle (no credentials required): tell the developer
    // it is local-only and how to sign. Signing/notarization opt-in paths surface
    // their own credential errors from config.zig when a developer supplies none.
    if (flags.skip_sign) {
        std.debug.print(
            "zigware build: producing an UNSIGNED bundle (local use). To sign, pass --sign (and --notarize) and supply your signing identity via APPLE_SIGNING_IDENTITY or the manifest, plus notary credentials via the APPLE_* env vars.\n",
            .{},
        );
    }

    var build_runner = SystemBuildRunner{};
    var pkg_runner = package.SystemRunner{};
    var runner = pkg_runner.runner();
    return runBuildInner(io, gpa, &m, build_runner.make(), proc.system(), &runner, "zig-out", flags.skip_sign, flags.skip_notarize, flags.arch);
}

/// Map the CLI-level `Arch` to the packaging module's `Arch` so `Artifacts.arch`
/// records what was actually built. The two enums are deliberately kept separate
/// (one owns the `-Dtarget` triple mapping, the other the packaging record).
fn packagerArch(arch: Arch) package.Arch {
    return switch (arch) {
        .host => .host,
        .arm64 => .arm64,
        .x86_64 => .x86_64,
        .universal => .universal,
    };
}

/// The headless-testable build core: compile the release binary, then hand it to the
/// packaging pipeline. The compile seams (`builder`/`proc`) and the packaging child-process
/// `runner` are all injected by pointer/value so the integration tests drive the whole verb
/// over fakes (mirroring how `build_verb.run` takes `builder`/`proc`). On a packaging
/// failure the populated `*Diagnostic` is rendered through `printPackageDiagnostic` and the
/// error collapses to `package_failed`. It is not routed through `mapVerbError` (whose `else`
/// arm would mislabel the named G errors as `internal error`/`bad_usage` and double-print).
fn runBuildInner(
    io: std.Io,
    gpa: std.mem.Allocator,
    manifest: *const parse.Manifest,
    builder: dev.BuildRunner,
    proc_spawner: proc.Spawner,
    runner: *package.Runner,
    out_dir: []const u8,
    skip_sign: bool,
    skip_notarize: bool,
    arch: Arch,
) CliError!void {
    if (arch == .universal) {
        // A universal bundle is two single-arch compiles combined by lipo. Compile the
        // arm64 slice first. `build_verb.run` ALWAYS returns `zig-out/bin/<productName>`
        // regardless of target (build.zig:158), so the x86_64 compile below OVERWRITES
        // this binary in place; copy the arm64 result to a distinct path first.
        const first_bin = build_verb.run(io, gpa, .{
            .manifest = manifest,
            .optimize = .ReleaseSafe,
            .out_dir = out_dir,
            .builder = builder,
            .proc = proc_spawner,
            .target = "aarch64-macos",
        }) catch |err| return mapVerbError(err);
        defer gpa.free(first_bin);

        const arm_bin = try std.fmt.allocPrint(gpa, "{s}-arm64", .{first_bin});
        defer gpa.free(arm_bin);
        std.Io.Dir.cwd().copyFile(first_bin, std.Io.Dir.cwd(), arm_bin, io, .{}) catch {
            std.debug.print("zigware: failed to stage the arm64 slice for the universal build\n", .{});
            return CliError.package_failed;
        };
        defer std.Io.Dir.cwd().deleteFile(io, arm_bin) catch {}; // temp slice cleanup

        // Compile the x86_64 slice into the (now free to overwrite) canonical path. The
        // double compile repeats the arch-independent frontend build + asset staging; it
        // is idempotent (same asset table both times), so v0.1 accepts the extra time.
        const x86_bin = build_verb.run(io, gpa, .{
            .manifest = manifest,
            .optimize = .ReleaseSafe,
            .out_dir = out_dir,
            .builder = builder,
            .proc = proc_spawner,
            .target = "x86_64-macos",
        }) catch |err| return mapVerbError(err);
        defer gpa.free(x86_bin);

        return packageBundle(io, gpa, manifest, out_dir, runner, skip_sign, skip_notarize, &.{ arm_bin, x86_bin }, .universal);
    }

    // Single-arch (host/arm64/x86_64): one compile, one binary.
    const binary_path = build_verb.run(io, gpa, .{
        .manifest = manifest,
        .optimize = .ReleaseSafe,
        .out_dir = out_dir,
        .builder = builder,
        .proc = proc_spawner,
        .target = archTriple(arch),
    }) catch |err| return mapVerbError(err);
    defer gpa.free(binary_path);

    return packageBundle(io, gpa, manifest, out_dir, runner, skip_sign, skip_notarize, &.{binary_path}, packagerArch(arch));
}

/// Hand the compiled binary/binaries to the packaging pipeline and render the result.
/// On a packaging failure the populated `*Diagnostic` is rendered through
/// `printPackageDiagnostic` and the error collapses to `package_failed`. It is not
/// routed through `mapVerbError` (whose `else` arm would mislabel the named G errors
/// as `internal error`/`bad_usage` and double-print).
fn packageBundle(
    io: std.Io,
    gpa: std.mem.Allocator,
    manifest: *const parse.Manifest,
    out_dir: []const u8,
    runner: *package.Runner,
    skip_sign: bool,
    skip_notarize: bool,
    binaries: []const []const u8,
    arch: package.Arch,
) CliError!void {
    var diag: ?package.Diagnostic = null;
    const arts = package.package(io, .{
        .gpa = gpa,
        .binaries = binaries,
        .config = package.configFromManifest(manifest),
        .out_dir = out_dir,
        .runner = runner,
        .skip_sign = skip_sign,
        .skip_notarize = skip_notarize,
        .arch = arch,
        .diag = &diag,
    }) catch {
        // A typed PackageError. Most stages populate `*diag` before returning, but a few
        // runtime/OOM paths (a runner spawn failure inside assessStapled, an env-read or
        // mid-fill OOM) return without writing one, so render defensively: the diagnostic
        // when present (freeing its gpa-owned `detail`), else a generic line.
        if (diag) |d| {
            printPackageDiagnostic(&d);
            gpa.free(d.detail);
        } else {
            std.debug.print("zigware: packaging failed\n", .{});
        }
        return CliError.package_failed;
    };
    defer arts.deinit(gpa);

    std.debug.print("built {s} ({s}) -> {s}\n", .{ arts.app_name, arts.version, arts.binary_path });
}

/// Render G's structured packaging `Diagnostic` to stderr. This is a SEPARATE path from
/// `printDiagnostics` (which takes `*const parse.Diagnostics`, the structurally different
/// manifest-parse type and cannot render this one). `detail` is the captured tool output
/// or formatted notary-log issue list; it is printed verbatim and freed by the caller.
fn printPackageDiagnostic(d: *const package.Diagnostic) void {
    std.debug.print("zigware: packaging error: {s}\n", .{d.title});
    if (d.detail.len > 0) std.debug.print("  {s}\n", .{d.detail});
    std.debug.print("  {s}\n", .{d.remediation});
}

// ─────────────────────────── manifest read ───────────────────────────

/// Read the END-USER's zigware.zon from the process cwd (the scaffolded project root) via
/// D's disk reader. The returned Manifest is allocator-OWNED and must be freed with
/// freeManifest. This is NOT parse.embedded() (which would return Zigware's OWN baked-in
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
/// reaps the child itself with no separate kill/wait needed). It maps the run result's term to
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
        // A staged asset table (prod packaging) is wired via `-Dasset_table`.
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, &.{ "zig", "build" });
        if (spec.optimize != .Debug) try argv.append(gpa, "-Drelease=true");
        var at_buf: []u8 = &.{};
        defer if (at_buf.len > 0) gpa.free(at_buf);
        if (spec.asset_table) |at| {
            at_buf = try std.fmt.allocPrint(gpa, "-Dasset_table={s}", .{at});
            try argv.append(gpa, at_buf);
        }
        var tgt_buf: []u8 = &.{};
        defer if (tgt_buf.len > 0) gpa.free(tgt_buf);
        if (spec.target) |t| {
            tgt_buf = try std.fmt.allocPrint(gpa, "-Dtarget={s}", .{t});
            try argv.append(gpa, tgt_buf);
        }

        const result = try std.process.run(gpa, io, .{ .argv = argv.items });
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
        CliError.package_failed => 13,
    };
}

/// A human-readable stderr line for each CliError; never a bare "command failed". The
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
        CliError.package_failed => "packaging failed (see the diagnostic above)",
    };
}

// ─────────────────────────── cooperative SIGINT shutdown ───────────────────────────
//
// The SIGINT handler runs with no userdata and a fixed C signature, so the shutdown
// flag it must flip is reached through a file-scope pointer the install routine stores.
// The dev dispatch constructs the flag on its stack, installs the handler pointed at it,
// and `defer`s uninstall so the handler is disarmed and `g_shutdown` nulled before the
// flag leaves scope. A late SIGINT after the dev frame unwinds then finds a null pointer
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
    // children with NO environment (broken npm/zig). Do NOT construct one.
    const io = init.io;

    // toSlice yields []const [:0]const u8; dispatch wants []const []const u8. The
    // element type ([:0]const u8 -> []const u8) does not coerce through the outer
    // slice, so widen element-wise here. dispatch's signature is locked.
    const argv = try init.minimal.args.toSlice(arena);
    const args = try arena.alloc([]const u8, argv.len);
    for (argv, 0..) |a, i| args[i] = a;

    // ZIGWARE_FRAMEWORK_PATH fallback for `init --framework-path` (pre-release dep).
    const framework_env = init.environ_map.array_hash_map.get("ZIGWARE_FRAMEWORK_PATH");

    dispatch(io, gpa, args, framework_env) catch |err| {
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
    try testing.expectEqual(@as(u8, 13), exitCodeFor(CliError.package_failed));
}

// ─────────────────────────── build verb + package() integration ───────────────────────────

/// Minimal BuildRunner fake for the build-verb integration tests: returns a canned ok
/// result with an owned (empty) stderr so build.run's `defer gpa.free(result.stderr)`
/// exercises real allocator bookkeeping without driving a real `zig build`.
const StubBuilder = struct {
    fn make(self: *StubBuilder) dev.BuildRunner {
        return .{ .ptr = self, .vtable = &vtable };
    }
    const vtable: dev.BuildRunner.VTable = .{ .build = build };
    fn build(_: *anyopaque, _: std.Io, gpa: std.mem.Allocator, _: dev.BuildSpec) anyerror!dev.BuildResult {
        return .{ .ok = true, .stderr = try gpa.alloc(u8, 0) };
    }
};

/// Minimal Spawner fake. The integration manifests declare no frontend.build command, so it
/// is never spawned; it exists only to satisfy build.run's `proc` seam.
const StubSpawner = struct {
    fn make(self: *StubSpawner) proc.Spawner {
        return .{ .ptr = self, .vtable = &vtable };
    }
    const vtable: proc.Spawner.VTable = .{ .spawn = spawn, .wait = wait, .kill = kill };
    fn spawn(_: *anyopaque, _: std.Io, _: std.mem.Allocator, _: proc.ChildSpec) anyerror!proc.Child {
        var inner: std.process.Child = undefined;
        inner.id = 1;
        return .{ .inner = inner };
    }
    fn wait(_: *anyopaque, _: std.Io, _: *proc.Child) anyerror!proc.Term {
        return .{ .exited = 0 };
    }
    fn kill(_: *anyopaque, _: std.Io, _: *proc.Child) anyerror!void {}
};

fn buildTestManifest() parse.Manifest {
    return .{ .identifier = "com.example.app", .productName = "Example", .version = "0.1.0" };
}

/// Write a `dist/index.html` fixture under `dir` for the build-verb compile stage.
fn writeDistFixture(io: std.Io, dir: std.Io.Dir) !void {
    try dir.createDirPath(io, "dist");
    try dir.writeFile(io, .{ .sub_path = "dist/index.html", .data = "<html><head></head><body></body></html>" });
}

fn absUnder(io: std.Io, dir: std.Io.Dir, buf: []u8, sub: []const u8) ![]const u8 {
    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try dir.realPath(io, &base_buf)];
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ base, sub });
}

/// build.run returns the cwd-relative release path `zig-out/bin/<productName>`; the real
/// `zig build` emits there, decoupled from the CSP out_dir. The StubBuilder fakes the
/// compile without producing that file, so the packaging stage's binary copy would fail.
/// Stage a dummy executable at the exact returned path (mirrors the package-pipeline
/// fixture) so assembleBundle has a real source to copy. Tests run sequentially, so the
/// shared "Example" name is safe with the defer-cleanup the caller installs; it does not
/// collide with the real `zig-out/bin/zigware`.
const staged_binary_rel = "zig-out/bin/Example";
fn stageDummyBinary(io: std.Io) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, "zig-out/bin");
    try cwd.writeFile(io, .{ .sub_path = staged_binary_rel, .data = "#!/bin/sh\necho hi\n" });
}

fn unstageDummyBinary(io: std.Io) void {
    std.Io.Dir.cwd().deleteFile(io, staged_binary_rel) catch {};
}

test "runBuildInner surfaces a packaging failure through printPackageDiagnostic and returns package_failed" {
    const io = testing.io;
    const gpa = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeDistFixture(io, tmp.dir);
    try tmp.dir.createDirPath(io, "out");
    // build.run returns zig-out/bin/Example; stage a real source so the sign stage is
    // reached (an absent binary would fail the bundle copy before codesign ever runs).
    try stageDummyBinary(io);
    defer unstageDummyBinary(io);

    var dist_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var out_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dist = try absUnder(io, tmp.dir, &dist_buf, "dist");
    const out = try absUnder(io, tmp.dir, &out_buf, "out");

    var builder = StubBuilder{};
    var spawner = StubSpawner{};
    var manifest = buildTestManifest();
    manifest.frontend.outDir = dist;
    // A signing identity is configured so the sign stage runs and the scripted codesign
    // failure (below) classifies a real packaging Diagnostic.
    manifest.bundle.macos.signingIdentity = "Developer ID Application: Acme (TEAMID)";

    // FakeRunner scripts a first-call codesign failure: the package pipeline aborts at
    // sign() with IdentityNotFound, which runBuildInner collapses to package_failed.
    var fr = package.FakeRunnerForTest.init(gpa);
    defer fr.deinit();
    try fr.push(.{ .term = .{ .exited = 1 }, .stdout = "", .stderr = "no identity found" });
    var runner = fr.runner();

    // skip_notarize so the notary-credential preflight (env-only, empty in the test
    // environment) does not abort before sign(); signing still runs because skip_sign is
    // false and an identity is configured. Without this the test would short-circuit at
    // the notary preflight and the scripted codesign result would never be consumed.
    try testing.expectError(CliError.package_failed, runBuildInner(io, gpa, &manifest, builder.make(), spawner.make(), &runner, out, false, true, .host));

    // Prove the failure came from the SCRIPTED codesign call, not an earlier preflight:
    // the runner recorded exactly the one codesign invocation before sign() aborted.
    try testing.expectEqual(@as(usize, 1), fr.argv_log.items.len);
    try testing.expectEqualStrings("codesign", fr.argv_log.items[0][0]);
}

test "parseBuildFlags: default is unsigned (both skips true)" {
    const f = try parseBuildFlags(&.{});
    try std.testing.expect(f.skip_sign);
    try std.testing.expect(f.skip_notarize);
}

test "parseBuildFlags: --sign enables signing only" {
    const f = try parseBuildFlags(&.{"--sign"});
    try std.testing.expect(!f.skip_sign);
    try std.testing.expect(f.skip_notarize);
}

test "parseBuildFlags: --notarize implies signing" {
    const f = try parseBuildFlags(&.{"--notarize"});
    try std.testing.expect(!f.skip_sign); // cannot notarize an unsigned bundle
    try std.testing.expect(!f.skip_notarize);
}

test "parseBuildFlags: unknown flag is bad_usage" {
    try std.testing.expectError(CliError.bad_usage, parseBuildFlags(&.{"--nope"}));
}

test "parseBuildFlags: default arch is host (no target triple)" {
    const f = try parseBuildFlags(&.{});
    try std.testing.expect(f.target == null);
}

test "parseBuildFlags: --arch arm64 selects the aarch64-macos triple" {
    const f = try parseBuildFlags(&.{ "--arch", "arm64" });
    try std.testing.expectEqualStrings("aarch64-macos", f.target.?);
}

test "parseBuildFlags: --arch x86_64 selects the x86_64-macos triple" {
    const f = try parseBuildFlags(&.{ "--arch", "x86_64" });
    try std.testing.expectEqualStrings("x86_64-macos", f.target.?);
}

test "parseBuildFlags: --arch with no value or unknown value is bad_usage" {
    try std.testing.expectError(CliError.bad_usage, parseBuildFlags(&.{"--arch"}));
    try std.testing.expectError(CliError.bad_usage, parseBuildFlags(&.{ "--arch", "sparc" }));
}

test "parseBuildFlags: --arch universal sets arch universal with no target triple" {
    const f = try parseBuildFlags(&.{ "--arch", "universal" });
    try std.testing.expectEqual(Arch.universal, f.arch);
    try std.testing.expect(f.target == null); // universal compiles two slices, not one -Dtarget
}

test "runBuildInner skip_sign assembles the bundle without signing (hdiutil only)" {
    const io = testing.io;
    const gpa = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeDistFixture(io, tmp.dir);
    try tmp.dir.createDirPath(io, "out");
    // build.run returns zig-out/bin/Example; stage a real source so assembleBundle can
    // copy it into Contents/MacOS before the dmg is built.
    try stageDummyBinary(io);
    defer unstageDummyBinary(io);

    var dist_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var out_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dist = try absUnder(io, tmp.dir, &dist_buf, "dist");
    const out = try absUnder(io, tmp.dir, &out_buf, "out");

    var builder = StubBuilder{};
    var spawner = StubSpawner{};
    var manifest = buildTestManifest();
    manifest.frontend.outDir = dist;

    // skip_sign + skip_notarize: the package pipeline assembles the .app and builds an
    // unsigned dmg, so only the single hdiutil call reaches the runner.
    var fr = package.FakeRunnerForTest.init(gpa);
    defer fr.deinit();
    try fr.push(.{ .term = .{ .exited = 0 }, .stdout = "", .stderr = "" }); // hdiutil
    var runner = fr.runner();

    try runBuildInner(io, gpa, &manifest, builder.make(), spawner.make(), &runner, out, true, true, .host);

    const log = fr.argv_log.items;
    try testing.expectEqual(@as(usize, 1), log.len);
    try testing.expectEqualStrings("hdiutil", log[0][0]);
}
