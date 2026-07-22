#!/usr/bin/env bash
# Build twice and prove the designated requirement is unchanged.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

npm run build >/dev/null
FIRST="$(codesign -d -r- "dist/Slack Status Sync.app" 2>&1 | sed -n 's/^designated => //p')"

npm run build >/dev/null
SECOND="$(codesign -d -r- "dist/Slack Status Sync.app" 2>&1 | sed -n 's/^designated => //p')"

if [[ -z "${FIRST}" || "${FIRST}" != "${SECOND}" ]]; then
  echo "Designated requirement changed across rebuilds." >&2
  echo "First:  ${FIRST}" >&2
  echo "Second: ${SECOND}" >&2
  exit 1
fi

echo "Designated requirement is stable across two rebuilds:"
echo "  ${SECOND}"
