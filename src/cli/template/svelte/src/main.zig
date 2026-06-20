const std = @import("std");
const builtin = @import("builtin");
const z = @import("zigware");

// The app's command surface. greet is the sample command; referencing Commands
// forces the compiler to analyze the handler and the linker to include it.
pub const Commands = @import("commands/greet.zig").Commands;

comptime {
    _ = Commands;
}

fn Backend() type {
    return switch (builtin.os.tag) {
        .macos => z.MacOSBackend,
        else => @compileError("this app targets macOS only"),
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
    defer backend.deinit();

    const app = try z.App(B).init(alloc, io, backend);
    defer app.deinit();

    app.run();
}
