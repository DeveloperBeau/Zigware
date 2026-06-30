//! The notes example app entry point.
//!
//! The window runs on the framework command surface via `App(B).init`; the app's
//! `hashFile` handler is proven end to end by the headless integration test
//! (`integration_test.zig`), which drives it through the path-scoped grant. The
//! command is referenced below so the compiler type-checks it against the
//! `*Ctx(State)` + scope contract even though init wires the framework surface.
const std = @import("std");
const z = @import("zigware");
const commands = @import("commands.zig");

comptime {
    _ = commands.Commands;
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const B = z.Backend();
    const backend = try B.init(alloc);
    // Deinit order: app.deinit() runs before backend.deinit() (LIFO defers);
    // App.deinit does not call back into the backend, so the order is safe.
    defer backend.deinit();

    const app = try z.App(B).init(alloc, io, backend);
    defer app.deinit();

    app.run();
}
