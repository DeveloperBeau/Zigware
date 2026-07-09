const std = @import("std");

pub const MAX_PATH: usize = 4096;

pub const PathResult = union(enum) {
    ok: []const u8, // slice into the input, NUL-free, 1..=MAX_PATH bytes
    empty, // -> caller fails the task with 400
    too_long, // -> caller fails the task with 414
};

/// Extract a bounded path from a readable byte slice. Never reads past `buf`.
/// The caller passes a real slice (e.g. `std.mem.sliceTo(pathC, 0)`), never a
/// fixed-width window over a many-pointer (finding H2). The scan stops at the
/// first NUL or at MAX_PATH, whichever comes first.
pub fn extractPath(buf: []const u8) PathResult {
    const len = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    if (len == 0) return .empty;
    if (len >= MAX_PATH) return .too_long;
    return .{ .ok = buf[0..len] };
}

test "extractPath: normal path" {
    const r = extractPath("/index.html\x00garbage");
    try std.testing.expectEqualStrings("/index.html", r.ok);
}

test "extractPath: NUL at index 0 is empty" {
    try std.testing.expect(extractPath("\x00rest") == .empty);
    try std.testing.expect(extractPath(&[_]u8{}) == .empty);
}

test "extractPath: length MAX_PATH-1 is ok" {
    var buf: [MAX_PATH]u8 = undefined;
    @memset(buf[0 .. MAX_PATH - 1], 'a');
    buf[MAX_PATH - 1] = 0;
    const r = extractPath(&buf);
    try std.testing.expectEqual(@as(usize, MAX_PATH - 1), r.ok.len);
}

test "extractPath: length == MAX_PATH (no NUL in window) is too_long" {
    var buf: [MAX_PATH]u8 = undefined;
    @memset(&buf, 'a'); // no NUL anywhere in the readable window
    try std.testing.expect(extractPath(&buf) == .too_long);
}
