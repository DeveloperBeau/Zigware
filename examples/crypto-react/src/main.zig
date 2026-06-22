//! The crypto-demo example app entry point.
//!
//! `App(MacOSBackend).initWithCommands` builds the secure window/lifecycle shell
//! from the manifest, REGISTERS this app's `Commands` alongside the framework
//! builtins, and synthesizes the grant that authorizes them for the app's
//! windows. The frontend's `window.Zigware.invoke("cryptoDemo", …)` reaches
//! the real Zig handler in `commands/crypto.zig`, exercising the web-UI ↔ Zig
//! round-trip the framework exists for.

const std = @import("std");
const builtin = @import("builtin");
const z = @import("zigware");
const crypto = @import("commands/crypto.zig");

/// The app command surface registered with the bridge. `initWithCommands` composes
/// it with the framework builtins over the shared State.
pub const Commands = crypto.Commands;

comptime {
    _ = Commands;
}

fn Backend() type {
    return switch (builtin.os.tag) {
        .macos => z.MacOSBackend,
        else => @compileError("the crypto example targets macOS only"),
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

    const app = try z.App(B).initWithCommands(Commands, alloc, io, backend);
    defer app.deinit();

    app.run();
}
