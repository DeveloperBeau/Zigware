const std = @import("std");
const ctxmod = @import("command_ctx.zig");
const protocol = @import("protocol.zig");

/// A per-invocation cancel observer. The worker cancels when EITHER its own
/// invocation flag OR the pool's shared `cancel_all` (the ordered-shutdown
/// signal) is set. Two `*const` pointers so the worker reads both lock-free in
/// its hashing loop and shutdown never has to walk the in-flight registry.
///
/// The own-flag lives in `bridge.inflight` (the G5 reservation map) guarded by
/// `inflight_mutex`; `shutdown` is `&pool.cancel_all`.
pub const CancelToken = struct {
    own: *const std.atomic.Value(bool), // this invocation's flag
    shutdown: *const std.atomic.Value(bool), // the pool's cancel_all

    /// True if this invocation OR the whole process is being cancelled.
    pub fn isCancelled(self: CancelToken) bool {
        return self.own.load(.acquire) or self.shutdown.load(.acquire);
    }

    /// A token that never reports cancellation. For null/test callers that have
    /// no live invocation flag (sha256/demo logic-test roots, direct unit tests).
    /// Both pointers target one shared always-false flag.
    pub fn never() CancelToken {
        return .{ .own = &never_flag, .shutdown = &never_flag };
    }
};

// Ordering convention (matches the rest of the codebase): the worker reads both
// flags LOCK-FREE in its hashing loop (it never takes `inflight_mutex`), so the
// canceller's store and the worker's load are paired only by the atomic's own
// ordering. `isCancelled()` loads `.acquire`; therefore `bridge.cancelId` MUST
// store the own-flag with `.release` ordering (mirroring the existing
// `cancel_all` store at jobs.zig:79). The flag is a standalone bool publishing no
// associated data, so this is convention-consistency, not a correctness fix.
const never_flag = std.atomic.Value(bool){ .raw = false };

/// The logical error set the offload path maps to reject codes
/// (`cancelled`/`queue_full`/`out_of_memory`/`worker_failed`).
///
/// DOCUMENTATION-ONLY: no runtime `error{...}` value crosses any dispatch seam.
/// `registry.validate` rejects `!T` returns, `jobs.Pool.submit` returns
/// `error.QueueFull` (not this set), and the registry emits string codes
/// directly. A handler converts a logical `Cancelled`/`WorkerFailed` into a
/// `Result(P).err{ .code = ... }` value before returning via `Async`.
pub const ComputeError = error{ Cancelled, QueueFull, OutOfMemory, WorkerFailed };

/// Typed sugar over the State-independent slice of `Ctx` for offload handlers.
///
/// `P` is the PROGRESS-frame type (e.g. `struct { pct: u8 }`), DISTINCT from the
/// handler's success payload (the `Result(P_ok)` it returns via `Async`). The two
/// must be named separately and never conflated in this type parameter.
///
/// `Sink` does NOT store `*Ctx(State)`: `Ctx(State)` is generic over the app's
/// `State` (command_ctx.zig), so framework code cannot name `*Ctx(AppState)`.
/// Instead it stores exactly the State-independent fields its methods use.
/// `cancelled()` reads only `cancel`; `channel`/`binaryChunk` read only
/// `emit`/`id`/`arena`/`bin_seq`, never `state`. `bin_seq` is a POINTER to the
/// Ctx's mutable `bin_seq` so `progressBytes` bumps the SAME counter `binaryChunk`
/// does (no seq collision between Ctx and Sink emissions).
pub fn Sink(comptime P: type) type {
    return struct {
        const Self = @This();

        emit: *ctxmod.EmitSink,
        id: u64,
        arena: std.mem.Allocator,
        cancel: CancelToken,
        bin_seq: *u32,

        /// Project the State-independent fields off the handler's `*Ctx`. Built by
        /// the handler as `const sink = compute.Sink(P).from(ctx);`. Duck-typed on
        /// `ctx` because `Ctx(State)` is unnameable here; takes `&ctx.bin_seq` so
        /// the sink shares the Ctx's mutable sequence counter.
        pub fn from(ctx: anytype) Self {
            return .{
                .emit = ctx.emit,
                .id = ctx.id,
                .arena = ctx.arena,
                .cancel = ctx.cancel,
                .bin_seq = &ctx.bin_seq,
            };
        }

        /// Emit one progress frame carrying a `P` value over this call's stream
        /// channel. Mirrors `Ctx.channel(P).send`.
        pub fn progress(self: Self, v: P) void {
            const ch = ctxmod.Channel(P){ .emit = self.emit, .id = self.id, .arena = self.arena };
            ch.send(v);
        }

        /// Park `chunk` and emit a `_bin` control frame, using the SHARED `bin_seq`
        /// so terminal `Bytes` and streamed chunks never collide on a seq.
        /// `mime` is mandatory (caller-supplied; `from` has no mime to project).
        /// Returns false ONLY when the per-id binary budget is exceeded (nothing
        /// parked, no frame). The caller must surface a dropped chunk rather than
        /// lose it. Mirrors `Ctx.binaryChunk` against the stored fields.
        pub fn progressBytes(self: Self, chunk: []const u8, mime: []const u8) bool {
            const seq = self.bin_seq.*;
            if (!self.emit.parkBinary(self.emit, self.id, seq, chunk)) return false;
            self.bin_seq.* += 1;
            var fw: std.Io.Writer.Allocating = .init(self.arena);
            defer fw.deinit();
            protocol.encodeBinReady(&fw.writer, self.id, seq, chunk.len, mime) catch return true;
            self.emit.evalJS(self.emit, fw.writer.buffered());
            return true;
        }

        /// True if this invocation OR the whole process is being cancelled.
        pub fn isCancelled(self: Self) bool {
            return self.cancel.isCancelled();
        }
    };
}

/// The author-facing offload shape, DOCUMENTATION-ONLY: there is no runtime
/// offload runner that invokes a `Worker` value. Dispatch is the registry async
/// thunk calling the handler as `(ctx, args) -> Async(Result(P_ok))`; the real
/// handler returns `Async(Result(P_ok))`, NOT `ComputeError!P`. `A` is the typed
/// args, `P` the progress-frame type. The handler/`Sink` sugar converts a logical
/// `Cancelled`/`WorkerFailed` into a `Result.err` value before returning (see the
/// `ComputeError` doc comment). `P` here names the progress frame, distinct from
/// the success payload the worker ultimately produces.
pub fn Worker(comptime A: type, comptime P: type) type {
    return *const fn (A, Sink(P), CancelToken) ComputeError!P;
}
