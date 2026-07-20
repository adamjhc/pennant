#!/usr/bin/env bash
set -euo pipefail

LABEL="com.slack-status-sync"
PLIST_DST="${HOME}/Library/LaunchAgents/${LABEL}.plist"

launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
rm -f "${PLIST_DST}"
echo "Removed ${LABEL}"
