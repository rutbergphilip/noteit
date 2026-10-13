# NoteIt design assets

This folder holds NoteIt's logo and icon assets. See [`BRAND.md`](BRAND.md) for the name, the logo and how to use them.

## Assets

| Path | What |
|---|---|
| [`assets/logo/`](assets/logo/) | Swift Page mark: colour, white and small SVGs, plus 512 px PNGs |
| [`assets/app-icon/`](assets/app-icon/) | App icon SVG masters (light, dark, tinted, small) and an `AppIcon.iconset/`; `alt-paper/` has an earlier paper + pencil icon and its render script |
| [`assets/menu-bar/`](assets/menu-bar/) | Menu bar template images, idle and capturing, as SVG and PNG |
| [`assets/icons/`](assets/icons/) | Line icon set for the website, onboarding and docs |

The shipping app icon and menu bar glyph are drawn by `scripts/make_icon.swift` and `scripts/make_menubar_glyph.swift`; re-render both with `scripts/render_icon.sh`.

## Banners

README banners and the GitHub social preview image live in [`.github/assets/`](../.github/assets/). The hero and strip banners are animated SVGs, with static PNG versions alongside.
