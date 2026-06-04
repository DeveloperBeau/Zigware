# Follow-ups (Zigware)

Known items that are not blockers for the current line. Each is safe under the headless test contract and is staged for verification when the relevant GUI build exists.

## macOS multi-window inbound attribution

The macOS backend keeps a single module-level `current_window_id` for inbound message attribution. With one window this is correct, but multi-window inbound `windowId` attribution on the real backend is unverified, and it cannot be tested headlessly. The window layer is correct against the seam contract: `NullBackend` implements `windowId(handle)` per handle, so attestation is exercised in the headless tests. This is an item for the macOS backend in sub-project A, not a window-lifecycle blocker. Verify it when the macOS multi-window GUI is exercised.

## emitAll snapshot cap

`emitAll` snapshots at most 32 live handles per call into a fixed stack buffer and logs a warning if the live set is larger, then truncates. An app with more than 32 simultaneous windows would miss emits to the windows past the cap. This is acceptable for the current line. If multi-dozen-window apps become real, raise the cap or switch to an allocating snapshot.

## Stale handle on emit after close

`emit` and `emitAll` resolve a handle under the map lock, then call `evalJS` on it outside the lock. A window closed between the snapshot and the eval therefore hands a stale handle to the seam. On `NullBackend` this is harmless: the unknown handle routes to the sentinel and does nothing. The macOS backend must DROP, not trap, an `evalJS` on a destroyed handle. This is the same drop-after-close discipline already established for the post-terminate message path. Verify it when the macOS multi-window GUI is exercised.

## Show-fallback runs on a main-thread timer (resolved)

The show-fallback no longer spawns any OS thread. It is a main-thread timer scheduled through the platform seam (`dispatchMainAfter` / `cancelMainTimer`): only the main/UI thread touches the backend, so the framework spawns no hidden threads. On macOS the timer is a one-shot GCD dispatch source whose cancellation is a hard guarantee (a cancelled source never fires); on `NullBackend` it is a deadline entry that `pumpMain` fires, with a `fireTimers` test helper to trigger it deterministically. Scheduling, cancellation, and firing all happen on the main thread, so cancel-vs-fire is serialized and the timer's ctx is freed exactly once. This retires the earlier one-thread-per-window concern: window count no longer scales thread count, and the `sec_regression` fuzz drivers can keep `fallback_ms = 0` simply to skip pointless per-iteration timer work, not to avoid thread explosion.

## A scaffolded project cannot yet build into a full app (framework-as-package)

`zigware init` produces a project whose `zig build dts` works (type bindings are generated from `src/commands` via a vendored `command_ctx`/`emit_dts`/`protocol` exposed as a named `zigware` module). What it cannot yet do is compile into a running app: `_shared/build.zig` roots the app at a `src/main.zig` that no template ships and links Cocoa/WebKit against a frontend dist that only exists after the frontend build runs. The root cause is that Zigware is not consumable as a dependency: `build.zig.zon` has empty `.dependencies` and `build.zig` exports no modules, so a generated project has no way to `@import` the framework. Closing this needs a packaging decision (expose Zigware as a published module via `addModule`/the package manager, or vendor the whole framework into each scaffold) and a real app `src/main.zig` template that wires the manifest, command registry, and window. This is the packaging boundary that sub-project G owns; the CLI `build` verb already does everything up to the final `zig build` (manifest read, frontendDist walk, CSP injection, artifact mapping), so only the framework-link step is blocked.

## Packaging: the CI certificate-import keychain lane is scaffolded, not wired

`diagnostics.zig` defines a `keychain_locked` code whose remediation references importing `$APPLE_CERTIFICATE` (base64 `.p12`) into a temporary keychain, and `package()` carries a `defer` keychain-teardown hook. Neither is actually implemented in v0.1.0: nothing reads the `.p12`/`.p8` bytes (only the `.p8` PATH reaches the notarytool argv), nothing creates or imports into a keychain, and the teardown `defer` only flips a test flag. This is correct and safe for local signing (the developer's login keychain already holds the identity), but a CI runner with no persistent keychain needs the import lane built: read `$APPLE_CERTIFICATE` + `$APPLE_CERTIFICATE_PASSWORD`, `security create-keychain` a temp keychain, `security import` the cert, unlock it, and make the teardown a real `security delete-keychain` in the `defer`. No secret may reach a log. Until then, signing in CI requires a pre-provisioned keychain.

## Developer-facing managed async threads

Only the command bridge's internal worker pool (`jobs.zig`) runs work off the main thread today, and it is not a public API. The framework should offer a developer-facing way to run async work on managed, directable threads (so application code never spawns ad-hoc threads and never touches the UI off the main thread). This is net-new public surface, not owned by any current sub-project; filed here as a design direction.
