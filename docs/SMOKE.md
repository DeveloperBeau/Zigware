# Manual Smoke Checklist (Zigware PoC)

The objc/WKWebView glue (objc.zig, platform_macos.zig, app.zig, scheme.zig) has no unit tests; it needs a live AppKit GUI session. Run these by hand on a Mac at a desktop session:

1. `zig build run`: a window opens showing the Zigware PoC UI, served from `app://localhost/index.html`.
2. Open Web Inspector (Develop > Web Inspector; debug builds set `inspectable`). The Console shows no Content-Security-Policy violations.
3. Click "Hash 300 MB in Zig". The progress bar advances 0 to 100%.
4. While the bar advances, drag the window around. It keeps responding, which proves the hash runs off the main thread.
5. On completion the page shows `SHA-256: <64 hex chars>`.
6. Check correctness: the deterministic 300 MB buffer (byte[i] = i & 0xff) hashes to the same value the unit tests assert for the chunked path.
7. Quit with Cmd-Q mid-hash. Expect a clean exit, no crash report in Console.app, and no allocator leak warnings on stderr. This exercises the applicationWillTerminate shutdown: flip alive off, join workers, drain the main queue, free.

Failure triage:
- CSP errors at step 2: JS leaked into index.html and must move back into app.js.
- Freeze at step 4: the worker-to-main hop is wrong (check dispatch_async_f / PlatformSink).
- Hash mismatch at step 6: a chunked-hash or hex bug the unit tests should have caught.
- Crash or leak at step 7: a shutdown-ordering bug.

## Automated coverage
- `zig build test` runs the logic unit + integration tests.
- `bun test` runs the JS shim contract + hardening + JS-eval round-trip over Zig-emitted escapes.
- `zig build test --fuzz` (corpus fuzzing) does not work on the Zig 0.16.0_1 toolchain, a test-runner compiler bug. The fuzz bodies still run once under plain `zig build test`, and explicit table-driven unit tests carry the adversarial coverage (see protocol.zig).
