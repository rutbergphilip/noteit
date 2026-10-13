# Toast

A brief confirmation that a quick note was saved, shown about 1.8 s in the menu bar panel.

- Provide: the message, always "Saved to <notebook>".
- Capsule on `surface-raised` with a hairline; a check in `success`, text in `ink`. Enters with a fade and slide from the trailing edge, 0.2 s ease-out.
- Use only for saves. Never for errors, and never as the only feedback a save happened.


Reference rendering: `previews/Toast.html` (open in a browser; styles in `previews/components.css`, tokens in `../tokens.css`). It is a visual spec, not code to port: rebuild it natively in SwiftUI/AppKit.
