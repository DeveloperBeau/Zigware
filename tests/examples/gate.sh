#!/bin/sh
# Example app build gates. Each example is a standalone package consumer with a
# relative path dependency on the framework (../..). Proves every example builds
# the run exe, generates frontend/bindings.d.ts, and passes its headless command
# tests and bridge integration test off the published package surface. Run from
# the repo root: sh tests/examples/gate.sh
set -eu
set -o pipefail 2>/dev/null || true

repo="$(pwd)"

for ex in crypto-vanilla crypto-react crypto-vue crypto-svelte notes; do
  proj="$repo/examples/$ex"
  echo "gate [$ex]: zig build (links the run exe against the package)"
  ( cd "$proj" && zig build )

  echo "gate [$ex]: zig build dts writes frontend/bindings.d.ts"
  ( cd "$proj" && zig build dts )
  if [ ! -f "$proj/frontend/bindings.d.ts" ]; then
    echo "FAIL [$ex]: zig build dts did not write frontend/bindings.d.ts"; exit 1
  fi

  echo "gate [$ex]: zig build test (headless command tests)"
  ( cd "$proj" && zig build test )

  echo "gate [$ex]: zig build integration-test (headless bridge round-trip)"
  ( cd "$proj" && zig build integration-test )
done

echo "all example gates passed"
