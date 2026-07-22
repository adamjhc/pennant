#!/usr/bin/env bash
# Install the built app into /Applications (requires admin for that directory).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${ROOT_DIR}/dist/Slack Status Sync.app"
DEST="/Applications/Slack Status Sync.app"
LEGACY_HELPER="${HOME}/Applications/Slack Status Sync Calendar.app"
LEGACY_AGENT="gui/$(id -u)/com.slack-status-sync"

if [[ ! -d "${SRC}" ]]; then
  echo "Build first: npm run build" >&2
  exit 1
fi

bash "${ROOT_DIR}/scripts/verify-identity.sh" "${SRC}"

# Stop a running copy if present.
pkill -x "Slack Status Sync" 2>/dev/null || true
sleep 0.5

# Remove legacy launchd agent and helper app.
launchctl bootout "${LEGACY_AGENT}" 2>/dev/null || true
if [[ -d "${LEGACY_HELPER}" ]]; then
  rm -rf "${LEGACY_HELPER}"
fi

echo "Installing to ${DEST} (may prompt for administrator password)…"
if [[ -w /Applications ]]; then
  rm -rf "${DEST}"
  cp -R "${SRC}" "${DEST}"
else
  # Atomic replace via admin privileges.
  TMP_COPY="$(mktemp -d)/Slack Status Sync.app"
  cp -R "${SRC}" "${TMP_COPY}"
  osascript -e "do shell script \"rm -rf '${DEST}' && cp -R '${TMP_COPY}' '${DEST}' && chown -R $(whoami):staff '${DEST}'\" with administrator privileges"
  rm -rf "$(dirname "${TMP_COPY}")"
fi

# Copying preserves the complete nested and outer signatures. Re-signing here
# could accidentally apply the main app's Calendar entitlement to the Node
# sidecar or strip the sidecar's JIT entitlements.
bash "${ROOT_DIR}/scripts/verify-identity.sh" "${DEST}"

# Clean legacy CLI data (fresh start). App will also do this on first launch.
if [[ -d "${HOME}/.slack-status-sync" ]]; then
  rm -rf "${HOME}/.slack-status-sync"
  echo "Removed legacy ~/.slack-status-sync"
fi
security delete-generic-password -s "slack-status-sync" -a "slack-user-token" 2>/dev/null || true

echo "Installed ${DEST}"
echo "Launching…"
open -a "${DEST}"
