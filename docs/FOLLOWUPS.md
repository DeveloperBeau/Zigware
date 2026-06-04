# Follow-ups (Zigware)

Known items that are not blockers for the current line. Each is safe under the headless test contract and is staged for verification when the relevant GUI build exists.

## macOS multi-window inbound attribution

The macOS backend keeps a single module-level `current_window_id` for inbound message attribution. With one window this is correct, but multi-window inbound `windowId` attribution on the real backend is unverified, and it cannot be tested headlessly. The window layer is correct against the seam contract: `NullBackend` implements `windowId(handle)` per handle, so attestation is exercised in the headless tests. This is an item for the macOS backend in sub-project A, not a window-lifecycle blocker. Verify it when the macOS multi-window GUI is exercised.

## emitAll snapshot cap

`emitAll` snapshots at most 32 live handles per call into a fixed stack buffer and logs a warning if the live set is larger, then truncates. An app with more than 32 simultaneous windows would miss emits to the windows past the cap. This is acceptable for the current line. If multi-dozen-window apps become real, raise the cap or switch to an allocating snapshot.

## Stale handle on emit after close

`emit` and `emitAll` resolve a handle under the map lock, then call `evalJS` on it outside the lock. A window closed between the snapshot and the eval therefore hands a stale handle to the seam. On `NullBackend` this is harmless: the unknown handle routes to the sentinel and does nothing. The macOS backend must DROP, not trap, an `evalJS` on a destroyed handle. This is the same drop-after-close discipline already established for the post-terminate message path. Verify it when the macOS multi-window GUI is exercised.

## Full Debug test suite runtime under the show-fallback watchdog

The show-fallback timer spawns one OS thread per window. A stress test that builds thousands of short-lived windows (the `sec_regression` manual fuzz drivers create a fresh `App` per iteration, 10000+ iterations) spawns and joins that many threads against the shared `std.Io`, which under the Debug testing allocator's per-allocation stack-trace capture pushes the full `zig build test` runtime past practical limits on a memory-constrained machine. The first mitigation is in place: `fallback_ms = 0` now skips the watchdog entirely (see `WindowManager.spawnWatchdog`), and the `sec_regression` Harness uses it, since those tests assert message-handling safety rather than window visibility. A deeper fix (a single shared timer thread instead of one-per-window, so window count no longer scales thread count) is the right long-term shape and is filed here for a dedicated pass; it is not specific to any one sub-project.
