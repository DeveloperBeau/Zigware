//! The notes example app entry point.
//!
//! `App(MacOSBackend)` builds the secure window/lifecycle shell from the
//! manifest and runs the platform loop. The app's one command, `hashFile`, is
//! defined in `commands/hash_file.zig`; the cancel registry it relies on is
//! framework-internal (wired by app.zig/bridge), so the author constructs
//! nothing here.
//!
//! `hashFile` reaches the bridge through the framework command surface. It is
//! referenced below so the linker pulls it in and the compiler type-checks it
//! against the `*Ctx(State)` + scope contract; the headless integration test
//! (`integration_test.zig`) drives it end to end through G0-G6.

const std = @import("std");
const builtin = @import("builtin");
const z = @import("zigware");
const hash_file = @import("commands/hash_file.zig");

/// The app command surface. `hashFile` is the example's one app command; the
/// framework wires its own builtins (compute.cancel, window.*) alongside.
pub const Commands = struct {
    pub const hashFile = hash_file.hashFile;
};

// Force semantic analysis of the handler even though App's shipping registration
// is the framework surface (the in-repo example demonstrates the secure path; the
// headless test is the executable proof). Zig only analyzes referenced decls.
comptime {
    _ = Commands;
}

fn Backend() type {
    return switch (builtin.os.tag) {
        .macos => z.MacOSBackend,
        else => @compileError("the notes example targets macOS only"),
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
