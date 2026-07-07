# Building a macOS bundle

`zigware build` compiles a release binary and packages it into a macOS `.app`
(and a `.dmg`) under `zig-out/`.

## Frontends: node-based and static

Before compiling, `zigware build` runs the manifest's `frontend.build` command
(in `zigware.zon`), so a node-based frontend is built as part of packaging:

- **Node frontend** (React, Vue, Svelte, any bundler): set
  `frontend.build = "npm run build"` (and `frontend.outDir` to the build output
  directory). `zigware build` runs the build, then packages the produced output.
  The dev loop uses `frontend.dev` / `frontend.serveUrl`.
- **Static frontend** (plain HTML/JS/CSS, no build step): leave `frontend.build`
  unset and `frontend.dev`/`frontend.serveUrl` null. The committed files under
  `frontend/` are served and packaged as-is.

## Default: unsigned

With no flags, the bundle is UNSIGNED. It needs no Apple credentials and is
suitable for local use and testing. macOS Gatekeeper will warn when an unsigned
bundle is opened on another machine.

```
zigware build
```

## Signing and notarization (opt-in)

Signing and notarization are an opt-in extra step that uses YOUR own Apple
credentials. Nothing is hardcoded to any account.

- `zigware build --sign` code-signs the bundle.
- `zigware build --notarize` signs and notarizes it (notarization requires a
  signed bundle).

Supply your credentials through the environment (preferred for CI) or the
manifest:

- Signing identity: `APPLE_SIGNING_IDENTITY` (overrides the manifest), or
  `bundle.macos.signingIdentity` in `zigware.zon`.
- Notary credentials (either set):
  - API key: `APPLE_API_KEY`, `APPLE_API_ISSUER`, `APPLE_API_KEY_PATH`.
  - Apple ID: `APPLE_ID`, `APPLE_PASSWORD`, `APPLE_TEAM_ID`.

If you pass `--sign`/`--notarize` without the matching credentials, the build
stops with a clear error naming what is missing.
