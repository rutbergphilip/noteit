#!/usr/bin/env bash
# Usage: staple.sh <app-or-dmg>
# Apple's ticket service can fail for a short while right after notarization, so retry.
set -euo pipefail

target=${1:?usage: staple.sh <app-or-dmg>}
for attempt in 1 2 3 4 5 6; do
    if xcrun stapler staple "$target" && xcrun stapler validate "$target"; then
        exit 0
    fi
    if [[ $attempt -lt 6 ]]; then
        echo "Stapling or validation failed (attempt $attempt), retrying in $((attempt * 20)) s"
        sleep $((attempt * 20))
    fi
done
echo "error: could not staple $target" >&2
exit 1
