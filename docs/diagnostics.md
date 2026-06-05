# Diagnostics

`diag` is the framework's structured, leveled diagnostic logger. It is the
channel for build, manifest, and dev errors and traces. It is **not** the CLI's
user-facing program output: help text, `--version`, and packaging result text a
human reads stay on a plain stdout writer and are never routed through the
leveled or JSON-lines transport.

Every record carries a level, a scope, a free-form message, and zero or more
typed fields.

## Levels

```zig
const diag = @import("diag");

const log = diag.scoped("build");
log.info("assembled bundle", &.{ diag.str("app", name) });
log.warn("missing optional asset", &.{ diag.str("path", p) });
log.err("codesign failed", &.{ diag.int("status", code) });
```

| Level | Always live |
|---|---|
| `trace` | Debug builds only |
| `debug` | Debug builds only |
| `info` | yes |
| `warn` | yes |
| `err` | yes |

`scoped(comptime scope)` returns an emitter tagged with a scope string. Call
`trace`/`debug`/`info`/`warn`/`err` on it; each takes a message and a slice of
fields.

## Scopes

A scope is a short string naming the subsystem that emitted the record. It
travels with every record and renders in both transports, so a reader can filter
by it. Choose one scope per module (`"build"`, `"manifest"`, `"dev"`).

## Fields

Fields are typed key-value pairs. Use the constructors so call sites read
cleanly:

```zig
diag.str("path", p)      // string
diag.int("status", -1)   // signed
diag.uint("bytes", 4096) // unsigned
diag.boolean("signed", true)
diag.secret("password")  // redacted, see below
```

The underlying `Value` is a tagged union (`str`, `int`, `uint`, `boolean`,
`redacted`).

## Redaction

```zig
log.err("notary auth failed", &.{ diag.secret("APPLE_APP_SPECIFIC_PASSWORD") });
```

`secret(key)` records **only the key**. The raw value never enters the logger by
construction, so a secret cannot leak through a transport even by accident. It
renders as `***` in every transport. The constructor takes the key alone; there
is no value parameter to pass the secret into.

## Build-gating

`trace` and `debug` lower to no-ops whenever `comptime builtin.mode != .Debug`.
This is the single normative predicate, exported as `diag.verbose_stripped` so
tests can assert against the exact expression the gate uses. Under ReleaseSafe
(and the other release modes) those two levels produce no transport output at
all. `info`, `warn`, and `err` are always live, so a ship build keeps its error
diagnostics.

One caveat: `fields` is a runtime slice, so the **caller** still materializes the
field slice literal before a gated-out call is entered. The guarantee is narrow
and exact: a gated-out `trace`/`debug` call performs no format and no transport
work and emits nothing. It is not a promise that the field expressions at the
call site are never evaluated. Keep field expressions cheap and side-effect free.

Zigware ships Debug and ReleaseSafe. Verify the no-op by building with
`-Drelease=true` and confirming the transport recorded nothing for a `trace` or
`debug` call.

## Transports

A transport is a sink: a `record` function plus an opaque context it casts back.
The active transport defaults by build mode:

- **Debug:** human-readable single lines,
  `LEVEL [scope] message key=value key=***`, written to stderr.
- **Release:** one JSON object per line, suitable for machine ingestion.

```zig
diag.setTransport(.{ .ctx = my_ctx, .record = myRecord }); // swap the sink
diag.resetTransport();                                     // restore the default
```

Tests capture output by installing a transport whose `record` appends to a
buffer. The human and JSON renderers are also exposed as
`writeHumanForTest`/`writeJsonForTest` for direct byte inspection. The JSON
transport escapes strings with `std.json` (JSON-string rules), distinct from the
JS/HTML eval-channel encoding used on the command output path.
