#!/usr/bin/env bash
# Runs LiveS3EmulatorTests against local cloud emulators (Floci) in Docker:
#   aws  — floci/floci      (Amazon S3, port 4566)
#   gcp  — floci/floci-gcp  (Google Cloud Storage XML API, port 4588)
# Usage: scripts/live_s3_tests.sh [aws] [gcp]   (default: both)
# Set KEEP_EMULATORS=1 to leave the containers running afterwards.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

command -v docker >/dev/null || { echo "docker is required (Docker Desktop, Rancher Desktop, Colima, …)"; exit 1; }
docker info >/dev/null 2>&1 || { echo "docker daemon is not running"; exit 1; }

TARGETS=("$@")
[ ${#TARGETS[@]} -eq 0 ] && TARGETS=(aws gcp)

if [ -d /Applications/Xcode.app ] && [ -z "${DEVELOPER_DIR:-}" ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

STARTED=()
cleanup() {
    [ "${KEEP_EMULATORS:-}" = "1" ] && return
    for name in "${STARTED[@]+"${STARTED[@]}"}"; do docker rm -f "$name" >/dev/null 2>&1 || true; done
}
trap cleanup EXIT

start() { # name image port [env...]
    local name=$1 image=$2 port=$3; shift 3
    if ! docker ps --format '{{.Names}}' | grep -qx "$name"; then
        docker rm -f "$name" >/dev/null 2>&1 || true
        docker run -d --name "$name" -p "127.0.0.1:$port:$port" "$@" "$image" >/dev/null
        STARTED+=("$name")
    fi
    for _ in $(seq 1 60); do
        curl -s -o /dev/null "http://127.0.0.1:$port/" && return
        sleep 1
    done
    echo "$name did not come up on port $port"; exit 1
}

FAILED=0
for target in "${TARGETS[@]}"; do
    case "$target" in
        aws)
            start inkwell-floci floci/floci:latest 4566 -e FLOCI_SERVICES_UI_ENABLED=false
            echo "==> Amazon S3 (Floci)"
            INKWELL_LIVE_S3_ENDPOINT=http://127.0.0.1:4566 INKWELL_LIVE_S3_CREATE_BUCKET=1 \
                swift test --filter LiveS3EmulatorTests || FAILED=1
            ;;
        gcp)
            start inkwell-floci-gcp floci/floci-gcp:latest 4588
            curl -s -o /dev/null -X POST "http://127.0.0.1:4588/storage/v1/b?project=inkwell" \
                -H 'content-type: application/json' -d '{"name":"inkwell-live"}'
            echo "==> Google Cloud Storage (Floci GCP)"
            INKWELL_LIVE_S3_ENDPOINT=http://127.0.0.1:4588 INKWELL_LIVE_S3_REGION=auto \
                swift test --filter LiveS3EmulatorTests || FAILED=1
            ;;
        *) echo "unknown target: $target (use aws or gcp)"; exit 2 ;;
    esac
done
exit $FAILED
