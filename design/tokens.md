# NoteIt design tokens

Source of truth: `tokens.json`. This table is a readable mirror. **Swift mapping** says what the macOS app should use: where a system colour is named, use the system colour (it adapts to appearance, accent and accessibility settings) and treat the hex as a reference only. Where it says *fixed*, hard-code the hex.

## Colour

| Token | Light | Dark | Swift mapping | Usage |
|---|---|---|---|---|
| `surface-editor` | `#ffffff` | `#1e1e1e` | NSColor.textBackgroundColor | Editor writing surface and note list. The ground for almost all text. ≈ NSColor.textBackgroundColor. |
| `surface-window` | `#ececec` | `#323232` | NSColor.windowBackgroundColor | Window chrome and Settings panes. The sidebar sits on system vibrancy over this, so treat it as an approximation there. ≈ NSColor.windowBackgroundColor. |
| `surface-raised` | `#ffffff` | `#3a3a3c` | NSColor.controlBackgroundColor (or a material) | Composer card, keycaps, the Saved toast: small surfaces that sit on a material. Approximation; the app uses system materials. |
| `ink` | `rgba(0, 0, 0, 0.85)` | `rgba(255, 255, 255, 0.85)` | NSColor.labelColor | Primary text: note titles, body copy, sidebar rows. On every surface in both themes (≥12:1 on surface-editor). ≈ NSColor.labelColor. |
| `ink-secondary` | `rgba(0, 0, 0, 0.5)` | `rgba(255, 255, 255, 0.55)` | NSColor.secondaryLabelColor | Card previews, relative dates, the 'Edited…' line, counts. ≈ NSColor.secondaryLabelColor. KNOWN MISS: 3.98:1 on surface-editor and 3.84:1 on surface-window in Light, below 4.5:1 for its 11–12 pt uses. It is the system value, kept exact; dark theme passes (5.9:1). |
| `ink-tertiary` | `rgba(0, 0, 0, 0.25)` | `rgba(255, 255, 255, 0.25)` | NSColor.tertiaryLabelColor / placeholderTextColor | Placeholders only ('Start writing…', 'Jot down a quick note…'). Never for content: 1.8:1 Light, 2.3:1 Dark. |
| `hairline` | `rgba(0, 0, 0, 0.1)` | `rgba(255, 255, 255, 0.1)` | NSColor.separatorColor | 0.5 pt separators, table borders, card and composer outlines. Source range is 8–12% of primary; this is the middle. |
| `fill-quiet` | `rgba(0, 0, 0, 0.05)` | `rgba(255, 255, 255, 0.06)` | NSColor.quaternaryLabelColor (≈) or existing EditorStyles alpha | Code block and inline code backgrounds, toolbar button hover, table header row tint. Approximation of the dynamic alphas in EditorStyles.swift. |
| `accent` | `#007aff` | `#0a84ff` | NSColor.controlAccentColor / Color.accentColor | Stands in for the user's system accent (default Blue); the app never hard-codes a brand accent. Active toolbar buttons, filled checkboxes, focus ring, prominent CTAs, All Notes icon. As text: 4.0:1 on surface-editor Light, 4.6:1 Dark: use for icons and ≥13 pt semibold labels, not small body text. |
| `on-accent` | `#ffffff` | `#ffffff` | NSColor.white | The check glyph inside a filled checkbox and the label on a prominent CTA. White on accent is the system pair (4.0:1 Light, 3.65:1 Dark): fine as a mark, short of 4.5:1 for small text. Kept exact. |
| `focus-ring` | `{accent}` | `{accent}` | NSColor.keyboardFocusIndicatorColor | Keyboard focus: a solid 3 px ring, the macOS convention. ≥3.4:1 on surface-editor and surface-window in both themes. |
| `pinned` | `#ff9500` | `#ff9f0a` | NSColor.systemOrange | Pin icons, the Pinned sidebar row and its empty state. ≈ NSColor.systemOrange. Icon only, never text: 2.2:1 on surface-editor Light; the word 'Pinned' always sits beside it. |
| `recent` | `#30b0c7` | `#40c8e0` | NSColor.systemTeal | The Recent sidebar icon. ≈ NSColor.systemTeal. Icon only, never text (2.6:1 Light). |
| `success` | `#34c759` | `#30d158` | NSColor.systemGreen | The check glyph in the 'Saved to Inbox' toast. ≈ NSColor.systemGreen. Below 3:1 on light surfaces (2.2:1), so the toast's words carry the meaning; never colour alone. |
| `destructive` | `#ff3b30` | `#ff453a` | NSColor.systemRed | The Discard button in Quick Capture and delete confirmations. ≈ NSColor.systemRed. 3.55:1 on surface-editor Light, short of 4.5:1 for its 13 pt label: kept exact, and the word 'Discard' carries the meaning. |
| `notebook-blue` | `#0a84ff` | `#0a84ff` | fixed hex (same in both appearances) | Notebook palette, swatch 1 (Inbox). Fixed in both themes. Notebook colours paint glyphs, list dots and tinted chips, never body text. 3.65:1 on white. |
| `notebook-indigo` | `#5e5ce6` | `#5e5ce6` | fixed hex (same in both appearances) | Notebook palette, swatch 2. Fixed in both themes. 5.1:1 on white, 3.3:1 on surface-editor Dark. |
| `notebook-purple` | `#bf5af2` | `#bf5af2` | fixed hex (same in both appearances) | Notebook palette, swatch 3 (Shortcuts). Fixed in both themes. 3.5:1 on white. |
| `notebook-pink` | `#ff375f` | `#ff375f` | fixed hex (same in both appearances) | Notebook palette, swatch 4. Fixed in both themes. 3.5:1 on white. |
| `notebook-red` | `#ff453a` | `#ff453a` | fixed hex (same in both appearances) | Notebook palette, swatch 5. Fixed in both themes. 3.4:1 on white. |
| `notebook-orange` | `#ff9f0a` | `#ff9f0a` | fixed hex (same in both appearances) | Notebook palette, swatch 6 (Ideas). Fixed in both themes. KNOWN MISS as a glyph on white: 2.1:1; the notebook name always sits beside it. |
| `notebook-yellow` | `#ffd60a` | `#ffd60a` | fixed hex (same in both appearances) | Notebook palette, swatch 7. Fixed in both themes. KNOWN MISS on white: 1.4:1. Fine in Dark (11.8:1); in Light it relies on the notebook name beside it. |
| `notebook-green` | `#30d158` | `#30d158` | fixed hex (same in both appearances) | Notebook palette, swatch 8. Fixed in both themes. KNOWN MISS on white: 2.0:1; relies on the name beside it. |
| `notebook-teal` | `#64d2ff` | `#64d2ff` | fixed hex (same in both appearances) | Notebook palette, swatch 9. Fixed in both themes. KNOWN MISS on white: 1.7:1; relies on the name beside it. |
| `notebook-gray` | `#8e8e93` | `#8e8e93` | fixed hex (same in both appearances) | Notebook palette, swatch 10. Fixed in both themes. 3.3:1 on white, 5.1:1 on surface-editor Dark. |
| `tile-show-hide` | `{notebook-indigo}` | `{notebook-indigo}` | alias → notebook-indigo | Settings › Shortcuts tile for Show / Hide NoteIt. |
| `tile-new-note` | `{notebook-orange}` | `{notebook-orange}` | alias → notebook-orange | Settings › Shortcuts tile for New Note. |
| `tile-quick-capture` | `{notebook-blue}` | `{notebook-blue}` | alias → notebook-blue | Settings › Shortcuts tile for Quick Capture. |
| `brand-violet` | `#6e5bff` | `#6e5bff` | fixed hex (same in both appearances) | The NoteIt brand colour: app icon ground, Quick Capture tile, lockup tiles, marketing. Fixed in both themes. White on it is 4.6:1, so white lockups and labels are fine at any size. |
| `brand-deep` | `#1e2470` | `#1e2470` | fixed hex (same in both appearances) | Logo ink: the single-colour mark and wordmark on light grounds, the dark app icon ground, the heading line on the page. Fixed in both themes; 1.2:1 on surface-editor Dark, so on dark grounds switch the mark to white or ink. |
| `brand-pencil` | `#ffc93c` | `#ffc93c` | fixed hex (same in both appearances) | The speed streaks in the app icon. Decorative only, never text; 1.5:1 on white, so it only appears on brand-violet or brand-deep. |
| `brand-paper` | `#fbf8f1` | `#fbf8f1` | fixed hex (same in both appearances) | The note page in the app icon and the light lockup tile. Fixed in both themes; brand-deep on it is 13:1. |

## Type

All sizes in pt. Editor styles scale from the user's body size B (default 15); the px values below are at B = 15.

| Group | Style | Family | Size | Weight | Line height | Tracking | Usage |
|---|---|---|---|---|---|---|---|
| Editor | `title` | sans | 27px | 700 |  |  | Body size + 12. One per note, usually the first line. 10 pt after. |
| Editor | `heading` | sans | 20px | 600 |  |  | Body size + 5. 10 pt before, 6 pt after. |
| Editor | `subheading` | sans | 16.5px | 600 |  |  | Body size + 1.5. 6 pt before, 4 pt after. |
| Editor | `body` | sans | 15px | 400 | 1.15 |  | The default 15 pt; the user sets 11–24 pt in Settings › Editor and every editor style scales from it. 6 pt after. |
| Editor | `quote` | sans | 15px | 400 | 1.15 |  | Body size, 18 pt indent with a vertical bar in hairline. |
| Editor | `table-header` | sans | 14px | 600 |  |  | Body size − 1, first table row only, on fill-quiet, 8 pt cell padding. |
| Code | `code-block` | mono | 14px | 400 | 1.1 |  | Body size − 1 in SF Mono, 14 pt inset, on fill-quiet with radius-card corners. |
| Code | `inline-code` | mono | 14px | 500 |  |  | Body size − 1, medium, on fill-quiet. Also the keycap face. |
| Chrome | `card-title` | sans | 13px | 600 |  |  | Note card title; 'New Note' in ink-secondary when the note is empty. |
| Chrome | `card-preview` | sans | 12px | 400 | 16px |  | Note card preview, two lines max, ink-secondary. |
| Chrome | `card-meta` | sans | 11px | 400 |  |  | Relative date and notebook name on cards, ink-secondary. |
| Chrome | `row` | sans | 13px | 400 |  |  | Sidebar rows, menu bar panel rows, Settings labels. |
| Chrome | `row-meta` | sans | 11px | 400 |  |  | Menu bar row preview and short time ('15m', 'Yesterday', 'Mon'). |
| Chrome | `section-label` | sans | 10px | 600 |  | 0.6px | Menu bar section headers. Always set in uppercase (text-transform: uppercase), +0.6 tracking, ink-secondary. |
| Chrome | `capture-title` | sans | 22px | 600 |  |  | The Title field in Quick Capture. |
| Chrome | `capture-body` | sans | 14px | 400 |  |  | The body area in Quick Capture. |
| Brand | `wordmark` | sans italic | 34px | 800 | 1 | -0.5px | SF Pro Heavy Italic, tight. The logotype beside the Swift Page mark; the italic leans the same way the note flies in. Always two-tone: "Note" in the lockup ink, "It" in the accent tone (brand-violet on light grounds, brand-pencil on brand-deep or dark, brand-deep on brand-violet), because in SF Pro a capital I is a plain bar and a one-colour NoteIt reads as Notelt. Outline it to paths for production artwork. |

Families: `sans` = -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif; `mono` = ui-monospace, "SF Mono", Menlo, monospace; `rounded` = ui-rounded, "SF Pro Rounded", -apple-system, BlinkMacSystemFont, system-ui, sans-serif. In Swift: `.system(...)`, `.system(..., design: .monospaced)`, `.system(..., design: .rounded)`.

## Spacing

| Token | Value | Usage |
|---|---|---|
| `space-4` | `4px` | Tightest gap: icon to count, keycap to keycap. |
| `space-6` | `6px` | Paragraph spacing after body; heading after. |
| `space-8` | `8px` | Table cell padding; gap between card lines. |
| `space-10` | `10px` | Space after title; before heading. |
| `space-12` | `12px` | Card padding; row gaps in the menu bar panel. |
| `space-14` | `14px` | Code block inset. |
| `space-16` | `16px` | Panel padding in Quick Capture and the menu bar panel. |
| `quote-indent` | `18px` | Block quote indent, bar included. |
| `editor-inset-y` | `22px` | Minimum vertical inset of the writing surface. |
| `editor-inset-x` | `28px` | Minimum horizontal inset of the writing surface. |

## Radius

| Token | Value | Usage |
|---|---|---|
| `radius-toolbar` | `6px` | Formatting toolbar buttons. All corners are continuous (squircle) in the app. |
| `radius-tile` | `7px` | Hotkey tiles in Settings › Shortcuts. |
| `radius-card` | `10px` | Composer card, code blocks, note cards. |
| `radius-preview` | `12px` | The New Notebook icon preview tile. |
| `radius-panel` | `16px` | Quick Capture panel. |
| `radius-glyph` | `28%` | Notebook glyph tiles: 28% of the tile's side, whatever its size. |
| `radius-capsule` | `9999px` | Notebook chip in the note header, Saved toast. |

## Sizes

| Token | Value | Usage |
|---|---|---|
| `hairline-width` | `0.5px` | Every separator and outline. |
| `toolbar-button-w` | `26px` | Formatting toolbar button width. |
| `toolbar-button-h` | `24px` | Formatting toolbar button height. |
| `empty-state-circle` | `88px` | Tinted circle behind an empty-state symbol. |
| `about-icon` | `96px` | App icon in Settings › About. |
| `reading-max` | `760px` | Maximum width of the editor text column, centred. |
| `sidebar-w` | `220px` | Sidebar ideal width (190–320). |
| `note-list-w` | `300px` | Note list ideal width (240–440). |
| `menubar-panel-w` | `340px` | Menu bar panel width (460 tall). |
| `capture-w` | `580px` | Quick Capture panel width (330 tall). |
| `settings-w` | `520px` | Settings window width. |

## Opacity

| Token | Value | Usage |
|---|---|---|
| `tint-chip` | `0.14` | Notebook colour at this opacity fills the note-header chip. |
| `tint-glyph` | `0.16` | Notebook colour at this opacity fills glyph tiles and menu bar glyph backgrounds; also empty-state circles. |
