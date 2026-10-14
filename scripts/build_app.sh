#!/usr/bin/env bash
# Builds NoteIt.app (release), adds its icon, embeds Sparkle, signs it and installs it atomically to
# ~/Applications (override with NOTEIT_INSTALL_DIR=/some/dir).
#
# NOTEIT_SIGN_IDENTITY  codesign identity; "-" (default) signs ad-hoc, anything else signs for
#                       distribution (hardened runtime, secure timestamp, inside-out).
# NOTEIT_UNIVERSAL=1    builds arm64 + x86_64 instead of the host architecture only.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="NoteIt"
# The bundle id is defined once, in Swift (AppIdentity.bundleID).
BUNDLE_ID="$(sed -nE 's/^ *public static let bundleID = "([^"]+)".*/\1/p' Sources/NoteItSync/Migration/AppIdentity.swift | head -n 1)"
[[ -n "$BUNDLE_ID" ]] || { echo "error: couldn't read AppIdentity.bundleID" >&2; exit 1; }
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
# The main app's entitlements: Apple Events, for importing from the Notes app.
ENTITLEMENTS="$ROOT/Resources/NoteIt.entitlements"
# NOTEIT_* first, then the legacy INKWELL_* names (pre-rename), then the default.
INSTALL_DIR="${NOTEIT_INSTALL_DIR:-${INKWELL_INSTALL_DIR:-$HOME/Applications}}"
SIGN_IDENTITY="${NOTEIT_SIGN_IDENTITY:--}"
# Distribution signing (hardened runtime, inside-out) for any real identity. NOTEIT_HARDENED_RUNTIME=1
# forces that path with an ad-hoc identity, to check it locally without a Developer ID certificate.
if [[ "$SIGN_IDENTITY" != "-" || "${NOTEIT_HARDENED_RUNTIME:-0}" == "1" ]]; then
    DISTRIBUTION_SIGNING=1
else
    DISTRIBUTION_SIGNING=0
fi

BUILD_FLAGS=(-c release)
if [[ "${NOTEIT_UNIVERSAL:-0}" == "1" ]]; then
    BUILD_FLAGS+=(--arch arm64 --arch x86_64)
fi

echo "==> Building release binary (${BUILD_FLAGS[*]})"
swift build "${BUILD_FLAGS[@]}"
BIN_DIR="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)"
BIN="$BIN_DIR/$APP_NAME"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

echo "==> Embedding Sparkle.framework"
SPARKLE_SRC="$BIN_DIR/Sparkle.framework"
[[ -d "$SPARKLE_SRC" ]] || { echo "error: missing $SPARKLE_SRC" >&2; exit 1; }
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
# ditto keeps the framework's symlinks intact.
ditto "$SPARKLE_SRC" "$SPARKLE"
RPATH="@executable_path/../Frameworks"
if ! otool -l "$APP/Contents/MacOS/$APP_NAME" | grep -F "path $RPATH " >/dev/null; then
    install_name_tool -add_rpath "$RPATH" "$APP/Contents/MacOS/$APP_NAME"
fi

VERSION="${NOTEIT_VERSION:-${INKWELL_VERSION:-0.1.0}}"
BUILD_NUMBER="${NOTEIT_BUILD:-${INKWELL_BUILD:-$(date +%Y%m%d%H%M)}}"
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
# Sparkle: the appcast is attached to each GitHub release; updates are verified with this EdDSA key.
plist_str SUFeedURL "https://github.com/rutbergphilip/noteit/releases/latest/download/appcast.xml"
plist_str SUPublicEDKey "xK/MPK9UYC+zcyvc1/b1PUdPShY7k4F3+NGyaFF1B4o="
# Shown when macOS asks for permission to control Notes (File › Import… › Apple Notes).
plist_str NSAppleEventsUsageDescription "NoteIt reads your notes from the Notes app when you choose to import them."
plutil -lint "$PLIST"

echo "==> Building AppIcon.icns"
# Resources/AppIcon.iconset is pre-rendered from scripts/make_icon.swift (scripts/render_icon.sh).
iconutil -c icns "$ROOT/Resources/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> Copying SwiftPM resources"
# Images loaded at runtime (AppResources) live in the target's resource bundle.
RESOURCE_BUNDLE="$(dirname "$BIN")/${APP_NAME}_${APP_NAME}.bundle"
[[ -d "$RESOURCE_BUNDLE" ]] || { echo "error: missing $RESOURCE_BUNDLE" >&2; exit 1; }
ditto "$RESOURCE_BUNDLE" "$APP/Contents/Resources/$(basename "$RESOURCE_BUNDLE")"

if [[ "$DISTRIBUTION_SIGNING" == "1" ]]; then
    echo "==> Codesigning for distribution ($SIGN_IDENTITY, hardened runtime)"
    SIGN_FLAGS=(--force --options runtime --sign "$SIGN_IDENTITY")
    # Ad-hoc signatures can't carry a secure timestamp.
    [[ "$SIGN_IDENTITY" == "-" ]] || SIGN_FLAGS+=(--timestamp)
    # Inside-out, in the order Sparkle's documentation gives; no --deep.
    SPARKLE_B="$SPARKLE/Versions/B"
    for xpc in "$SPARKLE_B"/XPCServices/*.xpc; do
        if [[ "$(basename "$xpc")" == "Downloader.xpc" ]]; then
            codesign "${SIGN_FLAGS[@]}" --preserve-metadata=entitlements "$xpc"
        else
            codesign "${SIGN_FLAGS[@]}" "$xpc"
        fi
    done
    codesign "${SIGN_FLAGS[@]}" "$SPARKLE_B/Autoupdate"
    codesign "${SIGN_FLAGS[@]}" "$SPARKLE_B/Updater.app"
    codesign "${SIGN_FLAGS[@]}" "$SPARKLE"
    codesign "${SIGN_FLAGS[@]}" --entitlements "$ENTITLEMENTS" "$APP"
else
    echo "==> Codesigning (ad-hoc)"
    codesign --force --deep -s - "$APP"
    # --deep would hand the app's entitlements to Sparkle's helpers too, so the app is re-signed on its own.
    codesign --force -s - --entitlements "$ENTITLEMENTS" "$APP"
fi
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
