#!/usr/bin/env bash
# Builds NoteIt.app (release), adds its icon, embeds Sparkle, signs it and installs it atomically to
# ~/Applications (override with NOTEIT_INSTALL_DIR=/some/dir).
#
# NOTEIT_SIGN_IDENTITY  codesign identity; "-" (default) signs ad-hoc, anything else signs for
#                       distribution (hardened runtime, secure timestamp, inside-out). Ad-hoc builds give the
#                       app a designated requirement on its bundle id instead of the default cdhash, so
#                       privacy grants such as Accessibility keep applying after a rebuild.
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
# The main app's entitlements: Apple Events, for importing from the Notes app and reading browser page addresses.
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
# App Intents: the compiler records the intent types' constant values, which appintentsmetadataprocessor
# turns into Metadata.appintents (what Shortcuts reads) once the app is assembled.
mkdir -p "$BUILD_DIR"
INTENT_PROTOCOLS="$BUILD_DIR/appintents-protocols.json"
echo '["AppIntent","AppEntity","TransientAppEntity","AppEnum","EntityQuery","EntityStringQuery","EnumerableEntityQuery","EntityPropertyQuery","DynamicOptionsProvider","AppShortcutsProvider","AppIntentsPackage","_IntentValueRepresentable"]' > "$INTENT_PROTOCOLS"
BUILD_FLAGS+=(-Xswiftc -emit-const-values -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file -Xswiftc -Xfrontend -Xswiftc "$INTENT_PROTOCOLS")

BIN_DIR="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)"
BIN="$BIN_DIR/$APP_NAME"
# Where this build writes the app's swiftconstvalues, so a file left by another kind of build is never used:
# SwiftPM puts $APP_NAME.swiftconstvalues next to the binary; universal builds go through Xcode's build system,
# which writes $APP_NAME-primary.swiftconstvalues per architecture (the host's matches --target-triple below).
if [[ "${NOTEIT_UNIVERSAL:-0}" == "1" ]]; then
    OBJECTS_DIR="$(dirname "$(dirname "$BIN_DIR")")/Intermediates.noindex/$APP_NAME.build/$(basename "$BIN_DIR")/$APP_NAME.build/Objects-normal"
    CONST_DIR="$OBJECTS_DIR/$(uname -m)"
else
    CONST_DIR="$BIN_DIR/$APP_NAME.build"
fi
CONST_NAMES=("$APP_NAME.swiftconstvalues" "$APP_NAME-primary.swiftconstvalues")

echo "==> Building release binary (${BUILD_FLAGS[*]})"
swift build "${BUILD_FLAGS[@]}"

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
add_rpath() {
    if ! otool -l "$1" | grep -F "path $RPATH " >/dev/null; then
        install_name_tool -add_rpath "$RPATH" "$1"
    fi
}
add_rpath "$APP/Contents/MacOS/$APP_NAME"

# Helpers and extensions embedded in the app, one row each (program §10):
#   "<path in bundle>|<source path relative to $BIN_DIR>|<build step script or empty>|<entitlements path or empty>"
# The path in bundle always starts with Contents/. Later plans add rows; the main app is never a row.
# Planned rows:
#   Contents/Helpers/noteit                  automation (the CLI, built as NoteItCLI)
#   Contents/PlugIns/NoteItShare.appex       automation (the Share extension)
#   Contents/Helpers/NoteItPluginHost        plugins
#   Contents/PlugIns/NoteItClipper.appex     web-clipper (the Safari extension)
EMBEDS=(
    "Contents/Helpers/noteit|NoteItCLI||"
)
# Rows that were copied, as "<path in bundle>|<entitlements path or empty>", for signing.
EMBEDDED=()

echo "==> Embedding helpers and extensions"
for row in ${EMBEDS[@]+"${EMBEDS[@]}"}; do
    IFS='|' read -r embed_path embed_source embed_step embed_entitlements <<< "$row"
    if [[ "$embed_path" != Contents/* ]]; then
        echo "error: embeds row path must start with Contents/: $row" >&2
        exit 1
    fi
    if [[ -n "$embed_step" ]]; then
        "$ROOT/$embed_step"
    fi
    if [[ ! -e "$BIN_DIR/$embed_source" ]]; then
        echo "Skipping $embed_path: $embed_source not built"
        continue
    fi
    mkdir -p "$(dirname "$APP/$embed_path")"
    ditto "$BIN_DIR/$embed_source" "$APP/$embed_path"
    if [[ -f "$APP/$embed_path" ]] && file -b "$APP/$embed_path" | grep -q "Mach-O"; then
        add_rpath "$APP/$embed_path"
    fi
    EMBEDDED+=("$embed_path|$embed_entitlements")
done

# Shell completion scripts, linked by Settings › Integrations › Install (CLIInstaller.completionLinks).
if [[ -x "$APP/Contents/Helpers/noteit" ]]; then
    echo "==> Generating shell completions"
    COMPLETIONS="$APP/Contents/Resources/completions"
    mkdir -p "$COMPLETIONS"
    "$BIN_DIR/NoteItCLI" completion zsh > "$COMPLETIONS/_noteit"
    "$BIN_DIR/NoteItCLI" completion bash > "$COMPLETIONS/noteit.bash"
    "$BIN_DIR/NoteItCLI" completion fish > "$COMPLETIONS/noteit.fish"
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
# Shown when macOS asks for permission to control Notes (File › Import… › Apple Notes) or a browser (capture).
plist_str NSAppleEventsUsageDescription "NoteIt reads your notes from the Notes app when you choose to import them, and the address of the page you're viewing in your browser when you capture selected text."
# Services › Capture to NoteIt, for selected text in any app (handled by CaptureServiceProvider).
plutil -replace NSServices -json '[{"NSMenuItem":{"default":"Capture to NoteIt"},"NSMessage":"captureService","NSPortName":"NoteIt","NSSendTypes":["public.utf8-plain-text","NSStringPboardType"],"NSRequiredContext":{}}]' "$PLIST"
# noteit:// links (handled by URLSchemeHandler).
plutil -replace CFBundleURLTypes -json '[{"CFBundleURLName":"'"$BUNDLE_ID"'","CFBundleURLSchemes":["noteit"]}]' "$PLIST"
plutil -lint "$PLIST"

echo "==> Building AppIcon.icns"
# Resources/AppIcon.iconset is pre-rendered from scripts/make_icon.swift (scripts/render_icon.sh).
iconutil -c icns "$ROOT/Resources/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> Copying SwiftPM resources"
# Images loaded at runtime (AppResources) live in the target's resource bundle.
RESOURCE_BUNDLE="$(dirname "$BIN")/${APP_NAME}_${APP_NAME}.bundle"
[[ -d "$RESOURCE_BUNDLE" ]] || { echo "error: missing $RESOURCE_BUNDLE" >&2; exit 1; }
ditto "$RESOURCE_BUNDLE" "$APP/Contents/Resources/$(basename "$RESOURCE_BUNDLE")"

echo "==> Generating App Intents metadata"
CONST_VALS=""
for name in "${CONST_NAMES[@]}"; do
    if [[ -f "$CONST_DIR/$name" ]]; then
        CONST_VALS="$CONST_DIR/$name"
        break
    fi
done
[[ -n "$CONST_VALS" ]] || { echo "error: missing $APP_NAME.swiftconstvalues in $CONST_DIR" >&2; exit 1; }
# Its age can't be checked: the compiler leaves the file untouched when its contents wouldn't change.
grep -q "CreateNoteIntent" "$CONST_VALS" || { echo "error: $CONST_VALS doesn't list CreateNoteIntent" >&2; exit 1; }
INTENTS_WORK="$BUILD_DIR/appintents"
rm -rf "$INTENTS_WORK"
mkdir -p "$INTENTS_WORK"
find "$ROOT/Sources/$APP_NAME" -name '*.swift' > "$INTENTS_WORK/sources.txt"
echo "$CONST_VALS" > "$INTENTS_WORK/const-values.txt"
DEV_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
xcrun appintentsmetadataprocessor \
    --output "$APP/Contents/Resources" \
    --toolchain-dir "$DEV_DIR/Toolchains/XcodeDefault.xctoolchain" \
    --module-name "$APP_NAME" \
    --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" \
    --xcode-version "$(xcodebuild -version | awk '/Build version/ { print $3 }')" \
    --platform-family macOS \
    --deployment-target 14.0 \
    --target-triple "$(uname -m)-apple-macos14.0" \
    --source-file-list "$INTENTS_WORK/sources.txt" \
    --swift-const-vals-list "$INTENTS_WORK/const-values.txt"
for f in extract.actionsdata version.json; do
    [[ -f "$APP/Contents/Resources/Metadata.appintents/$f" ]] || { echo "error: App Intents metadata is missing $f" >&2; exit 1; }
done
grep -q "CreateNoteIntent" "$APP/Contents/Resources/Metadata.appintents/extract.actionsdata" \
    || { echo "error: App Intents metadata doesn't list CreateNoteIntent" >&2; exit 1; }

# Signs inside-out with the flags given, without --deep: Sparkle's pieces in the order its documentation gives,
# then the embedded rows deepest path first, then the app last with its own entitlements.
sign_inside_out() {
    local flags=("$@")
    local sparkle_b="$SPARKLE/Versions/B"
    for xpc in "$sparkle_b"/XPCServices/*.xpc; do
        if [[ "$(basename "$xpc")" == "Downloader.xpc" ]]; then
            codesign "${flags[@]}" --preserve-metadata=entitlements "$xpc"
        else
            codesign "${flags[@]}" "$xpc"
        fi
    done
    codesign "${flags[@]}" "$sparkle_b/Autoupdate"
    codesign "${flags[@]}" "$sparkle_b/Updater.app"
    codesign "${flags[@]}" "$SPARKLE"
    local entry embed_path embed_entitlements
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        IFS='|' read -r embed_path embed_entitlements <<< "${entry#*$'\t'}"
        if [[ -n "$embed_entitlements" ]]; then
            codesign "${flags[@]}" --entitlements "$ROOT/$embed_entitlements" "$APP/$embed_path"
        else
            codesign "${flags[@]}" "$APP/$embed_path"
        fi
    done < <(for entry in ${EMBEDDED[@]+"${EMBEDDED[@]}"}; do
        depth="$(tr -cd '/' <<< "${entry%%|*}" | wc -c | tr -d ' ')"
        printf '%s\t%s\n' "$depth" "$entry"
    done | sort -t $'\t' -k1,1nr)
    codesign "${flags[@]}" ${APP_SIGN_FLAGS[@]+"${APP_SIGN_FLAGS[@]}"} --entitlements "$ENTITLEMENTS" "$APP"
}

# An ad-hoc signature's default designated requirement is its cdhash, which changes on every build, and
# TCC then stops honouring grants such as Accessibility. Pin it to the bundle id instead.
APP_SIGN_FLAGS=()
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    APP_SIGN_FLAGS=(--requirements "=designated => identifier \"$BUNDLE_ID\"")
fi

if [[ "$DISTRIBUTION_SIGNING" == "1" ]]; then
    echo "==> Codesigning for distribution ($SIGN_IDENTITY, hardened runtime)"
    SIGN_FLAGS=(--force --options runtime --sign "$SIGN_IDENTITY")
    # Ad-hoc signatures can't carry a secure timestamp.
    [[ "$SIGN_IDENTITY" == "-" ]] || SIGN_FLAGS+=(--timestamp)
    sign_inside_out "${SIGN_FLAGS[@]}"
else
    echo "==> Codesigning (ad-hoc)"
    sign_inside_out --force -s -
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
