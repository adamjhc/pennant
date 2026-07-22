#!/usr/bin/env bash
# Verify the designated requirement is cert-anchored and matches the stored baseline.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-${ROOT_DIR}/dist/Slack Status Sync.app}"
BASELINE="${ROOT_DIR}/dist/designated-requirement.txt"
CERT_NAME="${SLACK_STATUS_SYNC_SIGN_IDENTITY:-Slack Status Sync Local}"

if [[ ! -d "${APP_PATH}" ]]; then
  echo "App not found: ${APP_PATH}" >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "${APP_PATH}"

DR="$(codesign -d -r- "${APP_PATH}" 2>&1 | sed -n 's/^designated => //p')"
if [[ -z "${DR}" ]]; then
  echo "Could not read designated requirement" >&2
  exit 1
fi

echo "Designated requirement:"
echo "  ${DR}"

if echo "${DR}" | grep -q 'cdhash'; then
  echo "ERROR: Designated requirement is cdhash-anchored (ad-hoc). Calendar TCC will not survive rebuilds." >&2
  echo "Run: npm run setup:signing" >&2
  exit 1
fi

if ! echo "${DR}" | grep -Eq 'certificate leaf = H"|anchor '; then
  echo "WARNING: Designated requirement is not certificate-anchored." >&2
fi

AUTHORITY="$(codesign -dv --verbose=4 "${APP_PATH}" 2>&1 | sed -n 's/^Authority=//p' | head -n1 || true)"
echo "Authority: ${AUTHORITY:-unknown}"
if [[ -n "${AUTHORITY}" && "${AUTHORITY}" != "${CERT_NAME}" ]]; then
  echo "WARNING: Expected Authority=${CERT_NAME}, got ${AUTHORITY}" >&2
fi

mkdir -p "$(dirname "${BASELINE}")"
if [[ -f "${BASELINE}" ]]; then
  PREV="$(cat "${BASELINE}")"
  if [[ "${PREV}" != "${DR}" ]]; then
    echo "ERROR: Designated requirement changed since last baseline." >&2
    echo "Previous: ${PREV}" >&2
    echo "Current:  ${DR}" >&2
    echo "Calendar permission may require re-approval. If you intentionally rotated the cert, update the baseline:" >&2
    echo "  codesign -d -r- \"${APP_PATH}\" 2>&1 | sed -n 's/^designated => //p' > \"${BASELINE}\"" >&2
    exit 1
  fi
  echo "Designated requirement matches baseline."
else
  echo "${DR}" >"${BASELINE}"
  echo "Wrote new baseline to ${BASELINE}"
fi
