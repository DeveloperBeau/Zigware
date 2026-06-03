const std = @import("std");
const seam = @import("../platform/backend.zig");
const D = @import("../manifest/types.zig");
const WindowManager = @import("manager.zig").WindowManager;

pub fn Lifecycle(comptime B: type) type {
    return struct {
        const Self = @This();
        backend: *B,
        manager: *WindowManager(B),
        policy: D.QuitPolicy,
        reopen_handler: ?*const fn (*Self) void = null,
        terminated: bool = false,

        pub fn init(backend: *B, manager: *WindowManager(B), policy: D.QuitPolicy) Self {
            return .{ .backend = backend, .manager = manager, .policy = policy };
        }
        pub fn setReopenHandler(self: *Self, cb: *const fn (*Self) void) void {
            self.reopen_handler = cb;
        }

        /// Wired to A's onLifecycle. The seam enum type is seam.LifecycleEvent
        /// (NOT a B-associated type).
        pub fn handle(self: *Self, event: seam.LifecycleEvent) void {
            switch (event) {
                .did_launch => {},
                .window_all_closed => switch (self.policy) {
                    .quit_on_last_close => self.orderedShutdown(),
                    .keep_running_on_last_close => {},
                    .explicit => if (self.reopen_handler) |cb| cb(self),
                },
                .reopen => if (self.reopen_handler) |cb| cb(self),
                .will_terminate => self.orderedShutdown(),
            }
        }

        /// closeAll (every destroyWindow) precedes terminate. Idempotent.
        fn orderedShutdown(self: *Self) void {
            if (self.terminated) return;
            self.terminated = true;
            self.manager.closeAll();
            self.backend.terminate();
        }
        pub fn didTerminate(self: *Self) bool {
            return self.terminated;
        }
    };
}

const NullBackend = @import("../platform/null.zig").NullBackend;
const Mgr = WindowManager(NullBackend);

test "window_all_closed terminates under quit_on_last_close" {
    const be = try NullBackend.init(std.testing.allocator, std.testing.io);
    defer {
        be.markJoined();
        be.deinit();
    }
    var mgr = Mgr.init(std.testing.allocator, be, std.testing.io);
    defer mgr.deinit();
    var lc = Lifecycle(NullBackend).init(be, &mgr, .quit_on_last_close);
    lc.handle(.window_all_closed);
    try std.testing.expectEqual(@as(usize, 1), be.countEvents(.terminated));
}

test "window_all_closed stays alive under keep_running_on_last_close" {
    const be = try NullBackend.init(std.testing.allocator, std.testing.io);
    defer {
        be.markJoined();
        be.deinit();
    }
    var mgr = Mgr.init(std.testing.allocator, be, std.testing.io);
    defer mgr.deinit();
    var lc = Lifecycle(NullBackend).init(be, &mgr, .keep_running_on_last_close);
    lc.handle(.window_all_closed);
    try std.testing.expectEqual(@as(usize, 0), be.countEvents(.terminated));
}

test "will_terminate runs ordered shutdown: every destroy precedes terminate" {
    const be = try NullBackend.init(std.testing.allocator, std.testing.io);
    defer {
        be.markJoined();
        be.deinit();
    }
    var mgr = Mgr.init(std.testing.allocator, be, std.testing.io);
    defer mgr.deinit();
    _ = try mgr.create(.{ .label = "main", .url = "app://localhost/index.html" });
    _ = try mgr.create(.{ .label = "viewer", .url = "app://localhost/v" });
    var lc = Lifecycle(NullBackend).init(be, &mgr, .keep_running_on_last_close);
    lc.handle(.will_terminate);
    try std.testing.expectEqual(@as(usize, 2), be.countEvents(.destroyed));
    try std.testing.expectEqual(@as(usize, 1), be.countEvents(.terminated));
    try std.testing.expectEqual(NullBackend.Event.terminated, be.events.items[be.events.items.len - 1]);
}

test "closeAll destroys every live window and is idempotent" {
    const be = try NullBackend.init(std.testing.allocator, std.testing.io);
    defer {
        be.markJoined();
        be.deinit();
    }
    var mgr = Mgr.init(std.testing.allocator, be, std.testing.io);
    defer mgr.deinit();
    _ = try mgr.create(.{ .label = "main", .url = "app://localhost/index.html" });
    _ = try mgr.create(.{ .label = "viewer", .url = "app://localhost/v" });
    _ = try mgr.create(.{ .label = "panel", .url = "app://localhost/p" });
    try std.testing.expectEqual(@as(usize, 3), mgr.liveCount());
    mgr.closeAll();
    try std.testing.expectEqual(@as(usize, 0), mgr.liveCount());
    try std.testing.expectEqual(@as(usize, 3), be.countEvents(.destroyed));
    mgr.closeAll(); // idempotent: no live windows, no extra destroys
    try std.testing.expectEqual(@as(usize, 3), be.countEvents(.destroyed));
}
