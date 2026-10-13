# NoteCard

A note in the note list: title, optional pin, two-line preview, relative date and notebook.

- Provide: title and preview (both derived from the note's first lines), edited date, pinned flag, and the notebook's name and colour as `--nb`.
- Title in `card-title`, "New Note" in `ink-secondary` when empty. Preview in `card-preview`, clamped to two lines. Meta in `card-meta`: relative date, then a notebook dot and name, omitted when the list is already scoped to that notebook.
- Selected cards fill with `fill-quiet`. No separators between cards.
- Sort pinned first, then most recently edited.


Reference rendering: `previews/NoteCard.html` (open in a browser; styles in `previews/components.css`, tokens in `../tokens.css`). It is a visual spec, not code to port: rebuild it natively in SwiftUI/AppKit.
