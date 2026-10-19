# NoteIt for iPhone and iPad — Design

Status: proposed · Date: 2026-10-19 · Companion plan: docs/plans/2026-10-19-mobile.md

## Goal

Put NoteIt on iPhone and iPad as a native app that syncs with the Mac through the same end-to-end encrypted store the user already owns. The phone app starts as the fastest way to get a thought into NoteIt, then grows into a reader, search and editor for the whole library. It needs no account, sends nothing anywhere except the user's own storage, and costs nothing.

It ships in three milestones, each useful on its own:

- **M1 Capture.** Quick note, share extension, widgets and a Control Center button. Notes go to the Mac through sync. TestFlight only.
- **M2 Read, search, edit.** The whole library on the phone, search, and an editor for the common formatting. First App Store release.
- **M3 iPad and depth.** iPad layout, photos and files, the full library offline, Shortcuts actions, iCloud Drive folder sync.

This app and the web app (`docs/specs/2026-10-13-web-app-design.md`) split the platforms: the web app and its PWA cover Windows, Linux, Android, ChromeOS and any desktop browser, and this native app covers iPhone and iPad. It replaces the web spec's future iOS Safari and installable iPhone PWA item (§4.4, §16), so the web app adds no iOS-specific work; it still opens in iOS Safari as a best-effort browser. The plan changes the line in `docs/roadmap.md` that promises a "web app that also works as an installable iPhone app" to match.

## What the user gets

### First launch

A single screen:

> **NoteIt**
> Write it down now. It shows up on your Mac.
>
> [Scan from Your Mac] (primary)
> [Set Up Manually]
> [Use Without Sync]

- **Scan from Your Mac** opens the camera with the hint "On your Mac, open NoteIt › Settings › Sync › Add iPhone or iPad…". After a scan the phone asks "Enter the code shown on your Mac." After the right code: "Connected to <provider name>. Getting your notebooks…", then the composer.
- **Set Up Manually** shows the Mac Sync tab's S3-compatible providers with the same fields (provider, endpoint, region, bucket, prefix, access key, secret, passphrase), then derives the key on the device. In M1 and M2 it offers no folder or WebDAV option; the iCloud Drive folder arrives in M3.
- **Use Without Sync** keeps notes on this device. Settings › Sync can connect later; existing notes are pushed on the first sync.

### M1: capture

**Composer (app home screen in M1).** The app opens straight into an empty note with the keyboard up.

- First line is the title, same rule as the Mac: the first non-empty line, single line, at most 60 characters. Empty composer: placeholder "Title" on line 1, "Write something…" below.
- Toolbar above the keyboard: notebook chip ("Inbox ▾" or the default notebook name), **Done**.
- **Done** saves, clears the composer, shows the banner "Saved to <notebook>" for 1.5 s, and keeps the keyboard up for the next note. Swiping the composer down also saves.
- Nothing is lost if the app is killed: the draft is written to `inbox/draft.json` every 2 s while typing and on background, and restored on the next launch.
- A **Sent** button in the navigation bar opens a list of the last 50 captures on this device with their state: "Waiting to sync", "On your Mac" (pushed), or "Sync off".
- Plain text only in M1. Lines starting with `- `, `* `, `1. ` or `[ ] ` become list items, matching what the Mac's paste of plain text produces.

**Share extension.** "NoteIt" appears in the iOS share sheet for text, URLs and web pages (Safari sends title and URL).

- Sheet titled **Save to NoteIt**, with an editable title, a text box holding the shared content, and the notebook chip. **Cancel** / **Save**.
- Shared URL: body is the page title as a link, then the URL on its own line, then any selected text quoted. Title defaults to the page title, or the host name.
- Shared text: quoted, title from its first line (Mac `CaptureFormatter` rule).
- Saving writes to the inbox and closes the sheet. The extension never talks to the network.

**Widgets and controls.**

- **New Note** home screen widget (small): tapping opens the composer.
- **Lock screen** accessory (circular): pencil icon, opens the composer after unlock.
- **Control Center** control and Action button (iOS 18): "New Note", opens the composer.
- All of them run the `NewNoteIntent` App Intent, which opens the app at the composer. On iOS 17 only the widget and lock screen accessory exist.

**Sync.** Notes made on the phone appear on the Mac within a minute while the phone app is open, and at the next background refresh otherwise. In M1 the phone pulls notebooks (so it can file notes) but not other notes.

### M2: read, search, edit

- **Library.** A sidebar list in the program's frozen order (program spec §9): All Notes, Pinned, Recent and Conflicts (when there are any) at the top; then notebooks and the tag tree; then Recently Deleted in its own section at the bottom. It leads to the note list. Today, Tasks and Smart Folders stay on the Mac in this spec. Rows show title, preview and relative date, same as the Mac cards. Swipe actions: Pin, Move, Delete. Pull to refresh runs a sync.
- **Composer stays one tap away:** a compose button in the bottom bar, and the widgets still open it.
- **Search.** A search field at the top of the note list searches titles and text as the Mac list does (the shared `LibraryQuery` and query language in `NoteItCore`). Results appear as you type.
- **Reading and editing.** Notes open in the mobile editor. Formatting bar above the keyboard: **Aa** (Title, Heading, Subheading, Body, Code, Quote), **B**, *I*, U, ~~S~~, bulleted list, numbered list, checklist, indent/outdent, link. Tapping a checkbox ticks it without opening the keyboard.
- **Content the phone can't edit** (tables, some attachments) appears as a grey block "Table — edit on your Mac" that's kept unchanged when the rest of the note is edited.
- **Notes the phone can't open for editing** (bodies in the old RTFD format, or content from a newer version) show "This note can be read on your Mac. Open it there once to make it editable here." with plain-text preview.
- **Locked notes** (from `sync-security`) appear in lists with a lock icon, their title and no preview. They can't be opened, changed or deleted on the phone in its first releases; tapping one shows "This note is locked. Open it on your Mac." Search matches their title only.
- **Notebooks.** Create and rename. Choose the default notebook for new notes in Settings.
- **Recently Deleted.** Restore and Delete Now, 30-day retention as on the Mac.
- **Conflicts.** Conflict copies show a badge "Conflict copy from <device>". The Mac conflict flow handles merging; on the phone the user can keep either note and delete the other.
- **Recent Notes** widget (medium/large): the last 3 or 6 edited notes, tap to open. Setting **Show note titles in widgets** (on by default) hides titles behind "Note" when off.
- **App lock.** Setting **Require Face ID** (off by default) locks the app on launch and after 5 minutes in the background.
- **Links.** `noteit://note/<UUID>` links (the `NoteLink` format in `NoteItCore`) open the note inside the app. Title links (`noteit://note?title=`) open search with that title.

### M3: iPad and depth

- **iPad:** three columns (sidebar, list, editor), Stage Manager and multiple windows, drag notes onto notebooks, keyboard shortcuts:

  | Shortcut | Action |
  |---|---|
  | ⌘N | New note |
  | ⌘F | Search |
  | ⌘O | Open Quickly (fuzzy find by title) |
  | ⌘B / ⌘I / ⌘U | Bold / italic / underline |
  | ⇧⌘L | Checklist |
  | ⌘⌫ | Delete note |
  | ⌘R | Sync now |

  The shortcuts match `App/MenuShortcuts.swift` defaults where the Mac has the same command.
- **Photos and files:** an attachment button (Photo Library, Take Photo, Choose File). Images display inline; other files show as chips that open in Quick Look. HEIC becomes JPEG quality 0.9 and TIFF becomes PNG before storing, same as the Mac export rules. Limit 25 MB per attachment, message "“<name>” is too large to add. Attachments can be up to 25 MB."
- **Keep full library offline** (Settings › Storage, off by default): downloads every note body and keeps them current.
- **Shortcuts actions:** Create Note, Append to Note, Find Notes, Open Note, Get Note Text, with the names, parameters and App Shortcuts phrases from `automation` ("Create a note in NoteIt", "Search NoteIt", "Add to a note in NoteIt"), shared through the package (Design §10).
- **iCloud Drive folder sync:** join a library synced through an iCloud Drive folder (best effort, see Design §5).
- Delete and reorder notebooks.

### Settings (iPhone/iPad)

One screen, grouped:

- **Sync:** status line ("Up to date · 2 min ago", "Syncing…", "Waiting for network", "Encryption was changed on <Mac>"), **Sync Now**, provider name, device name (default "iPhone" or "iPad", editable), **Disconnect…**.
- **Notes:** Default notebook, Show note titles in widgets.
- **Storage (M2):** "Notes on this iPhone: 1,240 · Downloaded: 312 MB", Download limit (250 MB / 500 MB / 1 GB / No limit; default 500 MB), **Keep full library offline** (M3), **Remove Downloads**.
- **Privacy:** Require Face ID (M2).
- **About:** version, "Source code" link to the GitHub repository at the exact tag of this build, license, "No account. No tracking. Your notes go only to the storage you choose."

## Design

### 1. Shared code

The Mac app keeps its storage and UI inside the `NoteIt` executable target. `NoteStore` (`Sources/NoteIt/Model/NoteStore.swift`) stores `NSAttributedString` bodies as RTFD and listens to `NSApplication` notifications, so none of it compiles on iOS. The phone builds on the library targets in the program's target graph (program spec §1). `Package.swift` declares `platforms: [.macOS(.v14), .iOS(.v17)]` once, in foundations; this spec doesn't change it.

**`NoteItCore` (built in foundations, used here).** Extracting the shared models was the first step of this spec; it moved to foundations (program spec §2 step 1, `docs/plans/2026-10-19-foundations.md`). `NoteItCore` holds:

- `Notebook`, `NoteMeta` and `SidebarSelection` (including `.today`, `.tasks`, `.tag(path)` and `.smartFolder(UUID)`), with `public` initialisers. `SmartFolder` is added to `NoteItCore` by `organise` in wave 1. Every field any sub-project adds later is added there, so the phone sees it without changes.
- Text folding, `FuzzyMatcher` and the query language (from `organise`; there is no `NoteItOrganise` target).
- `LibraryQuery`: the single pure filter, sort and search over `[NoteMeta]` for every sidebar case. The Mac list, `organise`'s search and the phone all call it.
- `NoteLink` (the `noteit://note/<UUID>` format), the `URLCommand` parser, daily note titles and the `DailyLogLine` formatter.
- The `library.json` schema and coding, the capture title rule (first usable line, single line, at most 60 characters), the 30-day trash policy and the notebook palette hexes and symbols, as foundations extracts them from the Mac app.

This spec adds one thing to `NoteItCore`: `NoteLibrary`, a `@MainActor` protocol with the read and write operations both stores support (list, filter, plain text, create, append, pin, move, delete, restore). The Mac `NoteStore` conforms in an extension; the phone's `DocLibrary` conforms. Features from other sub-projects that only need these operations work on both.

**`NoteItSync` (reused, with the additions in §5 and §6).** It imports only Foundation, CryptoKit, CommonCrypto and Security. Backends, cipher, key derivation, planner, engine, `StoreSession`, manifest features, `RawMetaOverlay` and `AppIdentity` all work on iOS. `SyncProvider` moves here from `Sources/NoteIt/Sync/SyncConfiguration.swift` (it is Foundation-only) so both apps show the same provider list. It moves with every case, including `.webdav` from `sync-security` (wave 2, before this wave 3 work); the phone refuses `.webdav` in pairing and manual setup, and `.folder` until the iCloud Drive folder arrives in M3.

**`NoteItDoc` (Foundation only, from foundations).** Foundations provides `BodyContainer`, `DocNode`, `DocValidation` and `AttachmentLimit`; `web-app` Phase 0 adds `BodyFormat` and the derivation rules (`DocDerivation`). The `NSAttributedString` converter and style provider live in the macOS-only `NoteItDocAppKit`, which the phone never links. This spec adds a Foundation-only `DocText` type (§7) to `NoteItDoc` as the phone's editing model. `NoteItDocTestSupport` (a library target) provides the random document generator and golden fixtures for its tests.

**`NoteItMarkdown` (from `markdown-storage`).** The only lossless Markdown path; the phone uses it for Get Note Text in Markdown format (§10).

**New `NoteItMobileKit` target (Foundation, CryptoKit and Security, plus ImageIO and CoreGraphics for image conversion; no UI frameworks; built for macOS and iOS).** Depends on `NoteItCore`, `NoteItDoc`, `NoteItSync` and `NoteItMarkdown`. Phone-specific logic that has no UI and is tested with `swift test` on the Mac: `DocLibrary` (storage), `DocLibrarySyncAdapter` (the `SyncLocalStore` conformance), `CaptureInbox`, `BodyCache`, `WidgetSnapshot`, `MobileRoute` (what the phone does with a parsed `URLCommand`), `MobileSyncSettings`, `MobileSyncScheduler` (timing decisions only), `MobileSyncRunner` (one sync pass and its status) and `MobileImageNormalizer` (§8).

**App code** lives in an Xcode project generated by XcodeGen from `mobile/project.yml` (§9). It holds only SwiftUI views, the UIKit text view, extensions, widgets, intents and glue. It depends on the library products `NoteItCore`, `NoteItDoc`, `NoteItSync`, `NoteItMarkdown` and `NoteItMobileKit` only.

### 2. Library storage on the phone

**Container.** The App Group `group.io.github.rutbergphilip.noteit.mobile`, shared by the app, the share extension and the widget extension. Root: `<group>/Library/Application Support/NoteIt/`.

| Path | Contents | Written by |
|---|---|---|
| `library.json` | `LibraryFile`: notebooks and note metadata, same schema as the Mac | app |
| `meta-raw/notes/<UUID>.json`, `meta-raw/notebooks/<UUID>.json` | the last decrypted record `meta` JSON per note and per notebook, one folder per record kind as on the Mac, for unknown-key preservation (`RawMetaOverlay`) | app |
| `notes/<UUID>.json` | the note body as a `BodyContainer` (`noteit-doc/1`) | app |
| `notes/<UUID>.locked` | the sealed body of a locked note, exactly as received, never opened on the phone | app |
| `search-index.json` | folded text per downloaded note, `organise` index format; locked notes have no entry | app |
| `sync-state-<hash>.json` | `SyncState` per store, same naming as the Mac | app |
| `sync-deletions.json` | local deletion journal | app |
| `inbox/<UUID>.json` | captures not yet imported (`CaptureInboxItem`) | app, extensions, intents |
| `inbox/draft.json` | the composer's unsaved draft, never imported | app |
| `library-cache.json` | last-opened dates for the body cache (M2) | app |
| `captures.json` | Sent history, last 50 | app |
| `widget-snapshot.json` | recent notes for widgets (M2) | app |
| `.trash/` | files of notes being purged | app |

- All files use `FileProtectionType.completeUntilFirstUserAuthentication`, so background refresh can sync after the first unlock.
- Only the main app writes `library.json`, `notes/` and sync state. Extensions write a single new file in `inbox/` each (atomic write of a fresh UUID name, no shared file to coordinate). The app imports the inbox on launch, on foreground, and when it receives the Darwin notification `io.github.rutbergphilip.noteit.mobile.inbox` posted by an extension.
- Widgets read only `widget-snapshot.json` (titles, previews, dates, no bodies). With **Show note titles in widgets** off, the snapshot holds no titles.
- **Unknown fields are kept.** Notebooks and notes from newer Macs can carry fields the phone doesn't know (the parent notebook from `organise`, `checkedItemsToBottom` from `surfaces-polish`, future ones). Board layouts aren't a notebook field; they are their own `boards/` records, which the phone ignores (§5.1). The phone keeps the raw decrypted `meta` JSON in `meta-raw/notes/` and `meta-raw/notebooks/` and, when it writes a record, merges it with `RawMetaOverlay` from `NoteItSync` (program spec §4.5): the keys the phone owns come only from its newly encoded meta (an owned key it cleared is removed), every other key is kept from the raw JSON. The same applies to unknown `DocNode` content (§7).
- Library size: metadata for 10,000 notes is about 5 MB in `library.json`; bodies are separate and downloaded on demand (§5.3).
- **Device ID** is a UUID kept in the App Group `UserDefaults` (`syncDeviceID`). Reinstalling makes a new device in the Mac's device list.
- **Backups:** the App Group container is included in the device backup. Settings › Storage › Remove Downloads removes bodies that are synced; it never removes unsynced notes or `.locked` files.
- **Locked notes:** a `.locked` file is removed only when the next version of that note from sync isn't locked (the lock was removed on a Mac, so a `noteit-doc` body replaces it) or the note is purged. Purging a locked note deletes its `.locked` file, whether the purge is the phone's own 30-day purge from Recently Deleted or a tombstone from another device. Delete Now isn't offered for locked notes on the phone. The body cache and Remove Downloads never remove a `.locked` file.

**Settings keys** (App Group `UserDefaults`, suite `group.io.github.rutbergphilip.noteit.mobile`):

| Key | Type | Default |
|---|---|---|
| `syncConfiguration` | JSON `MobileSyncSettings` | none |
| `syncDeviceID` | String | new UUID on first launch |
| `syncDeviceName` | String | "iPhone" / "iPad" |
| `syncLastSync` | Date | none |
| `defaultNotebookID` | String (UUID) | none (Inbox = no notebook) |
| `showTitlesInWidgets` | Bool | true |
| `bodyCacheLimitMB` | Int | 500 (0 = no limit) |
| `keepLibraryOffline` | Bool | false |
| `appLockEnabled` | Bool | false |

### 3. Capture (M1)

**Behaviour.** Every capture path produces a `CaptureInboxItem` and nothing else:

```
CaptureInboxItem { id: UUID, createdAt: Date, title: String?, text: String,
                   url: URL?, sourceTitle: String?, notebookID: UUID?, origin: composer | share | intent }
```

The app turns each item into a note: `CaptureTitle` picks the title when none is given, the body is built as a `BodyContainer` (paragraphs, list items from simple markers, a quote block for shared text, a link for a shared URL), and the note gets a fresh `revision`. The inbox file is deleted only after `library.json` and `notes/<id>.json` are written.

**Notebook.** The chip lists notebooks from the last sync, plus "No Notebook". The default is `defaultNotebookID`. If that notebook was deleted on another device, the note goes to no notebook and the setting is cleared.

**Edge cases.**

- Empty composer on Done: nothing is saved, no banner.
- Over 200,000 characters (the Mac `CaptureFormatter.maxSelectionLength`): the share sheet keeps the first 200,000 and appends "…".
- Share sheet with images in M1: the extension doesn't accept images (activation rule excludes them); in M3 it does.
- Captures made before sync is set up are pushed on the first sync.
- If the extension is launched while the device is locked before first unlock, the App Group isn't readable. The sheet says "Unlock your iPhone once, then try again."

**Errors.** Writing the inbox fails (disk full): "Couldn't save. Your iPhone is out of space." and the sheet stays open with the text.

**Privacy.** The share extension has no network entitlement use, and never sees the store key or credentials (§6).

### 4. Widgets, controls and the URL scheme

- Widget extension bundle id `io.github.rutbergphilip.noteit.mobile.widgets`. Widgets: `NewNoteWidget` (small, accessory circular), `RecentNotesWidget` (medium, large; M2). Control: `NewNoteControl` (iOS 18).
- `NewNoteIntent: AppIntent` with `openAppWhenRun = true`, opens the composer. It is the shared target of widget taps, the control and the Action button.
- **URL scheme:** the phone registers `noteit://`, owned by `automation`. Every link is parsed by the shared `URLCommand` parser in `NoteItCore`; the phone has no grammar of its own. `MobileRoute` (in `NoteItMobileKit`) maps a parsed command to what the phone does:
  - M1: `.new` with text creates a note through the inbox, then shows the composer with a "Saved to <notebook>" banner; `.new` with no text opens the composer.
  - M2: `.open(id)`, `.note(id:heading:)` open the note (scrolled to the heading when given); `.open(title)` and `.noteTitle(title:heading:)` open search with that title; `.search` opens search.
  - Everything else (`append`, `daily`, `settings`, and hosts the Mac registers through `URLRouteRegistry`, such as `join`) opens the app with "This works in NoteIt for Mac."
  - x-callback parameters are parsed and ignored; there is no x-callback support on the phone until `automation` defines it for iOS.
- Widget timelines reload after each sync pass that changed notes and after local edits (`WidgetCenter.shared.reloadTimelines(ofKind:)`), at most once every 30 s.

### 5. Sync

**Principle.** The phone is one more device on the existing store. No NoteIt server, no push notifications, no relay. The wire prefix `inkwell/v1/` is unchanged.

#### 5.1 Store format

- The phone works only with stores whose manifest `features` contain `noteit-doc` (`web-app` spec §3.4, program spec §4.1). It never looks at `formatVersion` to decide this.
- It never creates a store and never adds a feature. `SyncEngine.ensureFeature(_:backend:session:currentDeviceID:confirm:)` and the upgrade to `noteit-doc` run on a Mac only; upgrading also needs the Mac's RTFD converter, which the phone doesn't have. A store without `noteit-doc` shows: "Open NoteIt on your Mac once to finish setting up iPhone access." with a **Try Again** button. A store `StoreSession` can't open (a newer format, or a feature that isn't in `StoreFeature.supported`) shows: "This library needs a newer version of NoteIt."
- The engine gains a policy flag so the phone's engine never runs the `noteit-doc` upgrade or calls `ensureFeature(_:backend:session:currentDeviceID:confirm:)`.
- The phone writes its device record through the shared engine like any other device (program spec §4.4): `platform: "ios"` (on iPad too), `appVersion`, `supportedFeatures` (its `StoreFeature.supported`, sorted; the phone links the same `NoteItSync`, so it lists the same features as a Mac of the same build) and `rekeyAck`. A Mac's `ensureFeature` and `devicesBlocking` use it to list the phone among the devices that would stop syncing.
- Notes whose last envelope is a legacy RTFD body (`SyncState.legacyBodies`) are shown read-only with the placeholder in "What the user gets". The Mac's conversion sweep (web plan) converts them, after which the phone can edit them.
- Notes with `bodyFormat: "noteit-locked/1"` (stores with `locked-notes`) are kept sealed as `notes/<UUID>.locked` and shown as locked (§11). The phone never pushes them.
- Record kinds the phone doesn't use are ignored without error and never deleted (program spec §4.9): `smart-folders/`, `boards/`, `claims/`, `keys/`, `noteit/identity/`, `noteit/space/` and any kind added later. They produce no per-record errors, and the phone never writes, rewrites or deletes their objects, even when it deletes the notebook a board belongs to.

#### 5.2 Capture scope (M1)

The M1 app doesn't keep the library. A full pass would treat every remote note as something to pull. So the engine gets a **scope**:

- `.full`: today's pass (M2 onwards).
- `.capture`: processes this device's local notes, its local note deletions, and all notebooks (pulled so the chip is current). Remote notes this device never had are skipped. No sidecar resolution, no tombstone sweep.

After a note is pushed and its base recorded, the M1 adapter moves it from the live library to Sent history: its body file is deleted, and its id is added to a `forgotten` set that `records()` and `deletions()` never return, so the engine doesn't treat it as a local deletion. Editing a sent note isn't possible in M1.

Upgrading from M1 to M2 runs one `.full` pass; notes in Sent history are pulled back as normal remote notes.

#### 5.3 On-demand bodies (M2)

Downloading every body to a phone is slow and uses storage. Metadata is always synced; bodies are fetched when needed.

- `SyncLocalStore` gains `wantsBody(for:)`, default `true` (the Mac keeps today's behaviour). The phone answers `true` for notes it has cached, opened in the last 30 days, pinned, or all notes when **Keep full library offline** is on.
- When the engine pulls a note whose body isn't wanted, it applies the meta with `bodyDeferred = true` and doesn't download the body.
- `SyncEngine.fetchBody(_:)` downloads, verifies and decrypts the current body of one note for the given revision. The app calls it when the user opens the note. The editor shows the preview text with a spinner, then the body. Offline: "This note hasn't been downloaded. Connect to the internet to open it."
- **Changing a note needs its body.** Pin, move, rename, edit and delete all first fetch the body (if missing), because the engine pushes whole records. Offline, these actions are disabled for bodies that aren't downloaded, with the footnote "Download this note to change it."
- **Cache limit** (`bodyCacheLimitMB`): after each pass, the least recently opened clean bodies are removed until under the limit. Unsynced notes, pinned notes and notes open in any window are never removed. Removing a body marks it deferred; search for those notes uses the index entry written when the body was last present, or the preview when none exists.

#### 5.4 Timing

- On launch, on foreground, 2 s after the last edit (10 s max delay), every 60 s in the foreground, and on **Sync Now** and pull to refresh. Same constants as `SyncController` on the Mac.
- On background: `UIApplication.beginBackgroundTask` to finish a running pass and push pending captures.
- `BGAppRefreshTask` identifier `io.github.rutbergphilip.noteit.mobile.refresh`, requested every 15 minutes (iOS decides the actual timing), runs a pass with a 25 s budget.
- Backoff on errors as on the Mac: doubling up to 600 s.
- Network: `URLSession` with `waitsForConnectivity = true`; `allowsExpensiveNetworkAccess` and `allowsConstrainedNetworkAccess` true (notes are small).

#### 5.5 Backends

- **M1/M2:** S3 providers only (AWS S3, Cloudflare R2, Backblaze B2, Google Cloud, MinIO, custom S3), using `S3Backend` as is. MinIO and custom S3 allow `http://` as on the Mac; the app sets `NSAllowsLocalNetworking` in ATS and `NSLocalNetworkUsageDescription` "NoteIt connects to your sync server on your network." for NAS setups.
- **Folder-backed Macs** (iCloud Drive, Dropbox, NAS mount) can't pair in M1/M2. The Mac pairing sheet explains: "iPhone sync works with S3-compatible storage. Folder sync on iPhone is coming later."
- **M3, iCloud Drive folders:** the user picks the library folder with the document picker; the app keeps a security-scoped bookmark and runs `FolderBackend` through `NSFileCoordinator`. Files that iCloud hasn't downloaded are requested with `startDownloadingUbiquitousItem` and the pass retries them later. Background refresh can't see iCloud changes reliably, so folder sync runs only in the foreground. From M3 the Mac pairing sheet also works for libraries in iCloud Drive: the code carries no credentials, and the phone asks the user to choose that folder. Other folder providers (Dropbox, NAS) are not supported on the phone.

#### 5.6 Errors

| Situation | Status line | Action |
|---|---|---|
| Offline | "Waiting for network" | retry on reachability |
| Encryption key replaced on another Mac (`SyncError.keyChanged`, `sync-security`) | "Encryption was changed on <Mac>" | **Scan Again** opens pairing |
| Key replacement running (`SyncError.rekeyInProgress`) | "Waiting for <Mac> to finish changing encryption" | retry on the normal schedule |
| Wrong key in the keychain (`wrongPassphrase`) | "Your sync key no longer works" | **Scan Again** |
| Credentials rejected (403) | "Your storage rejected the sign-in" | **Update Credentials…** |
| Store missing (bucket emptied) | "Sync library not found" | **Disconnect…** |
| Store without `noteit-doc` (`SyncError.storeNeedsUpgrade`) | message in §5.1 | **Try Again** |
| Quota or disk full | "Your iPhone is out of space" | none |

Notes are never discarded on a sync error; unsynced notes stay in the library and in Sent history as "Waiting to sync".

### 6. Pairing and keys

**Why a QR code.** Typing an S3 secret and a long passphrase on a phone is error-prone, and the passphrase is the only thing between the store and anyone with the bucket. Pairing from the Mac copies everything in one scan plus a short code, and the phone never needs the passphrase itself.

**Mac side.** Settings › Sync gets **Add iPhone or iPad…** (enabled when sync is on and the store is S3-backed), and the command palette gets the same command (ID `pairDevice`).

1. NoteIt asks for the Mac login (Touch ID or password, `LAContext` `.deviceOwnerAuthentication`, reason "show the pairing code for your iPhone").
2. NoteIt picks a random 8-character code (Crockford base32, about 40 bits) and a random `pairingID`, and seals the payload with a key derived from the code (below).
3. A sheet shows the QR code (CoreImage `CIQRCodeGenerator`, correction level M), the code in large characters, grouped in fours ("Code: 7KQM-4X2D"), the text "Scan this with NoteIt on your iPhone or iPad, then enter the code. Together they contain your sync key. Don't share them.", a countdown, and **Done**.
4. The window uses `sharingType = .none` so it doesn't appear in screenshots or screen sharing. It closes after 10 minutes (when the code expires), on Done, or as soon as the paired device's record appears in the store. The code can be used once: when a new device record appears, the Mac discards the code and closes the sheet.

**Payload.** The QR code holds `NOTEIT-PAIR1:` followed by base64url (no padding) of `salt (16 bytes) ‖ AES-GCM combined box (nonce, ciphertext, tag)`. The box key is PBKDF2-HMAC-SHA256 of the normalised code (uppercase ASCII, hyphens and spaces removed, `I` and `L` read as `1`, `O` as `0`) with that salt and 600,000 iterations. The QR alone isn't enough (program spec §11). The sealed plaintext is JSON:

```
{ "v": 1,
  "provider": "cloudflareR2",            // SyncProvider raw value
  "endpoint": "https://…", "region": "auto", "bucket": "…", "prefix": "…",
  "accessKey": "…", "secret": "…",
  "key": "<base64 of the 32-byte data key>",      // absent for plaintext stores
  "keyID": "a1b2c3d4e5f60718",                   // keyring stores only, for verification
  "macName": "Studio",
  "pairingID": "<UUID>",                  // one per code; the phone refuses an ID it has used
  "expiresAt": "2026-10-19T10:12:00Z" }  // 10 minutes after creation
```

- The QR code holds the **data key**, not the passphrase. With the keyring from `sync-security` that is the DEK the Mac keeps in its keychain (account `syncDataKey`); on a store still using the original `encryption` block it is the PBKDF2 output, which is the same thing there. A leaked code and QR give access to this store, same as the passphrase would, but don't reveal a passphrase the user may have reused elsewhere. Because the data key survives a passphrase change, the phone keeps syncing when the passphrase is changed on a Mac.
- Typical size about 740 characters, QR version 22 at level M, readable on a laptop screen.
- The phone asks "Enter the code shown on your Mac." The field accepts letters and digits, ignores case and hyphens, and shows the code grouped in fours. A code that doesn't open the box shows "That code doesn't match. Check the code on your Mac and try again." The phone then checks `v`, `expiresAt`, provider and URL validity, reads the manifest and connects with `StoreCredential.dataKey` from `sync-security`, which accepts the key only if its keyID matches the keyring (or it opens `Manifest.Encryption.keyCheck` on a store without a keyring). Expired: "This code has expired. Show a new one on your Mac." A `pairingID` this phone has already used: "This code has already been used. Show a new one on your Mac." Wrong store: "This code doesn't match your sync library."
- The code protects against someone who only sees or photographs the QR code. About 40 bits behind 600,000 PBKDF2 iterations takes years of offline guessing on one GPU, far longer than the 10-minute expiry, but the code is still short, so the expiry, single use, the login prompt and `sharingType = .none` still matter. Single use is enforced by the phone (it refuses a reused `pairingID`) and by the Mac closing the sheet once a device joins; a stolen QR and code together still work on another device until then.
- Only the NoteIt camera reads it (DataScannerViewController, with AVFoundation fallback). The system camera would show the text as a search suggestion, so the payload deliberately isn't a URL.

**Phone storage of secrets.** Keychain, service `AppIdentity.keychainService` (`io.github.rutbergphilip.noteit.sync`), accounts `s3-access-key`, `s3-secret` (same names as the Mac) and `syncDataKey` (the 32-byte data key, same account name as the Mac in foundations task 3.3). Accessibility `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: available to background refresh after first unlock, never in backups or on another device. No access group is shared with extensions, so the share extension and widgets can't read them.

**Manual setup.** The phone connects with `StoreCredential.passphrase` (PBKDF2 at the manifest's iterations; 600,000 takes about a second on an iPhone 12, with a spinner), then stores only the unlocked data key, as the Mac does after unlock. The passphrase field uses `PassphraseHint.text` from the web plan.

**Plaintext stores.** Joining a store without encryption works and shows, once: "This library isn't encrypted. Anyone with access to your storage can read your notes."

**Disconnect…** removes the keychain items, sync state and the deletion journal. It asks: "Keep notes on this iPhone?" **Keep** (notes stay as local-only) or **Remove**.

### 7. Editor (M2)

**Model.** `DocText` (in `NoteItDoc`, Foundation only) is the phone's in-memory form of a note:

- `string`: the visible text, one paragraph per block, `\n` separated, `U+2028` for hard breaks, `U+FFFC` for images, attachments and islands.
- `paragraphs`: per paragraph a `BlockStyle` (body, title, heading, subheading, code, quote, listItem(kind, level, number, checked), divider) plus `align` and `indent`.
- `runs`: character ranges with `InlineMarks` (bold, italic, underline, strike, code, link, textColor, highlight, fontSize).
- `islands`: the original `DocNode` for each `U+FFFC` that the phone can't edit (tables, unknown nodes), kept byte-for-byte.

`DocText(doc:)` and `toDoc()` round-trip every golden vector in `fixtures/golden/` exactly (loaded through `NoteItDocTestSupport`, the same files the `NoteItDocAppKit` converter is tested against). Edits are operations on `DocText` (`replace(range:with:)`, `setBlock`, `toggleMark`, `setLink`, `toggleCheckbox`, `indent`), each tested without UI.

**Rendering.** `NoteTextView` wraps `UITextView` with TextKit 2. A `DocTextRenderer` turns `DocText` into an attributed string with UIKit fonts (Dynamic Type body size, same size ratios as `EditorStyles` on the Mac), and maps edits from `UITextViewDelegate` back to `DocText` operations. Tables and unknown nodes are `NSTextAttachment`s with an `NSTextAttachmentViewProvider` that draws a read-only preview. Images draw from attachment data; large images are downsampled for display.

**Editable on the phone:** paragraph, title, heading, subheading, quote, code block, divider (insert and delete), bulleted, numbered and checklist items with levels 0-8; bold, italic, underline, strikethrough, inline code, links. **Kept and shown but not editable:** text colour, highlight, font size, alignment, indent of non-list paragraphs (applied text keeps them), tables, unknown nodes.

**Edge cases.**

- `DocValidation.validate` returns `.readOnly(reason:)` for content from a newer format: the note opens read-only with "This note uses formatting from a newer version of NoteIt."
- Notes over 1 MB of text open read-only with "This note is too long to edit on iPhone." (keeps typing responsive).
- Typing saves 1 s after the last keystroke and on background. Each save bumps `revision` and writes `notes/<id>.json` atomically.
- Derived fields (title, preview, tags) come from `NoteItDoc` derivation (web plan `DocDerivation`), so the Mac and phone agree.
- Spell check, autocorrect, dictation and Writing Tools use the standard text view behaviour.
- Undo: standard `UndoManager` on the text view, three-finger gestures and shake.

### 8. Attachments (M3)

- Added via `PhotosPicker`, the camera (`UIImagePickerController`) or `UIDocumentPickerViewController`, and through the share extension (images and files).
- Stored inside the `BodyContainer` `attachments` map keyed by SHA-256, as the web spec defines. Same image conversions as the Mac (HEIC to JPEG 0.9, TIFF to PNG), applied with ImageIO and CoreGraphics by `MobileImageNormalizer` in `NoteItMobileKit` (the only portable target allowed to import them) so `NoteItDoc` stays Foundation only. It is the phone's counterpart of the Mac's `ImageNormalizer` in `NoteItDocAppKit` and stays in `NoteItMobileKit`.
- Limit `AttachmentLimit.maxBytes` (25 MB) per attachment; total body over 100 MB is refused with "This note is too large to sync. Remove an attachment first."
- Images display with `width` from the node; tapping opens a full-screen viewer. Files open in Quick Look.
- Screenshot to text and voice notes are `capture-plus` features; the phone shows their results like any other note content.

### 9. Project, build and distribution

**Project.** SwiftPM can't build an iOS app with extensions, so the iOS app is an Xcode project generated by **XcodeGen** from `mobile/project.yml`. The `.xcodeproj` isn't committed (`.gitignore` already ignores `*.xcodeproj`). XcodeGen keeps the definition reviewable as text, and Tuist would add a Swift build tool the repo doesn't otherwise need.

| Target | Bundle ID | Kind |
|---|---|---|
| `NoteItMobile` | `io.github.rutbergphilip.noteit.mobile` | iOS app (iPhone, iPad), iOS 17 |
| `NoteItShare` | `io.github.rutbergphilip.noteit.mobile.share` | share extension |
| `NoteItWidgets` | `io.github.rutbergphilip.noteit.mobile.widgets` | widget extension |
| `NoteItMobileTests` | — | smoke tests for app glue (launch, routing, rendering a note) |
| `NoteItMobileUITests` | — | UI smoke tests (launch, capture, save) |

The bundle id differs from the Mac's `io.github.rutbergphilip.noteit` so the two can't be confused in App Store Connect, and `AppIdentity` gains `mobileBundleID` and `appGroupID`.

**Apple Developer Program.** The Mac release already needs the paid membership (Developer ID). The same membership covers iOS. New items: an Apple Distribution certificate, App Store provisioning profiles for the three bundle ids, the App Group identifier, an App Store Connect app record, and an App Store Connect API key for CI uploads. Nothing extra to pay.

**Release pipeline.** `.github/workflows/mobile-release.yml`, triggered by tags `mobile-v*.*.*` (so it never collides with the Mac's `v*.*.*`). It runs on `macos-15`, installs XcodeGen, generates the project, archives with `xcodebuild archive`, exports with `-exportArchive` (method `app-store-connect`), and uploads to TestFlight with the API key. `CFBundleVersion` is the workflow run number; `CFBundleShortVersionString` comes from the tag. Signing uses automatic signing with the API key (`-allowProvisioningUpdates`), so no profiles are stored in the repo. Secrets: `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`, `APP_STORE_CONNECT_KEY_P8_BASE64`, `APPLE_TEAM_ID`. Submission for App Review stays a manual step in App Store Connect.

`ci.yml` gets its own `ios` job: generate the project, pick an available iPhone simulator from `xcrun simctl list` (no hard-coded device name), build and run `NoteItMobileTests` and `NoteItMobileUITests`. iOS tests stay smoke tests; logic lives in the SwiftPM targets and is tested with `swift test` in the existing jobs.

**Channels.**

- **M1:** TestFlight. Internal testers right away; an external public link after Beta App Review. The README links it as "iPhone beta".
- **M2:** App Store, free, no in-app purchases, no ads. Age rating 4+. Category Productivity.
- **App Review needs:** the app is usable without sync (**Use Without Sync**), so reviewers can test it without credentials. Review notes explain sync and pairing.
- **Privacy label:** "Data Not Collected". `PrivacyInfo.xcprivacy` declares no tracking and the required-reason APIs: `UserDefaults` (CA92.1) and file timestamps (C617.1).
- **Export compliance:** the app uses only Apple's CryptoKit/CommonCrypto for the user's own data. `ITSAppUsesNonExemptEncryption` is set to `NO` and the app is answered as exempt in App Store Connect, because the encryption only protects the user's own data. If Apple asks for a self-classification report, the answer is revisited.

**Licensing: AGPL and the App Store.**

NoteIt is AGPL-3.0-or-later. The Free Software Foundation's position is that the App Store terms (Apple's usage rules, the device limit and the ban on redistribution) are further restrictions on recipients, which GPLv3 and AGPLv3 §10 forbid. Apple has removed GPL apps from the store after complaints from copyright holders. Distributing an AGPL binary through the App Store is therefore not reliably allowed by the license alone.

The fix GPLv3 itself provides is an **additional permission** under §7, granted by the copyright holders. NoteIt can do this now: the project uses the DCO with no CLA, and the git history shows every commit is by the maintainer (plus one automated dependency bump with no copyrightable content).

- A new file `LICENSE-APP-STORE.md` grants: "As an additional permission under section 7 of the GNU Affero General Public License, the copyright holders give you permission to convey the covered work, or works based on it, through Apple's App Store and TestFlight, under Apple's standard terms, provided the corresponding source code for that version stays available as the license requires." Downstream redistributors may remove the permission, as §7 allows.
- `README.md` (License section) and `CONTRIBUTING.md` mention it. `CONTRIBUTING.md` says that contributions are made under AGPL-3.0-or-later **with this additional permission**, so future contributors grant it too (DCO sign-off covers the statement). The change lands before the first external contribution to mobile code and before the first TestFlight build.
- Every App Store build has a matching `mobile-v*` tag; About › Source code links to it. No third-party GPL code goes into the app (it uses only Apple frameworks and this repo's code, like the Mac app).
- This is not legal advice. The plan's distribution milestone includes reading the final text against the FSF FAQ wording and, if a contributor without the permission ever contributes mobile code, either getting their consent or rewriting that code.

### 10. App Intents and Shortcuts (M3)

- Names, parameters and results follow `automation` (Create Note, Append to Note, Find Notes, Open Note, Get Note Text, `NoteEntity`, `NotebookEntity`). The definitions and App Shortcuts phrases are shared with `automation` through the package where App Intents allow it (automation's spike, T19); where they can't be shared, the phone declares its intents from the same shared names and phrases rather than copies. The phone versions run against `DocLibrary` through `NoteLibrary`. Append to Daily Note isn't on the phone, because daily notes aren't.
- Intents run in the app process with `openAppWhenRun = false` (except Open Note). Create Note and Append to Note go through `NoteLibrary` like the composer. Before the first unlock after a restart the library files can't be read, and the intents fail with "Unlock your iPhone and try again."
- Find Notes searches metadata and the search index; results whose bodies aren't downloaded still return title and preview. Get Note Text fetches the body if needed and fails offline with "This note hasn't been downloaded."
- Notes in Recently Deleted are never returned. No destructive intents.
- `NoteItShortcuts: AppShortcutsProvider` registers the shared phrases "Create a note in NoteIt", "Search NoteIt" and "Add to a note in NoteIt".
- Get Note Text with Markdown format uses `NoteItMarkdown`. Locked notes are returned by Find Notes with their title only; Get Note Text fails on them with "This note is locked. Open it on your Mac."
- Spotlight on iOS (Core Spotlight) is not part of this spec; `automation` owns Spotlight indexing on the Mac, and iOS indexing waits until that design is extended to the phone.

### 11. Privacy and security summary

- Network: only the user's storage endpoint. No analytics, crash reporting or update checks (the App Store updates the app).
- Keys: data key and S3 credentials in the keychain, this device only. The passphrase is never stored on the phone after pairing or manual setup.
- Files: data protection until first unlock; the App Group is readable by NoteIt's own extensions only.
- Widgets: no bodies; titles can be turned off.
- App lock (M2): Face ID or passcode via `LAContext`, the app switcher snapshot is blurred while locked.
- Locked notes from `sync-security` are shown as locked and can't be opened in the phone's first releases. Their sealed bodies stay at `notes/<UUID>.locked`, are never decrypted, and are left out of the search index and widgets.
- Pairing: the QR code is sealed with a key derived from an 8-character code that the Mac shows and the phone asks for. The code expires after 10 minutes and works once. The QR alone isn't enough. The payload includes the S3 credentials, so the QR and code together grant full bucket access until the code expires; users who prefer not to send them can use **Set Up Manually**.

### 12. Performance budgets

| Measure | Budget | Device |
|---|---|---|
| Cold launch to composer with keyboard | < 400 ms | iPhone 12 |
| Share sheet visible | < 300 ms | iPhone 12 |
| Capture saved to inbox | < 50 ms | iPhone 12 |
| Library list ready, 10,000 notes | < 500 ms | iPhone 12 |
| Search keystroke, 10,000 notes | < 50 ms | iPhone 12 |
| Open a cached 50 KB note | < 150 ms | iPhone 12 |
| Sync pass, nothing changed, 10,000 notes | < 3 s | iPhone 12, Wi-Fi |

## Dependencies

- **Foundations (wave 0, `docs/plans/2026-10-19-foundations.md`):** `NoteItCore` (models, `SidebarSelection`, `LibraryQuery`, folding, `FuzzyMatcher`, query language, `NoteLink`, `URLCommand` parser), the Foundation-only `NoteItDoc` and `NoteItDocTestSupport`, `StoreSession` with manifest features, `SyncEngine.ensureFeature(_:backend:session:currentDeviceID:confirm:)`, `DeviceInfo` with `platform`, `appVersion`, `supportedFeatures` and `rekeyAck`, the `RemoteLayout` prefix registry, `RawMetaOverlay` in `NoteItSync`, and the `noteit-doc` schema (`BodyContainer`, `DocNode`, `DocValidation`, `AttachmentLimit`) with its golden vectors. The platforms line in `Package.swift` comes from there.
- **`web-app` (existing spec), Phase 0:** `bodies/`, `BodyFormat`, `DocDerivation`, the `NSAttributedString` conversion and its vectors, the conversion sweep, adding `noteit-doc` to `StoreFeature.supported`, and the upgrade to `noteit-doc` on the Mac. M1 can't ship until Macs write stores with the `noteit-doc` feature. The phone needs only Phase 0, not the Nuxt app. Both clients work only with stores whose manifest `features` contain `noteit-doc` and share its body format, so nothing here changes the wire format the web app reads.
- **`organise`:** the query language and ranking in `NoteItCore`; tag rules for derived tags. Notebook `parent` field kept. Smart folders aren't on the phone.
- **`markdown-storage`:** `NoteItMarkdown`, for Get Note Text in Markdown format.
- **`automation`:** owns `noteit://` routing and the `URLCommand` grammar, and the App Intent names and phrases. The phone implements a subset (§4, §10) and has no Local API, CLI or Spotlight.
- **`linking`:** the `NoteLink` format, rendered and opened by the phone. Backlinks, daily notes and templates aren't on the phone in this spec.
- **`sync-security`:** the keyring and `StoreCredential` (the phone stores the data key; a passphrase change needs nothing on the phone, a key replacement means scanning again), `rekeyInProgress` handling, `rekeyAck` in the device record, `locked-notes` in `StoreFeature.supported`, locked notes (shown locked, sealed files kept; locked notes are sync-security's milestone 5, which lands in wave 3 after web-app Tasks 0.4–0.5, so until then no store has `locked-notes` and the phone's tests use fixture stores), WebDAV (not on the phone in this spec).
- **`surfaces-polish`:** the phone ignores `boards/` records and keeps `checkedItemsToBottom` through `RawMetaOverlay`.
- **`capture-plus`:** none required. Its iOS counterparts (voice notes on the phone) would build on this app later.
- **`sharing`:** none required; `ShareLinkCodec` in `NoteItSync` is available for a later phone feature.
- **`growth`:** App Store listing and the name question (§4.5 there). The README and website mention the phone app as planned until M1 is on TestFlight.
- **Local API (01):** not used. The phone has no localhost server.

## Non-goals

- A NoteIt server, push notifications or any relay. Sync timing is limited by what iOS allows a background app to do.
- Creating a new sync library from the phone, upgrading a store to `noteit-doc`, or adding any manifest feature.
- Opening, locking or unlocking locked notes on the phone in its first releases.
- Editing tables, text colour, highlight, font size or alignment on the phone.
- Folder sync on the phone other than iCloud Drive (M3).
- An iOS PWA or iOS-specific work in the web app.
- Apple Watch, visionOS, macOS Catalyst. The Mac keeps its AppKit app.
- Local API, CLI, plugins, web clipper or Spotlight on iOS.
- Paid tiers, in-app purchases, ads or analytics.
- Pairing over Bluetooth, local network or iCloud Keychain.

## Open questions

1. **App Store name.** "NoteIt" may be taken or confusing (`growth` §4.5). Default: try "NoteIt" first; fall back to "NoteIt Notes" with subtitle "Private notes that sync".
2. **EU trader status (Digital Services Act).** Default: declare as a non-trader (free app, no revenue). If Apple requires trader status, publish a contact address rather than delay the EU listing.
3. **Additional permission scope.** Default: limited to Apple's App Store and TestFlight. Other stores (for example a future Mac App Store build) would need a new grant.
