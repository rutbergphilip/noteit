#!/usr/bin/env bash
# Re-renders the NoteIt app icon from scripts/make_icon.swift into Resources/AppIcon.iconset and the
# runtime copy used by unbundled runs (Sources/NoteIt/Resources/AppIcon.png). Commit the results.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build/icon"
rm -rf "$WORK"
mkdir -p "$WORK"
swiftc -O "$ROOT/scripts/make_icon.swift" -o "$WORK/make_icon"
rm -rf "$ROOT/Resources/AppIcon.iconset"
"$WORK/make_icon" "$ROOT/Resources/AppIcon.iconset"
cp "$ROOT/Resources/AppIcon.iconset/icon_256x256@2x.png" "$ROOT/Sources/NoteIt/Resources/AppIcon.png"
echo "==> Done"
