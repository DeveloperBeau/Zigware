# Window + platform / FFI (`src/window/`, `src/platform/`, `objc.zig`)

## Purpose

Manages native window lifecycle (create, show, focus, close) behind a
compile-time-checked backend interface, so Zig logic is decoupled from
Cocoa/WebKit (macOS) and from a test double (`NullBackend`). UI access is
single-threaded: only the main thread touches the backend; workers marshal back
through main-thread dispatch. Windows stay hidden until the page signals ready or
a fallback timer fires.

## Key files

| File | Responsibility |
|------|----------------|
| `platform/backend.zig` | The abstract backend interface + `assertBackend` comptime conformance check; shared error sets and lifecycle/navigation/response enums. |
| `platform/null.zig` | `NullBackend` test double: fake windows, deadline-based timers, eval logging, lifecycle replay. |
| `platform/macos/backend.zig` | `MacOSBackend`: NSApplication setup, `WKWebView` windows, GCD main-thread timers, association-based backend-pointer passing, an `alive` flag for late callbacks. |
| `platform/macos/scheme.zig` | `app://` `WKURLSchemeHandler` IMP; looks up the backend via association; synchronous asset response. |
| `platform/macos/webview.zig` | User-script injection and `evalJS` hop to the main thread. |
| `platform/macos/delegate.zig` | `NSApplicationDelegate` lifecycle bridging. |
| `objc.zig` | Objective-C FFI primitives: `id`/`SEL`/`Class`/`IMP`, the `objc_msgSend` cast-and-call pattern, class registration, `nsString`/`utf8`. |
| `window/manager.zig` | `WindowManager(B)`: window registry (`by_label`/`by_id` under a mutex), create/close/focus/setTitle/setSize/setFullscreen, show-fallback timers, injects `zigware.js` + `window.js` + the label constant. |
| `window/window.zig` | `WindowEntry` per-window state (incl. the fallback timer + context). |
| `window/lifecycle.zig` | `Lifecycle(B)`: quit policy and ordered shutdown (closeAll → terminate). |
| `window/commands.zig` | `WindowCommands(B)`: the `window.*` builtins with G4 label/host scope checks. |

## Backend abstraction

`assertBackend(B)` (comptime) requires `B` to declare `WindowHandle`/`WindowId`
and the full method set (create/destroy/show/focus/setTitle/setSize/setFullscreen,
`evalJS`, `injectUserScript`, `dispatchMain`/`dispatchMainAfter`/`cancelMainTimer`,
`pumpMain`, `run`, `terminate`, `setCallbacks`, …) plus the central error sets. A
missing or wrong-typed declaration is a compile error. `App(B)`, `WindowManager(B)`,
`Bridge(B)`, and `Lifecycle(B)` are all parameterized over the same `B`.

## Window layer

`WindowManager.create` allocates label/url/title and builds the per-window injected
scripts: `zigware.js`, `window.js`, a `label` constant wrapped via `protocol.jsString`
(the G6 injection boundary), and the dev-client script (included **only when the
`allow_eval` fuse is set**). It then arms a show-fallback timer via
`dispatchMainAfter`. Show-on-ready is serialized on the main thread:
`markReadyAndShow` (page-initiated) cancels the timer then transitions; if the
timer fires first, `fireMain` transitions instead. The transition is idempotent,
so cancel-vs-fire races are safe. Registry reads from worker threads
(`Bridge.emit`/`emitAll`) take the mutex only to copy a handle, never across the
`evalJS` seam call.

`Lifecycle` routes `window_all_closed` per policy (quit / keep-running / explicit
reopen) and runs an idempotent ordered shutdown.

## FFI boundary (`objc.zig`)

All Zig→Objective-C calls go through `objc.zig`; raw `id`/`SEL`/`Class` pointers
never leak into window/manager logic. The pattern is `msgSend(Fn)` casting
`objc_msgSend` to the caller's signature. IMPs wrap their bodies in an autorelease
pool. The backend pointer is passed to IMPs via `objc_setAssociatedObject`; IMPs
read it back and bail if it is nil. `deinit` nulls the associations **before**
freeing the backend, so a late callback sees nil and returns (no use-after-free,
reinforced by the `alive` atomic flag).

## `app://` scheme + asset serving

The macOS backend registers the `app` scheme on the `WKWebView` config. The scheme
IMP extracts the request path (bounded to the NUL terminator), calls
`dispatchSchemeRequest(.asset_scheme, path)` → the bridge's `onSchemeRequest` →
`assets.serveAsset` (see [app-and-assets.md](app-and-assets.md)), and writes the
response back to the `WKURLSchemeTask`.

## Threading model

- **Main thread**: the NSApplication loop, all window seam calls, and show-fallback
  timer callbacks.
- **Worker threads**: run commands, then `evalJS` by allocating a hop and
  dispatching to the main queue (retaining the webview, re-checking `alive`).
- **Timer seam** (`dispatchMainAfter`/`cancelMainTimer`): schedule, cancel, and
  fire all happen on the main thread, so they serialize without locks; after
  `cancelMainTimer` returns the work is guaranteed not to fire. `NullBackend` uses
  an in-process deadline queue driven by `pumpMain` for tests.

No hidden framework threads exist; timers only schedule work.

## Invariants

- Backend conformance is enforced at **compile time**.
- Single-threaded UI; brief mutex only for the registry, never across seam calls.
- Late-callback safety via association-nulling + `alive` flag.
- Shutdown order: `terminate()` flips `alive` and drains before `deinit` frees.
