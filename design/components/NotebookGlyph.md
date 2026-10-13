# NotebookGlyph

A notebook's symbol, either bare in its colour or on a tinted rounded-square tile.

- Provide: the symbol (one of 32 curated SF Symbols) and the notebook colour as `--nb`; size via `--s`.
- Tile form: notebook colour at `tint-glyph` (16%), corners `radius-glyph` (28% of the side), symbol at about 55% in full colour. Bare form: just the symbol in colour, as in the sidebar.
- The preview glyphs are stand-ins for SF Symbols.


Reference rendering: `previews/NotebookGlyph.html` (open in a browser; styles in `previews/components.css`, tokens in `../tokens.css`). It is a visual spec, not code to port: rebuild it natively in SwiftUI/AppKit.
