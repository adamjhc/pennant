#!/usr/bin/env bash
# Create or verify the long-lived local code-signing certificate.
# Never silently rotates an existing identity.
set -euo pipefail

CERT_NAME="${SLACK_STATUS_SYNC_SIGN_IDENTITY:-Slack Status Sync Local}"
KEYCHAIN="${SLACK_STATUS_SYNC_KEYCHAIN:-login.keychain-db}"

identity_usable() {
  local tmp
  tmp="$(mktemp)"
  echo 'int main(void){return 0;}' >"${tmp}.c"
  if ! cc "${tmp}.c" -o "${tmp}.bin" 2>/dev/null; then
    rm -f "${tmp}" "${tmp}.c" "${tmp}.bin"
    return 1
  fi
  if codesign --force --sign "${CERT_NAME}" "${tmp}.bin" >/dev/null 2>&1; then
    rm -f "${tmp}" "${tmp}.c" "${tmp}.bin"
    return 0
  fi
  rm -f "${tmp}" "${tmp}.c" "${tmp}.bin"
  return 1
}

if security find-certificate -c "${CERT_NAME}" >/dev/null 2>&1 && identity_usable; then
  echo "Found usable codesigning identity: ${CERT_NAME}"
  TMP_SHOW="$(mktemp)"
  echo 'int main(void){return 0;}' >"${TMP_SHOW}.c"
  cc "${TMP_SHOW}.c" -o "${TMP_SHOW}.bin" 2>/dev/null
  codesign --force --sign "${CERT_NAME}" "${TMP_SHOW}.bin" >/dev/null 2>&1
  echo "Authority=$(codesign -dv --verbose=4 "${TMP_SHOW}.bin" 2>&1 | sed -n 's/^Authority=//p' | head -n1)"
  echo "DR=$(codesign -d -r- "${TMP_SHOW}.bin" 2>&1 | sed -n 's/^designated => //p')"
  rm -f "${TMP_SHOW}" "${TMP_SHOW}.c" "${TMP_SHOW}.bin"
  echo "Designated-requirement anchor will stay stable across rebuilds while this certificate remains."
  echo "Optional: in Keychain Access, set Trust → Code Signing → Always Trust so the identity also appears in find-identity."
  exit 0
fi

if security find-certificate -c "${CERT_NAME}" >/dev/null 2>&1; then
  echo "Certificate \"${CERT_NAME}\" exists but codesign cannot use it yet." >&2
  echo "Open Keychain Access → \"${CERT_NAME}\" → Trust → Code Signing → Always Trust." >&2
  exit 1
fi

echo "Creating self-signed codesigning certificate: ${CERT_NAME}"
echo "This is a one-time setup for this Mac. Do not delete this certificate if you want Calendar permission to survive rebuilds."

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# Generate a code-signing certificate via openssl + Keychain import isn't as reliable
# as Keychain Access CSR flow. Use `security` certificate creation with a temp config.
cat >"${TMP_DIR}/cert.conf" <<EOF
[ req ]
distinguished_name = req_distinguished_name
prompt = no
[ req_distinguished_name ]
CN = ${CERT_NAME}
[ extensions ]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF

openssl req -new -newkey rsa:2048 -nodes \
  -keyout "${TMP_DIR}/key.pem" \
  -out "${TMP_DIR}/req.pem" \
  -config "${TMP_DIR}/cert.conf" >/dev/null 2>&1

openssl x509 -req -days 3650 \
  -in "${TMP_DIR}/req.pem" \
  -signkey "${TMP_DIR}/key.pem" \
  -out "${TMP_DIR}/cert.pem" \
  -extfile "${TMP_DIR}/cert.conf" \
  -extensions extensions >/dev/null 2>&1

# Prefer OpenSSL 3 -legacy when available; fall back for LibreSSL on macOS.
if ! openssl pkcs12 -export -legacy \
  -inkey "${TMP_DIR}/key.pem" \
  -in "${TMP_DIR}/cert.pem" \
  -out "${TMP_DIR}/cert.p12" \
  -passout pass:temp \
  -name "${CERT_NAME}" >/dev/null 2>&1; then
  openssl pkcs12 -export \
    -inkey "${TMP_DIR}/key.pem" \
    -in "${TMP_DIR}/cert.pem" \
    -out "${TMP_DIR}/cert.p12" \
    -passout pass:temp \
    -name "${CERT_NAME}" >/dev/null 2>&1
fi

security import "${TMP_DIR}/cert.p12" \
  -k "${KEYCHAIN}" \
  -P temp \
  -T /usr/bin/codesign \
  -T /usr/bin/security >/dev/null

# Allow codesign to use the key without UI prompts in future builds.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "${KEYCHAIN}" >/dev/null 2>&1 || true

echo
echo "Imported ${CERT_NAME}."
echo "Optional but recommended: Keychain Access → \"${CERT_NAME}\" → Trust → Code Signing → Always Trust."
echo

if identity_usable; then
  echo "Identity is usable with codesign."
else
  echo "codesign cannot use the identity yet. Set Code Signing trust to Always Trust in Keychain Access, then re-run:" >&2
  echo "  npm run setup:signing" >&2
  exit 1
fi
