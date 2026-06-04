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
