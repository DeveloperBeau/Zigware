const std = @import("std");

pub fn main() !void {
    // thread_safe = true is required: worker threads in jobs.Pool will allocate
    // through this allocator (via the bridge). The default GPA is NOT thread-safe.
    // NOTE: In Zig 0.16.0, GeneralPurposeAllocator was renamed to DebugAllocator.
    var gpa = std.heap.DebugAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    _ = gpa.allocator();
    std.debug.print("zigware scaffold ok\n", .{});
}

test "scaffold compiles" {
    try std.testing.expect(true);
}
