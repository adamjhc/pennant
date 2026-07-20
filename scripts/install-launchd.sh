#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="com.slack-status-sync"
PLIST_SRC="${ROOT_DIR}/deploy/${LABEL}.plist"
DATA_DIR="${HOME}/.slack-status-sync"
CONFIG_PATH="${SLACK_STATUS_SYNC_CONFIG:-${DATA_DIR}/config.yaml}"
LOG_PATH="${DATA_DIR}/sync.log"
LAUNCH_AGENTS="${HOME}/Library/LaunchAgents"
PLIST_DST="${LAUNCH_AGENTS}/${LABEL}.plist"

NODE_BIN="$(command -v node)"
if [[ -z "${NODE_BIN}" ]]; then
  echo "node not found on PATH" >&2
  exit 1
fi

if [[ ! -f "${ROOT_DIR}/dist/cli.js" ]]; then
  echo "Building project..."
  (cd "${ROOT_DIR}" && npm run build)
fi

CLI_PATH="${ROOT_DIR}/dist/cli.js"
mkdir -p "${DATA_DIR}" "${LAUNCH_AGENTS}"

if [[ ! -f "${CONFIG_PATH}" ]]; then
  echo "Config not found at ${CONFIG_PATH}" >&2
  echo "Run: npm run dev -- init" >&2
  exit 1
fi

if [[ ! -x "${ROOT_DIR}/dist/calendar-reader" ]]; then
  echo "Native calendar helper missing. Run: npm run build" >&2
  exit 1
fi

echo "Reminder: grant Calendar access interactively first:"
echo "  node \"${ROOT_DIR}/dist/cli.js\" calendar authorize"
echo "  node \"${ROOT_DIR}/dist/cli.js\" calendar list"

sed \
  -e "s|__NODE_BIN__|${NODE_BIN}|g" \
  -e "s|__CLI_PATH__|${CLI_PATH}|g" \
  -e "s|__CONFIG_PATH__|${CONFIG_PATH}|g" \
  -e "s|__LOG_PATH__|${LOG_PATH}|g" \
  -e "s|__REPO_PATH__|${ROOT_DIR}|g" \
  "${PLIST_SRC}" > "${PLIST_DST}"

launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "${PLIST_DST}"
launchctl enable "gui/$(id -u)/${LABEL}"
launchctl kickstart -k "gui/$(id -u)/${LABEL}"

echo "Installed and started ${LABEL}"
echo "Logs: ${LOG_PATH}"
echo "Unload with: ${ROOT_DIR}/scripts/uninstall-launchd.sh"
