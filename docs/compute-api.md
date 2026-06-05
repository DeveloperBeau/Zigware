# Compute API

The compute API runs a command off the UI thread, streams typed progress back
to the page, and lets the page cancel a single in-flight call. It is a thin
layer over the command dispatch path: there is no separate job system to set up
and nothing to construct in `main`. A handler opts into the worker pool simply
by returning `Async(Result(...))`, and the framework runs its body on a worker.

The worked example throughout is `examples/notes/src/commands/hash_file.zig`,
which hashes a file in 64 KiB chunks with streamed percent progress and
cooperative cancellation.

## Offloading via an async return

A synchronous handler returns `Result(T)` directly. To run on a worker thread,
return `Async(Result(T))` instead:

```zig
const z = @import("zigware");

const Out = struct { hash: []const u8 };

pub fn hashFile(ctx: *z.Ctx(State), args: struct { path: []const u8 }) z.Async(z.Result(Out)) {
    // ... runs on a worker thread ...
    return z.done(z.Result(Out){ .ok = .{ .hash = hex } });
}
```

`z.done(value)` wraps a finished `Result` as the `Async` the dispatch expects.
The dispatch path does the rest: it reserves an in-flight slot, hands the body to
the pool, and emits exactly one terminal frame (resolve or reject) when the body
returns.

The return type carries two distinct payload types and they must not be
conflated:

- The **success payload** is the `T` in `Result(T)` you return (`Out` above,
  `struct { hash: []const u8 }`).
- The **progress-frame type** is the `P` you stream during the call (see `Sink`
  below, e.g. `struct { pct: u8 }`).

Name them separately. They are different shapes carried on different channels.

## `Sink(P)`: streaming progress and binary

A handler builds its sink from its own context with the comptime projector:

```zig
const Pct = struct { pct: u8 }; // the progress-frame type, distinct from Out

const sink = z.Sink(Pct).from(ctx);
```

`Sink(P).from(ctx)` projects the state-independent fields off the handler's
`*Ctx` (the emit hook, the call id, the per-call arena, the cancel token, and a
pointer to the call's binary sequence counter). It does **not** store
`*Ctx(State)`: `Ctx` is generic over the app's `State`, so framework code cannot
name it. Build the sink with `from(ctx)`; do not write a field literal like
`Sink(P){ .ctx = ctx }`, and do not reach for a two-parameter `Sink(State, P)`.
The single type parameter is the progress frame.

### JSON progress

```zig
sink.progress(.{ .pct = 50 });
```

`progress(v: P)` sends one progress frame carrying a `P` value over this call's
stream channel. The argument is a `P` struct, so pass `.{ .pct = 50 }`, not a
bare scalar. On the page side each frame is delivered to `opts.onStream` (see
the JS client doc).

The example streams a frame only when the integer-percent bucket advances, so a
small file does not flood the channel:

```zig
const pct: u8 = if (size == 0) 100 else @intCast(@min(@as(u64, 100), read_total * 100 / size));
if (pct != last_pct) {
    sink.progress(.{ .pct = pct });
    last_pct = pct;
}
```

### Binary progress

```zig
const ok = sink.progressBytes(chunk, "application/octet-stream");
if (!ok) {
    // the per-id binary budget overflowed; this chunk was dropped
}
```

`progressBytes(chunk, mime) bool` parks the raw bytes for retrieval over the
stream scheme and emits a `_bin` control frame carrying the id, sequence, length,
and mime. The `mime` argument is **mandatory** (the sink has no mime to project
from the context, so the caller supplies it). The return is the budget-overflow
flag: it is `false` only when the per-id binary budget is exceeded, in which case
nothing was parked and no frame emitted. Do not discard the return value; surface
a dropped chunk to the caller rather than losing it silently.

Raw chunk bytes never cross the JavaScript eval channel. Only the `_bin` control
frame is evaluated; the bytes themselves are fetched separately over the stream
scheme (see the JS client doc). This is the G6 output-encoding boundary.

## Cancellation

Cancellation is **cooperative**. The framework never interrupts a worker; the
handler must poll and return.

```zig
if (sink.isCancelled()) {
    return z.done(z.Result(Out){ .err = .{ .code = "cancelled", .message = "cancelled" } });
}
```

`sink.isCancelled()` returns true when **either** of two flags is set:

- the **per-invocation flag** for this exact call, flipped by `compute.cancel`
  (see the JS client doc), or
- the process **shutdown flag** (`cancel_all`), set during ordered shutdown so
  every in-flight worker drains on quit.

Each in-flight call gets its own invocation flag, so cancelling one call leaves
its concurrent siblings running. Poll on a tight cadence (the example polls once
per 64 KiB chunk) so a cancel lands promptly. On observing cancellation, return a
`Result.err` with code `cancelled`; the page-side promise rejects with a
`ZigError` whose `.code` is `cancelled`.

`CancelToken` is the underlying observer (two `*const` atomic-bool pointers, own
and shutdown). Handlers read it through `sink.isCancelled()`; the token is also
threaded through helper functions that want to bail between chunks. A
`CancelToken.never()` constructor returns a token that never reports
cancellation, for unit tests and callers with no live invocation flag.

## Reject codes

There is one terminal reject site. A failure reaches the page as a `ZigError`
whose `.code` is the string the handler put in the `Result.err`, or the string
the dispatch emits before the handler runs. The codes a page actually observes:

| Code | Source |
|---|---|
| `scope.path.no_match` | the G4 scope gate denied the path argument, before the handler ran |
| `queue_full` | the in-flight budget was full when the call arrived (G5) |
| `cancelled` | the handler observed cancellation and returned a `Result.err` |
| `io_error` | a handler-chosen code, e.g. the example's open/read/stat failures |
| `internal` | a handler-chosen catch-all, e.g. the example's out-of-memory path |

The first three are framework-emitted; the last two are codes the example
handler chooses for its own failures. A handler is free to define its own codes.
Branch on `err.code`, not on the message text.

`ComputeError` (`error{ Cancelled, QueueFull, OutOfMemory, WorkerFailed }`) and
`Worker(A, P)` are documentation-only. They name the **logical** failure
categories and the author-facing offload shape; they are not the literal wire
codes and no runtime `error{...}` value crosses the dispatch seam. The dispatch
rejects error-union returns, so a handler converts a logical failure into a
`Result.err` value (picking its own `.code`) before returning. Return
`Async(Result(P_ok))`, not `ComputeError!P_ok`.

v0.1.0 ships on macOS only.
