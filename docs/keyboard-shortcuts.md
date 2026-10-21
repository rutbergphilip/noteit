# Keyboard shortcuts

Everything in NoteIt can be done from the keyboard. This page lists every shortcut, the markdown you can type in the editor, and the global hotkeys you can set up yourself.

## App and navigation

| Shortcut | Action |
|---|---|
| ⌘N | New note in the selected notebook, with the cursor in the editor |
| ⌥⌘N | New Note from Template… (type to find a template; text that matches none becomes the new note's title) |
| ⇧⌘N | New notebook… |
| ⌘O | Open Quickly… (see [Command palette](#command-palette)) |
| ⇧⌘P | Command Palette… |
| ⌘F | Search all notes |
| ⌥⌘F | Find in the current note (see [Find and replace](#find-and-replace)) |
| ⇧⌘F | Find and replace in the current note |
| ⇧⌘S | Export note as… |
| ⌘P | Print the note |
| ⌥⇧⌘C | Copy as Markdown (the selection, or the whole note) |
| ⌃⌘L | Copy Note Link (a `noteit://` link to the current note) |
| ⌃⌘← / ⌃⌘→ | Go Back / Go Forward through the notes you opened in this window |
| ⌃⌘T | Open Today's Note (creates it in Daily Notes the first time) |
| ⌥⌘I | Show or hide Links and Outline (backlinks, the links in this note and its headings) |
| ⌘0 | Show the main window (*NoteIt Notes* in the Window menu) |
| ⌘, | Settings |
| ⌘⌫, or ⌫ in the note list | Move the selected note to Recently Deleted (in Recently Deleted: delete it now, after confirming) |
| ⌘Z (after deleting) | Undo the deletion |
| ⌥⌘Y | Version History… |

### Changing menu shortcuts

The menu shortcuts above for New Note, New Notebook…, Open Quickly…, Command Palette…, Search Notes, Find…, Find and Replace…, Export Note As…, Print…, Copy as Markdown, Copy Note Link, Version History…, Delete Note (⌘⌫), Go Back, Go Forward, Link to Note…, Show Links and Outline, New Note from Template…, Open Today's Note and Daily Note for Date… (no shortcut until you set one) can be changed in **Settings › Shortcuts › In NoteIt**. The menus and the command palette pick up the change right away.

When recording one:

- It must include ⌘ or ⌃, or be a function key. ⌥ or ⇧ on their own aren't enough.
- Arrow, delete, Home, End and Page Up/Down keys are kept for moving around and editing text.
- Esc cancels and ⌫ removes the shortcut, so the command has none.
- A combination that's already used by another NoteIt command, a formatting shortcut or a standard macOS shortcut such as ⌘Q is rejected.
- You'll see a warning, but can still go ahead, if one of your global hotkeys uses the same keys. The global hotkey takes priority.

The button next to a changed shortcut puts back its default, and **Restore Defaults** resets them all. The other shortcuts on this page can't be changed.

## Text formatting

| Shortcut | Action |
|---|---|
| ⌘B / ⌘I / ⌘U | Bold / italic / underline |
| ⇧⌘X | Strikethrough |
| ⇧⌘E | Inline code |
| ⇧⌘H | Highlight on or off |
| ⌘K | Link… |
| ⇧⌘K | Link to Note… (the selection becomes the link's text) |
| ⌘+ / ⌘− | Bigger / smaller text |
| ⌥⌘\\ | Clear formatting |

## Pasting

| Shortcut | Action |
|---|---|
| ⌘V | Paste. Copied Markdown, such as a list, a checklist or `**bold**`, comes in formatted |
| ⇧⌘V (or ⌥⇧⌘V) | Paste and Match Style: just the text, in the style where you paste it |

Text copied from a web page or another rich-text app keeps its formatting as before; ⌘V only turns text into formatting when it's clearly Markdown source, for example from a code editor, a terminal or a `.md` file. Anything less clear, such as code, a config file, a diff, a single `- item` line or `# headings` with nothing else Markdown, is pasted as it is. Markdown pasted in the middle of a line joins that line; headings, lists and other blocks go on lines of their own. Inside a code block, pasted text always stays as it is. One ⌘Z undoes the whole paste.

If you've bound ⇧⌘V yourself, as a menu shortcut or a global hotkey, it keeps working and Paste and Match Style stays on ⌥⇧⌘V.

## Paragraphs and blocks

| Shortcut | Action |
|---|---|
| ⌥⌘1 / ⌥⌘2 / ⌥⌘3 | Title / heading / subheading |
| ⌥⌘0 | Body text |
| ⌥⌘4 | Code block |
| ⌥⌘5 | Quote |
| ⇧⌘8 | Bulleted list |
| ⇧⌘7 | Numbered list |
| ⇧⌘L | Checklist |
| ⇧⌘U | Check or uncheck a checklist item |
| ⌘] / ⌘[ | Indent / outdent |
| Tab / ⇧Tab | Indent or outdent a list item; move to the next or previous table cell |
| ⇧⌘{ / ⇧⌘\| / ⇧⌘} | Align left / center / right |
| ⌥⇧⌘D | Divider |

Inside a list, Return starts a new item and Return on an empty item ends the list.

## Command palette

| Shortcut | Action |
|---|---|
| ⌘O | Open the palette to find notes, notebooks and commands |
| ⇧⌘P | Open the palette with `>` typed, to find commands only |
| `>` at the start of the query | Search commands only |
| ↑ / ↓ or ⌃P / ⌃N | Move through the results |
| ↩ | Open the note, show the notebook, or run the command |
| Esc or ⌘W | Close the palette |

Letters can be spread out, so `gn` finds *Grocery Notes*. With nothing typed, the palette lists the 10 most recently edited notes. The last row, *New Note “…”*, creates a note with the title you typed and puts the cursor on the line below it.

If you change the Open Quickly or Command Palette shortcut, the new one opens and closes the palette instead. Both can also get a [global hotkey](#global-hotkeys).

Text editing shortcuts such as ⌘A, ⌘C, ⌘V and ⌘Z work in the palette's search field. Any other menu shortcut, such as ⌘P, closes the palette first and then runs in the main window.

## Find and replace

| Shortcut | Action |
|---|---|
| ⌥⌘F | Open the find bar. Selected text fills the find field |
| ⇧⌘F | Open the find bar with the replace row |
| ↩ / ⇧↩ (in the find field) | Next / previous match |
| ⌘G / ⇧⌘G | Next / previous match |
| ⌘E | Use the selection for find |
| Tab / ⇧Tab | Move between the find and replace fields |
| ↩ (in the replace field) or ⇧⌘1 | Replace the current match and go to the next one |
| ⌥⌘↩ | Replace all matches |
| Esc | Close the find bar and go back to the text, with the current match selected |

The **Aa**, **ab** and **.\*** buttons in the find field turn on Match Case, Whole Word and Regular Expression. In regex mode, `$1`, `$2` and so on in the replacement insert the matching groups. Each Replace or Replace All can be undone with one ⌘Z, and replaced text keeps its formatting. In notes in Recently Deleted you can find, but not replace.

## Markdown as you type

Type these at the start of a line:

| Type… | …then | Result |
|---|---|---|
| `#` / `##` / `###` | Space | Title / heading / subheading |
| `-`, `*` or `+` | Space | Bulleted list |
| `1.` or `1)` | Space | Numbered list |
| `[]` or `[ ]` / `[x]` | Space | Checklist item, unchecked / checked |
| `>` | Space | Quote |
| ```` ``` ```` | Space or Return | Code block |
| ```` ```swift ```` (any language name or alias, such as `py`, `js` or `sh`) | Space or Return | Code block in that language |
| `---`, `***` or `___` | Return | Divider |

And these anywhere in a line:

| Type… | Result |
|---|---|
| `**bold**` | **bold** |
| `*italic*` | *italic* |
| `` `code` `` | `code` |
| `~~strike~~` | ~~strike~~ |
| `[[Note title]]` | A link to that note (`[[Title#Heading]]` for a heading, `[[Title\|text]]` to show other text) |

Each conversion can be undone with ⌘Z.

### Note link suggestions

Typing `[[` opens a list of notes under the caret that filters as you type. ↑/↓ (or ⌃P/⌃N) move through it, ↩ or Tab inserts the link, and Esc closes it and leaves what you typed. After `#` the list shows the note's headings.

### Template picker and daily calendar

In New Note from Template… and Edit › Insert Template…, ↑/↓ move through the templates, ↩ uses the highlighted one and Esc cancels. In File › Daily Note for Date…, the arrow keys move by a day (← →) or a week (↑ ↓), ↩ opens that day's note and Esc closes the calendar.

## Menu bar panel

| Shortcut | Action |
|---|---|
| ↑ / ↓, then ↩ | Move through the notes and open the highlighted one |
| Esc | Clear the search, then close the panel |
| ⌘↩ | Save the quick note |
| ⌘O | Open NoteIt |
| ⌘N | New note |
| ⌘, / ⌘Q | Settings / quit NoteIt |

## Quick Capture

| Shortcut | Action |
|---|---|
| ↩ (in the title) | Jump to the body |
| ⌘↩ | Save the note |
| ⇧⌘⌫ | Discard the draft and close |
| Esc | Close the panel and keep the draft for next time |

## Global hotkeys

These work from any app. They're **unbound by default**, so NoteIt never takes over a shortcut you already use. Set them in **Settings › Shortcuts › Global**:

| Hotkey | What it does |
|---|---|
| Show / Hide NoteIt | Brings the main window forward, or hides NoteIt if it's already in front |
| New Note | Opens NoteIt with a fresh note, ready to type |
| Quick Capture | Opens or closes the floating Quick Capture panel |
| Open Quickly | Opens the command palette to find notes, notebooks and commands |
| Command Palette | Opens the command palette with `>` typed, to find commands only |
| Capture Selection | Saves the text selected in the app you're in as a new note, with a link back to where it came from |
| Open Today's Note | Brings NoteIt forward with today's daily note open, creating it if needed |

Pressed while you're in another app, the palette opens over that app. Esc closes it and takes you back there.

Capture Selection keeps you in the app you're in. A notice in the top-right corner says where the note was saved, and clicking it opens the note. You can also capture with **Services › Capture to NoteIt** in the right-click or app menu, and give that its own shortcut in System Settings › Keyboard › Keyboard Shortcuts › Services.

When recording a shortcut:

- It must include ⌘, ⌃ or ⌥, or be a function key.
- Esc cancels and ⌫ clears.
- A combination that's already used by another NoteIt hotkey is rejected.
- You'll see a warning, but can still go ahead, if it clashes with a macOS shortcut or a common app shortcut.
- You'll see an error if another app already owns it.

Global hotkeys don't need Accessibility permission. Capture Selection does need it to read the selected text, and you can allow it in **Settings › General › Capture**. Without it, the hotkey shows a notice with **Allow Access…** and **Capture Clipboard**, which saves the text on the clipboard instead.
