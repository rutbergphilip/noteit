# Feature parity: Mac app and web app

NoteIt runs as a native Mac app and as a self-hosted web app that opens the same end-to-end encrypted store. Every user-facing feature should exist on both, or be listed here with the reason it doesn't. The rule and how to keep this page current are in [CONTRIBUTING.md](../CONTRIBUTING.md#feature-parity).

Statuses:

- **Parity**: both have it, reading and writing the same data.
- **Web gap**: the web app should have it and doesn't yet.
- **Native-only by design**: a browser can't do it (global hotkeys, the menu bar, Finder, AppleScript and Shortcuts, local files). The *web equivalent* column says what comes closest.
- **Native-only (local data)**: the Mac keeps this data on the Mac only; it isn't synced, so the web can't show the Mac's copy.
- **Web-only**: the web app has it and the Mac app doesn't need it.
- **Planned**: neither app has it yet; it lands on both together.

Command IDs in backticks are the native command palette's (`Sources/NoteIt/Palette/PaletteCommandRegistry.swift`); the web's palette and shortcuts use the same IDs (`web/apps/web/app/utils/commands.ts`). A test (`web/apps/web/test/parity.test.ts`) fails when a native palette command or a web command has no row here.

Shortcuts: the web uses native's shortcuts with ⌘ as Ctrl off a Mac and ⌃ as Alt off a Mac. Where a browser keeps a key for itself (⌘N, ⇧⌘N and ⇧⌘T in Chrome), the web adds an alternative, listed in the row.

## Notes and notebooks

| Feature | Mac | Web | Status |
|---|---|---|---|
| Create, edit and delete notes (`newNote`) | ⌘N | ⌘N where the browser allows it, ⌥⌘N | Parity |
| Rich text: bold, italic, underline, strikethrough, inline code, colours, highlight | Format menu | Toolbar and the same shortcuts (⇧⌘E code, ⇧⌘H highlight); the same colour swatches | Parity |
| Headings, lists, checklists, quotes, code blocks, dividers, tables | Yes | Yes, with native's ⌥⌘0–5, ⇧⌘7/8/L, ⇧⌘U, ⌥⇧⌘D, ⌘[ ⌘] | Parity |
| Markdown as you type (`#`, `-`, `+`, `1.`, `1)`, `[]`, `>`, ```` ``` ````, `---`, `**bold**`, `*italic*`, `` `code` ``, `~~strike~~`) | Yes | Yes, the same triggers and rules | Parity |
| Images and file attachments (25 MB each) | Yes | Yes: paste, drop or pick | Parity |
| Code blocks with syntax colouring | Yes | Yes: native's languages, its language guess for Automatic and the same `language` values in the doc; colours from highlight.js grammars folded into native's token kinds, with its four themes (theme and on/off are kept per browser, as the Mac keeps its own) | Parity |
| Bigger/smaller text (⌘+ ⌘−), alignment, clear formatting | Yes | Yes: the same `fontSize` deltas, `align` values and Clear Formatting rules; toolbar and native's shortcuts (⇧⌘{ and ⇧⌘} may be kept by the browser) | Parity |
| Table rows: Add Row Above/Below, Delete Row | Format › Table | Toolbar while in a table, the same rules | Parity |
| Any text colour (Show Colors) | Colour panel | Colour picker in the text colour menu | Parity |
| Paste Markdown as formatting, Paste and Match Style | Yes | Yes: the same "clearly Markdown" rules and reader (the Mac's Markdown fixtures); ⇧⌘V pastes plain text | Parity |
| Find and replace in a note (`find`, `findReplace`) | ⌥⌘F, ⇧⌘F | ⌥⌘F, ⇧⌘F: Match Case, Whole Word, regex with `$1`, ⌘G/⇧⌘G, ⌘E, one ⌘Z per replace | Parity |
| Pin and unpin (`togglePin`) | Yes | Yes | Parity |
| Notebooks: create, rename, colour, symbol (`newNotebook`) | ⇧⌘N | ⌥⇧⌘B (⇧⌘N where the browser allows it) | Parity |
| Nested notebooks | Drag, Move To | Create inside, shown nested; Edit Notebook › Inside moves one | Parity |
| Move a note to a notebook (`move.<notebook>`) | Palette, menu | Notebook picker in the editor | Parity |
| A notebook's default template for new notes | Notebook settings | Used for new notes; choosing one is a web gap | Parity |
| Recently Deleted, recover, delete now, 30-day purge (`deleteNote`, `showRecentlyDeleted`) | ⌘⌫ | ⌘⌫ outside text, toolbar | Parity |
| Undo a deletion | ⌘Z | Undo in the "Moved to Recently Deleted" notice, or Recover | Parity |
| Conflict copies | Yes | Yes, with the same notice | Parity |
| Locked notes | Not yet: the note metadata, the `noteit-locked/1` name and the exclusions exist, but there is no lock, notes password or relock | Listed by title, read-only | Planned: ships on both together ([roadmap](roadmap.md)); a first draft of the shared crypto is parked on `wip/locked-notes` |
| Notes from older Macs (RTFD bodies) | Yes | Listed, read-only until a Mac converts them | Native-only by design |
| Version history (`versionHistory`) | ⌥⌘Y | — | Native-only (local data): versions stay on the Mac that saved them |
| Note list sorting | Date edited; Best Match while searching | Edited (Best Match while searching), created or title | Web-only (the extra orders) |

## Tags, search and smart folders

| Feature | Mac | Web | Status |
|---|---|---|---|
| `#tags` and nested `#tags/sub` in note text | Yes | Yes, the same parser (shared vectors) | Parity |
| Tag list in the sidebar, choosing a tag shows its children's notes | Tree | Chips; nesting is matched but not drawn as a tree | Parity |
| Tag suggestions after `#` | Yes | Yes: the same boundaries, ranking and end rules | Parity |
| Rename, merge and delete tags everywhere | Yes | Right-click a tag: the same rewrite rules (nested tags, code and links left alone) and smart folder searches renamed; no Undo | Parity |
| Search: words, "phrases", `-word`, `OR`, brackets (`searchNotes`) | ⌘F | ⌘F; the same parser and evaluator (shared vectors) | Parity |
| Search filters `tag:` `notebook:`/`in:` `title:` `is:` `has:` `edited:` `created:` `due:` | Yes | Yes, with a warning for a filter it can't read | Parity |
| Search ranking | Yes | Best Match while searching for words, the same ranker | Parity |
| Search snippets and highlights in the note | Yes | Yes: the same snippets and marks (shared vectors); Esc or an edit clears the marks | Parity |
| Text in images found by search | Yes | — | Native-only by design (macOS text recognition) |
| Smart folders (`newSmartFolder`, `saveSearchAsSmartFolder`) | Yes, synced | Yes: the same synced `smart-folders/` records (shared envelope vectors), in the sidebar and the palette | Parity |

## Linking, outline and note info

| Feature | Mac | Web | Status |
|---|---|---|---|
| `noteit://note` links between notes | Yes | Yes; clicking one opens the note, or creates it for a link by title | Parity |
| `[[` note suggestions, `[[Title]]` as you type, Link to Note… (`linkToNote`, ⇧⌘K) | Yes | Yes: the same title resolution and link URLs; headings after `#` aren't suggested | Parity |
| Backlinks and links in this note (`showBacklinks`) | ⌥⌘I | ⌥⌘I, Links tab | Parity |
| Unlinked mentions | Yes | Yes, in the Links tab: the same matching rules, Link and Link All | Parity |
| Update links on rename | Yes | Yes: the same offer after 2 seconds, Update or Not Now, and Undo; Ask/Always/Never is kept per browser, as the Mac keeps its own | Parity |
| Outline of headings (`showOutline`) | Yes | Outline tab; click to jump | Parity |
| Note info: words, characters, reading time, dates, notebook, tags (`showNoteInfo`) | ⌃⌘I | ⌃⌘I, Info tab; the same counts (shared vectors) | Parity |
| Copy Note Link (`copyNoteLink`) | ⌃⌘L | ⌃⌘L | Parity |
| Go Back / Go Forward (`goBack`, `goForward`) | ⌃⌘← ⌃⌘→ | ⌃⌘← ⌃⌘→, through the notes opened in this tab | Parity |

## Daily notes, templates, tasks and reminders

| Feature | Mac | Web | Status |
|---|---|---|---|
| Today's note (`openToday`) | ⌃⌘T, sidebar | ⌃⌘T, Today in the sidebar; finds the same note by title | Parity |
| Daily Note for Date… calendar, ‹ › between days (`dailyNoteForDate`) | Yes | A day picker (arrow keys move by a day or a week) and ‹ › on a daily note | Parity |
| Daily note notebook, title format and template | Settings › Editor | Native's defaults (Daily Notes, yyyy-MM-dd, no template) | Native-only (local data): Mac preferences |
| New Note from Template… (`newNoteFromTemplate`) | ⌥⌘N | ⌥⇧⌘N (⌥⌘N is New Note on the web) | Parity |
| Insert Template… (`insertTemplate`), New Template (`newTemplate`) | Yes | Yes | Parity |
| Template placeholders `{{title}}` `{{date:…}}` `{{time:…}}` `{{clipboard}}` `{{cursor}}` | Yes | Yes (the caret isn't placed at `{{cursor}}`) | Parity |
| Which notebook holds templates | Preference, else "Templates" | The notebook named "Templates" | Native-only (local data): Mac preference |
| Tasks view (`showTasks`) | ⇧⌘T | ⌥⇧⌘T (⇧⌘T where the browser allows it); check off there, ⌘Z undoes the last check | Parity |
| Show completed tasks (`showCompletedTasks`) | Yes | Completed switch in Tasks | Parity |
| `@due(…)` dates, Set Due Date… (`setDueDate`), natural dates such as `@due(fri)` | ⇧⌘D | ⇧⌘D picker; `@due(fri)`, `@remind(tomorrow 9am)` become dates on `)` with the same parser (shared vectors). Long forms only the Mac's data detector reads, such as "October 21", stay as typed | Parity |
| Reminders: `@remind(…)` notifications (`addReminder`) | ⌃⌘R, notifications | ⌃⌘R; browser notifications (Settings › General) while NoteIt is open in a tab, else a notice in the app. Claims in the same `claims/reminders/` format (shared vectors), so only one device rings | Parity |

## Capture, import and export

| Feature | Mac | Web | Status |
|---|---|---|---|
| Quick Capture | Global hotkey, menu bar | ⌥⌘C in the app (`quickCapture`) | Parity |
| Quick Capture offers a reminder for a dated first line | Yes | Yes, the same offer and `@remind(…)` | Parity |
| Capture Selection, Services › Capture to NoteIt | Yes | Install the web app (PWA) and share to it is a possible equivalent | Native-only by design |
| Menu bar panel | Yes | — | Native-only by design |
| Global hotkeys | Yes | — (browsers can't take system-wide keys) | Native-only by design |
| Export Note as Markdown (`export`) | ⇧⌘S | ⇧⌘S; the same writer rules (checked against the Mac's Markdown fixtures) | Parity |
| Export as HTML (`exportHTML`) | Yes | Yes, self-contained | Parity |
| Print, Save as PDF (`print`) | ⌘P | ⌘P, the browser's print dialog | Parity |
| Copy as Markdown (`copyMarkdown`) | ⌥⇧⌘C | ⌥⇧⌘C (whole note) | Parity |
| Export a notebook or everything as folders | Yes | Right-click a notebook or All Notes: Markdown or HTML, the same folders, file names, assets folders and links between notes, as a zip (not PDF, RTFD or plain text) | Parity |
| Import Markdown and text files, or a folder such as an Obsidian vault (`import`, `importFolder`) | Yes | Yes: the same reader, titles, front matter dates and tags, folders as nested notebooks, images from the chosen files. `[[links]]` to notes in the same import link by title | Parity |
| Import Evernote (.enex), Notion, TextBundle | Yes | Yes: Import… takes .enex files, a Notion zip or folder, .textbundle folders and .textpack zips, with the Mac's notebooks, titles, dates, tags, checklists, attachments and note links (its importer tests ported) | Parity |
| Import from Apple Notes | Yes | — | Native-only by design (reads the Mac's Notes database) |
| Import ledger (no duplicates on re-import) | Yes | — | Native-only (local data) |

## Sync, security and settings

| Feature | Mac | Web | Status |
|---|---|---|---|
| End-to-end encrypted sync, same store | iCloud, folder, S3, NoteIt Server | NoteIt Server (its own) | Parity |
| Passphrase change, re-key, devices list | Yes | Yes | Parity |
| Clean Up Unused Storage… | Settings › Sync | Settings › Sync & storage: the same confirmation, wording and rules (`cleanUpUnusedStorage`, same vectors), only on storage with atomic conditional writes | Parity |
| Direct browser→S3 sync, without a server | Syncs straight to S3 | — (deferred: needs the connect wizard and the sealed key vault, plan Tasks 3.9, 4.8, 5.3) | Web gap |
| Sync Now (`syncNow`), Lock (`lock`) | Automatic; no app lock | Commands | Web-only |
| Server accounts, invites, access keys, users | — | Yes | Web-only |
| Server keeps the stores in an S3 bucket (`NOTEIT_STORE=s3`) | — | Yes | Web-only |
| Settings (`settings`) | ⌘, | ⌘, | Parity |
| Menu shortcut editor | Settings › Shortcuts | Settings › Shortcuts: the same commands and conflict rules, kept per browser in localStorage (the Mac keeps its own locally) | Parity |
| Light and dark appearance | System | System, light or dark | Parity |
| Welcome guide (`showWelcome`) | Yes | Setup wizard for the server | Native-only by design (it walks through hotkeys, menu bar and import) |
| Markdown library (notes as `.md` files in a folder) | Yes | — | Native-only by design (local files) |
| Spotlight | Yes | — | Native-only by design |
| Shortcuts actions, Siri, `noteit://` URL scheme | Yes | `noteit://note` links open in the web app only from inside it | Native-only by design |
| Local API, `noteit` command line tool (`localAPIOn`, `localAPIOff`, `installCLI`, `integrationsSettings`) | Yes | The server's S3 endpoint for sync clients | Native-only by design |
| Open at login, Sparkle updates | Yes | — | Native-only by design |

## Summary

As of this page's last change, by row: 61 parity, 1 web gap (direct browser→S3 sync), 1 planned (locked notes, on both apps), 12 native-only by design, 4 native-only (local data), 4 web-only. Smaller differences noted in Parity rows: choosing a notebook's default template, the caret at `{{cursor}}`, heading suggestions after `[[Title#`, the tag list drawn as a tree, Undo for a tag rename, and PDF, RTFD and plain text folder exports.
