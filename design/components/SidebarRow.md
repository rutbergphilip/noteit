# SidebarRow

A row in the sidebar's Library, Notebooks or Tags section: coloured symbol, name, count.

- Provide: symbol, label, count, and its colour: `accent` for All Notes, `pinned` for Pinned, `recent` for Recent, the notebook's own colour for notebooks.
- Label in `row`, count in `ink-secondary`. Selected row fills with `fill-quiet` (the app uses the system selection).
- Section headers are small `ink-secondary` labels. Tags appear only when a note contains a `#hashtag`.
- Rows accept dropped notes: onto a notebook moves them, onto Pinned pins them.


Reference rendering: `previews/SidebarRow.html` (open in a browser; styles in `previews/components.css`, tokens in `../tokens.css`). It is a visual spec, not code to port: rebuild it natively in SwiftUI/AppKit.
