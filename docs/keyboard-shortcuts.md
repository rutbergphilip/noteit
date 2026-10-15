# Keyboard shortcuts

Everything in NoteIt can be done from the keyboard. This page lists every shortcut, the markdown you can type in the editor, and the global hotkeys you can set up yourself.

## App and navigation

| Shortcut | Action |
|---|---|
| ⌘N | New note in the selected notebook, with the cursor in the editor |
| ⇧⌘N | New notebook… |
| ⌘F | Search all notes |
| ⌥⌘F | Find in the current note (see [Find and replace](#find-and-replace)) |
| ⇧⌥⌘F | Find and replace in the current note |
| ⇧⌘S | Export note as… |
| ⌘P | Print the note |
| ⌥⇧⌘C | Copy as Markdown (the selection, or the whole note) |
| ⌘0 | Show the main window (*NoteIt Notes* in the Window menu) |
| ⌘, | Settings |
| ⌘⌫, or ⌫ in the note list | Move the selected note to Recently Deleted (in Recently Deleted: delete it now, after confirming) |
| ⌘Z (after deleting) | Undo the deletion |
| ⌥⌘Y | Version History… |

## Text formatting

| Shortcut | Action |
|---|---|
| ⌘B / ⌘I / ⌘U | Bold / italic / underline |
| ⇧⌘X | Strikethrough |
| ⇧⌘E | Inline code |
| ⇧⌘H | Highlight on or off |
| ⌘K | Link… |
| ⌘+ / ⌘− | Bigger / smaller text |
| ⌥⌘\\ | Clear formatting |

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

## Find and replace

| Shortcut | Action |
|---|---|
| ⌥⌘F | Open the find bar. Selected text fills the find field |
| ⇧⌥⌘F | Open the find bar with the replace row |
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

Each conversion can be undone with ⌘Z.

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

These work from any app. They're **unbound by default**, so NoteIt never takes over a shortcut you already use. Set them in **Settings › Shortcuts**:

| Hotkey | What it does |
|---|---|
| Show / Hide NoteIt | Brings the main window forward, or hides NoteIt if it's already in front |
| New Note | Opens NoteIt with a fresh note, ready to type |
| Quick Capture | Opens or closes the floating Quick Capture panel |

When recording a shortcut:

- It must include ⌘, ⌃ or ⌥, or be a function key.
- Esc cancels and ⌫ clears.
- A combination that's already used by another NoteIt hotkey is rejected.
- You'll see a warning, but can still go ahead, if it clashes with a macOS shortcut or a common app shortcut.
- You'll see an error if another app already owns it.

Global hotkeys don't need Accessibility permission.
