const std = @import("std");

/// Single choke point for Zig->JS emission. Production impl hops to the main thread
/// via dispatch_async_f + evaluateJavaScript. TestSink/AliveSink record/control.
pub const Sink = struct {
    ctx: *anyopaque,
    evalJs: *const fn (ctx: *anyopaque, js: []const u8) void,
    isAlive: *const fn (ctx: *anyopaque) bool,
};
