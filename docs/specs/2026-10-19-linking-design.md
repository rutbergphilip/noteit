# Linking, Daily Notes and Templates — Design

Status: proposed · Date: 2026-10-19 · Companion plan: docs/plans/2026-10-19-linking.md · Program contract: docs/specs/2026-10-19-program-design.md (wins where this spec disagrees)

## Goal

Turn a pile of notes into a connected notebook without giving up speed: type `[[` to link to another note, see what links back, keep links working when titles change, open today's note with one key, start new notes from templates, and jump around a long note through its headings. Everything works offline, on both library formats, and stays fast with 10,000 notes.

## What the user gets

### Links between notes

- Typing `[[` in a note opens a small suggestion list under the caret. It shows the 8 most recently edited notes, and filters as you type: `[[proj` finds "Project Atlas". Each row shows the note title with the matched letters in bold and its notebook in grey.
- ↑/↓ (or ⌃P/⌃N) move through the list, ↩ or Tab inserts the link, Esc closes the list and leaves what you typed.
- The link shows the target note's title in the accent color, without an underline, so it reads differently from a web link (blue, underlined).
- `[[Project Atlas|the project]]` links to "Project Atlas" but shows "the project". Typing `|` in the query keeps the list on the target and uses the rest as the shown text.
- `[[Project Atlas#Budget]]` links to the heading "Budget" inside that note. After `#` the list shows that note's headings. `[[#Budget]]` links to a heading in the current note.
- When nothing matches, the last row is **Create "Project Atlas"**. Choosing it creates that note (empty except for its title, or from the notebook's template) and links to it. You stay in the note you're writing.
- Typing the whole thing by hand works too: `[[Some title]]` becomes a link when you type the closing `]]`, like the other Markdown shortcuts. ⌘Z restores the typed text.
- If no note has that title, the link is shown in grey with a dotted underline. Clicking it creates the note and opens it.
- **Format › Link to Note…** (⇧⌘K) opens the same list. With text selected, the selection is the query and becomes the shown text.
- Clicking a link opens the target note in the main window. **View › Go Back** (⌃⌘←) and **Go Forward** (⌃⌘→), plus back/forward buttons in the window toolbar, walk the notes you opened by following links or picking them in the list.
- A link to a note in Recently Deleted is shown struck through. Clicking it says **"Project Atlas" is in Recently Deleted** with **Show** and **Cancel**. A link to a note that no longer exists shows its text in grey and clicking it offers **Remove Link**.
- Right-click a note in the list › **Copy Note Link** runs the same command as **Edit › Copy Note Link** (⌃⌘L), which `automation` owns. Pasting the result into another note makes a note link. Pasting it into another app gives a `noteit://note/<UUID>` address, which `automation`'s URL router opens.

### Links and Outline panel

- **View › Show Links and Outline** (⌥⌘I) opens the main window's inspector on the right of the editor. Linking owns the inspector. It has two tabs, **Links** and **Outline**, and remembers which one was open and whether it was shown. Plugin panels (`plugins`) appear as extra tabs, and the board view (`surfaces-polish`) can show the same inspector next to a card's note.
- **Links** has three sections:
  - **Backlinks (12)**: every note that links to this one, newest first. Each row shows the note title and its notebook, then one line of text around each link with the link text in bold. Clicking a line opens that note with the caret on the link.
  - **Unlinked Mentions (4)**: notes that mention this note's title in plain text but don't link to it. Collapsed by default; it's only searched when you open it. Each line has a **Link** button that turns that mention into a link. **Link All** in the header does every one, after a confirmation that names the count.
  - **In This Note (5)**: the links this note makes, in order. Links to notes that don't exist yet have a **Create** button.
- While NoteIt is still reading notes for the first time after the update, the panel says **Finding links… 4,120 of 10,000** and fills in as it goes.
- **Outline** lists the title, headings and subheadings of the open note, indented by level. The heading you're reading is highlighted. Clicking one scrolls there and puts the caret at its start. A note without headings shows **No headings yet** and the tip **Use ⌥⌘2 for a heading.**

### Renaming

- A note's title is its first line, as today. Links store the note, not the title, so renaming never breaks a link.
- Links whose shown text is the old title are updated too. After you change a title and stop typing for 2 seconds, a bar under the note header says **Update 3 links that show "Atlas"?** with **Update** and **Not Now**. Links that show something else (`[[Project Atlas|the project]]`) are never changed. Each note it changes gets a Version History entry of its text from just before the change; afterwards the bar says **Updated 3 links** with **Undo**.
- **Settings › Editor › Links › When a note is renamed** offers *Ask* (default), *Always update links* and *Never update links*.

### Daily notes

- **File › Open Today's Note** (⌃⌘T) opens today's note, creating it if needed. The same action is a global hotkey, **Open Today's Note**, in Settings › Shortcuts › Global, unbound by default, a command palette command, **Today's Note**, and an **Open Today's Note** Shortcuts action (when Shortcuts actions are available, see Dependencies).
- The sidebar has a **Today** row right after All Notes (before Tasks, Pinned, Recent and Conflicts; Recently Deleted sits in its own section at the bottom), with a calendar icon and the day of the month. Clicking it opens today's note and shows the daily notes notebook in the list.
- Daily notes live in the **Daily Notes** notebook, which is created the first time with the `calendar` symbol. Settings can point to another notebook.
- The title is the date. **Settings › Editor › Daily Notes › Title** offers `2026-10-19` (default), `19 October 2026` and `Monday, 19 October 2026`, in your Mac's language for the last two.
- A daily note's header has ‹ and › buttons that go to the previous and next daily note that exists, and a calendar button.
- The calendar button, the Today row's right-click menu and the palette command **Daily Note for Date…** open a month calendar. Days that have a note have a dot. Clicking such a day opens it. Clicking an empty day shows **Create note for Tuesday, 14 October** under the calendar.
- A daily note can start from a template, chosen in **Settings › Editor › Daily Notes › Template**.
- Text appended to a daily note from elsewhere (Append to Today, the Local API, the command line, `noteit://append?daily=today`, Shortcuts) is added as `- 14:05 text` lines, always 24-hour.

### Templates

- A template is an ordinary note in the **Templates** notebook, created the first time you use the palette command **New Template** with the `doc.on.doc` symbol. You write and format it like any note.
- Templates can contain variables, which are filled in when the template is used:

  | Variable | Becomes |
  |---|---|
  | `{{title}}` | The new note's title: the link text when created from a link, the date for a daily note, the text typed in the template picker, otherwise empty |
  | `{{date}}` | Today as `2026-10-19`. `{{date:EEEE d MMMM}}` uses any date pattern |
  | `{{time}}` | The time as `14:05` (24-hour) or `2:05 PM`, following the Mac's setting. `{{time:HH:mm:ss}}` uses any pattern |
  | `{{clipboard}}` | The plain text on the clipboard, up to 10,000 characters |
  | `{{cursor}}` | Where the caret goes. Only the first one counts |

  A variable takes the formatting of its first brace, so a bold `{{date}}` gives a bold date. Unknown variables are left as typed.
- **File › New Note from Template…** (⌥⌘N) shows a picker with a search field and the list of templates. Text typed in the search field that matches no template can be used as the title: ↩ on a template uses the typed text as `{{title}}` when it doesn't match the template's name. The note is created in the notebook selected in the sidebar, as ⌘N does.
- **Format › Insert Template…** inserts a template at the caret in the open note. `{{title}}` becomes the open note's title there.
- Each notebook can have a template for new notes: the notebook sheet (**Edit Notebook…**) has **Template for new notes**, *None* by default. ⌘N in that notebook, Quick Capture into it and **Create "…"** from a link all use it.
- In the picker and menus, a template is named by its title line with the variables left out, so "Meeting – {{date}}" is listed as "Meeting –" trimmed to "Meeting". A title made only of variables is listed as "Untitled Template".
- Notes in the Templates notebook are left out of link suggestions, backlinks, unlinked mentions and daily notes, so their placeholder links don't clutter real notes.

## Design

### 1. How a link is stored

**Decision: a standard link attribute with a `noteit:` URL, not a custom attribute.** RTFD drops custom attributes (that's why block kinds are stored as paragraph-style sentinels, see `EditorStyles.swift`), but it keeps `.link` exactly. A note link is therefore an ordinary `.link` run whose value is a `URL`, and its text is what's shown. This also flows through copy/paste, version history, sync (`noteit/v1/` bodies are flattened RTFD, unchanged) and the `noteit-doc` `link{href}` mark without schema changes.

URL grammar (`NoteItCore.NoteLink`, in `Sources/NoteItCore/NoteLink.swift`, so `automation`'s `URLCommand` parser, the phone and the Mac app share one definition), parsed case-insensitively, written in canonical form. Linking owns this format; foundations Task 5.3 builds `NoteLink` in wave 0 and linking uses it without creating it:

| Form | Meaning |
|---|---|
| `noteit://note/<UUID>` | Link to a note (UUID uppercase when written) |
| `noteit://note/<UUID>?heading=<text>` | Link to the first heading with that text in the note |
| `noteit://note?title=<text>` | Unresolved link to a note titled `<text>` |
| `noteit://note?title=<text>&heading=<text>` | Unresolved link with a heading |

`<text>` is percent-encoded with `URLComponents` query rules. Titles and headings are limited to `NoteLink.maxTextLength` (120) characters; `NoteLink` rejects longer text, so linking cuts a title or heading to 120 characters before it builds a link. Anything else with the `noteit` scheme is not a note link and is handed to `automation`'s URL router, which owns all `noteit://` routing (including `noteit://open?id=`, which opens the same note).

- `URLCommand` has `.note(id:heading:)` and `.noteTitle(title:heading:)`, built from `NoteLink` (both from foundations Task 5.3; `automation` owns the router). Their handlers call `NoteStore.followLink(_:from:)` (§3), so a note link opened from another app behaves exactly like one clicked in the editor.
- Shown text is the run's text. When it equals the target's title, compared with `TextFold.fold`, the link counts as "showing the title" for rename updates. Otherwise it is an alias.
- Heading targets are matched by text, not by position, because there is no stable heading identity in RTFD. If the heading is renamed, the link still opens the note, at the top, and the header shows **Heading "Budget" not found** for 3 seconds.
- Links are never placed in code blocks or inline code: the `[[` trigger, the `]]` shortcut and the suggestion list are off there, matching the other Markdown shortcuts (`MarkdownShortcuts.swift` already returns early for `.code` and inline code).
- `#hashtags` inside link text keep being ignored for tags (`NoteStore.parseTags` masks `.link` ranges).
- In `noteit-doc` (web-app spec, §3.3), a note link is `link{href: "noteit://note/<UUID>…"}`. Foundations (program §2 step 2) already lets the Swift `DocValidation` and the TypeScript validator accept `noteit:` links matching this grammar, with golden vectors, so linking makes no validator change.

### 2. Display

- `NoteItTextView.linkTextAttributes` is reduced to the pointing-hand cursor. A new `LinkStyler` (in `Editor/`) colors links with layout-manager temporary attributes, the same technique `CodeStyler` uses, so nothing is written into the note:
  - web and mail links: `NSColor.linkColor`, single underline (today's look);
  - resolved note links: `Tokens.Color.accent`, no underline;
  - unresolved: `secondaryLabelColor`, dotted underline;
  - target in Recently Deleted: `secondaryLabelColor`, strikethrough;
  - target gone: `tertiaryLabelColor`.
- Styling runs for the visible paragraphs after load and for edited paragraphs after a 0.15 s debounce, and again for the whole note when the store's notes change (a target is renamed, deleted or created). It never runs during layout or drawing.
- An unresolved link whose title now matches a live note (created later or on another Mac) is drawn as resolved. Clicking it resolves it for good: the URL is rewritten to the note's UUID through `NoteStore.editBody` on the source note (one undo step in the open editor).
- Tooltips (`displaysLinkToolTips`) show the target's title and notebook for note links instead of the raw URL, via `textView(_:willDisplayToolTip:forCharacterAt:)` on the coordinator.

### 3. Following links and navigation history

- `RichTextEditor.Coordinator.textView(_:clickedOnLink:at:)` checks `NoteLink(url:)` first and handles note links in place, without a round trip through Launch Services. Both a click and `automation`'s `.note`/`.noteTitle` handlers call `NoteStore.followLink(_:from:)`, which uses `NoteStore.resolve(_:)`:
  - `.note(id, heading)`: commit the current note, select the target, set `RichTextEditor.pendingCaret[id]` to the heading's location (or the start), and record the move in `NavigationHistory`. If the target's notebook isn't the current sidebar selection, the selection switches to *All Notes* and the search field is cleared (as `NoteStore.reveal(_:)` does).
  - `.unresolved(title)`: if a live note has that title, resolve as above and rewrite the link. Otherwise create the note (§5) and open it.
  - `.deleted(id)`: alert with **Show** (selects Recently Deleted and the note) and **Cancel**.
  - `.missing(id)`: alert **This note no longer exists** with **Remove Link** (removes `.link` on the run through `NoteStore.editBody`, one undo step) and **Cancel**.
- Several notes with the same title: an unresolved link resolves to the one in the source note's notebook, else the most recently edited one.
- `NavigationHistory` keeps up to 50 entries per main window, drops entries for notes that are gone or deleted when moving through them, and is reset when the window closes. Every note opened in the editor (list click, palette, link) is a visit; consecutive visits to the same note count once.

### 4. Typing `[[` and the suggestion list

- `NoteItTextView.insertText` already dispatches Markdown triggers. When the typed character is `[` and the one before it is `[`, outside code, the editor opens a session of the shared `InlineCompletionController` anchored at the caret rectangle, with a `LinkCompletionSource`. The query is the text from after `[[` to the caret.
- `InlineCompletionController` is generic: it owns the panel, placement, key handling and close rules, and asks an `InlineCompletionSource` for rows and for what to insert. Linking creates it; `organise` reuses it for tags and the query language with its own sources instead of building a second panel.
- The list closes when the caret leaves that range, the query passes 120 characters or contains a line break, on Esc, when the window resigns key, or when `]]` is typed (which then runs the `]]` shortcut).
- Keys reach the list through `NSTextViewDelegate.textView(_:doCommandBy:)` on the coordinator: `moveUp:`, `moveDown:`, `insertNewline:`, `insertTab:`, `cancelOperation:`, and ⌃P/⌃N via `moveUp:`/`moveDown:` bindings. Typing still goes into the note, so undo, marked text (input methods) and spell checking behave as normal.
- The window is a borderless child `NSPanel` of the editor window hosting a SwiftUI list, at most 8 rows of 28 pt, 320 pt wide, placed below the caret or above it when there isn't room. It never becomes key.
- `LinkSuggester` (pure Swift, no AppKit) ranks candidates:
  - The query is parsed as `title[#heading][|alias]`.
  - Candidates are live notes, minus the current note when no heading is given, minus templates, minus notes with an empty title.
  - Empty title query: the 8 most recently edited notes.
  - Otherwise `FuzzyMatcher.evaluate` over titles with a shared `FuzzyQuery`, exact title first, then by score, then by `updatedAt`.
  - Heading mode: the target is the exact title match, or the top suggestion; its headings come from `OutlineExtractor` over `NoteStore.body(for:)` and are filtered with the same matcher.
  - **Create "…"** is appended when the query has a title and no live note has exactly that title (folded). It's the first row when there are no other matches.
- Accepting replaces `[[` + query (and a `]]` right after the caret, if present) with one link run in a single undo group. The run uses the typing attributes at the `[[` minus `.link`, and the typing attributes after it have no `.link`, so the next character isn't part of the link.
- The `]]` shortcut (`MarkdownShortcuts.swift`, new case for `]`) matches `\[\[([^\[\]\n]{1,240})\]$` before the caret, parses the inside the same way and links to the exact-title note if one exists, else writes an unresolved link. As with `**bold**`, the conversion is its own undo step.

### 5. Creating a note from a link

- **Create "…"** in the list, a click on an unresolved link, and **Create** in the panel all call `NoteStore.createNoteForLink(title:from:)`.
- Notebook: **Settings › Editor › Links › New notes from links go to**: *The same notebook as the linking note* (default) or *The notebook for new notes* (the existing **Default notebook for new notes** setting).
- Content: the notebook's template with `{{title}}` set to the link title, or a title paragraph (text styled with `EditorStyle.attributes(for: .title)`) and an empty body paragraph.
- From the list, the new note is not opened. From a click it is opened. Either way the source link is a resolved `noteit://note/<UUID>` afterwards.

### 6. Link index

The link index answers "what links here" without reading note bodies.

- **Extraction.** `LinkExtractor.links(in:)` enumerates `.link` runs once and returns `OutgoingLink { link, text, location, context }`. `context` is the surrounding paragraph trimmed to 80 characters around the link, on one line. At most 2,000 links per note are kept.
- **Updating.** The link index registers as a `DerivedIndex` (program §7; the registry is built by foundations Task 4.4), the only hook for keeping data in step with note bodies. Linking does not edit `NoteStore.swift` to add hooks. All hooks run on the main actor.
  - `noteChanged(_:body:)`: called wherever a body is committed (create, `updateBody`, `editBody`, and after `applyPreparedRemoteNote` on the sync path). Never called for locked notes, and never for metadata-only changes. Extraction of a 10,000-word note takes under 2 ms, and runs on the same commit that derives the title and tags, never per keystroke.
  - `noteRemoved(_:)`: removal for good drops the note's entries. It's also called when a note is locked.
  - `metadataChanged(_:)`: metadata-only changes: pin, move, tag, moving to Recently Deleted and recovering from it. Entries are kept; queries filter deleted sources out.
  - `rebuild(notes:body:)`: the library rebuild and the background index rebuild pass each parsed body to every registered index, so each RTFD file is read once.
  - `flush()`: writes `link-index.json` (below).
- **In memory** (`LinkIndex`, created by linking and registered with the `DerivedIndex` registry once per store open, program §7): `outgoing: [UUID: [OutgoingLink]]`, a reverse map `incoming: [UUID: Set<UUID>]`, and `unresolvedByTitle: [String: Set<UUID>]` keyed by folded title. Backlinks to a note are the sources in `incoming[id]` plus the sources in `unresolvedByTitle[fold(title)]`.
- **On disk**: `link-index.json` in `NoteStore.rootURL` (the data folder, next to `search-index.json`), never in a Markdown library's content folder. Local only, never synced, rebuildable:

  ```json
  {"version": 1, "entries": {"<UUID>": {"updatedAt": "2026-10-19T08:00:00Z",
    "links": [{"url": "noteit://note/…", "text": "Atlas", "location": 120, "context": "…"}]}}}
  ```

  As with the search index, an entry is used only if its `updatedAt` matches the note's within 1 s, and notes with unsaved bodies are left out when saving. It is written atomically when the registry calls `flush` (the same 3-second coalescing as the search index). It's loaded on a background task when the store opens, so a 10,000-note file never blocks the first frame. Notes missing an entry join the registry's background rebuild, which publishes progress for the panel.
- **Privacy.** `link-index.json` holds short snippets of note text, like `search-index.json` holds the full text. It stays in the data folder and is covered by the same "starting over" instructions. Locked notes (`NoteMeta.isLocked`, program §8) are left out entirely: no entry, no context, and links to them show only their title. When a note is locked, its entry is removed.
- **Title index.** `[String: [UUID]]` from folded title to live, non-template notes, rebuilt lazily when `notesVersion` changes (like `noteIndexByID`). It serves unresolved links, the rename check, imports and daily notes.

### 7. Backlinks and unlinked mentions

- `NoteStore.backlinks(to:)` returns one `Backlink` per live source note, sorted by `updatedAt` descending, each with its occurrences in text order. Self-links are listed under **In This Note** only.
- **Unlinked mentions** are searched only when the section is expanded, on a background task, cancelled when the note changes:
  1. Skip titles shorter than 3 characters, and notes whose title is only a date (daily notes would match too much); the section then says **Titles this short aren't searched.**
  2. Take a snapshot of the folded search index, and keep notes whose folded text contains the folded title at a word boundary, excluding the note itself, templates, deleted notes and notes that already link to it (resolved or by title).
  3. Show up to 100 notes, each with the first 3 mentions' context; **Show All** lists the rest.
- **Link** on a row finds the mention in that note with `MentionFinder.ranges(of:in:)` (case-, accent- and width-insensitive, whole words, not inside an existing link, code or the note's own title line) and adds the `.link` attribute keeping the text, through `NoteStore.editBody` (which handles a note open in any editor and keeps its undo).
- **Link All** does the same for every listed mention, 20 notes per run-loop turn so the UI stays responsive. Because it changes more than one note, each note is changed through `editBody` with `versioning: .recordCurrent`, so `editBody` records one Version History entry per note before the change (linking never records versions itself); it then reports **Linked 14 mentions in 9 notes.** with **Undo** (program §6).

### 8. Rename updates

- `RenameTracker` (per editor) remembers the open note's title when it's opened and after each completed update. After a commit changes the title, it waits until the title has been unchanged for 2 s, then asks `NoteStore.renameCandidate(for:oldTitle:)`: the live, editable source notes with links to this note whose text equals the old title (folded).
- With *Ask*, `EditorContainerView` shows `LinkRenameBanner` under the header. Typing more in the title restarts the 2 s wait and keeps the original old title, so "Atl" → "Atlas" → "Atlas 2" asks once about the original.
- **Update** calls `NoteStore.rewriteLinkText(targeting:from:to:)`. It replaces the text of each matching run with the new title, keeping its attributes, through `NoteStore.editBody` with `versioning: .recordCurrent`, so `editBody` records each note's current text in Version History exactly once before changing it (new revision, synced like any edit; a note open in any editor, including the current one, is changed through its text view so its undo keeps working), 20 notes per run-loop turn. Notes in Recently Deleted, locked, with load errors or write-blocked are skipped and counted: **Updated 12 links. 1 note couldn't be changed.** with **Undo**, which restores the recorded versions of the changed notes that haven't been edited since. Undo restores through `restoreVersion`, which itself goes through `editBody`.
- **Not Now** dismisses until the title changes again. With *Always*, the update runs without the banner and shows a 3-second confirmation with **Undo** in the same place. With *Never*, nothing happens.
- Unresolved links whose title equals the new title are not rewritten automatically; they already resolve by display (§2).

### 9. Outline

- `OutlineExtractor.items(in:)` walks paragraphs and keeps those whose `EditorStyle.blockKind(paragraphStyle:font:)` is `.title` (level 0), `.heading` (1) or `.subheading` (2), skipping empty ones and table cells.
- The panel refreshes 0.3 s after the last edit, from the text view's storage, and marks the last heading above the top of the visible rect as current (updated on scroll, throttled to 10 per second).
- Clicking scrolls the heading to the top third of the editor and places the caret at its start. ⌘-click selects the whole section up to the next heading of the same or a higher level.

### 10. Daily notes

Linking owns how daily notes behave and look. Two pieces of the code are built earlier, in wave 0, so other sub-projects can rely on them: `NoteStore+Daily` (`dailyNote(for:createIfMissing:)`) and `DailyLogAppender`. Moved to foundations (docs/plans/2026-10-19-foundations.md, Task 4.6). They follow the rules in this section; linking's own work builds the UI and the template on top of them. Foundations also adds the gate `DailyNotes.isAvailable` in `NoteItCore`, false in wave 0: while it's false, daily surfaces are hidden and the daily API routes return `501 not_implemented` (program §5). Linking sets it to true in the task that ships the daily UI.

- **Identity.** A daily note is a live note in the daily notes notebook whose title parses as a date in any supported title format (`iso`, `long` or `weekdayLong`), not only the current one, so changing the format never loses old notes or creates a second note for the same day. New notes are titled in the user's chosen format (`dailyNoteTitleFormat`, default `iso`); existing titles are not rewritten. Titles are formatted and parsed by the daily note title functions in `NoteItCore` (`DailyNoteTitle`, `DayKey`). `NoteStore.dailyNoteIndex` maps `DayKey` (year, month, day in the current calendar) to the note with the oldest `createdAt`; it's rebuilt lazily when `notesVersion` changes. The note ID is random, not derived from the date: deterministic IDs would collide with Recently Deleted entries and sync tombstones.
- **Two Macs offline.** If both create the same day's note before syncing, both exist afterwards. Today opens the older one, the other stays visible in the notebook. No merge is attempted.
- **Creating.** `NoteStore.dailyNote(for:createIfMissing:)` creates the notebook if needed (setting `dailyNotesNotebookID`) and the note. Once templates exist (§11), linking applies the daily template inside `dailyNote(for:createIfMissing:)` itself, so every caller (`DailyLogAppender`, the API, the calendar) creates the same note, with `{{title}}` = the formatted date and `date` = that day at 09:00 local time (so `{{date}}` in a note for last Tuesday is last Tuesday). `NoteStore.openDailyNote(for:)` (linking) calls it, selects the notebook and the note, and puts the caret at `{{cursor}}` or at the end.
- **Appending.** `DailyLogAppender` is the only code that appends to a daily note. Its entry point is `@discardableResult static func append(_ content: DailyLogContent, timestamp: Bool = true, to date: Date, in store: NoteStore, now: Date = Date()) throws -> NoteMeta`, as frozen in the foundations plan (Task 4.6), where `DailyLogContent` is `.plain(String)` or `.attributed(NSAttributedString)`. With `timestamp`, each line is formatted by `NoteItCore.DailyLogLine` as `- HH:mm text`, 24-hour, `en_US_POSIX`, whatever the Mac's clock setting. The appender never parses Markdown: callers that accept Markdown (such as `automation`'s `POST /v1/daily/append` with `format: markdown`) parse it with the existing importer into `.attributed` before calling. It writes through `NoteStore.editBody`. Capture-plus's Append to Today, `automation`'s `POST /v1/daily/append`, `noteit today`, `noteit append --today`, `noteit://append?daily=today&text=` and the "Append to Daily Note" Shortcuts action all call it. There is no fallback provider: until linking turns on `DailyNotes.isAvailable`, Append to Today is unavailable and the API returns `501 not_implemented`.
- **Day boundaries** follow the Mac's calendar and time zone at the moment of the action. The Today row's day number refreshes at midnight via `NSCalendarDayChanged`.
- **Calendar.** `DailyCalendarView` is a custom month grid (not `DatePicker`, which can't mark days) shown in a popover: month name with ‹ › buttons, weekday initials in locale order, dots on days with a note, today circled. Keyboard: arrows move the day, ↩ opens or creates, Esc closes.
- **Sidebar.** The Today row is `SidebarSelection.today` (in `NoteItCore` from wave 0), placed after All Notes as program §9 orders the sidebar. It's hidden when `showTodayInSidebar` is off.
- **For other sub-projects.** `NoteStore.dailyNote(for:createIfMissing:)` is the public way to find or make a day's note, and `DailyLogAppender` the only way to add to one.

### 11. Templates

- **Where they live.** The Templates notebook is found by `templatesNotebookID` and, if that's unset or gone (for example on a second Mac, since preferences don't sync), by a notebook named "Templates" (case-insensitive). It's created on first use. Templates are normal notes: they sync, have history, can be exported and deleted.
- **Expansion.** `TemplateExpander.expand(_:context:)` works on the attributed body:
  - It finds `{{name}}` and `{{name:pattern}}` with `\{\{(title|date|time|clipboard|cursor)(?::([^}\n]{1,64}))?\}\}` (names are case-insensitive).
  - Each match is replaced by its value with the attributes at the first `{`, in one pass from the end so ranges stay valid.
  - `date` and `time` patterns go through `DateFormatter.dateFormat` with the user's locale; `time` without a pattern uses `DateFormatter.timeStyle = .short`.
  - `clipboard` is read once per expansion, only if the template uses it, as plain text, trimmed of trailing newlines and cut at 10,000 characters. Nothing is kept.
  - `cursor`: the first occurrence's location is returned as the caret, all occurrences are removed.
  - Links, attachments, tables and block sentinels in the template are copied unchanged, then `NoteItTextView.normalize(_:around:)` runs over the inserted range.
- **Applying.** New note from a template: the expanded body is the initial body passed to `createNote(in:initial:)`, so title, tags, search and link index are derived from the expanded text. The template itself is never changed. Insert Template: the expanded body (without its title paragraph, if the template has one and the caret isn't on an empty first line) is inserted at the caret through `NoteItTextView.replace(_:with:select:actionName:)` as one undo step named "Insert Template".
- **Default template per notebook.** `Notebook` (in `NoteItCore`, where every new model field goes) gains `defaultTemplateID: UUID?` (optional, decoded as nil from existing files and older devices). It syncs with the notebook record and is written into the revision fields only when it isn't nil, so existing revisions don't change; current writers keep it through `RawMetaOverlay` (program §4 rule 5), and linking adds `defaultTemplateID` to `Notebook.ownedCodingKeys`. A NoteIt version released before this field that edits the notebook drops it, which is an acceptable loss of a convenience setting. A template that no longer exists is treated as *None*.
- **Exclusions.** `NoteStore.isTemplate(_:)` (notebook check) is used by link suggestions, backlinks, unlinked mentions and daily notes. Templates still appear in All Notes, search and the palette.

### 12. Export and import

- **Markdown export** (`MarkdownWriter`): a note link run becomes `[[Name]]`, `[[Name|shown text]]` when the text differs from Name, and `[[Name#Heading]]` with a heading. Name is the target's exported file name without extension when it's part of the same export (notebook or Export All), otherwise its current title with `[]|#^` removed. Unresolved links use their title. Links to missing notes become plain text. This happens before the existing `ExportLinks.isSafe` filter, which keeps dropping other `noteit:` URLs.
- **HTML export**: a link to a note in the same export becomes `<a href="Name.html">` (with `#heading-slug` for headings; headings get `id` attributes, slug = lowercased, non-alphanumerics to `-`). Otherwise the text is wrapped in `<span class="note-link">`. **Plain text, PDF and print** keep only the text. **RTFD** keeps the `noteit:` URL.
- **Copy as Markdown** uses the current titles.
- The names come from `ExportLinkContext`, built by `NoteExporter` for each export with `title(for:)` and `exportedName(for:)`. The default context (single notes, Copy as Markdown) uses titles only.
- **Import** (`MarkdownReader`, `MarkdownImporter`): `[[Note]]`, `[[Note|alias]]`, `[[Note#Heading]]`, `[[folder/Note]]` and non-image `![[Note]]` become note links instead of plain text.
  - Before importing a folder or vault, the importer gives every file a new UUID and builds a map from folded file name (without extension and folders) to UUID.
  - A link resolves to a note in the same import first, then to an existing note with that exact title, else becomes an unresolved title link that resolves later.
  - Notes are created with their assigned IDs through `createImportedNote(…, id:)`, so links between imported notes work immediately in one pass.
  - Callers that pass no resolver (single-file import, Bear TextBundles) keep today's plain text, unchanged.
- **Markdown storage** (`markdown-storage`) owns the on-disk wiki-link syntax in a Markdown library (`[[file name|text]]`, program §12). Linking provides the resolution rules it follows, so a link written and read back points at the same note UUID while that note exists:
  1. A `noteit://note/<UUID>` link is written with the target's current file name (without extension and folders), adding `|text` when the shown text differs and `#Heading` for a heading link.
  2. Reading resolves the name to a note in the same library by file name first (folded), then by exact title (folded), preferring the source note's notebook, then the most recently edited note.
  3. A name that matches no note becomes `noteit://note?title=<name>` and resolves later like any unresolved link (§2, §3).
  4. A link to a missing note is written as plain text; a link to a note in Recently Deleted keeps its name and resolves when the note is restored.
  5. Unresolved links keep their title on disk.

  The same rules drive the importer above, through `WikiLinkResolver`. The link index needs nothing extra because it reads bodies through the `DerivedIndex` registry.

### 13. Settings and commands

| Where | Setting | Key | Default |
|---|---|---|---|
| Settings › Editor › Links | When a note is renamed: Ask / Always update links / Never update links | `linkRenameUpdates` | `ask` |
| Settings › Editor › Links | New notes from links go to: Same notebook as the linking note / Notebook for new notes | `linkNewNoteNotebook` | `source` |
| Settings › Editor › Daily Notes | Notebook | `dailyNotesNotebookID` | Daily Notes, created on first use |
| Settings › Editor › Daily Notes | Title: 2026-10-19 / 19 October 2026 / Monday, 19 October 2026 | `dailyNoteTitleFormat` | `iso` |
| Settings › Editor › Daily Notes | Template | `dailyNoteTemplateID` | None |
| Settings › Editor › Daily Notes | Show Today in the sidebar | `showTodayInSidebar` | on |
| Settings › Editor › Templates | Templates notebook | `templatesNotebookID` | Templates, created on first use |
| Settings › Shortcuts › Global | Open Today's Note | `HotkeyAction.openToday` (case 7 in the frozen order, program §9) | unbound |
| (not shown) | Panel shown / tab / Unlinked Mentions expanded | `inspectorVisible`, `inspectorTab`, `unlinkedMentionsExpanded` | off / `links` / off |

Menu items (all also in the command palette, which reads `MenuShortcuts`):

| Menu | Item | Shortcut | Changeable |
|---|---|---|---|
| File | New Note from Template… | ⌥⌘N | yes (`newNoteFromTemplate`) |
| File | Open Today's Note | ⌃⌘T | yes (`openToday`) |
| File | Daily Note for Date… | none | yes (`dailyNoteForDate`) |
| Format | Insert Template… | — | — |
| Format | Link to Note… | ⇧⌘K | yes (`linkToNote`) |
| View | Show / Hide Links and Outline | ⌥⌘I | yes (`toggleInspector`) |
| View | Go Back / Go Forward | ⌃⌘← / ⌃⌘→ | yes (`goBack`, `goForward`) |
| Note list context menu | Copy Note Link | ⌃⌘L (`automation`'s `copyNoteLink`) | in Settings › Shortcuts, owned by `automation` |

Open Today's Note uses ⌃⌘T, as program §9 sets, and can be changed in Settings › Shortcuts. ⌘T stays with the system font panel.

Menu placement follows program §9: File holds New Note from Template… (after New Note), Open Today's Note and Daily Note for Date… (after Open Quickly); Format holds Insert Template… and Link to Note…; View holds the panel and Back / Forward. Every changeable item above is a row in foundations' `PlannedMenuShortcuts` (Task 6.1); the task that adds its `MenuShortcutCommand` case deletes the row and updates `MenuShortcutRules` and `docs/keyboard-shortcuts.md`.

Palette-only commands: **Today's Note** (keywords daily, journal), **New Template**, **Show Backlinks** (opens the panel on Links), **Show Outline** (opens it on Outline). Linking adds no copy-link command of its own: the palette's **Copy Note Link** is `automation`'s.

### 14. Performance targets (10,000 notes, 50,000 links, Apple M1, release build)

| Operation | Target |
|---|---|
| Suggestion list update per keystroke | ≤ 8 ms on the main actor |
| Link extraction on commit, 10,000-word note | ≤ 2 ms |
| Load `link-index.json` (about 8 MB) | ≤ 150 ms, off the main actor |
| Backlinks for a note with 500 sources | ≤ 16 ms (one frame) |
| Unlinked mentions scan | ≤ 200 ms, background, cancellable |
| Rename update of 100 source notes | ≤ 1 s, UI stays responsive |
| Outline for a 5,000-paragraph note | ≤ 5 ms |
| Today's note lookup | O(1) after a ≤ 5 ms index build |
| Extra memory for the index | ≤ 15 MB |
| First-time rebuild | same pass as the search index rebuild, no second read of each body |

Linking defines these metrics. The benchmarks themselves live in the suite owned by `surfaces-polish` and run against the shared `NOTEIT_BENCH_FIXTURE` library (program §12). `LinkingPerformanceTests` keeps a quick check with synthetic data in `swift test`.

### 15. Accessibility

- Note links are read by VoiceOver as links with the target title. The suggestion list announces the selected row and the count ("Project Atlas, 1 of 6").
- The panel's sections are headings; each backlink line is a button labelled "Open <note>, <context>". The calendar grid exposes each day as a button with its full date and "has note".

## Dependencies

- **Foundations (wave 0, docs/plans/2026-10-19-foundations.md).** Built before linking starts:
  - `NoteItCore` with `SidebarSelection.today`, `SidebarLibraryRow`, the daily note title functions, `DailyLogLine` and the `DailyNotes.isAvailable` gate (§10).
  - `NoteLink` and `URLCommand`'s `.note`/`.noteTitle` (Task 5.3), in the format §1 defines.
  - `NoteStore+Daily` (`dailyNote(for:createIfMissing:)`, `dailyNotesNotebookID(createIfMissing:)`) and `DailyLogAppender` (§10, Task 4.6).
  - `NoteStore.editBody` and `OpenEditorRegistry` (program §6, Task 4.5), used for every change linking makes to a note other than through typing.
  - The `DerivedIndex` registry (program §7, Task 4.4), which the link index registers with.
  - `NoteMeta.isLocked` as data (program §8), so the link index can leave locked notes out from the start.
  - The Swift `DocValidation` and TypeScript validators already accept `noteit:` links with golden vectors (program §2 step 2).
  - The frozen tables (program §9): `HotkeyAction.openToday` at position 7 in `HotkeyOrder`, the menu shortcuts in `PlannedMenuShortcuts`, the sidebar order and the inspector.
- **`automation` (01).**
  - Owns all `noteit://` routing. The handlers of `URLCommand`'s `.note(id:heading:)` and `.noteTitle(title:heading:)` call `NoteStore.followLink(_:from:)`. These URLs must open forever, since they're stored inside notes.
  - Owns **Copy Note Link** (Edit menu, ⌃⌘L, `copyNoteLink`), which copies `noteit://note/<UUID>`. Linking's note list context menu calls it.
  - Owns the Local API daily shape: `GET /v1/daily?date=&create=&format=` and `POST /v1/daily/append`, both backed by the foundations daily code. Linking adds no daily routes.
  - Provides `LocalAPIRouteRegistry`. Linking registers its own routes with it, each with a `linking.<name>` route id, an explicit scope and errors from `APIErrorCode` only:

    | Route id | Method and path | Scope | Calls |
    |---|---|---|---|
    | `linking.backlinks` | `GET /v1/notes/{id}/backlinks` | read | `NoteStore.backlinks(to:)` |
    | `linking.links` | `GET /v1/notes/{id}/links` | read | `NoteStore.outgoingLinks(from:)` |
    | `linking.outline` | `GET /v1/notes/{id}/outline` | read | `OutlineExtractor` |
    | `linking.templates` | `GET /v1/templates` | read | `NoteStore.templates` |
    | `linking.createFromTemplate` | `POST /v1/templates/{id}/notes` with `{title?, notebookID?}` | write | `NoteStore.createNote(fromTemplate:title:in:)` |

    A locked note returns `423 note_locked` for the body-derived routes (backlinks context, links, outline). Notes are created from templates only through `POST /v1/templates/{id}/notes`; `automation`'s create-note route has no `templateID`.
  - Provides the App Intents scaffolding. Linking's **Open Today's Note** intent is built on it and depends on `automation`'s App Intents spike: if App Intents can't be built from SwiftPM, Shortcuts users open `noteit://daily` instead. The `noteit today` CLI command is `automation`'s and calls the daily routes.
- **`markdown-storage` (02).** Owns the wiki-link syntax on disk in Markdown libraries and the only lossless Markdown path (`NoteItMarkdown`). Linking provides the resolution rules in §12; markdown-storage keeps note UUIDs in front matter so links resolve to the same UUID after a round trip and after external renames, and reuses `NoteLink` and `WikiLinkResolver` for reading. `link-index.json` stays in `NoteStore.rootURL`, never in the content folder.
- **`organise` (04).** Owns the shapes of `NoteStore.editBody` and the `DerivedIndex` registry, which foundations builds (Tasks 4.4 and 4.5). Reuses linking's `InlineCompletionController` for tags and the query language with its own sources. Templates and daily notes are ordinary notebooks, so nested notebooks need nothing special. Tags written in templates (`#meeting`) are counted like any tag; organise may choose to hide the Templates notebook from tag counts.
- **`capture-plus` (05).** Its Append to Today panel calls `DailyLogAppender`. It owns the `appendToToday` hotkey.
- **`sync-security` (08).** Owns locked notes. The link index leaves them out and drops their entries when a note is locked (§6); no extra call from 08 is needed beyond the `DerivedIndex` notifications.
- **`sharing` (09).** Publishing a notebook reuses `ExportLinkContext` so links between published notes work.
- **`plugins` (10).** Plugin panels are extra tabs in linking's inspector.
- **`surfaces-polish` (12).** Runs the link benchmarks from §14 in its suite with `NOTEIT_BENCH_FIXTURE`. The board view can show linking's inspector next to a card's note. The canvas view may read `LinkIndex` to draw connections.
- **`mobile` (11).** Renders `noteit://note/<UUID>` links from `noteit-doc` as note links, using `NoteLink` from `NoteItCore`.
- **`web-app` (existing spec).** Gets `noteit:` href support from foundations; the web editor should open such links as internal links.

## Non-goals

- Embedding (transcluding) another note's content.
- A graph view of all links.
- Hover previews of linked notes (could come with `surfaces-polish`).
- Links to blocks or paragraphs (`[[Note#^block]]`).
- Aliases stored on the target note (front matter `aliases:`).
- Automatic merging of duplicate daily notes, weekly or monthly notes, a configurable day start time.
- Template logic (conditionals, loops, scripts) or variables beyond the five listed and their patterns. Plugins (`plugins`, 10) can add transforms.
- Updating heading links when a heading is renamed.
- Converting `[[ ]]` text that's pasted or already in old notes. Only typing and importing create links.

## Open questions

1. **Markdown export link style.** Wiki links (`[[Name]]`) or standard links (`[text](Name.md)`)? Default: wiki links, which Obsidian, Bear and Logseq read and which round-trip through NoteIt's importer. An export option can be added later.
2. **Should the suggestion list create notes immediately?** Default: yes for **Create "…"**, because the user chose it; typed `[[Title]]` stays unresolved until clicked, so stray brackets never create notes.
3. **Default template field on `Notebook` vs a per-Mac preference.** Default: on `Notebook`, so it syncs; the older-version drop is accepted.
4. **Template naming.** Default: title line with variables removed. Alternative: a separate name field, rejected because it needs metadata that RTFD can't hold.
5. **Unlinked mentions for short titles and dates.** Default: skip titles under 3 characters and date-only titles.
6. **Should templates be hidden from All Notes?** Default: no, they stay visible like any note; only linking features skip them.
