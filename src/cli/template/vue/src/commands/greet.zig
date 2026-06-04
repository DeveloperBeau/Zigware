const z = @import("zigware"); // the framework module wired by `zigware init`

pub const Commands = struct {
    pub fn greet(ctx: *z.Ctx(struct {}), args: struct { name: []const u8 }) z.Result(struct { message: []const u8 }) {
        _ = ctx;
        return .{ .ok = .{ .message = args.name } };
    }
};
