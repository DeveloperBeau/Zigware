# App shell + assets + barrel (`app.zig`, `assets.zig`, `asset_table.zig`, `zigware.zig`)

## Purpose

The app shell ties a comptime manifest + a platform backend + windows + asset
serving + the command bridge into one running application. The barrel module
(`zigware.zig`) is the public API a package consumer imports.

## Key files

| File | Responsibility |
|------|----------------|
| `app.zig` | `App(Backend)` orchestrator: init/run/deinit, builds windows from the manifest, dev-URL override, routes inbound callbacks. |
| `assets.zig` | `serveAsset(path)`: `app://` path → embedded asset; `/`→`/index.html`; reserved-route + 404 fail-closed. |
| `asset_table.zig` | The asset table format (`Asset{path, body, mime}`, `table`); default entries via `@embedFile`. Replaced by `zigware build` / `-Dasset_table`. |
| `zigware.zig` | The public barrel: re-exports `App`, backends, `Bridge`, the command-author types, compute types, security, and manifest. |
| `app_catalog.zig` | Runtime permission catalog: app-declared permissions spliced onto the built-ins at comptime. |
| `main.zig` | The in-repo PoC app entry (selects the backend by OS; LIFO defer ensures `app.deinit` before `backend.deinit`). |

## `App(Backend)` lifecycle

`App` is generic over the backend `B` (`MacOSBackend` in production, `NullBackend`
in tests) and asserts the backend interface at comptime. `init`/`initWithCommands`:

1. `parse.embedded()` → the comptime manifest; collect window labels.
2. Build a `GrantTable`. `init` grants only `core:default`; `initWithCommands`
   synthesizes `app:*` grants for each declared command, preserving any scopes the
   app declared (e.g. a path-scoped `app:hashFile`). See [security.md](security.md).
3. `initWithConfig`: construct `WindowManager(B)` in place (stable address), create
   every manifest window, construct the `Bridge`, wire it to the manager, build the
   `Lifecycle` quit-policy state machine, and register inbound callbacks
   (`onSchemeRequest`, `onMessage`, `onLifecycle`, `onNavigation`).

`run()` delegates to the backend's blocking platform loop. `shutdown()` (from
`deinit` or lifecycle) is exactly-once via an atomic swap: close all windows,
terminate the backend, repoint inbound callbacks to fail-closed sentinels, drain
the main-thread queue, join the worker pool, then free.

**Dev-URL override** (`app.zig:28-50` region): compiled to `return null` in
release; in Debug it reads `ZIGWARE_DEV=1` + `ZIGWARE_DEV_URL` and applies the
override to the **`main` window only**. It does not widen navigation trust (that
flows through the navigation guard against granted origins).

## Asset serving

`serveAsset(path)` is pure: reject reserved routes (`protocol.isReservedRoute`),
alias `/`→`/index.html`, linear-scan `asset_table.table` for an exact match, return
200 + `@embedFile` body + mime, else 404. The macOS backend wires the `app://`
custom scheme to this (see [window-and-platform.md](window-and-platform.md)); the
`stream://` route is handled by the bridge for out-of-band binary
(see [bridge-and-commands.md](bridge-and-commands.md)). `zigware build` regenerates
the table from `frontend.outDir` and the app build wires it via `-Dasset_table`,
shadowing the framework default.

## The barrel (`zigware.zig`)

The public surface consumers import as `zigware`: `App`, `MacOSBackend`,
`NullBackend`, `Bridge`; the command-author types (`Ctx`, `Result`, `Async`,
`Channel`, `Bytes`, `CommandError`, `done`, `State`); compute sugar (`Sink`,
`CancelToken`, `Worker`, `ComputeError`); security (`capability`, `gates`,
`GrantTable`, `app_catalog`); and `manifest` + `parse`. Because the barrel roots
the framework, all internal path imports resolve within the one module instance.

## Invariants

- **Comptime manifest + static assets.** The only runtime URL override is the
  Debug-only dev URL for the `main` window.
- **Single UI thread.** Callbacks run on the platform main thread; brief
  `map_mutex` only for window registry insert/remove, never held across a seam call.
- **Show-on-ready.** Windows are created hidden and shown on the `__zigware_ready`
  signal or a fallback timer.
- **Fail closed.** Unknown/reserved asset paths → 404; post-shutdown callbacks hit
  sentinels, never a freed `App`.
- **Deinit order**: `app.deinit` runs before `backend.deinit` (LIFO defer in
  `main`), so no callback reaches the backend after app teardown.
