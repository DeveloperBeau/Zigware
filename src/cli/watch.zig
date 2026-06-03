const std = @import("std");

pub const ChangedPath = struct { path: []const u8, kind: enum { zig_src, manifest, other } };

pub const Watcher = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        // Blocks until a debounced batch is ready; null when the watcher is closed
        // OR when the shutdown flag (handed to polling()) is observed set. The internal
        // scan/sleep loop polls that flag every interval so a SIGINT mid-next() returns
        // null promptly instead of stranding the dev loop until an unrelated file changes.
        // The returned slice is owned by the watcher and valid only until the next next()/close().
        next: *const fn (*anyopaque, io: std.Io) anyerror!?[]const ChangedPath,
        close: *const fn (*anyopaque) void,
    };
    pub fn next(self: Watcher, io: std.Io) anyerror!?[]const ChangedPath {
        return self.vtable.next(self.ptr, io);
    }
    pub fn close(self: Watcher) void {
        self.vtable.close(self.ptr);
    }
};

/// `shutdown` is observed by next()'s scan/sleep loop: when it is set, next() returns
/// null on the next interval boundary (at the latest) instead of blocking until a file
/// changes. The Poller stores this pointer; it does NOT widen the Watcher vtable — fakes
/// receive the same flag by construction.
pub fn polling(gpa: std.mem.Allocator, roots: []const []const u8, interval_ms: u32, shutdown: *std.atomic.Value(bool)) !Watcher {
    _ = gpa;
    _ = roots;
    _ = interval_ms;
    _ = shutdown;
    return error.NotImplemented;
}

/// Deferred to v0.2: macOS FSEvents has no public std.Io API. polling() is the shipped default.
pub fn fsEvents(gpa: std.mem.Allocator, roots: []const []const u8, debounce_ms: u32) !Watcher {
    _ = gpa;
    _ = roots;
    _ = debounce_ms;
    return error.Unsupported;
}
