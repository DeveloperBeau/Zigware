# Native frontend over an FFI/IPC bridge

- Proposal: ZW-0001
- Author: Beau Ayres
- Status: Draft
- Implementation: none yet

## Introduction

Let a native UI, for example SwiftUI on macOS, drive the Zig command and security
core in place of the HTML/JS frontend that runs in a WebKit webview.

## Motivation

The framework pairs a Zig backend with an HTML/JS frontend rendered in a webview.
Some apps want a native UI on top of the same Zig commands, security gates, and
streams. The command model does not depend on the webview, so a native frontend
fits as an expansion rather than a rewrite.

## Proposed solution

Add a native transport that speaks the framework's command protocol directly, and
teach the bridge to return replies as raw JSON instead of JavaScript. A SwiftUI
app then sends a command as JSON, receives a JSON reply, and renders the result
with native views. The webview path stays as it is.

## Detailed design

Two parts of the framework already point this way:

- `NullBackend` (`src/platform/null.zig`) runs the whole pipeline with no webview:
  the bridge, the command registry, the security gates, and streams. The
  integration tests send commands and read replies through it, so the command
  logic runs without the GUI.
- Every backend implements one interface, the `Backend` seam in
  `src/window/backend.zig`. A native transport is a fresh implementation of that
  seam, the same shape the reserved Linux and Windows ports will take.

One part blocks a native frontend today: the reply format is JavaScript.
`bridge.zig` builds strings such as `window.Zigware._resolve(id, {...})` and hands
them to `backend.evalJS`. A SwiftUI frontend runs no JavaScript, so it cannot read
that reply as written. The inbound path needs no change, since the bridge accepts
a message string and any transport that delivers JSON works.

The work, in three steps:

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

The reply-encoder split is the bulk of the work. A spike that wires `zw_invoke`
and `zw_on_reply` against a small SwiftUI harness would measure the refactor
before any commitment.

## Compatibility

The change is additive. The native backend is a new implementation behind the
existing `Backend` seam, so webview apps build and run as before. The encoder
split must keep the JavaScript path byte for byte for the webview, which the
existing bridge tests pin.

## Alternatives considered

- Render a native-looking UI inside the webview with HTML and CSS. This keeps the
  current model but gives no real native controls or platform integration.
- Run a JavaScript engine inside the Swift app to execute the `_resolve` replies.
  This drags a JS runtime into a native app to undo a format the framework
  produced, which the encoder split removes at the source.

## Open questions

- Streams and binary frames (`_stream`, `_bin`) need a native representation, not
  a JavaScript call.
- Threading. The bridge runs on one UI thread; a native UI owns its own run loop,
  so the `dispatchMain` seam needs a native mapping.
- Scope. A native UI over an FFI or IPC bridge is a distinct product shape from
  the current webview model, so it needs its own design pass.
