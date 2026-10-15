# Capture from Any App — Design

## Goal

Save text you're reading in another app as a note with one key press, without leaving that app, and keep a link back to where it came from.

## 1. Triggering

- **Capture Selection** is a global hotkey in **Settings › Shortcuts › Global**. Like the other global hotkeys it's unbound by default.
- Select text in any app and press the hotkey. NoteIt saves a new note and the app you're in stays in front.
- **Capture to NoteIt** is a macOS Service. Select text, then right-click › Services › Capture to NoteIt, or use the app menu › Services. It works without Accessibility permission.
- The Service can get its own shortcut in System Settings › Keyboard › Keyboard Shortcuts › Services.

## 2. Reading the selection

- The hotkey reads the selection only with Accessibility permission, which is opt-in.
- NoteIt first asks the app for its selected text through Accessibility.
- If the app doesn't expose selected text that way, NoteIt copies the selection with ⌘C, reads it, and puts the clipboard back the way it was.
- If the app says nothing is selected, NoteIt shows **Nothing selected** and doesn't press ⌘C, because editors like VS Code would copy the current line. Browsers, including Firefox, are the exception: they can report an empty selection too early, so NoteIt tries ⌘C there.
- Electron apps turn on their Accessibility support only when asked, so the first capture from one reads the selection again after a short pause.
- An app that doesn't answer in time gets no ⌘C, so a hung app is never sent keystrokes.
- Without permission, the hotkey shows a notice with two buttons:
  - **Allow Access…** shows the macOS Accessibility prompt and opens System Settings › Privacy & Security › Accessibility. NoteIt stays in the background.
  - **Capture Clipboard** saves the text on the clipboard instead.
- The Service gets the selected text from macOS, so it never needs permission or the clipboard.

## 3. Source and link back

- In Safari and Chrome-based browsers, NoteIt reads the front tab's title and address. That covers Safari and Safari Technology Preview, plus Chrome, Edge and Brave (including their beta and preview builds), Chromium, Vivaldi and Arc.
- NoteIt checks first whether it may control the browser. The first time, macOS asks for permission only after a capture from that browser has been saved, never for one that saved nothing. That note has no link, and later ones do. If you don't allow it, captures from that browser have no link.
- **Include page links from browsers** in Settings › General › Capture turns page links off.
- Links may be skipped while an Apple Notes import is running, because both use the same AppleScript thread.
- When the hotkey has no Accessibility permission, NoteIt doesn't contact the browser, so no permission prompt appears, unless you press **Capture Clipboard**.
- **Firefox** doesn't make the page address available, so captures from Firefox get no page link and use the window title.
- In document apps, such as Pages, NoteIt uses the document's name and file.
- In any other app, it uses the app's name and the window title.

## 4. The note

- The title is the web page title. Without one it's the window or document title, and without that the first line of the selection.
- Titles are a single line of at most 60 characters. Longer ones are cut short with an ellipsis.
- The selection is added as a quote.
- A source line follows the quote:
  - **From <page title> in Safari**, with the page title linked to the page.
  - **From <document> in Pages**, with the document name linked to the file.
  - **From <App> — <window title>** for other apps.
- Captures go to the notebook chosen for new notes in Settings › Editor › New Notes, which is Inbox by default.

## 5. Feedback

- A small notice in the top-right corner of the screen says where the note went, such as **Saved to Inbox**.
- Clicking the notice opens the note in NoteIt. Otherwise the app you were in keeps focus, and NoteIt stays hidden if it was hidden, unless you bring NoteIt to the front yourself while the notice is up.
- A notice goes away after about 3 seconds, or about 8 seconds when it has buttons. Hovering over it keeps it open.
- Capture Clipboard shows **Saving…** until the result appears.
- Other notices say **Nothing selected**, or that the clipboard is empty after Capture Clipboard.

## 6. Permissions and privacy

- Global hotkeys still don't need Accessibility permission. Only reading the selection with the hotkey does.
- Nothing leaves the Mac. The text, title and address go straight into a local note.
- When NoteIt copies with ⌘C, it puts back what was on the clipboard before. If a slow app finishes the copy late, NoteIt undoes it for up to about a second, as long as that app is still in front. If you switch apps first, the late copy stays.
- NoteIt doesn't watch other apps in the background. It reads only when you press the hotkey or use the Service.
- Browser control is used only to read the front tab's title and address, and only while capturing.

## 7. Settings

| Where | Setting |
|---|---|
| Settings › Shortcuts › Global | **Capture Selection** hotkey, unbound by default |
| Settings › General › Capture | Accessibility status, updated live, with an **Allow…** button when it's not granted |
| Settings › General › Capture | **Include page links from browsers**, on by default |
| Settings › Editor › New Notes | The notebook new notes and captures go to, Inbox by default |

## Implementation

- Capture lives in `Sources/NoteIt/Capture/`.
- `CaptureFormatter` builds the note's title and body from the selection and its source. `BrowserSources` knows the supported browsers and how to ask each for its front tab. `PasteboardSnapshot` saves and restores the clipboard. All three are pure Swift and unit tested without any UI.
- `SelectionReader` reads the selected text with the Accessibility API and falls back to ⌘C. It never runs scripts. `AccessibilityAccess` checks and requests the permission.
- `SourceResolver` finds the app, window, document or page. Accessibility reads use a short timeout, so a slow app can't hold up a capture. For browsers it uses `BrowserPageReader`, which runs the scripts from `BrowserSources` with `NSAppleScript` on the app's single AppleScript thread, shared with the Apple Notes import. It checks Automation permission first and, when needed, asks for it only after the capture has been saved. Each script has a 2 s AppleScript timeout, and NoteIt gives up waiting after 1.5 s.
- `CaptureController` ties it together for the hotkey, the Service and Capture Clipboard, and saves the note through `NoteStore`.
- `CaptureToast` is a non-activating panel, so showing it never takes focus from the app you're in. `TransientSurfaceHider`, shared with the global command palette, hides NoteIt again when the last notice or palette closes if NoteIt was hidden before and you didn't bring it to the front in the meantime.
- `CaptureServiceProvider` handles the Service. Its `NSServices` entry is added to `Info.plist` by `scripts/build_app.sh`.
