#!/usr/bin/env bash
set -euo pipefail
OUT="coverage"
rm -rf "$OUT"
zig build coverage-exe
EXE="zig-out/bin/logic-tests"

if ! command -v kcov >/dev/null 2>&1; then
  echo "kcov not installed — skipping HTML coverage."
  echo "Fallback: logic coverage is asserted by the test suite itself:"
  echo "  protocol.zig            : decode (max_len), encode, jsString, writeJsonAsJsLiteral, reserved-route registry, fuzz"
  echo "  allowlist.zig           : allowed/unknown/empty, duplicate, fuzz bypass"
  echo "  commands/*              : NIST SHA-256 vectors, chunked==oneshot, cancel"
  echo "  jobs.zig                : single/200-job/queue-full/storm"
  echo "  platform/backend        : assertBackend conformance (fn shape, error sets, count==17)"
  echo "  platform/null           : record/drive, pump ordering, terminate-drop, simulate*, eval_drops"
  echo "  platform/macos/origin   : formatOrigin protocol/host/port, overflow, fuzz"
  echo "  platform/macos/scheme_logic : path extraction boundaries (0, MAX-1, MAX, NUL@0)"
  echo "  assets.zig              : serveAsset 200/404, reserved-route exclusion, fuzz"
  echo "  bridge.zig              : happy/unknown/malformed/concurrent/terminate/flood, budget, fuzz"
  echo "  app.zig                 : headless end-to-end, lifecycle, shutdown idempotency, navigation, scheme"
  echo "  sec_regression.zig      : adversarial bench (depth bomb, Unicode, maxInt ids, 100MB field, SlowBackend, memory ceiling)"
  echo "Run 'zig build test' to exercise all of the above."
  exit 0
fi

# Scope coverage to THIS project's src/ (kcov otherwise instruments the whole Zig
# stdlib + compiler_rt pulled into the test binary, drowning the real number).
# Within src/, exclude the objc/AppKit glue — it needs a live GUI and is verified
# only by the manual smoke checklist (docs/SMOKE.md), not by the logic test binary.
kcov \
  --include-path="$(pwd)/src" \
  --exclude-pattern=objc.zig,platform/macos/assoc.zig,platform/macos/backend.zig,platform/macos/window.zig,platform/macos/webview.zig,platform/macos/scheme.zig,platform/macos/delegate.zig,platform/macos/dispatch.zig,main.zig,tools/ \
  "$OUT" "$EXE"
echo "coverage report: $OUT/index.html"
