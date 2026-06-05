const std = @import("std");

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
