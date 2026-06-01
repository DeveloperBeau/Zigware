#!/usr/bin/env bash
set -euo pipefail
OUT="coverage"
rm -rf "$OUT"
zig build coverage-exe
EXE="zig-out/bin/logic-tests"

if ! command -v kcov >/dev/null 2>&1; then
  echo "kcov not installed — skipping HTML coverage."
  echo "Fallback: logic coverage is asserted by the test suite itself:"
  echo "  protocol.zig  — decode happy/malformed, encode*, jsString adversarial table + round-trip"
  echo "  allowlist.zig — allowed/unknown/empty, duplicate, fuzz bypass"
  echo "  commands/*    — NIST SHA-256 vectors, chunked==oneshot, cancel"
  echo "  jobs.zig      — single/200-job/queue-full/storm"
  echo "  bridge.zig    — happy/unknown/malformed/concurrent/alive=false/flood"
  echo "Run 'zig build test' to exercise all of the above."
  exit 0
fi

# Scope coverage to THIS project's src/ (kcov otherwise instruments the whole Zig
# stdlib + compiler_rt pulled into the test binary, drowning the real number).
# Within src/, exclude the objc/AppKit glue — it needs a live GUI and is verified
# only by the manual smoke checklist (docs/SMOKE.md), not by the logic test binary.
kcov \
  --include-path="$(pwd)/src" \
  --exclude-pattern=objc.zig,platform_macos.zig,app.zig,scheme.zig,main.zig,tools/ \
  "$OUT" "$EXE"
echo "coverage report: $OUT/index.html"
