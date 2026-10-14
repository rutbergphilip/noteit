#!/usr/bin/env bash
# Submits a file (zip, dmg or pkg) for notarization and waits for the result. On failure it
# prints the notary log. Needs NOTARY_KEY_FILE (App Store Connect API .p8), NOTARY_KEY_ID and
# NOTARY_ISSUER_ID.
#   ./scripts/notarize.sh out/NoteIt-1.2.0.dmg
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <file>" >&2
    exit 2
fi
FILE="$1"
: "${NOTARY_KEY_FILE:?set NOTARY_KEY_FILE}" "${NOTARY_KEY_ID:?set NOTARY_KEY_ID}" "${NOTARY_ISSUER_ID:?set NOTARY_ISSUER_ID}"
[[ -f "$FILE" ]] || { echo "error: $FILE not found" >&2; exit 1; }

AUTH=(--key "$NOTARY_KEY_FILE" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
RESULT="$FILE.notary.json"
trap 'rm -f "$RESULT"' EXIT

echo "==> Notarizing $(basename "$FILE")"
submit_status=0
xcrun notarytool submit "$FILE" "${AUTH[@]}" --wait --timeout 45m --output-format json > "$RESULT" || submit_status=$?
cat "$RESULT"
echo
id="$(plutil -extract id raw "$RESULT" 2>/dev/null || true)"
status="$(plutil -extract status raw "$RESULT" 2>/dev/null || true)"

if [[ $submit_status -ne 0 || "$status" != "Accepted" ]]; then
    echo "::error::Notarization of $(basename "$FILE") failed (status: ${status:-unknown})."
    if [[ -n "$id" ]]; then
        xcrun notarytool log "$id" "${AUTH[@]}" || true
    fi
    exit 1
fi
echo "==> Accepted: $id"
