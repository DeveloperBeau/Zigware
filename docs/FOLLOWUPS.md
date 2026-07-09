# Follow-ups (Zigware)

Known items that are not blockers for the current line. Each is safe under the headless test contract and is staged for verification when the relevant GUI build exists.

## macOS multi-window inbound attribution

The macOS backend keeps a single module-level `current_window_id` for inbound message attribution. With one window this is correct, but multi-window inbound `windowId` attribution on the real backend is unverified, and it cannot be tested headlessly. The window layer is correct against the seam contract: `NullBackend` implements `windowId(handle)` per handle, so attestation is exercised in the headless tests. This is an item for the macOS backend in sub-project A, not a window-lifecycle blocker. Verify it when the macOS multi-window GUI is exercised.

## emitAll snapshot cap

`emitAll` snapshots at most 32 live handles per call into a fixed stack buffer and logs a warning if the live set is larger, then truncates. An app with more than 32 simultaneous windows would miss emits to the windows past the cap. This is acceptable for the current line. If multi-dozen-window apps become real, raise the cap or switch to an allocating snapshot.

## Stale handle on emit after close

`emit` and `emitAll` resolve a handle under the map lock, then call `evalJS` on it outside the lock. A window closed between the snapshot and the eval therefore hands a stale handle to the seam. On `NullBackend` this is harmless: the unknown handle routes to the sentinel and does nothing. The macOS backend must DROP, not trap, an `evalJS` on a destroyed handle. This is the same drop-after-close discipline already established for the post-terminate message path. Verify it when the macOS multi-window GUI is exercised.

## Packaging: the CI certificate-import keychain lane is scaffolded, not wired

`diagnostics.zig` defines a `keychain_locked` code whose remediation references importing `$APPLE_CERTIFICATE` (base64 `.p12`) into a temporary keychain, and `package()` carries a `defer` keychain-teardown hook. Neither is implemented in v0.1.0: nothing reads the `.p12`/`.p8` bytes (only the `.p8` PATH reaches the notarytool argv), nothing creates or imports into a keychain, and the teardown `defer` only flips a test flag. This is correct and safe for local signing (the developer's login keychain already holds the identity), but a CI runner with no persistent keychain needs the import lane built: read `$APPLE_CERTIFICATE` + `$APPLE_CERTIFICATE_PASSWORD`, `security create-keychain` a temp keychain, `security import` the cert, unlock it, and make the teardown a real `security delete-keychain` in the `defer`. No secret may reach a log. Until then, signing in CI requires a pre-provisioned keychain.

## App.init must consume loaded capabilities and resolve a real app-data base

The live scoped-path engine is fully wired and proven: a manifest capability that grants an app-declared permission (a `commandsAllow` plus a path `scopeAllow`) flows through the runtime catalog into the grant table, the bridge extracts the command's path argument with the handler's own decoder, and G4 denies an out-of-scope path with `scope.path.no_match` (the integration test exercises both halves). What is NOT yet wired is `App.init` consuming it: `app.zig` still compiles a hardcoded `core:default`-only capability and never calls `loadCapabilities`, and it passes `appdata = "."` rather than a resolved per-app data directory. This is fail-closed today and not exploitable (a live app shipping a scoped command is denied at G2/G3 by deny-by-default, and no `core:default` permission declares a path scope so the `"."` base is never dereferenced), so the example app's scoped feature works only in the headless test (via a hand-built grant), not as a shipped GUI app. Closing it needs two pieces before any real app ships a scoped command: `App.init` building its capability set from `loadCapabilities` (the parsed permission lists), and a platform app-data/known-folder resolver to supply the real `$APPDATA` base (only the `$APPDATA`/`$HOME` token expander exists today; nothing resolves the absolute folder). Keep one capability per window until the multi-cap merge hole is closed.

## Developer-facing managed async threads

Only the command bridge's internal worker pool (`jobs.zig`) runs work off the main thread today, and it is not a public API. The framework should offer a developer-facing way to run async work on managed, directable threads (so application code never spawns ad-hoc threads and never touches the UI off the main thread). This is net-new public surface, not owned by any current sub-project; filed here as a design direction.
