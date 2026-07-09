# Security (`src/security/`, fuses, CSP)

## Purpose

Least-privilege, fail-closed command gating. Three layers decide what a window may
do: a **capability** model (permissions bound to windows + origins + scopes), build-time
**fuses** (kill switches), and a strict **CSP** on the rendered HTML. Every decision
defaults to deny.

## Key files

| File | Responsibility |
|------|----------------|
| `security/capability.zig` | `Capability`/`Permission`/`PermissionSet` types; comptime catalog validation (cycle/member checks). |
| `security/grantTable.zig` | Compile capabilities + fuses into a `GrantTable`: per-(window,command) grants, scope merge, fuse-driven force-deny. |
| `security/gates.zig` | The gates G1 (origin), G2 (command), G4 (scope) and `evaluate()` orchestration; fuzz-tested origin matching. |
| `security/defaults.zig` | Built-in permissions (`fs:read/write`, `shell:execute`, `http:request`, `core:window:*`, `core:compute:cancel`) and the safe `core:default` set. |
| `security/scope/{glob,path,host,argv,label}.zig` | G4 matchers; glob (`**`/`*`/`?`), path (token-expand + realpath + glob), host+port, exact argv, window-label glob. |
| `manifest/fuses.zig` | Comptime exposure of the four fuse constants. |
| `manifest/validate.zig` | Capability cross-check + `debugInspector`-in-release rejection. |
| `cli/csp.zig` | The strict CSP builder/injector (also see [cli.md](cli.md)). |

## Capability model

A `Capability` = `{ identifier, windows[], origins[], permissions[] }`: it grants a
set of resolved permissions to a set of window-label globs from a set of origins.
Origins are `app_scheme` (exactly `app://localhost`), `devUrl` (exact, Debug only),
or `httpsExact` (exact, requires the `allowRemoteContent` fuse). Empty origins ⇒
`app_scheme` only. `GrantTable.compile` resolves permission sets transitively into
commands + scopes, dropping fuse-gated families (shell, https) and emitting
diagnostics. Built-ins live in `defaults.zig`; app-declared permissions are spliced
in at comptime via `app_catalog.zig`. `core:default` (the `App.init` grant) contains
only safe commands (no fs, http, or shell).

## Gates

`evaluate()` runs **G1 → G2 → G4**, fail-closed, stopping at the first deny:

- **G1 (origin trusted)**: the request origin must exactly match a trusted
  `OriginPattern` for the window (`app://localhost` only by default; `devUrl`
  honored only when `is_debug`). Deny → `origin.untrusted`.
- **G2 (command granted)**: deny-by-default; deny-list beats allow-list. No matched
  capability ⇒ denied. Deny → `command.not_granted`.
- **G4 (scope matched)** (only if the command carries a scope): `.path` (token
  expand → realpath → glob, deny-beats-allow, unresolvable ⇒ deny), `.host`,
  `.argv` (exact), `.label` (window glob). Deny → `scope.<kind>.no_match`.

Each denial returns a stable code for frontend branching.

## Fuses

Four build-time kill switches in `manifest/types.zig`, all default `false`:

| Fuse | Effect |
|------|--------|
| `allowRemoteContent` | Required for any `httpsExact` origin; otherwise such grants are **dropped** at compile (`fuse_requires_capability`). |
| `allowShell` | Required for `shell:*` permissions; otherwise dropped during resolution. |
| `allowEval` | Gates the dev-client script injection (see [window-and-platform.md](window-and-platform.md)); declared, broader enforcement reserved. |
| `debugInspector` | **Rejected in any release mode** at validate time (`inspector_in_release`); allowed only in Debug. |

Fuses are comptime constants (`manifest/fuses.zig`); a refactor that made one
runtime would fail the build. The binary's real attack surface is therefore
immutable and auditable.

## CSP

`cli/csp.zig` builds a strict policy: `default-src/script-src/style-src/connect-src/
img-src 'self'` plus per-script SHA-256 hashes (`'sha256-<b64>'`) and any
manifest-validated host tokens. A deny-scan rejects `'unsafe-inline'`,
`'unsafe-eval'`, `'unsafe-hashes'`, `'wasm-unsafe-eval'`, scheme sources
(`https:`/`http:`/`data:`/`blob:`), and the bare `*`. Injection into `index.html`
is idempotent (identical `<meta>` is a no-op) and fail-closed (a differing author
`<meta>` is `csp_conflict`, never a silent overwrite). Both the deny-scan and the
injection are fuzz-tested.

## Enforcement flow

```
origin, window label, command, optional scope input, is_debug
  → originsFor(window)         → G1: exact origin match?         (else deny)
  → commandGranted(win,cmd)    → G2: deny-list then allow-list   (else deny)
  → scopeFor(win,cmd)          → G4: deny-set then allow-set     (else deny)
  → allow / deny + stable code
```

Manifest validation runs first: parse `zigware.zon`, merge per-OS overrides,
require a `main` window, cross-check every `security.grants` ref against a
`src/grants/<id>.zon` file (missing dir ⇒ all refs fail), reject
`debugInspector` in release. Errors fail the build; warnings don't.

## Invariants & known limits

- **Fail closed everywhere**: unknown command/origin, unresolvable path, unknown
  `$TOKEN`, >64-segment glob, missing capability. `GrantTable.compile` removes a
  fuse-gated grant from the table; it never leaves one present but unreachable.
- **Comptime verification**: fuses comptime-known; catalog cycles and unresolved
  permission-set members are build errors; script hashes precomputed.
- **Multi-cap (v0.1.0)**: at most one capability may match a (window, command) pair;
  an assert guards the not-yet-implemented multi-cap scope/origin merge.
- **Path TOCTOU / case-insensitive FS**: acknowledged low-risk author footguns;
  no scoped command ships in v0.1.0 (all scope inputs are `.none`), so not currently
  exploitable. Future fs handlers should re-verify the fd (e.g. `O_NOFOLLOW`).
- Permission strings are static comptime literals; `GrantTable.compile` copies
  headers only and dereferences those exact bytes on every check, so callers must
  never free them.
