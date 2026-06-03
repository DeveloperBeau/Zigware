const std = @import("std");

pub const EnvPair = struct { key: []const u8, value: []const u8 };

pub const ChildSpec = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    env: []const EnvPair = &.{}, // override pairs merged onto the parent env; empty => inherit unchanged
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
    fn spawn(_: *anyopaque, _: std.Io, _: std.mem.Allocator, _: ChildSpec) anyerror!Child {
        return error.NotImplemented;
    }
    fn wait(_: *anyopaque, _: std.Io, _: *Child) anyerror!Term {
        return error.NotImplemented;
    }
    fn kill(_: *anyopaque, _: std.Io, _: *Child) anyerror!void {
        return error.NotImplemented;
    }
    const vtable: Spawner.VTable = .{ .spawn = spawn, .wait = wait, .kill = kill };
    var instance: u8 = 0;
};

pub fn system() Spawner {
    return .{ .ptr = &SystemSpawner.instance, .vtable = &SystemSpawner.vtable };
}
