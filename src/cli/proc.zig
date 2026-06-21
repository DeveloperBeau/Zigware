const std = @import("std");

pub const EnvPair = struct { key: []const u8, value: []const u8 };

pub const ChildSpec = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    env: []const EnvPair = &.{}, // override pairs merged onto the parent env; empty => inherit unchanged
    /// true  => child inherits the parent's stdin/stdout/stderr (the terminal).
    /// false => child is fully DETACHED: all three go to /dev/null.
    ///
    /// !!! ONLY tests may set this false. ALL non-test code — production AND dev —
    /// must keep it true. !!! `false` exists for ONE reason: the proc.zig tests
    /// spawn real children under the Zig test runner's `--listen=-` protocol,
    /// where the runner's stdin+stdout ARE the IPC pipe to `zig build`. A child
    /// inheriting that pipe deadlocks the whole test suite (the build system never
    /// sees EOF). Detaching keeps the pipe private. Nothing outside the tests runs
    /// under that protocol, so nothing else needs — or should use — false.
    ///
    /// Do NOT set this false to "quiet" a child: it SILENTLY discards the child's
    /// stdout AND stderr, so real failures vanish. If you need the child's stderr,
    /// use `capture_stderr`; to hide a noisy child, redirect at the command level
    /// instead. See SystemSpawner.spawn.
    inherit_stdio: bool = true,
    capture_stderr: bool = false, // when true, stderr is piped and returned by the BuildRunner caller
    // When true, the child is placed in its OWN process group (detached from the
    // controlling terminal's foreground group). Dev children (app, beforeDevCommand)
    // set this so an interactive Ctrl-C delivers SIGINT to the CLI only — the CLI's
    // ordered teardown is then the sole path that signals the group, preserving the
    // "kill app before dev server" ordering. Because the child leads its own group,
    // teardown MUST signal the whole GROUP (`kill(-pid, …)`), not just the leader pid:
    // `npm run dev` forks Vite/esbuild grandchildren into this same group, and a
    // leader-only signal would leak them (still holding port 5173). See B1 Step 3.
    // Generic spawns and the build verb's beforeBuildCommand leave this false.
    new_process_group: bool = false,
};

pub const Term = union(enum) { exited: u8, signal: u32, unknown };

/// Opaque handle over the std.process spawn result. Fields are owned by proc.zig.
pub const Child = struct {
    inner: std.process.Child,
    /// True when this child was spawned with `ChildSpec.new_process_group` (it is its
    /// own group leader, pgid == pid). kill() uses this to signal the whole GROUP
    /// (`kill(-pid, …)`), not just the leader pid, so forked grandchildren (e.g. Vite
    /// under `npm run dev`) are torn down too. spawn() sets it from the spec.
    group_leader: bool = false,
};

pub const Spawner = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        spawn: *const fn (*anyopaque, io: std.Io, gpa: std.mem.Allocator, ChildSpec) anyerror!Child,
        wait: *const fn (*anyopaque, io: std.Io, *Child) anyerror!Term,
        kill: *const fn (*anyopaque, io: std.Io, *Child) anyerror!void,
    };
    pub fn spawn(self: Spawner, io: std.Io, gpa: std.mem.Allocator, spec: ChildSpec) anyerror!Child {
        return self.vtable.spawn(self.ptr, io, gpa, spec);
    }
    pub fn wait(self: Spawner, io: std.Io, child: *Child) anyerror!Term {
        return self.vtable.wait(self.ptr, io, child);
    }
    pub fn kill(self: Spawner, io: std.Io, child: *Child) anyerror!void {
        return self.vtable.kill(self.ptr, io, child);
    }
};

/// Grace window between SIGTERM and the SIGKILL fallback in kill(). Wave B uses this.
pub const kill_grace_ms: u32 = 2000;

const SystemSpawner = struct {
    fn spawn(_: *anyopaque, io: std.Io, gpa: std.mem.Allocator, spec: ChildSpec) anyerror!Child {
        var opts: std.process.SpawnOptions = .{ .argv = spec.argv };

        if (spec.cwd) |c| opts.cwd = .{ .path = c };

        if (spec.inherit_stdio) {
            opts.stdin = .inherit;
            opts.stdout = .inherit;
            opts.stderr = .inherit;
        } else {
            // Explicitly DETACH the child from the parent's stdio rather than
            // leaving std's default (which is .inherit for all three).
            //
            // stdin + stdout are load-bearing: under the Zig test runner's
            // build-system protocol (`zig build <step>` / `--listen=-`), the
            // runner's stdin+stdout ARE the IPC channel to/from `zig build`. A
            // child that inherits them keeps that channel open after the tests
            // finish, so the build system never sees EOF and deadlocks (the whole
            // suite hangs); an inherited stdin could also consume protocol bytes.
            // stderr is not part of the IPC channel, but is detached too so
            // `inherit_stdio = false` means one thing: a fully headless child.
            // `capture_stderr` below is the escape hatch when a caller needs the
            // child's stderr. `.ignore` routes to /dev/null (safer than `.close`,
            // which would fault a child that writes to the stream).
            opts.stdin = .ignore;
            opts.stdout = .ignore;
            opts.stderr = .ignore;
        }
        if (spec.capture_stderr) opts.stderr = .pipe;

        // Process group: pgid = 0 places the child in a NEW group with itself as
        // leader (race-free, before exec). Leave null so the child inherits the
        // parent's group.
        if (spec.new_process_group) opts.pgid = 0;

        // Env merge. When no overrides are requested, pass environ_map = null so
        // the io's real process environ flows through to the child (the CLI sources
        // its io from std.process.Init, which carries the live environ). When
        // overrides are present, a non-null environ_map REPLACES the child env, so
        // the merged map must be seeded from the FULL parent environ first.
        if (spec.env.len == 0) {
            return .{ .inner = try std.process.spawn(io, opts), .group_leader = spec.new_process_group };
        }

        const c_environ = std.c.environ;
        var n: usize = 0;
        while (c_environ[n] != null) : (n += 1) {}
        const block: std.process.Environ.Block = .{ .slice = @ptrCast(c_environ[0..n :null]) };
        var map = try std.process.Environ.createMap(.{ .block = block }, gpa);
        defer map.deinit();
        for (spec.env) |pair| try map.put(pair.key, pair.value);

        opts.environ_map = &map;
        // The kernel copies the environ into the child by the time spawn returns,
        // so freeing the parent-side map (via defer above) after spawn is safe.
        return .{ .inner = try std.process.spawn(io, opts), .group_leader = spec.new_process_group };
    }

    fn wait(_: *anyopaque, io: std.Io, child: *Child) anyerror!Term {
        const term = try child.inner.wait(io);
        return switch (term) {
            .exited => |code| .{ .exited = code },
            .signal => |sig| .{ .signal = @intFromEnum(sig) },
            .stopped => |sig| .{ .signal = @intFromEnum(sig) },
            .unknown => .unknown,
        };
    }

    fn kill(_: *anyopaque, io: std.Io, child: *Child) anyerror!void {
        const pid = child.inner.id orelse return; // already reaped; idempotent
        const target: std.posix.pid_t = if (child.group_leader) -pid else pid;

        // Initial SIGTERM (to the whole group for a group leader). Ignore errors:
        // the child may already be gone.
        std.posix.kill(target, .TERM) catch {};

        const step_ms: u64 = 25;
        var waited_ms: u64 = 0;
        while (waited_ms < kill_grace_ms) : (waited_ms += step_ms) {
            // Cancellation rule: a Canceled sleep is a recheck, not an error.
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(@intCast(step_ms)), .awake) catch {};

            // Non-blocking reap. waitpid returns the child's pid when it has exited,
            // or 0 if it is still running. kill(pid, 0) cannot see an unreaped zombie,
            // so it is NOT a valid exit detector here.
            var status: c_int = undefined;
            const r = std.c.waitpid(pid, &status, std.posix.W.NOHANG);
            if (r == pid) {
                // Reaped at the C level: null the std id so callers (and std's own
                // asserts) see the child as gone, and SKIP the SIGKILL fallback.
                // kill targets are dev children spawned with inherit_stdio (no
                // pipes), so there are no stdio handles to close here.
                child.inner.id = null;
                return;
            }
        }

        // Grace expired with the child still alive. Send an explicit group SIGKILL
        // (so a grandchild ignoring SIGTERM still dies), then reap the leader. The
        // grandchildren are orphaned to launchd, which reaps them; the CLI reaps
        // only the leader, so no double-reap.
        std.posix.kill(target, .KILL) catch {};
        // wait reaps the leader and nulls child.inner.id itself.
        _ = child.inner.wait(io) catch {};
        child.inner.id = null;
    }

    const vtable: Spawner.VTable = .{ .spawn = spawn, .wait = wait, .kill = kill };
    var instance: u8 = 0;
};

pub fn system() Spawner {
    return .{ .ptr = &SystemSpawner.instance, .vtable = &SystemSpawner.vtable };
}

// --- inline tests (real processes, no GUI) ---

test "spawn /bin/echo exits 0" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const sp = system();

    var child = try sp.spawn(io, std.testing.allocator, .{
        .argv = &.{ "/bin/echo", "hi" },
        .inherit_stdio = false, // detach: never leak the test-runner IPC pipe to the child
    });
    const term = try sp.wait(io, &child);
    try std.testing.expectEqual(Term{ .exited = 0 }, term);
}

test "spawn /bin/sh -c exit 3 reports exit code 3" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const sp = system();

    var child = try sp.spawn(io, std.testing.allocator, .{
        .argv = &.{ "/bin/sh", "-c", "exit 3" },
        .inherit_stdio = false,
    });
    const term = try sp.wait(io, &child);
    try std.testing.expectEqual(Term{ .exited = 3 }, term);
}

test "kill terminates a sleeper within the grace window" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const sp = system();

    // New process group so kill() exercises the group-signal path.
    var child = try sp.spawn(io, std.testing.allocator, .{
        .argv = &.{ "/bin/sh", "-c", "sleep 30" },
        .new_process_group = true,
        .inherit_stdio = false,
    });

    const start = std.Io.Clock.now(.awake, io);
    try sp.kill(io, &child);
    const end = std.Io.Clock.now(.awake, io);
    const elapsed_ms: i128 = @divTrunc(@as(i128, end.nanoseconds) - @as(i128, start.nanoseconds), std.time.ns_per_ms);

    // SIGTERM should drop the sleeper well inside the grace window. Generous bound
    // to stay robust on a loaded CI host.
    try std.testing.expect(elapsed_ms < kill_grace_ms + 1000);
    // kill reaps the child; the id must be null afterward (no follow-up wait).
    try std.testing.expect(child.inner.id == null);
}

test "env-merge applies overrides and preserves inherited PATH" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const sp = system();

    // The override must apply AND the parent PATH must survive the merge. Prove
    // both through the exit code so no stdout pipe is needed (ChildSpec captures
    // only stderr, and an unread pipe could deadlock a chatty child).
    var child = try sp.spawn(io, std.testing.allocator, .{
        .argv = &.{ "/bin/sh", "-c", "[ \"$ZIGWARE_TEST\" = x ] && [ -n \"$PATH\" ]" },
        .env = &.{.{ .key = "ZIGWARE_TEST", .value = "x" }},
        .inherit_stdio = false,
    });
    const term = try sp.wait(io, &child);
    try std.testing.expectEqual(Term{ .exited = 0 }, term);
}
