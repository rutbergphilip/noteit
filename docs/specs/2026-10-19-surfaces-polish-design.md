# Surfaces and Polish — Design

Status: proposed · Date: 2026-10-19 · Companion plan: docs/plans/2026-10-19-surfaces-polish.md

## Goal

Give notes more places to live than the main window: a cheat sheet you hold a key to see, small notes that stay on top, and a board where a notebook's notes are laid out as cards. At the same time, finish the work that makes the app feel complete. That means:

- reading comfort (typography);
- checklists that behave the way people expect from Apple Notes and Things;
- a first-run guide;
- a VoiceOver pass;
- measured, published performance;
- the small rough edges in Quick Capture, pinning and the sync status.

All of it stays local-first. The only new remote data is the board layout record, which syncs through the existing encrypted store like every other record.

## What the user gets

- **Cheat sheet.** Hold a hotkey in any app and a note appears floating over that app. Let go and it's gone. Each app can have its own cheat sheet ("Figma shortcuts" while in Figma, "Git commands" in Terminal). One note can be the cheat sheet for every other app. The app you're in never loses focus.
- **Floating notes.** Window › Float Note pops the current note into a small window that stays on top of other apps. You can have up to 10, each with its own opacity. They come back where you left them the next time NoteIt starts.
- **Board.** A notebook can be shown as a board, with each note as a card you can drag anywhere. Zoom in and out. The layout syncs to your other Macs.
- **Typography.** Settings › Editor gets Font (System, Serif, Rounded), Zoom, Line spacing and Text width. These change how notes look on this Mac, never what's saved.
- **Checklists.** ⌘↩ checks or unchecks the item you're on. Tab and ⇧Tab nest items. Drag an item by its handle to reorder it, and its nested items move with it. A note can keep checked items at the bottom on its own. Checked items are dimmed and struck through.
- **Welcome.** On first launch a short guide first asks whether you're new to NoteIt or already use it on another Mac.
  - New to NoteIt: record hotkeys and set up the menu bar, bring notes from Apple Notes (about 30 seconds for 500 notes), Evernote or Notion, and see how to sync a second Mac.
  - Already use it on another Mac: set up sync first, so your notes arrive, then record hotkeys and set up the menu bar. There's no import step.

  You can skip it, and Help › Welcome to NoteIt… brings it back. It suggests no shortcuts: you record your own or skip the step.
- **VoiceOver.** Every control has a label. The editor has rotors for headings, checklist items, code blocks and links. The sidebar has rotors for notebooks and tags. The palette announces how many results it found.
- **Published performance.** `docs/performance.md` lists measured numbers, with the machine they came from:
  - launch to first keystroke;
  - opening a note;
  - searching 10,000 notes;
  - palette keystroke latency;
  - link suggestions and backlinks;
  - meaning search (Smart Features).

  `scripts/bench.sh` reproduces them.
- **Polish.**
  - Quick Capture opens with a short scale-and-fade and, on save, shrinks toward the menu bar icon.
  - Pinned notes get their own "Pinned" section in the list, a swipe action and a menu shortcut.
  - The sync pill opens a popover that says how many changes are waiting and has a Sync Now button.

## Design

### 1. Library settings file (shared storage)

Several features need per-library state that belongs to this Mac and must not be synced:

- typography;
- cheat-sheet assignments;
- open floating notes;
- which notebooks show as a board;
- board zoom.

`library.json` is the wrong place for it. It holds the note and notebook records, which sync, and keys in those records that this build doesn't know are preserved by `RawMetaOverlay` (foundations), so anything put there would travel to other devices. Board card positions are not in this file either: they sync, as their own record kind (§4).

- **File:** `library-settings.json` in `NoteStore.rootURL` (the data folder), like every other per-Mac file. It is never in a Markdown library's content folder.
- **Type:** `LibrarySettings` (in `Sources/NoteIt/Model/LibrarySettings.swift`), `Codable`. Every field is decoded with `decodeIfPresent`, so a missing key means the default.
  ```
  { "version": 1,
    "typography": { "lineSpacing": 1.0, "width": "full", "fontFamily": "system", "zoom": 1.0 },
    "cheatSheets": { "global": "<note uuid>" | null, "perApp": { "<bundle id>": "<note uuid>" } },
    "floatingNotes": [ { "noteID": "<uuid>", "frame": [x, y, w, h], "opacity": 1.0, "isVisible": true } ],
    "boardNotebookIDs": [ "<uuid>" ],
    "boardZoom": { "<notebook uuid>": 1.0 } }
  ```
  - Dictionaries keyed by UUID are encoded with string keys (`uuidString`). That keeps the JSON readable and avoids Swift's array encoding for non-string keys.
- **Access:** only through `NoteStore`:
  - `librarySettings` (published, read-only);
  - `updateLibrarySettings(_:)`, which takes a mutating closure, clamps values, saves with the same debounce as the library, and posts `.noteItLibrarySettingsChanged`.
  - No view reads the file directly.
- **Never synced:**
  - The sync adapter only reads notebooks, notes, smart folders and board records, so nothing has to be excluded.
  - Floating-window frames and cheat-sheet app IDs are specific to one Mac.
  - Typography is a reading preference. A second Mac can have a different screen.
- **Errors:**
  - An unreadable file is renamed `library-settings.corrupt-<timestamp>.json` and defaults are used. Nothing here is user content, so there is no alert, only an `NSLog` line.
  - A file whose `version` is newer than this build understands is read for the keys it knows. Changes are then kept in memory for the session and not written, so a newer NoteIt's file is never overwritten by an older one.
- **Deleted notes:** note IDs that no longer exist, or that are in Recently Deleted, are pruned from cheat sheets, floating notes and board flags when the store loads, and on `noteItLocalChange`.
- **Markdown folder library (02 `markdown-storage`):** the file stays in `NoteStore.rootURL`. Markdown-storage's content folder (`contentRootURL`) never holds it, so nothing in this section changes for Markdown libraries.

### 2. Cheat-sheet overlay

**Triggering**

- New global hotkey **Show Cheat Sheet**, `HotkeyAction.cheatSheet`, at position 13 in the frozen hotkey order (program §9). It's unbound by default, like every global hotkey, and listed in Settings › Shortcuts › Global with its own tile color. The task that adds the case also adds its `ShortcutsSettingsView` tile and its `AppDelegate` handler.
- **Mode** (Settings › General › Cheat Sheet, key `cheatSheetMode`; the section is `GeneralSettingsSection.cheatSheet`, already in the frozen section order between `reminders` and `updates` (foundations task 6.5); this sub-project flips its availability):
  - **Hold to show** (default): the cheat sheet shows while the hotkey is held and hides on release. A tap shorter than 300 ms latches it open, so a quick press works like Toggle; the next press closes it.
  - **Press to toggle**: one press shows, the next hides.
- Holding needs key-up events. `HotkeyManager` also listens for `kEventHotKeyReleased` and calls a new `releaseHandler`. Key repeat while held is ignored.
- Palette command **Show Cheat Sheet** (id `showCheatSheet`) opens it in toggle mode for the app that was in front when the palette opened. `PaletteController` records it in a new `previousApp` property, read from `NSWorkspace.shared.frontmostApplication` as the palette appears.
- Link **`noteit://cheat-sheet`** toggles it for the app in front, and `noteit://cheat-sheet?app=<bundle id>` for a named app. It's registered by this sub-project through `URLRouteRegistry.register(host:handler:)` (foundations task 5.4; dispatch is automation's), so Shortcuts, scripts and launchers can show it. It changes no note, so it never asks for confirmation. There is no Local API route for it (program §10).

**Which note**

- Assignments are stored per library in `library-settings.json` under `cheatSheets`:
  - one optional **global** note;
  - per-app notes keyed by bundle ID.
- At press time NoteIt reads `NSWorkspace.shared.frontmostApplication?.bundleIdentifier`:
  - If an app note is set, it's used.
  - Otherwise the global note is used.
  - If neither is set, the panel shows "No cheat sheet for <App name>." with a button **Choose a Note…**. The button opens Settings › General › Cheat Sheet.
- When NoteIt itself is in front, the global note is used.
- **Assigning:**
  - Note list context menu and the editor header's ⋯ menu: **Use as Cheat Sheet** › **For All Apps** / **For <App>…**. **For <App>…** opens a sheet listing running regular apps plus **Other App…**, which shows an `NSOpenPanel` filtered to applications.
  - Palette: **Use as Cheat Sheet for All Apps** (`cheatSheetGlobal`) and **Use as Cheat Sheet for <previous app>** (`cheatSheetForApp`).
  - Settings › General › Cheat Sheet:
    - Mode picker.
    - Global note picker.
    - A table of app rows (icon, name, note title, remove button).
    - **+**, which adds an app using the same app sheet.
- A note can be the cheat sheet for several apps. Assigning a new note to an app replaces the old one.

**The panel**

- `CheatSheetPanel: NSPanel`, styled like `QuickCapturePanel` and `CaptureToastPanel`:
  - `[.borderless, .nonactivatingPanel, .fullSizeContentView]`;
  - level `.floating`;
  - `canJoinAllSpaces`, `fullScreenAuxiliary`, `transient`;
  - `canBecomeKey` false. The app in front keeps focus and keyboard input.
- Content:
  - a small header (note title, app icon when it's an app sheet);
  - a `RichTextEditor` in the cheat-sheet role, using the same typography as the editor. The user can't type in it: the panel never becomes key, and the text view has `isEditable = false`, which also turns off checkbox clicks, drag handles and drops. Nothing writes into it except the mirror below.
- **Keeping it current** (program §6): the cheat sheet is a read-only surface, so it registers in `OpenEditorRegistry` as an **observer** of its note (`registerObserver(_:for:)`, foundations task 4.5) while the panel is visible, never as an editor. `textView(for:)` never returns it and `editBody` never edits it.
  - On every show the body is loaded through `NoteStore.body(for:)`, so saved edits always appear.
  - If the main window, a floating note or the board's note pane has the note open, the observer mirrors that editor's text storage, including typing not saved yet, after each edit it processes.
  - If no editor has the note open, `editBody`'s closed path saves the change and the registry passes the new body to the observer, for example when a task in the sheet is completed from the Tasks view or a plugin edits it.
  - The observer is removed when the panel hides. There is never a second registered editor for one note.
- Scrolling with the trackpad works without activating NoteIt, because non-activating panels receive scroll events.
- Links open in their app; note links (`noteit://note/…`, linking) open the note in the main window.
- Size: default 420 × 520 pt; resizable from 280 × 200 up to 90% of the screen.
  - Default position: the right third of the screen under the mouse, centered vertically.
  - The panel can be dragged by its header. Its frame is saved with `setFrameAutosaveName("NoteItCheatSheet")`, which lives in this Mac's defaults, because frames belong to screens, not libraries.
- **Closing (Toggle mode or a latched tap):**
  - the hotkey again;
  - a click outside the panel, caught by a global mouse-down monitor (which needs no permission);
  - the frontmost app changing (`NSWorkspace.didActivateApplicationNotification`).
- Esc can't close it, because the panel never becomes key and reading global key presses would need Input Monitoring. The help text says so: "Press the hotkey again or click anywhere to close."
- `TransientSurfaceHider` gets a `.cheatSheet` surface, so showing the panel while NoteIt is hidden doesn't bring NoteIt's windows forward.
- Motion: 0.12 s fade in, 0.08 s fade out. With Reduce Motion the fade is instant.

**Edge cases**

| Case | Behaviour |
|------|-----------|
| The assigned note was deleted | The assignment is pruned and the "No cheat sheet" state is shown. |
| The assigned note is locked (08 `sync-security`) | "Locked notes can't be shown as a cheat sheet." The body is never decrypted for the overlay, even while the note is unlocked in NoteIt. **Use as Cheat Sheet** is disabled for locked notes with the same help text. |
| The library is switched | Assignments belong to the library, so they switch with it. |
| A full-screen app is in front | The panel appears over it (`fullScreenAuxiliary`). |
| Secure input is on (a password field is focused) | Carbon hotkeys don't fire, so nothing happens. This is documented in known limitations. |

**Privacy**

- The frontmost app's bundle ID is read only when the hotkey is pressed. It's stored only when the user assigns a note to that app.
- It stays in `library-settings.json`, which is never synced.

### 3. Floating notes

**Behaviour**

- **Window › Float Note** (palette `floatNote`; note list context menu **Float Note**) opens the selected note in a floating window. It has no default shortcut.
- Link **`noteit://float?id=<UUID>`** floats a note from Shortcuts, scripts or another app. It's registered through `URLRouteRegistry.register(host:handler:)` (foundations task 5.4) and follows the same rules as the menu command (limit, locked notes). It changes no note, so it doesn't ask for confirmation. There is no Local API route for it (program §10).
- If the note is already floating, the command brings its window to the front.
- `FloatingNotePanel: NSPanel` with `[.titled, .closable, .resizable, .fullSizeContentView, .utilityWindow]`:
  - level `.floating`;
  - `hidesOnDeactivate = false`;
  - `collectionBehavior` `[.canJoinAllSpaces, .fullScreenAuxiliary]`.
- It does become key when clicked, so it's editable like the main editor. It uses the same `RichTextEditor`, so edits commit through `NoteStore.updateBody` with the usual 0.3 s debounce, and version history and sync behave as they do for the main window.
- Its text view registers with `OpenEditorRegistry` (organise) for as long as the window is open, so `NoteStore.editBody` changes the floating note in place, as one undo step, like it does for the main editor (program §6).
- Title bar: the note title and a ⋯ menu with:
  - **Opacity** (100%, 85%, 70%, 55%, 40%);
  - **Show in Main Window**;
  - **Return to Main Window** (closes the float and selects the note);
  - **Close**.
- Default size 320 × 360 pt; minimum 220 × 160. A new float opens cascaded 24 pt from the previous one near the top right of the screen with the mouse.
- **Limit:** 10 floating notes. An 11th shows "You can float up to 10 notes. Close one first."
- **Show/Hide:** new global hotkey **Show / Hide Floating Notes**, `HotkeyAction.toggleFloatingNotes`, at position 14 in the frozen hotkey order (program §9), unbound by default. The task that adds the case also adds its tile and `AppDelegate` handler. The same toggle is in the Window menu and the palette (`toggleFloatingNotes`). It's also in the menu bar extra when at least one note floats. Hiding keeps the windows' state; showing restores them.
- **One editor per note:** the main window never shows a second live editor for a floating note. `OpenEditorRegistry` holds one text view per note, and `RichTextEditor` only reloads on `NoteStore.externallyUpdatedNoteID`, so two editors would silently overwrite each other. The main window's editor area shows instead:
  > This note is in a floating window.
  >
  > **Show Window**  **Return to Main Window**
- **Restore:** open floats are saved in `library-settings.json` (`floatingNotes`, with frame, opacity and visibility). Each change is saved with the library debounce, and all are saved again on quit. At launch, after the main scene is built, each saved note that still exists and isn't deleted gets its window back.
  - A frame that no longer intersects any screen is moved onto the main screen's visible frame.

**Edge cases**

| Case | Behaviour |
|------|-----------|
| The note is deleted (locally or by sync) | The window closes and its entry is removed. |
| Sync changes the body | The floating editor reloads through `externallyUpdatedNoteID` like the main editor. |
| Code changes the body (`editBody`) | The change runs inside the floating editor, keeps its undo stack and is saved like typing. |
| The note is locked (08) | Notes with a lock can't float, even while unlocked for the session, because a float would outlive 08's auto-relock. Float Note is disabled with the help text "Locked notes can't float." Locking a floating note closes its window. |
| The library is switched | All floats close; the new library's floats are restored. |
| Typography | Floats use the library typography and zoom. |

**Privacy:** floating windows use `sharingType = .readOnly` (the default), so they appear in screen recordings like any window. Nothing extra is stored.

### 4. Board view

**Behaviour**

- When a notebook is selected in the sidebar, the note list toolbar shows a segmented **List | Board** control. The same switch is in the palette as **Show as Board** / **Show as List** (`toggleBoard`). The choice is per notebook and stored in `library-settings.json` (`boardNotebookIDs`). All Notes, Pinned, Recent, Tags, Conflicts and Recently Deleted are list-only.
- In Board mode, `MainView` swaps the note list and editor columns for `BoardView`, which spans both columns.
- **Opening a card:** the note opens in the board's own note pane, a resizable panel on the right edge of `BoardView` (default 420 pt wide). It is not the window's `.inspector`, which belongs to linking (Links and Outline, ⌥⌘I; program §9). The pane hosts the same `RichTextEditor` as the main window and registers with `OpenEditorRegistry` like it, so `editBody` reaches the open card. While board mode is on, ⌥⌘I shows or hides linking's inspector inside the pane, for the opened note. Plugin inspector tabs appear there the same way.
- **Cards:** 220 × 140 pt, showing:
  - the title;
  - three lines of preview;
  - the pin glyph;
  - the date edited.
- **Interacting with cards:**
  - Click selects a card; Shift-click or a drag on empty space selects several.
  - Drag moves the selected cards. Positions snap to an 8 pt grid.
  - Double-click or Return opens the note in the note pane. Esc closes the pane.
  - Arrow keys move the selection to the nearest card in that direction. ⌥ plus an arrow nudges the selected cards by 8 pt; ⌥⇧ plus an arrow nudges by 64 pt.
  - The context menu matches the note list's, plus **Float Note**.
- **Zoom:** 50%–200%. Pinch, ⌘-scroll or the toolbar's − / 100% / + all work. Zoom is per notebook in `library-settings.json` (`boardZoom`), so it stays on this Mac.
- **Arranging:** **Arrange in Grid** (toolbar ⋯ and palette `boardArrange`) lays cards out in rows by date edited. A notebook that has never been arranged shows the same grid.
- **New notes:** a new note in the notebook gets the first free grid slot to the right of the last row. With the board in front, ⌘N places the new note at the center of the visible area.
- **Moving notes:** dropping a card on a notebook in the sidebar moves the note (the same drag type as the list, `note.id.uuidString`).
- **No freeform drawing,** arrows, groups or images on the canvas in v1.

**Data model and sync**

Board layouts are their own record kind, not a field on `Notebook` (program §4 rules 6 and 14, and §12). One record per notebook, last writer wins.

- **Type:** `BoardLayout` in `NoteItCore`, so the phone and other targets can decode it:
  - `BoardLayout { version: Int = 1, notebookID: UUID, revision: String, modifiedAt: Date, positions: [String: BoardPosition] }` (position keys are note UUID strings);
  - `BoardPosition { x: Double, y: Double }` in board points at 100% zoom.
  - Unknown keys in a board record are kept through `RawMetaOverlay` when this build rewrites it, like note and notebook records.
- **Remote:** `noteit/v1/boards/<notebookID>.json`, sealed with the store key like every other record. The `boards/` prefix is registered in `RemoteLayout.prefixes` as `RemotePrefix(path: "noteit/v1/boards/", depth: 1, sealing: .storeKey, owner: "surfaces-polish")`, so `RekeyRunner` re-seals it, and the web server's key vectors in `fixtures/golden/layout-keys.json` gain a valid `noteit/v1/boards/<UUID>.json` key and the `boards/` list prefix. The wire prefix `noteit/v1/` doesn't change.
- **Local:** `boards/<notebookID>.json` in `NoteStore.rootURL` (the data folder), written atomically. The file also holds the remote revision last applied to that board (local only, never synced). Unknown keys in board records survive through foundations' per-kind raw-meta lifecycle as kind `boards`: the raw copy in `sync-meta-raw/boards/<notebookID>.json` is written before the board is applied, merged on export only when its source revision matches the applied one, deleted only after the board file is gone, and still merged after a relaunch. Like `library-settings.json`, it is never in a Markdown library's content folder, so Markdown libraries need nothing extra.
- **Engine:** `RecordKind.board`, no body, `usesLastWriterWins` (the flag organise adds for notebooks and smart folders).
  - A board's ID is its notebook's ID, so board bases are kept in their own map in `SyncState` (`boardBases`, decoded with `decodeIfPresent`) and never share an entry with the notebook.
  - Boards have no tombstones (program §4 rule 14), because `tombstones/<id>` would collide with the notebook's. A board is deleted with its notebook: deleting a notebook on a Mac deletes its board record (local file and remote object, best effort). A board whose notebook is missing or tombstoned is ignored on every device. The web app and the phone never delete records they don't use (program §4 rule 9), so when a notebook is deleted there, the next Mac that syncs and sees the orphaned board deletes it.
- **Writes:** a move changes the positions, sets a new `revision` and `modifiedAt` on the board record only, and is saved with the normal debounce. A drag commits once, on mouse-up. The notebook record and its revision don't change, so moving cards never conflicts with renaming or moving the notebook on another Mac.
- **Conflicts:** if two Macs rearrange the same board at the same time, the later layout wins entirely: last writer wins for the whole board record (`boards/<notebookID>.json`), as the program requires. There is no per-card merge in this version. No conflict copy is made for a layout.
- **Pruning:** positions for notes that left the notebook or were deleted are dropped the next time the board is saved. Notes without a position use the auto-placement above, which doesn't write until the user moves something, so opening a board never creates a sync change.
- **Older versions:** NoteIt 0.2 never lists `boards/` (its remote index skips folders it doesn't know), so it neither reads nor damages board records. Editing a notebook on 0.2 keeps the layout, because the layout isn't in the notebook record.
- **Limits:** the board shows up to 2,000 cards, the most recently edited. Above that a bar says "Showing the 2,000 most recently edited notes. Use the list to see all of them." Only cards that intersect the visible area are built, so scrolling stays smooth.
- **The web app (store format v2) and mobile (11):** they ignore `boards/` records without error and never delete them until they show boards, as they do for smart-folder records (program §4.9). Because the layout isn't in the notebook record, they have nothing to carry through when they write a notebook. When they delete a notebook, a Mac removes its board later (above).

**Accessibility**

- Each card is one element: "<title>, card, edited <relative date>". Its custom actions are Open, Move Left, Move Right, Move Up and Move Down, each moving one grid step (64 pt).
- The board exposes a rotor "Cards" in reading order (top to bottom, left to right).

### 5. Typography

**Controls**

Settings › Editor › Text, below the existing "Default font size", which still only affects new text:

| Setting | Control | Values | Default |
|---------|---------|--------|---------|
| Font | Picker | System, Serif (New York), Rounded (SF Rounded) | System |
| Zoom | Stepper with value | 90%–150% in 10% steps | 100% |
| Line spacing | Slider | 1.0–1.8 in 0.1 steps, labelled "Tight" … "Relaxed" | 1.0 |
| Text width | Picker | Narrow (560 pt), Medium (720 pt), Wide (900 pt), Full (1100 pt) | Full |

- The sample text under the controls updates live.
- Footnote: "These change how notes look in this library on this Mac. Notes themselves aren't changed."
- **Zoom commands** (View menu, palette, `MenuShortcutCommand`): **Zoom In** ⌃⌘=, **Zoom Out** ⌃⌘-, **Actual Size** ⌃⌘0, as in the program's frozen menu table (§9). They don't use ⌘=/⌘-/⌘0, which are already taken by Bigger, Smaller and NoteIt Notes. They can be remapped in Settings › Shortcuts like other menu shortcuts.

**How it works (display only)**

Fonts and paragraph spacing are saved inside each note's RTFD, so changing them for real would rewrite every note and create sync traffic. All four settings are therefore applied at display time, the way `CodeStyler` handles inline code:

- **Zoom** is `NSScrollView.magnification` on the editor's scroll view. Text stays sharp, and the column math works on the magnified width.
- **Text width** feeds `EditorColumnLayout.fitting(width:maxReadingWidth:minInset:)`, which already takes the maximum. `EditorStyle.maxReadingWidth` becomes the selected width.
- **Line spacing** comes from an `NSLayoutManagerDelegate` that adds `(multiple − 1) × line height` after each line fragment. Code blocks keep 1.0, so code cards stay tight.
- **Font family** swaps runs whose font is the system font for the chosen design (`NSFontDescriptor.SystemDesign.serif` / `.rounded`) at the same size and traits. The original font is stored in a display-only attribute.
  - `TypographyStyler.persisted(_:)` puts it back, and `NoteItTextView.attributedString()` and `writeSelection(to:type:)` already route through the persisted form. So saving, copying, dragging, export and print see the real fonts.
  - Fonts the user set explicitly (via the Font panel) and code runs are left alone.
- Changes apply live to every open editor, floating note and cheat sheet, through `.noteItLibrarySettingsChanged`.

**Edge cases:** Export and Print use the saved fonts and widths. Typography is per library, so switching libraries switches typography. Values out of range in the file are clamped.

### 6. Onboarding

**When it shows**

- Automatically only on a fresh library: the launch where `NoteStore` seeded the welcome notes and `onboardingCompletedVersion` (UserDefaults) is below `OnboardingFlow.currentVersion` (1).
- People upgrading from 0.2 don't see it.
- Always available from **Help › Welcome to NoteIt…** and the palette (`showWelcome`).
- Debug: `--debug-onboarding` launch argument.

**Window and paths**

- A SwiftUI `Window("Welcome to NoteIt", id: "welcome")`, 560 × 460, not resizable. It shows page dots, **Back** / **Continue**, and **Skip Setup** on every page. Skip Setup and closing both set `onboardingCompletedVersion` to the current version.
- The first page asks one question, and the answer picks the path. **Back** to the first page lets the user change the answer.

| Page | New to NoteIt | I use NoteIt on another Mac |
|------|---------------|-----------------------------|
| 1 | Welcome (the question) | Welcome (the question) |
| 2 | Hotkeys | Sync first |
| 3 | Menu bar and Dock | Hotkeys |
| 4 | Bring your notes | Menu bar and Dock |
| 5 | Another Mac | Done |
| 6 | Done | — |

**Pages**

- **Welcome.** "NoteIt is for fast notes on this Mac. Your notes stay on your Mac unless you set up sync." Two large choices:
  - **New to NoteIt**
  - **I use NoteIt on another Mac**
- **Sync first** (other-Mac path only). "Connect this Mac to the storage your other Mac syncs with. Your notes will appear here."
  - **Set Up Sync…** opens Settings › Sync (`SettingsTabRouter.show(.sync)`). Sync setup itself is the sync feature's UI; this page only links to it and shows its state.
  - The page shows `SyncController`'s status while it waits: "Not set up yet", "Syncing…", then "Synced. 1,204 notes on this Mac." **Continue** is always allowed, so a slow first sync never traps the user.
  - Before sync is set up from this path, the seeded welcome notes are removed if they are unchanged, so they don't sync to the other Mac as duplicates. They were never synced, so they leave no Recently Deleted entries and no tombstones. Edited welcome notes are kept.
  - This path has no import page. Notes come from the other Mac.
- **Hotkeys.** Three rows: Quick Capture, Show / Hide NoteIt and Command Palette. Onboarding suggests no default hotkey (program §9).
  - Each row has an empty `ShortcutRecorder`, the same control as Settings › Shortcuts, with the help text "Click to record a shortcut."
  - The page has **Skip**, which moves on with nothing bound. Once a row has a recorded shortcut, the page's button reads **Continue** instead.
  - Nothing is registered until **Continue**. Then recorded rows go through `HotkeyManager.setCombo`.
  - A combo that `isSystemShortcut` rejects, or that `registrationErrors` reports as taken, shows "In use by macOS or another app. Pick another." on its row, and the page stays.
  - Rows left empty stay unbound, which keeps the "unbound by default" rule: nothing is bound unless the user records it.
- **Menu bar and Dock.** The same controls as Settings › General (Dock and menu bar / Menu bar only, Show menu bar icon, Launch at login), bound to the same keys.
- **Bring your notes** (new-user path only). Three buttons: **Apple Notes**, **Evernote** and **Notion**, plus **Other…**, which opens the import sheet with every source (Markdown files, Bear and the rest).
  - Evernote and Notion use markdown-storage's importers (`ImportSource.evernote` and `.notion`) with the same file prompts and wording as the import sheet. Until markdown-storage ships them, those two buttons are hidden.
  - Each importer runs inside the page through `ImportModel` and shows the existing progress line ("Importing 312 of 1,040…").
  - For Apple Notes, the macOS automation prompt appears on the first click, and denial shows the existing permission message.
  - **Continue** is allowed while importing. If the window closes mid-import, the run continues in the existing import sheet via `ImportSheetPresenter.show(continuing:)`.
  - **Target:** 500 Apple Notes in about 30 seconds on Apple silicon, measured by hand and recorded in `docs/performance.md`.
  - Importing doesn't change how the library is stored. Markdown storage is chosen only from Settings › Your Data (markdown-storage), never in onboarding.
- **Another Mac** (new-user path only). "Use NoteIt on another Mac by syncing through a folder or storage you own. Notes are encrypted before they leave this Mac."
  - **Set Up Sync…** opens Settings › Sync.
  - **Not now** moves on.
- **Done.** Three tips: Command Palette shortcut, Quick Capture, "Hold your cheat-sheet hotkey in any app". Then **Start Writing**, which closes the window and focuses the editor (`WindowRouter.focusEditor()`).

**Errors:** a failed hotkey registration stays on its row. An import failure shows the importer's existing error text, and the user can continue. A sync setup failure is shown by the Sync settings, and the Sync first page keeps waiting. The window never blocks the main window.

**Privacy:** onboarding itself sends nothing anywhere. Sync connects only after the user sets it up in Settings › Sync. Onboarding state is one integer in UserDefaults.

### 7. Accessibility audit

**Scope:** sidebar, note list, editor header and toolbar, editor text, palette, Quick Capture, capture toast, Settings, sync status, and the new surfaces (cheat sheet, floating notes, board, onboarding).

**Labels**

- Labels come from a pure `NoteAccessibility` helper so they can be unit tested:
  - Note row: one element, "<title>, pinned, <notebook>, edited <relative date>, <preview>". "Untitled" is used for an empty title.
  - Sidebar rows: "All Notes, 120 notes".
  - Pin icon: "Pinned". Sync pill: the existing headline.
  - Toolbar buttons: their menu titles.
- Every icon-only `Button` and `Image(systemName:)` used as content gets `.accessibilityLabel`. Decorative images get `.accessibilityHidden(true)`.

**Rotors**

- Sidebar: **Notebooks**, **Tags**.
- Note list: **Pinned Notes**.
- Editor (`NoteItTextView.accessibilityCustomRotors()`): **Headings**, **Checklist Items**, **Code Blocks**, **Links**. They're built from a pure `EditorRotorIndex` over the text storage, using the block markers in `EditorStyle` and the `.link` attribute, and refreshed lazily after edits.
- Board: **Cards**.

**Custom actions in the editor**

- **Toggle Checkbox** for the checklist line at the insertion point.
- **Copy Code Block** when inside one.
- **Move Item Up** and **Move Item Down** on a checklist item (§12).

**Announcements**

- The palette posts `.announcementRequested` with "12 results" (`NoteAccessibility.resultsAnnouncement`), debounced 0.5 s after typing stops.
- Quick Capture announces "Saved to <notebook>".

**Motion and contrast**

- All new motion checks `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`.
- Tokens used for text meet 4.5:1 in light and dark. The audit lists any that don't, and they're fixed in the same milestone.

**Automated checks (SwiftPM, no XCUITest)**

- Unit tests for every `NoteAccessibility` builder and `EditorRotorIndex`.
- `AccessibilityAuditTests` hosts each main view (`SidebarView`, `NoteListView`, `EditorContainerView`, `PaletteView`, `SyncStatusPill`, onboarding pages, `BoardView`) in an `NSHostingView` inside an offscreen `NSWindow`, with a temporary `NoteStore`. The test then:
  - walks `accessibilityChildren()` recursively;
  - fails on any element whose role is button, image, checkbox, pop-up button or slider and has an empty label and title, unless it's hidden.
- If the hosted tree comes back empty (no window server), the test is skipped with `XCTSkip` and the pure tests still run.

**Manual checklist:** `docs/accessibility.md` lists a VoiceOver walk-through of each surface (navigate, act, hear the right thing), a keyboard-only pass, and a Reduce Motion / Increase Contrast pass. Each row records the result and the version. It's run before each release that touches UI.

### 8. Performance benchmark suite

**Harness**

The app target is an executable, and SwiftPM won't let another executable link it, so the benchmarks run inside NoteIt:

- `NOTEIT_BENCH=<suite>` runs a benchmark and exits. Suites: `launch`, `openNote`, `search`, `palette`, `links`, `semantic`, `all`.
- `NOTEIT_BENCH_OUT=<path>` sets where the JSON results are written. The default is `<data dir>/bench-<suite>.json`.
- It refuses to run without `NOTEIT_DATA_DIR`, with the message "Benchmarks need NOTEIT_DATA_DIR", so it can never touch a real library.
- `NOTEIT_BENCH_FIXTURE=<count>` fills an empty data dir with a deterministic library first and exits after writing. It is the one shared fixture for every suite, including the linking and private-ai numbers; no sub-project builds its own benchmark library.
  - `<count>` notes, seeded text with headings, lists, checklists, code and web links, 1–40 KB bodies, 20 notebooks, tags.
  - Note links in the stored form (`noteit://note/<UUID>`): five per note on average (50,000 at 10,000 notes), one hub note with 500 backlinks, and one 5,000-paragraph note. These match the library linking's targets are stated for.
  - Everything is written through `NoteStore`, so every `DerivedIndex` indexer (search, links, and the semantic index when Smart Features are on) sees the same notes.
- The harness is compiled into release builds, because the numbers must be for release code. It does nothing unless `NOTEIT_BENCH` is set.

**Suites**

| Suite | What is measured | Runs |
|-------|------------------|------|
| `launch` | From process start (`kinfo_proc.p_starttime` via `sysctl`) to a synthetic key event's character landing in the editor's text storage. The key is posted with `NSApp.postEvent` as soon as the main window is key with an editor. | One per process; `scripts/bench.sh` launches 10 times. |
| `openNote` | From changing `store.selectedNoteID` to the editor's first draw after the body is loaded, for 30 notes of 1 KB, 20 KB and 200 KB (with an image). | 30 × 3 |
| `search` | `NoteStore.notes(for:search:)` over the 10,000-note fixture for 20 fixed queries (1–3 words, including single letters). | 20 queries × 5 |
| `palette` | Typing "project review notes" one character at a time into `PaletteModel.query`. Each sample runs from setting the query until `items` publishes. | 21 keystrokes × 5 |
| `links` | Link suggestions: typing a 12-character title one character at a time into `LinkSuggester` over the fixture, each sample on the main actor. Backlinks for the hub note with 500 sources. Loading `link-index.json`. Metrics and targets are linking's (linking spec §14). | 12 keystrokes × 5; backlinks × 20; load × 5 |
| `semantic` | Meaning search: 20 fixed queries through `SmartSearchService`, each sample covering query embedding plus search at the fixture size. Also records the first full index build time and the index size on disk. Metrics and targets are private-ai's. | 20 queries × 5; build × 1 |

**Results**

- Each result records:
  - suite;
  - Mac model (`hw.model`);
  - chip;
  - macOS version;
  - NoteIt version and git commit (from `Info.plist`);
  - note count;
  - samples in milliseconds;
  - median, p95, min and max (`BenchStats`).
- **Script:** `scripts/bench.sh [--notes 10000] [--runs 10]` does this:
  - builds release;
  - creates the fixture once in `.bench/library-<count>` (gitignored);
  - copies it per run, so runs don't affect each other;
  - runs every suite;
  - calls `scripts/bench_report.py`, which rewrites the table between `<!-- bench:start -->` and `<!-- bench:end -->` in `docs/performance.md`.
- **Targets:** the first published table states these. A miss is reported, not hidden.

  | Metric | Target |
  |--------|--------|
  | Launch to first keystroke (warm) | ≤ 600 ms median |
  | Open a 20 KB note | ≤ 50 ms median |
  | Search 10,000 notes | ≤ 30 ms median |
  | Palette keystroke | ≤ 16 ms p95 |
  | Link suggestion update per keystroke | ≤ 8 ms (linking) |
  | Backlinks for a note with 500 sources | ≤ 16 ms (linking) |
  | Load `link-index.json` | ≤ 150 ms (linking) |
  | Meaning search, query embedding plus search at 10,000 notes | under 60 ms (private-ai) |
  | First semantic index build, 10,000 notes | under 15 minutes on one core (private-ai) |

  The linking and private-ai rows are those sub-projects' targets, copied here for the published table. If their specs change a target, the table follows them.

- **Suites that need another sub-project:** `links` runs once linking has shipped, and `semantic` once private-ai has. `semantic` also needs Smart Features turned on in the fixture library and an on-device embedding model; when either is missing it writes a result marked "skipped" with the reason, and the table shows "not measured" instead of a number.
- **CI:** the suite doesn't run in CI, because shared runners are too noisy to publish numbers from. CI only runs the `BenchStats`, fixture and suite-selection unit tests.
- **Publishing:** `docs/performance.md` in the repo. 13 `growth` may show it on the website.

**Privacy:** the results file includes the Mac model and macOS version. It's written only where the user points it, and nothing is uploaded.

### 9. Quick Capture motion

- **Show:** the panel starts at 96% scale, 8 pt above its final spot, with alpha 0, and animates to its final frame and alpha 1 over 0.18 s (ease out).
- **Save:** the panel shrinks to 20% while moving toward the menu bar icon, fading out over 0.22 s (ease in). The menu bar glyph then pulses: it shows the capturing glyph for 0.4 s.
  - The icon's frame is found by looking for the status item's window in `NSApp.windows`. If it can't be found, or the icon is hidden, the panel shrinks toward the top center of the screen.
- **Discard / Esc:** a fade to 0 with a slight scale to 98% over 0.12 s.
- **Reduce Motion:** fades only, at the same durations, with no scale or movement.
- The frame math is pure (`QuickCaptureMotion`) and unit tested.
- The existing `presentationGeneration` guard stays, so a show during a dismissal animation is never closed by the old completion.

### 10. Pinning polish

- **Sections:** in All Notes, a notebook, Recent and tag lists, when there are both pinned and unpinned notes, the list shows section headers **Pinned** and **Notes**. Pinned is the Pinned view itself, so it shows no headers. Search results keep one flat ranked list.
- **Sidebar:** this sub-project adds the **Pinned** library row (program §9) at its place in the frozen `SidebarLibraryRow` order (foundations task 1.1): All Notes, Today, Tasks, Pinned, Recent, Conflicts. Today (linking) and Tasks (organise) sit above it when they're present, Recent and Conflicts below it; Recently Deleted stays in its own section at the bottom. This sub-project doesn't move other rows.
- **Swipe:** a leading swipe on a row shows **Pin** / **Unpin** (orange, `pin` / `pin.slash`).
- **Shortcut:** new `MenuShortcutCommand.togglePin`, **Pin Note** / **Unpin Note**, default ⌥⌘P (program §9).
  - The menu item is the first item in the `NoteCommands` group, which foundations renamed from `RecentlyDeletedCommands` (task 6.4). The group's order is the frozen `NoteCommands.order`: Pin, Lock Note, Remove Lock, Lock All Notes, Version History, Delete. Pin doesn't add or move the others.
  - The palette's existing `togglePin` command shows the shortcut.
  - The editor header's pin button shows it in its help tag.
- **Motion:** pin and unpin animate the row into its new place (`.snappy`), with no animation under Reduce Motion.
- **Accessibility:** the pin icon is labelled "Pinned". The pin button reads "Pin Note" / "Unpin Note".
- No limit on pinned notes. The data model doesn't change (`NoteMeta.isPinned`).

### 11. Sync status polish

This covers presentation only. Sync setup, devices and conflict compare belong to the sync feature and 08 `sync-security`.

- **Popover:** clicking `SyncStatusPill` opens `SyncStatusPopover` instead of jumping straight to Settings. It shows:
  - the existing `SyncStatusPresentation.headline(now:)`;
  - **"Everything is synced"** or **"3 changes waiting to sync"**;
  - last sync time, relative;
  - **"2 conflicts"** when there are any, which selects Conflicts in the sidebar;
  - **Sync Now**, disabled while syncing or when sync isn't set up;
  - **Sync Settings…**.
- **Wording:**
  - Offline: "Offline. Changes are saved on this Mac and will sync when you're back online."
  - Not set up: "Sync is off. Set up sync to use your notes on another Mac." with **Set Up Sync…**.
  - Errors keep their existing text and add **Sync Settings…**.
- **Count:**
  - `SyncState.unsyncedCount(local:deletions:)` in `NoteItSync` counts:
    - local records whose revision differs from their base, or have no base;
    - local deletions not yet in `knownTombstones`.
  - `SyncEngine.unsyncedCount()` applies it to the engine's state and the adapter's records.
  - `SyncController` publishes `unsyncedCount: Int?` (nil when not configured) after each pass, and 2 s after `noteItLocalChange`.
- **Menu bar:** `MenuBarSyncRow` shows the same count when it's above 0.

### 12. Checklist polish

Checklists already exist: `☐`/`☑` list markers, click or ⇧⌘U to check, Tab and ⇧Tab to change a list item's level, and a dimmed, struck-through style for checked items. This section makes them behave like a dedicated checklist app. Program §12 assigns it here.

**Toggle with ⌘↩**

- ⌘↩ is a second key for Format › Mark as Checked (⇧⌘U) and does exactly what it does: it toggles every checklist item in the selection, or the item the insertion point is on. On a line that isn't a checklist item it turns the line into one, as ⇧⌘U does today. The undo name is "Check" or "Uncheck".
- It's an editor key shortcut (a `KeyShortcut` entry in `FormatCommand.swift`), so `MenuShortcutRules` treats it as reserved and the collision test catches any menu shortcut set to ⌘↩.
- It works in the main editor, floating notes and the board's note pane. Quick Capture keeps ⌘↩ as Save, because its panel handles the key first. The cheat sheet can't be typed in.

**Nesting with Tab and ⇧Tab**

- Tab indents the item and its nested items together; ⇧Tab outdents them together.
- An item can be at most one level deeper than the item above it, and at most 6 levels deep. Tab beyond that does nothing (no beep, no tab character).
- Return on an empty nested item outdents it one level. Return on an empty top-level item ends the list, as today.
- These rules apply to every list kind (bullets, numbers, checklists), because they share the level code.

**Checked style**

- A checked item's own text is dimmed (`EditorStyle.checkedTextColor`) and struck through. Its nested items keep their own state and style.
- Every way of checking an item applies the style, and unchecking removes it: a click, ⇧⌘U, ⌘↩, the VoiceOver Toggle Checkbox action, moving items, pasting checklist items, and importing `- [x]` from Markdown or `noteit-doc`.
- The checkbox draws filled with the accent color and a check mark. With Increase Contrast on, checked text uses `secondaryLabelColor` so it stays readable.
- The style is saved in the note, as today. It's not a display-only setting.

**Keep checked items at the bottom (per note)**

- A per-note toggle, **Keep Checked Items at Bottom**, in the editor header's ⋯ menu, the editor's context menu (checklist section) and the palette (`checkedItemsToBottom`). The menu item shows a check mark when it's on. It's off for new notes.
- Stored as `NoteMeta.checkedItemsToBottom: Bool?` in `NoteItCore` (nil means off). It's a synced field: it's in the note's `meta` record and travels with the note's metadata to every device. Following program §4.5, it's added to the revision fields only when it's set (not nil), so existing revisions don't change. Turning it off writes nil, not `false`. Apps that don't know it keep it through `RawMetaOverlay`, and markdown-storage stores it with the other `NoteMeta` fields.
- When it's on:
  - Checking an item in the editor moves it, with its nested items, to the top of the checked items at the end of its own list and level. The check and the move are one undo step, so ⌘Z puts it back unchecked in its old place.
  - Unchecking an item moves it back to just after the last unchecked item at its level.
  - Turning the toggle on sorts every checklist in the note once, as one undo step ("Move Checked Items to Bottom"). Turning it off leaves the order as it is.
  - Sorting is stable and stays inside one list and one level; nested items are sorted within their parent.
- Checks made by other code through `NoteStore.editBody` (for example completing a task from the Tasks view) don't move items. The next sort in the editor puts them in place. Moving text in another sub-project's edit would surprise its undo name and its Version History entry.

**Drag to reorder**

- Hovering a checklist item shows a grip handle in the margin to the left of its checkbox, outside the text column.
- Dragging the handle moves the item and its nested items. An insertion line shows where it will land, and its horizontal position picks the level, within the nesting rules above. Dragging near the top or bottom edge scrolls. Esc cancels.
- The drop is one undo step, "Move Item". It only moves items within the same note; dropping outside the list cancels.
- Keyboard and VoiceOver: **Move Item Up** and **Move Item Down** in the editor's context menu and the palette (`moveItemUp`, `moveItemDown`), and as custom accessibility actions on the item. They have no default shortcut.
- The handle only shows in editable text views, so never in the cheat sheet, or in print and export.

**How it works**

- A pure `ChecklistOutline` reads the paragraphs of a text storage into items (paragraph range, level, list kind, checked state, parent) using the existing `EditorStyle.listMarker(in:)` and `listLevel(of:)`. It answers: an item's range including its nested items; whether an indent is allowed; the order after sorting checked items; and the edit for moving an item to a new place and level.
- `NoteItTextView` applies those answers as text edits through `shouldChangeText`/`didChangeText`, so undo, saving, version history and sync behave as they do for typing.
- `NoteItLayoutManager` draws the grip handle and the insertion line.

**Edge cases**

| Case | Behaviour |
|------|-----------|
| A checklist item inside a quote or next to a table | Moves stay inside the list's contiguous paragraphs. Quotes, tables and code blocks are never moved or split. |
| Mixed list kinds at one level | Each contiguous run of one list kind is its own list for sorting and drops. |
| A very long list (1,000 items) | Sorting and a drop each take one pass over the list's paragraphs; the edit is a single replacement. |
| A locked note | Locked notes can't be opened in an editor without unlocking, so nothing here applies to them while locked. |
| A Markdown library | Items are saved as nested `- [ ]` / `- [x]` lines by markdown-storage. The per-note toggle travels with the note's metadata. |

## Dependencies

- **foundations (wave 0):**
  - `NoteItCore` holds `BoardLayout`, `BoardPosition` and `NoteMeta.checkedItemsToBottom`.
  - `RemoteLayout.prefixes` gets the `boards/` row (depth 1, `.storeKey`), with key vectors in `fixtures/golden/layout-keys.json`. `RawMetaOverlay` keeps unknown keys in board, note and notebook records.
  - The frozen tables fix this sub-project's hotkey positions (`HotkeyOrder` 13 and 14), menu shortcuts (⌥⌘P, ⌃⌘= / ⌃⌘- / ⌃⌘0), the `NoteCommands` group and its order (task 6.4), the sidebar order (`SidebarLibraryRow`) and the General tab's section order (`GeneralSettingsSection`, task 6.5).
  - `OpenEditorRegistry` and `editBody` (task 4.5), including `registerObserver(_:for:)`, the observer registration read-only surfaces use (program §6).
  - `URLRouteRegistry` (task 5.4), through which the `float` and `cheat-sheet` hosts are registered.
  - `NoteBodyStorage` is the only way bodies are read and written; `NoteStore.body(for:)` and `updateBody` go through it.
- **01 `automation`:** owns `noteit://` dispatch. This sub-project registers the `float` and `cheat-sheet` hosts through foundations' `URLRouteRegistry`. It adds no Local API routes; the only UI route stays automation's `POST /v1/notes/{id}/open`.
- **02 `markdown-storage`:** provides the Evernote and Notion importers offered in onboarding, and stores `NoteMeta.checkedItemsToBottom` with the other note fields and nested checklists as nested `- [ ]` lines. `library-settings.json` and `boards/` stay in `NoteStore.rootURL`, so its folder layout needs nothing for them. Choosing Markdown storage stays in Settings › Your Data. Typography is display-only, so it works unchanged on Markdown libraries.
- **03 `linking`:** owns the window inspector (Links and Outline, ⌥⌘I); the board's note pane shows it for the opened card. The Today sidebar row sits above Pinned. Note links in cheat sheets and floating notes open the target note in the main window. Defines the link-suggestion, backlink and index-load metrics measured by the `links` suite.
- **04 `organise`:** the behaviour of `NoteStore.editBody` and `OpenEditorRegistry` (built in foundations); floating notes and the board's note pane register with it as editors, and the cheat sheet as an observer. `RecordKind.usesLastWriterWins`, which board records use. The Tasks sidebar row sits above Pinned. Board view applies to a notebook's direct notes; with nested notebooks, child notebooks are not shown as cards in v1. Smart folders and tags are list-only. The audit covers organise's new views.
- **05 `capture-plus`:** adds the `emailIn` General section. The General tab is already a scrolling form from foundations (task 6.5); the Cheat Sheet section is the frozen `GeneralSettingsSection.cheatSheet` case, whose availability this sub-project turns on.
- **06 `private-ai`:** defines the meaning-search and index-build metrics measured by the `semantic` suite, and provides `SmartSearchService`.
- **08 `sync-security`:** locked notes can't be cheat sheets or floats. The sync status popover links to its conflict compare when it exists.
- **11 `mobile` and `web-app` (store format v2):** ignore `boards/` records without error and never delete them until they show boards; a Mac removes boards orphaned by notebook deletions there. They keep `checkedItemsToBottom` through their `RawMetaOverlay`.
- **13 `growth`:** may publish `docs/performance.md` numbers on the website. Onboarding copy matches the site's wording.
- **Sync (existing):** one new record kind under `noteit/v1/boards/`. The notebook and note records gain no board data.

## Non-goals

- Freeform drawing, connectors, groups, images or frames on the board. Boards for smart folders or tags.
- Rewriting saved fonts or spacing in notes ("apply typography to note"), and per-note typography.
- Syncing typography, cheat-sheet assignments or floating-window state between Macs.
- Editing in the cheat sheet. A cheat sheet that follows the active document or website, not just the app.
- Running benchmarks in CI, or collecting performance data from users.
- XCUITest-based UI automation.
- A full second main window. Floating notes are the multi-window story for v1.
- Onboarding for people upgrading from an earlier version, tours or tooltips inside the main window.
- Choosing Markdown storage in onboarding. It's chosen only from Settings › Your Data (markdown-storage).
- Local API routes for floating notes or cheat sheets. `noteit://float` and `noteit://cheat-sheet` cover automation.
- Dragging list items between notes, and drag handles for bullet and numbered lists, in v1.
- An app-wide "keep checked items at the bottom" setting. The toggle is per note.

## Open questions

| Question | Default chosen |
|----------|----------------|
| Should cheat-sheet assignments sync between Macs? | No. They're per library on this Mac in `library-settings.json`. Bundle IDs and apps differ between Macs. |
| Should typography sync? | No. Per library, this Mac only. |
| How should two editors on one note be handled? | They aren't allowed. The main window shows a placeholder while a note floats, and the cheat sheet is only ever an observer in `OpenEditorRegistry`, never a second editor. |
| Zoom shortcuts, given ⌘=/⌘-/⌘0 are taken? | ⌃⌘= / ⌃⌘- / ⌃⌘0, remappable. |
| Pin shortcut | ⌥⌘P, remappable. |
| Cheat sheet hold threshold | 300 ms; a shorter tap latches open. |
| Should benchmark code ship in release builds? | Yes, inert unless `NOTEIT_BENCH` and `NOTEIT_DATA_DIR` are set, so numbers reflect release code. |
| Should onboarding show for upgrading users? | No. Only on a freshly seeded library, plus Help › Welcome to NoteIt…. |
| Maximum floating notes | 10. |
| Board card limit | 2,000 most recently edited. |
| Should checks made through `editBody` move items to the bottom? | No. Only checks in the editor move items; the next sort in the editor tidies the rest. |
| Should ⌘↩ on a non-checklist line turn it into a checklist? | Yes, to match ⇧⌘U exactly. One command, two keys. |
| Shortcuts for Move Item Up / Down? | None by default in v1. They're in the context menu, the palette and VoiceOver actions. |
| Maximum list depth | 6 levels. |
