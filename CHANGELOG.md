# Changelog

All notable changes to NoteIt are listed here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/rutbergphilip/noteit/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/rutbergphilip/noteit/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/rutbergphilip/noteit/releases/tag/v0.1.0
