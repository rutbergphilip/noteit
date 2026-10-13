# Logo

The NoteIt logo, Swift Page: a formatted note flying in on speed streaks, shown as the app icon in its three appearance modes, the size ladder, lockups and menu bar states.

- Provide nothing: use the files in `assets/Logos`, `assets/AppIcons` and `assets/MenuBar` as they are.
- Mark in `brand-deep` on light grounds, white on `brand-violet`, `brand-deep` or dark grounds. Wordmark in the `wordmark` style beside it.
- At 32 px and below swap to the small master (`noteit-mark-small.svg`, `noteit-icon-small.svg`).
- Menu bar: page only at rest, page with streaks while Quick Capture is open.
- Don't recolour, rotate, add effects, split the streaks from the page, or set it in a notebook colour or `accent`.
- The icon files use a plain rounded rect for the body; export the final `.icns` on Apple's continuous squircle template with the system drop shadow.


Reference rendering: `previews/Logo.html` (open in a browser; styles in `previews/components.css`, tokens in `../tokens.css`). It is a visual spec, not code to port: rebuild it natively in SwiftUI/AppKit.
