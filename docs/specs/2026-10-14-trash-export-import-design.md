# Recently Deleted, Version History, Export and Import — Design

## Goal

Close the gaps that keep people from moving their notes into NoteIt, or trusting it once they have:

1. **Recently Deleted and version history**, so no edit or deletion is ever final by accident.
2. **Export, print and Share**, so notes are never locked in.
3. **Import** from Apple Notes, Bear, Obsidian and plain Markdown, so switching takes a minute.

## Non-goals

- Syncing version history between Macs. History stays on the Mac where it was recorded.
- Links between notes and nested notebooks. They're on the [roadmap](../roadmap.md).
- Two-way sync with other apps. Import is a one-time copy.

## 1. Recently Deleted

### Behavior

- **Delete** (⌘⌫, context menu, menu bar) moves a note to *Recently Deleted* instead of removing it. A toast reads "Moved to Recently Deleted" with an **Undo** button; ⌘Z also undoes it.
- *Recently Deleted* is a smart view at the bottom of the sidebar. It shows a count and only appears when it isn't empty.
- Notes in *Recently Deleted* don't appear anywhere else: not in notebooks, smart views, tags, search, the menu bar panel or the Recent list.
- Opening a deleted note shows it read-only, under a banner: "Deleted 3 days ago. It will be removed in 27 days." The banner has **Recover** and **Delete Now** buttons.
- Recovering puts the note back in its notebook, or in Inbox if that notebook no longer exists. Without an Inbox the note has no notebook and shows under All Notes.
- Notes are removed for good 30 days after deletion. This is checked at launch and once a day. **Empty Recently Deleted…** asks for confirmation and removes them all now.
- Deleting a notebook moves its notes to Recently Deleted. The notes keep the notebook ID, so recovery falls back to Inbox.

### Data

- `NoteMeta` gains `deletedAt: Date?`. It decodes as `nil` when missing.
- Moving a note to or from Recently Deleted is a normal metadata change. It bumps the revision and syncs like any edit, with no new wire format. Removing a note for good uses the existing permanent-delete path: tombstones, `sync-deletions.json`, and the body moved to `.trash/`.
- Compatibility: NoteIt 0.1.0 ignores `deletedAt`, so on a Mac still running 0.1.0 a deleted note shows up as a normal note. If that Mac edits the note, it comes back from Recently Deleted. This is acceptable because 0.1.0 updates itself, and it's documented in Known limitations.
- Conflicts follow the existing rules. An edit on one Mac and a deletion on another produce a conflict copy, so nothing is lost.

## 2. Version history

### Behavior

- **File › Version History…** (⌥⌘Y) and the note's context menu open a sheet. A list of versions ("Today 14:02", "Yesterday 09:15", …) is on the left and a read-only preview on the right. **Restore This Version** replaces the note's body; the current body is saved as a version first, so restoring can also be undone.
- Versions are recorded automatically and need no setup.

### Rules

- Before a body write replaces the saved body, NoteIt keeps the old body as a version if the newest version of that note is more than 10 minutes old, or if none exists.
- A version is also kept before restoring a version. Before sync replaces the body with a remote change, the same 10-minute rule applies, unless the body holds local edits not kept as a version yet; then it's always kept.
- Each note keeps up to 50 versions, and none older than 30 days. A permanently removed note loses its versions too.

### Data

- Versions are stored at `history/<note UUID>/<yyyyMMdd'T'HHmmss'Z'>.rtfd` in the library folder and are written atomically. They aren't synced, aren't indexed for search, and aren't in `library.json`.

## 3. Export, print and Share

### Formats

| Format | Output |
|---|---|
| Markdown | `.md`. Images go in an `<note title> assets/` folder next to it, with relative links. If that name is taken, the folder is `<note title> assets 2/` and so on; an existing folder is never replaced. |
| HTML | One self-contained `.html` file with images embedded as data URLs. Colors and highlights are kept. |
| PDF | Uses the same layout as printing. |
| Rich Text (RTFD) | The note's own body, unchanged. |
| Plain Text | `.txt`. |

### Markdown mapping

| NoteIt | Markdown |
|---|---|
| Title / heading / subheading | `#` / `##` / `###` |
| Bold, italic, strikethrough, inline code | `**`, `*`, `~~`, `` ` `` |
| Link | `[text](url)` for http, https, mailto, tel, ftp and relative links. Other links (such as `javascript:`) become plain text, in HTML too. |
| Bulleted, numbered, checklist (with nesting) | `- `, `1. `, `- [ ] ` / `- [x] `, indented to line up with the parent item's text |
| Quote | `> ` |
| Code block | fenced ```` ``` ```` |
| Divider | `---` |
| Table | GFM pipe table. The first row becomes the header row. |
| Image | `![](<note title> assets/image-1.png)` |
| Underline, colors, highlights, alignment | Dropped. Markdown has no equivalent. |

### Commands

- **File › Export Note As…** (⇧⌘S) opens a save panel with a format picker.
- **File › Export Notebook…** and **File › Export All Notes…** ask for a format and a folder. They write one folder per notebook and one file per note. File names are the note title with characters unsafe for file names removed; duplicates get " 2", " 3" and so on. Notes in Recently Deleted are not exported.
- **File › Print…** (⌘P) prints the note with its title and standard margins.
- **Share**: a toolbar button and a **File › Share** submenu use the system share picker. They share the note as Markdown text, with the title as the subject.
- **Edit › Copy as Markdown** (⌥⇧⌘C) copies the note, or the selection, as Markdown.

## 4. Import

**File › Import…** opens a sheet with three sources. Each import runs in the background with a progress bar and a Cancel button. It ends with a summary such as "Imported 132 notes into 6 notebooks. Skipped 3 locked notes."

### Markdown and Obsidian (a folder or individual files)

- `.md`, `.markdown` and `.txt` files are imported. Hidden folders, `.obsidian` and `.trash` are skipped.
- Notebooks: files in the chosen folder go into a notebook named after that folder. Each subfolder becomes a notebook named `Folder / Subfolder`, because notebooks can't be nested yet. A notebook that already exists with the same name is reused.
- The title is the YAML front matter `title:`, or the first `#` heading, or the file name.
- `tags:` in front matter are added as a final line of `#hashtags`, so NoteIt's tag detection picks them up. Other front matter is dropped.
- Obsidian `[[Note]]` and `[[Note|alias]]` become plain text, until links between notes exist. Images referenced as `![](path)` or `![[image.png]]` are embedded when the file exists.
- Dates come from the front matter `created`/`updated` fields, or else from the file's creation and modification dates.

### Bear

- Bear's export to TextBundle (`.textbundle` folders or `.textpack` zips) or Markdown is imported like Markdown, including the assets in the bundles. Bear's `#tag/subtag` tags are kept as typed.

### Apple Notes

- NoteIt reads notes directly from the Notes app through Apple Events. macOS asks once for permission to control Notes.
- Each Notes folder becomes a notebook with the same name. Folders are flattened with ` / ` and account names are omitted.
- Bodies come in as HTML and are converted to NoteIt styles: headings by font size, lists, bold, italic, underline, strikethrough, links, and images when they're embedded.
- Notes keep their creation and modification dates.
- Locked notes and other attachments (PDFs, drawings, scans) are skipped and counted in the summary. Apple Notes checklists arrive as bulleted lists.
- Packaging: the app gets the `com.apple.security.automation.apple-events` entitlement and an `NSAppleEventsUsageDescription`, which `build_app.sh` adds when signing with hardened runtime.

### Rules

- Importing never changes or removes existing notes. Importing the same thing twice creates duplicates. Users are warned in the sheet and can delete the duplicates.
- Notes are created through the store's normal paths, so search, tags and sync see them like any new note.

## Architecture

| Unit | Responsibility |
|---|---|
| `NoteStore` + `NoteStore+Trash.swift` | `deletedAt`, move to / recover from Recently Deleted, delete now, empty, auto-purge, filtering every view |
| `VersionHistory` (`Model/VersionHistory.swift`) | Records, lists, loads, restores and prunes versions on disk. Called by `NoteStore` before body writes. |
| `MarkdownWriter` (`Export/`) | NoteIt attributed string → Markdown plus a list of image assets. Pure, so it can be unit-tested. |
| `HTMLWriter`, `NoteExporter` (`Export/`) | HTML output, file naming, folder layout, PDF and printing, Share and Copy as Markdown |
| `MarkdownReader` (`Import/`) | Markdown, including front matter, wikilinks, task lists and tables → NoteIt attributed string, using the same block styles as the editor (`EditorStyles`, `TextFormatter`) |
| `MarkdownImporter`, `AppleNotesImporter`, `ImportSheet` (`Import/`) | Reading sources, mapping notebooks, progress, summary |

## Testing

- Unit tests (XCTest, temporary libraries) for:
  - moving to Recently Deleted, recovering, deleting now, emptying, purging after 30 days;
  - views and search excluding deleted notes;
  - the `deletedAt` round trip through `library.json` and sync records;
  - version capture timing, retention, and restoring;
  - Markdown writing for every block in the mapping table;
  - Markdown reading of front matter, wikilinks, task lists, tables and images;
  - a round trip: write a note as Markdown, read it back, and compare the block structure;
  - notebook naming and file naming with duplicates;
  - converting Apple Notes HTML, using a fixture string with no live Notes access.
- A manual check of the built app: delete and recover a note, restore a version, export each format, print preview, Share, import an Obsidian-style folder, and import from Apple Notes.
