#!/bin/sh
# macOS bundling gate: `zigware build` (default, unsigned) produces a .app for a
# real project with no Apple credentials. Run from the repo root.
set -eu
set -o pipefail 2>/dev/null || true

repo="$(pwd)"

echo "gate: build the zigware CLI"
zig build
cli="$repo/zig-out/bin/zigware"
if [ ! -x "$cli" ]; then echo "FAIL: zigware CLI not found at $cli"; exit 1; fi

echo "gate: zigware build (unsigned) produces notes.app"
# No APPLE_* credentials set, so this exercises the credential-free unsigned path.
# notes uses a path dep (../.. in build.zig.zon) and resolves with no env var.
# Unset every credential var config.zig consults so a developer's ambient shell
# env cannot flip this onto the signing path.
( cd "$repo/examples/notes" && \
  env -u APPLE_SIGNING_IDENTITY \
      -u APPLE_ID -u APPLE_PASSWORD -u APPLE_TEAM_ID \
      -u APPLE_API_KEY -u APPLE_API_ISSUER -u APPLE_API_KEY_PATH \
  "$cli" build )

app="$repo/examples/notes/zig-out/Notes.app"
if [ ! -d "$app" ]; then echo "FAIL: bundle not produced at $app"; exit 1; fi
if [ ! -f "$app/Contents/Info.plist" ]; then echo "FAIL: Info.plist missing"; exit 1; fi
if [ ! -f "$app/Contents/MacOS/Notes" ]; then echo "FAIL: bundle executable missing"; exit 1; fi
# Unsigned: no _CodeSignature dir should be present.
if [ -d "$app/Contents/_CodeSignature" ]; then echo "FAIL: bundle unexpectedly signed"; exit 1; fi

echo "gate: node-based frontend (crypto-react) builds via npm and packages"
# Proves the node path end to end: zigware build runs the manifest's
# frontend.build (npm run build / Vite), then packages the built dist into a
# .app. Requires node + npm on the runner.
react="$repo/examples/crypto-react"
( cd "$react" && (npm ci || npm install) )
( cd "$react" && \
  env -u APPLE_SIGNING_IDENTITY -u APPLE_ID -u APPLE_PASSWORD -u APPLE_TEAM_ID \
      -u APPLE_API_KEY -u APPLE_API_ISSUER -u APPLE_API_KEY_PATH \
  "$cli" build )
# Bundle path confirmed: displayName "Crypto Demo (React)" -> Crypto Demo (React).app
rapp="$(find "$react/zig-out" -maxdepth 1 -name '*.app' -type d | head -1)"
if [ -z "$rapp" ] || [ ! -f "$rapp/Contents/Info.plist" ]; then
  echo "FAIL: node-frontend bundle not produced under $react/zig-out"; exit 1
fi
if [ ! -f "$rapp/Contents/MacOS/Crypto Demo (React)" ]; then echo "FAIL: crypto-react bundle executable missing"; exit 1; fi
# Unsigned: no _CodeSignature dir should be present.
if [ -d "$rapp/Contents/_CodeSignature" ]; then echo "FAIL: crypto-react bundle unexpectedly signed"; exit 1; fi
echo "node-frontend bundle gate passed ($rapp)"

echo "gate: zigware build --arch x86_64 produces an x86_64 bundle"
( cd "$repo/examples/notes" && \
  env -u APPLE_SIGNING_IDENTITY -u APPLE_ID -u APPLE_PASSWORD -u APPLE_TEAM_ID \
      -u APPLE_API_KEY -u APPLE_API_ISSUER -u APPLE_API_KEY_PATH \
  "$cli" build --arch x86_64 )
exe="$repo/examples/notes/zig-out/Notes.app/Contents/MacOS/Notes"
if ! file "$exe" | grep -q 'x86_64'; then
  echo "FAIL: --arch x86_64 did not produce an x86_64 binary"; file "$exe"; exit 1
fi
echo "arch selection gate passed"

echo "gate: zigware build --arch universal produces a universal binary"
( cd "$repo/examples/notes" && \
  env -u APPLE_SIGNING_IDENTITY -u APPLE_ID -u APPLE_PASSWORD -u APPLE_TEAM_ID \
      -u APPLE_API_KEY -u APPLE_API_ISSUER -u APPLE_API_KEY_PATH \
  "$cli" build --arch universal )
exe="$repo/examples/notes/zig-out/Notes.app/Contents/MacOS/Notes"
archs="$(lipo -archs "$exe" 2>/dev/null || echo '')"
case "$archs" in
  *arm64*x86_64*|*x86_64*arm64*) echo "universal gate passed ($archs)" ;;
  *) echo "FAIL: expected a universal (arm64 + x86_64) binary, got: $archs"; exit 1 ;;
esac

echo "all bundle gates passed"
