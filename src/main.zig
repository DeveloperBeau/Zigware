const std = @import("std");
const builtin = @import("builtin");
const App = @import("app.zig").App;
const MacOSBackend = @import("platform/macos/backend.zig").MacOSBackend;

// ReleaseSafe enforcement (M1): Zigware never ships with bounds checks stripped.
comptime {
    if (builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall) {
        @compileError("Zigware ships ReleaseSafe or Debug only");
    }
}

/// The single site that selects a backend by target OS. Adding Windows or Linux
/// later means adding a branch here and a new backend module; nothing else.
fn Backend() type {
    return switch (builtin.os.tag) {
        .macos => MacOSBackend,
        else => @compileError("zigware v0.1.0 targets macOS only"),
    };
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const B = Backend();
    const backend = try B.init(alloc);
    // Deinit order (L4): defers run LIFO, so app.deinit() runs BEFORE
    // backend.deinit(). App.deinit's shutdown drains and re-points callbacks at
    // the sentinel; it does not call back into the backend afterward, so the
    // order is safe even after the macOS drain (B2) lands.
    defer backend.deinit();

    const app = try App(B).init(alloc, io, backend);
    defer app.deinit();

    app.run();
}
