const std = @import("std");
const sha = @import("sha256.zig");

pub fn hashGenerated(alloc: std.mem.Allocator, megabytes: usize, progress: ?sha.Progress, cancel: ?*const std.atomic.Value(bool)) !sha.HexDigest {
    const len = megabytes * 1024 * 1024;
    const buf = try alloc.alloc(u8, len);
    defer alloc.free(buf);
    for (buf, 0..) |*b, i| b.* = @truncate(i);
    return sha.hashBuffer(buf, progress, cancel);
}

test "demo hashGenerated equals a direct hashBuffer over the seeded buffer" {
    const direct = blk: {
        const buf = try std.testing.allocator.alloc(u8, 1 * 1024 * 1024);
        defer std.testing.allocator.free(buf);
        for (buf, 0..) |*b, i| b.* = @truncate(i);
        break :blk try sha.hashBuffer(buf, null, null);
    };
    const via_demo = try hashGenerated(std.testing.allocator, 1, null, null);
    try std.testing.expectEqualStrings(&direct, &via_demo);
}
