# Editor Polish: Layout, Code Styling, Find and Replace — Design

## Goal

Make the editor feel as polished as Apple Notes, then go further: fix layout bugs, style code beautifully with syntax highlighting, and add find and replace like a code editor.

## 1. Layout and motion

- **Text reflows on every resize.** When the window or editor gets wider, lines rewrap to use the new width, just as they do when it gets narrower. If the editor has a maximum reading width, the text column stays centered within it.
- **The sidebar collapses and expands smoothly**, matching Apple Notes: no dropped frames and no text reflowing on every frame. Reflow may happen once when the animation ends, or be throttled during it, whichever looks smoother.

## 2. Code styling

### Inline code

- Drawn as a rounded pill with a soft tinted background and tinted text, like Apple Notes' monostyled text. There's horizontal padding, and the pill never touches the text next to it.
- It's styled at display time from the note's existing inline code formatting, so changing the look in Settings restyles every note immediately and doesn't rewrite any note.

### Code blocks

- A rounded card with a subtle background and border, comfortable padding, and a monospaced font.
- A small **language** label sits in the card's top-right corner and opens a picker: Plain Text, Bash/Shell, C, C++, C#, CSS, Go, HTML/XML, Java, JavaScript, JSON, Kotlin, Markdown, PHP, Python, Ruby, Rust, SQL, Swift, TypeScript, YAML. The default is **Automatic**, which guesses the language from the content.
- **Syntax highlighting** colors keywords, strings, comments, numbers, types and punctuation using a small built-in tokenizer, with no new dependencies. The colors are display-only (layout-manager temporary attributes), so they're never saved into the note, copied, or exported as colors.
- A copy button appears on hover in the top-right corner and copies the block's text.
- The chosen language is saved with the note and survives sync. It uses the same RTFD-safe paragraph-style sentinel technique as the existing block kinds.
- When typing ```` ```swift ````, the block's language is set to Swift.
- Markdown export writes ```` ```swift ```` fences, Markdown import reads them, and HTML export adds `class="language-swift"`.

### Settings › Editor › Code

| Setting | Options | Default |
|---|---|---|
| Inline code color | Pink, Purple, Blue, Green, Orange, Gray, Accent color | Pink |
| Inline code font | Monospaced, Same as text | Monospaced |
| Code block theme | Xcode, GitHub, Solarized, Nord. Each has a light and a dark variant that follows the system appearance. | Xcode |
| Syntax highlighting | On / Off | On |

There's a live preview of inline code and a short code block next to the settings.

## 3. Find and replace

- **⌥⌘F** opens a find bar pinned to the top-right of the editor, in VS Code style. **⇧⌥⌘F** opens it with the replace row expanded. A chevron toggles the replace row.
- **Find field:**
  - Toggles for **Match Case** (Aa), **Whole Word** (ab) and **Regular Expression** (.*).
  - A live match count such as "3 of 12", or "No results" in red.
  - Previous and next arrows; ↩ / ⇧↩ also step forward and back, and ⌘G / ⇧⌘G work too.
  - A close button; Esc also closes the bar and returns focus to the text.
- All matches are highlighted, with the current one emphasized, and it scrolls into view.
- **Replace field:**
  - **Replace** (⌘⇧1) replaces the current match and moves to the next.
  - **Replace All** (⌘⌥↩) replaces every match.
  - Regex mode supports `$1` capture groups.
  - Each Replace or Replace All is one undo step. Replacements keep the formatting of the text they replace.
- Selected text fills the find field when the bar opens.
- In read-only notes in Recently Deleted, Find works but the replace row is hidden.
