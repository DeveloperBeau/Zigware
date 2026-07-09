# Zigware Architecture

This directory documents how the Zigware framework is built, one file per subsystem.
Each doc is a map for contributors: what the subsystem owns, its key files, public
surface, dependencies, and the invariants that must not be broken. Line references
(`file:line`) point at the source as of this writing; treat them as signposts, not
guarantees. Verify against the code before trusting a specific line.

## What Zigware is

A framework for building native macOS desktop apps with a web frontend. The Zig
side is the trusted host: it owns a native window (Cocoa/WebKit), serves the
frontend over a custom `app://` scheme, and exposes strongly-typed Zig "commands"
the frontend invokes over a JSON bridge. Security is declarative and fail-closed:
a manifest (`zigware.zon`) plus capability files decide what each window may do,
enforced largely at compile time.

An app is a normal Zig project that depends on the framework as a package and
provides its own `zigware.zon`, `src/main.zig`, commands, and frontend. The
`zigware` CLI (`zw` for short) scaffolds, runs (`dev`), and packages (`build`) it.

## System map

```
                         zigware.zon (+ src/grants/*.zon)
                                      │  build-time codegen
                                      ▼
   ┌─────────┐   zig build   ┌──────────────────┐   embeds   ┌──────────────┐
   │   CLI    │ ────────────▶ │ effective manifest│ ─────────▶ │ App(Backend) │
   │ init/dev │               │  (comptime const) │            │   shell      │
   │ /build   │               └──────────────────┘            └──────┬───────┘
   └─────────┘                                                        │ builds
        │ packages                                                    ▼
        ▼                                            ┌─────────────────────────┐
   .app / .dmg                                       │ WindowManager + Backend  │
   (sign/notarize)                                   │ (Cocoa/WebKit | Null)    │
                                                     └───────────┬─────────────┘
                                  app:// asset requests          │ webview
                                  ◀──────────  serveAsset  ──────┤
                                                                 │ JSON messages
   frontend (webview) ── Zigware.invoke() ──▶ Bridge ── gates ──▶ Registry ──▶ command
                       ◀── _resolve/_stream ── (G1..G6)           (sync | worker pool)
                                                  │
                                          Security: capabilities + fuses + CSP
```

## Subsystems

| Doc | Subsystem | One-liner |
|-----|-----------|-----------|
| [cli.md](cli.md) | CLI (`src/cli/`) | `init`/`dev`/`build` verbs over DI seams; scaffolding, dev loop, release orchestration. |
| [manifest.md](manifest.md) | Manifest (`src/manifest/`) | `zigware.zon` → validated, comptime-embedded config; build-time codegen + runtime `embedded()`. |
| [app-and-assets.md](app-and-assets.md) | App shell + assets (`app.zig`, `assets.zig`, `zigware.zig`) | `App(Backend)` lifecycle, `app://` asset serving, the public barrel module. |
| [window-and-platform.md](window-and-platform.md) | Window + platform/FFI (`src/window/`, `src/platform/`, `objc.zig`) | Native window lifecycle over a compile-checked backend seam; Objective-C FFI. |
| [bridge-and-commands.md](bridge-and-commands.md) | Bridge + command surface (`bridge.zig`, `commandContext.zig`, `protocol.zig`, `registry.zig`) | How the frontend invokes typed Zig commands; wire protocol, dispatch, streaming, dts codegen. |
| [compute.md](compute.md) | Compute/async (`compute.zig`, `jobs.zig`) | Off-main worker pool, cancellation, progress/binary streaming. |
| [security.md](security.md) | Security (`src/security/`, fuses, CSP) | Least-privilege, fail-closed: capabilities, gates (G1-G6), fuses, strict CSP. |
| [packaging.md](packaging.md) | Packaging (`src/package/`) | Compiled binary + manifest → signed, notarized `.app`/`.dmg`. |

## Cross-cutting principles

- **Fail closed.** Every security decision defaults to deny: unknown command, untrusted
  origin, unresolvable path, missing capability → denied. See [security.md](security.md).
- **Comptime where it counts.** The manifest, fuses, command registry, and asset table
  are resolved at compile time, so an auditor reads the binary's real attack surface.
- **Single UI thread.** Only the main thread touches the backend/windows. Command work
  runs on a bounded worker pool and marshals results back through one `evalJS` choke
  point. No hidden framework threads. See [compute.md](compute.md), [window-and-platform.md](window-and-platform.md).
- **Dependency-injection seams.** Child-process spawning, the compile step, the dev-URL
  probe, the file watcher, and the packaging tool-runner are all vtable seams so the
  logic is testable over fakes. See [cli.md](cli.md), [packaging.md](packaging.md).
- **One injection boundary for JS.** All user bytes entering a JS string go through
  `protocol.jsString` / `writeJsonAsJsLiteral` (G6). See [bridge-and-commands.md](bridge-and-commands.md).
