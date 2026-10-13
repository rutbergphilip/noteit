# Implementation plan: Inkwell → NoteIt

Work through the tasks in order. Each task should land as its own commit and must leave `swift build` green. The app is SwiftPM-only (no Xcode project), macOS 14+, SwiftUI + AppKit, no third-party dependencies; keep it that way.

Current layout for reference (before the rename): `Sources/Inkwell/{App,Model,Views,Editor,MenuBar,Hotkeys,Settings}`, `scripts/build_app.sh`, `scripts/make_icon.swift`, data in `~/Library/Application Support/Inkwell/`, bundle id `com.inkwell.app`.

---

## 1. Rename the product to NoteIt

**Code and build**

- Rename the SwiftPM target and executable `Inkwell` → `NoteIt`, and the folder `Sources/Inkwell` → `Sources/NoteIt` (use `git mv`).
- Rename types that carry the name: `InkwellApp` → `NoteItApp`, `InkwellTextView` → `NoteItTextView`, and any other `Inkwell*` symbol.
- `scripts/build_app.sh`: produce `build/NoteIt.app`, install to `~/Applications/NoteIt.app`, `CFBundleName`/`CFBundleDisplayName` = `NoteIt`, `CFBundleExecutable` = `NoteIt`.
- Bundle id: replace `com.inkwell.app` with a new constant defined in **one** place. Use `TODO_BUNDLE_ID` = `com.noteit.app` for now and leave a `// TODO(owner): pick reverse-DNS of a domain you own` comment. Do not invent a domain.
- Environment variables: `INKWELL_*` → `NOTEIT_*` (`NOTEIT_DATA_DIR`, `NOTEIT_EDITOR_SELFTEST*`, `NOTEIT_INSTALL_DIR`, `NOTEIT_VERSION`, `NOTEIT_BUILD`). For one release, still read the old `INKWELL_*` names as a fallback.

**User-facing strings** (see `BRAND.md` › Voice and copy)

- Every "Inkwell" in UI → "NoteIt": menu items (Open NoteIt, Quit NoteIt, Show / Hide NoteIt, "NoteIt Notes" in the Window menu), Settings › About, menu bar panel header, hotkey titles, alerts, accessibility labels.
- Seed content: the welcome note becomes "Welcome to NoteIt". Only affects fresh installs; **never rewrite existing user notes**.

**Data migration (must not lose notes)**

- On launch, before `NoteStore` loads: if `~/Library/Application Support/NoteIt/` does not exist and `~/Library/Application Support/Inkwell/` does, **move** the folder (atomic `FileManager.moveItem`), including hidden `.initialized` and `.trash/`. If the move fails, fall back to using the old folder and log it; never seed over an existing library.
- Skip migration when `NOTEIT_DATA_DIR` (or legacy `INKWELL_DATA_DIR`) is set.
- `UserDefaults`: the bundle id changes, so the defaults domain changes. On first launch of NoteIt, copy keys from `UserDefaults(suiteName: "com.inkwell.app")` (`hideDockIcon`, `showMenuBarIcon`, `editorFontSize`, `defaultNotebookID`, hotkey bindings) into the new standard defaults if they are not already set. Mark completion with a `didMigrateFromInkwell` key.
- Launch at login: if the old login item was enabled, re-register with `SMAppService.mainApp` under the new bundle and tell the user once if approval is required.

**Acceptance**

- `swift build` and `./scripts/build_app.sh` succeed; the app launches as NoteIt.
- An existing Inkwell library and settings appear unchanged in NoteIt after first launch.
- `grep -rni inkwell Sources scripts` only matches migration and fallback code (with a comment saying why).

---

## 2. Design tokens in Swift

Create `Sources/NoteIt/Design/Tokens.swift` from `tokens.json` / `tokens.md`.

- **Semantic colours map to system colours**, not hex: follow the *Swift mapping* column in `tokens.md` (`ink` → `NSColor.labelColor`, `accent` → `controlAccentColor`, `pinned` → `systemOrange`, …). The hex values for these are approximations used by web previews only.
- **Fixed colours** (notebook palette, hotkey tiles, `brand-*`) are hard-coded hex. Notebook palette must stay identical to the current `Model/Models.swift` values (it is), so move the palette into `Tokens` and have `Models.swift` reference it.
- Spacing, radius, size and opacity tokens become `CGFloat` constants, e.g. `Tokens.Radius.card = 10`, `Tokens.Opacity.tintChip = 0.14`. Radii are continuous corners: `RoundedRectangle(cornerRadius:style: .continuous)`.
- Type: keep `EditorStyles.swift` as the editor type scale (it already matches `tokens.md`); add the chrome styles (`cardTitle`, `cardPreview`, `cardMeta`, `row`, `rowMeta`, `sectionLabel`, `captureTitle`, `captureBody`, `wordmark`) as SwiftUI `Font` helpers.
- Replace literal numbers in views with tokens where they match exactly. **Do not change any rendered value** in this task; it is a refactor.

**Acceptance:** no visual change in light or dark mode; no hex literals remain in `Views/`, `MenuBar/` or `Settings/` except via `Tokens`.

---

## 3. App icon

- Add `Resources/AppIcon.iconset/` by copying `design/assets/app-icon/AppIcon.iconset/` (10 PNGs; 16 and 32 px slots use the simplified small master on purpose).
- Change `scripts/build_app.sh` to run `iconutil -c icns Resources/AppIcon.iconset -o …/AppIcon.icns` instead of rendering `scripts/make_icon.swift`. Delete `make_icon.swift`.
- The runtime fallback icon used by `swift run` (unbundled) should load the same artwork (e.g. the 512 px PNG as a SwiftPM resource) instead of drawing the old placeholder.
- Dark and tinted variants (`noteit-icon-dark.svg`, `noteit-icon-tinted.svg`) are provided for a later Icon Composer `.icon` file; out of scope for now, just keep them in `design/`.

**Acceptance:** the built `.app` shows the Swift Page icon in Finder, Dock, Settings › About (96 pt) and the menu bar panel header.

---

## 4. Menu bar glyph

- Add `design/assets/menu-bar/noteit-menubarTemplate.png` (+ `@2x`) and `noteit-menubar-capturingTemplate.png` (+ `@2x`) as resources. Load as `NSImage`, set `isTemplate = true`, size 18 × 18 pt.
- Replace the SF Symbol `pencil.line` in the `MenuBarExtra` label with the idle image. While the Quick Capture panel is visible, show the capturing image; switch back when it hides.

**Acceptance:** icon tints correctly in light and dark menu bars and with a coloured wallpaper; state changes when Quick Capture opens and closes.

---

## 5. Brand touches

- **Settings › About:** 96 pt app icon, then the two-tone wordmark: "Note" in `labelColor` and "It" in `brand-violet`, SF Pro Heavy Italic 26 pt with −0.5 tracking (`wordmark` style scaled down; build it as an `AttributedString` or two `Text` views concatenated), then the version, then "Notes that keep up with your thinking."
- **Quick Capture tile:** keep the ⚡ tile but fill it solid `brand-violet` instead of the old indigo gradient (see `BRAND.md` › Color: no gradients the tokens don't define).
- **Copy pass:** apply `BRAND.md` › Voice and copy. In particular, the delete dialog currently says "permanently deleted" while bodies go to `.trash/`; change the text to "This note will be deleted." until a Trash UI exists.

---

## 6. Component conformance (only where the current build differs)

Check each spec in `components/*.md` against the current view and fix mismatches only. Most already match because the specs were written from the current build. Pay attention to:

- `Checkbox.md`: round, accent-filled, strikethrough + secondary colour when checked.
- `NoteCard.md`: pinned-first sort, two-line preview, notebook dot omitted inside that notebook.
- `Toast.md`: capsule, check glyph in `success`, text in `ink`.
- `EmptyState.md`: 88 pt circle at 16% tint.
- Focus ring: 3 px solid accent (`BRAND.md` › Accessibility).

Do not port the HTML previews; they are visual references.

---

## Out of scope

Website, App Store screenshots, onboarding flow, tag chip styling, Trash UI, Icon Composer variants. The `assets/icons/` set is for those later surfaces, not for app chrome (which keeps SF Symbols).
