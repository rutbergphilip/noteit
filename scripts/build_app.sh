#!/usr/bin/env bash
# Builds NoteIt.app (release), adds its icon, ad-hoc signs it and installs it atomically to
# ~/Applications (override with NOTEIT_INSTALL_DIR=/some/dir).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="NoteIt"
# The bundle id is defined once, in Swift (AppIdentity.bundleID).
BUNDLE_ID="$(sed -nE 's/^ *public static let bundleID = "([^"]+)".*/\1/p' Sources/NoteItSync/Migration/AppIdentity.swift | head -n 1)"
[[ -n "$BUNDLE_ID" ]] || { echo "error: couldn't read AppIdentity.bundleID" >&2; exit 1; }
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
INSTALL_DIR="${NOTEIT_INSTALL_DIR:-$HOME/Applications}"

echo "==> Building release binary"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/$APP_NAME"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

VERSION="${NOTEIT_VERSION:-1.0}"
BUILD_NUMBER="${NOTEIT_BUILD:-$(date +%Y%m%d%H%M)}"
PLIST="$APP/Contents/Info.plist"
# Build with plutil so values (version strings from env etc.) are always correctly escaped.
plutil -create xml1 "$PLIST"
plist_str() { plutil -replace "$1" -string "$2" "$PLIST"; }
plist_bool() { plutil -replace "$1" -bool "$2" "$PLIST"; }
plist_str CFBundleDevelopmentRegion "en"
plist_str CFBundleExecutable "$APP_NAME"
plist_str CFBundleIdentifier "$BUNDLE_ID"
plist_str CFBundleName "$APP_NAME"
plist_str CFBundleDisplayName "$APP_NAME"
plist_str CFBundlePackageType "APPL"
plist_str CFBundleShortVersionString "$VERSION"
plist_str CFBundleVersion "$BUILD_NUMBER"
plist_str CFBundleIconFile "AppIcon"
plist_str LSMinimumSystemVersion "14.0"
plist_str LSApplicationCategoryType "public.app-category.productivity"
plist_bool NSHighResolutionCapable YES
plist_str NSPrincipalClass "NSApplication"
plist_bool NSSupportsAutomaticTermination NO
plist_str NSHumanReadableCopyright "© $(date +%Y) NoteIt"
# Self-hosted sync servers (MinIO on a NAS) often only speak http on the local network.
plutil -replace NSAppTransportSecurity -json '{"NSAllowsLocalNetworking":true}' "$PLIST"
plutil -lint "$PLIST"

echo "==> Building AppIcon.icns"
# Resources/AppIcon.iconset is pre-rendered from scripts/make_icon.swift (scripts/render_icon.sh).
iconutil -c icns "$ROOT/Resources/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> Copying SwiftPM resources"
# Images loaded at runtime (AppResources) live in the target's resource bundle.
RESOURCE_BUNDLE="$(dirname "$BIN")/${APP_NAME}_${APP_NAME}.bundle"
[[ -d "$RESOURCE_BUNDLE" ]] || { echo "error: missing $RESOURCE_BUNDLE" >&2; exit 1; }
ditto "$RESOURCE_BUNDLE" "$APP/Contents/Resources/$(basename "$RESOURCE_BUNDLE")"

echo "==> Codesigning (ad-hoc)"
codesign --force --deep -s - "$APP"
codesign --verify --deep --strict "$APP"

echo "==> Installing to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
DEST="$INSTALL_DIR/$APP_NAME.app"
STAGE="$INSTALL_DIR/.$APP_NAME.app.installing.$$"
OLD="$INSTALL_DIR/.$APP_NAME.app.old.$$"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT
rm -rf "$STAGE"
# Copy next to the destination (same volume), verify, then swap; the old app is removed only after.
ditto "$APP" "$STAGE"
codesign --verify --deep --strict "$STAGE"
if [[ -e "$DEST" ]]; then
    mv "$DEST" "$OLD"
    if ! mv "$STAGE" "$DEST"; then
        mv "$OLD" "$DEST"
        echo "error: failed to install $DEST; previous version restored" >&2
        exit 1
    fi
    rm -rf "$OLD"
else
    mv "$STAGE" "$DEST"
fi
codesign --verify --deep --strict "$DEST"

echo "==> Done: $DEST"
