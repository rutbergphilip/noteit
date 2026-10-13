# NoteIt design system

This folder holds NoteIt's design system: the brand guidelines, design tokens, component specs and icon assets. The macOS app follows it, and the planned web app and website will too.

The app icon and menu bar glyph use the squiggle + pencil mark. The icon (a white squiggle and pencil on a violet → indigo gradient) is drawn by `scripts/make_icon.swift` and pre-rendered into `Resources/AppIcon.iconset`. The menu bar glyph is drawn by `scripts/make_menubar_glyph.swift`, with PNGs in `Sources/NoteIt/Resources` and SVGs in `Resources/MenuBarGlyph`. Re-render both with `scripts/render_icon.sh`. The Swift Page artwork in `assets/logo/`, `assets/app-icon/` and `assets/menu-bar/` is kept as an alternative, as is an earlier paper sheet + yellow pencil icon in `assets/app-icon/alt-paper/`.

## Where to start

1. `BRAND.md`: naming, voice and copy, colour, type, spacing, shape, motion, iconography, logo rules and accessibility.
2. `tokens.md`: every token with its light and dark value **and the Swift API to use for it**. `tokens.json` is the machine-readable source.
3. `components/*.md`: one spec per UI element. Each links a reference rendering in `components/previews/` (open it in a browser).

## Folder map

| Path | What |
|---|---|
| `tokens.json` | Source of truth for colours, type, spacing, radius, sizes, opacity |
| `tokens.css` | Generated CSS custom properties, used by the previews and the future website |
| `tokens.md` | Readable token table with Swift mapping |
| `BRAND.md` | Brand book |
| `components/` | Component specs and HTML reference renderings |
| `assets/logo/` | Swift Page mark: `noteit-mark.svg` (brand-deep), `-white`, `-small` (≤ 32 px), plus 512 px PNGs |
| `assets/app-icon/` | Icon SVG masters (light, dark, tinted, small) and a ready `AppIcon.iconset/` for `iconutil` |
| `assets/menu-bar/` | Template images: idle and capturing, SVG plus `…Template.png` / `…Template@2x.png` |
| `assets/icons/` | 32-glyph line icon set (24 grid, 1.75 stroke) for website, onboarding and docs |

## Rules of thumb

- The name is **NoteIt**. Exactly that casing everywhere user-facing; `noteit` in identifiers and file names.
- The app stays native: system font, SF Symbols in app chrome, system semantic colours. The `brand-*` colours are for the icon, Quick Capture tile, About pane and marketing only.
- HTML previews are visual specs. Rebuild natively in SwiftUI/AppKit; never embed web views.

## Banners

README banners and the GitHub social preview image live in [`.github/assets/`](../.github/assets/). The hero and strip banners are animated SVGs, with static PNG versions alongside.
