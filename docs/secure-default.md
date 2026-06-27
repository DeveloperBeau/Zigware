# The secure default, end to end

This walks the `examples/notes/` app and shows where each piece sits in the
request pipeline. The headline property: **the command is allowed, but the target
is not.** A page may call `hashFile`, but only against paths inside the
capability's scope. Anything outside is denied before the file is opened.

The example hashes a file. Its capability grants `hashFile` scoped to
`$APPDATA/notes/**` plus the framework's `core:compute:cancel`. Nothing else is
granted, and every native fuse is off.

## The manifest

`examples/notes/zigware.zon` spells out the secure baseline rather than relying
on inferred defaults, so an auditor reads the whole native attack surface in one
place:

```zig
.security = .{
    .grants = .{"main"},
    .csp = .{
        .defaultSrc = .{"'self'"},
        .scriptSrc = .{"'self'"},
    },
    .fuses = .{
        .allowRemoteContent = false,
        .allowEval = false,
        .allowShell = false,
        .debugInspector = false,
    },
},
```

The capability `main.zon` references the app-declared `hashFile` permission
(`commands_allow = ["hashFile"]`, `scope_allow = ["$APPDATA/notes/**"]`) and
`core:compute:cancel`. Scope lives on the permission, not the capability.

One capability per window is a runtime precondition once the scoped path is live:
the scope lookup asserts a single capability grants a given command to a given
window, in both Debug and ReleaseSafe.

## The page

`frontend/index.html` ships a strict CSP meta and loads only its own scripts. No
inline JavaScript:

```html
<meta http-equiv="Content-Security-Policy"
      content="default-src 'self'; script-src 'self';">
...
<script src="zigware.js"></script>
<script src="app.js"></script>
```

`app.js` calls `Zigware.invoke("hashFile", { path }, { onStream })`, drives a
progress bar from each frame, and offers a Cancel button that invokes
`compute.cancel` against the in-flight id. It branches on the reject code:

```js
if (err.code === "scope.path.no_match") {
  out.textContent = "denied: that path is outside $APPDATA/notes/**";
} else if (err.code === "cancelled") {
  out.textContent = "cancelled";
}
```

## The gate pipeline

A request from the page to a handler passes through the gates below, in order. A
failure at any gate emits exactly one terminal reject correlated to the call, and
the request never reaches a later gate.

- **G0: message boundary.** The inbound message is size-capped
  (`MAX_MESSAGE_LEN`, 64 KiB) at the native seam and again defensively in the
  bridge, then decoded as JSON. An oversize or malformed message is dropped or
  rejected with `internal` before any gate logic runs.

- **G1: origin trust.** The message must come from a trusted origin for the
  window. The strict CSP keeps the page at `app://localhost`; a foreign origin is
  denied with `origin.untrusted`.

- **G2: command granted.** The window's capability must grant the command. The
  notes window is granted `hashFile` and `compute.cancel`; anything else is
  denied with `command.not_granted`.

- **G3: allowlist.** The command name must be a registered command. The
  allowlist is derived at comptime from the registered handler names; an unknown
  name is rejected with `unknown_command`.

- **G4: scope.** This is where the secure default earns its name. For a
  path-scoped command the bridge extracts the candidate `path` from the **same**
  `args_json` the handler will decode, using the registry's parse options
  verbatim, so there is no parse differential between what the gate validates and
  what the handler opens. The path is canonicalized and matched against
  `$APPDATA/notes/**`. An in-scope path allows; an out-of-scope path (say
  `../etc/passwd`) is denied with `scope.path.no_match`. The denial happens here,
  before any reservation or dispatch, so the file is never touched. Unscoped
  commands feed `.none` and pass G4 as a no-op allow.

- **G5: in-flight reservation.** An allowed call reserves a slot under a bounded
  in-flight budget (`MAX_CONCURRENT`). The per-invocation cancel flag lives in
  this same reservation map, under the same lock. A full budget is rejected with
  `queue_full`. Because G4 runs first, an out-of-scope request never consumes a
  slot.

- **G6: output encoding.** Every byte the framework evaluates as JavaScript
  passes through a single choke point that encodes it for the eval channel.
  Streamed binary chunks never cross this channel: only the `_bin` control frame
  is evaluated, and its `mime` string is encoded; the raw bytes are fetched
  separately over the stream scheme.

The observable code for the out-of-scope denial is `scope.path.no_match`, emitted
by gate `g4_scope`. The frontend branches on this exact code. There is no
`out_of_scope` code.

## Allow and deny diverge on the path

The integration test asserts both halves from one fixture. An in-scope path that
exists on disk **resolves** with the hex digest, and an out-of-scope path
**rejects** with `scope.path.no_match`. Asserting only the deny would prove
nothing: if `$APPDATA` expansion or path resolution failed, both halves would
fail closed for the same reason. Requiring the in-scope file to exist,
and asserting it allows, makes the allow a real allow and confirms G4 is
discriminating allow from deny on the path, not failing closed on both.

## Scope of v0.1.0

v0.1.0 ships on macOS only.

The in-repo example builds, packages, and signs into a `.app` and has both a
headless integration test and a GUI smoke. A **scaffolded** project now builds
the same way: `zigware init` produces a normal Zig project that consumes the
framework as a package dependency, so `init -> zig build` yields a runnable
binary and `zigware build` packages a signed `.app`/`.dmg`. One gap remains for a
*shipped scoped command*: `App.init` does not yet load author-declared
capabilities or resolve a real app-data base (it compiles a `core:default`-only
grant and passes `appdata = "."`), so the scoped-path feature works in the
headless integration test but not yet in a shipped GUI app. See
`docs/FOLLOWUPS.md` ("App.init must consume loaded capabilities").
