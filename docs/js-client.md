# JavaScript client

The framework injects a single global, `window.Zigware`, into every app window
before the page loads. It is the only bridge between page JavaScript and the
native command handlers. The page never posts to the native message handler
directly; it calls `Zigware.invoke`.

## `invoke(name, args, opts) -> Promise`

```js
const result = await window.Zigware.invoke("hashFile", { path }, {
  onStream: (frame) => {
    bar.value = frame.pct;
  },
});
// result is the handler's success payload, e.g. { hash: "…" }
```

- `name` is the command name (must be a registered, granted command).
- `args` is the typed argument object the handler decodes.
- `opts` is optional. The only field today is `onStream`.

`invoke` returns a `Promise` that resolves with the handler's success payload, or
rejects with a `ZigError` (see below). Each call is assigned a fresh monotonic id
(`Zigware._seq` is incremented and is the new call's id immediately after the
`invoke` returns its promise), which correlates the request with its stream
frames and its terminal resolve or reject.

## Streaming with `opts.onStream`

When a handler streams progress, each frame is delivered to `opts.onStream`:

```js
{
  onStream: (frame) => {
    bar.value = frame.pct;
    pct.textContent = frame.pct + "%";
  },
}
```

The frame object is the handler's progress-frame value (for the notes example,
`{ pct }`). The backend constructs an id-keyed channel internally: frames carry
the call id, and the shim routes each to the matching pending call's `onStream`
before the terminal resolve or reject settles the promise. The stream is
informational; the resolved value is the terminal success payload, not the last
frame.

### Binary chunks

A handler may stream binary chunks. The raw bytes never cross the eval channel:
the backend emits only a `_bin` control frame (id, sequence, length, mime), and
the shim fetches the bytes separately over the app's stream scheme
(`app://localhost/__zigware_stream/<id>/<seq>`). The promise does not finish
until every advertised chunk has been fetched. In v0.1.0 a single advertised
chunk becomes the resolved value directly (a `Uint8Array`).

## Errors: `window.Zigware.ZigError`

A rejected `invoke` rejects with a `ZigError`:

```js
try {
  await window.Zigware.invoke("hashFile", { path });
} catch (err) {
  // err instanceof window.Zigware.ZigError
  err.code;     // string reject code, e.g. "scope.path.no_match", "cancelled"
  err.message;  // human-readable message
  err.payload;  // optional structured payload, may be undefined
}
```

Branch on `err.code`, not `err.message`. The codes are stable; the messages are
for humans. Two codes the notes example branches on:

- `scope.path.no_match`: the path argument fell outside the capability's scope
  and was denied at the G4 gate before the file was touched. (This is the real
  observable code; there is no `out_of_scope` code.)
- `cancelled`: the call was cancelled and the handler returned.

## Cancelling from the UI

Cancellation is a normal command. Capture the in-flight call's id, then invoke
`compute.cancel` with it:

```js
const promise = window.Zigware.invoke("hashFile", { path }, { onStream });
const currentId = window.Zigware._seq; // this call's id

// later, from a Cancel button:
window.Zigware.invoke("compute.cancel", { id: currentId }).catch(() => {});
```

`compute.cancel` is fire-and-forget and idempotent: cancelling an unknown or
already-finished id is a no-op success. The backend flips that one invocation's
own cancel flag; the worker observes it between chunks and settles the **original**
`invoke` promise with a `ZigError` whose `.code` is `cancelled`. Concurrent calls
are unaffected, since each has its own flag.

v0.1.0 ships on macOS only.
