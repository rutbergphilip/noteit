# Markdown Storage — Design

Status: proposed · Date: 2026-10-19 · Companion plan: docs/plans/2026-10-19-markdown-storage.md · Program contract: docs/specs/2026-10-19-program-design.md (wins where this spec disagrees)

## Goal

Let people keep their NoteIt library as a folder of plain Markdown files they can read, edit, grep and back up with any tool, without losing NoteIt's formatting and without giving up encrypted sync. Make it obvious where the data lives and that it can be restored: a "Your Data" settings tab, a one-click backup ZIP, automatic backups, and restore drills that prove a backup or the sync storage really contains every note. Make switching to NoteIt easy with importers for Evernote `.enex` files and Notion exports.

The Markdown library is an alternative **local** format. The remote sync format, the `noteit/v1/` prefix and the encryption don't change, so a Mac with a Markdown library and a Mac with the default RTFD library sync with each other through the same store.

## What the user gets

### Settings › Your Data

A new Settings tab, **Your Data** (raw value `data`, SF Symbol `externaldrive`), the fifth tab, right after Sync (program §9). `noteit://settings?tab=data` opens it. The tab constant is frozen in wave 0; this sub-project fills in the view. From top to bottom:

**Library**
- **Format:** "NoteIt library (rich text)" or "Markdown folder".
- **Location:** the path with `~` for the home folder, and a **Show in Finder** button.
- A summary line: "1,284 notes in 9 notebooks · 312 MB, of which 280 MB attachments".
- Button: **Switch to Markdown Folder…** or **Switch to NoteIt Library…** (see 3.6).
- For a Markdown folder, the line "NoteIt picks up changes made to these files in other apps." and, when files were skipped, "Skipped: 2 files over 10 MB" with **Show in Finder**.
- For a Markdown folder, the switch **Rename files when titles change**. On by default for a folder NoteIt created, off by default for an adopted folder (3.4).
- After a conversion: "Previous library from 19 Oct 2026 (210 MB)" with **Remove** (3.6).
- This is the only place where Markdown storage is chosen. Onboarding never offers it (program §12).

**Sync**
- "Last synced 2 minutes ago to “Studio NAS”", or "Sync is off." with a **Set Up Sync…** button that switches to the Sync tab.
- **Check Sync Storage…**: the remote restore drill (3.10).

**Backups**
- **Back Up Everything…**: saves a ZIP (3.8).
- **Automatic backups:** Off / Daily / Weekly (default Off). When on: **Folder:** with **Choose…**, and **Keep the last:** 5 / 10 / 30 backups (default 10).
- "Last backup: today at 09:12 · NoteIt Backup 2026-10-19 0912.zip" with **Show in Finder**, or "No backup yet."
- **Check a Backup…** and **Restore from Backup…** (3.9).

**Import**
- **Import Notes…**: opens the existing import sheet, which gains **Evernote** and **Notion** sources.

The footnote under the tab: "Your notes are stored only on this Mac and in the sync storage you set up. NoteIt never uploads them anywhere else."

### Menus and command palette

New commands, all without default shortcuts (they are menu items and palette commands, not `MenuShortcutCommand` cases):

| Command | Menu | Palette id | Available when |
|---|---|---|---|
| Back Up Everything… | File, after the Share submenu | `backUpEverything` | always |
| Show Note File in Finder | File, after Back Up Everything… | `revealNoteFile` | Markdown folder library and a note is selected |
| Show Your Data | palette only (opens Settings › Your Data) | `showYourData` | always |
| Check a Backup… | palette only | `checkBackup` | always |
| Check Sync Storage… | palette only | `checkSyncStorage` | sync is set up |

The File menu order is the one in program §9. Palette ids are camelCase like every other palette command. Keywords include "export", "zip", "restore", "verify", "markdown", "files".

### Working with the Markdown folder

- Every note is a `.md` file named after its title. Every notebook is a folder; a notebook inside another notebook is a folder inside that folder, up to 4 levels deep. Images and files live in `_attachments/`.
- Links between notes are written as `[[File name]]` or `[[File name|shown text]]`, which Obsidian and similar apps understand.
- Editing a note in another app (Obsidian, iA Writer, VS Code, `vim`) shows up in NoteIt within about a second. If that note is open and has no unsaved NoteIt edits, it reloads in place.
- Creating a `.md` file in the folder adds a note. Deleting one moves the note to Recently Deleted. Moving a file into another notebook folder moves the note to that notebook.
- If many files disappear at once (more than 20, or at least 10% of the files when that is at least 5), NoteIt doesn't delete anything. It shows "Many notes disappeared from the folder" and waits for you.
- A folder you already had keeps its file names. NoteIt renames files when titles change only if you turn that on.
- If the same note was changed in NoteIt and in another app at the same time, nothing is lost: NoteIt keeps its own version and adds the other one as a separate note titled "<title> (Outside NoteIt)", the same way sync conflicts work today.

### Importers

The import sheet (`ImportSheet`) lists, in this order: Markdown files, Bear, Apple Notes, **Evernote**, **Notion**.
- **Evernote:** "Choose one or more .enex files exported from Evernote. Each file becomes a notebook."
- **Notion:** "Choose the .zip from Notion's Export › Markdown & CSV. Pages keep their images and tables."

The existing `ImportReport` summary sheet is reused, so results read like today's imports ("Imported 412 notes. 3 encrypted notes were skipped."). Surfaces-polish may offer these two importers in onboarding; they are the same importers (program §12).

## Design

### 3.1 Formats and where things live

A library has one **format**. Two folders are involved:

- the **data folder**, `NoteStore.rootURL`: `~/Library/Application Support/NoteIt/` (or `NOTEIT_DATA_DIR`). Below it is written `<data>`.
- the **content folder** of a Markdown library, `contentRootURL`: any folder the user picks; the default suggestion is `~/Documents/NoteIt`. Below it is written `<content>`. An RTFD library has no separate content folder. The content folder may not overlap the data folder (3.6): a folder that is, is inside or contains `<data>`, the current body folder `<data>/notes/`, or a path the conversion manages in the data folder (`<data>/backups/` with its staging folders, `<data>/sync-meta-raw/`, `<data>/body-extras/`, `<data>/history/`) is refused.

| Format | Note bodies | Metadata |
|---|---|---|
| `rtfd` (default, today) | `<data>/notes/<uuid>.rtfd` | `<data>/library.json` |
| `markdown` | `<content>/<notebook path>/<title>.md`, attachments in `<content>/_attachments/` | front matter in each file, `.noteit-notebook.json` per folder; `<data>/library.json` is a cache |

**Every derived and per-Mac file lives in the data folder**, for both formats (program §7). Nothing derived is ever written into the content folder, so it stays clean and can be shared with other tools. This sub-project's files:

| File | Purpose |
|---|---|
| `library-location.json` | New. `{"version":1,"format":"markdown","path":"~/Documents/NoteIt","bookmark":"<base64>","libraryID":"<uuid>","renameFilesOnTitleChange":true}`. Missing file = `rtfd` in `<data>`, which is today's behaviour. |
| `library.json` | Unchanged schema (`LibraryFile` version 1). For Markdown it is a cache of notebooks and `NoteMeta` (titles, previews, tags, revisions), rebuilt from the folder if missing. Revisions are only ever stored here. |
| `markdown-files.json` | New, Markdown only. Per note: `{"path":"Work/Plan.md","sha256":"…","size":1234,"mtimeNs":…,"inode":…,"frontMatterExtra":"…","formerPaths":["Work/Old plan.md"]}`. It is also the path → id map used to resolve wiki links (3.4). |
| `tombstones.json`, `sync-deletions.json`, `sync-state-*.json`, `recovery/`, `history/` | Unchanged role. |
| `backups/` | New. Temporary staging for backup ZIPs and safety backups made before a conversion. |

Files owned by other sub-projects stay in the data folder too and are listed in program §7: `search-index.json` (organise, v2 format), `link-index.json`, `attachment-text.json`, `semantic-index/`, `smart-folders.json`, `library-settings.json`, `lock-keys.json`, `shares.json`, `spaces.json`, `sites/`.

The content folder contains only:

```
<content>/
  Inbox.md                      ← note without a notebook
  Work/
    .noteit-notebook.json       ← the notebook record minus its name (3.4)
    Plan for Q4.md
    Meetings/                   ← nested notebook "Meetings" inside "Work"
      .noteit-notebook.json
      2026-10-19.md
  _attachments/
    3f9a1c2b7d10-photo.jpg
  .trash/
    Old idea.md                 ← Recently Deleted
  .noteit/
    library.json                ← {"format":"noteit-markdown","version":1,"libraryID":"…"}
    locked/
      6F1C2E9A-….sealed         ← sealed body of a locked note (3.7)
    staging/                    ← temporary files, removed at launch
```

`.noteit/` holds only content that can't live anywhere else: the folder's identity, sealed bodies and in-progress writes. It holds no indexes and no per-Mac state.

`.noteit/library.json` identifies the folder. If a second Mac picks the same folder (for example through Dropbox), NoteIt sees an existing `libraryID` and shows the cloud folder warning in 3.6. Adopting such a folder is allowed: ids in front matter keep notes from duplicating, and NoteIt Sync conflicts handle the rest.

### 3.2 Markdown dialect

Base: **CommonMark 0.31 + GitHub Flavored Markdown** (tables, task lists, `~~strikethrough~~`, autolinks). Everything NoteIt can't express in that base uses inline HTML or an HTML comment, both of which other Markdown apps show harmlessly. The parser and writer live in a new pure target, `NoteItMarkdown` (macOS and iOS, depends only on `NoteItDoc`, Foundation only), and convert between Markdown text and the `noteit-doc` tree (`DocNode`, `BodyContainer`) from `NoteItDoc`. It is the only lossless Markdown path in NoteIt: the Local API, MCP, plugins and the web clipper read and write Markdown through it (program §6). It has two flavours, chosen by the caller:

| Flavour | What it writes | Used by |
|---|---|---|
| `library` | Lossless: the dialect below, with NoteIt's HTML comments and fallback blocks | Markdown libraries, backups, plugins |
| `portable` | Clean Markdown: no NoteIt comments, front matter only for `id`; formatting Markdown can't hold is dropped | Local API and MCP reads (default), web clipper input |

`parse` reads either flavour, so the Local API and MCP accept both on write. The editor never sees Markdown directly: `.md` → `MarkdownCodec.parse` → `BodyContainer` → `DocConverter.importDocument` (`NoteItDocAppKit`) → `NSAttributedString`, and back the same way on save. In the app this chain is wrapped by `BodyCodec`, the enum foundations defines with no codec registry; this sub-project adds `case markdown` inside that enum's body in wave 1, with a `.markdown` branch in each of its switches (`fileExtension` is `md`), and puts its static Markdown helpers in an extension (3.12).

**Images on import.** Markdown that comes from outside the library refers to images by URL. `MarkdownImportOptions.resolveImage: (URL) async -> Data?` lets the caller fetch them: the web clipper downloads them, the Notion importer reads them from the export (3.11). An image that resolves to nil, or to more than 25 MB (`AttachmentLimit`), is dropped and listed in the result, so the caller can report it. A library read doesn't need it: images there are files in `_attachments/` (3.4).

| NoteIt formatting | Markdown written |
|---|---|
| Title / Heading / Subheading | `# `, `## `, `### `. `####`–`######` read as Subheading. |
| Body paragraph | plain text; paragraphs separated by one blank line |
| Line break inside a paragraph | `\` at end of line; a soft break read from a file stays a plain newline (below) |
| Bold, italic, strikethrough, inline code | `**…**`, `*…*`, `~~…~~`, `` `…` `` |
| Underline | `<u>…</u>` |
| Highlight, default yellow | `==…==` (as Obsidian, iA Writer, Typora) |
| Highlight, other colours | `<mark style="background-color: #C3F0B3">…</mark>` |
| Text colour | `<span style="color: #2899E0">…</span>` |
| Font size change | `<span data-size="+4">…</span>` (delta in points from the body size); combined with colour in one `span` |
| Link | `[text](url)`; bare URLs stay bare |
| Link to another note (`noteit://note/<UUID>`, linking) | `[[File name]]`, `[[File name\|shown text]]` when the text differs, `[[File name#Heading]]` with a heading (3.4) |
| Bulleted / numbered list | `- ` / `1. `, nested by 4 spaces per level |
| Checklist | `- [ ] ` / `- [x] ` |
| Quote | `> ` |
| Code block | fenced with ```` ``` ````; info string = `CodeLanguage.identifier` (`swift`, `python`, `text` for Plain); no info string = Automatic |
| Divider | `---` |
| Table | GFM pipe table; column widths in a block comment (below) |
| Image | `![photo.jpg|480](_attachments/3f9a1c2b7d10-photo.jpg)`; `|480` is the display width in points, omitted at natural size |
| Other attachment | `[report.pdf](_attachments/9b01e4aa52c7-report.pdf)` |

**Line breaks.** CommonMark has two: a hard break (`\` or two spaces at the end of a line) and a soft break (a plain newline inside a paragraph, which renderers show as a space). NoteIt shows a soft break as a line break, as Obsidian does, but keeps it apart: the reader makes a plain newline a `softBreak` inline (stored in `noteit-doc` as `{"type": "hardBreak", "attrs": {"soft": true}}`, so a reader that doesn't know the attribute sees a hard break), and the editor carries it as U+2028 with the `noteItSoftBreak` attribute. The writer writes a soft break back as a plain newline and a hard break as `\` + newline, so editing a hard-wrapped paragraph adds no backslashes. A line break the user types has no soft mark and is written as `\`. Where a plain newline can't stand — at the start or end of a paragraph or list item, next to another break, or in a heading, code block or table cell — a soft break is read and written as a hard one.

Colours are written as uppercase `#RRGGBB` sRGB. The editor's palettes (`EditorStyle.textColors`, `EditorStyle.highlightColors`) map to their exact hex values, so a Yellow highlight is always `==…==` and other highlights always use the same hex.

**Block attributes** that Markdown has no syntax for (alignment, indent of a body paragraph, table column widths, a list that starts at a level other than 0) go in a comment line directly before the block:

```
<!-- noteit: align=center -->
This paragraph is centred.
```

Keys: `align=left|center|right|justify`, `indent=1..8`, `level=1..8`, `widths=120,80,200`. Unknown keys are ignored when reading and dropped on the next write of that block.

**Rich-block fallback.** A few combinations exist in `noteit-doc` but have no Markdown form: formatting or images inside a code block (web-app spec §3.3 allows marks there), a table cell with several paragraphs or a list, a heading containing an image. For those blocks only, the writer emits the plain Markdown rendering plus a comment holding the exact block:

~~~
<!-- noteit: doc=eyJ0eXBlIjoiY29kZUJsb2NrIiwi… -->
```swift
let x = 1
```
~~~

The payload is base64url JSON of that one `DocNode`. When reading, the payload is used only if its plain text equals the text of the Markdown block that follows it. If someone edited the block in another app, the texts differ, the payload is ignored and the visible Markdown wins. Fallback comments are expected to be rare; the plan's corpus test fails if more than 1% of blocks in the sample library need one.

A block type this NoteIt doesn't know (`DocNode.unknown`, written by a newer client) has no visible rendering. In the `library` profile it is written as the comment alone, `<!-- noteit: doc=… -->` holding its raw JSON, and the reader turns that comment back into the same unknown block with no text check, so a note survives a round trip through an older NoteIt. The `portable` profile (export) drops unknown blocks, since other apps couldn't show them.

**Escaping.** The writer escapes only where needed (`*`, `_`, `` ` ``, `[`, `<`, `#` at line start, `1.` at line start, `|` in tables, `==`). Wiki links are written as raw `[[…]]`, never escaped, except inside a table cell, where the `|` between file name and shown text is written as `\|` (`[[File name\|shown text]]`, program §11) so it doesn't split the cell; the reader accepts both forms. Literal text that happens to contain `[[` is escaped as `\[[` so it doesn't turn into a link. After writing a block the writer parses the result again; if the parse is not equal to the block, it escapes every Markdown-significant character in that block except wiki links. Markdown that NoteIt doesn't model (footnotes, math, HTML other than the tags above) is kept as literal text and written back byte for byte.

**Unchanged blocks keep their bytes.** NoteIt keeps the source ranges of every block from the last read. On save, a block whose `DocNode` is equal to the one read from disk is written with its original text, so a file edited in another app is not reformatted just because NoteIt saved a different paragraph. Only changed blocks are written in NoteIt's canonical style. The canonical style for inline marks is nested in a fixed order, outermost first: link, `span`, `mark`/`==`, `<u>`, `~~`, `**`, `*`, code.

**Lossless round trip, guaranteed by tests.** Two properties are tested in `Tests/NoteItMarkdownTests`:
1. `parse(serialize(doc)) == doc` for every golden fixture and for 2,000 random documents from `RandomDocGenerator` (`NoteItDocTestSupport`).
2. `serialize(parse(md)) == md` byte for byte for every fixture `.md` in canonical form, and block-for-block for the "foreign" fixtures written by Obsidian, Bear and iA Writer.

Golden fixtures are pairs `Fixtures/<name>.md` + `Fixtures/<name>.json` (the `BodyContainer`), one per row of the table above plus the code-block cases from the `NoteItDoc` golden fixtures.

**What is lost.** Only what `noteit-doc` already drops: font families other than the body font, and any RTFD attribute the web-app spec lists as not exported. Converting a library or editing on a Markdown Mac therefore has exactly the fidelity of the web app.

### 3.3 Front matter

YAML front matter between `---` lines at the top of the file. NoteIt writes a small fixed subset and reads it with its own parser (no YAML dependency):

```yaml
---
id: 6F1C2E9A-6B0D-4E43-9B5C-1E0F5D7B9A11
created: 2026-10-19T09:12:44Z
updated: 2026-10-19T10:03:02Z
pinned: true
---
```

| Key | Written | Notes |
|---|---|---|
| `id` | always | Uppercase UUID, the `NoteMeta.id`. |
| `created` | always | ISO 8601 UTC with `Z`. |
| `updated` | always | ISO 8601 UTC. When a file is edited outside NoteIt, its modification date becomes `updatedAt` and `updated` is rewritten on the next NoteIt save of that note. |
| `pinned` | only when `true` | |
| `deleted` | only in `.trash/` | `deletedAt`. |
| `conflict-of`, `conflict-source` | only on conflict copies | `conflictOriginalID`, `conflictSource`. |
| `locked` | only on locked notes | `true`. Informational for other apps only. It is not the source of truth: whether a note is locked comes from its sealed file (3.7). The key is ignored when reading. |

Not written, because the file already says it: **notebook** (the folder), **title** (the first line of the body), **tags** (the `#tags` in the text, as today). `revision` is device-local sync state and stays in `library.json`. When `organise` adds tag chips or nested tags, it may add a `tags:` key; until then a `tags:` list read from a foreign file is appended as a hashtag line, as `MarkdownReader` does on import today.

Unknown keys (`aliases:`, `cssclasses:`) are kept verbatim, in their original order, in `markdown-files.json` (`frontMatterExtra`) and written back unchanged. On a store whose manifest `features` contains `noteit-doc` they also sync as the optional container field `frontMatter` (a string, added to `NoteItDoc` in foundations), which other Markdown Macs write back and other clients preserve and never show. In the app they travel beside the text as `ContainerExtras` (foundations: `MarkdownBodyStorage.read` returns them in `StoredBody.extras`, `NoteStore` keeps them by note ID and passes them back on every write), so they survive read → edit → write. On a store without `noteit-doc` (RTFD bodies) they stay on the Mac that has them. As in program §4.1, this depends on the feature, never on `formatVersion`.

A file without front matter, or with front matter but no `id`, is a valid note. NoteIt assigns an id and writes the front matter once the file has not changed for 2 seconds. If two files carry the same `id` (a copied file), the file already recorded for that id in `markdown-files.json` keeps it; if neither is recorded, the path that sorts first keeps it. The other file gets a new id.

### 3.4 Folders, files and attachments

**Notebooks.** Each folder is a notebook named after the folder. A folder inside a notebook folder is a nested notebook, up to 4 levels deep (program §12). Folders deeper than 4 levels are not notebooks: their notes belong to the depth-4 notebook and NoteIt keeps the files where they are. NoteIt never creates a folder deeper than 4 levels. Folder names starting with `.` or `_` are not notebooks. Files at the root have no notebook.

`.noteit-notebook.json` in each notebook folder stores the whole `Notebook` record except `name`, with the same keys as the synced notebook record: `id`, `symbol`, `color`, `sortIndex`, organise's `parent`, linking's `defaultTemplateID`, and any key a newer NoteIt adds. `spaceID` is never written to this file: which notebook belongs to a shared space is kept only in sharing's `spaces.json` in the store folder, so copying or syncing the content folder through another service never carries a share with it. If a file contains a `spaceID` key anyway, NoteIt ignores it on read and drops it on the next write; it is not kept as an unknown key. It has no board fields: board layouts are `boards/<notebookID>.json` sync records (program §4 rule 14) and are not written to the folder. Writers follow program §4.5: read the file, change only their own keys and write it back, so unknown keys survive. A folder without the file gets one on first sight with the defaults new notebooks use.

The folder layout is the source of truth for nesting. `parent` is written to match the folder; if the two disagree (a folder moved in Finder), the folder wins and `parent` is rewritten. Moving a notebook in NoteIt moves its folder; moving a folder in Finder moves the notebook. Renaming a notebook in NoteIt renames the folder; renaming the folder in Finder renames the notebook (matched by the `id` in `.noteit-notebook.json`). Until organise's notebook `parent` field is available, nested folders map to their top-level notebook, as described for depth over 4.

**File names.** `<title>.md`, where the title is sanitized with the existing `ExportNaming.sanitized` rules, cut to 100 characters, and made unique within the folder case-insensitively with ` 2`, ` 3` (the existing `ExportNaming.unique`). Untitled notes are `Untitled.md`.

Renaming files when titles change is a per-library setting, **Rename files when titles change** (`renameFilesOnTitleChange` in `library-location.json`). It is on for a folder NoteIt created and **off for an adopted folder** (program §11): an adopted folder keeps its file names, and new notes get a name from their title once. When the setting is on, the file is renamed when the note is deselected or after 5 seconds without typing, never on every keystroke. A file the user renamed outside NoteIt keeps its name until the title changes again in NoteIt.

**Links between notes (wiki links).** This sub-project owns the on-disk syntax; linking owns how links behave in the app and its resolution rules (program §12).
- A note link (`noteit://note/<UUID>` in the doc) is written as `[[File name]]`, `[[File name|shown text]]` or `[[File name#Heading]]`. File name is the target's file name without `.md`. If that name isn't unique in the library, the path from the content folder without `.md` is used (`[[Work/Plan]]`).
- An unresolved link (`noteit://note?title=`) is written as `[[title]]`.
- Reading resolves the name through the path → id map in `markdown-files.json`: exact path first, then a unique file name, then a former path of a renamed file (`formerPaths`). The result is `noteit://note/<UUID>`. A name that resolves to nothing becomes an unresolved link with that title. `![[name]]` for a non-image file in the library is a note link; for an image in `_attachments/` it is an image.
- `MarkdownCodec` gets the two lookups as closures, so `NoteItMarkdown` stays free of file access.
- When NoteIt renames a file, the old path is kept in `formerPaths`, so links in files NoteIt hasn't rewritten yet still resolve to the same UUID. Files that link to the renamed note are rewritten with the new name the next time NoteIt writes them; their doc is unchanged, so their revision doesn't change. When a file is renamed outside NoteIt, the same `formerPaths` rule keeps links in other files working.
- Wiki links are never escaped, except `|` inside a table cell, which is written as `\|` (3.2).

**Which files are notes.** Files ending `.md` or `.markdown`, anywhere in the content folder except `.trash/`, `.noteit/`, `_attachments/`, folders whose names start with `.`, and `node_modules`. Files over 10 MB are listed in the Your Data tab as "Skipped: 2 files over 10 MB" and not loaded. iCloud placeholders (`.icloud`) are skipped until downloaded.

**Attachments.** `_attachments/<first 12 hex of SHA-256>-<sanitized original name>`, shared by all notes. Identical files are stored once. References are relative to the note file (`../_attachments/…` from a notebook folder, `../../_attachments/…` from a nested one) so other apps resolve them. When reading, any relative path, `file://` URL inside the content folder, or Obsidian-style bare name that exists in `_attachments/` is accepted. Images keep their original bytes in a Markdown library (HEIC stays HEIC), using the `ImagePolicy.keepOriginal` export option that foundations adds to `DocConverter`. Attachments over 25 MB (`AttachmentLimit`) are never copied in; the import or paste reports them as it does today.

An attachment no note refers to is moved to the macOS Trash 24 hours after the last reference disappears, so an undo or an external edit in progress can still find it. NoteIt never deletes attachments it did not see referenced at least once.

**Writes.** Every write goes to `.<name>.noteit-tmp` in the same folder, is fsynced, then renamed over the target. Files are UTF-8 without a BOM, with LF line endings and a final newline. Before writing, NoteIt checks that the file on disk still matches `markdown-files.json` (size, modification time, inode, and SHA-256 if those differ); if not, it handles the external change first (3.5).

### 3.5 Watching external edits and conflicts

`MarkdownFolderWatcher` uses an FSEvents stream on the content folder with file-level events and 0.3 s latency. Events are debounced 0.5 s per path. NoteIt ignores events for files it wrote itself: every NoteIt write records `(path, sha256)` in a short-lived ledger, and an event whose file still has that hash is dropped.

At launch, and whenever FSEvents reports `MustScanSubDirs` or a dropped event, NoteIt rescans the folder: for every file it compares size, modification time and inode with `markdown-files.json` and reads and hashes only files that differ. Budget: a 10,000-note library with no changes scans in under 1 second; this and the 10 MB per-file limit are hard targets in the plan's benchmark task. A folder with more than 50,000 Markdown files still opens, and the Your Data tab shows "This folder has more than 50,000 Markdown files. NoteIt may be slow."

| Change outside NoteIt | Result |
|---|---|
| File content changed, note not open or open without unsaved edits | Body reloaded through `NoteStore.editBody` with the default `.recordCurrent`, which records the previous body in history once. New `revision`, `updatedAt` = file modification date, the note syncs. An open note reloads in place through `externallyUpdatedNoteID`, keeping the scroll position. |
| File changed while the note has unsaved NoteIt edits | NoteIt's version wins and is written. The external version is kept as a new note "<title> (Outside NoteIt)" with `conflictSource = "Outside NoteIt"` and `conflictOriginalID` set, exactly like a sync conflict copy. |
| New file | New note. Front matter is added after 2 s of no changes. |
| File moved or renamed | Matched by `id`; the note keeps its id, history and revision. Moving into another notebook folder changes its notebook. The old path goes to `formerPaths` so wiki links keep resolving (3.4). |
| File deleted | Note moved to Recently Deleted, unless the mass-deletion guard below holds the batch. NoteIt writes its last known content to `.trash/<name>.md` so Recover works. |
| Folder renamed or moved | Notebook renamed or moved (nesting follows the folder, 3.4). Folder deleted: its notes go to Recently Deleted, as when a notebook is deleted in NoteIt, unless the mass-deletion guard holds the batch. |
| File is not valid UTF-8, or front matter can't be parsed | The note opens read-only with the banner "This file can't be read as Markdown. NoteIt won't change it." It is never rewritten. |
| The content folder disappears (unmounted disk, renamed) | NoteIt shows "Your Markdown folder can't be found" with **Locate…** and **Quit**; nothing is written until it is back. The bookmark in `library-location.json` follows a rename. |

**Mass-deletion guard** (program §11). If one scan finds that more than 20 files have disappeared, or at least 10% of the library's files and at least 5 files, NoteIt doesn't apply any of those deletions. It shows "Many notes disappeared from the folder" with the count, **Move to Recently Deleted** and **Not Now**. Until the user confirms, the notes stay in the library and their tombstones are not written or synced; a note whose file is missing opens read-only with "This note's file is missing from the folder." If the files come back (a cloud provider finished downloading, a disk was remounted) the next scan clears the warning by itself. **Not Now** keeps waiting and asks again at the next launch. Deletions below the threshold apply as in the table. Locked notes count like other notes; their sealed files are never removed by this path (3.7).

An external edit counts as a local user edit for sync: the note gets a new revision and is pushed on the next sync. If sync then finds a remote change too, the existing sync conflict rules apply unchanged.

### 3.6 Converting a library, both ways

Settings › Your Data › **Switch to Markdown Folder…** opens a sheet:

- "Choose a folder for your notes" with **Choose…** (default `~/Documents/NoteIt`, created if missing). An empty folder is used as is. A folder that already contains Markdown files is **adopted**: the sheet says "This folder already has 248 Markdown files. NoteIt will add them to your library and add a small header with an id to each file. File names stay as they are." and the option **Make a backup ZIP of this folder first** (on by default). An adopted folder starts with **Rename files when titles change** off (3.4).
- **Back up my library first** (on by default): writes a backup ZIP (3.8) to `<data>/backups/`.
- **Folders that overlap the library are refused.** Paths are compared after resolving symlinks and standardising. The chosen folder is refused if it is equal to, inside, or contains any of: the current body folder `<data>/notes/`; the paths the conversion manages in the data folder (`<data>/backups/`, including its `staging-*` folders, `<data>/sync-meta-raw/`, `<data>/body-extras/`, `<data>/history/`); and the data folder `<data>` itself. The picker shows "This folder holds NoteIt's own library files. Choose a folder outside them." under the folder, and **Switch** stays disabled. `LibraryConverter` checks the same rule again before step 1, so nothing is flushed, paused, staged or moved for a refused folder.
- If the folder is inside iCloud Drive, Dropbox, OneDrive, Google Drive or `~/Library/CloudStorage` and NoteIt Sync is on: "This folder is also synced by another service. Using both can create duplicate notes. NoteIt Sync already keeps your Macs in sync." Buttons **Use Both Anyway** and **Choose Another Folder**. Not blocked.
- **Switch** starts the conversion; a progress bar shows "Converting 412 of 1,284 notes…".

Steps, in this order:
1. Flush all pending saves (`NoteStore.flush()`), pause sync, stop accepting edits (the editor shows "Converting your library…").
2. Optional backup ZIP.
3. Write every note, notebook and attachment into `<content>/.noteit/staging/convert-<timestamp>/`. Sealed bodies of locked notes are copied as they are, without being opened: `<data>/notes/<uuid>.locked` becomes `.noteit/locked/<uuid>.sealed`, and the reverse when converting back (program §8).
4. Verify: parse every staged file and compare it with the source body using the same semantic equality as the `NoteItDoc` converter tests. Sealed files are compared by SHA-256. A note that does not round-trip is reported by title and the conversion stops before anything is moved, with "2 notes can't be converted without losing formatting" and **Show Notes** / **Cancel**. Nothing has changed at that point.
5. Move the staged files into place (same volume, so these are renames).
6. Write `library-location.json` atomically. This is the commit point: before it, the old library is still in use; after it, the new one is.
7. Move `<data>/notes/` to `<data>/Previous Library 2026-10-19/` and relaunch NoteIt.

Revisions, ids, `createdAt`, `updatedAt`, version history, Recently Deleted, locks and the derived indexes in the data folder carry over. A format change is not a user edit: no revision changes and nothing is re-uploaded.

**The previous library is never moved to the Trash on its own** (program §11). The Your Data tab shows "Previous library from 19 Oct 2026 (210 MB)" with **Remove** for as long as it exists. After 30 days NoteIt asks once at launch: "Your previous library from 19 Oct 2026 is still on this Mac (210 MB). Move it to the Trash?" with **Move to Trash** and **Keep**. **Keep** stops the question; the row in Your Data stays.

**Switch to NoteIt Library…** does the reverse: converts every `.md` into `notes/<uuid>.rtfd` and moves every sealed file to `notes/<uuid>.locked`, with the same staging, verification and commit. The Markdown folder is left untouched (NoteIt removes its own `.noteit/` folder only, after the sealed files have been moved out of it) and the sheet says "Your Markdown folder stays where it is. NoteIt won't change it any more."

If NoteIt crashes or the Mac loses power mid-conversion, the next launch sees no new `library-location.json`, opens the old library and deletes the staging folder. If it crashes after step 6, the new library is complete and only the move in step 7 is retried.

### 3.7 History, Recently Deleted, search and sync with Markdown

All features go through `NoteStore`, which reads and writes bodies through `NoteBodyStorage` (foundations, program §2 step 4). Foundations ships the protocol and the RTFD implementation; this sub-project adds `MarkdownBodyStorage`. Nothing outside `NoteStore` and the storage types reads note files. Code outside the editor that changes note text uses `NoteStore.editBody` (program §6).

- **Version history** keeps living in `<data>/history/<uuid>/`. For Markdown libraries versions are saved as `<timestamp>.noteitdoc`: a self-contained `BodyContainer` JSON (attachments embedded). `VersionHistory` reads both `.rtfd` and `.noteitdoc`, so history survives a conversion in either direction. The limits (one version per 10 minutes, 50 versions, 30 days) are unchanged.
- **Recently Deleted** is `.trash/` in the content folder, with `deleted:` in front matter. Recover moves the file back to its notebook folder. Delete Now, Empty Recently Deleted and the 30-day purge move files to the macOS Trash, not straight to deletion.
- **Search index** uses organise's v2 format (`search-index.json` in the data folder) as is. This sub-project adds no fields to it. Files changed outside NoteIt reach it, and every other derived index, through the `DerivedIndex` registry (`noteChanged`, `noteRemoved`, and `metadataChanged` for a move between folders) after the watcher reloads them; this sub-project adds no other hook (program §7).
- **Recovery copies** (`recovery/`) are written as `.md` for Markdown libraries.
- **Sync** is unchanged on the wire. On a store whose manifest `features` doesn't contain `noteit-doc`, the body is still flattened RTFD: a Markdown Mac converts `.md` → `DocNode` → `NSAttributedString` → RTFD when pushing, and the reverse when pulling. When `features` contains `noteit-doc`, the body is the `noteit-doc` container, so a Markdown Mac converts directly without going through RTFD. Pulled notes are written with the same atomic write and recorded in the watcher ledger, so they are not mistaken for external edits. `bodySHA256`, conflict copies, tombstones and the deletion journal work as today. Notebook and note JSON keep unknown keys through `RawMetaOverlay` (program §4.5).
- **Revisions for notes that have none** are computed from the body file, as today (`contentRevisions`), using the `.md` file and its referenced attachments.
- **Locked notes.** Sync-security owns locking (program §8); this sub-project owns how a locked note looks in a Markdown library. Locked notes ship in wave 3 with sync-security's milestone M5 (program §1, §8), so the locked-note parts of this spec (this item, sealed files in conversion 3.6, backups 3.8, checks and restore 3.9, the drill 3.10) are built then, in the plan's wave-3 milestone, after sync-security's lock crypto. The wave-1 release has no locked notes and no lock handling.
  - The sealed body is `.noteit/locked/<uuid>.sealed`, byte for byte the same sealed file that an RTFD library keeps as `notes/<uuid>.locked`. It never appears as plaintext in the folder.
  - The note's `.md` file is a placeholder: front matter with `locked: true`, the title as the first line, and "This note is locked. Open it in NoteIt to read it." It keeps the title visible in other apps.
  - The sealed file is the source of truth. A note is locked when its sealed file exists; `NoteMeta.lock` is rebuilt from the sealed file's cleartext header (`keyID`, `sealedID`) if the metadata lost it. `locked: true` in front matter is ignored when reading.
  - Text added to a placeholder in another app is not lost: it becomes a new note "<title> (Outside NoteIt)", and the placeholder is rewritten.
  - Deleting the placeholder outside NoteIt moves the note to Recently Deleted; Recover writes it again. The sealed file stays in place while the note is in Recently Deleted. It is deleted when the note is deleted for good, on every path: Delete Now, Empty Recently Deleted and the 30-day purge. Remove Lock also deletes it after writing the plain body. A scan or a conversion never deletes a sealed file.
  - Locked notes are left out of every derived index; their sealed files are never opened by the watcher, the scanner, backups or the restore drills.

### 3.8 Back Up Everything (ZIP)

**Back Up Everything…** shows a save panel with the name `NoteIt Backup 2026-10-19 0912.zip` and the option **Include version history** (off by default). The ZIP has the same layout for both library formats, so it is useful without NoteIt:

```
NoteIt Backup 2026-10-19 0912/
  README.txt                    ← "These are your NoteIt notes as Markdown files. …"
  Work/Plan for Q4.md
  Work/Private.md               ← placeholder of a locked note (3.7)
  _attachments/…
  .trash/…
  .noteit-backup/
    manifest.json
    library.json                ← notebooks and metadata including revisions
    locked/<uuid>.sealed        ← sealed bodies of locked notes, copied as they are
    locked/lock-keys.json       ← the lock keyring, copied as it is
    history/<uuid>/<ts>.noteitdoc   ← only with Include version history
    fallback/<uuid>.noteitdoc   ← only for notes whose Markdown doesn't round-trip exactly
```

`manifest.json`: `{"format":"noteit-backup","version":1,"createdAt":"…","appVersion":"0.3.0","libraryFormat":"rtfd","noteCount":1284,"notebookCount":9,"lockedCount":2,"files":{"Work/Plan for Q4.md":"<sha256>","…/locked/6F1C2E9A-….sealed":"<sha256>",…}}`. Every file, including sealed files and `lock-keys.json`, has a checksum.

Writing: NoteIt flushes, writes the tree into `<data>/backups/staging-<timestamp>/` (Markdown libraries copy the files; RTFD libraries convert with the `library` flavour), checks free space (needs the estimated size plus 10%), zips with `ditto -c -k --keepParent` to `<name>.zip.partial` next to the destination, renames it to `.zip`, and removes the staging folder. Sealed files and `lock-keys.json` (from the data folder) are copied byte for byte and never opened (program §8). Version history of locked notes is not in the backup, because locking deletes it. Progress shows in the sheet; Cancel removes the partial file. If a note fails to convert, its `fallback/<uuid>.noteitdoc` is still written and the summary says "1 note was saved in NoteIt's own format because it has formatting Markdown can't hold."

**Automatic backups** (`automaticBackups` = `off`/`daily`/`weekly`): checked at launch and every hour while running; a backup is due when `lastBackupAt` is older than 24 h or 7 days. It runs at utility priority, never while a conversion or restore runs, and keeps the newest `automaticBackupKeep` ZIPs in the folder (only files matching `NoteIt Backup *.zip` are ever removed, and they go to the macOS Trash). If the folder is missing (unplugged drive) the backup is skipped and the tab shows "Last automatic backup failed: the folder “Backups” isn't available." No notification.

Settings keys (`PrefKey`): `automaticBackups` (String), `automaticBackupFolder` (Data, security-scoped bookmark not needed because the app isn't sandboxed; a regular bookmark so renames are followed), `automaticBackupKeep` (Int, default 10), `lastBackupAt` (Date), `lastBackupFile` (String), `lastBackupError` (String), `lastRestoreCheckAt` (Date).

### 3.9 Check a Backup, Restore from Backup

**Check a Backup…** asks for a NoteIt backup ZIP (or any folder with `.noteit-backup/manifest.json`) and runs a restore drill without touching the library:
1. Unzip with `ditto -x -k` into `<data>/restore-drill/`, using the same zip-safety checks as `MarkdownImporter` (no absolute paths, no `..`, size limits).
2. Verify every file against `manifest.json` checksums. Sealed files and `lock-keys.json` are verified by hash only; they are never opened.
3. Parse every note that isn't locked, and its attachments.
4. Compare with the current library by id.

The result sheet: "This backup is complete. All 1,284 notes and 9 notebooks can be restored." plus, when the backup has locked notes, "2 locked notes (sealed, not opened)", and, when relevant, "12 notes have changed since this backup. 3 notes in this backup are no longer in your library." Failures list the files: "2 files are damaged: Work/Plan for Q4.md …". `lastRestoreCheckAt` is set; the drill folder is removed when the sheet closes.

**Restore from Backup…** runs the same check, then offers **Restore Missing Notes** (adds notes that are in the backup but not in the library or Recently Deleted) and **Restore Missing and Changed Notes** (also replaces notes whose body differs). Replacing a body goes through `NoteStore.editBody`, so an open note updates in place. Because it rewrites more than one note it follows program §6: each replacement goes through `editBody` with the default `.recordCurrent`, which records the current body in history once, and after the restore NoteIt offers **Undo**. The restore never records a version itself. Restored notes get new revisions so they sync. Notebooks missing from the library are recreated by id, with every key from the backup's `library.json`. A missing locked note is restored by copying its sealed file as it is, and the backup's `lock-keys.json` is merged into the current one with sync-security's keyring merge; a locked note that exists but differs is left alone and listed: "1 locked note has changed since this backup and wasn't replaced." Nothing is ever deleted by a restore.

### 3.10 Check Sync Storage

**Check Sync Storage…** proves the remote store can rebuild the library on a new Mac. It uses the current store session (`StoreSession`, through `SyncController.ensureSession`) and a new read-only `RemoteRestoreDrill` in `NoteItSync`:

- lists `noteit/v1/`, opens the manifest, decrypts every note and notebook envelope, downloads every body, checks `bodySHA256`, and decodes the body (flattened RTFD, or the `noteit-doc` container when the manifest `features` contains `noteit-doc`);
- a body with `bodyFormat: "noteit-locked/1"` is checked by `bodySHA256` only and never opened; the drill also checks that the lock keyring (`keys/`) is present when any note is locked;
- prefixes registered by other sub-projects in `RemoteLayout` are listed but not decoded;
- compares the result with the local library by id and revision;
- writes nothing to the remote and nothing to the library.

Result: "All 1,284 notes and 9 notebooks in “Studio NAS” can be restored on a new Mac." plus, when there are locked notes, "2 locked notes (sealed, not opened)", or a list: "3 notes on this Mac aren't in the sync storage yet. They'll be uploaded at the next sync." / "1 note in the sync storage can't be read: <title or id> (damaged body)." with **Sync Now**. It runs at utility priority with at most 4 parallel downloads, can be cancelled, and pauses automatic sync while running. The passphrase is never asked again; if the session is locked, the button says "Unlock sync first" and switches to the Sync tab.

### 3.11 Evernote and Notion importers

**Evernote `.enex`** (`EvernoteImporter`):
- Streams each file with `XMLParser` so 1 GB exports don't load into memory. Each file becomes a notebook named after the file (`notebookForImport(named:)`).
- For each `<note>`: `title`, `created`/`updated` (format `yyyyMMdd'T'HHmmss'Z'`), `tag` elements (added as a hashtag line, as Markdown import does), `content` (ENML, CDATA).
- ENML is turned into HTML: `en-note` → `div`, `en-todo checked="true|false"` → a checkbox list item, `en-media hash="<md5>"` → the matching `<resource>` (decoded from base64, matched by MD5) as an `img` data URL for images or a file link otherwise. The HTML then goes through the existing `AppleNotesImporter.convert(html:title:)`, so formatting rules match the Apple Notes import.
- `en-crypt` sections: the note is imported without them and counted in `ImportReport.lockedSkipped` ("3 notes had encrypted sections that were skipped."). Resources over 25 MB count in `attachmentsSkipped`.
- Duplicates are not detected; importing the same file twice creates two notebooks ("Work", "Work 2").

**Notion "Markdown & CSV" export** (`NotionImporter`):
- Accepts the export `.zip` or its unzipped folder. Notion nests ZIPs (`Export-….zip` containing `Part-1.zip`); nested ZIPs are opened one level deep with the existing zip-safety checks.
- Notion appends a 32-character hex id to every file and folder (`Plan 1a2b…c3d4.md`); it is removed from titles and notebook names, and used to resolve links between pages.
- Each top-level page that has subpages becomes a notebook containing itself and all its descendants (flattened). Top-level pages without subpages go to a notebook named "Notion".
- Pages are read with `MarkdownCodec.importDocument` (Notion's Markdown is plain CommonMark), with a `resolveImage` that percent-decodes the path and reads the file inside the export (3.2). `<aside>` callouts become quotes. Links to other pages in the export become plain text with the page title until `linking` turns them into wiki links.
- Database `.csv` files become one note each with a table (the first 1,000 rows; "Only the first 1,000 rows of “Tasks” were imported." in the report). The database's page `.md` files are imported as normal notes.
- An HTML export is recognised (`.html` pages) and refused with "This is an HTML export. In Notion, choose Export › Markdown & CSV and try again."

Both importers report through `ImportReport` and use `NoteStore.createImportedNote`, so they work on both library formats.

### 3.12 Data model and API changes

- `NoteStore` gets `libraryFormat: LibraryFormatKind` (`.rtfd`, `.markdown`). Body I/O goes through `NoteBodyStorage`, which foundations adds (below). `LibraryLocation` gains `format` and `contentRootURL`. `NoteStore.rootURL` stays the data folder.
- `NoteMeta` and `Notebook` do not change in this sub-project. `NoteMeta.conflictSource` takes the new value `"Outside NoteIt"`. Fields that other sub-projects add live in `NoteItCore` (program §2 step 1) and survive in `.noteit-notebook.json` and `library.json` because writers keep unknown keys.
- `library.json` keeps version 1; nothing about the format is stored in it.

**Already done in foundations** (program §2). This sub-project uses these and does not plan them again:
- **`NoteItDoc` split** (step 2): `NoteItDoc` (schema, validation, body container; Foundation only, macOS and iOS), `NoteItDocAppKit` (`DocConverter`, style provider) and `NoteItDocTestSupport` (`RandomDocGenerator`, golden fixtures loader). Step 2 also makes the changes this spec needs: the optional `language` on `codeBlock` (kept through editing by one paragraph attribute, `noteItCodeLanguageID`, also for languages `CodeLanguage` doesn't know), `ImagePolicy` on export (`.keepOriginal` keeps HEIC and other original bytes), `frontMatter` as a known optional container field that other clients preserve and never show, and `.noteitdoc` as the name of a standalone `BodyContainer` file.
- **`NoteBodyStorage` and `BodyCodec`** (step 4, from this sub-project's former milestone 1): the protocol with `RTFDBodyStorage`, `NoteStore` routing every body read and write through it, and `BodyCodec` as the one codec type for bodies. The storage protocol names its folder `contentRootURL`. Reads return `StoredBody` (text plus `ContainerExtras`) and writes take the extras back, for both the storage and the codec. This sub-project adds `MarkdownBodyStorage` and, in wave 1, `case markdown` of `BodyCodec` by editing that enum's body (Swift can't add a case in an extension) and adding a branch to each of its switches, which have no `default:` (there is no codec registry, program §6); static Markdown helpers may go in an extension. It creates no second codec type.
- **`NoteStore.editBody`**, the **`DerivedIndex`** registry and **`NoteMeta.lock`** (step 4), used as described in 3.7 and 3.9.
- **`LocalAPIRouteRegistry`** (step 5) and the frozen Settings tab, menu and palette tables (step 6).

**Local API routes**, registered by this sub-project through `LocalAPIRouteRegistry.register` (program §10), with errors from `APIErrorCode` only:

| Route id | Route | Scope | Result |
|---|---|---|---|
| `markdown-storage.library` | `GET /v1/library` | read | `{"format":"markdown","noteCount":…,"lockedCount":…,"lastBackupAt":…}`; no paths |
| `markdown-storage.backup` | `POST /v1/backups` `{destination}` | admin | starts Back Up Everything; `503 not_ready` while the library loads or a conversion or restore runs |

`GET /v1/notes/{id}?format=markdown` belongs to automation and uses `MarkdownCodec` with the `portable` flavour by default (program §6); writes accept both flavours, so exported Markdown matches files on disk.

### 3.13 Privacy and safety

- No network use is added except Check Sync Storage, which only reads the user's own store with the existing session.
- A Markdown folder is plaintext on disk, like RTFD today. FileVault is the protection; the Your Data tab says "Files in this folder are not encrypted on this Mac. Sync storage stays encrypted." when sync encryption is on. Locked notes are the exception: only their sealed files are on disk.
- Backup ZIPs are not encrypted. The save sheet says "Backups aren't encrypted. Keep them somewhere safe." Encrypted backups are not part of this sub-project.
- NoteIt never deletes files it didn't create: removals go to the macOS Trash, and adoption never removes or renames foreign files except to add front matter.
- The data safety rules of program §11 apply: the mass-deletion guard (3.5), adopted folders keep their file names (3.4), the previous library is never moved to the Trash without asking (3.6), and restoring many notes records each replaced body once through `editBody` and offers Undo (3.9).

## Dependencies

- **foundations (wave 0, program §2):** the `NoteItDoc` split with the changes listed in 3.12 (step 2), the store session and manifest features (step 3), `NoteBodyStorage`, `BodyCodec`, `NoteStore.editBody`, the `DerivedIndex` registry and `NoteMeta.lock` (step 4), `LocalAPIRouteRegistry` (step 5) and the frozen tables (step 6). All are required before this sub-project starts. Markdown libraries sync over stores with or without the `noteit-doc` feature.
- **automation (01):** owns the Local API and `GET /v1/notes/{id}?format=markdown`, which uses `NoteItMarkdown`. This sub-project registers its own routes (3.12).
- **linking (03):** owns note links in the app and their resolution rules. This sub-project owns the wiki-link syntax on disk (3.4) and writes it from the first Markdown release; before linking ships there are no note links to write and `[[…]]` read from a file becomes a link only once linking's `NoteLink` is available. Notion page links become note links once 03 ships.
- **organise (04):** search index v2 (used as is), `NoteStore.editBody` and `DerivedIndex` (through foundations), and the notebook `parent` field that nested folders map to; tag chips may add a `tags:` front matter key.
- **sync-security (08):** owns locking, the sealed file format and its header, `lock-keys.json` and the keyring merge. This sub-project stores sealed files at `.noteit/locked/<uuid>.sealed`, moves them as they are, backs them up and checks them by hash (3.7–3.10). That work is wave 3, after sync-security's lock crypto (its Task 5.1); the wave-1 work uses none of its lock types.
- **surfaces-polish (12):** may offer the Evernote and Notion importers in onboarding. It does not offer Markdown storage; that choice is only in Your Data (program §12).
- **mobile (11), web clipper (07), plugins (10):** use `NoteItMarkdown` for Markdown in and out of notes (program §6): plugins the `library` flavour, the web clipper the `portable` flavour with `resolveImage`. `NoteItMarkdown` therefore stays Foundation only and builds for iOS.

## Non-goals

- Syncing the Markdown folder through iCloud Drive or Dropbox as NoteIt's sync mechanism. NoteIt Sync stays the supported way; a cloud folder is allowed with a warning.
- A Markdown source editing mode inside NoteIt. The editor stays rich text.
- Changing the remote format, the remote layout or encryption.
- Obsidian plugin compatibility beyond plain files (`.obsidian/` is ignored and left alone).
- Importers for OneNote, Google Keep, Simplenote, Joplin. The Markdown importer covers most of them through their own Markdown export.
- Two-way sync with Evernote or Notion.
- Encrypted backup ZIPs. Backups are plain ZIPs with the warning in 3.13; sync-security may add a passphrase option later.
- Replacing `MarkdownWriter` and `MarkdownReader` behind File › Export and Import. Program §6 already makes `NoteItMarkdown` the only Markdown path everywhere else; the old types are replaced in a later cleanup with the `portable` flavour, once the golden tests have run in production for a release.

## Open questions

None.
