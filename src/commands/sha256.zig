const std = @import("std");
const compute = @import("../compute.zig");

pub const Progress = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, pct: u8) void,
    fn report(self: Progress, pct: u8) void {
        self.func(self.ctx, pct);
    }
};

pub const HexDigest = [64]u8;

/// Hash `data` in 64KB chunks. Reports integer-percent progress and observes the
/// cancel token (own OR shutdown) between chunks. Pure — no allocator.
pub fn hashBuffer(data: []const u8, progress: ?Progress, cancel: compute.CancelToken) !HexDigest {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    const chunk: usize = 64 * 1024;
    var done: usize = 0;
    var last_pct: u8 = 255;
    while (done < data.len) {
        if (cancel.isCancelled()) return error.Cancelled;
        const end = @min(done + chunk, data.len);
        h.update(data[done..end]);
        done = end;
        if (progress) |p| {
            const pct: u8 = @intCast((done * 100) / @max(data.len, 1));
            if (pct != last_pct) {
                p.report(pct);
                last_pct = pct;
            }
        }
    }
    if (data.len == 0) if (progress) |p| p.report(100);
    var raw: [32]u8 = undefined;
    h.final(&raw);
    return std.fmt.bytesToHex(raw, .lower);
}

test "matches known SHA-256 vectors" {
    const empty = try hashBuffer("", null, compute.CancelToken.never());
    try std.testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        &empty,
    );
    const abc = try hashBuffer("abc", null, compute.CancelToken.never());
    try std.testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        &abc,
    );
}

test "chunked equals one-shot and reports monotonic progress" {
    const data = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(data);
    for (data, 0..) |*b, i| b.* = @truncate(i);

    var cap = ProgressCapture{};
    const chunked = try hashBuffer(data, cap.cb(), compute.CancelToken.never());
    const oneshot = try hashBuffer(data, null, compute.CancelToken.never());
    try std.testing.expectEqualStrings(&oneshot, &chunked);
    try std.testing.expect(cap.last == 100);
    try std.testing.expect(cap.calls > 1);
}

test "honours cancel flag between chunks" {
    const data = try std.testing.allocator.alloc(u8, 4 * 1024 * 1024);
    defer std.testing.allocator.free(data);
    var cancel = std.atomic.Value(bool){ .raw = true };
    var shutdown = std.atomic.Value(bool){ .raw = false };
    try std.testing.expectError(error.Cancelled, hashBuffer(data, null, .{ .own = &cancel, .shutdown = &shutdown }));
}

const ProgressCapture = struct {
    last: u8 = 0,
    calls: usize = 0,
    fn onProgress(self: *ProgressCapture, pct: u8) void {
        self.calls += 1;
        self.last = pct;
    }
    fn cb(self: *ProgressCapture) Progress {
        return .{
            .ctx = self,
            .func = struct {
                fn f(c: *anyopaque, p: u8) void {
                    onProgress(@ptrCast(@alignCast(c)), p);
                }
            }.f,
        };
    }
};
