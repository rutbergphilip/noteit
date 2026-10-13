# Keycap

A rounded chip showing one key of a shortcut, used in the hotkey recorder and hints like `esc`.

- Provide: one key glyph per chip (⌃ ⌥ ⇧ ⌘, a letter, ↩, `esc`), in modifier order ⌃ ⌥ ⇧ ⌘.
- Face in `mono` at 12 px on `surface-raised` with a `hairline` border.
- Give the group an `aria-label` that spells the shortcut out.


Reference rendering: `previews/Keycap.html` (open in a browser; styles in `previews/components.css`, tokens in `../tokens.css`). It is a visual spec, not code to port: rebuild it natively in SwiftUI/AppKit.
