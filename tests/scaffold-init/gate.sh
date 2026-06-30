#!/bin/sh
# End-to-end scaffold gate. Scaffolds each template through the built CLI with a
# path dependency back to this repo, then exercises the addApp build surfaces.
# Run from the repo root: sh tests/scaffold-init/gate.sh
set -eu
set -o pipefail 2>/dev/null || true

repo="$(pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "gate: build the CLI (embeds the current template tree)"
zig build

for fw in vanilla react vue svelte; do
  proj="$work/zw-$fw"
  echo "gate: scaffold $fw at $proj"
  "$repo/zig-out/bin/zigware" init "$proj" --template "$fw" --framework-path "$repo"

  echo "gate [$fw]: zig build dts (headless codegen) writes bindings.d.ts"
  ( cd "$proj" && zig build dts )
  if [ ! -f "$proj/frontend/bindings.d.ts" ]; then
    echo "FAIL [$fw]: zig build dts did not write frontend/bindings.d.ts"; exit 1
  fi

  echo "gate [$fw]: zig build links the run exe"
  ( cd "$proj" && zig build )
  if [ ! -f "$proj/zig-out/bin/zw-$fw" ]; then
    echo "FAIL [$fw]: run exe zig-out/bin/zw-$fw not produced"; exit 1
  fi
done

echo "gate [vanilla]: zigware build stages the CSP-injected asset_table (release path)"
proj="$work/zw-vanilla"
# zigware build always attempts codesign + notarize after the release compile;
# on an unconfigured host (no signing identity / empty notary creds) that step
# exits nonzero. The asset_table staging (src/cli/build.zig step 4) and the
# release exe (step 5) are both produced BEFORE packaging, so tolerate the
# packaging failure and assert the pre-packaging artifacts directly. The staged
# dir is out_dir/staged with out_dir = "zig-out" (src/cli/main.zig:201,
# src/cli/build.zig:28), i.e. zig-out/staged/asset_table.zig.
( cd "$proj" && "$repo/zig-out/bin/zigware" build ) || true
if [ ! -f "$proj/zig-out/staged/asset_table.zig" ]; then
  echo "FAIL [vanilla]: staged asset_table.zig not emitted at zig-out/staged/"; exit 1
fi
if ! grep -q '@embedFile("index.html")' "$proj/zig-out/staged/asset_table.zig"; then
  echo "FAIL [vanilla]: staged asset_table.zig missing the colocated index.html embed"; exit 1
fi
if [ ! -f "$proj/zig-out/bin/zw-vanilla" ]; then
  echo "FAIL [vanilla]: release exe zig-out/bin/zw-vanilla not produced"; exit 1
fi

echo "all scaffold-init gates passed"
