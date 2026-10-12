#!/usr/bin/env bash
# Builds Inkwell.app (release), generates its icon, ad-hoc signs it and installs it atomically to
# ~/Applications (override with INKWELL_INSTALL_DIR=/some/dir).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="Inkwell"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
INSTALL_DIR="${INKWELL_INSTALL_DIR:-$HOME/Applications}"

echo "==> Building release binary"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/$APP_NAME"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

VERSION="${INKWELL_VERSION:-1.0}"
BUILD_NUMBER="${INKWELL_BUILD:-$(date +%Y%m%d%H%M)}"
PLIST="$APP/Contents/Info.plist"
# Build with plutil so values (version strings from env etc.) are always correctly escaped.
plutil -create xml1 "$PLIST"
plist_str() { plutil -replace "$1" -string "$2" "$PLIST"; }
plist_bool() { plutil -replace "$1" -bool "$2" "$PLIST"; }
plist_str CFBundleDevelopmentRegion "en"
plist_str CFBundleExecutable "$APP_NAME"
plist_str CFBundleIdentifier "com.inkwell.app"
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
plist_str NSHumanReadableCopyright "© $(date +%Y) Inkwell"
# Self-hosted sync servers (MinIO on a NAS) often only speak http on the local network.
plutil -replace NSAppTransportSecurity -json '{"NSAllowsLocalNetworking":true}' "$PLIST"
plutil -lint "$PLIST"

echo "==> Generating AppIcon.icns"
ICON_WORK="$BUILD_DIR/icon"
rm -rf "$ICON_WORK"
mkdir -p "$ICON_WORK"
swiftc -O "$ROOT/scripts/make_icon.swift" -o "$ICON_WORK/make_icon"
"$ICON_WORK/make_icon" "$ICON_WORK/AppIcon.iconset"
iconutil -c icns "$ICON_WORK/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

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
