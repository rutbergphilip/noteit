NoteIt is a native macOS notes app: Apple Notes speed, power-user formatting, capture from anywhere. Everything here describes the current build. The visuals are engineering defaults that sit close to macOS itself, so build anything new to feel like Apple made it, then let the note content be the loudest thing on screen.

The name is **NoteIt**: one word, capital N, capital I, no space, in every place it appears (UI, App Store, website, file names use `noteit`). Never "Noteit", "Note It" or "NOTEIT". The app was developed under the working name Inkwell; nothing user-facing should say Inkwell any more. The logo is Swift Page; see Logo and icon.

## Principles

| Principle | Means | Shows up as |
|---|---|---|
| Speed | Nothing between the thought and the note | Global hotkeys, Quick Capture, autosave ~0.5 s after typing stops |
| Calm | Quiet chrome; content is the hero | System materials, soft tints, a 760 pt reading column, no badges or nags |
| Native | Feels like Apple made it | SF Pro, SF Symbols, sidebar vibrancy, standard menus and Settings |
| Private | Your notes are files on your Mac | No account, no network code |
| Keyboard-first | Every frequent action has a shortcut | ~30 editor shortcuts, markdown triggers, a keyboard-driven menu bar panel |
| Delightful | Small moments of craft | Round checkboxes, keycap chips, the Saved toast, the reject shake |

## Voice and copy

- Write UI labels in Title Case, like macOS menus: "New Note", "Open NoteIt", "Record Shortcut", "Edit Notebook…".
- Write messages and placeholders in sentence case and end unfinished prompts with a real ellipsis (…), not three dots: "Start writing…", "Jot down a quick note…", "Type Shortcut…".
- Keep confirmations short and past-tense with a destination: "Saved to Inbox".
- Empty states are a title plus one plain sentence plus one action: "No Notes Yet", "No Pinned Notes", "No Results", "No Note Selected".
- Address the user as "you" only when needed; most copy has no pronoun at all. The app speaks about itself by name ("Show / Hide NoteIt", "Quit NoteIt").
- Dates are relative and compact: "1 minute ago" on cards, "15m", "Yesterday", "Mon" in the menu bar; the editor header is absolute, "Edited 12 Oct 2026 at 10:28".
- Show shortcuts as glyphs, never spelled out: ⌘↩, ⇧⌘N, ⌥⌘F.
- No emoji in UI copy. No exclamation marks. Match deletion copy to what actually happens (today the dialog says "permanently deleted" while bodies move to a hidden trash; fix the words or the behaviour, not neither).

## Color

- Ground almost everything on `surface-editor`; use `surface-window` for window chrome and Settings, `surface-raised` for small floating surfaces (composer card, keycaps, toast).
- Set text in `ink`; metadata (previews, dates, counts) in `ink-secondary`; placeholders only in `ink-tertiary`.
- Never define a brand accent in UI. `accent` stands in for the user's system accent: active toolbar buttons, filled checkboxes, focus ring, prominent CTAs.
- Notebook colours are the user's, chosen from the 10 `notebook-*` swatches. They paint glyphs, list dots, the header chip at `tint-chip` and glyph tiles at `tint-glyph`. Never set text in a notebook colour, and always show the notebook's name beside its colour, because yellow, green, teal and orange miss 3:1 on white.
- `pinned` (orange) and `recent` (teal) are fixed meanings in the sidebar; don't reuse them for anything else.
- `success` and `destructive` always travel with words ("Saved to Inbox", "Discard").
- Separate things with a `hairline` at `hairline-width`, not shadows. Tint code, inline code and hovers with `fill-quiet`.
- The four `brand-*` tokens (`brand-violet`, `brand-deep`, `brand-pencil`, `brand-paper`) are the logo's colours. Use them for the app icon, the Quick Capture tile, the website and marketing, never in note content or app chrome. Never put `brand-deep` straight on a dark surface; it vanishes.
- Every new brand colour must survive next to a sidebar full of rainbow notebooks. Keep chrome neutral.

Dark mode is fully supported: system neutrals flip, notebook colours stay fixed, editor text colours are stored as light values and adapted automatically.

## Type

- Use the system font only: SF Pro (`sans`) for everything, SF Mono (`mono`) for code and keycaps, SF Rounded (`rounded`) only for the wordmark. No font files ship; these are system faces.
- Editor styles scale from the user's body size B (default 15 pt, range 11–24): `title` B+12 bold, `heading` B+5 semibold, `subheading` B+1.5 semibold, `body` B at 1.15 line height, `code-block` and `inline-code` B−1 mono, `table-header` B−1 semibold. The specimens show B = 15.
- Chrome sizes are fixed: `card-title` 13, `card-preview` 12, `card-meta` 11, `row` 13, `row-meta` 11, `section-label` 10 uppercase with +0.6 tracking, `capture-title` 22, `capture-body` 14.
- A custom display face is acceptable for marketing only, never in the app.

## Spacing and layout

- Space on a 4 / 6 / 8 / 10 / 12 / 14 / 16 pt rhythm (`space-4` … `space-16`).
- Centre the editor text in a column no wider than `reading-max` (760 pt), with at least `editor-inset-x` and `editor-inset-y` around it.
- The main window is three columns: sidebar (190 / 220 / 320), note list (240 / 300 / 440), flexible editor. Default window 1120 × 720, minimum 820 × 480.
- When the editor narrows, the formatting toolbar collapses groups into a "…" menu in this order: Size, Layout, Insert, Color, Lists.

## Shape

- All corners are continuous (squircle) in the app. On the web, plain `border-radius` with the same token is the closest match.
- `radius-toolbar` 6 for toolbar buttons, `radius-tile` 7 for hotkey tiles, `radius-card` 10 for cards and code blocks, `radius-preview` 12 for the notebook icon preview, `radius-panel` 16 for Quick Capture, `radius-capsule` for chips and the toast, `radius-glyph` (28% of the side) for notebook glyph tiles.
- Checkboxes are circles, never squares.

## Motion

Motion today is minimal and fast. Keep it "calm but quick" and honour Reduce Motion by falling back to a plain fade or nothing.

| Moment | Now |
|---|---|
| Quick Capture | Fade in 0.12 s, out 0.10 s |
| Saved toast | Fade + slide from trailing edge, 0.2 s ease-out, visible ~1.8 s |
| Hotkey recorder | 0.15 s fades; 0.3 s shake on reject, with a beep |
| Menu bar selection | 0.12 s scroll to highlight |
| Everything else | System default or none |

A fuller motion language is planned for later: Quick Capture entrance and save, note creation, checkbox fill and strikethrough sweep, pin, and drag and drop.

## Iconography

- Use SF Symbols everywhere, hierarchical rendering in empty states. Known symbols: `note.text` (All Notes), `pin.fill` (Pinned), `clock` (Recent), `number` (tags), `square.and.pencil` (new note), `bolt.fill` (Quick Capture), `macwindow`, `pencil.line` (menu bar today; replace with `noteit-menubar.svg`), `tray`, `command`, `lightbulb` (seed notebooks). The New Notebook sheet offers 32 curated symbols.
- Notebook glyphs come two ways: the symbol in the notebook colour, or a rounded-square tile (`radius-glyph`) filled at `tint-glyph` with the symbol in full colour.
- SF Symbols cannot be redistributed, so the component previews here use small hand-drawn stand-in glyphs. Treat them as placeholders for the matching symbol, not as icons to ship.
- Outside the app (website, docs, onboarding, App Store art), use the NoteIt icon set in `assets/Icons`: 32 glyphs on a 24 grid, 1.75 stroke, round caps. It is drawn to sit beside SF Symbols Regular. Use 16–32 px, colour with `ink` or `accent`.
- Keycaps are rounded chips in `inline-code` on `surface-raised` with a `hairline` border.

## Logo and icon

The logo is **Swift Page**: a note page with a folded corner, a heading and text lines (one with a round checkbox), flying in on three speed streaks. Capture speed on the left, formatted notes on the right. See the Logo card; files are in `assets/Logos`, `assets/AppIcons` and `assets/MenuBar`.

- **Mark:** `noteit-mark.svg` in `brand-deep` on light grounds; `noteit-mark-white.svg` on `brand-violet`, `brand-deep` or any dark ground. Below 32 px use `noteit-mark-small.svg` (three lines, two streaks, no checkbox).
- **Wordmark:** "NoteIt" in `wordmark` (SF Pro Heavy Italic, −0.5 tracking), set to the right of the mark with a gap of about a quarter of the mark's height; a stacked lockup puts it centred below. It is always two-tone: "Note" in the lockup ink, "It" in the accent tone (`brand-violet` on light grounds, `brand-pencil` on `brand-deep` or dark grounds, `brand-deep` on `brand-violet`). In SF Pro the capital I is a plain bar, so a one-colour wordmark reads as "Notelt". Running text (menus, copy) stays one colour. Outline the wordmark for production files.
- **App icon:** `noteit-icon-light.svg` (violet ground, paper page, deep heading, violet lines, pencil streaks), `noteit-icon-dark.svg` and `noteit-icon-tinted.svg` for the macOS appearance modes, `noteit-icon-small.svg` for the 16 and 32 px slots.
- **Menu bar:** `noteit-menubar.svg` (page only) at rest, `noteit-menubar-capturing.svg` (page with streaks) while Quick Capture is open. Both are template images.
- **Clear space:** keep at least the width of the longest streak free around the mark.
- **Colours:** only the four `brand-*` tokens. Never recolour the streaks to a notebook colour, never set the mark in `accent` (that is the user's colour, not ours).
- **Don't:** rotate it, add a shadow or gradient, separate the streaks from the page, or put the full-detail mark below 32 px.

The earlier concept rounds (A–L) are kept in the `LogoConcepts` asset group for reference only.

## Accessibility

- Focus is a solid 3 px ring in `focus-ring` (alias of `accent`), at least 3.4:1 on every surface in both themes.
- Known misses, kept exact because they are the system's own values: `ink-secondary` in Light (3.98:1 on white) for 11–12 pt metadata; `accent` and `destructive` as small text in Light; the four lightest notebook colours as glyphs on white. Each carries its meaning in words as well.
- Not yet audited: VoiceOver labels exist on some controls only.
