#!/bin/sh
# Scaffold consumer gates. Run from the repo root.
set -eu

cd "$(dirname "$0")"

echo "gate: zig build dts (headless codegen against the package)"
zig build dts

echo "gate: dts exe links no Cocoa/WebKit"
cocoa=$(otool -L zig-out/bin/scaffold-consumer-dts | grep -c -E 'Cocoa|WebKit' || true)
if [ "$cocoa" -ne 0 ]; then
  echo "FAIL: dts exe links Cocoa/WebKit ($cocoa references)"; exit 1
fi

echo "gate: run exe embeds the consumer's own index.html"
zig build
if ! strings zig-out/bin/scaffold-consumer | grep -q 'ZWSENTINEL_SCAFFOLD_CONSUMER_INDEX'; then
  echo "FAIL: run exe does not embed the consumer index.html sentinel"; exit 1
fi

echo "all scaffold-consumer gates passed"
