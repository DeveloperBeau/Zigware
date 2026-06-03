const std = @import("std");
const proc = @import("proc.zig");
const watch = @import("watch.zig");
const Manifest = @import("zigware_manifest").Manifest;

pub const BuildSpec = struct { optimize: std.builtin.OptimizeMode, dev: bool };
pub const BuildResult = struct { ok: bool, stderr: []u8 }; // stderr owned by caller (gpa)

pub const BuildRunner = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        build: *const fn (*anyopaque, io: std.Io, gpa: std.mem.Allocator, BuildSpec) anyerror!BuildResult,
    };
    pub fn build(self: BuildRunner, io: std.Io, gpa: std.mem.Allocator, spec: BuildSpec) anyerror!BuildResult {
        return self.vtable.build(self.ptr, io, gpa, spec);
    }
};

pub const ReloadOutcome = enum { reloaded, build_failed, no_change };

/// Injectable dev-server probe seam so C1 can drive a fake that times out without a live
/// server. `waitForUrl` is otherwise a concrete free function (devserver.zig) with no seam,
/// leaving the startup-timeout teardown path untestable. Production wires
/// `devserver.waitForUrl`; tests wire a fake returning error.dev_url_timeout.
pub const UrlProbe = *const fn (io: std.Io, gpa: std.mem.Allocator, url: []const u8, shutdown: *std.atomic.Value(bool)) anyerror!void;

pub const DevContext = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    manifest: *const Manifest,
    proc: proc.Spawner,
    watcher: watch.Watcher,
    builder: BuildRunner,
    wait_for_url: UrlProbe, // production: a thin wrapper over devserver.waitForUrl; tests: a fake
    shutdown: *std.atomic.Value(bool),
};

/// Full dev loop until shutdown is set. Reaps all children on every exit path. Bodies land in Wave C.
pub fn run(ctx: *DevContext) anyerror!void {
    _ = ctx;
    return error.NotImplemented;
}

/// One reload cycle, exposed for headless testing.
pub fn rebuildAndReload(ctx: *DevContext, changed: []const watch.ChangedPath) anyerror!ReloadOutcome {
    _ = ctx;
    _ = changed;
    return error.NotImplemented;
}
