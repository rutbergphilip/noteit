# EditorBlocks

How the rich-text editor draws its block types: inline code, block quote, table, divider and code block.

- Provide: content; the editor supplies the styling from the body size B.
- Inline code: `inline-code` on `fill-quiet`. Quote: `quote` with an `quote-indent` indent and a vertical bar. Table: `table-header` first row on `fill-quiet`, `space-8` cell padding, `hairline` borders. Divider: one hairline. Code block: `code-block` in a `radius-card` box on `fill-quiet` with a `space-14` inset.
- Keep the text column within `reading-max`, centred.
- `#hashtags` are plain text today; styling them as chips is an open design task.


Reference rendering: `previews/EditorBlocks.html` (open in a browser; styles in `previews/components.css`, tokens in `../tokens.css`). It is a visual spec, not code to port: rebuild it natively in SwiftUI/AppKit.
