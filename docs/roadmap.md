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
- [ ] **Capture from any app.** Select text anywhere, press a hotkey, and it's saved with a link back to where it came from.
- [ ] **Reminders in plain words.** "Call Anna tomorrow 9am" in a note becomes a notification.
- [ ] **Screenshot to text.** Capture part of the screen, and its text becomes searchable.
- [ ] **Voice notes.** Record and transcribe on your Mac.

Design: [`specs/2026-10-15-command-palette-design.md`](specs/2026-10-15-command-palette-design.md)

## Later: depth

- [ ] **Locked notes** with Touch ID.
- [ ] **Cheat sheets.** Show a note as a floating overlay with a hotkey, which is ideal for shortcut lists.
- [ ] **Floating notes** that stay above other windows.
- [x] **Snippets.** Copy a code block or command with one click, with syntax highlighting.
- [ ] **Links between notes** with `[[`, and backlinks.
- [ ] **Nested notebooks**, smart folders and saved searches.
- [ ] **Better tags.** Styled tag chips, plus renaming and merging tags.
- [ ] **Better search.** Ranked results and highlighted matches.
- [ ] **Templates** and daily notes.
- [ ] **Plain Markdown folder** as an optional storage format.
- [ ] **Private smart features** using the on-device models in macOS: summaries, asking questions about your notes, suggested tags.
- [ ] **Web app and iPhone access.** A self-hostable web app that also works as an installable iPhone app ([spec](specs/2026-10-13-web-app-design.md)).
- [ ] **iPhone and iPad apps**, starting with capture. The `NoteItSync` library has no AppKit dependency, so they can reuse it.
- [ ] **Spotlight, Shortcuts and a share extension.**
- [ ] **Sync:**
  - a WebDAV backend
  - a side-by-side view for comparing conflicts
  - changing the passphrase, or turning on encryption for an existing library
- [ ] **Onboarding:** a first-run guide for hotkeys, the menu bar and setting up a second Mac.
- [ ] **Polish:** motion for Quick Capture, checklists, pinning and sync status, plus an accessibility audit.
