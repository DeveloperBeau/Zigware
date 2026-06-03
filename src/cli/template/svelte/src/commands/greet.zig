const z = @import("command_ctx.zig"); // vendored

pub const Commands = struct {
    pub fn greet(ctx: *z.Ctx(struct {}), args: struct { name: []const u8 }) z.Result(struct { message: []const u8 }) {
        _ = ctx;
        return .{ .ok = .{ .message = args.name } };
    }
};
