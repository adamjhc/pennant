#!/usr/bin/env bash
# Build the Node SEA sidecar + Swift menu-bar app into dist/Slack Status Sync.app
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

CERT_NAME="${SLACK_STATUS_SYNC_SIGN_IDENTITY:-Slack Status Sync Local}"
OUT_DIR="${ROOT_DIR}/dist"
APP_NAME="Slack Status Sync.app"
APP_DIR="${OUT_DIR}/${APP_NAME}"
MACOS_DIR="${APP_DIR}/Contents/MacOS"
HELPERS_DIR="${APP_DIR}/Contents/Helpers"
RESOURCES_DIR="${APP_DIR}/Contents/Resources"
SIDECAR_NAME="slack-status-sync-core"
BUNDLE_BIN="Slack Status Sync"

mkdir -p "${OUT_DIR}" "${MACOS_DIR}" "${HELPERS_DIR}" "${RESOURCES_DIR}"

if ! codesign --force --sign "${CERT_NAME}" "$(mktemp)" >/dev/null 2>&1; then
  # Probe with a real Mach-O; mktemp file is not signed that way.
  PROBE="$(mktemp)"
  echo 'int main(void){return 0;}' >"${PROBE}.c"
  cc "${PROBE}.c" -o "${PROBE}.bin"
  if ! codesign --force --sign "${CERT_NAME}" "${PROBE}.bin" >/dev/null 2>&1; then
    rm -f "${PROBE}" "${PROBE}.c" "${PROBE}.bin"
    echo "Missing usable codesigning identity \"${CERT_NAME}\"." >&2
    echo "Run: npm run setup:signing" >&2
    exit 1
  fi
  rm -f "${PROBE}" "${PROBE}.c" "${PROBE}.bin"
fi

echo "==> Building TypeScript"
npm run build:ts

echo "==> Bundling sidecar with esbuild"
npx --yes esbuild src/sidecar.ts \
  --bundle \
  --platform=node \
  --target=node20 \
  --format=cjs \
  --outfile=dist/sidecar.cjs \
  --external:fsevents

echo "==> Creating Node SEA"
cat >dist/sea-config.json <<EOF
{
  "main": "dist/sidecar.cjs",
  "output": "dist/sea-prep.blob",
  "disableExperimentalSEAWarning": true
}
EOF

node --experimental-sea-config dist/sea-config.json

NODE_BIN="$(command -v node)"
cp "${NODE_BIN}" "dist/${SIDECAR_NAME}"
codesign --remove-signature "dist/${SIDECAR_NAME}" 2>/dev/null || true

npx --yes postject "dist/${SIDECAR_NAME}" NODE_SEA_BLOB dist/sea-prep.blob \
  --sentinel-fuse NODE_SEA_FUSE_fce680ab2cc467b6e072b8b5df1996b2 \
  --macho-segment-name NODE_SEA

chmod +x "dist/${SIDECAR_NAME}"

echo "==> Compiling Swift menu-bar app"
SOURCES=(native/App/Sources/*.swift)
SDK="$(xcrun --sdk macosx --show-sdk-path)"

swiftc \
  -sdk "${SDK}" \
  -target "$(uname -m)-apple-macosx14.0" \
  -O \
  -framework AppKit \
  -framework SwiftUI \
  -framework EventKit \
  -framework ServiceManagement \
  -framework UserNotifications \
  -framework Security \
  -framework Combine \
  "${SOURCES[@]}" \
  -o "${MACOS_DIR}/${BUNDLE_BIN}"

cp "native/App/Info.plist" "${APP_DIR}/Contents/Info.plist"
cp "dist/${SIDECAR_NAME}" "${HELPERS_DIR}/${SIDECAR_NAME}"
chmod +x "${MACOS_DIR}/${BUNDLE_BIN}" "${HELPERS_DIR}/${SIDECAR_NAME}"

# Also expose helper via Contents/MacOS for Bundle.main.url(forAuxiliaryExecutable:)
cp "${HELPERS_DIR}/${SIDECAR_NAME}" "${MACOS_DIR}/${SIDECAR_NAME}"
chmod +x "${MACOS_DIR}/${SIDECAR_NAME}"

APP_ENTITLEMENTS="${ROOT_DIR}/native/App/AppEntitlements.plist"
SIDECAR_ENTITLEMENTS="${ROOT_DIR}/native/App/SidecarEntitlements.plist"

echo "==> Signing nested helpers then outer app"
codesign --force --options runtime --entitlements "${SIDECAR_ENTITLEMENTS}" --sign "${CERT_NAME}" \
  --identifier "com.slack-status-sync.app.core" \
  "${HELPERS_DIR}/${SIDECAR_NAME}"

codesign --force --options runtime --entitlements "${SIDECAR_ENTITLEMENTS}" --sign "${CERT_NAME}" \
  --identifier "com.slack-status-sync.app.core" \
  "${MACOS_DIR}/${SIDECAR_NAME}"

codesign --force --options runtime --entitlements "${APP_ENTITLEMENTS}" --sign "${CERT_NAME}" \
  --identifier "com.slack-status-sync.app" \
  "${APP_DIR}"

echo "==> Verifying identity"
bash scripts/verify-identity.sh "${APP_DIR}"

echo "Built ${APP_DIR}"
echo "Install with: npm run install:app"
