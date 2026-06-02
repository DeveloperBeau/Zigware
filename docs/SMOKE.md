# Manual Smoke Checklist (Zigware)

The macOS objc/WKWebView glue needs a live AppKit GUI session and has no unit tests. The files in scope are `src/objc.zig` and the six objc files under `src/platform/macos/` (everything except `origin.zig` and `scheme_logic.zig`, which are pure and tested headless). The bridge, app orchestration, asset serving, lifecycle shutdown ordering, shutdown idempotency, post-terminate message drops, window identity, navigation policy, the origin formatter, and the scheme path extractor are all covered headless through `App(NullBackend)`, `platform/macos/origin.zig`, and `platform/macos/scheme_logic.zig` under `zig build test`. Run the steps below by hand on a Mac at a desktop session.

1. `zig build run`: a window opens showing the Zigware UI, served from `app://localhost/index.html`.
2. Open Web Inspector (Develop > Web Inspector; debug builds set `inspectable`). The Console shows no Content-Security-Policy violations.
3. Click "Hash 300 MB in Zig". The demo calls `window.Zigware.invoke("sha256", { megabytes: 300 }, { onStream })`. The progress bar advances 0 to 100% as each `onStream` frame arrives (the bar reads `frame.pct`). Progress now flows through the invoke's `onStream` callback, not the retired `zig:progress` CustomEvent, so a stalled bar means the stream channel, not the old event, is broken. The promise resolves with the result object and the page reads `r.hash` from it.
4. While the bar advances, drag the window around. It keeps responding, which proves the hash runs off the main thread.
5. On completion the page shows `SHA-256: <64 hex chars>`, matching the value the unit tests assert for the chunked path.
6. Quit with Cmd-Q mid-hash. Expect a clean exit. There must be no crash report in Console.app and no allocator-leak warnings on stderr. This exercises `applicationWillTerminate:` mapping to `onLifecycle(.will_terminate)` and the App's ordered shutdown (terminate, join workers, drain the main queue).
7. Run the app under Instruments (Leaks template) and repeat steps 3 through 6 a few times. Expect zero leaks from the scheme handler and the evalJS hop path.

Failure triage:
- CSP errors at step 2: JS leaked into index.html; move it back into app.js.
- Freeze at step 4: the worker-to-main hop is wrong; check `platform/macos/webview.zig` and `platform/macos/dispatch.zig`.
- Missing shim at step 3 (invoke undefined): user-script injection ordering broke. The boot shim must go in via `WindowOpts.user_scripts` and be added to the UCC before `loadRequest:` in `MacOSBackend.createWindow`.
- Hash mismatch at step 5: a chunked-hash or hex bug the unit tests should have caught. The 300 MB demo stays valid because `MAX_MEGABYTES` is 512, so 300 is not clamped and the smoke hash oracle still matches.
- Crash or leak at step 6: a shutdown-ordering bug in `App.shutdown`.

## Memory-safety runtime checks (GUI only)

These cover the macOS backend paths a memory-safety review flagged as having no automated coverage. They need a live GUI session, so run them here.

8. Run under Instruments Allocations, or set `MallocStackLogging=1`. Open a window, then close it. Confirm there is no net growth in NSString, NSURL, or NSError instances across the cycle. This checks the autorelease-pool fix in init and createWindow.
9. Build or launch with `NSZombieEnabled=YES`. Repeat the open/close cycle. Confirm no zombie messages. This catches any over-release of the objects the backend releases explicitly: cfg, ucc, handler, request, response, nsjs, and userScript.
10. Use an Address-Sanitizer build, or keep `NSZombieEnabled=YES`. From a worker thread, fire a burst of evalJS while you trigger window-close or quit at the same time. Confirm no crash and no zombie webview access. This exercises the worker-to-main Hop alive-recheck plus its retain/release pairing.
11. Open a window at a non-default size and toggle `setContentSize:`. Confirm the geometry is correct. A wrong NSRect or NSSize struct-ABI cast would garble the frame.
12. Launch with a deliberately malformed initial URL. Confirm the nil-URL guard logs and skips the load instead of crashing. There must be no ObjC exception and no crash. To find the guard log line, run the app with stderr captured and `grep -F 'createWindow: malformed url, skipping initial loadRequest:'` over the output.

## Automated coverage
- `zig build test` runs the logic unit, integration, and headless end-to-end tests. This now covers scheme serving (200/404/reserved), lifecycle shutdown, shutdown idempotency, post-terminate message drops, window identity, navigation policy, origin formatting, and scheme path extraction, all previously smoke-only.
- `bun test` runs the JS shim contract, hardening, and JS-eval round-trip over Zig-emitted escapes.

## Manifest is build-embedded
The app manifest (`zigware.zon`, plus any per-OS overrides and the capability files under `src/capabilities/`) is build-embedded. `embedded()` is a comptime `@import` of the codegen's merged-and-validated `zigware.effective.zon` artifact, so a manifest change requires a rebuild. There is no runtime config read or parse path. To regenerate the effective manifest by hand, run `zig build emit-effective-manifest`.

## Capability gate — v0.1.0 demo state

The shipped `App` compiles a `GrantTable` from `core:default` only. The `sha256`, `echoBytes`, and `echo` commands are not in `core:default`, so the GUI "Hash 300 MB in Zig" demo (step 3 above) is now denied at the capability gate (G2) rather than completing. The invoke returns a structured `command.not_granted` error to the frontend instead of a hash result. This is the correct behavior: the gate is live and fail-closed.

The example app with real author-declared capabilities (including a `sha256` grant) will be rebuilt in sub-project H. Until then, the v0.1.0 smoke pass verifies three things: the window opens and the UI loads, the shim script is injected and `window.Zigware.invoke` is available, and an invoke attempt is rejected with a structured `command.not_granted` error rather than hanging or crashing. Step 3 no longer shows a completed hash or a progress bar; the expected result is a rejected invoke and a console-visible error object from the frontend error handler.

## Fuzz contract
`zig build test --fuzz` (corpus-guided fuzzing) does not work on the Zig 0.16.0 toolchain because of a known test-runner compiler bug. To compensate, every fuzz body ships a manual driver. Each manual driver runs at least 10000 iterations per `zig build test`, seeding `std.Random.DefaultPrng` from `std.testing.random_seed`, and also replays every seed file in `test/fuzz/corpus/`. The enforced contract is: each fuzz body runs >= 10000 iterations per `zig build test`. When the toolchain bug is fixed, the drivers stay and `--fuzz` is re-enabled to run the same corpus under coverage guidance.
