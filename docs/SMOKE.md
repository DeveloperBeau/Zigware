# Manual Smoke Checklist (Zigware)

The macOS objc/WKWebView glue needs a live AppKit GUI session and has no unit tests. The files in scope are `src/objc.zig` and the six objc files under `src/platform/macos/` (everything except `origin.zig` and `schemeLogic.zig`, which are pure and tested headless). The bridge, app orchestration, asset serving, lifecycle shutdown ordering, shutdown idempotency, post-terminate message drops, window identity, navigation policy, the origin formatter, and the scheme path extractor are all covered headless through `App(NullBackend)`, `platform/macos/origin.zig`, and `platform/macos/schemeLogic.zig` under `zig build test`. Run the steps below by hand on a Mac at a desktop session.

1. `zig build run`: a window opens showing the Zigware UI, served from `app://localhost/index.html`.
2. Open Web Inspector (Develop > Web Inspector; the `debugInspector` fuse sets `inspectable`). The Console shows no Content-Security-Policy violations.
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

## Multi-window and quit policy (GUI only)

These cover the window-lifecycle paths that need a live AppKit session: ready-to-show first paint, runtime window creation, the keep-running quit policy, and reopen. Run them on a Mac once a multi-window GUI build exists.

13. Launch the app. The main window must appear only after its first paint, not as an empty white frame that then fills in. Watch for a white flash on open; there must be none. This verifies the ready-to-show flow holds the window hidden until the page signals ready.
14. Open Web Inspector and run `Zigware.Window.create({ label: "viewer", url: "app://localhost/index.html" })` in the Console. A second window opens and becomes visible once it paints, on the same ready-to-show path as the main window.
15. With the default quit policy (`keep_running_on_last_close`), close every window. The process must keep running and stay in the Dock. There must be no exit and no crash report in Console.app.
16. With the app still running and no windows open, click the Dock icon. This delivers `reopen`, which must recreate the default window. The new window appears ready-to-show, same as a fresh launch.
17. Rebuild with `quitOnLastWindowClosed: .quit_on_last_close` in the manifest. Open one window, then close it. Closing the last window must now quit the process cleanly: a clean exit, no crash report, and no allocator-leak warnings on stderr.
17a. Load a page that never signals ready (e.g. open the Console and run `Zigware.Window.create({ label: "slow", url: "app://localhost/index.html" })` against a build whose page omits the ready signal). The window must still appear on its own after the show-fallback delay, driven by the main-thread timer rather than a per-window thread. It must show exactly once, with no white flash and no second show.

## Web Inspector fuse (GUI only)

The inspector is now gated on the `debugInspector` fuse at compile time, not the build mode, so it has no headless coverage. Toggle the fuse in the manifest and confirm both directions in a Debug build on a Mac. (The manifest validator rejects `debugInspector: true` in any release mode, so the fuse-on case is exercised in Debug.)

18. Set `debugInspector: true` and build a Debug binary (`zig build install`). Launch it and open Develop > Web Inspector against the window. The inspector must attach.
19. Set `debugInspector: false` and build a Debug binary (`zig build install`). Launch it. Develop > Web Inspector must not attach to the window. This proves a Debug build no longer exposes the inspector when the fuse is off, so the gate follows the fuse and not `builtin.mode`.

## Packaging, signing, notarization (Developer-ID, GUI/cert only)

The packaging pipeline (`package()`: bundle assembly, codesign, notarytool, stapler, hdiutil) runs end-to-end headless over the record-and-drive fake runner, but the one path no fake can cover is a real Developer-ID round trip against Apple's signing and notary services. Run this once on a Mac that has a `Developer ID Application` certificate in the login keychain and a notary profile (App-Store-Connect key or an app-specific password) in the environment.

20. From a scaffolded project root, set the notary credentials in the environment (`APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID`, or the API-key trio) and the signing identity (`APPLE_SIGNING_IDENTITY`, or `bundle.macos.signingIdentity` in `zigware.zon`), then run `zigware build`. The build compiles the release binary, assembles the `.app`, signs it inside-out, submits it to the notary service with `--wait`, staples the ticket, builds the `.dmg`, and signs plus notarizes the dmg. Expect a clean exit and a final line reporting the `.app` and `.dmg` paths.
21. Assert Gatekeeper acceptance on the stapled disk image: `spctl --assess --type execute --verbose <out>/<App>.dmg`. The output must read `accepted` with `source=Notarized Developer ID`. A `rejected` result means the staple or notarization did not take; re-check the notary log the pipeline fetched on rejection.
22. Confirm no secret leaks to stdout/stderr: run step 20 again with stderr captured and `grep -i` the output for the app-specific password and any API-key contents. There must be zero matches. The pipeline duplicates credentials into a temp keychain and tears it down on both the success and failure paths; confirm `security list-keychains` no longer lists the temp keychain after the run.

Failure triage:
- `errSecInternalComponent` or an identity-not-found codesign error at step 20: the `Developer ID Application` cert is not in a keychain the signing session can reach, or `signingIdentity` does not match the certificate common name.
- Notary rejection at step 20: read the issue list the pipeline prints (fetched via `notarytool log`); the usual causes are a missing hardened-runtime flag or an unsigned nested binary.
- `rejected` at step 21 despite a successful step 20: the staple did not attach; re-run `xcrun stapler staple` by hand on the dmg and check for a network failure during stapling.

## Notes example: scoped hash with progress and cancel (GUI only)

These cover the `examples/notes/` app end to end on a Mac: streamed progress, cooperative cancel, the secure-default denial, and a signed `.app`. The headless integration test already proves the in-scope hash resolves and an out-of-scope path denies with `scope.path.no_match`; these steps confirm the live GUI and the packaged artifact.

23. Build and launch the example: `zig build install` puts the binary at `zig-out/bin/notes-example`; run it. A window opens showing the "Hash a file" UI served from `app://localhost/index.html`, with no Content-Security-Policy violations in the Web Inspector console.
24. Place a file under the app's `$APPDATA/notes/` directory. Enter its path and click "Hash". The progress bar advances 0 to 100% as `onStream` frames arrive (the bar reads `frame.pct`), and on completion the page shows `SHA-256: <64 hex chars>`. The progress must be monotonic, never jumping backward.
25. While a large file hashes, drag the window around. It keeps responding, proving the hash runs off the main thread.
26. Start hashing a large file, then click "Cancel" mid-run. The original invoke promise must settle with a `cancelled` rejection (the page shows "cancelled"), the progress bar stops advancing, and the worker stops promptly (within roughly one 64 KiB chunk). The UI returns to the ready state. There must be no crash and no leak warning on stderr.
27. Enter a path outside `$APPDATA/notes/**` (for example `../etc/passwd` or an absolute path elsewhere) and click "Hash". The invoke must reject with code `scope.path.no_match`, and the page shows "denied: that path is outside $APPDATA/notes/**". The file must never be opened (the denial happens at G4 before any file access).
28. Package the example into a signed `.app` and confirm Gatekeeper acceptance as in steps 20 to 21, against the example's bundle id (`com.zigware.notes`).

Failure triage:
- Stalled bar at step 24: the stream channel is broken; the progress now flows through `onStream`, not a DOM event.
- Cancel ignored at step 26: the captured id did not match the in-flight call, or the worker is not polling `sink.isCancelled()` between chunks.
- An in-scope path denied at step 24, or an out-of-scope path allowed at step 27: a G4 scope-matching regression; check that `$APPDATA` expansion resolves the fixture `notes/` dir and that the bridge extracts `path` from the same `args_json` the handler decodes.

## Automated coverage
- The per-suite test steps (`zig build test-init`/`test-app`/`test-sec`/`test-notes`/`test-crypto`/`test-main`/`test-build`) run the logic unit, integration, and headless end-to-end tests. They cover scheme serving (200/404/reserved), lifecycle shutdown, shutdown idempotency, post-terminate message drops, window identity, navigation policy, origin formatting, and scheme path extraction, all previously smoke-only. Run the per-suite steps rather than the aggregate `zig build test`, which does not terminate on the current toolchain. CI (GitHub Actions, macOS) runs `zig fmt --check`, `zig build`, and every per-suite step on each PR.
- `bun test` runs the JS shim contract, hardening, and JS-eval round-trip over Zig-emitted escapes.

## Manifest is build-embedded
The app manifest (`zigware.zon`, plus any per-OS overrides and the grant files under `src/grants/`) is build-embedded. `embedded()` is a comptime `@import` of the codegen's merged-and-validated `zigware.effective.zon` artifact, so a manifest change requires a rebuild. There is no runtime config read or parse path. To regenerate the effective manifest by hand, run `zig build emit-effective-manifest`.

## Capability gate: v0.1.0 demo state

The shipped `App` compiles a `GrantTable` from `core:default` only. The `sha256`, `echoBytes`, and `echo` commands are not in `core:default`, so the GUI "Hash 300 MB in Zig" demo (step 3 above) is now denied at the capability gate (G2) rather than completing. The invoke returns a structured `command.not_granted` error to the frontend instead of a hash result. This is the correct behavior: the gate is live and fail-closed.

The example app with real author-declared capabilities (including a `sha256` grant) will be rebuilt in sub-project H. Until then, the v0.1.0 smoke pass verifies three things: the window opens and the UI loads, the shim script is injected and `window.Zigware.invoke` is available, and an invoke attempt is rejected with a structured `command.not_granted` error rather than hanging or crashing. Step 3 no longer shows a completed hash or a progress bar; the expected result is a rejected invoke and a console-visible error object from the frontend error handler.

## Fuzz contract
`zig build test --fuzz` (corpus-guided fuzzing) does not work on the Zig 0.16.0 toolchain because of a known test-runner compiler bug. To compensate, every fuzz body ships a manual driver. Each manual driver runs at least 10000 iterations per `zig build test`, seeding `std.Random.DefaultPrng` from `std.testing.random_seed`, and also replays every seed file in `test/fuzz/corpus/`. The enforced contract is: each fuzz body runs >= 10000 iterations per `zig build test`. When the toolchain bug is fixed, the drivers stay and `--fuzz` is re-enabled to run the same corpus under coverage guidance.
