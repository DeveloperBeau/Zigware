const z = @import("zigware");

/// The app State. Defaults to the framework built-in State so the command
/// surface composes with the builtins over one State.
pub const State = z.State;

pub const Commands = struct {
    /// Return a greeting for `name`. Pure: no async, no streaming.
    pub fn greet(ctx: *z.Ctx(State), args: struct { name: []const u8 }) z.Result(struct { message: []const u8 }) {
        const msg = std.fmt.allocPrint(ctx.arena, "Hello, {s}!", .{args.name}) catch
            return .{ .err = .{ .code = "internal", .message = "oom" } };
        return .{ .ok = .{ .message = msg } };
    }
};

const std = @import("std");

test "greet builds a message" {
    // Compile-time proof the command surface is well-formed; the headless dts
    // and test steps re-root this file Cocoa-free.
    std.testing.refAllDecls(Commands);
}
