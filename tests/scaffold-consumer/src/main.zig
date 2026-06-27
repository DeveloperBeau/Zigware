const std = @import("std");
const builtin = @import("builtin");
const z = @import("zigware");
const commands = @import("commands.zig");

// Documentation-only mirror of the framework ReleaseFast ban; the authoritative
// ban lives in the zigware barrel and fires for any consumer regardless.
// Zigware ships ReleaseSafe or Debug only.

// Local backend switch. The barrel does not export `Backend()` until Task 5;
// until then the fixture selects its own backend so Task 4's gate is greenable
// without Task 5. Task 5 migrates this to `z.Backend()`.
fn Backend() type {
    return switch (builtin.os.tag) {
        .macos => z.MacOSBackend,
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
    // Deinit order: app.deinit() runs before backend.deinit() (LIFO defers);
    // App.deinit does not call back into the backend, so the order is safe.
    defer backend.deinit();

    const app = try z.App(B).initWithCommands(commands.Commands, alloc, io, backend);
    defer app.deinit();

    app.run();
}
