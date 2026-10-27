#!/usr/bin/env bash
# Builds the web client twice from a clean output and fails if the two trees differ. The signed release manifest
# (scripts/build-web-client-manifest.mjs) and the image's copy of the client both rely on this.
#   scripts/check_reproducible_build.sh   # from the repository root, after `pnpm -C web install`
set -euo pipefail
cd "$(dirname "$0")/.."
out=.selftest/repro
mkdir -p "$out"
export NOTEIT_BUILD_ID=noteit-repro SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct)}"

for run in 1 2; do
  rm -rf web/apps/web/.output web/apps/web/.nuxt
  pnpm -C web --filter @noteit/web build > "$out/build-$run.log" 2>&1
  node scripts/build-web-client-manifest.mjs --version 0.0.0-repro --commit repro --out "$out/run-$run" > /dev/null
  node -e 'const m = require(process.argv[1]); for (const [p, h] of Object.entries(m.files)) console.log(h + "  " + p); console.log("csp  " + m.csp)' \
    "$PWD/$out/run-$run/web-client-0.0.0-repro.json" > "$out/sha256-$run.txt"
done

if diff -u "$out/sha256-1.txt" "$out/sha256-2.txt"; then
  echo "reproducible: $(wc -l < "$out/sha256-1.txt" | tr -d ' ') entries match"
else
  echo "the two builds differ (see above)" >&2
  exit 1
fi
