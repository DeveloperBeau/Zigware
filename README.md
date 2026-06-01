# Zigware (PoC)

A web UI driving a Zig backend for heavy compute. Zigware binds WKWebView straight from Zig, with no Swift shim or third-party webview library.

## Status
PoC, macOS-only. A button kicks off a 300 MB SHA-256 in Zig on a worker thread, streams live progress, and returns the result while the window stays responsive.

## Run
    zig build run

## Test
    zig build test            # logic unit + integration tests
    bun test                  # JS shim contract + hardening + JS-eval round-trip
    bash scripts/coverage.sh  # kcov HTML report, or a documented fallback if kcov is absent

`zig build test --fuzz` does not work on the Zig 0.16.0_1 toolchain; see docs/SMOKE.md.

## Security posture
- `app://` custom scheme serving an embedded frontend, strict path allowlist (unknown path returns 404)
- strict CSP (`default-src 'self'; script-src 'self'`), zero inline JS
- command-name allowlist checked before any work runs
- every Zig-to-JS payload crosses as a JSON literal, never string-concatenated; the JS-eval round-trip test proves it
- bounded worker pool and bounded job queue
- per-job cancel flag wired through the pure hash path
- ordered shutdown: flip alive off, join workers, drain the main queue, free
- Web Inspector stays gated to debug builds

See `docs/SMOKE.md` for the manual verification checklist.
