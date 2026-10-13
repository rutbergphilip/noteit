# EmptyState

What a column shows when it has nothing: a tinted circle with a symbol, a title, one sentence and an optional action.

- Provide: symbol, colour (`pinned` for Pinned, the notebook's colour inside a notebook, `accent` otherwise), title, message, optional CTA.
- Circle is `empty-state-circle` (88 pt) at `tint-glyph`. Title in `ink`, message in `ink-secondary`. The CTA is a prominent `accent` button with `on-accent` text.
- Titles in Title Case: "No Notes Yet", "No Pinned Notes", "No Results", "No Note Selected".


Reference rendering: `previews/EmptyState.html` (open in a browser; styles in `previews/components.css`, tokens in `../tokens.css`). It is a visual spec, not code to port: rebuild it natively in SwiftUI/AppKit.
