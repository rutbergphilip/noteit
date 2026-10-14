#!/usr/bin/env bash
# Checks that a Sparkle private key (as exported by `generate_keys -x`) matches the SUPublicEDKey
# in an app's Info.plist, so updates are never signed with a key installed copies would reject.
#   ./scripts/check_sparkle_key.sh sparkle-private-key dist/NoteIt.app
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <private-key-file> <app>" >&2
    exit 2
fi
KEY_FILE="$1"
APP="$2"
[[ -f "$KEY_FILE" ]] || { echo "error: $KEY_FILE not found" >&2; exit 1; }
PLIST="$APP/Contents/Info.plist"
[[ -f "$PLIST" ]] || { echo "error: $PLIST not found" >&2; exit 1; }

# The system LibreSSL can't do Ed25519; prefer Homebrew's OpenSSL 3.
OPENSSL="openssl"
if command -v brew > /dev/null && [[ -x "$(brew --prefix openssl@3 2>/dev/null)/bin/openssl" ]]; then
    OPENSSL="$(brew --prefix openssl@3)/bin/openssl"
fi

EXPECTED="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST" 2>/dev/null || true)"
[[ -n "$EXPECTED" ]] || { echo "error: $PLIST has no SUPublicEDKey" >&2; exit 1; }

SEED_LENGTH="$(tr -d '[:space:]' < "$KEY_FILE" | base64 --decode 2>/dev/null | wc -c | tr -d ' ')"
if [[ "$SEED_LENGTH" != "32" ]]; then
    echo "error: $KEY_FILE isn't a base64 Ed25519 private key from 'generate_keys -x' (decodes to $SEED_LENGTH bytes, expected 32)" >&2
    exit 1
fi

# PKCS#8 DER for an Ed25519 private key is a fixed 16-byte prefix followed by the 32-byte seed.
ACTUAL="$(
    { printf '302e020100300506032b657004220420' | xxd -r -p; tr -d '[:space:]' < "$KEY_FILE" | base64 --decode; } \
        | "$OPENSSL" pkey -inform DER -pubout -outform DER \
        | tail -c 32 | base64
)" || { echo "error: couldn't derive the public key with $OPENSSL (it needs Ed25519 support)" >&2; exit 1; }

if [[ "$ACTUAL" != "$EXPECTED" ]]; then
    echo "error: the Sparkle private key doesn't match SUPublicEDKey in $PLIST." >&2
    echo "  SUPublicEDKey:            $EXPECTED" >&2
    echo "  public key of $KEY_FILE: $ACTUAL" >&2
    echo "Installed copies would reject updates signed with this key. Use the original key (see docs/releasing.md)." >&2
    exit 1
fi
echo "Sparkle key matches SUPublicEDKey ($EXPECTED)."
