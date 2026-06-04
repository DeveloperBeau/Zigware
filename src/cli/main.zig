const std = @import("std");

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

/// Maps argv[1] to a verb and dispatches. Verb bodies arrive in Wave C.
pub fn dispatch(io: std.Io, gpa: std.mem.Allocator, args: []const []const u8) CliError!void {
    _ = io;
    _ = gpa;
    if (args.len < 2) return printHelp();
    const cmd = parseCmd(args[1]) orelse return CliError.bad_usage;
    switch (cmd) {
        .help => return printHelp(),
        .version => return printVersion(),
        .init, .dev, .build => return CliError.bad_usage, // Wave C wires these
    }
}

fn printHelp() CliError!void {
    // Wave C replaces stderr writes with the real Io writer; a bare std.debug.print is fine for the skeleton.
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

// ─────────────────────────── cooperative SIGINT shutdown ───────────────────────────
//
// The SIGINT handler runs with no userdata and a fixed C signature, so the shutdown
// flag it must flip is reached through a file-scope pointer the install routine stores.
// The dev dispatch (wired later) constructs the flag on its stack, installs the handler
// pointed at it, and `defer`s uninstall so the handler is disarmed and `g_shutdown`
// nulled before the flag leaves scope — a late SIGINT after the dev frame unwinds then
// finds a null pointer instead of storing through freed stack.

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
        std.debug.print("zigware: {s}\n", .{@errorName(err)});
        std.process.exit(1);
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
