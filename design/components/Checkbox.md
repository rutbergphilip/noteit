# Checkbox

A round checklist checkbox drawn inline in the editor; clicking toggles the item.

- Provide: the item text and its checked state.
- Unchecked: an outlined circle in `ink-secondary`. Checked: an `accent`-filled circle with an `on-accent` check, and the label turns `ink-secondary` with a strikethrough.
- Created by typing `[]` or `[ ]` plus Space at line start, ⇧⌘L, or the toolbar; ⇧⌘U toggles.
- Don't: use square checkboxes anywhere in the app.


Reference rendering: `previews/Checkbox.html` (open in a browser; styles in `previews/components.css`, tokens in `../tokens.css`). It is a visual spec, not code to port: rebuild it natively in SwiftUI/AppKit.
