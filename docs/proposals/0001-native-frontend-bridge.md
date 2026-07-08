# 001 - Native frontend over an FFI/IPC bridge

Drive the Zig command and security core from a native UI, for example SwiftUI on
macOS, in place of the HTML/JS frontend that runs in a WebKit webview.

## Motivation

The framework pairs a Zig backend with an HTML/JS frontend rendered in a webview.
Some apps want a native UI on top of the same Zig commands, security gates, and
streams. The command model does not depend on the webview, so a native frontend
is a plausible expansion rather than a rewrite.

## What already supports it

`NullBackend` (`src/platform/null.zig`) runs the whole pipeline with no webview:
the bridge, the command registry, the security gates, and streams. The
integration tests send commands and read replies through it. The command logic
runs without the GUI.

Every backend implements one interface, the `Backend` seam in
`src/window/backend.zig`. A native transport is a fresh implementation of that
seam, the same shape the reserved Linux and Windows ports will take.

## What is missing

The reply format is JavaScript. `bridge.zig` builds strings such as
`window.Zigware._resolve(id, {...})` and hands them to `backend.evalJS`. A SwiftUI
frontend runs no JavaScript, so it cannot read that reply as written.

The inbound path needs no change. The bridge accepts a message string, so any
transport that delivers JSON works.

## Sketch

1. Separate the reply encoder from the transport in `bridge.zig`. The webview
   keeps its JavaScript encoder for `_resolve`, `_reject`, `_stream`, and `_bin`.
   A native frontend gets a raw JSON encoder that emits `{id, ok, result}`.
2. Add a native backend that implements the `Backend` seam. Swift calls a C-ABI
   `zw_invoke(json)`, and Zig returns replies through a registered
   `zw_on_reply(json)` callback. A local socket or XPC is an alternative
   transport.
3. Skip the webview-only pieces for this mode. The asset table, the `app://`
   scheme, and CSP injection all serve HTML to a webview, and a native UI needs
   none of them.

## Effort

The reply-encoder split in `bridge.zig` is the bulk of the work. The transport and
the native backend add on top of the existing seam. A spike that wires
`zw_invoke` and `zw_on_reply` against a small SwiftUI harness would measure the
refactor before any commitment.

## Open questions

- Streams and binary frames (`_stream`, `_bin`) need a native representation, not
  a JavaScript call.
- Threading. The bridge runs on one UI thread; a native UI owns its own run loop,
  so the `dispatchMain` seam needs a native mapping.
- Scope. A native UI over an FFI or IPC bridge is a distinct product shape from
  the current webview model, so it needs its own design pass.
