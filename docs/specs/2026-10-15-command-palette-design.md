# Command Palette — Design

## Goal

Open any note, jump to any notebook and run any command from the keyboard, without reaching for the mouse or remembering where something lives in the menus.

## 1. Opening

- **File › Open Quickly… (⌘O)** opens the palette: a search field with a results list below it.
- **File › Command Palette… (⇧⌘P)** opens the same palette with `>` already typed, so it lists commands only.
- The palette is a panel centered over the main window. If the main window is hidden, it's shown first.
- **Esc**, **⌘W** or a click anywhere outside the palette closes it. Nothing is changed until you pick a row.
- Any other menu shortcut, such as ⌘P or ⇧⌘S, closes the palette and runs in the main window, so sheets like Print and Export open there. Text editing shortcuts (⌘A, ⌘C, ⌘V, ⌘X, ⌘Z, ⇧⌘Z and ⌘ with the arrow or delete keys) keep working in the search field.

### Why these shortcuts

- ⌘O isn't used in the main window, since NoteIt has no files to open, and "open" is what the palette mostly does. Xcode's Open Quickly works the same way.
- ⇧⌘P is the command palette shortcut people already know from VS Code and Sublime Text.
- ⌘P stays **Print**, as in every other Mac app.

## 2. Matching and ranking

- The query is matched against note titles, notebook names and command names.
- Matching ignores case and accents, so "cafe" finds "Café".
- Letters don't have to be next to each other, only in order: "gn" finds "Grocery Notes".
- Matches score higher when letters land on the start of a word, form a prefix, or run together. Long gaps between matched letters score lower.
- Notes, notebooks and commands are ranked together by score. Ties go to the most recently edited note.
- Notes whose text matches but whose title doesn't are listed after all title matches. Text matching uses the folded text from the search index, so it's as fast as search.
- The matched letters in each row are highlighted.
- A query that starts with `>` searches commands only. The `>` itself isn't matched.

## 3. Results

### Rows

- **Notes** show the note's title and its notebook. A note without a title is shown as "New Note", as in the note list. Return opens the note in the main window.
- **Notebooks** show the notebook's icon in the notebook's color. Return selects the notebook in the sidebar.
- **Commands** show the command's name and its keyboard shortcut, if it has one. Return closes the palette and runs the command.

### Creating a note

- The last row is **New Note “<text>”**, where `<text>` is what you typed. Return creates a note with that title in the selected notebook and opens it with the cursor on the line below the title.
- The row is hidden when a note already has exactly that title, when the field is empty, and when searching commands.

### Empty field

- With an empty field, the palette lists the 10 most recently edited notes, newest first.
- With only `>` typed, it lists every available command.
- Notes in Recently Deleted are never listed, except through the Show Recently Deleted command.

## 4. Keyboard

| Key | Action |
|---|---|
| ↑ / ↓ or ⌃P / ⌃N | Move the selection up / down |
| Return | Open the note, show the notebook, or run the command |
| Esc | Close the palette |

Typing selects the first row again. Typing always goes to the search field.

If notes, notebooks or the open note change while the palette is open, the results and commands are updated and the selected row stays selected if it's still there. Picking a note or notebook that was removed in the meantime just updates the list.

## 5. Commands

Only commands that make sense right now are listed. A command that would do nothing, or that the matching menu item would show as disabled, is left out.

| Command | Shortcut | Listed when |
|---|---|---|
| New Note | ⌘N | Always |
| New Notebook… | ⇧⌘N | Always |
| Search Notes | ⌘F | Always |
| Find… | ⌥⌘F | A note is open |
| Find and Replace… | ⇧⌘F | A note is open. A note in Recently Deleted can't be edited, so there it opens Find only, like the menu item |
| Export Note As… | ⇧⌘S | A note is open, including one in Recently Deleted, as in the File menu |
| Print… | ⌘P | A note is open, including one in Recently Deleted, as in the File menu |
| Copy as Markdown | ⌥⇧⌘C | A note is open, including one in Recently Deleted, as in the File menu |
| Version History… | ⌥⌘Y | A note is open and isn't in Recently Deleted |
| Pin Note / Unpin Note | | A note is open and isn't in Recently Deleted. Only the one that applies is listed |
| Delete Note / Delete Now… | ⌘⌫ | A note is open. For a note in Recently Deleted it's Delete Now…, which asks first |
| Move to <Notebook> | | A note is open and isn't in Recently Deleted. One row for each notebook except the note's own |
| Show Recently Deleted | | Recently Deleted has at least one note |
| Import… | | Always |
| Settings… | ⌘, | Always |

The shortcuts shown come from the same table the menus use, so they can't drift apart.

Commands run the same actions as their menu items, so they behave the same way and can be undone the same way.

## Implementation

- The palette lives in `Sources/NoteIt/Palette/`.
- `FuzzyMatcher` scores one query against one string and returns the matched ranges for highlighting. `PaletteRanker` turns notes, notebooks and the available commands into the ordered list of rows. Both are pure Swift with no AppKit, and are unit tested without any UI.
- `PaletteCommandRegistry` builds the command list from the app state each time the palette opens or the store changes. `MenuShortcuts` (in `App/`) holds the key equivalents that both the menus and the palette use.
- The palette window is an `NSPanel` hosting a SwiftUI view, built the same way as the Quick Capture panel. It closes when it stops being the key window. A key monitor sorts ⌘ shortcuts into ones the palette handles, text editing in the field, and menu shortcuts that close the palette and go to the main window first.
