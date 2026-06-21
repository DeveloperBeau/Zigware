# Bridge + command surface (`bridge.zig`, `command_ctx.zig`, `protocol.zig`, `registry.zig`, `allowlist.zig`, `emit_dts.zig`)

## Purpose

How the webview frontend invokes strongly-typed Zig commands and receives results
or streams. A frontend `Zigware.invoke(name, args, opts)` becomes a JSON message;
the bridge decodes it, runs it through the security gates, dispatches to a
registered command (sync inline or async on a worker pool), and routes the
result/stream/binary back to the page.

## Key files

| File | Responsibility |
|------|----------------|
| `bridge.zig` | `Bridge(B)`: message routing, the security gates, concurrency budget (G5), per-id binary ring buffer, the single `evalJS` emission choke point, window-manager fan-out. |
| `command_ctx.zig` | The command-author API: `Ctx(State)`, `Result(T)`, `Async(T)`, `Channel(T)`, `CommandError`, `Bytes`; per-call arena + cancel token + emit sink. |
| `protocol.zig` | Wire protocol v1: decode/encode, `MAX_MESSAGE_LEN` (64 KiB), `MAX_JSON_DEPTH` (32), reserved names/routes, the `jsString` injection boundary. |
| `registry.zig` | `Commands(B, State, UserCommands)`: comptime command validation, dispatch, sync/async branching, arg decode + result encode. |
| `allowlist.zig` | The fail-closed command allowlist (G3), comptime-built. |
| `emit_dts.zig` | Walks the registry at comptime to emit the `ZigCommands` TypeScript interface (`bindings.d.ts`). |
| `frontend/zigware.js` | Client: `Zigware.invoke`, promise settlement, `_resolve`/`_reject`/`_stream`/`_bin` handlers, binary reassembly. |
| `frontend/window.js` | Window API layer (`Window.getCurrent().setTitle/focus/close`, event listeners) routed via `invoke`. |

## Command-author API

A command is a Zig function:

```zig
pub fn name(ctx: *Ctx(State)) T
pub fn name(ctx: *Ctx(State), args: struct { ... }) T
```

where `T` is `T`, `Result(T)`, `Bytes`, `Result(Bytes)`, or `Async(...)` wrapping
any of those. `Ctx(State)` carries a per-call `arena`, the shared `state`, the
invoke `id`, a `CancelToken`, an `emit` sink, the attested `window_label`, and a
per-call `bin_seq`. `Channel(T)` streams ordered `_stream` frames and a final
`_streamEnd`; `Bytes`/`ctx.binaryChunk` route binary out-of-band.

## Wire protocol

Inbound: `Message { id, cmd, args_json }`. Limits are enforced before parsing:
`MAX_MESSAGE_LEN` 64 KiB, a depth pre-scan against `MAX_JSON_DEPTH` 32, and a
per-value length cap. Encoders emit `window.Zigware._resolve/_reject/_stream/
_streamEnd/_emit/_bin(...)`. `__zigware_ready` is a reserved inbound name (bypasses
the command gate, handled specially); `/__zigware_stream` is a reserved route for
binary pulls (never served as an asset; boundary-matched so
`/__zigware_streamX` is not treated as reserved).

## Dispatch path

```
Zigware.invoke(name,args)  →  postMessage  →  bridge.handleMessage(window_id, origin, text)
  decode → Message{id,cmd,args_json}
  labelFor(window_id)                 (G2: attested window)
  reserved? → handleReserved          (e.g. __zigware_ready)
  allowlist.contains(cmd)             (G3, fail-closed)
  deriveScopeInput + gates.evaluate   (G1 origin, G4 scope)
  reserveCall(label,id)               (G5: ≤ 8 in-flight)
  dispatch → registry
     sync  → runHandler inline, then releaseCall
     async → armCancel(id) BEFORE submit → worker pool runs the job → releaseCall
  encodeResult → emitResolve / emitErrorReject   (one evalJS choke point)
```

See [security.md](security.md) for the gates and [compute.md](compute.md) for the
async/worker path and cancellation.

## Binary streaming

Binary results bypass JSON: the handler parks bytes in a per-id ring buffer
(budget ~16 MiB/id) and emits a `_bin(id, seq, len, mime)` control frame; the
frontend pulls the bytes from `app://localhost/__zigware_stream/<id>/<seq>`. Bytes
are freed only after the pull (not on settle); the whole ring is freed on teardown.

## dts codegen

`emit_dts.zig` walks `UserCommands` at comptime, mapping each command's arg struct
and unwrapped (`Async`→`Result`→`.ok`) return type to TypeScript, emitting the
`ZigCommands` interface and a typed `Zigware.invoke` signature into
`frontend/bindings.d.ts` (generated, gitignored). Unmappable types are a compile
error.

## Invariants

- **Comptime command registration + allowlist** (fail-closed): unknown command → denied.
- **Single injection boundary (G6)**: every user-byte→JS-string path goes through
  `protocol.jsString` / `writeJsonAsJsLiteral`, and every emission funnels through
  one `emitToLabel` → `backend.evalJS`.
- **Per-message arena**: all transient handler allocations live in one arena freed
  after the terminal result.
- **Gates run before the G5 reservation**: denied requests never reserve a slot.
- **No error unions on handlers** (v0.1.0): use `Result(T)` for expected failures;
  `CommandError.payload_json` must be `std.json` output, never raw bytes.
