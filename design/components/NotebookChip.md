# NotebookChip

The capsule in the note header that names the note's notebook and moves it when clicked.

- Provide: the notebook name and its colour as `--nb` (one of the `notebook-*` tokens).
- Fill is the notebook colour at `tint-chip` (14%), shape `radius-capsule`, label in `ink` so it reads in any notebook colour.
- Do: always show the name; colour alone is not enough for yellow, green, teal or orange. Don't: put the chip in lists; cards use a dot instead.


Reference rendering: `previews/NotebookChip.html` (open in a browser; styles in `previews/components.css`, tokens in `../tokens.css`). It is a visual spec, not code to port: rebuild it natively in SwiftUI/AppKit.
