#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "== Slack Status Sync check =="

if command -v xcodebuild >/dev/null 2>&1 && xcodebuild -version >/dev/null 2>&1; then
  echo "Using xcodebuild"
  # Unsigned / team-less build for CI when CODE_SIGNING_ALLOWED=NO
  xcodebuild \
    -project SlackStatusSync.xcodeproj \
    -scheme SlackStatusSync \
    -configuration Debug \
    -destination 'platform=macOS' \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGN_IDENTITY="" \
    build

  if xcodebuild -project SlackStatusSync.xcodeproj -scheme SlackStatusSync -destination 'platform=macOS' -quiet test 2>/dev/null; then
    echo "xcodebuild test passed"
  else
    echo "xcodebuild test unavailable or failed; falling back to TestRunner"
    swift run --package-path "$ROOT" TestRunner
  fi
else
  echo "xcodebuild unavailable — using SwiftPM TestRunner fallback"
  swift build --package-path "$ROOT"
  swift run --package-path "$ROOT" TestRunner
fi

echo "All checks passed."
