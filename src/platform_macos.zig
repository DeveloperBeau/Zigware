const std = @import("std");
const objc = @import("objc.zig");
const Sink = @import("sink.zig").Sink;

extern var _dispatch_main_q: anyopaque;
extern fn dispatch_async_f(queue: ?*anyopaque, context: ?*anyopaque, work: *const fn (?*anyopaque) callconv(.c) void) void;
extern fn dispatch_sync_f(queue: ?*anyopaque, context: ?*anyopaque, work: *const fn (?*anyopaque) callconv(.c) void) void;

/// Production Sink. evalJs is called from bridge worker threads; it copies the
/// JS into a heap sentinel buffer and hops to the main thread via
/// dispatch_async_f, where evaluateJavaScript is legal to call.
pub const PlatformSink = struct {
    alloc: std.mem.Allocator,
    webview: objc.id,
    alive: std.atomic.Value(bool) = .{ .raw = true },

    const Hop = struct { sink: *PlatformSink, js: [:0]u8 };

    pub fn sink(self: *PlatformSink) Sink {
        return .{ .ctx = self, .evalJs = evalJs, .isAlive = isAlive };
    }

    fn isAlive(ctx: *anyopaque) bool {
        const self: *PlatformSink = @ptrCast(@alignCast(ctx));
        return self.alive.load(.acquire);
    }

    fn evalJs(ctx: *anyopaque, js: []const u8) void {
        const self: *PlatformSink = @ptrCast(@alignCast(ctx));
        if (!self.alive.load(.acquire)) return;
        const buf = self.alloc.allocSentinel(u8, js.len, 0) catch return;
        @memcpy(buf, js);
        const hop = self.alloc.create(Hop) catch {
            self.alloc.free(buf);
            return;
        };
        hop.* = .{ .sink = self, .js = buf };
        dispatch_async_f(&_dispatch_main_q, hop, runOnMain);
    }

    fn runOnMain(ctx: ?*anyopaque) callconv(.c) void {
        const hop: *Hop = @ptrCast(@alignCast(ctx.?));
        const self = hop.sink;
        defer {
            self.alloc.free(hop.js);
            self.alloc.destroy(hop);
        }
        if (!self.alive.load(.acquire)) return;
        const nsjs = objc.nsString(hop.js.ptr);
        _ = objc.msgSend(*const fn (objc.id, objc.SEL, objc.id, objc.id) callconv(.c) objc.id)(self.webview, objc.sel("evaluateJavaScript:completionHandler:"), nsjs, null);
    }

    /// Flush any in-flight main-thread hops by enqueuing a no-op behind them and
    /// blocking until it runs. Call at shutdown after alive=false + bridge join.
    pub fn drainOnMain(self: *PlatformSink) void {
        _ = self;
        var sentinel: u8 = 0;
        dispatch_sync_f(&_dispatch_main_q, &sentinel, struct {
            fn f(_: ?*anyopaque) callconv(.c) void {}
        }.f);
    }
};
