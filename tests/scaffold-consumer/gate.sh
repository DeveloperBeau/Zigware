#!/bin/sh
# Scaffold consumer gates. Run from the repo root.
set -eu
set -o pipefail 2>/dev/null || true

cd "$(dirname "$0")"

echo "gate: zig build dts (headless codegen against the package)"
zig build dts

echo "gate: dts exe links no Cocoa/WebKit"
if [ ! -f zig-out/bin/scaffold-consumer-dts ]; then
  echo "FAIL: dts binary not found at zig-out/bin/scaffold-consumer-dts"; exit 1
fi
cocoa=$(otool -L zig-out/bin/scaffold-consumer-dts | grep -c -E 'Cocoa|WebKit' || true)
if [ "$cocoa" -ne 0 ]; then
  echo "FAIL: dts exe links Cocoa/WebKit ($cocoa references)"; exit 1
fi

echo "gate: run exe embeds the consumer's own index.html"
zig build
if ! strings zig-out/bin/scaffold-consumer | grep -q 'ZWSENTINEL_SCAFFOLD_CONSUMER_INDEX'; then
  echo "FAIL: run exe does not embed the consumer index.html sentinel"; exit 1
fi

echo "gate: ReleaseFast consumer fails with the documented ban"
if ( cd ../release-ban-consumer && zig build 2>build.err ); then
  echo "FAIL: ReleaseFast build unexpectedly succeeded"; exit 1
fi
if ! grep -q 'Zigware ships ReleaseSafe or Debug only' ../release-ban-consumer/build.err; then
  echo "FAIL: ReleaseFast build failed for the wrong reason"; cat ../release-ban-consumer/build.err; exit 1
fi
rm -f ../release-ban-consumer/build.err
echo "ReleaseFast ban gate passed"

echo "all scaffold-consumer gates passed"
