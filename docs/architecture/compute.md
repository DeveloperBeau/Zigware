# Compute / async (`compute.zig`, `jobs.zig`)

## Purpose

Long-running and streaming commands run off the main UI thread on a bounded worker
pool, with per-invocation cancellation and progress/binary streaming. A hash of
hundreds of MB never blocks the UI and can be cancelled mid-flight.

## Key files

| File | Responsibility |
|------|----------------|
| `compute.zig` | Async author types: `CancelToken`, `Sink(P)`, `ComputeError`, `Worker(A,P)`. |
| `jobs.zig` | The thread `Pool`: workers, a mutex-guarded FIFO queue, inflight count, atomic `cancel_all` shutdown flag. |
| `commandContext.zig` | Per-call `Ctx`/`Channel`/emit sink the worker streams through (see [bridge-and-commands.md](bridge-and-commands.md)). |
| `bridge.zig` | Owns the pool; arms/cancels/releases the per-id cancel flag in its `inflight` map. |
| `registry.zig` | Detects `Async(T)` returns, builds the job thunk, arms the cancel token before submit. |
| `commands/compute.zig` | The `compute.cancel` builtin: looks up an inflight id and sets its flag. |

## Core types

- **`CancelToken`** holds two atomic-bool pointers: `own` (this invocation's flag,
  in the bridge `inflight` map) and `shutdown` (the pool's `cancel_all`).
  `isCancelled()` returns true if either is set; the worker reads it lock-free with
  acquire ordering. `never()` targets an always-false flag for sync/demo use.
- **`Sink(P)`** projects the state-independent parts of `Ctx` for a worker:
  `progress(P)` emits one `_stream` frame; `progressBytes(chunk, mime)` parks binary
  and emits a `_bin` frame, sharing the per-call `bin_seq` so terminal `Bytes` and
  streamed chunks never collide on sequence number. It must not outlive the job.
- **`ComputeError`** and **`Worker(A,P)`** are documentation-only shapes. No runtime
  value crosses the dispatch seam; the registry converts logical errors into
  `Result.err` codes before emission.

## Jobs

A `Job` is `{ id, ctx: *anyopaque, run }`; `run` receives the pool's shared
`cancel_all` flag. The `Pool` spawns a fixed worker count (CPU-derived, capped at
8), `submit` rejects with `QueueFull` past `max_queue`, and the worker loop pops a
job under the mutex, runs it **outside** the lock, then decrements inflight and
broadcasts idle. `deinit` sets `cancel_all` (release ordering), broadcasts, and
joins every worker.

## Dispatch & cancellation flow

1. Bridge reserves the call slot (G5). For async handlers the registry calls
   `armCancel(id)` to allocate the per-id flag **before** `pool.submit`, so a
   `compute.cancel` arriving immediately after enqueue still finds it.
2. The worker runs the handler with the `CancelToken`, polling `isCancelled()` in
   its loop (per the protocol, roughly every 64 KB) and stopping if set.
3. `compute.cancel` looks up the id in the inflight map and sets its `own` flag.
4. After the handler returns, the thunk calls `releaseCall(id)`, which `fetchRemove`s
   the inflight entry (freeing the flag, double-free safe) and marks parked binary
   as settled (freed only after the frontend pulls it).
5. Pool `deinit` flips `cancel_all`, so in-flight jobs observe shutdown and exit.

## Threading model

Single UI/main thread for message dispatch; a bounded worker pool for command
execution; **no hidden framework threads** (timers schedule onto the pool). Results
and stream frames marshal back to the main thread through the bridge's single
`backend.evalJS` choke point (on macOS, `evalJS` hops to the main queue before
touching the webview). Workers never mutate UI state directly; only the
registry-thunk performs the post-handler state mutation.

## Invariants

- One flag instance each for `own` and `shutdown`; no aliasing.
- `inflight` map ops (arm/cancel/release) are serialized by `inflight_mutex`; the
  worker only reads the flag value lock-free.
- Only async handlers arm a cancel flag (sync uses a stack dummy that's never freed).
- One per-call arena, freed after the terminal result; `bin_seq` shared so binary
  sequence numbers never collide.
- Cancel flag armed before submit (early-cancel safety).
