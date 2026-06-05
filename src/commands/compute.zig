const std = @import("std");
const ctxmod = @import("../command_ctx.zig");
const Bridge = @import("../bridge.zig").Bridge;
const builtin = @import("builtin.zig");

const State = builtin.State; // compute.cancel shares the app State; it uses ctx.services

/// The `compute.cancel` command namespace. Parameterized over the backend `B` so
/// `*Bridge(B)` is nameable for the `@ptrCast` of `ctx.services` (mirroring
/// `window_commands.WindowCommands(B)`). G1/G2 already ran in handleMessage
/// (origin trust + the `core:compute:cancel` grant from `core:default`), and the
/// command is resource-free (`ScopeInput.none`), so no G4 scope check runs here.
pub fn ComputeCommands(comptime B: type) type {
    const Br = Bridge(B);
    return struct {
        /// Cancel the in-flight invocation identified by `id`. Idempotent: an
        /// unknown, finished, or sync (unarmed) id is a no-op success, because
        /// `bridge.cancelId` already short-circuits a missing entry or null flag.
        /// `ctx.services` is set to the bridge on every dispatched handler
        /// (registry.zig), so the null branch is defensive-only (unreachable on
        /// the live path) and resolves as a no-op success.
        pub fn @"compute.cancel"(ctx: *ctxmod.Ctx(State), args: struct { id: u64 }) ctxmod.Result(struct {}) {
            const services = ctx.services orelse return .{ .ok = .{} };
            const b: *Br = @ptrCast(@alignCast(services));
            b.cancelId(args.id);
            return .{ .ok = .{} };
        }
    };
}
