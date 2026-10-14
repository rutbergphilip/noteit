#!/usr/bin/env bash
# Writes the Homebrew cask for a release into a checkout of rutbergphilip/homebrew-tap:
#   ./scripts/update_cask.sh 1.2.0 <sha256 of NoteIt-1.2.0.dmg> path/to/homebrew-tap
set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "usage: $0 <version> <sha256> <tapdir>" >&2
    exit 2
fi
VERSION="$1"
SHA256="$2"
TAP_DIR="$3"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: version must be MAJOR.MINOR.PATCH, got '$VERSION'" >&2; exit 1; }
[[ "$SHA256" =~ ^[0-9a-f]{64}$ ]] || { echo "error: sha256 must be 64 lowercase hex characters" >&2; exit 1; }
[[ -d "$TAP_DIR" ]] || { echo "error: $TAP_DIR is not a directory" >&2; exit 1; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE_ID="$(sed -nE 's/^ *public static let bundleID = "([^"]+)".*/\1/p' "$ROOT/Sources/NoteItSync/Migration/AppIdentity.swift" | head -n 1)"
DATA_FOLDER="$(sed -nE 's/^ *public static let dataFolderName = "([^"]+)".*/\1/p' "$ROOT/Sources/NoteItSync/Migration/AppIdentity.swift" | head -n 1)"
[[ -n "$BUNDLE_ID" && -n "$DATA_FOLDER" ]] || { echo "error: couldn't read AppIdentity" >&2; exit 1; }

mkdir -p "$TAP_DIR/Casks"
CASK="$TAP_DIR/Casks/noteit.rb"
cat > "$CASK" <<EOF
cask "noteit" do
  version "$VERSION"
  sha256 "$SHA256"

  url "https://github.com/rutbergphilip/noteit/releases/download/v#{version}/NoteIt-#{version}.dmg"
  name "NoteIt"
  desc "Fast notes with Quick Capture and encrypted sync"
  homepage "https://github.com/rutbergphilip/noteit"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: :sonoma

  app "NoteIt.app"

  zap trash: [
    "~/Library/Application Support/$DATA_FOLDER",
    "~/Library/Caches/$BUNDLE_ID",
    "~/Library/HTTPStorages/$BUNDLE_ID",
    "~/Library/Preferences/$BUNDLE_ID.plist",
    "~/Library/Saved Application State/$BUNDLE_ID.savedState",
  ]
end
EOF
echo "$CASK"
