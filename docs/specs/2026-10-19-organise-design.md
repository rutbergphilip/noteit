# Organise — Design

Status: proposed · Date: 2026-10-19 · Companion plan: docs/plans/2026-10-19-organise.md · Program contract: docs/specs/2026-10-19-program-design.md (wins where they differ)

## Goal

Make a growing library easy to keep in order and easy to get back out of, without adding anything you have to maintain by hand:

- tags you can see, nest, rename and merge;
- notebooks inside notebooks;
- smart folders, which are saved searches written in a small query language;
- search that puts the best match first and shows where it matched;
- one list of every checkbox in every note, with due dates;
- reminders written in plain words ("call the supplier tomorrow 9am") that turn into notifications.

Everything stays local, works with sync through storage the user owns, and keeps working next to older NoteIt versions on another Mac.

### Guiding decision: the note text is the source of truth

Tags, due dates and reminders all live in the note's text as plain tokens: `#work/acme`, `@due(2026-10-21)`, `@remind(2026-10-20 09:00)`. Indexes are derived from the text and can always be rebuilt. This choice:

- survives older NoteIt versions, which keep the text even when they don't understand it;
- works the same in the RTFD library, the Markdown library from `markdown-storage`, `noteit-doc` bodies from the web app and in any export;
- needs no new note metadata, so `NoteMeta` and the note record on the wire don't change.

Only two new things are stored outside note text: the notebook `parent` (on the notebook record) and smart folders (a new record kind). Both are additive.

## What the user gets

### Tags

- `#tag` in a note shows as a rounded chip in the editor. Nested tags use a slash: `#work/acme/invoices`.
- Typing `#` opens a small completion list of existing tags, best match first, with note counts. Tab or Return accepts, Esc closes, typing anything else keeps going.
- ⌘-click a tag chip to show that tag's notes.
- Note list rows show up to three tag chips under the preview, then `+N`.
- The sidebar's **Tags** section is a tree. `#work/acme` shows **acme** inside **work**. Selecting **work** shows notes tagged `#work` or any tag under it. A parent that only exists through its children (no note says `#work` by itself) still appears.
- Right-click a tag in the sidebar:
  - **Rename Tag…** changes the tag in every note, including its nested tags (`#work` → `#job` turns `#work/acme` into `#job/acme`). If the new name already exists, the sheet says **“#job” already exists. Merge 12 notes into it?** and the button reads **Merge**.
  - **Delete Tag…** removes `#tag` (and its nested tags) from every note's text, after **Remove “#draft” from 8 notes? The words stay, only the tag goes.** The `#` and tag name are removed; surrounding text stays.
  - **New Smart Folder from Tag** creates a smart folder with `tag:work`.
- Before a rename, merge or delete changes anything, each affected note gets a Version History entry. Afterwards a toast says **Renamed #work in 12 notes** with **Undo** for 10 seconds.

### Notebooks inside notebooks

- Drag a notebook onto another notebook to put it inside. Drag it onto the **Notebooks** header to move it back to the top level. Drag between rows to reorder among siblings.
- Right-click a notebook: **New Notebook Inside…**, **Move To ▸** (a menu of valid places, with **Top Level** first), plus the existing items.
- The notebook sheet gets an **Inside** picker (**None** by default).
- Notebooks nest up to 4 levels. Drops that would go deeper, or into the notebook's own children, aren't accepted.
- Selecting a notebook shows its notes and the notes of every notebook inside it. The count badge counts them all. New notes go into the selected notebook itself.
- Each notebook row has a disclosure triangle when it has children. Which ones are open is remembered on this Mac.
- Every notebook picker (Move to, Quick Capture, Settings › Editor › New Notes, the note header) shows the tree with indentation. The palette shows a notebook's path as its subtitle, such as **Work › Clients**.
- **Delete Notebook…** on a notebook with children says **Delete “Work” and the 3 notebooks inside it? Their 42 notes will be moved to Recently Deleted.**
- Export writes sub-notebooks as sub-folders. Importing a Markdown folder turns sub-folders into sub-notebooks (up to 4 levels; deeper folders keep today's `Folder / Subfolder` names).

### Smart folders and the query language

- A **Smart Folders** section sits after the library rows (All Notes, Today, Tasks, Pinned, Recent, Conflicts) and before **Notebooks** and the tag tree. It appears once there is at least one smart folder. **Recently Deleted** moves into its own section at the bottom of the sidebar (program §9); this sub-project makes that move.
- **File › New Smart Folder…** opens a sheet with **Name**, **Symbol** and **Search** fields and a live count, such as **14 notes match**. Problems in the search show under the field (for example **“edited:<7x” isn't a date. Try edited:<7d.**) and disable **Create**.
- Starter searches in the sheet: **Open tasks** (`is:todo`), **Due this week** (`due:<7d`), **Edited today** (`edited:today`), **Untagged** (`is:untagged`).
- While searching, the note list header shows **Save as Smart Folder…**, which opens the sheet with the current search filled in.
- Right-click a smart folder: **Edit Smart Folder…**, **Duplicate**, **Delete Smart Folder…** (the notes aren't touched).
- Renaming a notebook or a tag updates smart folder searches that mention it.

The same language works in the toolbar search field, the smart folder sheet, the Tasks view filter and the Local API.

| Write | Finds notes… |
|---|---|
| `apple pie` | containing both words (any order, ignoring case, accents and width, as today) |
| `"apple pie"` | containing the exact phrase |
| `-draft` | not containing the word |
| `title:budget` | with the word in the title |
| `tag:work` | tagged `#work` or any tag under it, such as `#work/acme` |
| `notebook:"Client Work"` or `in:"Client Work"` | in that notebook or any notebook inside it. `notebook:"Work/Clients"` names a path |
| `is:pinned`, `is:todo`, `is:done`, `is:untagged`, `is:conflict` | pinned; with an unchecked checkbox; with checkboxes, all checked; without tags; conflict copies |
| `has:due`, `has:reminder`, `has:attachment` | with a task that has a due date; with a reminder that hasn't fired or been done; with an image or file |
| `edited:<7d`, `edited:>30d` | edited within the last 7 days; edited more than 30 days ago. Units: `h`, `d`, `w`, `m`, `y` |
| `edited:2026-10-01`, `edited:>2026-10-01`, `edited:<2026-10-01` | edited on, after, or before that day |
| `edited:today`, `yesterday`, `this-week`, `last-week`, `this-month` | edited in that period |
| `created:…` | the same forms, for the creation date |
| `due:today`, `due:overdue`, `due:<7d`, `due:2026-10-21` | with an open task due today, overdue, in the next 7 days, or on that day |
| `A OR B`, `(A OR B) C` | either; grouping. `OR` must be upper case |

Rules:

- Terms are combined with AND. `-` negates any term, including `-tag:x` and `-"a phrase"`. `OR` binds tighter than the implicit AND, so `a b OR c` means `a (b OR c)`. Order of binding: `-`, then `OR`, then AND.
- Unknown keys (`foo:bar`) are plain words, so searching for a time like `10:30` still works.
- In the search field an invalid value counts as a plain word and the field shows a small warning icon with the problem as its tooltip. In the smart folder sheet it blocks saving.
- A search runs inside the current sidebar selection, as today. A smart folder always searches the whole library, never Recently Deleted.

### Ranked search with highlights

- While a search has words or phrases, the note list is sorted by **Best Match**. A sort menu in the list header switches between **Best Match** and **Date Edited**. The choice is remembered.
- Title matches rank above body-only matches. Several words close together, matches at the start of words and recently edited notes rank higher. Searches with only filters (such as `tag:work`) keep the usual order: pinned first, then last edited.
- Matched words are highlighted in the title. The preview line becomes a snippet around the best match, such as **…call the supplier about the **budget** before Friday…**, with matches highlighted.
- Opening a note from a search highlights every match in the editor and scrolls to the first match after the title. The highlights go away when the search is cleared, on the first edit, or on Esc. ⌥⌘F opens the find bar with the first search word filled in.
- When a note matches only through text found in one of its images, its row shows **Found in an image** instead of a snippet. The image text comes from the `ImageTextProviding` provider that `capture-plus` registers; until one is registered, this row never appears.
- Locked notes match by title only and show an empty preview.
- The command palette ranks body-only note matches by the same score.

### Tasks view

- **Tasks** is a new library row after **Today** and before **Pinned** (symbol `checklist`). Its badge shows the number of open tasks that are overdue or due today, and nothing when there are none.
- The middle column lists every checkbox from every note except locked notes, grouped as **Overdue**, **Today**, **Upcoming** (next 7 days), **Later**, **No Date**. **Show Completed** in the header adds a **Completed** group, newest notes first.
- Each row shows the checkbox, the task text with tag chips and a due chip (red when overdue), and underneath, the note's title and notebook.
- Click the checkbox to complete or reopen the task. The note changes the same way it would in the editor. Completed rows stay in place for 1.5 s before moving, so a mis-click is easy to undo; ⌘Z also undoes it.
- Selecting a row opens its note in the editor column, scrolled to that line, which flashes once. Double-click or ↩ opens the note in **All Notes**. Space toggles the selected task.
- Right-click a task: **Set Due Date…**, **Remove Due Date**, **Add Reminder…**, **Open Note**, **Copy Task**.
- The search field filters the tasks with the query language. Words match the task's own text; `tag:` matches tags in the task line or in the note; `notebook:`, `edited:` and `is:pinned` apply to the note.
- If a task changed since the list was built (it was edited on another Mac, for example), completing it shows **This task changed. Open the note to edit it.**

### Due dates

- Write `@due(2026-10-21)` or `@due(2026-10-21 14:00)` after a task. While typing, `@due(fri)`, `@due(tomorrow)`, `@due(+3d)`, `@due(next tuesday)` or `@due(21 oct)` become a full date as soon as you type `)`.
- **Format › Task › Set Due Date…** (⇧⌘D) opens a date picker for the task under the cursor, and writes or updates the token.
- The token shows as a chip: the date in the accent color, red when overdue. Clicking it opens the same date picker with **Remove**.
- Due dates are plain dates on the wall clock: `@due(2026-10-21)` is the 21st wherever you are.

### Reminders in plain words

- Write a line such as `call the supplier tomorrow 9am` and press **Format › Task › Add Reminder…** (⌃⌘R). NoteIt reads the date in the line and adds `@remind(2026-10-20 09:00)` at its end. A small popover says **Reminder set for tomorrow at 09:00** with **Change…**. If the line has no date, the popover opens with a date picker instead.
- A date without a time uses the default reminder time, 09:00 (Settings › General › Reminders).
- Typing `@remind(tomorrow 9am)` and `)` works too, like `@due`.
- In Quick Capture, when the first line has a date, a clock button appears: **Remind tomorrow at 09:00**. Turning it on adds the token when the note is saved. It's off by default for each capture.
- At the time, a notification shows the line (without tokens) as its title and the note title as its subtitle. Its actions:
  - **Done** checks the checkbox when the line is a task; otherwise it marks the reminder done: `@remind(2026-10-20 09:00 done)`.
  - **Snooze 10 Minutes**, **Snooze 1 Hour**, **Tomorrow** move the reminder.
  - Clicking the notification opens the note at that line.
- The token chip shows a bell and the time. Clicking it opens a popover with the date picker, **Done** and **Remove**.
- The first reminder asks for notification permission. If it's denied, the Tasks view and Settings show **Notifications are off for NoteIt.** with **Open System Settings…**.
- Reminders only fire while NoteIt is running. The first time a reminder is added and **Open at Login** is off, the popover offers **Open at Login**. Reminders missed while NoteIt wasn't running are shown once at the next launch, if they're less than 24 hours old.
- With sync on and two Macs, a reminder is shown on one Mac only (see Design › Reminders). If both Macs ring at once anyway (for example while offline), handling it on one Mac clears it from the other after the next sync.
- **Show reminders on this Mac** (Settings › General › Reminders, on by default) turns delivery off for one Mac, for example a desktop you rarely sit at.
- Reminders in a locked note don't ring. The lock sheet (from `sync-security`) says so.

### Menus, palette and shortcuts

These follow the program's frozen menu table.

| Menu item | Shortcut | Notes |
|---|---|---|
| View › Tasks | ⇧⌘T | selects the Tasks row |
| File › New Smart Folder… | none | |
| Format › Task › Set Due Date… | ⇧⌘D | |
| Format › Task › Add Reminder… | ⌃⌘R | |
| Edit › Save Search as Smart Folder… | none | enabled while searching |

- All five are `MenuShortcutCommand` cases, so they can be changed in Settings › Shortcuts, and appear in the command palette. The task that adds each case also deletes its row from foundations' `PlannedMenuShortcuts` and updates `MenuShortcutRules` and `docs/keyboard-shortcuts.md`.
- Palette-only commands: **Rename Tag…**, **Delete Tag…**, **Move Notebook To…**, **Show Completed Tasks**.
- The palette also lists smart folders (kind label **Smart Folder**) and tags (`#work/acme`, kind label **Tag**). Choosing one selects it in the sidebar.
- New global hotkey: **Show Tasks** (`HotkeyAction.showTasks`, eighth in the frozen hotkey order, right after `openToday`), unbound by default. It shows the main window with Tasks selected.

### Settings

- **General › Reminders:** **Show reminders on this Mac** (on), **Default time** (09:00), and the permission state with **Open System Settings…** when notifications are off. Foundations (step 6, Task 6.5) makes General one scrolling form with a frozen section order; this sub-project fills the `reminders` section and sets `GeneralSettingsSection.reminders.isAvailable` to true.
- No other new settings. The search sort order, Show Completed and open notebooks are remembered as view state.

## Design

### 1. Shared foundation

#### 1.1 Where the code lives

There is no `NoteItOrganise` target. Parsing, matching, ranking and date logic (the token grammar, the query language parser and evaluator, the ranker and highlighter, the natural date parser, the tag tree, the notebook tree and the task parser) go into `NoteItCore`, the Foundation-only library shared by the Mac app and the phone. They have no AppKit or app types and are tested in `Tests/NoteItCoreTests/`. `ImportHygieneTests` keeps AppKit out.

- Text folding and `FuzzyMatcher` are moved into `NoteItCore` by foundations step 1 (docs/plans/2026-10-19-foundations.md). This sub-project uses them as they land there: `TextFold.fold`, the search index, the query evaluator, highlights and the palette all fold text the same way.
- The models this sub-project changes (`Notebook` and `SidebarSelection`) live in `NoteItCore` too. This sub-project creates `SmartFolder` there in wave 1 (wave 0 doesn't), and the `ImageTextProviding` protocol with no provider (see 5.1). `SidebarSelection` has `.today`, `.tasks`, `.tag(path)` and `.smartFolder(UUID)` from wave 0; this sub-project gives `.tasks`, `.tag` nesting and `.smartFolder` their behaviour.
- The web app spec keeps its own TypeScript port. The rules below are written so they can be checked with shared test vectors (see Dependencies).

#### 1.2 Search index v2

`search-index.json` today holds the folded text of each note. Version 2 holds what search, tasks and reminders all need, so nothing has to open RTFD files to answer a query. It is the single search index format: `markdown-storage` uses it as is, and other derived data (links, image text, the semantic index, Spotlight) lives in each owner's own index, registered through the `DerivedIndex` registry rather than added to this file.

```json
{ "version": 2, "entries": { "<uuid>": {
  "text": "<folded plain text>",
  "plain": "<plain text as written>",
  "tasks": [ { "paragraph": 4, "text": "Send invoice #work/acme @due(2026-10-21)", "checked": false,
               "due": "2026-10-21", "remind": null } ],
  "reminders": [ { "paragraph": 7, "text": "call the supplier", "at": "2026-10-20 09:00", "done": false,
                   "isTask": false, "checked": false } ],
  "hasAttachment": true,
  "updatedAt": "2026-10-19T08:00:00Z" } } }
```

- The file lives in `NoteStore.rootURL` (the data folder), never in a Markdown library's content folder.
- Entries are built by organise's own indexer, registered through the `DerivedIndex` registry (program §7). The store calls it on the main actor: `noteChanged(_:body:)` on body changes and note creation, from local saves and applied remote notes (never for locked notes), `noteRemoved` when a note is removed or locked, and only `metadataChanged` for metadata-only changes: pin, move, tag, move to Recently Deleted and restore from Recently Deleted (entries stay; those filters are applied at query time), `rebuild(notes:body:)` for the background rebuild and imports, and `flush()` to write the file. Nothing in this sub-project adds a hook to `NoteStore.swift`. Task and reminder lines are read from the same masked text as tags: inline code, code blocks and links are blanked first (`NoteStore.parseTags(_: NSAttributedString)` does this today and is factored into `NoteStore.maskedForTokens`).
- **Locked notes** (from `sync-security`) get no entry. Locking a note calls `noteRemoved`, so its text, tasks and reminders leave the index; search then matches its title only, from `NoteMeta`.
- A version 1 file still loads: its `text` is used for search right away and the rest is rebuilt in the background. An older NoteIt reading a version 2 file ignores the new fields.
- The index stays rebuildable and is never synced. Size grows by roughly the plain text again (about 20 MB for 10,000 notes of 2 KB).

#### 1.3 Editing a note body from outside the editor

Moved to foundations (docs/plans/2026-10-19-foundations.md, Tasks 4.4 and 4.5), following program §6. Tag rename, completing tasks from the Tasks view, setting a due date from a context menu and notification actions all change note text without the user typing. They all go through `NoteStore.editBody`, which foundations builds from this design:

- If the note is open in an editor (main window or floating note; `OpenEditorRegistry` knows the text view per note), the edit runs inside that text view as one undo step and is saved like typing. Cheat sheets are read-only observers: they register with `registerObserver(_:for:)`, are never returned by `textView(for:)` and are never edited by `editBody`. They only reload when the note changes.
- Otherwise the store hands over pending edits, applies the edit to a copy of the body, saves it as a new revision (sync and derived indexes follow) and tells any editor to reload, as `restoreVersion` does today.
- Notes in Recently Deleted, locked notes and notes with a blocked body write are never edited.
- Every edit keeps the attributes at the start of the text it replaces, like Find and Replace.

The signatures of `editBody(_:actionName:versioning:extras:_:)` (with `versioning: EditBodyVersioning = .recordCurrent` and `extras: ContainerExtras? = nil`, which only `NoteStore` itself passes), `EditBodyVersioning`, `BodyEditError`, `OpenEditorRegistry` and the `DerivedIndex` protocol are frozen in the foundations plan (Frozen interfaces, Tasks 4.4 and 4.5) and in program §6 and §7. This spec doesn't repeat them.

#### 1.4 Tokens in text

| Token | Grammar | Meaning |
|---|---|---|
| tag | `#` + segment (`/` segment){0,4}; segment = `[\p{L}_][\p{L}\p{M}\p{N}_\-]*` | lowercased, NFC; same left-boundary rule as today |
| due | `@due(YYYY-MM-DD)` or `@due(YYYY-MM-DD HH:MM)` | due date on the wall clock |
| reminder | `@remind(YYYY-MM-DD HH:MM)` or `@remind(YYYY-MM-DD HH:MM done)` | reminder time on the wall clock; `done` once handled |

- Tokens inside inline code, code blocks and links are ignored, like tags today.
- The editor styles tokens at display time: text color through layout-manager temporary attributes, and the chip background drawn by `NoteItTextView` next to the inline code pills (`drawInlineCodePills`). Nothing about the styling is saved, so the RTFD and every export keep plain text.
- Token text is never hidden. Hiding characters breaks cursor movement and copy, and the raw text is what other apps and older versions see anyway.
- `@due(...)` and `@remind(...)` with any other content are left alone and not styled, except right after typing `)`, when NoteIt tries the natural-date parser (see 6.2) and rewrites the token if it succeeds. Undo restores what was typed.

### 2. Tags v2

#### 2.1 Behaviour

- **Detection stays in text.** `NoteMeta.tags` keeps being derived from the body on every save and on every sync receive. There is no tag metadata to keep in step.
- The tag pattern gains `/` between segments. `#work/acme` derives the single tag `work/acme`. A trailing slash isn't part of the tag (`#work/` is `work`). More than five segments: the tag ends after the fifth.
- **Hierarchy is implied.** `TagTree` builds the sidebar tree from all tags; parents that only exist through children are added with the count of notes under them.
- **Selection** `.tag("work")` matches `work` and every tag starting with `work/`. `tag:` in queries works the same way.
- **Chips.** Editor chips are drawn with an accent tint and a 4 pt corner radius, in the same pass as inline code pills. Note list chips are a small SwiftUI `TagChip` view.
- **Completion.** Typing `#` at a tag boundary opens linking's shared `InlineCompletionController` under the caret, the same controller that serves `[[` completion. This sub-project adds a `#` source to it and doesn't build its own. Candidates are all tags ranked with `FuzzyMatcher` over the text typed after `#`, then by note count. At most 8 rows. Choosing `work/acme` inserts the rest of the name.

#### 2.2 Rename, merge and delete

`TagRewriter` (pure) computes the replacements for one note's masked text:

- **Rename** `from` → `to` replaces every occurrence of `#from` and `#from/…` with `#to` and `#to/…`, matching case-insensitively and writing `to` as the user typed it in the sheet (lowercased tags still derive the same).
- **Merge** is a rename into an existing name. Notes that end up with the same tag twice keep both occurrences in their text; the derived tags are de-duplicated as today.
- **Delete** removes each `#tag` occurrence and one adjacent space, so `buy #draft milk` becomes `buy milk`.
- The new name is checked against the grammar. Invalid names (empty, starting with a digit, too deep, with spaces) show **Tags can use letters, numbers, - and _, and / to nest.**
- Renaming `a` into `a/b` (its own child) is refused: **A tag can't be moved inside itself.**

`NoteStore.renameTag(_:to:)` (which also merges) and `deleteTag(_:)` follow the program's rule for changes that touch more than one note: every note's current body is in Version History before it changes, then Undo is offered.

- Run over notes not in Recently Deleted and not locked that carry the tag. Deleted notes keep their old tags; restoring one brings the old tag back, which the toast explains: **Notes in Recently Deleted weren't changed.** Locked notes aren't indexed, so their tags can't be found or changed.
- Edit through `editBody` with its default `versioning: .recordCurrent`, which records each note's current body in Version History exactly once before the change (ignoring the 10-minute rule). The tag code never records a version itself. Edits run in batches of 50 notes per main-loop turn. Above 200 notes a progress sheet with **Cancel** appears; notes already changed stay changed.
- Update smart folder queries that mention the tag (`tag:from` → `tag:to`) using the parser's token ranges, so quoting and other terms are kept.
- Return a `TagEditResult` (changed note IDs, skipped IDs and why) used by the toast and by **Undo**. Undo puts back each changed note's recorded version through `editBody`, so an open editor updates and keeps its own undo, when the note's revision hasn't changed since; notes edited in the meantime are left alone and the toast says how many.

#### 2.3 Sync and older versions

- Nothing new is synced; changed notes sync as edits.
- NoteIt 0.2 reads `#work/acme` as the tag `work`. That's acceptable: the note still shows up under `work`.
- Renaming tags on one Mac while another Mac edits the same notes can produce conflict copies, as any concurrent edit does.

### 3. Nested notebooks

#### 3.1 Data model

```swift
// NoteItCore
public struct Notebook: Identifiable, Codable, Hashable, Sendable {
    ...existing fields...
    public var parent: UUID? = nil                  // nil = top level; the Local API calls it parentID
}
```

- `parent` is encoded explicitly, as `null` for a top-level notebook, so a record can say "top level" (`"parent": null`) as opposed to not saying anything (no `parent` key). NoteIt 0.2 and earlier never write `parent`.
- From this version on, every notebook JSON written by NoteIt has a `parent` key (new notebooks get `"parent": null`; existing ones get it the next time they're edited). Whether the key was present is read from the raw record that `RawMetaOverlay` keeps. Notebooks loaded without one are top level. `Notebook.ownedCodingKeys` gains `parent`, so `RawMetaOverlay` treats it as a key this build owns. Writing the key doesn't change the revision; only a set parent does (next point).
- `sortIndex` orders siblings. Reindexing only renumbers the siblings of the changed parent.
- `revisionFields(_ nb: Notebook)` appends `"parent <uuid>"` only when a parent is set (`parent` isn't nil), so revisions of top-level notebooks, and every revision derived before this change, stay the same (program §4 rule 5).
- `library.json` keeps `version: 1`; the field is additive.

#### 3.2 The tree

`NotebookTree` (pure, in `NoteItCore`) is built from `(id, parentID, sortIndex, name)` tuples:

- **Missing parent** (deleted, or not synced yet): the notebook shows at the top level. Nothing is rewritten, so it moves back under its parent once the parent arrives.
- **Cycles** (two Macs move A under B and B under A at the same time): the notebook in the cycle with the smallest UUID string is treated as top level. Display only; nothing is rewritten until the user moves something.
- **Depth** over 4 (possible only through concurrent moves): shown as is. Moves that would create it are refused.
- `canMove(_:under:)` refuses moving a notebook into itself or its descendants, and moves where the notebook's depth plus its subtree height would exceed 4.

#### 3.3 Store

- `createNotebook(name:symbol:colorHex:parentID:)` (the existing signature keeps working with `parentID: nil`).
- `moveNotebook(_:under:at:)` sets the parent, places the notebook at the given sibling index (end when nil) and renumbers siblings. Each changed notebook gets a new revision.
- `moveNotebooks(from:to:)` keeps working for reordering inside one parent; it gets a `parent` argument.
- `deleteNotebook(_:)` deletes the notebook and its descendants: all their notes go to Recently Deleted, each notebook gets a sync deletion. Recovering a note falls back to Inbox as today.
- `notes(for: .notebook(id))` and `count(for:)` include descendants.
- `removeNotebookForRemote(_:)` (a parent deleted on another Mac) moves the parent's own notes to "no notebook" as today. Its child notebooks are left as they are and show at the top level (missing parent) until a deletion of them arrives too.

#### 3.4 Sync with other writers and older versions

The notebook record's JSON is the encoded `Notebook`.

- **Current writers keep `parent`.** Every current writer (this Mac app, the web app, the phone) keeps the last decrypted notebook JSON and patches only the keys it owns, through `RawMetaOverlay` in `NoteItSync` (the web app has the same thing in TypeScript). A writer that doesn't know `parent` yet still writes it back unchanged. This is the main protection and needs nothing extra from this sub-project.
- **NoteIt 0.2 and earlier** predate `RawMetaOverlay`. They decode the record, ignore `parent`, and re-encode without it when they change the notebook (rename, color, reorder: reordering touches every notebook). For these, a belt-and-braces repair stays:
  - **Receiving a notebook without `parent`** means an older version wrote it. `applyRemoteNotebook` then keeps the local parent and takes everything else from the remote record.
  - If the local parent isn't top level, the store **repairs** the record right after: the notebook gets a new revision and `modifiedAt`, and the next pass pushes it with `parent` again. Two new Macs repairing at once is an ordinary notebook conflict with identical content; older Macs ignore the repaired field and don't push back unless the user edits the notebook. This converges.
  - A fresh Mac that syncs between the older Mac's write and the repair sees the notebook at the top level briefly.
- Older versions show nested notebooks as a flat list and their notes as usual. They can't nest or un-nest. The release notes say so.
- Notebook conflicts stay last-writer-wins (`SyncEngine`), now including `parent`.
- Changing the store key re-seals notebook records with `RekeyRunner` like every other object; nothing here is specific to it.

#### 3.5 Sidebar drag and drop

- Notebook rows are `.draggable("notebook:<UUID>")`. Note rows keep dragging the bare UUID string, so drops can tell them apart.
- Dropping a notebook on a notebook row nests it as the last child; on the **Notebooks** section header it moves to the top level. Reordering among siblings uses `onMove` on each sibling `ForEach`.
- While dragging, rows that can't accept the drop don't highlight.
- Expanded notebooks are stored per Mac in `UserDefaults` under `expandedNotebookIDs` (array of UUID strings). Dropping onto a collapsed notebook expands it after 0.7 s of hovering.

#### 3.6 Export and import

- `NoteExporter.prepareAll` writes each notebook's folder inside its parent's folder. Exporting one notebook includes its sub-notebooks as sub-folders.
- `MarkdownImporter` creates sub-notebooks for sub-folders, using `notebookForImport(named:parentID:)`, up to depth 4. Deeper folders are flattened into the depth-4 notebook's name as `Folder / Subfolder`, as today.
- In a Markdown library, nested notebooks are nested folders, up to 4 deep, with the notebook record (including `parent`) in `.noteit-notebook.json`. That mapping is owned by `markdown-storage`; this sub-project only defines the field and the tree rules.

### 4. Smart folders

#### 4.1 Model and storage

```swift
// NoteItCore, created by this sub-project in wave 1 (wave 0 doesn't create it)
public struct SmartFolder: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var query: String
    public var symbol: String          // SF Symbol, default "folder.badge.gearshape"
    public var sortIndex: Int
    public var revision: UUID? = nil
    public var modifiedAt: Date? = nil
}
```

- Stored in `smart-folders.json` in `NoteStore.rootURL` (the data folder): `{ "version": 1, "smartFolders": [...], "appliedRemoteRevisions": {...} }`. `appliedRemoteRevisions` is local only (never synced) and records, per folder, the remote revision last applied; it is the `smartFolders` kind's map in foundations' raw-meta lifecycle (program §4.5), whose raw copies live in `sync-meta-raw/smart-folders/`. It's a separate file, not a key in `library.json`, so opening the library with an older NoteIt (which rewrites `library.json` without unknown keys) doesn't lose them.
- Written atomically with the library's save debounce. An unreadable file is copied to `smart-folders.corrupt-<ts>.json` and the list starts empty; it fills again from sync if sync is on.
- Markdown libraries keep the file in the same place, never in the library's content folder.
- `SidebarSelection.smartFolder(UUID)` exists in `NoteItCore` from wave 0; `notes(for:)` evaluates the query over active notes.
- Limits: name 1–60 characters, query 1–500 characters, at most 200 smart folders.

#### 4.2 Sync

- New `RecordKind.smartFolder`, stored at `noteit/v1/smart-folders/<id>.json` (sealed like other records). The prefix stays `noteit/v1/`; the object is additive.
- `noteit/v1/smart-folders/` and `noteit/v1/claims/reminders/` (see 7.3) are rows in `RemoteLayout.prefixes` (`RemotePrefix.path` is the full key prefix), each with `depth: 1` and `sealing: .storeKey`, with key vectors in `fixtures/golden/layout-keys.json` for the web server (`noteit/v1/smart-folders/<UUID>.json`, `noteit/v1/claims/reminders/<UUID>.json`). Both fit the web server's key rule (segments of `[A-Za-z0-9._-]`, at most 4 deep).
- Smart folders behave like notebooks in the engine: no body, last-writer-wins on conflict (`RecordKind.usesLastWriterWins`), deletions as tombstones in `noteit/v1/tombstones/`.
- Smart folder records keep unknown keys through `RawMetaOverlay`, like notebooks, using foundations' per-kind raw-meta lifecycle as kind `smartFolders` (`sync-meta-raw/smart-folders/<UUID>.json`): the raw copy is written before the record is applied, merged on export only when its source revision equals the folder's applied revision, deleted only after the save that removes the folder has succeeded, and still merged after a relaunch.
- `RekeyRunner` re-seals smart folder records and their tombstones with everything else under the store root.
- **Older versions.** NoteIt 0.2's `RemoteIndex` skips folders it doesn't know, so it never lists `smart-folders/`. It reads a tombstone's contents only for IDs it holds locally or sees a meta for, which never happens for a smart folder ID, so a tombstone with the unknown kind `smartFolder` is never decoded there. The tombstone sweep only deletes tombstones it has read. A manual check against the 0.2.0 release build is part of the plan.
- **Web app and phone.** Their engines ignore smart folder records and smart folder tombstones without error until they support them (program §4 rule 9).

#### 4.3 Query language

`SearchQuery.parse(_:)` (pure) produces a tree:

- **Tokens:** words, `"phrases"` (an unclosed quote runs to the end), `key:value` with `value` either a bare word or a quoted string, `-` prefix, `(`, `)`, `OR`.
- **Grammar:** `query = orExpr*` (implicit AND); `orExpr = unary ("OR" unary)*`; `unary = "-"? atom`; `atom = term | "(" query ")"`. Unbalanced parentheses are closed at the end and reported.
- **Keys:** `tag`, `notebook`/`in`, `title`, `is`, `has`, `edited`, `created`, `due`. Anything else is a plain word, the colon included.
- **Dates** use `Calendar.current` and the Mac's time zone at evaluation time. `<Nd`/`>Nd` are relative to now for `edited`/`created`; for `due`, `<7d` means from today to 7 days ahead and `>7d` later than that. `this-week` follows the locale's first weekday.
- **Issues** carry a range and a message. They're shown in the sheet; in the search field, issue terms fall back to plain words.
- `highlightTerms` lists the positive words, phrases and `title:` values, for highlighting.
- `QueryRewriter` renames `tag:` and `notebook:` values in place (used by tag and notebook renames). A notebook rename rewrites values that equal the old name or start with it as a path segment.

`QueryEvaluator` matches a `SearchDocument`, which the store builds from `NoteMeta`, the index entry, the image text from the registered `ImageTextProviding` provider (empty when none) and the notebook tree. Words and phrases use folded substring matching against the folded text, exactly like today's search, so no existing search stops matching. A word or phrase that matches only the image text still counts as a match; its source is reported as `image` so the list can say **Found in an image**.

### 5. Ranked search

#### 5.1 Score

For each positive word or phrase `t`, over the notes that passed the filter (`N` of them):

- `tf` counts occurrences in the folded text; an occurrence at the start of a word counts 1.0, one inside a word 0.5.
- `df` is the number of the `N` notes containing `t`; `idf = ln(1 + (N − df + 0.5) / (df + 0.5))`.
- Body: BM25 with `k1 = 1.2`, `b = 0.75`, document length = folded text length in characters, average over the `N` notes.
- Title: `+ 2.0 × idf` when `t` occurs in the title, `+ 1.0 × idf` more when the title starts with it.
- Tag: `+ 1.0 × idf` when a tag equals `t`.
- Whole query: `+ 3.0` when the folded title equals the folded query text.
- Proximity: `+ 0.5 × idf_avg` when all words occur within one 80-character window.
- Recency: the sum is multiplied by `1 + 0.3 × e^(−age_days / 30)`.
- Ties: pinned first, then last edited.
- Image text is scored like body text at half weight. It comes through `ImageTextProviding` (`func imageText(for noteID: UUID) -> String?`), which this sub-project defines in `NoteItCore` in wave 1 with no provider; `capture-plus` registers its provider in wave 2 with `NoteStore.registerImageTextProvider(_:)`. **Found in an image** shows only when a provider is registered. When a note matches only there, its row shows **Found in an image** instead of a snippet, and there are no editor highlights.
- Locked notes have no index entry, so only the title and tag terms score for them; their preview stays empty.

Queries with only filters keep the existing order. Notes in Recently Deleted keep the existing deletion-date order.

#### 5.2 Speed

- Folded texts are kept as UTF-8 byte arrays and counted with `memmem`; there's no inverted index. Substring counting keeps today's matching (including scripts without spaces) and keeps the index rebuild trivial.
- Budget: 30 ms per keystroke for 5,000 notes of 2 KB on an M1, measured in a test. Results are cached by (selection, query, notes version, index version), since SwiftUI asks for the list several times per update.
- If a measured query goes over 30 ms, the list updates from a debounced (120 ms) background evaluation instead of synchronously; the cache keeps the previous results meanwhile.

#### 5.3 Highlights

- `SearchHighlighter.ranges(of:in:)` folds the original text one character at a time (like `FuzzyMatcher`) so ranges point into the original string.
- `snippet(of:terms:maxLength:)` picks the 140-character window with the most distinct terms, prefers starting at a sentence or line start, adds `…` on cut sides, and returns highlight ranges inside it.
- In the editor, highlights are temporary attributes (`Tokens.Color.searchHighlight`, a soft yellow in light mode and amber at 35 % in dark mode), managed by `SearchHighlightController`, which reuses `FindReplaceEngine` to find ranges. They don't change the text and disappear on edit.

### 6. Tasks and due dates

#### 6.1 Task lines

- A task is a paragraph whose text starts with `☐\t` or `☑\t` (`EditorStyle.listMarker(in:)`), outside code and links, in a note that isn't locked. Indent level isn't shown; the Tasks view is flat. The two glyphs are defined once, as `ChecklistMarkers.unchecked`/`.checked` in `NoteItCore` (created by foundations); `EditorStyle.uncheckedBox`/`checkedBox` and `TaskParser` both use them.
- `TaskParser.lines(inMasked:)` returns `TaskLine`s and `ReminderLine`s with paragraph indexes, the line text without its marker, and parsed tokens. The first `@due` and the first `@remind` on a line count; more are ignored and not styled.
- **Identity:** a `TaskRef` is (note ID, paragraph index, SHA-256 of the line text). Before changing a task, the store checks the paragraph at that index still has that text; if not, it looks for the first paragraph with the same text; if none, the action fails with the message above.
- **Completing** replaces the marker character and applies or removes the checked style (`NoteItTextView.applyCheckedStyle`/`removeCheckedStyle`), through `editBody`. In an open editor this is the same `toggleCheckbox(atParagraphStart:)` the mouse uses.
- **No completion date** is recorded. Recurring tasks are out of scope.

#### 6.2 Dates in plain words

`NaturalDateParser.parse(_:now:calendar:defaultHour:)` returns a wall-clock `LocalDateTime` and the matched range:

1. Exact forms: `2026-10-21`, `2026-10-21 14:00`, `14:00` (today, or tomorrow if past).
2. Short forms: `today`, `tonight` (20:00), `tomorrow`, `mon`…`sun` and full names (the next one, never today), `next <weekday>`, `+3d`, `+2w`, `in 3 days`, `in 2 hours`.
3. Otherwise `NSDataDetector` with `.date`, which also covers other languages the system supports and forms like `21 oct at 9am`.

- Dates without a time get `defaultHour` (9) for reminders and stay date-only for due dates.
- Results in the past are rejected for reminders (**Add Reminder…** then opens the picker).
- Short forms are English only; other languages rely on `NSDataDetector`.

### 7. Reminders

#### 7.1 Storage

- Reminders live in the note text as `@remind(...)`. They sync with the note, survive older versions as plain text, and are edited by Done and Snooze like any other edit.
- Floating time: `09:00` means 09:00 wherever the Mac is.
- **Reminder ID:** a UUID (version 8) from SHA-256 of `"reminder"`, the note ID, the token time and the line text without tokens. Every Mac computes the same ID; editing the line or moving the time makes a new reminder.
- A reminder is **live** when its note isn't in Recently Deleted or locked, the token isn't `done`, and the line isn't a checked task. Locking a note removes its reminders from the index, so they stop ringing and any delivered notification for them is withdrawn.

#### 7.2 Scheduling on one Mac

- `ReminderScheduler` keeps the sorted list of live reminders from the index and one timer for the next one. It re-arms when the organise indexer reports a change, on wake (`NSWorkspace.didWakeNotification`), on time zone and clock changes (`NSSystemClockDidChange`, `NSSystemTimeZoneDidChange`) and at launch.
- Delivery goes through `UNUserNotificationCenter` with an immediate request whose identifier is the reminder ID, category `noteit.reminder` with the actions above. NoteIt doesn't use system calendar triggers, because the cross-Mac check (7.3) must run at delivery time.
- `remindersLastCheck` (`UserDefaults`, a date) marks the end of the last checked window. At launch and on wake, live reminders due in `(remindersLastCheck, now]` and less than 24 h old are delivered; then the value moves to now. Older ones only show as overdue in the Tasks view.
- `UNUserNotificationCenter` needs a bundled app. Under `swift run`, in tests, or without a bundle identifier the scheduler runs but delivery is a no-op logged in debug builds, the same way `AppUpdater` stays off.
- A notification's actions call `NoteStore.updateReminder(_:action:)`, which rewrites the token through `editBody`, then asks sync for a pass right away.

#### 7.3 Two Macs, one notification

With sync on, a Mac claims a reminder before showing it:

- **Claim:** a conditional create (`If-None-Match`) of `noteit/v1/claims/reminders/<reminderID>.json`, sealed like other objects, holding `{ id, deviceID, deliveredAt }`. Success means show it; "already exists" means another Mac did, so don't.
- **Who goes first:** a Mac where the user was active in the last 2 minutes (`CGEventSource.secondsSinceLastEventType`) claims at the reminder time. Other Macs wait 20 seconds, then try. So the Mac you're using rings, and an idle Mac only rings if nothing else did.
- **Failures:** without sync, offline, or on any storage error, the Mac shows the reminder. A duplicate is better than a missed reminder. Stores where conditional writes are best effort (some S3 providers, see the sync spec) can rarely show both.
- **Cleanup:** when a reminder is handled on one Mac, the token changes and syncs; the other Mac removes its delivered notification with that ID (`removeDeliveredNotifications`) on the next index change. Claims older than 7 days are deleted by the Mac that wrote them, once a day.
- Claims sit in a folder that no version's record sync reads, so they don't affect older versions or the web app. The `claims/reminders/` prefix is registered in the `RemoteLayout` registry (see 4.2), and `RekeyRunner` re-seals claims with everything else. A claim the sweep can't open (for example during a key change) is left alone.

#### 7.4 Privacy

- No new network calls. Claims go to the user's own sync store and are encrypted when sync encryption is on; they hold only a hash-derived ID, a device ID and a time.
- Notification text is the task line. Whether it shows on the lock screen follows the user's macOS notification preview setting for NoteIt.

### 8. Local API

`automation` owns the Local API. This sub-project registers its own routes through `LocalAPIRouteRegistry.shared.register` at launch, with route ids `organise.<name>`, an explicit scope, and errors from `APIErrorCode` only, in the nested error body. Handlers call the `NoteStore` methods listed in the plan's frozen interfaces, the same ones the UI uses.

| Route id | Route | Scope | Result |
|---|---|---|---|
| `organise.tagRename` | `POST /v1/tags/rename` `{from, to}` | write | `{changed, skipped}`; renames into an existing tag merge |
| `organise.tagDelete` | `POST /v1/tags/delete` `{tag}` | write | `{changed, skipped}` |
| `organise.notebookMove` | `POST /v1/notebooks/{id}/move` `{parentID, index?}` | write | the moved `Notebook` |
| `organise.smartFolderList` | `GET /v1/smart-folders` | read | `{smartFolders: [SmartFolder]}` in sidebar order |
| `organise.smartFolderCreate` | `POST /v1/smart-folders` `{name, query, symbol?}` | write | `201` + `SmartFolder` |
| `organise.smartFolderGet` | `GET /v1/smart-folders/{id}?limit=` | read | `{smartFolder, notes: [NoteSummary]}` |
| `organise.smartFolderUpdate` | `PATCH /v1/smart-folders/{id}` | write | `SmartFolder` |
| `organise.smartFolderDelete` | `DELETE /v1/smart-folders/{id}` | write | `204`; notes aren't touched |
| `organise.taskList` | `GET /v1/tasks?q=&includeCompleted=` | read | `{groups: [{group, tasks: [Task]}]}` |
| `organise.taskComplete` | `POST /v1/tasks/complete` `{noteID, paragraph, textHash, checked}` | write | the updated `Task` |
| `organise.taskDue` | `POST /v1/tasks/due` `{noteID, paragraph, textHash, due}` | write | the updated `Task`; `due: null` removes it |

- **Errors:** an invalid tag name, query or move gives `400 bad_request` with the same message the app shows; an unknown tag, notebook or smart folder gives `404 not_found`; a task that changed gives `412 revision_mismatch`; a task in a locked note gives `423 note_locked`; a library still loading gives `503 not_ready`.
- **Changes to automation's built-in shapes** (organise owns the fields; the wire fields come from foundations Task 5.1, and organise fills them through automation's seams):
  - Notebooks gain `parentID` (null at the top level) and `path` (names from the top, such as `["Work", "Clients"]`), filled through `NotebookDTOExtending`.
  - `GET /v1/tags?tree=1` returns the tag tree, `[{name, path, noteCount, totalCount, children}]`, supplied through `LocalAPIRouteRegistry.extendTags(treeProvider:)`. Plain `GET /v1/tags` stays a flat `[Tag]` list.
  - `GET /v1/search` accepts the query language in `q` and returns results ranked by this design. Each result gains an optional `score` and optional `highlights: [{field, ranges}]` (program §10): `field` is `"title"` or `"body"`, and `ranges` is a list of `[start, length]` pairs in UTF-16 offsets. A result that matched only image text has `matchedIn: "image"`. Locked notes appear with `locked: true` and an empty snippet, matched by title only.
- `noteit://search?q=` accepts the query language too.

### 9. Error handling summary

| Situation | Behaviour |
|---|---|
| `smart-folders.json` unreadable | copied to `smart-folders.corrupt-<ts>.json`, list starts empty, sync refills it |
| `search-index.json` v1 or unreadable | search uses what loads; the rest rebuilds in the background |
| Tag rename hits a note with a blocked body write | that note is skipped and listed in the toast's **Show Skipped** |
| Task changed under the Tasks view | **This task changed. Open the note to edit it.** |
| Reminder action for a note that's gone | notification is removed, nothing else happens |
| Notification permission denied | reminders stay in the text; banner in Tasks view and Settings |
| Notebook move refused | the drop isn't accepted; **Move To** greys out invalid targets |
| Task or reminder action on a note locked since | nothing changes; the Local API returns `423 note_locked`; the notification is withdrawn |

## Dependencies

- **Program contract** (docs/specs/2026-10-19-program-design.md) wins over this spec.
- **Foundations** (docs/plans/2026-10-19-foundations.md), wave 0:
  - Step 1 moves `Notebook`, `NoteMeta`, `SidebarSelection` (with `.today`, `.tasks`, `.tag(path)`, `.smartFolder(UUID)`), text folding and `FuzzyMatcher` into `NoteItCore`. This sub-project's pure logic goes there too.
  - Step 3 provides `RawMetaOverlay` and the `RemoteLayout` registry in `NoteItSync`.
  - Step 4 builds `NoteStore.editBody`, `OpenEditorRegistry` and the `DerivedIndex` registry (Tasks 4.4 and 4.5), with the shapes from 1.3 above.
  - Step 5 provides `LocalAPIRouteRegistry` and the wire fields `parentID`, `path`, `TagNodeDTO`, `score` and `highlights`.
  - Step 6 freezes the shortcut (`PlannedMenuShortcuts`), hotkey (`HotkeyOrder`, `showTasks` at position 8), menu and sidebar (`SidebarLibraryRow`) tables this spec follows, and Task 6.5 makes General a scrolling form with `GeneralSettingsSection`.
- **`automation` (Local API).** Owns the server and the built-in `/v1/tags`, `/v1/notebooks` and `/v1/search` handlers. This sub-project registers the routes in Design §8 itself, fills the tag tree and notebook fields through `LocalAPIRouteRegistry.extendTags(treeProvider:)` and `NotebookDTOExtending`, and fills `score`, `highlights` and `matchedIn` on search results. Spotlight indexes tags with their full path.
- **`linking`.** Creates the shared `InlineCompletionController`; this sub-project adds sources to it for `#` tags and the query language. `EditorNavigator.reveal` (jump to a line, used by the Tasks view and notifications) is built here. Daily notes are good homes for tasks but need nothing from here.
- **`markdown-storage`.** Tokens are plain text and round-trip unchanged. It owns nested notebooks as nested folders in Markdown libraries (`.noteit-notebook.json` keeps the whole record, `parent` included). It uses search index v2 as is. `search-index.json` and `smart-folders.json` stay in `NoteStore.rootURL`, never in the content folder. Checkboxes map to `- [ ]`/`- [x]`; the Tasks view reads them through the same index.
- **`web-app`.** Must adopt the v2 tag pattern in its derivation rules (§2.8 there) and the shared vectors, keep `parent` on notebooks through its `RawMetaOverlay`, and ignore smart folder records, smart folder tombstones and `claims/` without error until it supports them. Its server accepts the two new key prefixes (test vectors from this sub-project). `noteit-doc` bodies keep tokens in text nodes, so nothing changes in the schema.
- **`capture-plus`.** Registers an `ImageTextProviding` provider in wave 2 (backed by its own `DerivedIndex` indexer); this sub-project defines the protocol and the **Found in an image** match source. "Append to today" lines can carry `@remind`/`@due` tokens.
- **`private-ai`.** Suggested tags use `NoteStore.allTags`/`tagTree` and insert tags as text. "Ask your notes" can use `searchResults` as its keyword stage. This sub-project's `PaletteRanker` signature change (body matches carry a score) merges before private-ai's.
- **`mobile`.** Reuses the query language, tags, tasks and dates from `NoteItCore`. Its engine ignores smart folder records and tombstones without error. Native iOS reminders are specced there.
- **`sync-security`.** Owns locked notes. Locked notes are left out of search body text, tasks and reminders (Design 1.2, 6.1, 7.1); `RekeyRunner` re-seals smart folders and claims with everything else.
- **`plugins`.** May register query keys later; not part of v1.

## Non-goals

- Tag colors, tag icons, or tags stored as metadata.
- A note in more than one notebook.
- Recurring tasks or reminders, task priorities, completion dates, assigning tasks to people.
- Calendar or Apple Reminders integration.
- Location-based reminders.
- Hiding token syntax in the editor.
- Fuzzy (typo-tolerant) full-text search, stemming, or semantic search (`private-ai`).
- Sorting smart folders by anything other than their saved order; per-smart-folder sort settings.
- Changing the note record, the manifest, or `noteit/v1/` in any incompatible way.

## Open questions

1. **Should selecting a notebook include notes in its sub-notebooks?** Default: yes, like Finder's search scope and most outliners. A per-notebook toggle can come later.
2. **Reminders need NoteIt running.** Default: accepted, with the **Open at Login** prompt and catch-up at launch. System calendar triggers would fire while quit but can't do the cross-Mac claim.
3. **Floating time vs. time zone in tokens.** Default: floating wall-clock time. Travelling users get 09:00 local, which matches how people write "9am".
4. **Delete Tag edits text.** Default: yes, with confirmation, Version History entries and Undo. The alternative (hiding tags) would need tag metadata.
5. **Shared `tombstones/` folder for smart folders.** Default: shared, with the manual 0.2.0 cross-version check. If that check fails, smart folder tombstones move to `smart-folders/<id>.deleted.json`, which older versions never list.
6. **Maximum notebook depth.** Default: 4 levels. Deeper trees make the sidebar hard to read at the standard width.
7. **Best Match as the default sort while searching.** Default: yes; Date Edited is one click away and remembered.
8. **Who rings first on two Macs.** Default: the recently active Mac claims immediately, idle Macs after 20 s. No per-device priority setting beyond **Show reminders on this Mac**.
9. **Tasks view shows nesting.** Default: flat list, since sub-tasks are rare and grouping is by date.
10. **Typing `@due(fri)` rewrites to a date.** Default: yes, so the meaning never drifts; undo restores what was typed.
