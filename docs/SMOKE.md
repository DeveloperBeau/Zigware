# Zigware PoC — Manual Smoke Checklist

The objc/WKWebView glue (objc.zig, platform_macos.zig, app.zig, scheme.zig) is not
unit-tested (needs a live AppKit GUI session). Verify by hand on a Mac at a desktop session:

1. `zig build run` -> a window opens showing the Zigware PoC UI (served from `app://localhost/index.html`).
2. Open Web Inspector (Develop > Web Inspector; available because debug builds set `inspectable`).
   The Console must show ZERO Content-Security-Policy violations.
3. Click "Hash 300 MB in Zig" -> the progress bar advances 0 -> 100%.
4. WHILE the bar is advancing, drag the window around -> it stays fully responsive
   (proves the hash runs off the main thread).
5. On completion the page shows `SHA-256: <64 hex chars>`.
6. Correctness: the deterministic 300 MB buffer (byte[i] = i & 0xff) must hash to the
   same value the unit tests assert for the chunked path.
7. Quit via Cmd-Q mid-hash -> clean exit, no crash report in Console.app, no allocator
   leak warnings on stderr (exercises the applicationWillTerminate ordered shutdown:
   alive=false -> join workers -> drain main queue -> free).

Failure triage:
- CSP errors in step 2 -> JS leaked into index.html (must stay in app.js).
- Freeze in step 4 -> worker->main hop is wrong (dispatch_async_f / PlatformSink).
- Hash mismatch in step 6 -> chunked hash/hex bug (unit tests should have caught it).
- Crash/leak on step 7 -> shutdown ordering bug.

## Automated coverage notes
- `zig build test` runs all logic unit + integration tests (this is the CI gate).
- `bun test` runs the JS shim contract + hardening + JS-eval round-trip over Zig-emitted escapes.
- NOTE: `zig build test --fuzz` (corpus-driven fuzzing) is unavailable in the Zig 0.16.0_1
  toolchain (a test-runner compiler bug). The fuzz test bodies still execute once under
  plain `zig build test`; adversarial coverage is additionally pinned by explicit
  table-driven unit tests (see protocol.zig).
