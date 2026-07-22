#!/usr/bin/env bash
# Smoke-test the built app bundle and sidecar without installing.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${ROOT_DIR}/dist/Slack Status Sync.app"
CORE="${APP}/Contents/Helpers/slack-status-sync-core"

if [[ ! -d "${APP}" ]]; then
  echo "Build first: npm run build" >&2
  exit 1
fi

bash "${ROOT_DIR}/scripts/verify-identity.sh" "${APP}"

test -x "${APP}/Contents/MacOS/Slack Status Sync"
test -x "${CORE}"

# Sidecar must answer ping without system node modules.
REPLY="$(printf '%s\n' '{"v":1,"id":"smoke","method":"ping"}' | "${CORE}" 2>/dev/null)"
echo "${REPLY}" | grep -q '"ok":true'
echo "${REPLY}" | grep -q '"pong":true'

# Bundle ID and LSUIElement
/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "${APP}/Contents/Info.plist" | grep -qx 'com.slack-status-sync.app'
/usr/libexec/PlistBuddy -c 'Print LSUIElement' "${APP}/Contents/Info.plist" | grep -qx 'true'

# Hardened EventKit access requires this entitlement on the main app. The Node
# sidecar needs JIT entitlements but must not inherit Calendar access.
APP_ENTITLEMENTS="$(codesign -d --entitlements :- "${APP}" 2>&1)"
echo "${APP_ENTITLEMENTS}" | grep -q 'com.apple.security.personal-information.calendars'
CORE_ENTITLEMENTS="$(codesign -d --entitlements :- "${CORE}" 2>&1)"
echo "${CORE_ENTITLEMENTS}" | grep -q 'com.apple.security.cs.allow-jit'
if echo "${CORE_ENTITLEMENTS}" | grep -q 'com.apple.security.personal-information.calendars'; then
  echo "Calendar entitlement must not be present on the sidecar" >&2
  exit 1
fi

echo "Smoke checks passed."
