# Changelog

All notable changes to NoteIt are listed here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/rutbergphilip/noteit/commits/main
