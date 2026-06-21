# Zigware

A web UI driving a Zig backend for heavy compute. Zigware binds WKWebView straight from Zig, with no Swift shim or third-party webview library. macOS-only, early but past proof-of-concept: the framework is consumable as a Zig package and the CLI scaffolds, runs, and packages real apps.

## What you build with it

An app is a normal Zig project that depends on the framework as a package and supplies its own `zigware.zon` manifest, `src/main.zig`, command handlers, and frontend. The Zig side is the trusted host: it owns a native window, serves the frontend over a custom `app://` scheme, and exposes typed Zig commands the page invokes over a JSON bridge. Security is declarative and fail-closed: a manifest plus capability files, checked at compile time and again at the request gates.

See [docs/architecture/](docs/architecture/) for how the framework is built, subsystem by subsystem.

## The CLI

The CLI installs as both `zigware` and the short alias `zw`.

    zigware init <dir> --framework-path <path-to-this-checkout>   # scaffold a project
    zigware dev                                                   # run the dev loop (Debug)
    zigware build                                                 # package a signed release

`init` writes a normal Zig project (`build.zig`, `build.zig.zon` depending on the
framework, `zigware.zon`, `src/main.zig`, commands, frontend). Pre-release the
framework dependency is a relative path; pass `--framework-path` or set
`ZIGWARE_FRAMEWORK_PATH`. `dev` rebuilds and relaunches on source changes; `build`
compiles ReleaseSafe, injects a strict CSP, embeds the frontend, then signs,
notarizes, and builds a `.dmg`.

## Run the in-repo example

    zig build run

## Test

The aggregate `zig build test` step does **not** terminate on the current
toolchain. Run the per-suite steps instead:

    zig build test-init      # CLI scaffolding
    zig build test-app       # app shell / lifecycle
    zig build test-sec       # security regression
    zig build test-notes     # notes example integration
    zig build test-crypto    # crypto example round-trip
    zig build test-main      # CLI main wiring
    zig build test-build     # CLI build orchestrator

    bun test                 # JS shim contract + hardening + JS-eval round-trip
    bash scripts/coverage.sh # kcov HTML report, or a documented fallback if kcov is absent

CI (GitHub Actions, macOS) runs `zig fmt --check`, `zig build`, and the per-suite
tests on every PR to `develop`/`main`. `zig build test --fuzz` does not work on
the Zig 0.16.0 toolchain (a test-runner bug); each fuzz body ships a manual driver
instead. See [docs/SMOKE.md](docs/SMOKE.md) for the manual GUI checklist.

## Security posture

- `app://` custom scheme serving an embedded frontend, strict path allowlist (unknown path returns 404)
- strict CSP (`default-src 'self'; script-src 'self'`), zero inline JS
- command-name allowlist checked before any work runs
- every Zig-to-JS payload crosses as a JSON literal, never string-concatenated; the JS-eval round-trip test proves it
- bounded worker pool and bounded job queue
- per-job cancel flag wired through the pure hash path
- ordered shutdown: flip alive off, join workers, drain the main queue, free
- Web Inspector gated on the `debugInspector` fuse (rejected in release builds)

See [docs/secure-default.md](docs/secure-default.md) for the capability/gate model end to end.

## Branch model

- `develop` is the default branch and where active work integrates. Open PRs against it.
- `main` is the stable line. It stays pinned to the PoC until `develop` is ready to ship, at which point `develop` merges into `main`.
- Both branches are protected: changes land through a PR with one approving review; force-pushes and deletions are blocked.
