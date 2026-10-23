# Known limitations

NoteIt is a young project. These are the things it doesn't do yet, or does only partly. Several are on the [roadmap](../README.md#roadmap), and contributions are welcome.

## Sync

- **Folders kept in sync by another tool** (iCloud Drive, Dropbox and similar) get best-effort protection only. NoteIt locks the folder while writing, but that only helps when your Macs write to the same volume, such as a NAS share. A sync tool copies files between Macs after the fact, so two Macs can still race. When the tool leaves its own conflict files behind (such as `<id> 2.meta`), NoteIt imports them as conflict copies and cleans up unusable ones after 30 days.
- **S3 providers without conditional writes** (`If-Match` / `If-None-Match`) also get best-effort protection: NoteIt checks before and after each write, which narrows the race between two Macs but doesn't close it. This includes providers that silently ignore those headers, such as Google Cloud Storage's S3-compatible API. NoteIt detects them with a one-time check.
- **Synced storage keeps earlier copies of notes on folders.** Sync folders, and S3 providers that don't enforce conditional writes, keep each note's earlier versions and its pre-conversion RTFD copy, because there NoteIt can't prove that no other device still points at them. Clean Up Unused Storage… is unavailable there. Deleting a note removes all of its copies.
- **Older NoteIt builds stop syncing once a store uses the portable format.** They show “update NoteIt” and keep their notes; an edit made there syncs again after updating.
- **No WebDAV** backend yet.
- **No side-by-side view for conflicts.** You compare the conflict copy with the original yourself.
- **Encryption is chosen when you connect.** You can't change the passphrase or turn encryption on later without starting a new synced library.
- **Macs only.** There's no iPhone or iPad app.
- **Version history isn't synced.** Each Mac keeps the versions it recorded itself.
- **Older versions show nested notebooks flat** and read a nested tag such as `#a/b` as `#a`. Moving or renaming a notebook there keeps where it's nested.
- **Two Macs offline at the same time may both show a reminder.** Without a connection to the synced folder or bucket, a Mac can't tell that another one already showed it.
- **NoteIt 0.1.0 doesn't know about Recently Deleted.** A Mac still on 0.1.0 shows deleted notes as normal notes until it's updated, and editing one there brings it back.

## Notes and editing

- **Markdown export is lossy.** Underline, text colors, highlights, alignment and paragraph indents are dropped, because Markdown has no syntax for them. Export as HTML, PDF or RTFD to keep them.
- **Quick Capture is plain text.** The title becomes a bold first line; format the note afterwards in the editor. There's one draft at a time, and nothing outside the panel shows that a draft is waiting.
- **Tags live in the note text.** Renaming or deleting a tag skips locked notes and notes in Recently Deleted.
- **One notebook per note.** Notebooks nest up to four levels deep.
- **Search doesn't look inside attachments** such as PDFs. Best-match ranking applies only when the search has words; otherwise notes are sorted by last edit.
- **Reminders need NoteIt running.** A reminder that comes due while NoteIt is closed shows the next time it opens, if that's within a day. Reminders need the app bundle, so they don't show when running with `swift run`.
- **Reminders in locked notes don't ring**, and tasks in locked notes aren't listed in Tasks.
- **No note info.** There's no word count or created date.
- **One window.** Notes can't be opened in separate windows.

## Import

- **Importing twice makes duplicates.** NoteIt doesn't recognize notes it has already imported.
- **Apple Notes checklists become bulleted lists**, and ticked items aren't marked as done.
- **Apple Notes attachments other than images are skipped** (PDFs, drawings, scans, audio and so on), and so are locked notes. The summary at the end counts both.
- **Apple Notes formatting is approximate.** Headings are recognized by font size, and fonts and text colors are dropped.
- **Wikilinks become plain text.** `[[Note]]` and `[[Note|alias]]` keep their text but don't link anywhere, since notes can't link to each other yet. Links to other Markdown files become plain text too.
- **Markdown that NoteIt has no style for is simplified.** Underline, colors and alignment don't exist in Markdown, HTML inside Markdown is kept as text (except `<br>`), footnotes and math aren't rendered, and other front matter fields are dropped.
- **Subfolders deeper than four levels** become one notebook named `Folder / Subfolder` inside the deepest nested notebook. Apple Notes subfolders become flat notebooks named that way.
- **Markdown images must be image files inside what you import.** Images outside the chosen folder (or the TextBundle), including ones reached through symlinks, and images over 25 MB are skipped and counted in the summary. For files picked one by one, images are only looked for next to the file. Links other than web, email, phone and FTP links become plain text.
- **Apple Notes' Recently Deleted folder is recognized by name.** It's matched in every language Notes ships, so a top-level folder of your own with that exact name is skipped too.

## Setup and distribution

- **No first-run guide.** New users get sample notes only. Global hotkeys are unbound by default and are set up in Settings › Shortcuts.
- **Accessibility hasn't been audited** yet. Only some controls have VoiceOver labels.
