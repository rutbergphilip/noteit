# NoteIt design system (handoff)

This folder is the design source of truth for the NoteIt macOS app (formerly developed as "Inkwell"). It was exported from the NoteIt design system and is meant to be read by people and coding agents.

> **Owner decision:** the app icon and menu bar glyph use the squiggle + pencil mark; the Swift Page artwork is kept as an alternative. The shipped icon (white squiggle + pencil on the violet → indigo gradient) is rendered by `scripts/make_icon.swift` into `Resources/AppIcon.iconset`; an earlier paper-sheet + yellow pencil artwork is kept as an alternative in `assets/app-icon/alt-paper/`; the menu bar glyph by `scripts/make_menubar_glyph.swift` (PNGs in `Sources/NoteIt/Resources`, SVGs in `Resources/MenuBarGlyph`). Re-render both with `scripts/render_icon.sh`.

## Read in this order

1. `IMPLEMENTATION.md` — the work to do, in order, with acceptance criteria. Start here if you are implementing.
2. `BRAND.md` — the brand book: naming, voice and copy, colour, type, spacing, shape, motion, iconography, logo rules, accessibility.
3. `tokens.md` — every token with its light and dark value **and the Swift API to use for it**. `tokens.json` is the machine-readable source.
4. `components/*.md` — one spec per UI element. Each links a reference rendering in `components/previews/` (open in a browser).

## Folder map

| Path | What |
|---|---|
| `tokens.json` | Source of truth for colours, type, spacing, radius, sizes, opacity |
| `tokens.css` | Generated CSS custom properties, used by the previews and the future website |
| `tokens.md` | Readable token table with Swift mapping |
| `BRAND.md` | Brand book |
| `IMPLEMENTATION.md` | Task plan for the app |
| `components/` | Component specs and HTML reference renderings |
| `assets/logo/` | Swift Page mark: `noteit-mark.svg` (brand-deep), `-white`, `-small` (≤ 32 px), plus 512 px PNGs |
| `assets/app-icon/` | Icon SVG masters (light, dark, tinted, small) and a ready `AppIcon.iconset/` for `iconutil` |
| `assets/menu-bar/` | Template images: idle and capturing, SVG plus `…Template.png` / `…Template@2x.png` |
| `assets/icons/` | 32-glyph line icon set (24 grid, 1.75 stroke) for website, onboarding and docs |

## Rules of thumb

- The name is **NoteIt**. Exactly that casing everywhere user-facing; `noteit` in identifiers and file names.
- The app stays native: system font, SF Symbols in app chrome, system semantic colours. The `brand-*` colours are for the icon, Quick Capture tile, About pane and marketing only.
- HTML previews are visual specs. Rebuild natively in SwiftUI/AppKit; never embed web views.
