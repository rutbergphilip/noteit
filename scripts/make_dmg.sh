#!/usr/bin/env bash
# Packs an app into a compressed DMG with an /Applications link:
#   ./scripts/make_dmg.sh dist/NoteIt.app 1.2.0 dist  →  dist/NoteIt-1.2.0.dmg
set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "usage: $0 <app> <version> <outdir>" >&2
    exit 2
fi
APP="$1"
VERSION="$2"
OUT_DIR="$3"
VOLUME_NAME="NoteIt"

[[ -d "$APP" ]] || { echo "error: $APP is not an app bundle" >&2; exit 1; }
[[ -n "$VERSION" ]] || { echo "error: empty version" >&2; exit 1; }
mkdir -p "$OUT_DIR"
DMG="$(cd "$OUT_DIR" && pwd)/NoteIt-$VERSION.dmg"

STAGE="$(dirname "$DMG")/.NoteIt-$VERSION.dmg-stage.$$"
rm -rf "$STAGE"
mkdir "$STAGE"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/NoteIt.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -quiet -volname "$VOLUME_NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG"
hdiutil verify -quiet "$DMG"
echo "$DMG"
