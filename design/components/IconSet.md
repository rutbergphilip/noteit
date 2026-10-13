# IconSet

NoteIt's own 32-glyph line icon set, for the website, docs, onboarding, App Store art and anywhere SF Symbols cannot be used.

- Drawn on a 24 × 24 grid with a 1.75 stroke, round caps and joins, 2.5 corner radius on boxes, so they sit beside SF Symbols Regular without clashing.
- Use at 16, 20, 24 or 32. Below 16 the strokes close up.
- Colour with `ink` for UI, `accent` for active states, never a notebook colour on body text grounds.
- Inside the macOS app keep SF Symbols for chrome; use this set where the app draws its own artwork (onboarding, empty states if custom art is chosen).
- The files in `assets/Icons` are drawn in `#1C1C1E`; inline the SVG and set `stroke: currentColor` to theme them.


Reference rendering: `previews/IconSet.html` (open in a browser; styles in `previews/components.css`, tokens in `../tokens.css`). It is a visual spec, not code to port: rebuild it natively in SwiftUI/AppKit.
