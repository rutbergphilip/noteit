# HotkeyTile

A row in Settings › Shortcuts: coloured icon tile, title, description and the shortcut recorder.

- Provide: the action's tile colour (`tile-show-hide`, `tile-new-note`, `tile-quick-capture`), symbol, title, one-line description, and the current binding or none.
- Tile corners `radius-tile`; glyph white. KNOWN MISS: a white glyph on `tile-new-note` (orange) is 2.1:1; the title beside it carries the meaning.
- Recorder: "Record Shortcut" when empty, "Type Shortcut…" with live keycaps while recording. A combo needs ⌘, ⌃ or ⌥, or an F-key. Esc cancels, ⌫ clears, duplicates shake and beep.
- Global hotkeys ship unbound; never preassign one.


Reference rendering: `previews/HotkeyTile.html` (open in a browser; styles in `previews/components.css`, tokens in `../tokens.css`). It is a visual spec, not code to port: rebuild it natively in SwiftUI/AppKit.
