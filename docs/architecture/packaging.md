# Packaging (`src/package/`)

## Purpose

Turn a compiled release binary + the manifest into a signed, notarized, stapled
`.app` bundle and `.dmg`. Built over a tool-runner seam so the whole pipeline is
testable headlessly, with structured failure diagnostics carrying remediation.

## Key files

| File | Responsibility |
|------|----------------|
| `packager.zig` | The `package()` pipeline; `Artifacts`/`Arch` types; `configFromManifest`; credential resolution; post-stage Gatekeeper gates. |
| `bundle.zig` | Assemble the `.app` tree; write `Info.plist` (every value through `plistEscape`); icon via `iconutil` (`.png`) or copy (`.icns`). |
| `sign.zig` | `codesign --sign` + `--verify --strict` + advisory `spctl`; classify stderr (`cert_expired`, `keychain_locked`, `identity_not_found`); ad-hoc `-` drops hardened runtime. |
| `notarize.zig` | `xcrun notarytool submit --wait`, optional `notarytool log`, `stapler staple`; classify failures. |
| `dmg.zig` | Stage `.app` + `/Applications` symlink, `hdiutil create` (UDZO/HFS+), then re-sign + re-notarize the `.dmg`. |
| `config.zig` | `PackageConfig`, `configFromManifest` adapter, `resolveCredentials` (env-over-manifest), `validateConfig` (leading-dash / path-separator rejection). |
| `runner.zig` | The `Runner` seam over child-process exec: `SystemRunner` (prod) / `FakeRunner` (tests). |
| `diagnostics.zig` | `Diagnostic { code, title, detail, remediation }`; the `Code` enum; notary-result JSON parsing. |

## The `package()` pipeline

Preflight first (before any filesystem work): `validateConfig` then
`resolveCredentials`. Then four ordered stages, each shelling out through the
`Runner` seam:

1. **bundle**: create `Contents/MacOS` + `Resources`, copy the binary, write
   `Info.plist` (each field escaped via `plistEscape`), resolve the icon
   (`iconutil` or `.icns` copy).
2. **sign**: `codesign --force [--timestamp --options runtime] --sign <id>`, then
   `codesign --verify --strict`, then advisory `spctl --assess`. Hardened-runtime
   flags are skipped for the ad-hoc identity `-`.
3. **notarize** (when `notarize` on and not skipped): `notarytool submit --wait`;
   on `Invalid`, fetch the log and classify; on `Accepted`, `stapler staple`; then
   a hard `spctl --assess --type execute` gate.
4. **dmg**: stage, `hdiutil create`, re-sign + re-notarize the image, then a hard
   `spctl --assess --type open` gate.

A `defer` block runs CI temporary-keychain teardown on all paths. `package()`
returns a fully gpa-owned `Artifacts`.

## The Runner seam

`runner.zig` is a vtable (`run(argv) → RunResult{term,stdout,stderr}`).
`SystemRunner` wraps `std.process.run` with output limits (~64 MiB) and a 30-min
timeout, mapping `StreamTooLong`/`Timeout`/OOM to domain errors. `FakeRunner`
records every argv (for ordering assertions) and replays a scripted result queue,
so full-pipeline tests run with no real tools. Each stage builds argv via a pure
builder returning gpa-owned slices.

## Config & security

`configFromManifest` borrows manifest fields (`displayName` ← `bundle.displayName`
or `productName`; `bundleVersion` ← `bundle.bundleVersion` or `version`; icon, etc.).
`validateConfig` enforces reverse-DNS identifier, SemVer version, **rejects any
argv-bound value starting with `-`** (option-injection guard; the exact ad-hoc
identity `-` is the one allowed exception) and rejects `/`/`..` in filesystem
names. `resolveCredentials` prefers env over manifest: signing identity from
`APPLE_SIGNING_IDENTITY`; notary credentials API-key-first
(`APPLE_API_KEY`/`_ISSUER`/`_KEY_PATH`) then Apple-ID
(`APPLE_ID`/`APPLE_PASSWORD`/`APPLE_TEAM_ID`); all env values are duped and
leading-dash-checked. Secrets never enter a `Diagnostic` (API-key passes only a
path; the Apple-ID password is in the notarytool argv by necessity but is never
copied into diagnostics).

## Diagnostics

`Diagnostic { code, title (static), detail (gpa-owned captured output), remediation
(static) }`. The `Code` enum covers the spec set (missing-notary-credentials,
identity-not-found, cert-expired, hardened-runtime-required, notarization-rejected,
app-specific-password-required, keychain-locked, notary-timeout) plus
`unknown_tool_failure` and the three config codes. The failing stage dupes the
relevant stderr before freeing the `RunResult`; the caller frees `detail` after
rendering. This is a separate channel from the manifest `Diagnostics`.

## Dependencies & invariants

- Imports `zigware_manifest` (config only); consumed by `cli/main.zig`'s `runBuild`.
- **Signing identity required unless `skip_sign`**; **notarization on by default in
  production** (collapses to `.none` under `skip_notarize` or `notarize=false`).
- **Leading-dash rejection** at both config time and env-credential time.
- **Fail-fast ordering**: preflight before any FS work; each stage aborts before the
  next; Gatekeeper `spctl` gates are owned by `package()`, not the stages.
- **Ownership discipline**: inputs borrowed; the returned `Artifacts` fully duped
  (caller frees); credentials and argv freed on all paths; the signing identity is
  duped a second time into `Artifacts` to avoid a double-free with credential cleanup.
