//! Headless codegen surface for the zigware package.
//!
//! This barrel roots the Cocoa-free subset a consumer's `zig build dts` needs:
//! the command-handler value types (from command_ctx.zig) and the `.d.ts`
//! emitter (from emit_dts.zig). It deliberately does NOT import app.zig,
//! bridge.zig, any platform/macos/* file, the objc module, or
//! manifest/parse.zig, so a module rooted here links no Cocoa or WebKit. The
//! otool gate in tests/scaffold-consumer asserts that on every CI run.

const command_ctx = @import("command_ctx.zig");
const builtin_cmds = @import("commands/builtin.zig");
const compute = @import("compute.zig");

// Command-handler value types. The dts and test builds wire THIS module under
// the name "zigware" so a consumer's command files compile Cocoa-free against
// the same nominal types the full barrel exposes.
pub const Ctx = command_ctx.Ctx;
pub const Result = command_ctx.Result;
pub const Async = command_ctx.Async;
pub const done = command_ctx.done;
pub const Bytes = command_ctx.Bytes;
pub const Channel = command_ctx.Channel;
pub const CommandError = command_ctx.CommandError;
/// The progress sink a streaming handler declares as its third parameter
/// (`fn (..., sink: z.Sink(P))`). Re-exported here so a consumer's command file
/// compiles Cocoa-free against the headless barrel during `zig build dts`; the
/// emitter then reads P off this type to render the command's `stream` payload.
pub const Sink = compute.Sink;

/// The framework built-in command State, re-exported so a consumer barrel can
/// default its own `pub const State = ...` to it.
pub const State = builtin_cmds.State;
/// The framework built-in command surface, exposed for tooling that wants the
/// builtin contract.
pub const builtins = builtin_cmds.Commands;

/// The reusable `.d.ts` emitter. The synthesized dts-main addApp generates
/// calls this over the consumer's command surface.
pub const emit = @import("emit_dts.zig").emit;

test {
    @import("std").testing.refAllDecls(@This());
}

test "headless barrel exposes Sink for streaming handler signatures" {
    const P = struct { pct: u8 };
    try @import("std").testing.expect(Sink(P) == @import("compute.zig").Sink(P));
}
