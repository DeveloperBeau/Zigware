const std = @import("std");
const z = @import("../command_ctx.zig");
const demo = @import("demo.zig");
const sha = @import("sha256.zig");

/// The v0.1.0 app State for the built-in demo is empty; real apps supply their own.
pub const State = struct {};

/// Named once so every use site shares one nominal type (Zig structs are nominal:
/// a fresh `struct {...}` literal at each site would be a distinct type that does
/// not coerce on return/assignment).
const Out = struct { hash: []const u8 };
const Pct = struct { pct: u8 };

pub const Commands = struct {
    /// Hash `megabytes` MiB of generated data on the worker pool, streaming
    /// integer-percent progress, resolving with the hex digest.
    pub fn sha256(ctx: *z.Ctx(State), args: struct { megabytes: u32 = 256 }) z.Async(z.Result(Out)) {
        const Prog = struct {
            ch: z.Channel(Pct),
            fn report(c: *anyopaque, pct: u8) void {
                const self: *@This() = @ptrCast(@alignCast(c));
                self.ch.send(.{ .pct = pct });
            }
        };
        var p = Prog{ .ch = ctx.channel(Pct) };
        const prog = sha.Progress{ .ctx = &p, .func = Prog.report };

        const mb: usize = @min(args.megabytes, 512);
        const digest = demo.hashGenerated(ctx.arena, mb, prog, ctx.cancel) catch |err| {
            const code: []const u8 = switch (err) {
                error.Cancelled => "cancelled",
                error.OutOfMemory => "internal",
            };
            return z.done(z.Result(Out){ .err = .{ .code = code, .message = @errorName(err) } });
        };
        // The digest is arena-owned ([64]u8 by value); dupe into arena as a slice.
        const hex = ctx.arena.dupe(u8, &digest) catch
            return z.done(z.Result(Out){ .err = .{ .code = "internal", .message = "oom" } });
        return z.done(z.Result(Out){ .ok = .{ .hash = hex } });
    }

    /// Allocate `n` bytes on the per-call arena, fill them, and return them as a
    /// binary result. The bytes are served out-of-band over the stream scheme,
    /// never on the eval channel (G6).
    pub fn echoBytes(ctx: *z.Ctx(State), args: struct { n: u32 }) z.Result(z.Bytes) {
        const buf = ctx.arena.alloc(u8, args.n) catch
            return .{ .err = .{ .code = "internal", .message = "oom" } };
        for (buf, 0..) |*x, i| x.* = @truncate(i);
        return .{ .ok = .{ .data = buf, .mime = "application/octet-stream" } };
    }

    /// Echo the caller's string back as the result (G6 stress: attacker bytes on the
    /// resolve channel). Also streams it once and, if `fail` is set, rejects with it.
    pub fn echo(ctx: *z.Ctx(State), args: struct { s: []const u8, fail: bool = false }) z.Result(struct { s: []const u8 }) {
        ctx.channel(struct { s: []const u8 }).send(.{ .s = args.s });
        if (args.fail) return .{ .err = .{ .code = "boom", .message = args.s } };
        const copy = ctx.arena.dupe(u8, args.s) catch return .{ .err = .{ .code = "internal", .message = "oom" } };
        return .{ .ok = .{ .s = copy } };
    }
};
