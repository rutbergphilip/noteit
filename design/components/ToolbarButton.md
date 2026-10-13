# ToolbarButton

A 26 × 24 icon button in the editor's formatting toolbar that toggles or applies one format.

- Provide: an icon or a single letter glyph, an `aria-label`, and `aria-pressed` for toggles (Bold, Italic, lists).
- States: rest is transparent; hover fills `fill-quiet`; active (format applies to the selection) turns the glyph `accent` on `fill-quiet`. Corners `radius-toolbar`.
- Group buttons by job (Style, Text, Color, Lists, Layout, Insert, Size) with a hairline separator. When the editor narrows, collapse groups into a "…" menu in the order Size, Layout, Insert, Color, Lists.
- Do: give every button a shortcut and show it in the tooltip. Don't: add labels or colour fills; the toolbar must stay quieter than the note.


Reference rendering: `previews/ToolbarButton.html` (open in a browser; styles in `previews/components.css`, tokens in `../tokens.css`). It is a visual spec, not code to port: rebuild it natively in SwiftUI/AppKit.
