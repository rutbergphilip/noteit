# Roadmap

NoteIt aims to be the fastest notes app on the Mac, and one where you own every byte. This roadmap shows the order we plan to build things in. It isn't a promise of dates.

## Now: trust and switching

- [x] **Recently Deleted.** Deleted notes stay recoverable for 30 days.
- [x] **Version history.** Restore any earlier version of a note.
- [x] **Export, print and Share.** Markdown, HTML, PDF, RTFD and plain text, per note, per notebook or everything.
- [x] **Import.** Apple Notes, Bear, Obsidian and Markdown folders.

Design: [`specs/2026-10-14-trash-export-import-design.md`](specs/2026-10-14-trash-export-import-design.md)

## Next: fastest capture

- [x] **Command palette.** Open notes, run commands and move between notebooks without a mouse.
- [x] **Capture from any app.** Select text anywhere, press a hotkey, and it's saved with a link back to where it came from.

Design: [`specs/2026-10-15-command-palette-design.md`](specs/2026-10-15-command-palette-design.md)

Design: [`specs/2026-10-15-capture-from-any-app-design.md`](specs/2026-10-15-capture-from-any-app-design.md)

## Also shipped

- [x] **Snippets.** Copy a code block or command with one click, with syntax highlighting.

## Program: what comes next

Everything still to build is now one program of sub-projects, delivered in waves. Each sub-project has its own design and plan, and each milestone ships on its own and leaves the app working.

Program design: [`specs/2026-10-19-program-design.md`](specs/2026-10-19-program-design.md)

Foundations plan: [`plans/2026-10-19-foundations.md`](plans/2026-10-19-foundations.md)

### Wave 0: foundations

- [x] **Foundations.** Shared groundwork the later waves build on. You'll notice only two changes: the General settings tab scrolls, and Restore Version in an open note can be undone in one step ([design](specs/2026-10-19-program-design.md), [plan](plans/2026-10-19-foundations.md)).

### Wave 1

These can be built in parallel once wave 0 is done.

- [ ] **Automation.** Links that create and open notes, Shortcuts actions, notes in Spotlight, Share to NoteIt from any app, a `noteit` command for the terminal and a local API ([spec](specs/2026-10-19-automation-design.md), [plan](plans/2026-10-19-automation.md)).
- [ ] **Markdown storage.** Keep your library as a folder of plain Markdown files, with one-click and automatic backups, restore checks, and importers for Evernote and Notion ([spec](specs/2026-10-19-markdown-storage-design.md), [plan](plans/2026-10-19-markdown-storage.md)).
- [x] **Linking.** Link notes with `[[`, see backlinks and unlinked mentions, keep link text up to date when a note is renamed, open today's note with one key or from a calendar, start notes from templates and jump between headings ([spec](specs/2026-10-19-linking-design.md), [plan](plans/2026-10-19-linking.md)).
- [x] **Organise.** Nested tags and notebooks, renaming and merging tags, smart folders, ranked search with highlighted matches, one list of every checkbox with due dates, and reminders in plain words, so "Call the dentist tomorrow 9am" becomes a notification ([spec](specs/2026-10-19-organise-design.md), [plan](plans/2026-10-19-organise.md)).

### Wave 2

- [ ] **More capture.** Turn text on the screen into a note, record and transcribe voice notes, add a quick line to today's note, and save email from a mailbox you own, all recognised on your Mac ([spec](specs/2026-10-19-capture-plus-design.md), [plan](plans/2026-10-19-capture-plus.md)).
- [ ] **Private smart features.** Find notes by meaning, ask questions answered from your own notes, and get summaries and suggested titles and tags, all on your Mac and off by default ([spec](specs/2026-10-19-private-ai-design.md), [plan](plans/2026-10-19-private-ai.md)).
- [ ] **Web clipper.** Save an article, a selection, a whole page, a screenshot or a bookmark from Safari, Chrome, Edge, Brave or Firefox straight into NoteIt ([spec](specs/2026-10-19-web-clipper-design.md), [plan](plans/2026-10-19-web-clipper.md)).
- [ ] **Sync and security.** Sync through WebDAV servers such as Nextcloud, compare conflicts side by side, change your passphrase or turn on encryption later, and see every network connection the app can make. Locked notes come in wave 3 ([spec](specs/2026-10-19-sync-security-design.md), [plan](plans/2026-10-19-sync-security.md)).
- [ ] **Surfaces and polish.** Cheat sheets on a hotkey, floating notes, a board view of a notebook, better checklists and typography, a first-run guide, a VoiceOver pass and published performance numbers ([spec](specs/2026-10-19-surfaces-polish-design.md), [plan](plans/2026-10-19-surfaces-polish.md)).

### Wave 3

- [ ] **Web app.** A self-hostable web app that syncs with the Mac app and also works as an installable iPhone app ([spec](specs/2026-10-13-web-app-design.md), [plan](plans/2026-10-13-web-app.md)).
- [ ] **Locked notes.** Encrypt single notes with a notes password and unlock them with Touch ID, in both library formats (part of [sync and security](specs/2026-10-19-sync-security-design.md) and [Markdown storage](specs/2026-10-19-markdown-storage-design.md)).
- [ ] **iPhone and iPad.** A native app that starts with fast capture and grows into reading, search and editing, synced through your own storage ([spec](specs/2026-10-19-mobile-design.md), [plan](plans/2026-10-19-mobile.md)).
- [ ] **Sharing.** Send one note as an encrypted link, publish a notebook as a static website, and share a notebook with other people ([spec](specs/2026-10-19-sharing-design.md), [plan](plans/2026-10-19-sharing.md)).
- [ ] **Plugins.** Small JavaScript plugins that add commands, change note text and show inspector panels, limited to what you approve ([spec](specs/2026-10-19-plugins-design.md), [plan](plans/2026-10-19-plugins.md)).

### Alongside the waves

- [ ] **Growth.** A website, a public roadmap with voting, a Homebrew cask and help for new contributors. The public launch follows the first release with all of wave 1 ([spec](specs/2026-10-19-growth-design.md), [plan](plans/2026-10-19-growth.md)).
