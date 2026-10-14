# Known limitations

NoteIt is a young project. These are the things it doesn't do yet, or does only partly. Several are on the [roadmap](../README.md#roadmap), and contributions are welcome.

## Sync

- **Folders kept in sync by another tool** (iCloud Drive, Dropbox and similar) get best-effort protection only. NoteIt locks the folder while writing, but that only helps when your Macs write to the same volume, such as a NAS share. A sync tool copies files between Macs after the fact, so two Macs can still race. When the tool leaves its own conflict files behind (such as `<id> 2.meta`), NoteIt imports them as conflict copies and cleans up unusable ones after 30 days.
- **S3 providers without conditional writes** (`If-Match` / `If-None-Match`) also get best-effort protection: NoteIt checks before and after each write, which narrows the race between two Macs but doesn't close it. This includes providers that silently ignore those headers, such as Google Cloud Storage's S3-compatible API. NoteIt detects them with a one-time check.
- **No WebDAV** backend yet.
- **No side-by-side view for conflicts.** You compare the conflict copy with the original yourself.
- **Encryption is chosen when you connect.** You can't change the passphrase or turn encryption on later without starting a new synced library.
- **Macs only.** There's no iPhone or iPad app.

## Notes and editing

- **No Trash.** Deleting a note can't be undone, and there's no *Recently Deleted* view. Deleted note bodies are kept in a hidden `.trash/` folder in the library, but getting one back means digging in Finder, and its title and notebook are gone.
- **Markdown export is lossy.** Underline, text colors, highlights, alignment and paragraph indents are dropped, because Markdown has no syntax for them. Export as HTML, PDF or RTFD to keep them.
- **Quick Capture is plain text.** The title becomes a bold first line; format the note afterwards in the editor. There's one draft at a time, and nothing outside the panel shows that a draft is waiting.
- **Tags are plain text.** `#hashtags` aren't styled in the editor, can't be renamed or merged, and are only added by typing them.
- **Simple organization.** Notebooks can't be nested, a note belongs to one notebook, and notes are always sorted pinned first, then by last edit.
- **Basic search.** All words must match (ignoring case and accents). Results aren't ranked, and matches aren't highlighted.
- **No note info.** There's no word count or created date.
- **One window.** Notes can't be opened in separate windows.

## Setup and distribution

- **No first-run guide.** New users get sample notes only. Global hotkeys are unbound by default and are set up in Settings › Shortcuts.
- **Accessibility hasn't been audited** yet. Only some controls have VoiceOver labels.
