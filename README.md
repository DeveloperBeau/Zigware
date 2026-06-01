# Zigware (PoC)

A proof-of-concept desktop app: web UI + Zig backend for heavy compute, with
`WKWebView` bound directly from Zig (no Swift shim, no webview library). Built for
privacy and a safe-scaling compute model.

## Status
PoC, macOS-only. Demonstrates: button -> 300 MB SHA-256 in Zig on a worker thread ->
live progress -> result, UI never freezes.

## Run
    zig build run

## Test
    zig build test          # logic unit + integration tests (CI gate)
    bun test                # JS shim contract + hardening + JS-eval round-trip
    bash scripts/coverage.sh  # kcov HTML report if kcov installed, else documented fallback

(`zig build test --fuzz` is unavailable in the Zig 0.16.0_1 toolchain; see docs/SMOKE.md.)

## Security posture (seeded for the future framework)
- `app://` custom scheme serving an embedded frontend, with a strict path allowlist (unknown -> 404)
- strict CSP (`default-src 'self'; script-src 'self'`), zero inline JS
- command-name allowlist (frontend can only reach registered Zig commands)
- all Zig->JS data passed as JSON literals, never string-concatenated (proven by the JS-eval round-trip test)
- bounded worker pool AND bounded job queue (no unbounded resource growth under load)
- per-job cancel flag wired through the pure hash path
- ordered shutdown (alive=false -> join workers -> drain main queue -> free)
- dev affordances (Web Inspector) gated to debug builds only

See `docs/SMOKE.md` for the manual glue-verification checklist.
