const std = @import("std");
const seam = @import("../backend.zig");

/// Minimal stub landed in Task 6 so main.zig compiles; Task 7 fills in the
/// objc wiring. Every method satisfies the contract shape; the bodies are
/// replaced incrementally. Do NOT ship this stub: Task 7 must complete before
/// the GUI works. The comptime assertBackend below guards the shape.
pub const MacOSBackend = struct {
    pub const WindowHandle = struct { window: seam_id, webview: seam_id };
    pub const WindowId = u64;
    const seam_id = ?*anyopaque;

    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) !*MacOSBackend {
        const self = try alloc.create(MacOSBackend);
        self.* = .{ .alloc = alloc };
        return self;
    }
    pub fn deinit(self: *MacOSBackend) void {
        self.alloc.destroy(self);
    }
    pub fn createWindow(_: *MacOSBackend, _: seam.WindowOpts) seam.CreateWindowError!WindowHandle {
        // Panic rather than fake an OOM: a loud crash on this unreachable-in-prod
        // path is more honest than silently shipping a degraded app. Task 7 fills
        // this in. Do NOT ship this stub.
        @panic("MacOSBackend.createWindow: stub, implemented in Task 7");
    }
    pub fn destroyWindow(_: *MacOSBackend, _: WindowHandle) void {}
    pub fn setTitle(_: *MacOSBackend, _: WindowHandle, _: [:0]const u8) seam.SetTitleError!void {}
    pub fn setSize(_: *MacOSBackend, _: WindowHandle, _: f64, _: f64) void {}
    pub fn setFullscreen(_: *MacOSBackend, _: WindowHandle, _: bool) void {}
    pub fn showWindow(_: *MacOSBackend, _: WindowHandle) void {}
    pub fn focusWindow(_: *MacOSBackend, _: WindowHandle) void {}
    pub fn evalJS(_: *MacOSBackend, _: WindowHandle, _: []const u8) void {}
    pub fn injectUserScript(_: *MacOSBackend, _: WindowHandle, _: []const u8) seam.InjectScriptError!void {}
    pub fn windowId(_: *MacOSBackend, _: WindowHandle) WindowId {
        return std.math.maxInt(u64);
    }
    pub fn dispatchMain(_: *MacOSBackend, _: *const fn (?*anyopaque) callconv(.c) void, _: ?*anyopaque) void {}
    pub fn pumpMain(_: *MacOSBackend) void {}
    pub fn run(_: *MacOSBackend) void {}
    pub fn terminate(_: *MacOSBackend) void {}
    pub fn nativeWindow(_: *MacOSBackend, h: WindowHandle) ?*anyopaque {
        return h.window;
    }
    pub fn setCallbacks(_: *MacOSBackend, _: seam.Callbacks) void {}
    pub fn markJoined(_: *MacOSBackend) void {} // no-op: AppKit joins via the runloop; no joined assert
};

comptime {
    seam.assertBackend(MacOSBackend);
}
