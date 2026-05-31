const std = @import("std");
const app = @import("app.zig");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // The threaded Io backs the bridge's worker pool. It must outlive the run
    // loop; app.run blocks until the app terminates, so this frame stays alive.
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    try app.run(alloc, io);
}
