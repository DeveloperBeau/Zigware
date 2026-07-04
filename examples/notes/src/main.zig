//! The notes example app entry point.
//!
//! The window runs the app's own command surface (hashFile) live through
//! initWithCommands and the notes capability (examples/notes/src/grants/main.zon):
//! the main window trusts app:// (and, in Debug, the dev-server origin) and is
//! granted hashFile scoped to $APPDATA/notes/**. The headless integration test
//! (integration_test.zig) still drives the handler end to end over the bridge.
const std = @import("std");
const z = @import("zigware");
const commands = @import("commands.zig");

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

    const app = try z.App(B).initWithCommands(commands.Commands, alloc, io, backend);
    defer app.deinit();

    app.run();
}
