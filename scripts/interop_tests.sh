#!/usr/bin/env bash
# Web ⇄ Mac interop: builds and starts the NoteIt web server on a fresh data directory, then runs
#   - the web half (web/apps/web/test/interop/web-side.test.ts: the web app's worker code over /api/storage) and
#   - the Mac half (Tests/NoteItTests/LiveInteropTests.swift: NoteStore + the sync engine over the server's /s3)
# side by side; they take turns through marker files. Tears everything down afterwards.
#
# Usage: scripts/interop_tests.sh            (macOS; needs swift, node 22 and pnpm)
# Env:   INTEROP_PORT (default 3790), SKIP_WEB_BUILD=1 to reuse web/apps/web/.output, KEEP_INTEROP_DIR=1.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PORT="${INTEROP_PORT:-3790}"
URL="http://127.0.0.1:$PORT"
TOKEN="interop-setup-token-0123"

if [ -d /Applications/Xcode.app ] && [ -z "${DEVELOPER_DIR:-}" ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/noteit-interop-XXXXXX")"
SERVER_PID=""
WEB_PID=""
cleanup() {
    [ -n "$WEB_PID" ] && kill "$WEB_PID" 2>/dev/null || true
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
    wait 2>/dev/null || true
    if [ "${KEEP_INTEROP_DIR:-}" = "1" ]; then echo "kept $WORK"; else rm -rf "$WORK"; fi
}
trap cleanup EXIT

if curl -s -o /dev/null "$URL/api/health/live"; then echo "port $PORT is already in use"; exit 1; fi

echo "==> Building"
if [ "${SKIP_WEB_BUILD:-}" != "1" ]; then (cd web && pnpm --filter @noteit/web build >/dev/null); fi
swift build --build-tests >/dev/null

echo "==> Starting the server on $URL (data in $WORK/data)"
mkdir -p "$WORK/steps"
NOTEIT_DATA_DIR="$WORK/data" NOTEIT_SETUP_TOKEN="$TOKEN" PORT="$PORT" HOST=127.0.0.1 \
    node web/apps/web/e2e/server.mjs >"$WORK/server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 60); do
    curl -s -o /dev/null "$URL/api/health/live" && break
    sleep 0.5
done
curl -s -o /dev/null "$URL/api/health/live" || { echo "server did not start"; cat "$WORK/server.log"; exit 1; }

echo "==> Web half and Mac half"
(cd web/apps/web && NOTEIT_INTEROP_URL="$URL" NOTEIT_INTEROP_DIR="$WORK/steps" NOTEIT_INTEROP_SETUP_TOKEN="$TOKEN" \
    npx vitest run test/interop/web-side.test.ts) >"$WORK/web.log" 2>&1 &
WEB_PID=$!
MAC=0
NOTEIT_INTEROP_DIR="$WORK/steps" swift test --skip-build --filter LiveInteropTests 2>&1 | tee "$WORK/mac.log" | grep -E "error|failed|passed|skipped|Executed" || true
grep -q "with 0 failures" "$WORK/mac.log" && ! grep -q "skipped" "$WORK/mac.log" || MAC=1
WEB=0
wait "$WEB_PID" || WEB=1
WEB_PID=""
grep -E "✓|×|FAIL|passed|failed|skipped|Error" "$WORK/web.log" | head -40 || true

if [ "$MAC" = 0 ] && [ "$WEB" = 0 ]; then
    echo "==> Interop PASSED"
    exit 0
fi
echo "==> Interop FAILED (mac=$MAC web=$WEB)"
[ "$WEB" = 1 ] && cat "$WORK/web.log"
exit 1
