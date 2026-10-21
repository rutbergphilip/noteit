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
| `App/` | `NoteItApp` (main window, Settings, menu bar extra and menu commands), `AppDelegate` (activation policy, hotkey wiring, debug arguments), `WindowRouter` (show, hide and focus), `MenuShortcuts` and `MenuShortcutStore` (the menu key equivalents and the user's changes to them, also shown in the command palette), `MenuShortcutRules` (which menu shortcuts can be recorded), `AppUpdater` (in-app updates), and the launch-time migration from Inkwell (`LaunchMigration`, `LibraryLauncher`, `LegacyAppQuitter`, `LegacyAppMonitor`) |
| `Design/` | `Tokens` (colors, spacing, radii and chrome type styles) and `AppResources` (app icon and menu bar glyph images) |
| `Model/` | `Models` (notebooks, note metadata, sidebar selection, palette), `NoteStore` (the single observable store: queries, editing, tags and persistence), `NoteStore+Trash` (Recently Deleted), `VersionHistory`, seed content |
| `Views/` | The main window: three-column split, sidebar, note list, editor container with the note header and conflict badge, empty states, notebook sheet, the sync status pill, the Recently Deleted banner, undo toast and confirmations, and the Version History sheet |
| `Export/` | `NoteBlocks` (note body → blocks and styled runs), `MarkdownWriter` and `HTMLWriter`, `NoteExporter` (every format, file names, notebook folders and the print view) and `ExportActions` (File › Export…, Print, Share and Copy as Markdown) |
| `Import/` | `MarkdownReader` (Markdown → editor rich text), `MarkdownImporter` (folders, Obsidian vaults, Bear TextBundles), `AppleNotesImporter` (Notes app over Apple Events, HTML → editor styles) and `ImportSheet` (File › Import…) |
| `Editor/` | `RichTextEditor` (the SwiftUI wrapper), `NoteItTextView` (an `NSTextView` subclass whose layout manager draws code blocks, quotes, dividers and checkboxes), `TextFormatter`, `MarkdownShortcuts`, `FormatCommand` (every formatting command and its shortcut), `FormattingToolbar`, `EditorStyles` (type scale, colors and block kinds), `FindReplaceEngine`, `FindReplaceModel` and `FindReplaceBar` (find and replace in a note) |
| `MenuBar/` | The menu bar panel, the Quick Capture panel, the panel search field and shared views |
| `Palette/` | `FuzzyMatcher`, `PaletteRanker`, the palette commands and the command palette panel |
| `Capture/` | `CaptureController`, `SelectionReader`, `AccessibilityAccess`, `SourceResolver` and `BrowserPageReader`, `BrowserSources`, `CaptureFormatter`, `PasteboardSnapshot`, the `CaptureToast` notice and `CaptureServiceProvider` (Services › Capture to NoteIt) |
| `Hotkeys/` | `HotkeyAction`, `HotkeyManager` (Carbon `RegisterEventHotKey`), `KeyCombo` and the `ShortcutRecorder` view, whose recording session is shared with the menu shortcut recorder |
| `Settings/` | The Settings window and its General, Shortcuts, Editor, Sync and About tabs, plus `Preferences` (defaults keys) |
| `Sync/` | `SyncController`, `NoteStoreSyncAdapter`, `SyncConfiguration` (providers and settings) and `Keychain` |
| `Linking/` | `LinkExtractor` (note links in a body), `LinkIndex` (outgoing links and backlinks), `LinkSuggester` (ranks the `[[` list), `MentionFinder` (unlinked mentions), `OutlineExtractor`, `NavigationHistory` and `NavigationModel` (Go Back and Go Forward), `TemplateExpander` and `LinkingAPIRoutes` (the `linking.*` Local API routes) |

## Storage

Your library lives in `~/Library/Application Support/NoteIt/`. Set `NOTEIT_DATA_DIR` to use another folder (see [development.md](development.md)).

```text
~/Library/Application Support/NoteIt/
├── .initialized                     marker: first launch (seeding) has happened
├── library.json                     notebooks and note metadata (pretty-printed, ISO-8601 dates); notes in Recently Deleted have a `deletedAt` date
├── library.corrupt-<ts>.json        backup of an unreadable library.json, if that ever happens
├── search-index.json                folded plain text of each note, for search
├── link-index.json                  outgoing note links of each note, for backlinks (rebuilt if missing or stale)
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
- **Version history** (`VersionHistory.swift`). Before a save replaces a note's body on disk, the old body is copied to `history/` if the newest version is more than 10 minutes old (or there's none). A version is always kept before restoring a version. Sync follows the 10-minute rule when it replaces a body with a different one, unless the body holds local edits not kept as a version yet. Each note keeps up to 50 versions, none older than 30 days. Versions are written to a temp package and renamed into place. They aren't synced, indexed or listed in `library.json`.
- **Starting over.** Quit NoteIt and delete the whole folder, including the hidden `.initialized` marker, `.trash/` and `history/`.
- **Preferences** live in `UserDefaults`: `hideDockIcon`, `showMenuBarIcon`, `launchAtLogin`, `editorFontSize`, `defaultNotebookID`, the hotkey bindings and `menuShortcutOverrides` (changed menu shortcuts as JSON). Sync adds `syncConfiguration` (non-secret settings as JSON), `syncDeviceID` and `syncLastSync`. Secrets are kept only in the Keychain.

### Migration from Inkwell

NoteIt used to be called Inkwell. On launch, `LibraryLauncher` and `LaunchMigration` move an existing `~/Library/Application Support/Inkwell/` folder to `NoteIt/` (asking Inkwell to quit first if it's running), leave a relative link at the old path, copy over preferences from the `com.inkwell.app` defaults domain, and re-register the login item. Keychain secrets are copied from the old `com.inkwell.app.sync` service the first time they're read. Nothing is migrated when `NOTEIT_DATA_DIR` is set. The older `INKWELL_*` environment variable names are still read as a fallback.

## Editor

The editor is an `NSTextView` that stores each note as RTFD.

- **Block types.** RTFD drops custom attributes, so the kind of each paragraph (title, heading, subheading, body, code block, quote, divider) is stored as a sentinel `defaultTabInterval` value in its paragraph style. That way a heading stays a heading even if you change the default font size. Paragraphs without a sentinel, from older notes, fall back to guessing from the font size. See `BlockKind` and the `*Sentinel` constants in `EditorStyles.swift`.
- **Type scale.** Every editor style is derived from the *Default font size* setting (15 pt by default). Title is body + 12 pt (bold), heading body + 5 (semibold), subheading body + 1.5 (semibold), and code body − 1 (SF Mono); see `EditorStyles.swift`.
- **Drawing.** `NoteItTextView`'s layout manager draws code block cards (with the language label and copy button), inline code pills, quote bars, dividers and round checkboxes.
- **Code block language.** Each code paragraph stores its language as an extra left tab stop at `rawValue × 0.5` pt (0.5–10.5 pt), left of the code indent so a typed tab never reaches it. RTF writes tab stops in twips, so the value survives RTFD and sync exactly. Every paragraph of a block carries the same stop: normalization copies the first paragraph's language to the lines after it. No stop means Automatic. `CodeLanguage` raw values are persisted this way, so they must never change. See `EditorStyle.codeLanguage(of:)` and `SyntaxHighlighter.swift`.
- **Code styling.** `CodeStyler` styles code at display time from Settings › Editor › Code, so settings changes restyle open notes without rewriting them. Syntax colors and the guessed language of Automatic blocks are layout-manager temporary attributes, never saved. Highlighting runs only for the edited block, debounced while typing, and never during layout or drawing. `SyntaxHighlighter` is a pure tokenizer with `guessLanguage`; themes are in `CodeTheme.swift`.
- **Inline code** is stored only as a monospaced font (older notes may also carry a flat background, which the editor removes and never draws). The pill and tinted text are drawn from Settings. Its padding is a small kern on the characters around the code, and the *Same as Text* font swaps in the text font with an `inlineCodeDisplay` marker. Both live only in the editor: `NoteItTextView.attributedString()` and copy/drag return the saved form (`CodeStyler.persisted`), so export and saving still detect inline code by its monospaced font.
- **Find and replace.** `FindReplaceEngine` finds matches (UTF-16 ranges) and builds replacement strings, including `$1` captures in regex mode. `FindReplaceModel` drives the bar: it highlights matches with layout-manager temporary attributes, so the note's text is never changed to show them, and recomputes them when the text changes. Replace and Replace All go through the text view's `shouldChangeText`/`didChangeText` in one undo group, so they're single undo steps and are saved like typing. Each replacement keeps the attributes found at the start of the text it replaces.
- **Markdown shortcuts** are handled in `MarkdownShortcuts.swift`, and every formatting command, with its menu title, toolbar icon and shortcut, is defined in `FormatCommand.swift`. The full list is in [keyboard-shortcuts.md](keyboard-shortcuts.md).
- **Tags.** `#hashtags` are collected from note text, lowercased. A `#` counts only at the start of the text or after whitespace, an opening bracket or quote, `,` or `;`. Hashtags inside inline code, code blocks and links are ignored.
- **Search** matches every word of the query against the title and full text. Matching ignores case, accents and character width, using the folded text in `search-index.json`.

## Links, daily notes and templates

- **Links.** A link to a note is an ordinary link whose URL is `noteit://note/<UUID>`, with `?heading=<text>` for a heading. A link to a note that doesn't exist yet is `noteit://note?title=<text>[&heading=<text>]`. `NoteLink` (in `NoteItCore`) parses both, ignoring case, and writes the canonical form. Typing `[[` opens `InlineCompletionController`, a list under the caret that never takes focus; the text view forwards ↑ ↓ ↩ ⇥ and Esc to it. `LinkSuggester` ranks titles with `FuzzyMatcher`.
- **Link index.** `LinkIndex` is a `DerivedIndex` registered with `NoteStore` before `rebuildDerivedIndexes()` runs, so it's populated at launch. It keeps each note's outgoing links and reverse maps for backlinks and unresolved titles, saved to `link-index.json`. Bodies are parsed off the main thread and only for notes whose revision changed. Locked notes and notes in Recently Deleted contribute no links, so their text never reaches backlinks, previews or mentions.
- **Inspector.** `LinksPanelView` shows backlinks with a line of context, outgoing links, unlinked mentions (found by `MentionFinder` on a background task) and the note's outline. `RenameTracker` watches the open note's title and `LinkRenameBanner` offers to update the text of links to it; the rewrite goes through `NoteStore.editBody` in batches, keeping a version of each note so it can be undone.
- **Daily notes.** A daily note is a note in the daily notebook titled with a date (`DailyNoteTitle`, in any of its formats). Days are always counted in the Gregorian calendar in the current time zone (`DayKey.dailyCalendar()`), whatever the system calendar. `NoteStore+DailyUI` keeps a cached day index, reparsing only titles that changed, for Today, the calendar sheet and the header's ‹ › buttons.
- **Templates.** Notes in the Templates notebook are templates. `TemplateExpander` fills in `{{title}}`, `{{date}}` and `{{time}}` (each with an optional format), `{{clipboard}}` and `{{cursor}}` when a note is created from one, and a notebook can have a default template.
- **Export and import.** Markdown export writes note links as `[[Title]]` or relative links, and the folder importer turns `[[wiki links]]` back into note links once every file is in.

## Export

Export code lives in `Export/`.

- **`NoteBlocks`** turns a note body into blocks (paragraphs of each `BlockKind`, list items with their level, code blocks, dividers, tables) and inline runs. It reuses the editor's own helpers (`EditorStyle.blockKind`, `listMarker`, `listLevel`), so it reads notes exactly the way the editor does.
- **`MarkdownWriter`** and **`HTMLWriter`** render those blocks. Markdown returns the text plus image and file assets, which are written to a `<name> assets` folder next to the file. HTML is a single file with images embedded as data URLs.
- **`NoteExporter`** writes each format, picks safe, unique file names, and lays out notebook and Export All folders. PDF and print share one print view, so they look the same. `exportableNotes(in:)` is the one place that decides which notes get exported; it leaves out notes in Recently Deleted. A deleted note that's open can still be exported, printed, shared or copied, since that doesn't change it.
- **`ExportActions`** holds the panels, sharing and Copy as Markdown, used by `ExportCommands` and the toolbar Share button. Before reading a note it asks an open editor to save pending edits.

## Import

File › Import… (`ImportCommands`) opens `ImportSheet` on the main window. Imports run on the main actor in small steps, so the progress bar and Cancel stay responsive; notes already imported are kept when you cancel.

- **Building notes.** `MarkdownReader` and `AppleNotesImporter.convert(html:title:)` build bodies with the editor's own helpers (`EditorStyle.paragraph`, `markerText`, `listParagraphStyle`, `table`, `NoteItTextView.applyCheckedStyle` and `normalize`), so imported notes carry the same block sentinels as typed ones. `MarkdownReader` is the inverse of the Markdown export mapping, and `MarkdownRoundTripTests` checks that a note written and read back keeps its blocks. Lines without a blank line between them form one paragraph with line breaks, as Obsidian shows them; extra blank lines are ignored. Image paths go through a resolver closure.
- **Saving.** `NoteStore+Import.swift` adds `createImportedNote(body:title:notebookID:createdAt:updatedAt:)`, which goes through `createNote` (search index, tags, revision, sync) and then sets the source's dates, and `notebookForImport(named:)`, which reuses a notebook with the same name.
- **Sources.** `MarkdownImporter` walks folders (skipping hidden ones such as `.obsidian` and `.trash`), opens `.textbundle` folders, and unzips `.textpack` files with `ditto` into a temporary folder. `AppleNotesImporter` asks for Automation permission with `AEDeterminePermissionToAutomateTarget`, then reads folders and notes with `NSAppleScript`. The scripting is behind a protocol so tests use canned data. The app is signed with `Resources/NoteIt.entitlements` (Apple Events) for this.

## Global hotkeys

Global hotkeys use Carbon's `RegisterEventHotKey`, so they work from any app without Accessibility permission. `HotkeyManager` registers the bindings saved in `UserDefaults` and reports combinations that another app already owns. None are bound by default. `ShortcutRecorder` is the Settings control that records them.

Menu shortcuts can be changed too. `MenuShortcutStore` keeps only the changes from the defaults, either a different shortcut or none, and saves them under `menuShortcutOverrides`. Menu items read their shortcut through `.menuShortcut(_:)`, which observes the store. SwiftUI only rebuilds menu items when a menu is about to open, so after a change the store asks the main menu to update right away, otherwise the old keys would keep working until the menu was opened. The command palette and its ⌘O / ⇧⌘P handling read the current values. `MenuShortcutRules` turns a key press into a shortcut using the character on the ⌘ layer of the keyboard, so non-Latin layouts record Latin letters, and rejects combinations that other NoteIt or macOS shortcuts already use.

## Menu bar and Quick Capture

- The menu bar item is a SwiftUI `MenuBarExtra` with a window-style panel (`MenuBarView`). Its icon is a template image from `Sources/NoteIt/Resources/`, which switches to a "capturing" variant while Quick Capture is open.
- Quick Capture (`QuickCapturePanel.swift`) is a non-activating floating panel, so the app you were using stays in front. It appears on every Space, including over full-screen apps. Its draft (title, body and notebook) is kept until you save or discard it.
- In *Menu bar only* mode the app switches to the accessory activation policy and hides its Dock icon. The menu bar icon can't be turned off in that mode, so NoteIt stays reachable.

## Command palette

The palette (File › Open Quickly… and File › Command Palette…) lives in `Palette/`. `FuzzyMatcher` scores a query against one string, ignoring case and accents, and returns the matched ranges for highlighting. `PaletteRanker` merges notes, notebooks and the commands available right now into one ordered list, with notes that only match in their text after title matches. Both are pure Swift with no AppKit, so they're unit tested without any UI. `PaletteCommandRegistry` lists the commands that make sense for the current selection, and each one calls the same code as its menu item. `PaletteModel` keeps the results up to date while the palette is open, including when the store changes. The window is an `NSPanel` hosting a SwiftUI view, like Quick Capture, centered over the main window and closed when it stops being key. Menu shortcuts other than text editing close the palette before the menu sees them, so sheets attach to the main window.

## Capture from other apps

The Capture Selection hotkey and the Capture to NoteIt Service live in `Capture/`, and `CaptureController` runs both; `CaptureServiceProvider` receives the Service's text. `SelectionReader` asks the front app for its selected text through the Accessibility API, which needs the user's opt-in (`AccessibilityAccess`). It falls back to ⌘C when the app doesn't expose selected text that way, or when a browser reports an empty selection, and `PasteboardSnapshot` puts the clipboard back afterwards; other apps that report an empty selection get no ⌘C. `SourceResolver` finds the app, window title, document or web page with short Accessibility timeouts, and for browsers calls `BrowserPageReader`, which checks Automation permission first, then runs the `BrowserSources` scripts with `NSAppleScript` on `AppleScriptThread`, the same thread the Apple Notes import uses (links may be skipped while an import is running), and gives up after 1.5 s. `CaptureFormatter` turns the text and its source into a single-line title of at most 60 characters and a quoted body with a source line, saved to the notebook set for new notes; it, `BrowserSources` and `PasteboardSnapshot` are pure Swift and unit tested without any UI. `CaptureToast` is a non-activating panel, so the app you're in keeps focus. If NoteIt was hidden, `TransientSurfaceHider` (in `Palette/PaletteController+Global.swift`, shared with the global command palette) hides it again when the last notice or palette closes, unless you brought NoteIt to the front in the meantime. `scripts/build_app.sh` adds the Service's `NSServices` entry to `Info.plist`. Full design: [specs/2026-10-15-capture-from-any-app-design.md](specs/2026-10-15-capture-from-any-app-design.md).

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
- **Remote layout.** Everything goes under `noteit/v1/` in the chosen folder or bucket. Stores created before the rename live under `inkwell/v1/`. The first time a device connects to one of those, `RemoteMigration` copies it byte for byte to `noteit/v1/`, with the manifest last, and leaves the old folder in place. From then on, Macs still running Inkwell or NoteIt 0.3.0 or earlier sync with the old folder only. The copy only creates objects that are missing and checks for the new manifest before each one. If another device finished first, it stops and deletes the objects it created since its last check, unless they have changed since, so a slow copy can't bring back notes deleted under `noteit/v1/`. On S3-compatible providers without conditional writes, both the copy and sync rely on a HEAD check instead, so two devices upgrading at the exact same moment are not fully protected.

  ```text
  noteit/v1/
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
