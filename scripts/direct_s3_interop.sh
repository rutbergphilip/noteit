#!/usr/bin/env bash
# Direct mode interop (web-app Task 5.3): the web app's S3Backend and the Mac's S3Backend share one bucket prefix.
#   1. web:  creates a v2 store with the passphrase and syncs a note "From the web"
#   2. Mac:  LiveS3EmulatorTests/testSharesABucketWithTheWebApp opens it, reads that note, writes "From the Mac"
#   3. web:  reads both notes, then deletes the prefix
# It also runs the web's canary and CORS check against the emulator.
#
# Usage: scripts/direct_s3_interop.sh
# Uses NOTEIT_LIVE_S3_ENDPOINT if set (the bucket must exist); otherwise starts moto (`uvx --from 'moto[server]'`)
# on 127.0.0.1:4570 and creates the bucket.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ -d /Applications/Xcode.app ] && [ -z "${DEVELOPER_DIR:-}" ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

MOTO_PID=""
cleanup() { [ -n "$MOTO_PID" ] && kill "$MOTO_PID" 2>/dev/null || true; }
trap cleanup EXIT

export NOTEIT_LIVE_S3_BUCKET="${NOTEIT_LIVE_S3_BUCKET:-noteit-live}"
if [ -z "${NOTEIT_LIVE_S3_ENDPOINT:-}" ]; then
    command -v uvx >/dev/null || { echo "set NOTEIT_LIVE_S3_ENDPOINT, or install uv to run moto"; exit 1; }
    uvx --from 'moto[server]' moto_server -H 127.0.0.1 -p 4570 >/dev/null 2>&1 &
    MOTO_PID=$!
    export NOTEIT_LIVE_S3_ENDPOINT=http://127.0.0.1:4570
    for _ in $(seq 1 60); do curl -s -o /dev/null "$NOTEIT_LIVE_S3_ENDPOINT/" && break; sleep 1; done
    # moto doesn't check signatures, so an unsigned create works.
    curl -s -o /dev/null -X PUT "$NOTEIT_LIVE_S3_ENDPOINT/$NOTEIT_LIVE_S3_BUCKET"
fi

export NOTEIT_LIVE_S3_INTEROP_PREFIX="interop-$(date +%s)"
export NOTEIT_LIVE_S3_INTEROP_PASSPHRASE="interop passphrase $RANDOM"
WEB=(pnpm -C web --filter @noteit/web exec vitest run test/worker/direct.live.test.ts)

echo "==> web: canary and CORS check"
"${WEB[@]}"
echo "==> web: create the store and a note"
NOTEIT_INTEROP_STEP=write "${WEB[@]}"
echo "==> Mac: open the web's store, read its note, write one back"
swift test --filter LiveS3EmulatorTests/testSharesABucketWithTheWebApp
echo "==> web: read the Mac's note"
NOTEIT_INTEROP_STEP=read "${WEB[@]}"
echo "Direct mode interop passed."
