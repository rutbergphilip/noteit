# Capture Plus — Design

Status: proposed · Date: 2026-10-19 · Companion plan: docs/plans/2026-10-19-capture-plus.md

## Goal

Get things into NoteIt that aren't selected text: text on the screen, spoken thoughts, a quick line for today, and email. Every capture is saved without leaving the app you're in, gets a sensible title on its own, and becomes searchable. All recognition runs on the Mac. Email comes only from a mailbox you own.

This builds on [Capture from Any App](2026-10-15-capture-from-any-app-design.md): the same notice, the same "notebook for new notes", the same rule that NoteIt stays in the background.

## What the user gets

### Screenshot to Text

- **Screenshot to Text** is a global hotkey in **Settings › Shortcuts › Global**, unbound by default. It's also in **File › Capture › Screenshot to Text**, the command palette and the menu bar panel (`text.viewfinder` button).
- Pressing it shows the standard macOS crosshair. Drag a region, or press Space and click a window. Esc cancels and nothing is saved, with no notice.
- NoteIt saves a new note with:
  - a title (see [Auto titles](#5-auto-titles-for-captures));
  - the screenshot as an image;
  - the text found in it, as normal editable paragraphs below the image;
  - a source line, such as **From Example Page in Safari**, when the front app could be identified.
- The notice says **Saved to Inbox** with the title. If no text was found it says **Saved to Inbox — No text found in the image**.
- Without Screen Recording permission the notice says **Allow NoteIt to record the screen** with two buttons:
  - **Allow Access…** shows the macOS prompt and opens System Settings › Privacy & Security › Screen & System Audio Recording. macOS asks you to quit and reopen NoteIt afterwards.
  - **Use Clipboard Image** turns the image on the clipboard into a note instead. This pairs with ⌃⇧⌘4, which copies a region without any permission.
- **Find text in images** (Settings › General › Capture, off by default) also reads text in images already in your notes, in the background, so searching for a word in a pasted photo or receipt finds the note. Search shows such a match as **Found in an image**. Locked notes are never read.
- After your first Screenshot to Text, while **Find text in images** is off, a notice asks once: **Find text in all your images?** / *NoteIt can read the images already in your notes, on this Mac, so search finds their text.* with **Turn On** and **Not Now**.

### Voice notes

- **Record Voice Note** is a global hotkey, unbound by default. It's also **File › Capture › New Voice Note**, a palette command and a menu bar panel button (`mic`).
- A small recorder appears in the top-right corner: a red dot, the elapsed time, a level meter, **Save** and **Cancel**. The app you're in keeps focus. Pressing the hotkey again saves. Return saves and Esc cancels while the recorder has keyboard focus.
- Recordings stop at 45 minutes. At 44:00 the time turns orange and reads **1 min left**; at 45:00 the recording is saved.
- Saving creates a note with the recording as a playable audio attachment and the line **Transcribing…** under it. When transcription finishes, that line is replaced with the transcript, and the title is set from it if you haven't changed it.
- The transcript is normal text in the note. Edit it like anything else. Right-click the recording › **Insert Transcript** transcribes it again and inserts a fresh copy below the recording, leaving your edited text alone. This also works for audio files you add to a note yourself.
- Transcription happens on the Mac only. If it isn't available for the chosen language, the note keeps the recording and the notice says **Saved without a transcript** with the reason.
- The first recording asks for Microphone permission, and the first transcription asks for Speech Recognition permission. If Microphone access is off, the notice says **Allow NoteIt to use the microphone** with **Open Settings…**.

### Append to Today

- **Append to Today** is a global hotkey, unbound by default. It's also **File › Capture › Append to Today…** and a palette command.
- It needs daily notes, which come with `linking`. Before that ships, the menu item and palette command are hidden and the hotkey shows the notice **Daily notes aren't available yet**.
- A single-line field appears near the top of the screen, like Quick Capture but one line high, with the placeholder **Add to today's note**. Return adds the line and closes the field; Esc closes it. Text you typed and didn't add stays until you add it or clear it.
- The line is added to today's daily note in the program's daily log format: `- 09:42 Called the plumber, coming Thursday`.
- The notice says **Added to 2026-10-19** (the daily note's title). Clicking it opens the note.
- Pasted text with several lines becomes one line, with line breaks turned into spaces.
- The same append is available from other apps through `automation`: the link `noteit://append?daily=today&text=…`, the commands `noteit today` and `noteit append --today`, and the Shortcuts action **Append to Daily Note**. Capture Plus defines none of these.

### Email to NoteIt

- **Settings › General › Email-in** connects a mailbox you already have. NoteIt checks one folder (**NoteIt** by default) every 15 minutes while it's running and turns each new message from an allowed sender into a note.
- You set up the routing on your mail server: a filter or rule that files mail sent to `you+notes@example.com` (or similar) into that folder. NoteIt never needs a server of its own.
- The subject becomes the title, the message becomes the body, images stay inline, and other attachments are added as files. A source line says **From The Supplier by email · 19 Oct 2026 at 09:42**.
- After saving, NoteIt marks the message as read (default) or moves it to another folder you choose.
- **Check Now** in Settings and the palette command **Check Email Now** run a check right away.
- Settings shows the last check and what happened, for example **Checked 2 minutes ago · 3 notes saved** or **Sign-in failed. Check the password and try again.**

### Auto titles for captures

- Every capture gets a single-line title of at most 60 characters, picked by simple rules from the email subject, the page or window title, or the first meaningful line of recognised or transcribed text.
- When nothing usable exists it falls back to **Screenshot 19 Oct 2026 at 09:42**, **Voice Note 19 Oct 2026 at 09:42** or **Email from The Supplier**.
- With Smart Features on, `private-ai` can replace that title with a better one shortly after the capture is saved, as long as you haven't changed it.

## Design

### 1. Shared pieces

**Hotkeys.** Three new `HotkeyAction` cases, at the positions the program's frozen hotkey table gives them: `screenshotToText` (9), `recordVoiceNote` (10) and `appendToToday` (11), after `linking`'s `openToday` and `organise`'s `showTasks` and before `private-ai`'s `askNotes`, whatever order the plans merge in. Bindings are saved by raw value, so the position never changes a saved binding. All unbound by default. The task that adds the cases also adds them to the `ShortcutsSettingsView` tile switch and the `AppDelegate` handler switch.

| Case | Title | Symbol | Description |
|---|---|---|---|
| `screenshotToText` | Screenshot to Text | `text.viewfinder` | Save part of the screen as a note, with the text in it. |
| `recordVoiceNote` | Record Voice Note | `mic.fill` | Record a voice note and transcribe it on this Mac. |
| `appendToToday` | Append to Today | `calendar.badge.plus` | Add a timestamped line to today's daily note. |

**Menus and palette.** A **Capture ▸** submenu in the File menu, after the Open group (Open Quickly, Open Today's Note, Daily Note for Date…) and before **Share ▸**, as the program's menu table sets out: **Screenshot to Text**, **New Voice Note**, **Append to Today…**. They have no menu shortcut by default, so `MenuShortcutCommand` is unchanged; the global hotkeys cover keyboard use. Palette commands (`PaletteCommandRegistry`): `screenshotToText`, `newVoiceNote`, `appendToToday` (available only while daily notes are), and `checkMailNow` (available only while email-in is on). Each calls the same code as its menu item or hotkey.

**Notices.** `CaptureOutcome` gains cases and `CaptureToastButton` gains buttons; the notice panel, timings and `TransientSurfaceHider` behaviour are reused as they are.

| Outcome | Notice |
|---|---|
| `.saved(…)` with `detail: "No text found in the image"` | **Saved to Inbox** / *No text found in the image* |
| `.screenRecordingNotAllowed` | **Allow NoteIt to record the screen** / *Or use an image you copied with ⌃⇧⌘4.* Buttons **Use Clipboard Image**, **Allow Access…** |
| `.clipboardHasNoImage` | **No image on the clipboard** / *Copy part of the screen with ⌃⇧⌘4, then try again.* |
| `.microphoneNotAllowed` | **Allow NoteIt to use the microphone** / button **Open Settings…** |
| `.savedWithoutTranscript(…, reason)` | **Saved without a transcript** / the reason |
| `.appended(noteID, dayTitle)` | **Added to 2026-10-19** / the line, clickable |
| `.dailyNotesUnavailable` | **Daily notes aren't available yet** |
| `.offerImageTextIndexing` | **Find text in all your images?** / *NoteIt can read the images already in your notes, on this Mac, so search finds their text.* Buttons **Turn On**, **Not Now** |
| `.needsAppBundle` | **Open NoteIt from its app** / *Voice notes need the installed app.* (dev builds run with `swift run`) |
| `.screenshotNotSaved(noteID)` | **Couldn't save the screenshot note** / *The screenshot is kept until it's saved.* Button **Try Again** |

`CaptureOutcome.saved` gets an optional `detail: String?` that replaces the title as the notice message when set.

**Permissions** live in `Capture/CapturePermissions.swift`, one small type per permission with `status` and `request()`:

- Screen Recording: `CGPreflightScreenCaptureAccess()` and `CGRequestScreenCaptureAccess()`. macOS only reports a grant after NoteIt relaunches, so Settings shows **Allowed after NoteIt restarts** until then, with a **Restart NoteIt** button.
- Microphone: `AVCaptureDevice.authorizationStatus(for: .audio)` / `requestAccess(for: .audio)`.
- Speech Recognition: `SFSpeechRecognizer.authorizationStatus()` / `requestAuthorization`. It's requested before the first transcription on every macOS version, including when the macOS 26 engine is used, so behaviour is the same everywhere.

`scripts/build_app.sh` adds `NSMicrophoneUsageDescription` ("NoteIt records voice notes when you ask it to.") and `NSSpeechRecognitionUsageDescription` ("NoteIt turns your voice notes into text on this Mac. Audio never leaves your Mac."). `Resources/NoteIt.entitlements` adds `com.apple.security.device.audio-input`, which the hardened runtime needs for the microphone. The app's entitlements are applied through its row in the embeds table that `automation` adds to `scripts/build_app.sh` in wave 0 (foundations task 5.5); Capture Plus adds no helpers or extensions, so it adds no rows. Without an app bundle (`swift run`) these keys are missing and macOS would end the process on a microphone request, so voice notes show `.needsAppBundle` instead.

**Settings › General.** The General tab is already a scrolling form (`Form` with `.formStyle(.grouped)`), built in wave 0 (foundations task 6.5) with its sections frozen in `GeneralSettingsSection` (`NoteItCore`). Capture Plus adds its rows to the `capture` section and, when Email-in ships, sets `GeneralSettingsSection.emailIn.isAvailable` to true. It doesn't restructure the tab.

**Settings › General › Capture** grows. Rows in order:

| Row | Control | Key | Default |
|---|---|---|---|
| Read selected text | existing Accessibility row | — | — |
| Record the screen | status + **Allow…** | — | — |
| Use the microphone | status + **Allow…** | — | — |
| Include page links from browsers | existing toggle | `captureIncludesBrowserLinks` | on |
| Find text in images | toggle + progress line *Reading images: 120 of 450* | `imageTextIndexing` | off |
| Text recognition language | picker: **Automatic** or one of Vision's languages | `textRecognitionLanguages` (`[String]`, empty = automatic) | Automatic |
| Also copy recognised text | toggle | `screenshotCopiesText` | off |
| Transcribe voice notes | toggle | `voiceTranscription` | on |
| Voice note language | picker of on-device languages | `voiceTranscriptionLocale` (BCP 47, empty = system) | system language |
| Speech model (macOS 26) | status + **Download…** | — | not downloaded |

**Email-in** is its own section in the General form (see §4).

**Scratch folder.** Recordings in progress and screenshots being processed live in `capture-pending/` inside `NoteStore.rootURL`, the NoteIt data folder (the folder `NOTEIT_DATA_DIR` overrides), never in a Markdown library's content folder. It's never synced or indexed. At launch, leftover screenshots older than a day are deleted and leftover recordings are offered back (§3.1).

**Attachment limit.** One attachment is at most 25 MB, `AttachmentLimit.maxBytes` in `NoteItDoc` (the cap the web app spec sets). Capture Plus uses that constant directly and keeps no copy of its own.

### 2. Screenshot to Text

#### 2.1 Taking the screenshot

Decision: run `/usr/sbin/screencapture -i -x -o <capture-pending>/<uuid>.png` as a subprocess, not a custom overlay on ScreenCaptureKit.

- It's the selection UI people already know from ⇧⌘4: drag a region, Space for a window, Esc to cancel, all displays, Retina scale, and correct behaviour over full-screen apps and Spaces.
- ScreenCaptureKit's `SCScreenshotManager` (macOS 14) can capture a rectangle but has no region picker; `SCContentSharingPicker` picks windows and displays, not regions. A custom overlay window per display, with drag handling, window snapping and accessibility, would be a few hundred lines of UI to get to parity with a system tool.
- Both approaches need Screen Recording permission for other apps' windows, so the subprocess costs nothing extra in permissions.
- `-x` turns off the shutter sound, `-o` leaves out the window shadow. No other flags.

Behaviour:

- Screen Recording is checked first. Not allowed → `.screenRecordingNotAllowed`; `screencapture` is not started, because without permission it saves only the wallpaper.
- The front app is recorded when the hotkey is pressed, before the crosshair appears. When Accessibility is allowed, `SourceResolver.resolve(app:includeBrowserLinks:)` runs in parallel, exactly as for Capture Selection, for the source line. Without Accessibility only the app name is used. When NoteIt itself is in front, there's no source line.
- Exit status 0 with a file → continue. No file (Esc, or the user clicked away) → stop silently. A non-zero exit with no file → stop silently too, because `screencapture` uses it for cancel. The process is terminated after 5 minutes, which only happens if the crosshair is left open.
- A second press while the crosshair is up is ignored (`isCapturing`, shared with Capture Selection).
- **Use Clipboard Image** reads the first PNG or TIFF on `NSPasteboard.general` and continues from the next step. Nothing there → `.clipboardHasNoImage`.

#### 2.2 Recognising text

- `VNRecognizeTextRequest`, revision 3, `recognitionLevel = .accurate`, `usesLanguageCorrection = true`.
- Language: **Automatic** sets `automaticallyDetectsLanguage = true`. A chosen language sets `recognitionLanguages = [code]`. The picker lists `supportedRecognitionLanguages()` for that revision, with display names from `Locale.current`.
- Observations with a top-candidate confidence under 0.3 are dropped.
- `RecognizedTextLayout` (pure, unit tested) turns observations into paragraphs:
  - Sort by the top of each bounding box, then group into lines when two boxes overlap vertically by more than half the smaller height. Within a line, order by x and join with one space.
  - Start a new paragraph when the gap to the previous line is over 1.2 × the median line height, or the left edge moves by more than 5% of the image width.
  - Hyphenated line ends (`exam-` + `ple`) are joined only when the line ends in a letter followed by `-`.
- Recognition runs in a detached task at `.userInitiated`, with the image downsampled with ImageIO to at most 4096 px on the long side.
- At most 100,000 characters are kept per image (well above a full screen of text).

#### 2.3 The note

- Body, in order: title paragraph (`EditorStyle.paragraph(_:kind: .title)`), the image, the recognised paragraphs in body style, an empty paragraph, then the source line.
- The source line reuses Capture Selection's: **From \<page title\> in Safari** linked to the page, **From \<document\> in Pages**, or **From \<App\> — \<window\>**. Capture Plus extracts it from `CaptureFormatter`'s private code into two internal functions: `sourceLine(for:title:)`, which takes a `CaptureSource` and covers every case, and `sourceLine(linkingTo:label:appName:)`, which builds the linked form and which `web-clipper` reuses as is. Capture Selection's output stays byte for byte the same.
- Image: the PNG from `screencapture` is kept if it's at most 8 MB. Larger ones are saved as JPEG at quality 0.85, and if that's still over 25 MB, scaled down to 4096 px on the long side first. File name: `Screenshot 2026-10-19 at 09.42.31.png` (or `.jpg`).
- The note goes to the notebook for new notes and is saved with `NoteStore.createNote(in:initial:)`, without selecting or opening it.
- **Also copy recognised text** puts the recognised text, as plain text, on the clipboard after saving.
- After the first successful Screenshot to Text, if **Find text in images** is off and hasn't been offered before (`imageTextIndexingOffered`), the `.offerImageTextIndexing` notice follows the saved notice. It's a one-time notice: **Turn On** turns the setting on, and either button, or ignoring it, means it's never offered again.
- The temporary file is deleted only after `NoteStore.persistNow` reports the note on disk. If that fails, the file stays and the `.screenshotNotSaved` notice offers **Try Again**, which saves the same note again (never a second one). Closing the notice keeps the file: it is deleted only once a later save of that note succeeds. NoteIt tries again at the next Screenshot to Text, every 5 minutes while a file is kept, and at launch. A marker file next to the screenshot holds the note's ID, so a retry saves that note and never makes a second one; if at launch the note never reached disk, NoteIt builds it again from the screenshot (without the source line) and saves it.

#### 2.4 Text in images already in notes

Text inside images should be found by search, but not written into note bodies, since it would change notes the user didn't touch and sync every one of them. This is off by default (program rule on text in images); the user turns it on in Settings or from the offer after the first Screenshot to Text (§2.3).

- **Storage.** `attachment-text.json` in `NoteStore.rootURL` (the data folder), next to `search-index.json`, never in a Markdown library's content folder. Like the search index it's local, rebuildable and never synced; each Mac reads its own images.

  ```json
  {
    "version": 1,
    "engine": "vision-text-3",
    "images": { "<sha256 hex of image bytes>": { "text": "folded text", "recognizedAt": "…" } },
    "notes":  { "<note UUID>": { "updatedAt": "…", "images": ["<sha256>", "…"] } }
  }
  ```

  Keys are the SHA-256 of the attachment bytes, the same key `noteit-doc` uses for attachments, so the file stays valid when bodies move to `noteit-doc` or to Markdown storage (`markdown-storage`). The text is stored folded with `TextFold.fold` (`NoteItCore`).

- **Search.** Capture Plus provides the text; `organise` owns search and ranking. `organise` defines the `ImageTextProviding` protocol (`func imageText(for noteID: UUID) -> String?`) in wave 1, with no provider. Capture Plus registers its provider in wave 2 with `NoteStore.registerImageTextProvider(_:)`; the provider's `imageText(for:)` returns a note's folded image text. `organise`'s search uses it for its **Found in an image** match source, shown instead of a highlighted snippet when the only match is in an image, and shown only once a provider is registered. The palette and the Local API search go through the same search, so they find these notes too. `imageText(for:)` returns nil while **Find text in images** is off and for locked notes.
- **Indexer.** `AttachmentTextIndexer` registers with `organise`'s `DerivedIndex` registry (foundations task 4.4) through `NoteStore.registerDerivedIndex(_:)`, the only hook for keeping something in step with note bodies. It doesn't add hooks to `NoteStore.swift`.
  - `noteChanged(_:body:)`, sent on body changes and note creation, marks the note and schedules a pass 10 s after the last change. `noteRemoved(_:)` drops the note's `notes` entry. `metadataChanged(_:)`, the only hook sent for metadata-only changes (pin, move, tag, move to Recently Deleted, restore), needs no work, except that a note restored from Recently Deleted is marked like a changed one. `rebuild(notes:body:)` clears the file and re-reads every note. `flush()` (synchronous) writes `attachment-text.json`.
  - While **Find text in images** is off, the indexer ignores every event and keeps no file.
  - After launch, or after the setting is turned on, a catch-up pass starts 30 s later.
  - A note needs work when it has no `notes` entry or the entry's `updatedAt` differs from the note's. The indexer asks `NoteStore.imageAttachments(in:)` for the note's images. That reads the body through `NoteBodyStorage` off the main actor, so the indexer never reads note files itself and works with any storage format.
  - Images whose hash already has an entry are reused (the same image in two notes is read once).
  - Images under 64 × 64 px or over 50 megapixels are skipped. GIFs use their first frame.
  - One image at a time, at `.utility` priority, with a 100 ms pause between images. It pauses while Low Power Mode is on or the thermal state is `.serious` or worse, and resumes when that ends.
  - Screenshot to Text notes already have their text in the body, but their image is indexed too (when the setting is on), so editing the body later doesn't lose matches.
  - Image entries no note refers to are swept at the end of each pass.
  - The engine string changes when the recognition settings change in a way that affects results (revision or language), which clears `images` and re-reads everything.
- **Locked notes** (`sync-security`) are left out. The indexer skips any note whose `NoteMeta.isLocked` is true and `imageAttachments(in:)` returns nothing for it. Locking a note removes its `notes` entry (the registry calls `noteRemoved` on lock and never sends `noteChanged` for a locked note), and its images are swept unless an unlocked note shares them. Removing the lock makes the note eligible again on the next pass.
- **Turning it off** stops the indexer and deletes `attachment-text.json`. Search then ignores image text.
- **Progress** shows in Settings as **Reading images: 120 of 450**, and **All images read** when done.

#### 2.5 Errors and privacy

- Recognition failure (Vision error, unreadable image): the note is still saved with the image; notice detail **Couldn't read text in the image**.
- Saving the note can't fail in a way the user sees today (`createNote` saves later and retries), so no extra handling.
- Images never leave the Mac. Vision runs locally. NoteIt doesn't take screenshots on its own; only the hotkey, menu, palette or menu bar button start one.

### 3. Voice notes

#### 3.1 Recording

- `AVAudioRecorder` with AAC (`kAudioFormatMPEG4AAC`), 1 channel, 44.1 kHz, 64 kbit/s, into a CAF file `capture-pending/<uuid>.caf`. CAF is written so that a recording cut off by a crash is still readable, which an `.m4a` isn't until it's closed.
- At 64 kbit/s a minute is about 0.48 MB, so the 45-minute limit stays under the 25 MB attachment cap (about 21.6 MB).
- On **Save** the CAF is turned into `.m4a` with `AVAssetExportSession` (`AVAssetExportPresetPassthrough`, `.m4a`), so the audio isn't re-encoded. Attachment file name: `Voice Note 2026-10-19 at 09.42.m4a`.
- After the note is created, NoteIt writes a marker `capture-pending/<uuid>.note-id` holding the note's ID next to the CAF and calls `NoteStore.persistNow` for the note. Only once it returns are the marker and the CAF deleted (the attachment is the `.m4a`, already in the saved body; a CAF that is itself an attachment's source is deleted only once the attachment is in the saved body) and transcription queued. If `persistNow` fails, the CAF and marker stay, nothing is queued, and the recording is offered through **Recovery** below.
- Recordings shorter than 1 s are discarded with no note and no notice.
- **Cancel** deletes the CAF.
- The recorder uses the system's default input. If the input device goes away mid-recording, the recording is saved as it is.
- Only one recording at a time. The hotkey toggles: start, then save.
- **Recovery.** A `.caf` left in `capture-pending/` at launch means NoteIt quit while recording. A notice says **Recover voice recording from 19 Oct at 09:42?** with **Save as Note** and **Delete**. Ignored, it's asked again at every launch. The same notice covers a recording whose note couldn't be saved. A recovered recording is never deleted automatically; it stays in `capture-pending/` until the user picks **Save as Note** or **Delete**. If its marker names a note still in the library, **Save as Note** saves that note again rather than making a second one; the CAF and marker are deleted only after the save succeeds.

#### 3.2 The recorder panel

- `VoiceRecorderPanel` is an `NSPanel` that can become key without activating NoteIt (the `QuickCapturePanel` pattern), placed in the top-right corner where capture notices appear, 300 × 64 pt, on all Spaces.
- Contents: red dot, elapsed time `0:42`, a level meter fed by `averagePower(forChannel:)` every 0.1 s, **Save** and **Cancel** buttons.
- Clicking elsewhere doesn't stop the recording, unlike Quick Capture.
- It joins `TransientSurfaceHider` as a new `Surface.voiceRecorder`, so NoteIt hides again afterwards if it was hidden before.

#### 3.3 Transcription

- **Engine choice.** `Transcriber` is a protocol with two implementations:
  - `SpeechAnalyzerTranscriber` on macOS 26 and later, using `SpeechAnalyzer` with a `SpeechTranscriber` module. It's compiled only with a Swift 6.2 or later compiler (`#if compiler(>=6.2)`), so CI on older Xcode still builds. It needs Apple's speech model for the language; NoteIt never downloads it on its own. Settings shows **Speech model: Not downloaded** with **Download…**, which calls `AssetInventory` after the user clicks. Until it's installed, the older engine is used.
  - `SFSpeechTranscriber` everywhere else: `SFSpeechURLRecognitionRequest` with `requiresOnDeviceRecognition = true`, `addsPunctuation = true`, no partial results. If `supportsOnDeviceRecognition` is false for the language, transcription is skipped with the reason **\<Language\> can't be transcribed on this Mac.** It never falls back to Apple's servers.
- **Long recordings** on the older engine are split into chunks of at most 60 s. `TranscriptChunker` (pure, unit tested) picks each cut at the quietest 0.5 s window between 45 and 60 s, using RMS levels read from the file, so words aren't cut in half. Chunk transcripts are joined with a space.
- **Paragraphs.** A new paragraph starts after a pause of 2 s or more (from segment timestamps), or after 5 sentences.
- **Placement.**
  - The note is created right away with the title, the audio attachment and the paragraph **Transcribing…**, so the recording is safe on disk before transcription starts.
  - When the transcript is ready, NoteIt changes the note through `NoteStore.editBody`, the only way code outside the editor changes note text. That works whether or not the note is open (main window, floating note or cheat sheet), keeps undo working and marks the note for saving. Inside the edit, it finds a paragraph that is exactly `Transcribing…` after the attachment and replaces it. If the user removed or changed it, the transcript is added at the end of the note under a subheading **Transcript**. If the title is still the fallback title, it's replaced with one from the transcript (§5) in the same edit, so it's one undo step.
  - On failure or when nothing was heard, the placeholder is removed through `editBody` and the notice says **Saved without a transcript** with the reason (**No speech found**, **Transcription isn't available on this Mac**, …).
  - If the note was locked or moved to Recently Deleted in the meantime, `editBody` refuses the edit; the job is dropped and the recording stays as it is.
- **Interrupted transcription.** Pending jobs are kept in `capture-pending/transcriptions.json` (note ID + attachment SHA-256). At launch, unfinished jobs run again.
- **Insert Transcript.** The editor's context menu on an audio attachment (`.m4a`, `.mp3`, `.wav`, `.aiff`, `.caf`) offers **Insert Transcript**, which transcribes it and inserts the text after the attachment through `editBody`, as one undoable edit.
- Transcription is user-started (a recording or **Insert Transcript**). Nothing runs on audio in the background.

#### 3.4 Playback in the editor

- An audio attachment is drawn by `AudioAttachmentCell` as a rounded pill: a play/pause button, **Voice note** (or the file name for other audio), and the duration, `3:12`. Clicking plays or pauses with `AVAudioPlayer`. Only one plays at a time, and playback stops when the note is closed.
- The cell is display-only and assigned when the editor loads the body, like `fitAttachments`. The saved RTFD keeps a plain file attachment, so export, sync and other apps see a normal `.m4a`.

#### 3.5 Privacy

- Audio and transcripts stay on the Mac (and in your sync storage, encrypted if sync encryption is on).
- The only network access is the optional speech model download, which goes to Apple through `AssetInventory` and only after **Download…**. It's listed in the network inventory (`sync-security`).

### 4. Email-in

#### 4.1 Which mailbox, which messages

- One IMAP account per Mac. Settings live in `UserDefaults` under `mailInConfiguration` (JSON), so they're per Mac by nature. The password is in the Keychain under the service `io.github.rutbergphilip.noteit.mail-in`, account `<username>@<host>`, `kSecAttrAccessibleAfterFirstUnlock`. It's never logged, not even in debug transcripts. A separate service is used so that disconnecting sync (`Keychain.deleteAll()`) doesn't remove it.
- Only implicit TLS on port 993 is supported. Plain IMAP on 143 and STARTTLS aren't offered, so the password is never sent before encryption is set up.
- **Folder:** one folder, **NoteIt** by default. Names are sent in IMAP's modified UTF-7.
- **Messages that become notes** — all must hold:
  - unread (`UNSEEN`) and without the keyword `$NoteIt`;
  - `From` address in **Allowed senders** (case-insensitive, exact address or `@domain`). The list starts with the account's own address when the username looks like one. An empty list blocks everything; **Accept mail from anyone** turns the check off, with the warning *Anyone who knows the address can add notes.*;
  - when the message has an `Authentication-Results` header from the user's server, it doesn't contain `dmarc=fail`;
  - `RFC822.SIZE` at most 50 MB;
  - its Message-ID hash isn't in `mail-in-state.json` (already imported).
- Messages that fail a check are left untouched and counted in the status (**2 messages from other senders were skipped**).
- At most 25 messages per check, oldest UID first; the rest come in the next check.
- **First connection:** existing unread messages in the folder are imported too. The setup sheet says how many there are before turning it on: **14 unread messages in NoteIt will become notes.**

#### 4.2 The IMAP client

Decision: a small IMAP client of our own, on Network.framework's `NWConnection` with TLS, in a new library target `NoteItMail` (Foundation and Network only, no AppKit), like `NoteItSync`.

- `URLSession` doesn't speak IMAP, `CFStream` sockets are deprecated, MailCore2 is a large C++/Objective-C dependency, and SwiftNIO IMAP would add NIO and its dependencies. NoteIt needs about ten commands, so its own client is small, fully testable with recorded server transcripts, and keeps Sparkle the only third-party dependency.
- Commands used: `CAPABILITY`, `AUTHENTICATE PLAIN` (with `SASL-IR`, else as a continuation) or `LOGIN` when `AUTH=PLAIN` isn't offered, `SELECT`, `UID SEARCH`, `UID FETCH` (`RFC822.SIZE`, `BODY.PEEK[HEADER.FIELDS (FROM MESSAGE-ID SUBJECT DATE AUTHENTICATION-RESULTS)]`, `BODY.PEEK[]`), `UID STORE +FLAGS.SILENT`, `UID MOVE` (RFC 6851), `UID COPY` + `UID EXPUNGE` (RFC 4315 UIDPLUS), `CREATE`, `LIST`, `LOGOUT`. `LOGINDISABLED` stops with an error.
- `IMAPResponseParser` is an incremental byte parser for tagged, untagged and continuation responses, with literals `{n}`, quoted strings, lists and `NIL`.
- `IMAPTransport` is a protocol; `NWIMAPTransport` is the real one and tests use a scripted transport.
- TLS 1.2 or later. The server certificate is checked with the system trust store. For servers with their own certificate (common at home), the first failure shows the SHA-256 fingerprint with **Trust This Certificate**; the fingerprint is then stored in the configuration and only that exact certificate is accepted.
- Timeouts: 15 s to connect, 30 s per command, 120 s per message download, 5 minutes per check.

#### 4.3 Turning a message into a note

`MIMEParser` (in `NoteItMail`, pure, unit tested) handles header unfolding, RFC 2047 encoded words, RFC 2231 parameters (`filename*=utf-8''…`), `multipart/mixed`, `alternative` and `related` at any depth, base64, quoted-printable, 7bit/8bit, and charsets through `CFStringConvertIANACharSetNameToEncoding` (UTF-8 when unknown).

`MailNoteBuilder` (app target) builds the body:

- **Title** from the subject (§5).
- **Text.** `text/html` is preferred when present, because forwarded receipts and newsletters keep their lists, links and emphasis. Before conversion `MailHTMLSanitizer` removes `script`, `style`, `link`, `iframe`, `object`, `embed`, `form` and `meta` elements, replaces `cid:` images with `data:` URLs from the message, and turns any other image into a link labelled **[image]**, so nothing is ever loaded from the network (no tracking pixels). The result goes through `AppleNotesImporter.convert(html:title:)`, which already builds editor-styled bodies from HTML and extracts data-URL images. Without HTML, `text/plain` becomes body paragraphs. Text is cut at 200,000 characters (`CaptureFormatter.maxSelectionLength`) with a final **…**.
- **Attachments.** Inline images stay where they are. Other parts with a file name are added after the text as file attachments, up to 20 per message and 25 MB each (`AttachmentLimit.maxBytes`). Anything skipped gets a line **Skipped attachment: report.zip (too large)**.
- **Source line** at the end: **From The Supplier by email · 19 Oct 2026 at 09:42** (the `Date` header in local time; the address when there's no name).
- **Notebook:** **Save to** in the email-in settings, defaulting to the notebook for new notes.
- **Dates.** Created through `createImportedNote(body:title:notebookID:createdAt:updatedAt:)` with `createdAt` from the `Date` header (if it's within the last year and not in the future, else now) and `updatedAt` now, so it appears at the top of the list.

After the note is created, NoteIt calls `NoteStore.persistNow` for it, which returns only once the note is on disk. Only then does it record the Message-ID hash in `mail-in-state.json` and then:

- **Mark as read** (default): `UID STORE <uid> +FLAGS.SILENT (\Seen $NoteIt)`. `$NoteIt` is left out when `PERMANENTFLAGS` doesn't allow new keywords.
- **Move to folder** (default name **NoteIt/Saved**, created with `CREATE` if missing): `UID MOVE`, or `UID COPY` + `\Deleted` + `UID EXPUNGE <uid>` with UIDPLUS. A plain `EXPUNGE` is never sent, because it would also remove other deleted messages. Without MOVE or UIDPLUS, NoteIt marks as read and Settings says **This server can't move messages, so NoteIt marks them as read.**

If the flag or move fails, the Message-ID record stops a second import. If `persistNow` fails, nothing is recorded and the server isn't touched, so the message stays eligible; the next check saves the note already made instead of making a second one, and the check ends with the server-error status (retry at the next interval).

#### 4.4 Schedule and state

- **Interval:** 5, 15 (default), 30 or 60 minutes, only while NoteIt is running. A check also runs 30 s after waking from sleep and when the network comes back (`NWPathMonitor`), but never more often than once a minute.
- **State file** `mail-in-state.json` in `NoteStore.rootURL` (the data folder): `uidValidity`, `lastCheck`, `lastResult`, and the SHA-256 of the last 2,000 imported Message-IDs. A message without a Message-ID uses a hash of `Date`, `From`, `Subject` and size. A changed `UIDVALIDITY` is fine because nothing depends on UIDs between checks.
- **Several Macs.** The setting is per Mac. Settings says *Turn on email-in on one Mac only. Other Macs get the notes through sync.* If two Macs do check, `$NoteIt` and `\Seen` make a duplicate unlikely but not impossible.

#### 4.5 Status and failures

`MailInStatus`, shown under the section header in Settings with a symbol, and as one line in the menu bar panel footer only when it's a failure:

| State | Text | What happens next |
|---|---|---|
| `off` | Off | — |
| `idle(lastCheck, saved, skipped)` | Checked 2 minutes ago · 3 notes saved | next interval |
| `checking` | Checking… | — |
| `offline` | Couldn't reach mail.example.com | retries at 1, 2, 4 … up to 60 minutes, then the normal interval |
| `signInFailed` | Sign-in failed. Check the password and try again. | stops until the account settings change |
| `untrustedCertificate(fingerprint)` | The server's certificate isn't trusted. | stops; shows the fingerprint and **Trust This Certificate** |
| `folderMissing(name)` | There's no folder named "NoteIt". | stops; **Create Folder** sends `CREATE` and resumes |
| `serverError(message)` | The server said: \<text\> | retries at the next interval |

A message that can't be parsed is left unread, counted as skipped, and logged without its content.

#### 4.6 Setup sheet

**Set Up Email-in…** opens a sheet: server (host), user name, password, folder, **Test Connection** (connects, logs in, selects the folder and counts unread messages), then **Turn On**. Presets fill in hosts for iCloud Mail (`imap.mail.me.com`), Fastmail (`imap.fastmail.com`) and Gmail (`imap.gmail.com`), each with the note *Use an app-specific password.* Connected, the section shows the account, folder, allowed senders, **After saving** (Mark as read / Move to folder…), **Save to**, **Check every**, **Check Now** and **Turn Off…**. Turning off deletes the password from the Keychain and `mail-in-state.json`; notes are kept.

### 5. Auto titles for captures

`CaptureTitler` (pure, unit tested) picks titles for every capture kind. `CaptureFormatter` keeps its current rules for Capture Selection but calls the shared truncation, `CaptureTitle.truncated` in `NoteItCore`, so its titles don't change.

- **Order of sources:**
  - Screenshot: first meaningful line of recognised text, then page title, then window title, then fallback.
  - Voice note: first sentence of the transcript, then fallback.
  - Email: cleaned subject, then first meaningful line of the body, then **Email from \<name or address\>**.
  - Append to Today: no title; the daily note keeps its own.
- **Meaningful line:** look at the first 10 non-empty lines. Strip list markers (`-`, `*`, `•`, `1.`), heading `#`s, `>` and wrapping quotes. Skip a line when it has fewer than 3 letters, is only a URL, email address, date or time, or is more than half digits and punctuation.
- **Subject cleaning:** repeatedly strip `Re:`, `Fwd:`, `Fw:`, `AW:`, `SV:`, `VS:`, `WG:` and a leading `[tag]`, any case. Empty after cleaning → next source.
- **Length:** at most 60 characters. A sentence end (`. `, `? `, `! `) before 60 cuts there without an ellipsis; otherwise the existing word-boundary cut with **…** applies. Trailing `:`, `;` and `,` are removed.
- **Fallback:** `"Screenshot " + date`, `"Voice Note " + date`, with the date as `Date.FormatStyle(date: .abbreviated, time: .shortened)` in the user's locale (**19 Oct 2026 at 09:42** in English (UK)).
- **Refinement.** Capture Plus owns the `CaptureTitleRefining` protocol; `private-ai` provides the model-based implementation and registers it at launch in `CaptureTitleRefinement.refiner`. After a capture is saved, Capture Plus asks the registered refiner for a better title (with the note ID and the heuristic title). It applies the answer through `NoteStore.editBody` only if the note's title still equals the heuristic title, so a title the user has changed is never replaced. No refiner registered, or a nil answer, keeps the heuristic title. `private-ai` decides whether its feature is on and which model runs; Capture Plus never calls a model itself.

### 6. Append to Today

- **One appender.** `linking` owns daily notes and `DailyLogAppender` (built in wave 0 as part of `NoteStore+Daily`), the only code that appends to a daily note. The line format is `DailyLogLine` in `NoteItCore`: `- HH:mm text`, 24-hour, `en_US_POSIX`. Capture Plus has no appender, no line formatter, no daily-note provider and no fallback daily note of its own.
- **Availability.** Append to Today is available only while `DailyNotes.isAvailable` (`NoteItCore`) is true. It's false until `linking` ships and flips it, so before then Append to Today is unavailable: the menu item and palette command are hidden and the hotkey shows `.dailyNotesUnavailable`. Nothing is written anywhere else.
- **Panel.** `AppendTodayPanel` follows `QuickCapturePanel`: borderless, key without activating NoteIt, on all Spaces, placed 22% down from the top of the screen with the mouse. 480 × 52 pt, one single-line `TextField`, placeholder **Add to today's note**, and today's date on the right in secondary text. Return adds, Esc closes, clicking elsewhere closes. The draft is kept until it's added or cleared, like Quick Capture. The field turns pasted line breaks and tabs into spaces.
- **Adding.** Return calls `DailyLogAppender` with the text and the time Return was pressed, so "today" is the local calendar day at that moment, not when the panel opened. The appender picks or creates the day's note and adds the line; Capture Plus doesn't edit the note itself. The result (note ID, day title, line) becomes `.appended`. Empty text after trimming beeps and keeps the panel open; the panel checks this first, and the appender's `DailyLogError.emptyText` is handled the same way.
- **Other entry points.** `automation` routes the link `noteit://append?daily=today&text=`, the `noteit today` and `noteit append --today` commands, the Shortcuts action **Append to Daily Note** and `POST /v1/daily/append` to the same `DailyLogAppender`. Capture Plus defines no URL, command, intent or route for this.

## Dependencies

- **Foundations (wave 0).** Capture Plus builds on these seams and doesn't redefine them:
  - `NoteStore.editBody` and `OpenEditorRegistry` (from `organise`, foundations task 4.5) for every change to an existing note's text: the transcript replacing **Transcribing…**, a removed placeholder, a refined title and **Insert Transcript**. There are no separate append or replace primitives.
  - The `DerivedIndex` registry (from `organise`, foundations task 4.4) for the image text indexer.
  - `NoteBodyStorage` (foundations task 4.1) for reading note bodies in `imageAttachments(in:)`.
  - `NoteStore+Daily` and `DailyLogAppender` (from `linking`, foundations task 4.6) for Append to Today, gated by `DailyNotes.isAvailable`, and `DailyLogLine` in `NoteItCore`.
  - `NoteMeta.isLocked` (from `sync-security`), to leave locked notes out of the image text index.
  - `AttachmentLimit.maxBytes` in `NoteItDoc` for the 25 MB cap.
  - `TextFold.fold` and `CaptureTitle` in `NoteItCore`.
  - The frozen hotkey, menu and Settings tables, the General settings form and `GeneralSettingsSection` (foundations task 6.5), and the embeds table in `scripts/build_app.sh` (foundations task 5.5).
- **`automation` (01).** Capture Plus works without it and registers no Local API routes; its hotkeys run in-process. `automation` routes `noteit://append?daily=today&text=`, `noteit today`, `noteit append --today`, the **Append to Daily Note** Shortcuts action and `POST /v1/daily/append` to `linking`'s `DailyLogAppender`. Core Spotlight indexing may include image text through the registered `ImageTextProviding` provider, which returns nil for locked notes.
- **`linking` (03).** Owns daily notes, `NoteStore.dailyNote(for:createIfMissing:)` and `DailyLogAppender`. Append to Today is unavailable until it ships.
- **`organise` (04).** Owns search, the search index and the `DerivedIndex` registry. It defines `ImageTextProviding` (wave 1) and adds the **Found in an image** match source, which reads the registered provider and appears only once Capture Plus has registered one. It adds its own sections to the foundations General settings form.
- **`markdown-storage` (02).** `NoteStore.imageAttachments(in:)` reads bodies through `NoteBodyStorage`, so it works for Markdown libraries with no extra work. Audio attachments are plain `.m4a` files next to the note. `attachment-text.json`, `mail-in-state.json` and `capture-pending/` stay in `NoteStore.rootURL`, never in the library's `contentRootURL`.
- **`private-ai` (06).** Provides the model-based `CaptureTitleRefining` implementation and registers it. It reads transcripts as note text and image text through the registered `ImageTextProviding` provider.
- **`sync-security` (08).** Owns locked notes; the image text index follows its rule that locked notes are left out of every derived index. The network inventory lists: IMAP over TLS to the user's server (email-in, off by default) and Apple's speech model download (`AssetInventory`, only after **Download…**).
- **`web-clipper` (07).** Reuses `CaptureFormatter.sourceLine(linkingTo:label:appName:)`, which Capture Plus extracts. Both are in wave 2; the extraction ships before the clipper task that calls it (program §2). Full-page screenshots arrive as images in notes, so the background indexer makes their text searchable when **Find text in images** is on.
- **Web app spec.** Screenshots map to `noteit-doc` `image` nodes and recordings to `attachment` nodes; both respect the shared 25 MB cap. The web app plays `.m4a` with the browser's audio element; that's its own work.

## Non-goals

- A custom screenshot overlay, timed screenshots, screen recording to video, or annotation.
- Text in PDFs, and choosing part of an existing image to read.
- Live transcription while recording, speaker labels, word timings, or translation.
- Choosing a microphone other than the system default.
- OAuth sign-in (Gmail and Outlook XOAUTH2), POP3, IMAP IDLE push, several mail accounts, sending mail, and STARTTLS on port 143.
- A NoteIt mail server or relay.
- The model behind refined titles, and summaries or tags (`private-ai`).
- Daily notes, their templates, title formats, the day boundary and the line format (`linking`).
- A Local API route, link, command or Shortcuts action for Append to Today (`automation`).
- Ranking and highlighting search results (`organise`).

## Open questions

| Question | Default chosen |
|---|---|
| `screencapture` subprocess or a ScreenCaptureKit overlay? | **`screencapture -i`.** Revisit only if a macOS release removes it or its flags. |
| Where does recognised screenshot text go? | **Visible, editable paragraphs below the image**, plus the background image index for search. |
| HTML or plain text for email bodies? | **Sanitized HTML** when present, never loading remote content; plain text otherwise. |
| Email-in on several Macs? | **One Mac**, stated in Settings; `$NoteIt` and `\Seen` keep duplicates unlikely. |
| Gmail and Outlook sign-in? | **App passwords only.** Outlook.com accounts that only allow OAuth aren't supported yet. |
| Audio quality and length? | **AAC mono 64 kbit/s, 45 minutes**, which fits the 25 MB attachment cap. |
| Speech model download on macOS 26? | **Only after the user clicks Download…**; the on-device older engine is used until then. |
| Review a screenshot note before saving, as in Quick Capture? | **No.** Saved directly with a notice, like Capture Selection. |
