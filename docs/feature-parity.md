# Feature parity: Mac app and web app

NoteIt runs as a native Mac app and as a self-hosted web app that opens the same end-to-end encrypted store. Every user-facing feature should exist on both, or be listed here with the reason it doesn't. The rule and how to keep this page current are in [CONTRIBUTING.md](../CONTRIBUTING.md#feature-parity).

Statuses:

- **Parity**: both have it, reading and writing the same data.
- **Web gap**: the web app should have it and doesn't yet.
- **Native-only by design**: a browser can't do it (global hotkeys, the menu bar, Finder, AppleScript and Shortcuts, local files). The *web equivalent* column says what comes closest.
- **Native-only (local data)**: the Mac keeps this data on the Mac only; it isn't synced, so the web can't show the Mac's copy.
- **Web-only**: the web app has it and the Mac app doesn't need it.

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
| Code blocks with syntax colouring | Yes | Plain code blocks | Web gap |
| Bigger/smaller text (⌘+ ⌘−), alignment, clear formatting | Yes | Shown, not settable | Web gap |
| Paste Markdown as formatting, Paste and Match Style | Yes | Yes: the same "clearly Markdown" rules and reader (the Mac's Markdown fixtures); ⇧⌘V pastes plain text | Parity |
| Find and replace in a note (`find`, `findReplace`) | ⌥⌘F, ⇧⌘F | ⌥⌘F, ⇧⌘F: Match Case, Whole Word, regex with `$1`, ⌘G/⇧⌘G, ⌘E, one ⌘Z per replace | Parity |
| Pin and unpin (`togglePin`) | Yes | Yes | Parity |
| Notebooks: create, rename, colour, symbol (`newNotebook`) | ⇧⌘N | ⌥⇧⌘B (⇧⌘N where the browser allows it) | Parity |
| Nested notebooks | Drag, Move To | Create inside, shown nested; moving a notebook is a web gap | Parity |
| Move a note to a notebook (`move.<notebook>`) | Palette, menu | Notebook picker in the editor | Parity |
| A notebook's default template for new notes | Notebook settings | Used for new notes; choosing one is a web gap | Parity |
| Recently Deleted, recover, delete now, 30-day purge (`deleteNote`, `showRecentlyDeleted`) | ⌘⌫ | ⌘⌫ outside text, toolbar | Parity |
| Undo a deletion | ⌘Z | Recover from Recently Deleted | Web gap |
| Conflict copies | Yes | Yes, with the same notice | Parity |
| Locked notes | Lock and unlock | Listed by title, read-only | Web gap |
| Notes from older Macs (RTFD bodies) | Yes | Listed, read-only until a Mac converts them | Native-only by design |
| Version history (`versionHistory`) | ⌥⌘Y | — | Native-only (local data): versions stay on the Mac that saved them |
| Note list sorting | Date edited; Best Match while searching | Edited, created or title | Web-only (the extra orders); Best Match is a web gap |

## Tags, search and smart folders

| Feature | Mac | Web | Status |
|---|---|---|---|
| `#tags` and nested `#tags/sub` in note text | Yes | Yes, the same parser (shared vectors) | Parity |
| Tag list in the sidebar, choosing a tag shows its children's notes | Tree | Chips; nesting is matched but not drawn as a tree | Parity |
| Tag suggestions after `#` | Yes | — | Web gap |
| Rename, merge and delete tags everywhere | Yes | Right-click a tag: the same rewrite rules (nested tags, code and links left alone) and smart folder searches renamed; no Undo | Parity |
| Search: words, "phrases", `-word`, `OR`, brackets (`searchNotes`) | ⌘F | ⌘F; the same parser and evaluator (shared vectors) | Parity |
| Search filters `tag:` `notebook:`/`in:` `title:` `is:` `has:` `edited:` `created:` `due:` | Yes | Yes, with a warning for a filter it can't read | Parity |
| Search ranking, snippets and highlights in the note | Yes | Matching notes in edit order | Web gap |
| Text in images found by search | Yes | — | Native-only by design (macOS text recognition) |
| Smart folders (`newSmartFolder`, `saveSearchAsSmartFolder`) | Yes, synced | Yes: the same synced `smart-folders/` records (shared envelope vectors), in the sidebar and the palette | Parity |

## Linking, outline and note info

| Feature | Mac | Web | Status |
|---|---|---|---|
| `noteit://note` links between notes | Yes | Yes; clicking one opens the note, or creates it for a link by title | Parity |
| `[[` note suggestions, `[[Title]]` as you type, Link to Note… (`linkToNote`, ⇧⌘K) | Yes | Yes: the same title resolution and link URLs; headings after `#` aren't suggested | Parity |
| Backlinks and links in this note (`showBacklinks`) | ⌥⌘I | ⌥⌘I, Links tab | Parity |
| Unlinked mentions | Yes | Yes, in the Links tab: the same matching rules, Link and Link All | Parity |
| Update links on rename | Yes | — (links by id keep working; links by title aren't rewritten when a note is renamed on the web) | Web gap |
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
| Tasks view (`showTasks`) | ⇧⌘T | ⌥⇧⌘T (⇧⌘T where the browser allows it); check off there | Parity |
| Show completed tasks (`showCompletedTasks`) | Yes | Completed switch in Tasks | Parity |
| `@due(…)` dates, Set Due Date… (`setDueDate`), natural dates such as `@due(fri)` | ⇧⌘D | ⇧⌘D picker; `@due(fri)`, `@remind(tomorrow 9am)` become dates on `)` with the same parser (shared vectors). Long forms only the Mac's data detector reads, such as "October 21", stay as typed | Parity |
| Reminders: `@remind(…)` notifications (`addReminder`) | ⌃⌘R, notifications | ⌃⌘R; browser notifications (Settings › General) while NoteIt is open in a tab, else a notice in the app. Claims in the same `claims/reminders/` format (shared vectors), so only one device rings | Parity |

## Capture, import and export

| Feature | Mac | Web | Status |
|---|---|---|---|
| Quick Capture | Global hotkey, menu bar | ⌥⌘C in the app (`quickCapture`) | Parity |
| Quick Capture offers a reminder for a dated first line | Yes | — | Web gap |
| Capture Selection, Services › Capture to NoteIt | Yes | Install the web app (PWA) and share to it is a possible equivalent | Native-only by design |
| Menu bar panel | Yes | — | Native-only by design |
| Global hotkeys | Yes | — (browsers can't take system-wide keys) | Native-only by design |
| Export Note as Markdown (`export`) | ⇧⌘S | ⇧⌘S; the same writer rules (checked against the Mac's Markdown fixtures) | Parity |
| Export as HTML (`exportHTML`) | Yes | Yes, self-contained | Parity |
| Print, Save as PDF (`print`) | ⌘P | ⌘P, the browser's print dialog | Parity |
| Copy as Markdown (`copyMarkdown`) | ⌥⇧⌘C | ⌥⇧⌘C (whole note) | Parity |
| Export a notebook or everything as folders | Yes | One note at a time | Web gap |
| Import Markdown and text files, or a folder such as an Obsidian vault (`import`, `importFolder`) | Yes | Yes: the same reader, titles, front matter dates and tags, folders as nested notebooks, images from the chosen files. `[[links]]` to notes in the same import link by title | Parity |
| Import Evernote (.enex), Notion, TextBundle | Yes | — (the Mac's importers aren't ported; about a day each) | Web gap |
| Import from Apple Notes | Yes | — | Native-only by design (reads the Mac's Notes database) |
| Import ledger (no duplicates on re-import) | Yes | — | Native-only (local data) |

## Sync, security and settings

| Feature | Mac | Web | Status |
|---|---|---|---|
| End-to-end encrypted sync, same store | iCloud, folder, S3, NoteIt Server | NoteIt Server (its own) | Parity |
| Passphrase change, re-key, devices list | Yes | Yes | Parity |
| Clean Up Unused Storage… | Yes | Server-side storage | Native-only by design |
| Sync Now (`syncNow`), Lock (`lock`) | Automatic; app lock via locked notes | Commands | Web-only |
| Server accounts, invites, access keys, users | — | Yes | Web-only |
| Settings (`settings`) | ⌘, | ⌘, | Parity |
| Menu shortcut editor | Settings › Shortcuts | Fixed shortcuts | Web gap |
| Light and dark appearance | System | System, light or dark | Parity |
| Welcome guide (`showWelcome`) | Yes | Setup wizard for the server | Native-only by design (it walks through hotkeys, menu bar and import) |
| Markdown library (notes as `.md` files in a folder) | Yes | — | Native-only by design (local files) |
| Spotlight | Yes | — | Native-only by design |
| Shortcuts actions, Siri, `noteit://` URL scheme | Yes | `noteit://note` links open in the web app only from inside it | Native-only by design |
| Local API, `noteit` command line tool (`localAPIOn`, `localAPIOff`, `installCLI`, `integrationsSettings`) | Yes | The server's S3 endpoint for sync clients | Native-only by design |
| Open at login, Sparkle updates | Yes | — | Native-only by design |

## Summary

As of this page's last change, by row: 36 parity, 20 web gaps, 13 native-only by design, 4 native-only (local data), 3 web-only. Highest-value web gaps, roughly in order: smart folders (needs the `smart-folders/` record kind in `@noteit/core`, with golden vectors), reminders with notifications and claims, `[[` link suggestions, tag rename/merge/delete, find and replace, Markdown import, natural due dates and the date picker, locked notes.
