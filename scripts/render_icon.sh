#!/usr/bin/env bash
# Re-renders the NoteIt app icon from scripts/make_icon.swift into Resources/AppIcon.iconset and the
# runtime copy used by unbundled runs (Sources/NoteIt/Resources/AppIcon.png), and the menu bar glyph
# from scripts/make_menubar_glyph.swift (PNGs in Sources/NoteIt/Resources, SVGs in
# Resources/MenuBarGlyph). Commit the results.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build/icon"
rm -rf "$WORK"
mkdir -p "$WORK"
swiftc -O "$ROOT/scripts/make_icon.swift" -o "$WORK/make_icon"
rm -rf "$ROOT/Resources/AppIcon.iconset"
"$WORK/make_icon" "$ROOT/Resources/AppIcon.iconset"
cp "$ROOT/Resources/AppIcon.iconset/icon_256x256@2x.png" "$ROOT/Sources/NoteIt/Resources/AppIcon.png"
swiftc -O "$ROOT/scripts/make_menubar_glyph.swift" -o "$WORK/make_menubar_glyph"
"$WORK/make_menubar_glyph" "$ROOT/Sources/NoteIt/Resources" "$ROOT/Resources/MenuBarGlyph"
echo "==> Done"
