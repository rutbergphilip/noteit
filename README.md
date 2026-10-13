<!--
  PLACEHOLDER: https://github.com/rutbergphilip/noteit is a placeholder repository URL.
  The repository has not been created yet. Update the links in this file, CONTRIBUTING.md,
  SECURITY.md, CODE_OF_CONDUCT.md and .github/ if it ends up somewhere else.
-->

# NoteIt

**Notes at the speed of thought.** A native macOS notes app with Apple Notes speed, power-user formatting, capture from anywhere, and optional end-to-end encrypted sync through storage you own.

[![License: AGPL-3.0-or-later](https://img.shields.io/badge/license-AGPL--3.0--or--later-blue.svg)](LICENSE)
[![CI](https://github.com/rutbergphilip/noteit/actions/workflows/ci.yml/badge.svg)](https://github.com/rutbergphilip/noteit/actions/workflows/ci.yml)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-lightgrey.svg)
![Swift](https://img.shields.io/badge/Swift-6%20toolchain-orange.svg)

NoteIt is a SwiftUI and AppKit app with no third-party dependencies. Your notes are files on your Mac. There's no account and no NoteIt server. If you want your Macs in sync, point NoteIt at a folder or an S3-compatible bucket you control, such as a MinIO instance on your NAS, and it encrypts everything before it leaves the machine.

> NoteIt was formerly called Inkwell. Existing notes, settings and sync setup migrate automatically the first time NoteIt launches; if Inkwell is still open, NoteIt asks to quit it first.

> **Status:** working app, single user, macOS 14 Sonoma or later. The visuals are engineering defaults and the app icon is a code-drawn placeholder. There are no signed or notarized release builds yet, so build it from source.

## Features

- **Capture from anywhere**
  - Global hotkeys for *Show / Hide NoteIt*, *New Note* and *Quick Capture*. They're unbound by default, you record your own, and they need no Accessibility permission.
  - A Spotlight-style **Quick Capture** panel that floats over any app, including full-screen ones, and keeps your draft when dismissed.
  - A **menu bar panel** with search, a quick-note composer, and Pinned and Recent notes. It's fully keyboard-driven.
  - A *Menu bar only* mode and *Launch at login*.
- **Organize lightly**
  - Notebooks with a color and an SF Symbol icon. Drag to reorder, and drop notes onto them to move them.
  - Automatic `#hashtag` tags, plus Pinned and Recent (last 7 days) smart views.
  - Search across titles and full text that ignores case and accents.
- **Format richly**
  - Title, heading and subheading styles, bold, italic, underline, strikethrough and inline code.
  - Bulleted, numbered and checklist lists, tables, code blocks, quotes, dividers, links and images.
  - Text colors and highlights.
  - Markdown as you type: `#`, `-`, `1.`, `[ ]`, `>`, ```` ``` ````, `---`, `**bold**`, `*italic*`, `` `code` `` and `~~strike~~`.
  - About 30 keyboard shortcuts. See the [shortcut reference](docs/design/HANDOFF.md#10-keyboard-shortcut-reference).
- **Native and local-first**
  - Light and dark mode, system accent color, and standard menus and Settings.
  - Notes are stored as RTFD in `~/Library/Application Support/NoteIt/`, with autosave and atomic writes.
- **Optional sync** between Macs through storage you own, end-to-end encrypted by default. See below.

## Sync & encryption

Sync is off until you connect it in **Settings › Sync**. Until then NoteIt makes no network requests and runs no sync timers.

| Provider | Notes |
|---|---|
| Folder | Any folder: a NAS share, iCloud Drive, Dropbox or a USB drive |
| Amazon S3 | Your own AWS bucket |
| Cloudflare R2 | S3-compatible, no egress fees |
| Backblaze B2 | S3-compatible |
| Google Cloud | Cloud Storage through its S3-compatible API with HMAC keys |
| MinIO / NAS | Self-hosted S3 on your network; `http://` is allowed for local servers |
| Custom S3 | Any other S3-compatible service, such as Wasabi or Synology C2 |

- **The storage is yours.** NoteIt doesn't run a server and never sees your data. On a second Mac, point it at the same location and enter the same passphrase.
- **End-to-end encryption is on by default.** Notes use AES-GCM with a key derived from your passphrase through PBKDF2-HMAC-SHA256. Only a small `manifest.json` that describes the format is stored unencrypted. The passphrase stays in the macOS Keychain and is never uploaded. **If you lose it, your synced notes can't be decrypted.**
- **Conflicts never lose data.** If a note changes on two Macs before they sync, the remote version is kept as a badged conflict copy and listed under a *Conflicts* filter.
- **It's lightweight.** It runs a single listing per check, once a minute while you use NoteIt and every 10 minutes in the background, on a low-priority thread.

The full sync and encryption design is documented in [`docs/specs/2026-10-12-sync-design.md`](docs/specs/2026-10-12-sync-design.md). Its known limitations are listed in [the handoff's known gaps](docs/design/HANDOFF.md#9-known-gaps--opportunities). Folders synced by tools like Dropbox and S3 providers without conditional writes get best-effort race protection only.

## Install / build from source

**Requirements**

- macOS 14 Sonoma or later.
- Xcode 16 / Swift 6 toolchain (package uses Swift 5 language mode): Xcode 16 or later, or the matching Command Line Tools. The package manifest declares `swift-tools-version:5.10`.
- Running the unit tests needs Xcode, because the Command Line Tools don't ship XCTest.

```sh
git clone https://github.com/rutbergphilip/noteit.git
cd noteit
./scripts/build_app.sh      # release build → ~/Applications/NoteIt.app
open ~/Applications/NoteIt.app
```

`build_app.sh` builds in release mode, writes `Info.plist`, renders the placeholder icon, ad-hoc signs the bundle and installs it atomically. You can set `NOTEIT_INSTALL_DIR`, `NOTEIT_VERSION` and `NOTEIT_BUILD` to override the install location and version numbers.

For development:

```sh
swift build                 # debug build
swift run NoteIt            # run unbundled; launch at login is unavailable this way
NOTEIT_DATA_DIR=~/scratch/noteit swift run NoteIt   # use a scratch library instead of your real notes
```

Debug builds accept extra launch arguments and environment variables for screenshots and self-tests. They're listed in the [engineer section of the handoff](docs/design/HANDOFF.md#debug--test-launch-arguments).

## Testing

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

- 175 XCTest cases in `Tests/NoteItSyncTests/` cover the sync planner, the engine against in-memory and faulty backends, the folder backend (including a cross-process lock test), S3 request handling, SigV4 signing, list parsing, crypto and the migration from Inkwell.
- `DEVELOPER_DIR` points SwiftPM at Xcode's toolchain without changing `xcode-select`.
- **Live S3 tests** (`LiveS3EmulatorTests`) are skipped by default. With Docker running, this starts [Floci](https://github.com/floci-io/floci) emulators, runs the suite against each one, and removes the containers:

  ```sh
  ./scripts/live_s3_tests.sh            # Amazon S3 and Google Cloud Storage emulators
  ./scripts/live_s3_tests.sh aws        # just one
  ```

  To test against another server, such as your own MinIO, set `NOTEIT_LIVE_S3_ENDPOINT` and optionally `NOTEIT_LIVE_S3_REGION`, `_BUCKET`, `_ACCESS_KEY`, `_SECRET` and `_CREATE_BUCKET=1`.
- The app layer is checked with debug-only self-test modes such as `NOTEIT_SYNC_SELFTEST=1` and `NOTEIT_EDITOR_SELFTEST=1`. Always pair them with `NOTEIT_DATA_DIR`.
- CI runs `swift build`, `swift test` and a release build on macOS. The live emulator tests don't run in CI, because the macOS runners have no Docker.

## Roadmap

These items aren't built yet. Contributions and design discussion are welcome.

- **A self-hosted web app.** A Nuxt app you can run in Docker next to your storage. It will read and write the same encrypted sync format, so a browser becomes another device. The spec is [`docs/specs/2026-10-13-web-app-design.md`](docs/specs/2026-10-13-web-app-design.md).
- **Sync:**
  - a WebDAV backend
  - a side-by-side conflict compare view
  - changing the passphrase, or turning encryption on for an existing library
- **iOS / iPadOS:** capture first. The `NoteItSync` library has no AppKit dependency, so an iOS app could reuse it.
- **Export and import:** export to Markdown, PDF and HTML, plus print and a Share menu. Import from Apple Notes, Bear and Obsidian.
- **Trash:**
  - a *Recently Deleted* view and undo for deletes (deleted bodies already go to a hidden `.trash/` folder)
  - version history
- **Organization:** nested notebooks, tag rename and merge, styled tag chips, saved searches, `[[wiki links]]` and backlinks.
- **Search:** ranking and highlighting of matches.
- **Onboarding:** a first-run flow for hotkeys, the menu bar and the second-Mac sync setup.
- **Polish:**
  - a real app icon, menu bar glyph and motion language (see the [design brief](docs/design/HANDOFF.md#7-design-brief--deliverables))
  - an accessibility audit
  - notarized builds and auto-update

## Project layout

```text
Package.swift                 Swift package: NoteIt (app), NoteItSync (library), NoteItSyncTests
Sources/NoteIt/               the macOS app (SwiftUI + AppKit)
├── App/                      app entry, AppDelegate, window routing
├── Model/                    NoteStore, notebooks and notes, seed content
├── Views/                    main window: sidebar, note list, editor container
├── Editor/                   rich-text editor, markdown shortcuts, formatting toolbar
├── MenuBar/                  menu bar panel, Quick Capture
├── Hotkeys/                  Carbon global hotkeys, shortcut recorder
├── Settings/                 Settings tabs and preferences
└── Sync/                     SyncController, NoteStore adapter, provider config, Keychain
Sources/NoteItSync/           sync engine with no AppKit dependency
├── Storage/                  folder and S3 backends, SigV4
├── Crypto/                   PBKDF2 key derivation, AES-GCM
├── Engine/                   SyncPlanner (pure decision table), SyncEngine
├── Model/                    manifest, sync state, records
└── Migration/                app identity, env vars, Inkwell → NoteIt migration
Tests/NoteItSyncTests/        XCTest suite (+ opt-in live S3 tests)
scripts/                      build_app.sh, live_s3_tests.sh, make_icon.swift
design/                       design system: brand, tokens, components (source of truth)
docs/design/HANDOFF.md        original product and design handoff (also the deep engineering reference)
docs/specs/, docs/plans/      design specs and implementation plans
```

## Contributing

Contributions are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) for dev setup, code style and the DCO sign-off (`git commit -s`), and follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Security

Please don't open public issues for vulnerabilities. Report them through GitHub private vulnerability reporting. [SECURITY.md](SECURITY.md) covers the scope and the threat model.

## License

NoteIt is free software, licensed under the [GNU Affero General Public License v3.0 or later](LICENSE) (AGPL-3.0-or-later). If you distribute NoteIt, or a modified version of it, or run a modified version as a network service, you must make the corresponding source available under the same license.

Copyright © 2026 Philip Rutberg and contributors.

SPDX-License-Identifier: AGPL-3.0-or-later

## Design

[`design/`](design/) is the design source of truth: the brand book, tokens, component specs, icons and the implementation plan. Start with [`design/README.md`](design/README.md).

The original product and design handoff, the brief the design team worked from, is kept at [docs/design/HANDOFF.md](docs/design/HANDOFF.md). It covers personas, the product tour, the visual language, the design brief, naming, known gaps, the full keyboard shortcut reference and the engineering internals.
