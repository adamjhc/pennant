#!/usr/bin/env bash
# Notarizes and staples an .app or .dmg. Needs NOTARY_API_KEY, NOTARY_KEY_ID and NOTARY_ISSUER_ID.
# Usage: .github/notarize.sh path/to/Pennant.app
set -euo pipefail

target="$1"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

key="$work/AuthKey.p8"
printf '%s' "$NOTARY_API_KEY" > "$key"
auth=(--key "$key" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")

submission="$target"
if [[ "$target" == *.app ]]; then
  submission="$work/notarize.zip"
  ditto -c -k --keepParent "$target" "$submission"
fi

xcrun notarytool submit "$submission" "${auth[@]}" --wait --output-format json > "$work/notary.json"
cat "$work/notary.json"
status=$(plutil -extract status raw "$work/notary.json")
if [ "$status" != "Accepted" ]; then
  id=$(plutil -extract id raw "$work/notary.json")
  xcrun notarytool log "$id" "${auth[@]}"
  exit 1
fi

xcrun stapler staple "$target"
if [[ "$target" == *.app ]]; then
  spctl --assess --type execute --verbose "$target"
else
  spctl --assess --type open --context context:primary-signature --verbose "$target"
fi
