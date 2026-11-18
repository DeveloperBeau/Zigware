#!/bin/sh
# URL+hash consumption gate: proves an EXTERNAL project can fetch the packaged
# framework by url+hash and build against it (the in-repo path-mode examples
# cannot catch a .paths-completeness gap; this does). Uses a LOCAL tarball so no
# published tag or network is needed. Archives HEAD (committed state). Run from
# the repo root.
set -eu
set -o pipefail 2>/dev/null || true

repo="$(pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "gate: archive the framework tree (GitHub serves the tag tarball the same way)"
git archive --format=tar.gz --prefix=zigware/ -o "$work/zigware.tar.gz" HEAD

echo "gate: throwaway consumer from the scaffold-consumer fixture, dep via fetch"
cp -R "$repo/tests/scaffold-consumer" "$work/consumer"
rm -rf "$work/consumer/zig-out" "$work/consumer/.zig-cache" "$work/consumer/gate.sh"
cd "$work/consumer"
# Drop the relative-path dep; zig fetch --save writes the url+hash form.
perl -0pi -e 's/\s*\.zigware = \.\{ \.path = "\.\.\/\.\." \},//' build.zig.zon

echo "gate: zig fetch --save the local tarball (writes .url + .hash)"
# zig fetch writes a local file:// URL here, but the build resolves the dep from
# the Zig global cache BY HASH, which is the identical mechanism a real
# https://github.com/.../vX.Y.Z.tar.gz URL uses. The local tarball just removes
# the need for a published tag or network in the gate.
zig fetch --save=zigware "$work/zigware.tar.gz"
if ! grep -q '\.hash = "zigware-0\.2\.0-' build.zig.zon; then
  echo "FAIL: fetch did not record a zigware-0.2.0 hash"; cat build.zig.zon; exit 1
fi

echo "gate: build the consumer against the FETCHED package"
zig build
if [ ! -f zig-out/bin/scaffold-consumer ]; then
  echo "FAIL: consumer did not build against the fetched package"; exit 1
fi
# The dts (headless) exe must also resolve off the fetched surface.
if [ ! -f zig-out/bin/scaffold-consumer-dts ]; then
  echo "FAIL: dts exe did not build against the fetched package"; exit 1
fi

echo "all fetch-consumer gates passed"
