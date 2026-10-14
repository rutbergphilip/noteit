#!/usr/bin/env bash
# Submits a file (zip, dmg or pkg) for notarization and waits for the result. On failure it
# prints the notary log. Authentication comes from the environment, one of:
#   App Store Connect API key: NOTARY_KEY_FILE (.p8 path), NOTARY_KEY_ID, NOTARY_ISSUER_ID
#   Apple ID:                  APPLE_ID, APPLE_APP_PASSWORD (app-specific), APPLE_TEAM_ID
# The API key is used when all of its variables are set. NOTARY_METHOD=api_key|apple_id forces one.
#   ./scripts/notarize.sh out/NoteIt-1.2.0.dmg
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <file>" >&2
    exit 2
fi
FILE="$1"
[[ -f "$FILE" ]] || { echo "error: $FILE not found" >&2; exit 1; }

METHOD="${NOTARY_METHOD:-}"
if [[ -z "$METHOD" ]]; then
    if [[ -n "${NOTARY_KEY_FILE:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER_ID:-}" ]]; then
        METHOD=api_key
    elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
        METHOD=apple_id
    else
        echo "error: set NOTARY_KEY_FILE, NOTARY_KEY_ID and NOTARY_ISSUER_ID, or APPLE_ID, APPLE_APP_PASSWORD and APPLE_TEAM_ID" >&2
        exit 1
    fi
fi

case "$METHOD" in
    api_key)
        : "${NOTARY_KEY_FILE:?set NOTARY_KEY_FILE}" "${NOTARY_KEY_ID:?set NOTARY_KEY_ID}" "${NOTARY_ISSUER_ID:?set NOTARY_ISSUER_ID}"
        [[ -f "$NOTARY_KEY_FILE" ]] || { echo "error: $NOTARY_KEY_FILE not found" >&2; exit 1; }
        AUTH=(--key "$NOTARY_KEY_FILE" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
        ;;
    apple_id)
        : "${APPLE_ID:?set APPLE_ID}" "${APPLE_APP_PASSWORD:?set APPLE_APP_PASSWORD}" "${APPLE_TEAM_ID:?set APPLE_TEAM_ID}"
        AUTH=(--apple-id "$APPLE_ID" --password "$APPLE_APP_PASSWORD" --team-id "$APPLE_TEAM_ID")
        ;;
    *)
        echo "error: NOTARY_METHOD must be api_key or apple_id, got '$METHOD'" >&2
        exit 1
        ;;
esac

RESULT="$FILE.notary.json"
trap 'rm -f "$RESULT"' EXIT

echo "==> Notarizing $(basename "$FILE") (auth: $METHOD)"
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
