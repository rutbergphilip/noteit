# Changelog

All notable changes to NoteIt are listed here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- A portable note format for sync, so the upcoming NoteIt web app can open your notes. The first time this version syncs, it switches your storage over and converts your notes in the background; there's nothing to set up. If another Mac still runs an older NoteIt, it asks you first, because that Mac stops syncing until it's updated. Nothing on it is lost. Each of your devices downloads every note once while this happens.
- A “NoteIt Server” choice when you set up sync, for syncing with your own NoteIt web app.
- Clean Up Unused Storage… in Settings › Sync removes leftover copies of notes that were never finished saving, for example from a Mac that was erased while it was syncing. It's available on storage that supports conditional writes, and it asks first.
- A short first-run guide. On a fresh library NoteIt opens a Welcome window that asks whether you are new or already use NoteIt on another Mac, then walks through recording hotkeys, the menu bar icon, importing notes and sync. Skip it any time; Help › Welcome to NoteIt… and the command palette open it again.
- A waiting Quick Capture draft now shows. While a draft is kept after you dismiss the panel, the menu bar icon gets a small dot and the menu bar panel shows a *Quick Capture draft waiting* row with a Resume button.
- Importing twice no longer makes duplicates. NoteIt remembers what each import made, by the source note's file path or id and a fingerprint of its content. Notes that are already in NoteIt are left alone and counted in the summary. A note whose source has changed since is imported again as a new note, so nothing you edited in NoteIt is overwritten. The memory is kept on this Mac only.
- Note info. The Links and Outline panel has a new Info tab with the note's word count, character count, reading time, created and last edited dates, notebook and tags. Counts update as you type. Show it with Show Note Info in the View menu (⌃⌘I) or from the command palette.
- The NoteIt web app searches with the same filters as the Mac: `tag:`, `notebook:`, `is:todo`, `has:due`, `due:today`, dates, `OR`, `-word` and "phrases". A filter it can't read shows a warning and is searched as a word.
- Tasks in the web app (⇧⌘T, or ⌥⇧⌘T where the browser keeps ⇧⌘T): checklist items from all your notes, grouped by due date, to check off or open.
- Templates and daily notes in the web app: New Note from Template…, Insert Template… and New Template use your Templates notebook and fill in `{{title}}`, `{{date}}`, `{{time}}` and `{{clipboard}}`; a notebook's default template starts its new notes; Today in the sidebar (⌃⌘T) opens the same daily note as your Mac.
- Links and Outline in the web app (⌥⌘I): notes that link here, links in this note, headings, and a Note Info tab (⌃⌘I) with the same word and character counts as the Mac. Clicking a link to a note opens it.
- Export from the web app as Markdown (⇧⌘S) or HTML, print or save as PDF (⌘P), Copy as Markdown and Copy Note Link. Markdown export writes links between notes as `[[wiki links]]`, as the Mac does.
- The web app's command palette and keyboard shortcuts follow the Mac's menus, with Ctrl in place of ⌘ off a Mac; type `>` in the palette for commands only.
- A [feature parity](docs/feature-parity.md) page lists every feature of the Mac and web apps and where each stands.
- Smart folders in the web app: New Smart Folder… and Save Search as Smart Folder… make a saved search in the sidebar, and smart folders made on a Mac show up on the web and the other way round.
- Note links as you type in the web app: `[[` lists your notes as you type, `[[Title]]`, `[[Title#Heading]]` and `[[Title|text]]` become links as on the Mac, and Link to Note… (⇧⌘K) starts one.
- Import Markdown in the web app: choose `.md` or `.txt` files, or a whole folder such as an Obsidian vault. Titles, front matter dates and tags, and images come in as on the Mac, and subfolders become nested notebooks.
- Rename, merge and delete tags in the web app: right-click a tag in the sidebar. Tags inside it change too, and smart folder searches follow a rename.
- Find and replace in a note in the web app (⌥⌘F, ⇧⌘F), with Match Case, Whole Word and regular expressions, as on the Mac. ⌘E now uses the selection for find, and inline code is ⇧⌘E, as on the Mac.
- Due dates in the web app: Set Due Date… (⇧⌘D) for a checklist item, and `@due(fri)`, `@due(+3d)` or `@remind(tomorrow 9am)` turn into full dates as you type the `)`, as on the Mac.
- Reminders ring in the web app while it's open in a tab, as a browser notification once you allow it in Settings › General. Like the Mac it claims each reminder first, so only one of your devices rings. Add Reminder… (⌃⌘R) is there too.
- In the web app: Go Back and Go Forward (⌃⌘← ⌃⌘→) between the notes you opened, Daily Note for Date… with ‹ › on a daily note to the days around it, and Unlinked Mentions in the Links tab, with Link and Link All.
- Searching for words in the web app lists the best matches first, ranked as on the Mac.
- Pasting Markdown in the web app brings it in formatted, by the same rules as the Mac: only text that's clearly Markdown source, never inside a code block, and ⇧⌘V pastes plain text.

### Changed

- Saving a note to sync is now crash-safe: a note's new text is uploaded completely before other devices are pointed at it, so they never see half a save.
- On S3 storage, a request that could change data is never sent twice automatically. A dropped connection is sorted out on the next sync instead.
- On storage that can't delete conditionally (sync folders and some S3 providers), NoteIt checks that a note is unchanged right before deleting it, and leaves anything another device changed meanwhile.
- In the NoteIt web app, server setup, sign-in, invites, passwords and user management now run as type-checked server actions built with nuxt-safe-action. Forms point at the field that needs fixing, often before anything is sent, and lists such as your access keys and the server's users refresh by themselves after a change. Sync is unchanged.
- Text colours and highlights picked in the web app are now the same swatches as the Mac's Format menu, and the web app has the Mac's paragraph shortcuts (⌥⌘4 and ⌥⌘5, ⇧⌘7, ⇧⌘8, ⇧⌘L, ⇧⌘U, ⇧⌘H, ⌥⇧⌘D, ⌘[ and ⌘]). Inline code is ⇧⌘E, as on the Mac; ⌘E still works.
- The NoteIt web app is rebuilt on Nuxt UI, keeping its look. Dialogs, menus and the command palette handle the keyboard, focus and Escape consistently and animate in and out. Notes and notebooks have right-click menus, buttons show when they're working, confirmations are in-app dialogs instead of browser pop-ups, the sidebar and note list can be resized, and Settings opens over your notes.

### Fixed

- Two tabs of the NoteIt web app editing the same note no longer lose an edit. Tabs see each other's saves straight away, and a save made from an older version keeps the other version as a conflict copy, as the Mac does when a note changes on two devices at once.
- In the web app, a note edited less than a second before a reload or a closed tab is saved; the browser asks you to stay while the save finishes. Reloading also opens faster.
- Confirmation dialogs in the web app, such as Delete Notebook and Delete Now, open again after you cancel one.
- In the web app, Tab and ⇧Tab indent and outdent list items and move between table cells (Tab in the last cell adds a row), and a new table starts with the cursor in its first cell. Focus no longer jumps out of the note.
- The web app's Markdown shortcuts now match the Mac's: `>`, `+`, `1)`, ```` ``` ```` with a language, `---` then Return, and `**bold**`, `*italic*`, `` `code` `` and `~~strike~~` as you type. One ⌘Z gives back what you typed.
- Quick Capture in the web app opens on the title, and Return in the title moves to the note.
- A new web account, or a reload in the middle of setup, goes straight to choosing an encryption passphrase instead of asking to unlock a library that doesn't exist yet.
- The web app's command palette matches and ranks like the Mac's, so `gn` finds *Grocery Notes*, and *New Note “…”* comes after every match.
- In the web app's Settings, a new S3 secret is shown only once, revoking a key asks first, the Users list shows a renamed account's new name, and this browser's last sync time matches the header.
- An invite link opened in a web app tab that's already open is no longer ignored.
- Moving a note to Recently Deleted in the web app can be undone from the notice. A forced password change no longer asks again for the temporary password you just used. New Notebook in the sidebar makes a top-level notebook, and Edit Notebook can move a notebook inside another.
- Notebooks made at the top level in the web app now record that they're top level, as the Mac does, so moving a notebook out of another on the web reaches your Mac.
- New Note from Template… run while the Templates notebook is open no longer makes another template, on the Mac and the web: the note goes in no notebook and All Notes opens.
- In the web app, typing in the search box while Tasks is open filters the tasks, as the Mac's Search Tasks does. Tasks rows are keyboard-navigable: ↑ and ↓ select, Space checks, and Return or a double-click opens the note; a single click shows it beside the list. Tasks in the Templates notebook are left out, as on the Mac.

### Security

- Information that another device stores with a note's text can no longer change the note's own details, such as its dates or whether it's pinned, in a Markdown library.

## [0.6.2] - 2026-10-23

### Changed

- The first published build of 0.6.0 and 0.6.1, which were tagged but never released. It brings everything listed under 0.6.0: importing from Evernote and Notion, `noteit://` links, the Local API and `noteit` command line tool, Spotlight and Shortcuts, links between notes, daily notes, templates, nested notebooks and tags, smart folders, search filters, Tasks and reminders.

## [0.6.1] - 2026-10-23

### Changed

- The first published build of 0.6.0, which was tagged but never released. It brings everything listed under 0.6.0: importing from Evernote and Notion, `noteit://` links, the Local API and `noteit` command line tool, Spotlight and Shortcuts, links between notes, daily notes, templates, nested notebooks and tags, smart folders, search filters, Tasks and reminders.

## [0.6.0] - 2026-10-23

### Added

- Import from Evernote. Choose one or more `.enex` files, or a folder of them, in File › Import…. Each file becomes a new notebook and folders become notebooks around them; a name already in use gets a number, such as “Work 2”. Notes keep their dates, tags, checklists, images and attachments, reminders and links to each other.
- Import from Notion. Choose the `.zip` from Notion's Export › Markdown & CSV in File › Import…. Pages keep their images and links to each other, subpages go into a new notebook named after their top page (a name already in use gets a number, such as “Projects 2”), and databases become tables.
- `noteit://` links. Open a note, search, or create and add to notes from Shortcuts, Raycast, Alfred, scripts and web pages. Links that create or add to a note ask first; you can turn that off in Settings › Integrations.
- Copy Note Link (⌃⌘L) in the Edit menu copies a link to the current note.
- Local API. Turn on Allow apps on this Mac to use NoteIt in Settings › Integrations, and scripts, command line tools and browser extensions on this Mac can read and change your notes. Apps pair with a code that NoteIt shows, and the same settings list every connected app so you can revoke one, or make a token for your own scripts. The command palette has Turn Local API On and Off.
- The `noteit` command line tool. Create, append to, list, search, show, edit and delete notes from Terminal and your scripts, with `--json` for machine-readable output. Install it from Settings › Integrations or with Install Command Line Tool… in the command palette, then run `noteit auth login` and enter the code NoteIt shows. Installing it also sets up tab completion for zsh, bash and fish, including note ids, notebooks and tags while NoteIt is running; zsh needs `autoload -Uz compinit && compinit` in `~/.zshrc` and bash needs bash-completion 2; `noteit help completion` has the details.
- Spotlight. Your notes now show up in Spotlight by title and text, and choosing one opens it in NoteIt. Notes in Recently Deleted and locked notes stay out. You can leave out the note text, rebuild the index or turn it off in Settings › Integrations.
- Shortcuts actions. Create Note, Append to Note, Open Note, Find Notes and Get Note Text are in the Shortcuts app, and you can say “Create a note in NoteIt”, “Search NoteIt” or “Add to a note in NoteIt” to Siri.
- Daily notes from scripts and Shortcuts. `noteit today` prints today's daily note or adds a line to it, as does `noteit append --today`, and there's an Append to Daily Note action in Shortcuts, `noteit://daily` links and Local API routes for it. Lines are added with the time, and a new daily note starts from your daily note template.
- Links between notes. Type `[[` to pick a note, or one of its headings after `#`, and press ↩ to link it. Edit › Link to Note… (⇧⌘K) links the selected text. Clicking a link to a note that doesn't exist yet creates it.
- Links and Outline (⌥⌘I). See the notes that link to the open note, with a line of context, the links in it, mentions of its title that aren't links yet (link them with one click) and its headings. Go Back and Go Forward (⌃⌘← and ⌃⌘→) move through the notes you've opened.
- When you rename a note, NoteIt offers to update the text of the links to it, and you can undo it.
- Daily notes. Open Today's Note (⌃⌘T), the Today row in the sidebar, or an optional global hotkey open today's note, creating it in a Daily Notes notebook the first time. File › Daily Note for Date… opens a calendar, and ‹ › in a daily note's header go to the day before and after. Choose the notebook, title format and template in Settings › Editor.
- Templates. Notes in the Templates notebook can start new notes with New Note from Template… (⌥⌘N) or be added to the open note with Edit › Insert Template…. Templates can fill in the date, time, title and clipboard and place the cursor, and each notebook can have a default template for its new notes.
- Markdown export keeps links between notes as `[[wiki links]]`, and importing a folder of Markdown files or an Obsidian vault turns `[[wiki links]]` back into links.
- The Local API can list a note's backlinks, links and outline, list templates and create a note from a template.
- Nested notebooks. Put notebooks inside other notebooks by dragging them in the sidebar, with Move To, or by choosing where it goes in the notebook's settings. A notebook shows the notes of the notebooks inside it. Exporting a nested notebook as Markdown makes matching folders, and importing a folder of Markdown files keeps its subfolders as nested notebooks.
- Nested tags. Write `#work/clients` and the sidebar shows clients under work; choosing a tag shows the notes of the tags under it too. Tags show as chips in the note list, and typing `#` suggests the tags you already use.
- Rename, merge and delete tags from the sidebar. NoteIt changes the tag in every note that has it and you can undo it.
- Smart folders. Save a search as a smart folder (New Smart Folder… or Save Search as Smart Folder…) and it stays in the sidebar, up to date, on every Mac you sync with.
- Search filters. Narrow a search with `tag:`, `notebook:`, `is:todo`, `is:done`, `is:pinned`, `has:attachment`, `due:today`, dates and more, combine them with `OR`, leave words out with `-` and search exact phrases with quotes.
- Tasks (⇧⌘T). See the checklist items from all your notes in one place, grouped into Overdue, Today, Upcoming, Later and No Date. Check them off there or jump to the note. Give an item a due date with Set Due Date… (⇧⌘D) or by writing `@due(2026-10-24)`.
- Reminders. Add Reminder… (⌃⌘R) or `@remind(2026-10-24 09:00)` in a note gives you a notification at that time. When you sync several Macs, only one of them shows it.
- Quick Capture offers to remind you when the first line has a date, such as "Call the bank tomorrow".
- Clicking a reminder in a note lets you mark it done. The first reminder you add offers to open NoteIt at login, since reminders only ring while NoteIt is running.
- The Tasks view tells you when notifications are off for NoteIt, with a button to open System Settings.
- The Local API can rename, merge and delete tags, move notebooks, list and change smart folders, and list, check off and set due dates for tasks.

### Changed

- Links and Outline explains itself: each section says what it lists and how to fill it (type `[[` to link a note), the section titles and buttons have tooltips, and found unlinked mentions say that Link turns them into links.
- New libraries start with a refreshed welcome note, and no longer include a sample shortcuts note or Shortcuts notebook.
- Search puts the best matches first, shows a line of matching text under each note and highlights the words you searched for in the list and in the open note. While searching, the sort menu switches between Best Match and Date Edited.
- Local API search ranks its results like the app does and reports where each one matched, and a notebook filter includes the notebooks inside it.

### Fixed

- Sidebar icons turn white on the selected row, so a notebook icon in a colour close to the selection colour (such as a blue notebook) stays visible, including notebooks inside other notebooks, tags and smart folders.
- With no note open, the editor is now simply blank instead of repeating the note list's “No Notes Yet” and New Note button.
- Going from Tasks to a notebook, tag or other list no longer leaves a note from elsewhere open; the first note in the list opens instead.
- A notebook with notebooks inside it now says so under its title (“including nested notebooks”), and notes from those inner notebooks show which notebook they're in.
- HTML export in Dark Mode no longer gives captured text, or notes made in Open Quickly, a fixed colour that could come out near-white.
- NoteIt no longer freezes when a sync folder on a NAS or network drive becomes unreachable. Sync shows “Can't reach” the folder and picks up again when it's back, and notes on this Mac are never removed because the folder couldn't be read.

## [0.5.0] - 2026-10-20

### Added

- Paste Markdown. Copy Markdown from a code editor, a terminal or a `.md` file and ⌘V adds it as formatted text: headings, lists, checklists, code, links, quotes and more. Code, diffs and text copied with formatting from web pages and other apps come in as before.

### Changed

- Paste and Match Style is now ⇧⌘V, and ⌥⇧⌘V still works. It pastes just the text, in the style where you paste it. If you've bound ⇧⌘V yourself, your shortcut keeps it and Paste and Match Style stays on ⌥⇧⌘V.

### Fixed

- A code block at the top of a note is no longer cut off.
- Upgrading two Macs at the same time could undo edits made on the first one right after the upgrade.

## [0.4.0] - 2026-10-20

### Changed

- Synced notes are now stored in a `noteit` folder in your sync folder or bucket instead of `inkwell`. The first time a Mac on this version connects, it copies the existing `inkwell` store over, still encrypted, and leaves the old folder in place. Update every Mac that syncs: Macs on an older version keep syncing with the old `inkwell` folder only. Once all of them are updated, you can delete the `inkwell` folder and the `.inkwell-lock` file.

### Fixed

- Notes in the list no longer show up squashed to a single clipped line after sync changes them.
- Note previews no longer show invisible control characters from pasted text.

## [0.3.0] - 2026-10-19

### Added

- Open Quickly. File › Open Quickly… (⌘O) finds notes, notebooks and commands as you type. Letters don't need to be next to each other, so "gn" finds "Grocery Notes". With nothing typed it shows your 10 most recently edited notes, and the last row creates a new note with the title you typed.
- Command palette. File › Command Palette… (⇧⌘P), or typing `>` in Open Quickly, lists only the commands you can use right now, each with its shortcut. It includes moving the open note to another notebook.
- Change the shortcuts for New Note, New Notebook…, Open Quickly…, Command Palette…, Search Notes, Find…, Find and Replace…, Export Note As…, Print…, Copy as Markdown, Version History… and Delete Note in Settings › Shortcuts › In NoteIt. The menus and the command palette use the new keys right away, and Restore Defaults puts them all back.
- Global hotkeys for Open Quickly and Command Palette. From any app they open the palette over what you're doing, and Esc takes you back.
- Capture from any app. Select text anywhere and press the Capture Selection hotkey, and NoteIt saves it as a note without leaving the app you're in. The note is titled after the page or window and links back to where the text came from, including the page in Safari and Chrome-based browsers. Reading the selection needs Accessibility permission, which you can allow in Settings › General › Capture.
- Capture to NoteIt in the Services menu saves the selected text as a note from any app, without Accessibility permission.

### Fixed

- A new list item keeps the text size of the one above it, including the checkbox, before you start typing.
- Lines that move up after you delete a line no longer disappear for a moment.
- Pressing Return with text selected in a list item now starts a new list item.
- Pressing Return on a list item that only has spaces in it ends the list, like an empty item does.

## [0.2.0] - 2026-10-15

### Added

- Recently Deleted. Deleted notes stay there for 30 days and can be recovered. ⌘Z undoes a delete.
- Version history. File › Version History… (⌥⌘Y) shows earlier versions of a note and can restore one. Versions stay on the Mac that recorded them.
- Export a note, a notebook or all notes as Markdown, HTML, PDF, RTFD or plain text. Notes in Recently Deleted are left out.
- Print a note (⌘P), share it from the toolbar or File › Share, or copy it as Markdown (⌥⇧⌘C).
- Import from Apple Notes, Bear, Obsidian and Markdown folders with File › Import…, keeping folders, images and dates.
- Find and replace in a note. ⌥⌘F opens a find bar and ⇧⌘F opens it with replace. It shows how many matches there are, highlights them all, and can match case, whole words or regular expressions. Replacements keep the text's formatting, and each one can be undone with ⌘Z.
- Code blocks have a language. Pick it from the label in the block's top-right corner, or type ```` ```swift ```` and Space. Automatic guesses the language from the code.
- Syntax highlighting in code blocks, with Xcode, GitHub, Solarized and Nord themes in light and dark.
- A copy button on code blocks, shown when you hover over them.
- Settings › Editor › Code: inline code color and font, code block theme, syntax highlighting on or off, and a live preview.
- Markdown export writes the code block language after the opening ```` ``` ````, Markdown import reads it, and HTML export keeps code looking like it does in the editor, with syntax colors and inline code pills in your chosen theme and color.

### Changed

- Inline code looks like a rounded, tinted pill, and code blocks are rounded cards.

### Fixed

- Note text now rewraps to use the extra room when the window or editor gets wider, instead of staying in a narrow centered column. Very wide editors still keep it centered at a comfortable reading width.
- Showing and hiding the sidebar is smooth. The formatting bar no longer measures itself over and over while the editor resizes, and note text rewraps once when the animation ends instead of on every frame.

## [0.1.0] - 2026-10-14

### Added

- Rich-text notes, saved automatically as RTFD files in `~/Library/Application Support/NoteIt`.
- Notebooks with a color and an icon. Drag to reorder them, and drop notes onto one to move them.
- `#hashtag` tags, plus Pinned and Recent (last 7 days) views.
- Search across titles and note text that ignores case and accents.
- Formatting: headings, bold, italic, underline, strikethrough, inline code, text colors and highlights, bulleted, numbered and checklist lists, tables, code blocks, quotes, dividers, links and images.
- Markdown shortcuts as you type, such as `#`, `-`, `[ ]`, `>` and `**bold**`.
- About 30 keyboard shortcuts, listed in the [shortcut reference](https://github.com/rutbergphilip/noteit/blob/main/docs/keyboard-shortcuts.md).
- Quick Capture, a panel that opens over any app, including full-screen ones, and keeps your draft when you close it.
- Global hotkeys for Show/Hide NoteIt, New Note and Quick Capture. You record your own in Settings › Shortcuts, and they need no Accessibility permission.
- A menu bar panel with search, a quick-note field, and pinned and recent notes, plus a Menu bar only mode and Launch at login.
- Optional sync between Macs through a folder (a NAS share, iCloud Drive, Dropbox or a USB drive) or an S3-compatible bucket: Amazon S3, Cloudflare R2, Backblaze B2, Google Cloud Storage, MinIO or another S3 service.
- End-to-end encryption for synced notes, on by default. The passphrase stays in your Keychain and is never uploaded.
- When a note is edited on two Macs before they sync, the other version is kept as a conflict copy. Conflict copies are listed under a Conflicts filter and can be marked as resolved.
- Signed and notarized downloads.
- Updates inside the app. NoteIt can check automatically (Settings › General), and Check for Updates is in the NoteIt menu and the menu bar panel.
- Install with Homebrew: `brew install --cask rutbergphilip/tap/noteit`.

### Known issues

- There's no Trash yet, so deleting a note can't be undone.
- Folders kept in sync by another tool, such as iCloud Drive or Dropbox, and S3 services without conditional writes only get best-effort protection when two Macs write at the same time.
- The full list is in [Known limitations](https://github.com/rutbergphilip/noteit/blob/main/docs/known-limitations.md).

[Unreleased]: https://github.com/rutbergphilip/noteit/compare/v0.6.2...HEAD
[0.6.2]: https://github.com/rutbergphilip/noteit/compare/v0.6.1...v0.6.2
[0.6.1]: https://github.com/rutbergphilip/noteit/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/rutbergphilip/noteit/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/rutbergphilip/noteit/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/rutbergphilip/noteit/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/rutbergphilip/noteit/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/rutbergphilip/noteit/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/rutbergphilip/noteit/releases/tag/v0.1.0
