# Development

This page covers building NoteIt, running it against a scratch library, and the debug options used for screenshots and self-tests. For how the app is put together, see [architecture.md](architecture.md). For pull request guidelines, see [CONTRIBUTING.md](../CONTRIBUTING.md).

## Requirements

- macOS 14 Sonoma or later.
- Xcode 16 or later, or the matching Command Line Tools. The manifest declares `swift-tools-version:5.10`.
- Running the unit tests needs Xcode, because the Command Line Tools don't include XCTest.
- The only third-party dependency is [Sparkle](https://sparkle-project.org) for in-app updates. SwiftPM fetches it on the first build.

## Build and run

```sh
swift build                 # debug build
swift run NoteIt            # run unbundled; launch at login, updates and reminder notifications are unavailable this way
./scripts/build_app.sh      # release build: build/NoteIt.app → ~/Applications/NoteIt.app
```

`build_app.sh`:

- builds in release mode, for the host architecture or as a universal (Apple silicon and Intel) binary;
- embeds `Sparkle.framework` in `Contents/Frameworks`;
- writes `Info.plist` with the bundle ID from `AppIdentity.swift`, a minimum macOS version of 14.0, App Transport Security's `NSAllowsLocalNetworking` (so plain `http://` MinIO or NAS servers on your local network work), and Sparkle's feed URL and public key;
- builds `AppIcon.icns` from `Resources/AppIcon.iconset` with `iconutil`;
- signs the app (ad-hoc by default, or with a Developer ID and the hardened runtime for releases) and installs it atomically: it stages a copy, verifies it, swaps it in, and restores the previous version if anything fails. Ad-hoc builds give the app a designated requirement on its bundle ID (`identifier "…"`) instead of the default cdhash, so permissions such as Accessibility keep working after you rebuild; `codesign -dr - NoteIt.app` shows it.

| Variable | Default | Effect |
|---|---|---|
| `NOTEIT_INSTALL_DIR` | `$HOME/Applications` | Where the app is installed |
| `NOTEIT_VERSION` | `0.1.0` | `CFBundleShortVersionString` |
| `NOTEIT_BUILD` | a `YYYYMMDDHHMM` timestamp | `CFBundleVersion` |
| `NOTEIT_SIGN_IDENTITY` | `-` (ad-hoc) | Signing identity. Any other value signs for distribution: hardened runtime, secure timestamp, and Sparkle's nested parts signed before the app |
| `NOTEIT_UNIVERSAL` | unset | `1` builds for both `arm64` and `x86_64` (slower) |
| `NOTEIT_HARDENED_RUNTIME` | unset | `1` uses the distribution signing steps with an ad-hoc identity, to check them without a certificate. The result won't launch, because ad-hoc code has no Team ID for library validation |

The app icon and menu bar glyph are pre-rendered. To regenerate them after changing `scripts/make_icon.swift` or `scripts/make_menubar_glyph.swift`, run `scripts/render_icon.sh`.

## Use a scratch library

Set `NOTEIT_DATA_DIR` so a dev build never touches your real notes (`~` is expanded):

```sh
NOTEIT_DATA_DIR=~/scratch/noteit swift run NoteIt
```

The older `INKWELL_*` names of all `NOTEIT_*` variables still work as a fallback.

To try the organise routes of the Local API against a scratch library, run with `NOTEIT_LOCAL_API_DEBUG=1` and use the token it prints (the port is 47600 unless it was changed):

```sh
curl -s -H "Authorization: Bearer $NOTEIT_LOCAL_API_TOKEN" "http://127.0.0.1:47600/v1/tasks?includeCompleted=1"
curl -s -H "Authorization: Bearer $NOTEIT_LOCAL_API_TOKEN" -H 'Content-Type: application/json' \
     -d '{"from":"work","to":"job"}' http://127.0.0.1:47600/v1/tags/rename
```

## Tests

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

`DEVELOPER_DIR` points SwiftPM at Xcode's toolchain without changing `xcode-select`. The live S3 tests are skipped by default; the [README](../README.md#testing) and [CONTRIBUTING.md](../CONTRIBUTING.md#tests) explain how to run them against emulators or your own server.

## Debug launch arguments

These only exist in debug builds (`#if DEBUG`). Release builds from `build_app.sh` ignore them.

| Argument | Effect |
|---|---|
| `--self-test` | Runs the hotkey self-test and exits with its result |
| `--debug-open-settings [--debug-settings-tab general\|shortcuts\|editor\|sync\|about]` | Opens Settings, optionally on a given tab |
| `--debug-preview-bindings` | Shows sample hotkey bindings without saving them, for screenshots |
| `--debug-menubar-preview` | Shows the menu bar panel in a normal window, for screenshots |
| `--debug-quick-capture` | Opens Quick Capture at launch |
| `--debug-onboarding` | Opens the Welcome guide at launch |
| `--debug-find <query> [--debug-replace <text>]` | Opens the note's find bar with a query, and the replace row when a replacement is given |
| `--debug-dark` | Forces dark mode |
| `--debug-show-conflicts` | Selects the Conflicts filter and its first note |
| `--debug-sync-provider <folder\|awsS3\|cloudflareR2\|backblazeB2\|googleCloud\|minio\|customS3>` | Preselects a provider in Settings › Sync. For `folder` with `NOTEIT_DATA_DIR` set, the folder is prefilled with a `remote` folder next to the data folder; S3 providers get their default region, path style and endpoint |
| `--debug-sync-endpoint <url>` | With an S3 provider above, prefills the endpoint |

Example:

```sh
swift run NoteIt --debug-open-settings --debug-settings-tab shortcuts
```

## Environment variables

Available in all builds:

| Variable | Effect |
|---|---|
| `NOTEIT_DATA_DIR=<path>` | Uses `<path>` instead of `~/Library/Application Support/NoteIt`, and skips the Inkwell migration |

Debug builds only:

| Variable | Effect |
|---|---|
| `NOTEIT_EDITOR_SELFTEST=1` | Runs a scripted editor exercise (markdown, lists, toolbar, saving) and logs `SELFTEST` lines. It edits real notes, so always pair it with `NOTEIT_DATA_DIR` |
| `NOTEIT_EDITOR_SELFTEST_DARK=1` | With the above, forces dark mode |
| `NOTEIT_EDITOR_SELFTEST_SHOW=<title prefix>` | With the above, only opens the matching note, for screenshots |
| `NOTEIT_EDITOR_SELFTEST_NARROW=1` | With the above, shrinks the window to 900 pt wide |
| `NOTEIT_MARKDOWN_ROOT=<folder>` | Debug builds only. Opens the library with its notes as Markdown files in `<folder>` (created when missing; `~` is expanded), keeping app data in the data folder. Refused, with a log line, when the data folder already has a library location file or RTFD notes. Use with `NOTEIT_DATA_DIR` |
| `NOTEIT_STORE_SELFTEST=1` | Forces body write failures and checks that the library and search index stay consistent, then quits. `newnote` checks a new note whose first save fails, then simulates a crash; `quit` logs the files on disk after launch and quits. Logs `STORETEST` lines. Use with `NOTEIT_DATA_DIR` |
| `NOTEIT_STORE_CRASHPOINT=<name>` | Exits immediately when the store reaches the named point, to simulate a crash |
| `NOTEIT_SYNC_SELFTEST=1` | Runs the sync self-test against scratch stores inside `NOTEIT_DATA_DIR` (required), logs `SYNCTEST` lines and exits non-zero on failure. `NOTEIT_SYNC_SELFTEST_LIBRARY=<path>` also loads a copy of that `library.json`; `NOTEIT_SYNC_SELFTEST_MARKDOWN=1` gives the second device of each pair a Markdown library |
| `NOTEIT_SYNC_CONFIG=<json>` | Connects sync at launch without the UI. The JSON is a `SyncConfiguration` (`provider`, `folderPath` or `s3`, `encrypted`, `deviceName`, …) plus optional `passphrase`, `accessKey` and `secret`. Nothing is written to `UserDefaults` or the Keychain, and a missing `folderPath` is created. When the data folder already has sync state for this config, it resumes like a normal launch instead of reconnecting, so relaunches keep their sync state |
| `NOTEIT_SYNC_INTERVAL=<seconds>` | Replaces both sync intervals and the 15 s backoff base, and logs each pass that changed something |
| `NOTEIT_DEBUG_EDIT_AFTER=<seconds>` | After the delay, appends "Edited on *device* at *time*" to the selected or first note, as if typed. Handy for testing two instances |
| `NOTEIT_DEBUG_UPDATE_CREDENTIALS=<seconds>:<accessKey>:<secret>` | After the delay, runs *Update Credentials…* without the UI |
| `NOTEIT_LOCAL_API_DEBUG=1` | With `NOTEIT_DATA_DIR`, turns the Local API on without touching `UserDefaults`, keeps paired clients in memory instead of the Keychain, and prints one token with every scope to stderr as `NOTEIT_LOCAL_API_TOKEN=nit_…`. `local-api.json` goes in the data folder |
| `NOTEIT_APP_SUPPORT_DIR=<folder>` | Stands in for `~/Library/Application Support`, to try the Inkwell → NoteIt migration safely |
| `NOTEIT_DEBUG_LEGACY_BUNDLE_ID=<bundle id>` | Treats another running app as Inkwell, to test the "Quit Inkwell" prompt |

Two instances syncing through a local folder, each with its own scratch library:

```sh
NOTEIT_DATA_DIR=~/scratch/a NOTEIT_SYNC_INTERVAL=5 \
NOTEIT_SYNC_CONFIG='{"provider":"folder","folderPath":"~/scratch/remote","encrypted":true,"deviceName":"A","passphrase":"correct horse battery"}' \
swift run NoteIt
```

Run it again with `~/scratch/b` and `"deviceName":"B"` in a second terminal.
