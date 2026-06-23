# Manifest (`src/manifest/`)

## Purpose

Turns an app's declarative `zigware.zon` into a typed, validated, comptime-embedded
configuration that drives window layout, security policy, fuses, and bundle config.
Security posture is fail-closed: the debug inspector is banned in release,
capability references are cross-checked, and CSP defaults to strict.

## Key files

| File | Responsibility |
|------|----------------|
| `types.zig` | The schema: `Manifest` and nested `App`/`Window`/`Security`/`Fuses`/`Csp`/`Build`/`Bundle`, the optional-mirror `OverrideManifest`, and `Diagnostics`. Imports nothing from `src/security/` (no cycle). |
| `parse.zig` | Build-time loader: `parseAtBuild` (dir-scanning override selection), `parseAtBuildFromPaths` (argv-driven), `embedded()` (comptime `@import("zigware_manifest_zon")`), `listCapabilityIds`, `freeManifest`. |
| `validate.zig` | Post-merge validation; returns bool (never errors), appends diagnostics. |
| `merge.zig` | Base + per-OS override merge: borrow-or-pick, then deep-copy into gpa-owned state. |
| `fuses.zig` | Comptime fuse accessors from the embedded manifest; a comptime block locks them as compile-time-known. |
| `emit_effective.zig` | Build-time codegen **exe**: argv-driven, merges + validates + re-serializes the effective manifest to a `.zon` artifact. |
| `capabilities.zig` | Loads full `Capability` bodies from `src/grants/*.zon` (kept separate so the codegen module needn't import `src/security/`). |
| `schema_gen.zig` | Reflection-driven JSON-Schema emitter (Draft 2020-12). |

## Core types & notable defaults

`Manifest` = `identifier` (reverse-DNS), `productName`, `version` (SemVer), plus
`app`, `security`, `build`, `bundle`. Defaults that matter:

- `Window.show = false` (hidden until first paint, which avoids the white flash),
  `Window.url = null` (derive: `serveUrl` in dev, `app://` in prod).
- `Security.grants = &.{}` and all four `Fuses` `false` (deny by default).
- `Csp.*Src = &.{"'self'"}`: a strict baseline with no open hosts.

## The two manifest paths

**(a) Build-time codegen → `effective.zon`.** `emit_effective.zig` is an installed
exe. Given argv (`out`, `base path`, then per-OS override + capability paths) it
opens the manifest's directory, runs `parseAtBuild` (merge + validate + capability
enumeration), and re-serializes the merged `Manifest` via
`std.zon.stringify.serialize`. Input paths come from argv (never `cwd`) so the
build Run step's cache key is stable. The generated app `build.zig` runs this exe,
then wires the output as the anonymous import `zigware_manifest_zon` onto the
`zigware` module.

**(b) Runtime → `parse.embedded()`.** `embedded()` is just
`return @import("zigware_manifest_zon")`: the effective manifest resolved at
compile time, with zero runtime I/O. `app.zig` calls it once at startup.

> When the framework is consumed as a package, the consumer's `build.zig` runs
> `dep.artifact("emit_effective_manifest")` and adds `zigware_manifest_zon` onto
> `dep.module("zigware")`. See [cli.md](cli.md) and [app-and-assets.md](app-and-assets.md).

## Validation invariants

- **debugInspector only in Debug** (`validate.zig:179` region): set in any release
  mode → `inspector_in_release` error.
- **A `main` window is required**; window labels must be non-empty and unique.
- **Grant cross-check**: every `security.grants[i]` must correspond to a
  `src/grants/<id>.zon` file; a missing directory yields an empty set so all
  refs fail (`unknown_capability_ref`), failing closed.
- **Identifier** is reverse-DNS; **version** is SemVer; the macOS team id is
  alphanumeric (argv-injection guard); CSP defaults strict.
- `frontend.serveUrl` without `frontend.dev` is a warning, not an error.

## Dependencies & key decisions

- `types.zig`/`parse.zig`/`validate.zig`/`merge.zig` cross-import by path, so they
  must live in **one module per compiled artifact**. The framework builds them in
  several artifacts (app exe, codegen exe, tests). That works because the
  "one module per file" rule is per-artifact, not per-build.
- **Comptime fuses**: every fuse is a comptime constant, so the binary's real
  capability set is immutable and auditable.
- **Static-default-aware freeing**: `Manifest` carries comptime-literal default
  slices; `freeManifest`/`merge` check pointer identity against the default before
  freeing (a naive `std.zon.parse.free` would double-free the static defaults).
- Per-OS overrides are selected by scanning for `zigware.{macos,linux,windows}.zon`.
- The package **fingerprint** lives in CLI `init`, not here (see [cli.md](cli.md)).
