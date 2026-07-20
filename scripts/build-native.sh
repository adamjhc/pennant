#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${ROOT_DIR}/native/calendar-reader.swift"
PLIST="${ROOT_DIR}/native/Info.plist"
OUT_DIR="${ROOT_DIR}/dist"
BIN_OUT="${OUT_DIR}/calendar-reader"
APP_NAME="Slack Status Sync Calendar.app"
APP_DIR="${OUT_DIR}/${APP_NAME}"
APP_MACOS="${APP_DIR}/Contents/MacOS"
APP_BIN="${APP_MACOS}/calendar-reader"
STABLE_DIR="${HOME}/Applications"
STABLE_APP="${STABLE_DIR}/${APP_NAME}"

mkdir -p "${OUT_DIR}" "${APP_MACOS}" "${APP_DIR}/Contents/Resources" "${STABLE_DIR}"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc not found. Install Xcode Command Line Tools." >&2
  exit 1
fi

swiftc \
  -O \
  -framework AppKit \
  -framework EventKit \
  -framework Foundation \
  "${SRC}" \
  -o "${BIN_OUT}"

# Install as a real .app so macOS TCC can show it under Calendar privacy.
cp "${BIN_OUT}" "${APP_BIN}"
cp "${PLIST}" "${APP_DIR}/Contents/Info.plist"
chmod +x "${BIN_OUT}" "${APP_BIN}"
cp "${APP_BIN}" "${BIN_OUT}"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - \
    --identifier "com.slack-status-sync.calendar-reader" \
    "${APP_DIR}" >/dev/null
  codesign --force --sign - \
    --identifier "com.slack-status-sync.calendar-reader" \
    "${BIN_OUT}" >/dev/null
fi

# Copy to ~/Applications so CLI always launches the same TCC identity.
rm -rf "${STABLE_APP}"
cp -R "${APP_DIR}" "${STABLE_APP}"
if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - \
    --identifier "com.slack-status-sync.calendar-reader" \
    "${STABLE_APP}" >/dev/null
fi

/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "${APP_DIR}/Contents/Info.plist" >/dev/null

echo "Built ${BIN_OUT}"
echo "Built ${APP_DIR}"
echo "Installed ${STABLE_APP}"
echo "Note: ad-hoc rebuilds may require re-enabling Calendar Full Access for this app."
