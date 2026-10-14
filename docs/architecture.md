# Architecture

This page explains how NoteIt is put together: where notes are stored, how the editor keeps formatting, how hotkeys and the menu bar work, and how sync fits in. For building, debugging and testing, see [development.md](development.md).

## Overview

NoteIt is a Swift package with two main targets. Its only third-party dependency is Sparkle, used for in-app updates:

| Target | What it is |
|---|---|
| `NoteIt` (`Sources/NoteIt/`) | The macOS app, written in SwiftUI and AppKit. It also uses Carbon for global hotkeys and ServiceManagement for the login item. |
| `NoteItSync` (`Sources/NoteItSync/`) | The sync engine, storage backends, encryption and the Inkwell → NoteIt migration helpers. It uses only Foundation, CryptoKit, CommonCrypto and Security, with no AppKit or app types, so it can be tested on its own and reused on other platforms. |

Tests live in `Tests/NoteItSyncTests/` (the sync library) and `Tests/NoteItTests/` (app launch and Quick Capture behavior).

### App folders (`Sources/NoteIt/`)

| Folder | What's in it |
|---|---|
| `App/` | `NoteItApp` (main window, Settings, menu bar extra and menu commands), `AppDelegate` (activation policy, hotkey wiring, debug arguments), `WindowRouter` (show, hide and focus), `AppUpdater` (in-app updates), and the launch-time migration from Inkwell (`LaunchMigration`, `LibraryLauncher`, `LegacyAppQuitter`, `LegacyAppMonitor`) |
| `Design/` | `Tokens` (colors, spacing, radii and chrome type styles) and `AppResources` (app icon and menu bar glyph images) |
| `Model/` | `Models` (notebooks, note metadata, sidebar selection, palette), `NoteStore` (the single observable store: queries, editing, tags and persistence), `NoteStore+Trash` (Recently Deleted), `VersionHistory`, seed content |
| `Views/` | The main window: three-column split, sidebar, note list, editor container with the note header and conflict badge, empty states, notebook sheet, the sync status pill, the Recently Deleted banner, undo toast and confirmations, and the Version History sheet |
| `Editor/` | `RichTextEditor` (the SwiftUI wrapper), `NoteItTextView` (an `NSTextView` subclass whose layout manager draws code blocks, quotes, dividers and checkboxes), `TextFormatter`, `MarkdownShortcuts`, `FormatCommand` (every formatting command and its shortcut), `FormattingToolbar`, `EditorStyles` (type scale, colors and block kinds) |
| `MenuBar/` | The menu bar panel, the Quick Capture panel, the panel search field and shared views |
| `Hotkeys/` | `HotkeyAction`, `HotkeyManager` (Carbon `RegisterEventHotKey`), `KeyCombo` and the `ShortcutRecorder` view |
| `Settings/` | The Settings window and its General, Shortcuts, Editor, Sync and About tabs, plus `Preferences` (defaults keys) |
| `Sync/` | `SyncController`, `NoteStoreSyncAdapter`, `SyncConfiguration` (providers and settings) and `Keychain` |

## Storage

Your library lives in `~/Library/Application Support/NoteIt/`. Set `NOTEIT_DATA_DIR` to use another folder (see [development.md](development.md)).

```text
~/Library/Application Support/NoteIt/
├── .initialized                     marker: first launch (seeding) has happened
├── library.json                     notebooks and note metadata (pretty-printed, ISO-8601 dates); notes in Recently Deleted have a `deletedAt` date
├── library.corrupt-<ts>.json        backup of an unreadable library.json, if that ever happens
├── search-index.json                folded plain text of each note, for search
├── seed-manifest.json               IDs and revisions of the sample content, until sync is connected
├── tombstones.json                  removed notes whose bodies haven't been moved to .trash yet
├── sync-state-<hash>.json           last-synced state per remote store (only while sync is set up)
├── sync-deletions.json              local deletions not yet pushed (only while sync is set up)
├── notes/<uuid>.rtfd                each note body as RTFD (rich text plus image attachments)
├── notes/<uuid>.rtfd.corrupt-<ts>   backup of an unreadable note body
├── recovery/<uuid>-<ts>.rtfd        last-resort copies of bodies that couldn't be saved at quit
├── history/<uuid>/<yyyyMMdd'T'HHmmss'Z'>.rtfd   earlier versions of each note (this Mac only)
└── .trash/<uuid>-<ts>.rtfd          bodies of removed notes (never deleted outright)
```

- **Saving.** The editor hands edits to `NoteStore` after 0.3 s of idle time, and right away when you switch notes, close the window, switch apps or quit. The store writes to disk about 0.5 s later. Writes are atomic: an RTFD body is written next to the old one and swapped in. A failed write is retried after 5 s, and at quit any body that still can't be saved is copied into `recovery/`.
- **First launch.** Sample notebooks and notes are created only on a real first launch: no `library.json`, no note bodies and no `.initialized` marker.
- **Recovery.**
  - If `library.json` is missing but note bodies exist, the library is rebuilt from `notes/*.rtfd`.
  - If `library.json` can't be read, it's copied to `library.corrupt-<ts>.json`, whatever can be salvaged is kept, and the rest is rebuilt from the bodies. If that backup fails, the original is never overwritten.
  - If a note body can't be read, it's copied to `<uuid>.rtfd.corrupt-<ts>` and the note opens empty with an error. If that backup fails, writes to the note are blocked.
- **Recently Deleted.** Deleting a note only sets its `deletedAt` date and gives it a new revision, so it syncs like any other edit. Deleted notes are left out of every list, search, tag and count except *Recently Deleted*, and open read-only. Deleting a notebook moves its notes there too; they keep the notebook ID, and recovery falls back to the notebook named Inbox (or no notebook) when it's gone. `NoteStore+Trash.swift` has this logic. Notes deleted more than 30 days ago are removed at launch and once a day.
- **Removing for good** (*Delete Now*, *Empty Recently Deleted* or the 30-day purge). The metadata removal is saved first, then the body moves to `.trash/` and the note's history is removed. While sync is set up, the removal is also recorded in `sync-deletions.json` and pushed as a tombstone.
- **Version history** (`VersionHistory.swift`). Before a save replaces a note's body on disk, the old body is copied to `history/` if the newest version is more than 10 minutes old (or there's none). A version is always kept before restoring a version and before sync replaces a body with a different one. Each note keeps up to 50 versions, none older than 30 days. Versions are written to a temp package and renamed into place. They aren't synced, indexed or listed in `library.json`.
- **Starting over.** Quit NoteIt and delete the whole folder, including the hidden `.initialized` marker, `.trash/` and `history/`.
- **Preferences** live in `UserDefaults`: `hideDockIcon`, `showMenuBarIcon`, `launchAtLogin`, `editorFontSize`, `defaultNotebookID` and the hotkey bindings. Sync adds `syncConfiguration` (non-secret settings as JSON), `syncDeviceID` and `syncLastSync`. Secrets are kept only in the Keychain.

### Migration from Inkwell

NoteIt used to be called Inkwell. On launch, `LibraryLauncher` and `LaunchMigration` move an existing `~/Library/Application Support/Inkwell/` folder to `NoteIt/` (asking Inkwell to quit first if it's running), leave a relative link at the old path, copy over preferences from the `com.inkwell.app` defaults domain, and re-register the login item. Keychain secrets are copied from the old `com.inkwell.app.sync` service the first time they're read. Nothing is migrated when `NOTEIT_DATA_DIR` is set. The older `INKWELL_*` environment variable names are still read as a fallback.

## Editor

The editor is an `NSTextView` that stores each note as RTFD.

- **Block types.** RTFD drops custom attributes, so the kind of each paragraph (title, heading, subheading, body, code block, quote, divider) is stored as a sentinel `defaultTabInterval` value in its paragraph style. That way a heading stays a heading even if you change the default font size. Paragraphs without a sentinel, from older notes, fall back to guessing from the font size. See `BlockKind` and the `*Sentinel` constants in `EditorStyles.swift`.
- **Type scale.** Every editor style is derived from the *Default font size* setting (15 pt by default). Title is body + 12 pt (bold), heading body + 5 (semibold), subheading body + 1.5 (semibold), and code body − 1 (SF Mono); see `EditorStyles.swift`.
- **Drawing.** `NoteItTextView`'s layout manager draws code block backgrounds, quote bars, dividers and round checkboxes.
- **Markdown shortcuts** are handled in `MarkdownShortcuts.swift`, and every formatting command, with its menu title, toolbar icon and shortcut, is defined in `FormatCommand.swift`. The full list is in [keyboard-shortcuts.md](keyboard-shortcuts.md).
- **Tags.** `#hashtags` are collected from note text, lowercased. A `#` counts only at the start of the text or after whitespace, an opening bracket or quote, `,` or `;`. Hashtags inside inline code, code blocks and links are ignored.
- **Search** matches every word of the query against the title and full text. Matching ignores case, accents and character width, using the folded text in `search-index.json`.

## Export

Export code lives in `Export/`.

- **`NoteBlocks`** turns a note body into blocks (paragraphs of each `BlockKind`, list items with their level, code blocks, dividers, tables) and inline runs. It reuses the editor's own helpers (`EditorStyle.blockKind`, `listMarker`, `listLevel`), so it reads notes exactly the way the editor does.
- **`MarkdownWriter`** and **`HTMLWriter`** render those blocks. Markdown returns the text plus image and file assets, which are written to a `<name> assets` folder next to the file. HTML is a single file with images embedded as data URLs.
- **`NoteExporter`** writes each format, picks safe, unique file names, and lays out notebook and Export All folders. PDF and print share one print view, so they look the same. `exportableNotes(in:)` is the one place that decides which notes get exported.
- **`ExportActions`** holds the panels, sharing and Copy as Markdown, used by `ExportCommands` and the toolbar Share button. Before reading a note it asks an open editor to save pending edits.

## Global hotkeys

Global hotkeys use Carbon's `RegisterEventHotKey`, so they work from any app without Accessibility permission. `HotkeyManager` registers the bindings saved in `UserDefaults` and reports combinations that another app already owns. None are bound by default. `ShortcutRecorder` is the Settings control that records them.

## Menu bar and Quick Capture

- The menu bar item is a SwiftUI `MenuBarExtra` with a window-style panel (`MenuBarView`). Its icon is a template image from `Sources/NoteIt/Resources/`, which switches to a "capturing" variant while Quick Capture is open.
- Quick Capture (`QuickCapturePanel.swift`) is a non-activating floating panel, so the app you were using stays in front. It appears on every Space, including over full-screen apps. Its draft (title, body and notebook) is kept until you save or discard it.
- In *Menu bar only* mode the app switches to the accessory activation policy and hides its Dock icon. The menu bar icon can't be turned off in that mode, so NoteIt stays reachable.

## Updates

`AppUpdater` wraps Sparkle's `SPUStandardUpdaterController`. It only starts when NoteIt runs from an app bundle whose `Info.plist` has `SUFeedURL` and `SUPublicEDKey` (`build_app.sh` adds both). Under `swift run`, in tests, or without those keys, it stays off and the update controls are hidden. When it's on, *Check for Updates…* appears in the app menu and the menu bar panel, and Settings › General has an *Updates* section. Sparkle asks on the second launch whether to check automatically, and does all checking on its own schedule. Each update archive is signed with an EdDSA key, and Sparkle checks it against `SUPublicEDKey` before installing.

## Sync

The full design, including the decision table, remote format and the reasoning behind it, is in [docs/specs/2026-10-12-sync-design.md](specs/2026-10-12-sync-design.md). In short:

- **`NoteItSync`** holds the engine and everything it needs.
  - `Storage/`: the `StorageBackend` protocol with conditional writes and deletes, plus `FolderBackend` (atomic writes, plus an advisory `flock` on a hidden lock file), `S3Backend` (AWS Signature V4, `If-Match` / `If-None-Match`, with a best-effort fallback for providers that don't support them) and `InMemoryBackend` for tests.
  - `Crypto/`: PBKDF2-HMAC-SHA256 key derivation (210,000 iterations) and AES-GCM, with each object's key used as additional authenticated data.
  - `Engine/`: `SyncPlanner`, a pure decision table that picks push, pull, conflict or delete for each record, and `SyncEngine`, an actor that runs one pass at a time.
- **App side.**
  - `NoteStore` gives every note and notebook a `revision` that changes on each edit, and records local deletions while sync is set up.
  - `NoteStoreSyncAdapter` connects the engine to the store. It does the heavy file work off the main thread, and it refuses to apply a remote change to a note you've edited since the pass started, so the next pass turns it into a conflict copy instead.
  - `SyncController` owns scheduling and status. Nothing runs until sync is set up. After that it syncs every 60 s while NoteIt is in use, every 10 minutes in the background, 2 s after a local edit (at most 10 s), shortly after waking from sleep, and on **Sync Now**. Failures back off from 15 s up to 10 minutes.
- **Secrets** are stored in the Keychain under the service `io.github.rutbergphilip.noteit.sync`, with the accounts `s3-access-key`, `s3-secret` and `passphrase`. Folders are remembered as security-scoped bookmarks.
- **Remote layout.** Everything goes under `inkwell/v1/` in the chosen folder or bucket. `inkwell` is the protocol name from before the rename, and it must stay that way.

  ```text
  inkwell/v1/
  ├── manifest.json            format version and encryption parameters; never encrypted
  ├── notebooks/<id>.json      notebook record
  ├── notes/<id>.meta          note metadata, including the hash of the body it expects
  ├── notes/<id>.body          the note body (flattened RTFD)
  ├── tombstones/<id>.json     deletion marker
  └── devices/<deviceID>.json  device name and last sync, shown in Settings › Sync
  ```

  With encryption on, everything except `manifest.json` is encrypted.

### Sync status

The sidebar footer and the menu bar panel show the current sync status:

| State | Symbol | Label |
|---|---|---|
| Synced | `checkmark.icloud` | Synced |
| Syncing | `arrow.triangle.2.circlepath` | Syncing |
| Offline | `icloud.slash` | Offline |
| Error | `exclamationmark.icloud` | Sync Issue |
| Needs passphrase | `lock.icloud` | Locked |

Short background passes don't show *Syncing*; the label only changes if a pass takes longer than 0.7 s.
