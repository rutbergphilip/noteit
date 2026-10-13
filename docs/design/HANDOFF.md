# Inkwell — design handoff

> Moved from the repository `README.md`. The user-facing README is now [`../../README.md`](../../README.md).

**Note-taking, done better.** A native macOS notes app: Apple Notes speed, power-user formatting, and capture from anywhere.

> **Who this document is for:** primarily the **design team** (UX, logotype and app icon, motion, brand). It covers what the product is, who it serves, how the current build looks and behaves, and what we need from you. Engineers can skip to [For engineers](#11-for-engineers).
>
> **Status (Oct 2026):** working app, macOS 14+, single user. Local-first, with optional sync between your Macs through storage you own (see [Sync & storage](#510-sync--storage)). Working name **Inkwell**, backup name **NoteIt** (see [Naming](#8-naming-inkwell-vs-noteit)). Visuals are engineering defaults, and the app icon is a code-drawn placeholder.

---

## Contents

1. [Tagline options](#1-tagline-options)
2. [The product in 30 seconds](#2-the-product-in-30-seconds)
3. [Who it's for](#3-who-its-for)
4. [Core principles](#4-core-principles)
5. [Product tour](#5-product-tour)
6. [Current visual language](#6-current-visual-language)
7. [Design brief & deliverables](#7-design-brief--deliverables)
8. [Naming: Inkwell vs NoteIt](#8-naming-inkwell-vs-noteit)
9. [Known gaps & opportunities](#9-known-gaps--opportunities)
10. [Keyboard shortcut reference](#10-keyboard-shortcut-reference)
11. [For engineers](#11-for-engineers)

---

## 1. Tagline options

These are proposals. Pick one, combine them, or replace them.

| # | Tagline | Angle |
|---|---|---|
| 1 | **Note-taking, done better.** | Confident and broad; the owner's own phrasing |
| 2 | **Notes at the speed of thought.** | Speed and capture |
| 3 | **Apple Notes, with superpowers.** | Instantly legible positioning (trademark-sensitive, so use it internally or in pitches, not in store copy) |
| 4 | **Capture anything. Find it instantly. Make it beautiful.** | Covers the full loop: capture, find, format |
| 5 | **Notes that keep up with your thinking.** | Already shipped in Settings › About |

---

## 2. The product in 30 seconds

**Vision.** A Mac notes app as calm and instant as Apple Notes, with the formatting depth and keyboard control power users expect from tools like Bear or Obsidian. It needs no account and no Inkwell cloud, and nothing loads between you and your note.

**Problem.**

- Apple Notes is fast and native, but it's thin for structured content and it's hard to drive from the keyboard.
- Notion and Obsidian are powerful, but they're heavy: web-tech UIs, setup, plugins, accounts, and a moment of friction before every note.
- Ideas get lost in the seconds between "I should write that down" and having a note open.

**Our answer.**

- **Capture from anywhere:** a global hotkey opens a Spotlight-style Quick Capture panel over any app, and the menu bar panel works from any Space.
- **Organize lightly:** colored notebooks with icons, automatic `#hashtag` tags, and Pinned and Recent smart views.
- **Format richly:** headings, lists, checklists, tables, code blocks, quotes, colors, highlights, links and images, plus markdown-as-you-type.
- **Stay native, local and private:** SwiftUI and AppKit with no third-party dependencies. Everything lives in a folder on your Mac.
- **Sync on your terms:** optionally, keep your Macs in sync through a folder or S3 bucket you own, end-to-end encrypted by default. There's no Inkwell account and no Inkwell server.

**Why now.** People are tired of subscription, cloud-first, Electron note apps. macOS 14+ gives us mature SwiftUI, `MenuBarExtra` and `SMAppService` login items, so a small team can build a native app with real polish.

**Positioning.** *Apple Notes' speed and nativeness, plus a pro's formatting and keyboard control, without Notion's or Obsidian's weight.*

### Honest comparison

Legend: ✅ yes · ◐ partial or limited · ❌ no. "Inkwell" means **today's build**. Competitor columns reflect general, publicly known capabilities; verify them before using in marketing.

| | **Inkwell (today)** | Apple Notes | Notion | Bear | Obsidian |
|---|---|---|---|---|---|
| Native Mac UI | ✅ SwiftUI + AppKit | ✅ | ❌ web/Electron | ✅ | ❌ Electron |
| Opens and creates notes instantly | ✅ | ✅ | ◐ | ✅ | ✅ |
| Global hotkey capture over any app | ✅ user-assigned | ◐ Quick Note | ◐ | ◐ | ◐ via plugins |
| Menu bar panel with search and quick note | ✅ | ❌ | ❌ | ❌ | ❌ |
| Markdown-as-you-type in a rich editor | ✅ | ◐ | ✅ | ✅ | ✅ (markdown source) |
| Tables | ✅ | ✅ | ✅ | ✅ | ✅ |
| Text colors and highlights | ✅ | ◐ | ✅ | ◐ | ◐ |
| Notebooks with color and icon | ✅ | ◐ folders | ✅ | ❌ tags only | ◐ folders |
| `#hashtag` tags | ✅ | ✅ | ❌ | ✅ | ✅ |
| Local-first, no account | ✅ | ❌ iCloud | ❌ | ◐ | ✅ |
| Sync across devices | ✅ Macs only, via your own folder or S3 bucket | ✅ | ✅ | ✅ | ✅ (paid) |
| iPhone / iPad app | ❌ | ✅ | ✅ | ✅ | ✅ |
| Export (Markdown/PDF) | ❌ **not yet** | ◐ | ✅ | ✅ | ✅ |
| Collaboration | ❌ | ✅ | ✅ | ❌ | ◐ |
| Plugins / extensibility | ❌ | ❌ | ◐ | ❌ | ✅ |

**Where we win today:** capture speed (hotkey, floating panel, menu bar), a native feel, and rich formatting without learning a syntax. **Where we lose today:** mobile, export and collaboration. Sync works between Macs only, and it needs storage the user brings.

---

## 3. Who it's for

### Persona 1: Mika, the power user who keeps a shortcut cheat-sheet

*Developer, tiling-terminal fan, lives on the keyboard.*

- **Story (the owner's first real use case).** Mika customizes everything: Ghostty splits, themes, window managers. He keeps forgetting his own bindings. Inkwell's very first seed note is literally his cheat-sheet:

  | Shortcut | Action |
  |---|---|
  | ⌃⌘E | Equalize the size of all split tabs in Ghostty |
  | ⇧⌘L | Switch theme mode in Ghostty |

- **Needs:** recall in two keystrokes, a real table rather than ASCII art, monospaced keys, and tags like `#ghostty`.
- **Inkwell moments:** he binds *Show / Hide Inkwell* to a global hotkey, presses it, presses ⌘F, types "ghostty", reads the answer, and presses the hotkey again to vanish. He never touches the mouse.

### Persona 2: Sara, the meeting-hopper

*Product manager, 6–8 calls a day.*

- **Needs:** jot an action item mid-call without leaving Zoom, and sort it later.
- **Inkwell moments:** the Quick Capture hotkey brings up a floating panel over the call, she types a title and a line, and ⌘↩ saves it to Inbox. Later, checklists in the note track follow-ups, and the important note gets pinned.

### Persona 3: Leo, the student or researcher

*Collects quotes, links, images and code snippets.*

- **Needs:** rich content in one place, light structure, and fast search.
- **Inkwell moments:** a notebook per course with its own color and icon, pasted images, block quotes, code blocks, highlights in yellow and green, and `#exam` tags across notebooks.

---

## 4. Core principles

| Principle | What it means | How it shows up today |
|---|---|---|
| **Speed** | Nothing between the thought and the note | Global hotkeys, Quick Capture, menu bar panel, ⌘N focuses the editor immediately, autosave about 0.5 s after typing stops |
| **Calm** | Quiet chrome; the content is the hero | System materials, soft tints, comfortable reading width (≤ 760 pt), no nags. The only alert-style badge marks a sync conflict copy |
| **Native** | Feels like Apple made it | SwiftUI + AppKit, SF Symbols, system fonts, sidebar vibrancy, light and dark mode, standard menus and Settings |
| **Private & local-first** | Your notes are files on your Mac | `~/Library/Application Support/Inkwell/`, no account. Inkwell only touches the network once you connect sync, and then only your own storage, end-to-end encrypted by default |
| **Keyboard-first** | Every frequent action has a shortcut | About 30 editor shortcuts, markdown triggers, a fully keyboard-driven menu bar panel, hotkey recorder |
| **Delightful** | Small moments of craft | Round accent-filled checkboxes, keycap chips, a "Saved to Inbox" toast, a shake on an invalid hotkey, collapsing toolbar |

---

## 5. Product tour

The core loop is **Capture → Organize → Find → Recall**.

```text
 Global hotkey ─┐                      ┌─ Sidebar: notebooks · Pinned · Recent · #tags
 Menu bar ──────┼─► Quick note ─► Inbox ┤
 ⌘N in app ─────┘                      └─ ⌘F search ─► note ─► rich editor
```

### 5.1 Main window: three columns

A `NavigationSplitView` with a unified toolbar. The default size is 1120 × 720 and the minimum is 820 × 480.

| Column | Width (min / ideal / max) | Contents |
|---|---|---|
| **Sidebar** | 190 / 220 / 320 | Library, Notebooks, Tags, and a footer with a "New Notebook" button and (when sync is on) the sync status pill |
| **Note list** | 240 / 300 / 440 | Title and subtitle ("All Notes · 3 notes"), toolbar search, New Note button, note cards |
| **Editor** | flexible | Note header, formatting toolbar, rich-text editor |

### 5.2 Sidebar

- **Library:** *All Notes* (accent-colored `note.text`), *Pinned* (orange `pin.fill`), and *Recent* (teal `clock`, showing notes edited in the **last 7 days**). Each row has a count badge.
  - *Conflicts* (orange `exclamationmark.triangle.fill`) appears only while sync conflict copies exist (see §5.10).
- **Notebooks:** each row shows the notebook's SF Symbol in its color plus a count.
  - Drag a notebook to reorder it.
  - Drop notes onto a notebook to move them.
  - The context menu offers Rename (inline), Edit Notebook…, and Delete Notebook…. Deleting asks for confirmation and keeps the notes in All Notes.
- **Tags:** appears only when at least one note contains a `#hashtag`. Tags are lowercased and collected automatically from note text. A `#` counts only at the start of the text or after whitespace, an opening bracket or quote, `,` or `;`. Hashtags inside inline code, code blocks or links are ignored.
- Drop notes on **Pinned** to pin them.
- **New Notebook sheet** (⇧⌘N):
  - A large gradient tile previews the icon.
  - A name field.
  - **10 colors:** `#0A84FF #5E5CE6 #BF5AF2 #FF375F #FF453A #FF9F0A #FFD60A #30D158 #64D2FF #8E8E93`.
  - **32 curated SF Symbols** (tray, command, lightbulb, book, terminal, brain…).

### 5.3 Note list

- Plain inset list rows (no separators) styled as cards. Each card shows:
  - **title** (13 pt semibold; "New Note" in secondary when empty)
  - an orange pin if pinned
  - an orange warning triangle if it's a sync conflict copy (tooltip: "Conflict copy from *Mac name*")
  - a **2-line preview** (12 pt secondary)
  - a **relative date** ("1 minute ago")
  - a **notebook dot and name**, except when you're already inside that notebook
- Title and preview are derived automatically from the first non-empty line and the following text.
- Sort order: **pinned first, then most recently edited.**
- Search (⌘F) matches all words across the title and full body text, within the current sidebar scope. Matching ignores case, accents and width, so `cafe` finds "Café".
- Right-click offers Pin/Unpin, Move to › notebook, Mark Conflict Resolved (conflict copies only), and Delete…. The app confirms first. The dialog says "This note will be permanently deleted", and the note does disappear from the app with no undo, but its body is quietly moved to a hidden `.trash/` folder on disk (see §11). The ⌫ key also triggers delete with confirmation.
- Drag a card onto a sidebar notebook or onto Pinned.
- **Empty states** use a large SF Symbol in a tinted 88 pt circle, a title, a message and a prominent CTA:
  - "No Pinned Notes" (orange)
  - "No Notes Yet" in a notebook, using that notebook's color and icon
  - "No Results"
  - "No Note Selected" in the editor column

### 5.4 Editor

- **Header row:**
  - a **notebook chip** (a capsule tinted with the notebook color; click it to move the note)
  - "Edited 12 Oct 2026 at 10:28"
  - on a sync conflict copy, an orange capsule badge, "Conflict copy from *Mac name*", with a **Mark Resolved** button
  - a pin toggle
- **Formatting toolbar.** A compact icon bar of 26 × 24 buttons with hover and active (accent) states. Groups left to right:

  | Group | Controls |
  |---|---|
  | Style | Paragraph-style menu: Title / Heading / Subheading / Body / Monospaced / Quote |
  | Text | Bold, Italic, Underline, Strikethrough, Inline code |
  | Color | Text color popover (9 swatches + custom), Highlight popover (6 swatches) |
  | Lists | Bulleted, Numbered, Checklist |
  | Layout | Outdent, Indent, Alignment menu |
  | Insert | Link…, Table (6 × 6 hover-grid picker; first row is the header), Image…, Divider |
  | Size | Smaller, Bigger, Clear formatting |

  As the editor narrows, groups **collapse into a "…" overflow menu** in this order: Size → Layout → Insert → Color → Lists.
- **Right-click › Format** offers the full command set. Inside a table, the menu adds Add Row Above, Add Row Below and Delete Row.
- **Writing surface:**
  - text is centered with a max width of 760 pt
  - the placeholder reads "Start writing…"
  - spell-check and automatic link detection are on
  - Undo works per conversion
  - find bar via ⌥⌘F
- **Checklists** draw as **round checkboxes**: an outlined circle, or an accent-filled circle with a white check. Click to toggle. Checked items turn gray with a strikethrough.
- **Lists:**
  - Return continues the list, and Return on an empty item ends it.
  - Tab and ⇧Tab change the indent level. Bullets cycle • ◦ ▪.
  - Numbered lists renumber automatically.
- **Tables:** native text tables with a tinted header row. Tab and ⇧Tab move between cells.
- **Images:** paste, drop, or use Image…. Oversized images are scaled to fit the text width.
- **Markdown as you type:**

  | Type at line start… | …then | Result |
  |---|---|---|
  | `#` / `##` / `###` | Space | Title / Heading / Subheading |
  | `-` `*` `+` | Space | Bulleted list |
  | `1.` or `1)` | Space | Numbered list |
  | `[]` or `[ ]` / `[x]` | Space | Checklist item, unchecked / checked |
  | `>` | Space | Block quote |
  | ```` ``` ```` | Return | Code block |
  | `---` / `***` / `___` | Return | Divider |

  | Type inline… | Result |
  |---|---|
  | `**bold**` | **bold** |
  | `*italic*` | *italic* |
  | `` `code` `` | `code` |
  | `~~strike~~` | ~~strike~~ |

### 5.5 Menu bar panel

- **Icon:** the SF Symbol `pencil.line`, a placeholder for a custom template glyph.
- **Panel:** a 340 × 460 window-style dropdown containing:
  1. **Header:** app icon, "Inkwell", an **Open Inkwell** button (⌘O) and a gear for Settings.
  2. **Search field** ("Search notes"). Use ↑/↓ to move, ↩ to open, and Esc to clear the query, then close the panel.
  3. **Composer card:** "Jot down a quick note…" (1–4 lines). It includes a notebook picker, an expand button (↗ opens the text in Quick Capture), and a send button (⌘↩). Saving shows a green **"Saved to Inbox"** toast for about 1.8 s.
  4. **List:** a **PINNED** section, then **RECENT** (up to 12 notes). Each row has a notebook glyph, title, one-line preview and a short time ("15m", "Yesterday", "Mon").
  5. **Sync row** (only when sync is on): status icon, "Synced 2 minutes ago" (or the problem in plain words), and a **Sync Now** link.
  6. **Footer:** New Note ⌘N · Settings… ⌘, · Quit Inkwell ⌘Q.

### 5.6 Quick Capture panel

- **What it is:** a Spotlight-style floating panel, 580 × 330 with 16 pt continuous corners and a popover material. It **doesn't activate Inkwell**, so the app you were in stays in front.
- **Where it appears:** horizontally centered on the screen with the mouse, about 22% down from the top. It shows on every Space, including over full-screen apps.
- **Layout:**
  - a purple-gradient ⚡ tile, "Quick Capture", and a notebook picker
  - a large **Title** field (22 pt semibold)
  - a body area ("Start typing your note…", 14 pt)
  - a footer with an `esc` keycap ("to dismiss — draft is kept"), a red borderless **Discard** button (shown only when there's a draft), and a **Save Note ⌘↩** button
- **Behavior:**
  - Return in the title moves to the body.
  - ⌘↩ saves; saving an empty note beeps.
  - Esc dismisses, and so does clicking elsewhere. **The draft is kept:** title, body and notebook are still there the next time the panel opens (by hotkey or the menu bar).
  - The draft is cleared only after a successful save or an explicit **Discard** (the button, or ⇧⌘⌫).
  - Text sent from the menu bar composer's ↗ button is appended to an existing draft instead of replacing it.
  - It fades in over 0.12 s and out over 0.10 s.
- **Note:** Quick Capture is **plain text**. The title becomes a bold first line, and formatting happens later in the editor.

### 5.7 Settings (⌘,)

A 520 pt wide tabbed window:

| Tab | Contents |
|---|---|
| **General** | *Show Inkwell in:* "Dock and menu bar" or "Menu bar only" · *Show menu bar icon* (locked on in menu-bar-only mode so the app can't become unreachable) · *Launch at login* (requires the .app bundle, and handles "requires approval") |
| **Shortcuts** | Three global-hotkey rows, each with a gradient icon tile, title, description and a **Record Shortcut** field. "Clear All" appears once any are set. Footer: "Shortcuts work from any app. No special permissions needed." |
| **Editor** | *Default font size* slider, 11–24 pt (default 15) with a live preview line · *Default notebook for new notes* (used by Quick Capture and the menu bar) |
| **Sync** | Connect storage, or manage the connection (see below) |
| **About** | 96 pt app icon, "Inkwell" in SF Rounded Bold 26, version, "Notes that keep up with your thinking.", and a caption line "Open source · AGPL-3.0-or-later" |

**Settings › Sync** has two states.

*Disconnected (setup):*

- **Storage:** a 3-column grid of **provider cards** (the short last row is centred), each with a gradient icon tile, a name and a one-line hint:

  | Card | SF Symbol | Tile color | Hint |
  |---|---|---|---|
  | Folder | `folder.fill` | `#0A84FF` | Any folder — NAS, iCloud Drive, Dropbox, USB |
  | Amazon S3 | `shippingbox.fill` | `#FF9F0A` | Your own AWS bucket |
  | Cloudflare R2 | `cloud.fill` | `#5E5CE6` | No egress fees |
  | Backblaze B2 | `flame.fill` | `#FF453A` | Low-cost cloud storage |
  | Google Cloud | `globe` | `#34C759` | Cloud Storage with HMAC keys |
  | MinIO / NAS | `externaldrive.fill.badge.wifi` | `#30B0C7` | Self-hosted S3 on your network |
  | Custom S3 | `server.rack` | `#8E8E93` | Wasabi, Synology C2 and more |

  Before a card is picked, the footer reads "Your notes sync through storage you own. Inkwell doesn't run a server and never sees your data."
- **Folder form:** a *Choose Folder…* button and the chosen path. Inkwell keeps its files in an `inkwell` subfolder.
- **S3 form:** Endpoint (prefilled per provider), Region, Bucket, *Folder inside bucket* (optional), *Path-style addressing*, Access key ID, Secret access key. Each provider has its own help text. Amazon S3, R2, B2 and Google Cloud require `https://`; MinIO / NAS and Custom S3 also accept `http://` for servers on the local network.
- **Encryption:** an *End-to-end encryption* toggle, **on by default**, with Passphrase (at least 8 characters), Confirm passphrase, a 4-segment strength meter (Too short / Weak / Fair / Good / Strong) and an orange warning that a lost passphrase means the synced notes can't be decrypted. Turning encryption off shows "anyone with access to the storage can read your notes". If the location already holds an encrypted library, the section switches to a single "Enter the passphrase used on your other Mac" field.
- **Action bar:** **Test Connection** reports what it found (an empty location, an unencrypted or encrypted Inkwell library, or one from a newer version). **Connect & Sync** is the default button.

*Connected:*

- **Status:** provider icon, provider name and destination, the live status line ("Synced 2 minutes ago"), a "N items will be retried on the next sync" note when some records failed, and a **Sync Now** button. When the passphrase is missing or wrong, an inline Passphrase field with **Unlock** appears here.
- **This Mac:** an editable *Name* (shown to your other Macs), *Encryption* ("End-to-end encrypted" with a green lock, or "Not encrypted"), and *Conflicts* ("None", or an orange "N conflict copies" with a **Show** button that opens the Conflicts filter).
- **Credentials** (S3 only): the saved access key ID and **Update Credentials…**, which opens Access key ID / Secret fields with **Test** and **Save**. If the storage rejects the saved key, this form opens on its own with an orange explanation.
- **Devices:** every Mac that has synced, with "This Mac" tagged and "Seen 5 minutes ago" for the others.
- **Disconnect…:** a confirmation explains that notes stay on this Mac and in the storage, and that the saved credentials are removed from the keychain.

### 5.8 Global hotkeys are **unbound by default**

None are preassigned, so we never steal someone's existing shortcut. The user records them in Settings › Shortcuts.

| Action | Tile color | What it does |
|---|---|---|
| **Show / Hide Inkwell** | `#5E5CE6` indigo | Brings the main window forward, or hides Inkwell if it's already frontmost |
| **New Note** | `#FF9F0A` orange | Opens Inkwell with a fresh note, ready to type |
| **Quick Capture** | `#0A84FF` blue | Toggles the floating Quick Capture panel |

**Recorder UX:**

- Click the field, and it shows "Type Shortcut…" with live modifier keycaps.
- A combo must include ⌘, ⌃ or ⌥, or be an F-key.
- Esc cancels and ⌫ clears.
- It rejects duplicates with a **shake and a beep**.
- It warns, without blocking, when a combo collides with a macOS shortcut or with common ⌘ / ⇧⌘ app shortcuts.
- It shows a red message if another app already owns the combo.
- It uses Carbon hotkeys, so **no Accessibility permission prompt** is needed.

### 5.9 First launch (seed content)

- Three notebooks: **Inbox** (`tray`, blue `#0A84FF`), **Shortcuts** (`command`, purple `#BF5AF2`) and **Ideas** (`lightbulb`, orange `#FF9F0A`).
- A pinned **"Welcome to Inkwell"** note explains navigation, markdown shortcuts and formatting.
- **"Custom keyboard shortcuts"** contains the Ghostty table from Persona 1, tagged `#shortcuts #ghostty`.
- There is no onboarding flow beyond this content (see §9).

### 5.10 Sync & storage

**The pitch:** your notes sync between your Macs through storage **you** own. There's no Inkwell account and no Inkwell server.

- **Where your notes can live:**
  - **Any folder:** a NAS share, iCloud Drive, Dropbox, or a USB drive.
  - **Any S3-compatible bucket:** Amazon S3, Cloudflare R2, Backblaze B2, Google Cloud Storage, MinIO on your NAS, or a custom S3 service (Wasabi, Synology C2 and others).
- **Setup** takes about a minute in Settings › Sync: pick a provider card, fill in the folder or bucket, set a passphrase, and click **Connect & Sync**. On your second Mac, point it at the same place and enter the same passphrase. Sample notes from that Mac's first launch that were never edited are removed before it joins, so the library doesn't get a second Welcome note.
- **End-to-end encryption is on by default.** Notes are encrypted on the Mac before they're uploaded. The storage only sees encrypted files named by random IDs, plus one small unencrypted file that describes the format. The passphrase stays in the Mac's keychain and is never uploaded. **If it's lost, the data can't be recovered**, and the setup screen says so.
- **Conflicts never lose data.** If a note changes on two Macs before they sync, both versions are kept:
  - the remote version arrives as a **conflict copy** titled "Title (conflict — *Mac name*, *date*)";
  - the copy carries an **orange badge** in the note list and the editor header;
  - all copies are gathered under the **Conflicts** filter in the sidebar;
  - **Mark Resolved** (or simply editing the copy) clears the badge. Deleting either version also works.
  - Notebooks don't get copies: the most recent change to a notebook's name, color or icon wins.
- **The status pill** sits in the sidebar footer, and the same status shows as a row in the menu bar panel. Clicking the pill opens Settings › Sync.

  | State | Symbol | Label | Tint |
  |---|---|---|---|
  | Synced | `checkmark.icloud` | Synced | secondary |
  | Syncing | `arrow.triangle.2.circlepath` (rotating) | Syncing | accent |
  | Offline | `icloud.slash` | Offline | secondary |
  | Error | `exclamationmark.icloud` | Sync Issue | orange |
  | Needs passphrase | `lock.icloud` | Locked | orange |

  Quick background passes don't flash "Syncing"; the pill only switches if a pass takes longer than 0.7 s.
- **Lightweight:** when sync isn't configured, it uses nothing at all: no timers, no observers, no network. Once configured, it checks **once a minute while you're using Inkwell** and **every 10 minutes in the background**, on a low-priority thread that never blocks typing. Local edits are pushed about 2 s after you stop typing (at most 10 s later), and a check also runs after waking from sleep. Each check is a single listing of the storage, and only records that changed are downloaded.

**Design opportunities and briefs:**

- **Status pill motion:** today the syncing glyph simply spins (SF Symbols' rotate effect on macOS 15, a 1.2 s linear rotation on 14), and labels cross-fade in 0.15 s. We'd like a calmer syncing rotation and a deliberate transition into *Offline* and *Sync Issue* that informs without alarming.
- **Provider card icons:** the six cards use SF Symbols on colored gradient tiles as placeholders. Explore a consistent icon family; we can't use third-party logos without checking each brand's guidelines.
- **"Connect your second Mac" onboarding:** right now the second Mac just goes through the same form. A short moment (or a sheet after the first connect) that explains "same place, same passphrase" would help.
- **Conflict badge:** an orange triangle in the list and an orange capsule in the editor header. It needs to be noticeable without feeling like an error.
- **Logo and motion brief:** if it fits, a subtle "sync" motif (two marks, a loop, ink flowing between pages) could inform the mark or the syncing animation. It's optional; don't force it.

### 5.11 Screenshots

Current UI captures exist in the project's working files. Proposed repo locations, for designers to drop exports into later:

| File (to be added) | Shows |
|---|---|
| `docs/images/main-light.png` | Three-column window, light mode, the shortcut cheat-sheet note |
| `docs/images/main-dark.png` | Editor in dark mode with lists, checklists, quote, code, divider, link, highlight, table |
| `docs/images/menubar.png` | Menu bar panel |
| `docs/images/quick-capture.png` | Quick Capture panel |
| `docs/images/settings-shortcuts.png` | Settings › Shortcuts |

---

## 6. Current visual language

> These are **engineering defaults**, not a brand system. They're consistent and native-feeling, and they're yours to evolve. File references are for engineers implementing your specs.

### 6.1 Typography

Everything uses the **system font (SF Pro)**; code uses **SF Mono**. Editor sizes scale from the user's *Default font size* (body **B**, default 15 pt). Source: `Sources/Inkwell/Editor/EditorStyles.swift`.

| Style | Formula | @ default 15 pt | Weight | Spacing |
|---|---|---|---|---|
| Title | B + 12 | 27 pt | Bold | 10 after |
| Heading | B + 5 | 20 pt | Semibold | 10 before / 6 after |
| Subheading | B + 1.5 | 16.5 pt | Semibold | 6 before / 4 after |
| Body | B | 15 pt | Regular | line height × 1.15, 6 after |
| Code block | B − 1 | 14 pt mono | Regular | × 1.1, 14 pt inset, tinted rounded background |
| Inline code | B − 1 | 14 pt mono | Medium | light gray background |
| Table header | B − 1 | 14 pt | Semibold | 8 pt cell padding |
| Quote | B | 15 pt | Regular | 18 pt indent + vertical bar |

**UI chrome:**

- Note card: 13 / 12 / 11 pt.
- Menu bar rows: 13 / 11 pt; section headers are 10 pt semibold uppercase with +0.6 tracking.
- Quick Capture title: 22 pt semibold.
- About wordmark: **SF Rounded Bold 26**. This is the only place a "brand" type treatment exists today.

### 6.2 Color

| Usage | Value | Notes |
|---|---|---|
| App accent | **System accent** (user's choice) | No brand accent defined yet |
| Notebook palette | `#0A84FF` `#5E5CE6` `#BF5AF2` `#FF375F` `#FF453A` `#FF9F0A` `#FFD60A` `#30D158` `#64D2FF` `#8E8E93` | Apple system hues. Used for sidebar icons, list dots, header chip (14% tint), empty states, menu bar glyphs (16% tint) — `Model/Models.swift` |
| Pinned | System orange | Pin icons, Pinned row |
| Sync conflicts / sync problems | System orange | Conflict badge and triangle, Conflicts row, pill in *Sync Issue* and *Locked* states |
| Sync provider tiles | `#0A84FF` `#FF9F0A` `#5E5CE6` `#FF453A` `#34C759` `#30B0C7` `#8E8E93` | Folder, Amazon S3, R2, B2, Google Cloud, MinIO / NAS, Custom S3 — `Settings/SyncSettingsView.swift` |
| Recent | System teal | Sidebar icon |
| Text colors | Red, Orange, Yellow, Green, Teal, Blue, Purple, Pink, Gray + custom | `EditorStyle.textColors` |
| Highlights | Yellow, Green, Blue, Pink, Purple, Orange (pastels) | `EditorStyle.highlightColors` |
| Placeholder icon / Quick Capture tile | `#6E5BFF → #3A3FD9 → #1E2470` indigo-violet gradient, `#FFC93C` pencil | `scripts/make_icon.swift`, `MenuBar/QuickCapturePanel.swift` |
| Hotkey tiles | `#5E5CE6` / `#FF9F0A` / `#0A84FF` | `Settings/ShortcutsSettingsView.swift` |

**Dark mode** is fully supported. Text colors are stored as light-mode values and adapted automatically. Code blocks, quote bars, dividers and table borders use dynamic white/black alphas.

### 6.3 Iconography

- **SF Symbols everywhere**, in hierarchical rendering for empty states. Examples: `note.text`, `pin.fill`, `clock`, `number` (tags), `square.and.pencil` (new note), `bolt.fill` (Quick Capture), `macwindow`, `pencil.line` (menu bar).
- **Notebook glyphs** come in two forms: the symbol in the notebook color, or a rounded-square tile (radius 28% of size) at 16% tint.
- **Keycaps:** rounded chips (e.g. `⌃ ⌘ E`) in the hotkey recorder and the `esc` hint.

### 6.4 Materials, shape, spacing, motion

- **Materials:** standard sidebar vibrancy; Quick Capture uses `.popover` visual-effect material and stays vibrant while inactive.
- **Corners:** all continuous ("squircle") style.

  | Element | Radius |
  |---|---|
  | Toolbar buttons | 6 |
  | Hotkey tiles | 7 |
  | Composer card | 10 |
  | Notebook preview | 12 |
  | Quick Capture | 16 |
  | Note-header chip | capsule |

- **Hairlines:** 0.5 pt at 8–12% primary.
- **Spacing:** roughly a 4/6/8/10/12/14/16 pt rhythm. Editor insets are at least 28 pt horizontal and 22 pt vertical. The reading column maxes out at 760 pt.
- **Motion today (minimal; see the brief):**

  | Moment | Current motion |
  |---|---|
  | Quick Capture | Fade in 0.12 s / out 0.10 s |
  | "Saved to…" toast | Fade + slide from trailing, 0.2 s ease-out |
  | Hotkey recorder | 0.15 s fades; 0.3 s shake on reject |
  | Menu bar selection | 0.12 s scroll-to-highlight |
  | Sync pill | Glyph rotates while syncing (SF Symbols rotate effect on macOS 15, 1.2 s linear loop on 14); label changes ease out over 0.15 s |
  | Sync provider cards | 0.15 s ease-out selection |
  | Everything else | System default (or no animation) |

---

## 7. Design brief & deliverables

### 7.1 What we need, in priority order

1. **Logotype and wordmark**
   - Works for the chosen name: Inkwell, or NoteIt as a fallback.
   - Needs to work in the About pane, the website, App Store art and the menu bar panel header.
2. **App icon**
   - macOS Big Sur+ style: rounded-square (squircle) body on Apple's 1024 grid (824 pt body, about 185 pt corner radius), with a subtle shadow.
   - Should read clearly at 16 px.
   - **Dark and tinted variants** (macOS 15+ appearance modes) and a "clear/mono" consideration.
   - Must replace `scripts/make_icon.swift`. That placeholder is an indigo squircle with a tilted paper sheet and a yellow pencil.
3. **Menu bar template glyph**
   - Monochrome **template image** (black with alpha; macOS tints it), about 16–18 pt tall, @1x and @2x, with optical alignment to Apple's own menu bar icons.
   - Replaces the SF Symbol `pencil.line`.
   - Optional: an "active/capturing" state.
4. **Motion language**
   - A small, consistent set of curves and durations ("calm but quick").
   - Specific moments:

     | Moment | Today | Ask |
     |---|---|---|
     | Quick Capture appear/dismiss | Fade 0.12 s | Signature entrance (scale + fade? drop-in?), save "whoosh into notebook" |
     | Note creation | Instant | Card arrival in the list, caret ready |
     | Checkbox toggle | Instant redraw | Fill + check-draw, strikethrough sweep |
     | Pin / unpin | Instant reorder | Pin "stick" + card moving to top |
     | Notebook drag & drop | System | Drop-target highlight, count tick |
     | Saved toast | Fade/slide | Keep or refine |
     | Empty states | Static | Gentle idle or entrance for the symbol |
     | Launch / first open | None | Optional welcome moment |
     | Hotkey reject | Shake | Keep or refine |
     | Sync pill: syncing | Plain rotation | Calm, branded "syncing" loop |
     | Sync pill: offline / error | Instant swap + 0.15 s label fade | A transition that informs without alarming |
     | Conflict copy arrives | Instant | A gentle way to draw the eye to the badge |
5. **Micro-interactions**
   - Toolbar hover/active states, the table-size picker, swatch popovers and keycaps.
   - Tag chips: `#hashtags` are currently **unstyled plain text** in the editor.
6. **Onboarding / first run**
   - Today it's only seed notes.
   - Proposal: a 3-step welcome covering hotkey setup, the menu bar, and markdown tips. Settings › Shortcuts is the "aha" screen.
   - A separate "connect your second Mac" moment for sync (see §5.10).
7. **Marketing site and App Store screenshots**
   - Hero, feature pages and a pricing placeholder.
   - App Store set at 2880 × 1800 and 1280 × 800.
8. **Sound (optional)**
   - Subtle capture/save and checkbox sounds. All must be off-able, with system sounds as the fallback.
   - Today the only sound is `NSSound.beep()` on invalid actions.

### 7.2 Deliverables

| Deliverable | Format | Sizes / specs | Notes |
|---|---|---|---|
| App icon master | Figma/Sketch + layered `.icon` (Icon Composer) or PSD/AI | 1024 × 1024 on Apple grid | Light, dark, tinted variants |
| App icon export | PNG iconset → `.icns` | 16, 32, 64, 128, 256, 512, 1024 px (1× & 2×) | We assemble the `.icns` via `iconutil` |
| Menu bar glyph | PDF (vector, template) + PNG | 18 × 18 pt @1x/@2x, single color + alpha | Must be a template image |
| Wordmark / logotype | SVG + PDF | Horizontal, stacked, mark-only | Light/dark, min-size rules |
| Brand colors | Tokens (hex + sRGB/P3), light & dark | Accent, neutrals, notebook palette review | Map to `Model/Models.swift`, `EditorStyles.swift` |
| Type spec | Table | Editor scale + chrome | System fonts preferred; a custom display face is OK for marketing only |
| Motion specs | Lottie/After Effects + spec sheet (duration, curve, delay) | Per moment in §7.1 | SwiftUI spring/easing equivalents appreciated |
| Empty-state art | SF Symbol choices or custom SVG | 88 pt circle composition | Should also work in dark mode |
| Sync provider icons | SVG/PDF or SF Symbol choices | 26 pt card tile, 36 pt status tile | Six providers (§5.7); check brand guidelines before using any logo |
| Sync status set | SF Symbol choices or custom symbols + motion spec | 11 pt in the pill | Synced, syncing, offline, error, needs passphrase |
| Onboarding screens | Figma frames | 520–640 pt wide sheet | 3 steps max |
| App Store screenshots | PNG | 2880 × 1800 (and 1280 × 800) | 5–8 frames |
| Website | Figma | Desktop + mobile | Landing + feature + pricing |
| Sounds (optional) | WAV/AIFF | < 300 ms, -20 LUFS-ish | Capture, save, check |

### 7.3 Constraints

- It must feel **at home on macOS**: respect system accent, light and dark mode, and Reduce Motion / Reduce Transparency.
- Notebook colors are user-chosen. The brand must not fight a sidebar full of rainbow notebooks.
- Note content is the hero, so chrome stays neutral.

---

## 8. Naming: Inkwell vs NoteIt

The working name is **Inkwell**, with **NoteIt** as backup. Before investing in the logotype, run a **trademark search** (USPTO / EUIPO / WIPO), plus checks on **App Store name availability**, **domains** (`.app`, `.com`) and **social handles**. Both names are generic-sounding and likely to have existing uses.

| | **Inkwell** | **NoteIt** |
|---|---|---|
| Tone | Crafted, literary, calm, a bit premium. Evokes writing by hand and "a well of ideas" | Casual, direct, action-oriented ("note it!"). Friendly and utilitarian |
| Fits the pitch | "Done better", quality, delight | "Swift capture", speed |
| Risks | Common word, so existing apps and brands are likely (and there's an Instagram filter called "Inkwell"). Slightly old-fashioned. Ink suggests handwriting/pen apps | Very generic, "Note" plus a verb collides with many apps. Casing ambiguity (NoteIt / Noteit / Note It). Hard to own in search |
| Logotype ideas | Serif or soft humanist wordmark; ink-drop counter in the "I" or "w" | Bold geometric sans; "It" as a highlighted pill/checkmark |
| App icon ideas | Ink drop, a well/pot seen from above, nib + page. Strong silhouette at 16 px | Note card with a lightning bolt or check; speech-bubble-like note |
| Menu bar glyph | Ink drop or nib: a simple, distinctive single-color shape | Small note with a corner fold or bolt. Risks looking like system "Notes" |
| Sayability / spelling | Easy and unambiguous | Easy to say; spelling and casing vary |
| Code impact | Current name (bundle id `com.inkwell.app`, data folder `Inkwell`, keychain service `com.inkwell.app.sync`) | Rename needed: bundle id, Application Support folder (with migration), keychain service (or users re-enter sync secrets), UI strings |

**Recommendation for design exploration:** explore **Inkwell first**, because its tone is more distinctive and fits "calm and crafted". Keep NoteIt as a quick parallel sketch for the icon and menu bar glyph only, so we can decide quickly if the trademark check fails.

---

## 9. Known gaps & opportunities

### 9.1 Known gaps (verified in the current code)

| Area | Gap |
|---|---|
| Brand | **Placeholder app icon** (code-drawn) and SF Symbol menu bar icon; no brand accent color |
| Sync: folders | Folders kept in sync by another tool (iCloud Drive, Dropbox) rely on **advisory file locking** (`flock`), which only helps when Macs write to the same volume that supports it, such as a NAS share. A sync tool copies files between Macs after the fact, so two Macs can still race. The tool's own conflict files (e.g. `<id> 2.meta`) are detected and imported as conflict copies, and unusable ones are cleaned up after 30 days |
| Sync: S3 | Providers without conditional writes (`If-Match` / `If-None-Match`) get **best-effort** protection: Inkwell checks before and after each write, which narrows but doesn't close the race between two Macs. This includes providers that silently ignore the headers, such as Google Cloud Storage's S3-compatible API; Inkwell detects these with a one-time probe |
| Sync: providers | **No WebDAV** backend yet |
| Sync: conflicts | **No side-by-side compare** view; the user compares the two notes manually |
| Sync: passphrase | Encryption is chosen at connect time; there's no "change passphrase" or "turn encryption on later" without starting a new library |
| Mobile | **No iOS app** (iPhone/iPad); sync is Mac-to-Mac only |
| Export / share | **No export** (Markdown, PDF, HTML), no print, no Share menu |
| Deletion | No Trash or "Recently Deleted" UI and no undo. Deleted bodies are kept in a hidden `.trash/` folder on disk, but recovering one means digging in Finder, and its title/notebook metadata is gone. The dialog copy ("permanently deleted") doesn't match this |
| Onboarding | No first-run flow; only seed notes. Global hotkeys are unbound by default and are only discoverable via Settings |
| Tags | `#hashtags` aren't visually styled in the editor; no tag rename/merge; tags can't be added except by typing them |
| Quick Capture | Plain text only (no formatting or images in the panel); a single draft only, with no indication outside the panel that one is waiting |
| Organization | Single-level notebooks (no nesting); one notebook per note; no manual note sorting or sort options |
| Search | All-words substring match (case- and accent-insensitive); no ranking, and no highlighting of matches in results or in the note |
| Note metadata | No word count, created-date display or note info panel |
| Windows | Single main window; no opening notes in separate windows |
| Accessibility | Not yet audited (VoiceOver labels exist on some controls only) |
| Testing | Unit tests cover the `InkwellSync` library only; the app layer is checked with built-in self-test modes (see §11) |
| Distribution | Ad-hoc signed; not notarized, no auto-update, no licensing/pricing |

### 9.2 Opportunities and future ideas (not built)

- **Capture++:** a "Capture selection" service, clipboard capture, a share extension, a Shortcuts/AppleScript action, and voice notes.
- **Sync:** a WebDAV backend, a side-by-side conflict compare view, passphrase change, and an optional iCloud (CloudKit) backend for people who don't want to bring their own storage.
- **Mobile companion:** iOS capture first, editing later. The `InkwellSync` engine has no AppKit dependency, so an iOS app could reuse it.
- **Export / import:** Markdown with images, PDF and HTML; import from Apple Notes, Bear and Obsidian.
- **Organization:** nested notebooks, a smart Today/Untagged view, saved searches, note links (`[[wiki links]]`), and backlinks.
- **Editor:** slash command menu, tag chips and autocomplete, table column add/delete and sorting, collapsible headings, callouts, syntax highlighting in code blocks.
- **Recall:** a Spotlight (CoreSpotlight) index, and a "cheat-sheet mode" that floats one note as an always-on-top HUD for Persona 1.
- **Trust:** a **Trash / "Recently Deleted" view to recover deleted notes**. Bodies already land in `.trash/`, so this mostly needs UI plus keeping metadata. Also auto-emptying after 30 days, undo for delete, version history (RTFD snapshots), and encrypted notes.
- **Polish:** theming (paper, sepia), focus/typewriter mode, and distinctive custom sounds.

---

## 10. Keyboard shortcut reference

Every entry was verified against the source: `App/InkwellApp.swift`, `Editor/FormatCommand.swift`, `MenuBar/*`, and `Hotkeys/*`.

### App & navigation

| Shortcut | Action |
|---|---|
| ⌘N | New note (in the selected notebook, and focuses the editor) |
| ⇧⌘N | New notebook… |
| ⌘F | Search all notes |
| ⌥⌘F | Find in note |
| ⌘G / ⇧⌘G | Find next / previous |
| ⌘E | Use selection for find |
| ⌘0 | Show main window ("Inkwell Notes" in the Window menu) |
| ⌘, | Settings |
| ⌫ (in note list) | Delete note (with confirmation) |

### Text formatting

| Shortcut | Action |
|---|---|
| ⌘B / ⌘I / ⌘U | Bold / Italic / Underline |
| ⇧⌘X | Strikethrough |
| ⇧⌘E | Inline code |
| ⇧⌘H | Highlight (toggle) |
| ⌘K | Link… |
| ⌘+ / ⌘− | Bigger / Smaller |
| ⌥⌘\\ | Clear formatting |

### Paragraphs & blocks

| Shortcut | Action |
|---|---|
| ⌥⌘1 / ⌥⌘2 / ⌥⌘3 | Title / Heading / Subheading |
| ⌥⌘0 | Body |
| ⌥⌘4 | Monospaced (code block) |
| ⌥⌘5 | Quote |
| ⇧⌘8 | Bulleted list |
| ⇧⌘7 | Numbered list |
| ⇧⌘L | Checklist |
| ⇧⌘U | Mark as checked (toggle) |
| ⌘] / ⌘[ | Indent / Outdent |
| Tab / ⇧Tab | Indent / outdent list item · next / previous table cell |
| ⇧⌘{ / ⇧⌘\| / ⇧⌘} | Align left / center / right |
| ⌥⇧⌘D | Divider |

### Menu bar panel

| Shortcut | Action |
|---|---|
| ↑ / ↓, ↩ | Move through notes, open highlighted |
| Esc | Clear search, then close panel |
| ⌘↩ | Save quick note |
| ⌘O | Open Inkwell |
| ⌘N | New note |
| ⌘, / ⌘Q | Settings / Quit |

### Quick Capture panel

| Shortcut | Action |
|---|---|
| ↩ (in title) | Jump to body |
| ⌘↩ | Save note |
| ⇧⌘⌫ | Discard draft and close |
| Esc | Dismiss (draft is kept) |

### Global hotkeys

**Unbound by default.** Assign them in Settings › Shortcuts: *Show / Hide Inkwell*, *New Note*, *Quick Capture*.

---

## 11. For engineers

### Requirements

- macOS **14 Sonoma** or later.
- Swift 6 toolchain. The manifest is `swift-tools-version:5.10`. Command Line Tools are enough to build and run; `xcodebuild` isn't used. **Running the unit tests needs Xcode**, because the Command Line Tools alone don't ship XCTest (see [Testing](#testing)).
- No third-party dependencies. The app uses SwiftUI and AppKit, plus Carbon for hotkeys and ServiceManagement for login items. Sync uses CryptoKit, CommonCrypto, Security (keychain) and URLSession.

### Build & run

```sh
swift build                 # debug build
swift run Inkwell           # run unbundled (launch-at-login disabled, icon falls back to a drawn stand-in)
./scripts/build_app.sh      # release: build/Inkwell.app → ~/Applications/Inkwell.app
```

`build_app.sh` does the following:

- builds in release mode
- writes `Info.plist` (bundle id `com.inkwell.app`, `LSMinimumSystemVersion` 14.0, category Productivity, and App Transport Security `NSAllowsLocalNetworking` so plain-`http://` MinIO/NAS servers on the local network work; see [Sync](#sync))
- renders the icon via `scripts/make_icon.swift` → `iconutil`
- ad-hoc codesigns the app, then installs it atomically (staged copy, verified, swapped in; the previous version is restored on failure)

Optional environment variables:

| Variable | Default | Effect |
|---|---|---|
| `INKWELL_INSTALL_DIR` | `$HOME/Applications` | Install destination |
| `INKWELL_VERSION` | `1.0` | `CFBundleShortVersionString` |
| `INKWELL_BUILD` | timestamp (`YYYYMMDDHHMM`) | `CFBundleVersion` |

### Data

```text
~/Library/Application Support/Inkwell/
├── .initialized                        # marker: first launch (seeding) has happened
├── library.json                        # notebooks + note metadata (pretty-printed, ISO-8601 dates)
├── library.corrupt-<ts>.json           # backup of an unreadable library.json (if it ever happens)
├── search-index.json                   # folded plain text per note (case/diacritic/width-insensitive)
├── seed-manifest.json                  # IDs/revisions of the seed content until sync consumes it
├── sync-state-<hash>.json              # per remote store: last-synced base per record (only while sync is configured)
├── sync-deletions.json                 # journal of local deletions not yet pushed (only while sync is configured)
├── notes/<uuid>.rtfd                   # each note body as RTFD (rich text + image attachments)
├── notes/<uuid>.rtfd.corrupt-<ts>      # backup of an unreadable note body
└── .trash/<uuid>-<ts>.rtfd             # bodies of deleted notes (never deleted outright)
```

- Override the location with `INKWELL_DATA_DIR=/some/dir` (`~` is expanded). This is handy for testing against a scratch library.
- **Editor → store:** the editor commits edits to `NoteStore` after 300 ms of idle (`RichTextEditor.Coordinator.commitDelay`). It also commits synchronously on note switch, teardown, window/app deactivation and quit.
- **Store → disk:** saves are debounced (about 0.5 s) and atomic (RTFD is written to a temp sibling and swapped in). The app also flushes on quit and when it loses focus. Failed writes retry after 5 s.
- **Seeding** happens only on a true first launch: no `library.json`, no note bodies and no `.initialized` marker. The seeded IDs and revisions go to `seed-manifest.json`. When sync joins a library that already exists, unedited seed notes and then unedited, empty seed notebooks are removed locally (not journaled, so nothing is deleted remotely) before the first pass. The manifest is deleted after any connect.
- **Recovery:**
  - If `library.json` is missing but bodies exist, the library is rebuilt from `notes/*.rtfd`.
  - If `library.json` is unreadable, it is copied to `library.corrupt-<ts>.json`, whatever metadata can be salvaged is kept, and the rest is rebuilt from the bodies. If that backup fails, the original is never overwritten.
  - An unreadable note body is copied to `<id>.rtfd.corrupt-<ts>`, and the note opens empty with an error message. If the backup fails, writes to that note are blocked.
- **Deleting a note** persists the metadata removal first, then moves the body to `.trash/`. There's no in-app recovery yet (see §9).
- To reset to first-launch state, quit and delete the whole folder, including the hidden `.initialized` marker and `.trash/`.
- Preferences live in `UserDefaults`: `hideDockIcon`, `showMenuBarIcon`, `editorFontSize`, `defaultNotebookID`, plus the hotkey bindings. Sync adds `syncConfiguration` (non-secret settings as JSON), `syncDeviceID` (stable per Mac, kept across reconnects) and `syncLastSync`. Sync secrets live only in the keychain (see [Sync](#sync)).

### Architecture map (`Sources/Inkwell/`)

| Folder | Responsibility |
|---|---|
| `App/` | `InkwellApp` (WindowGroup, Settings, MenuBarExtra, menu commands), `AppDelegate` (activation policy, hotkey wiring, debug args), `WindowRouter` (show/hide/focus) |
| `Model/` | `Models` (Notebook, NoteMeta, SidebarSelection, palette), `NoteStore` (singleton ObservableObject: queries, CRUD, tags, persistence), `SeedData` |
| `Views/` | `MainView` (3-column split), `SidebarView`, `NoteListView`, `EditorContainerView` (header + toolbar + editor, `ConflictBadge`), `EmptyStates`, `NotebookEditSheet`, `SyncStatusView` (pill, menu bar row) |
| `Editor/` | `RichTextEditor` (NSViewRepresentable), `InkwellTextView` (NSTextView subclass + custom layout manager drawing code blocks, quotes, dividers, checkboxes), `TextFormatter`, `MarkdownShortcuts`, `FormatCommand` (commands + shortcuts), `FormattingToolbar`, `EditorStyles` (type scale, colors, block model) |
| `MenuBar/` | `MenuBarView`, `QuickCapturePanel`, `PanelSearchField`, `SharedViews` (vibrancy, notebook glyph, icon view), `NoteStore+Capture` |
| `Hotkeys/` | `HotkeyAction`, `HotkeyManager` (Carbon `RegisterEventHotKey`), `KeyCombo`, `ShortcutRecorder` |
| `Settings/` | `SettingsView` + General / Shortcuts / Editor / Sync / About tabs, `Preferences` (keys, `SettingsOpener`) |
| `Sync/` | `SyncController`, `NoteStoreSyncAdapter`, `SyncConfiguration` (providers, settings), `Keychain` — see [Sync](#sync) |

Block identity is stored as sentinel `defaultTabInterval` values on each paragraph, because RTFD drops custom attributes. This covers special blocks (code, quote, divider) and also **title, heading, subheading and body**, so a heading stays a heading even if the user changes the body font size. Paragraphs without a sentinel (older notes) fall back to font-size inference. See `EditorStyles.swift` (`BlockKind`, `*Sentinel` constants).

### Sync

Design and decisions: [`docs/specs/2026-10-12-sync-design.md`](../specs/2026-10-12-sync-design.md), including the implementation notes and deviations at the end.

**`InkwellSync` library target** (`Sources/InkwellSync/`). Foundation, CryptoKit, CommonCrypto and Security only, with no AppKit or app types, so it's unit-testable on its own.

| Folder | Contents |
|---|---|
| `Storage/` | `StorageBackend` protocol: `list`, `get`, `put(ifMatch:ifNoneMatch:)`, conditional `delete(ifMatch:)`, `probe`. Backends: **`FolderBackend`** (atomic temp-file + rename, `renamex_np(RENAME_EXCL)` for create-if-absent, content-hash etags for files ≤ 256 KB, stat etags for larger bodies, and an in-process lock plus a cross-process `flock` on `<root>/.inkwell-lock` around every write and delete); **`S3Backend`** (path-style or virtual-host URLs, optional key prefix, `If-Match` / `If-None-Match`, falling back to HEAD-check, PUT, HEAD-verify when a provider answers 501/`NotImplemented` or a one-time canary shows it silently ignores the headers); **`InMemoryBackend`** (tests). `SigV4Signer` implements AWS Signature V4 with CryptoKit and is checked against AWS's published examples. `S3ListParser` parses `ListObjectsV2`. |
| `Crypto/` | `KeyDerivation`: PBKDF2-HMAC-SHA256, **210,000 iterations**, 16-byte random salt, 32-byte key. `AESGCMCipher`: AES-GCM, `nonce ‖ ciphertext ‖ tag`, with the object key relative to `inkwell/v1/` (e.g. `notes/<id>.meta`) as **AAD**, so a sealed object can't be replayed under another key. `PassthroughCipher` for unencrypted stores. |
| `Engine/` | **`SyncPlanner`**: the pure decision table (local record / local deletion / remote meta / remote tombstone / base → `push`, `pull`, `conflict`, `pushDeletion`, `applyRemoteDeletion`, `resurrectPush`, `forgetBase`, `none`). **`SyncEngine`** (actor): runs passes one at a time, each resuming from the persisted `SyncState`; connects/creates the store and verifies the passphrase; imports sync-tool sidecar copies; sweeps tombstones after 30 days; writes its device record at most every 10 minutes. `RemoteLayout`: object keys. |
| `Model/` | `Manifest` (format version, optional encryption parameters), `SyncState` (per-record bases, pending pushes, tombstone dates, sidecar first-seen dates), record/envelope/tombstone/device types. |

**App layer** (`Sources/Inkwell/`):

- **`NoteStore`** gives every note and notebook a `revision` UUID that changes on each user edit. Records created before sync get a deterministic revision derived from their content, so identical libraries on two Macs don't conflict. While sync is configured, local deletions are journaled to `sync-deletions.json`. Conflict copies carry `conflictSource` (device name) and `conflictOriginalID`.
- **`NoteStoreSyncAdapter`** implements the engine's `SyncLocalStore`. RTFD parsing and body writes happen off the main actor, and main-actor hops only swap prepared files in. Before a remote change replaces or deletes a note, it commits staged and open-editor edits; if the revision moved since the engine read it, the apply is refused and the next pass sees a conflict.
- **`SyncController`** owns scheduling and status. Nothing (no timers, tasks or observers) exists until sync is configured. Then one loop runs passes in `Task.detached(priority: .utility)`: every 60 s while Inkwell is active or has a visible window, every 600 s otherwise; 2 s after a local edit (at most 10 s); 5 s after wake; on activation if the last pass is more than 15 s old; and on **Sync Now**. Failures back off from 15 s, doubling up to 10 minutes. Wrong/missing passphrase, rejected credentials, an unsupported format and a missing manifest pause sync until the user acts.
- **Keychain:** generic passwords under service **`com.inkwell.app.sync`**, accounts `s3-access-key`, `s3-secret` and `passphrase` (`kSecAttrAccessibleAfterFirstUnlock`). Non-secret settings are JSON in `UserDefaults` (`syncConfiguration`); folders are kept as security-scoped bookmarks.
- **ATS:** `build_app.sh` sets `NSAppTransportSecurity` → `NSAllowsLocalNetworking`. In the app, plain `http://` endpoints are accepted **only for the MinIO / NAS and Custom S3 presets**; Amazon S3, R2, B2 and Google Cloud require `https://`. If macOS still blocks an `http://` request (e.g. a non-local host), sync stops with an explanation.

**Remote layout** (under the chosen folder, or the bucket plus the optional *Folder inside bucket*):

```text
inkwell/v1/
├── manifest.json            # format version, created date, encryption salt/iterations/key check — never encrypted
├── notebooks/<id>.json      # notebook envelope (revision, modifiedAt, device, metadata)
├── notes/<id>.meta          # note envelope, including the SHA-256 of the body it expects
├── notes/<id>.body          # flattened RTFD
├── tombstones/<id>.json     # deletion marker (deletedAt, device, the meta etag the deleter saw)
└── devices/<deviceID>.json  # device name and last sync, for Settings › Sync › Devices
```

Everything except `manifest.json` is AES-GCM sealed when encryption is on. A body that's missing or doesn't match its meta's hash is treated as an upload in progress and skipped until a later pass.

**Local files** (in `~/Library/Application Support/Inkwell/`):

| File | Purpose |
|---|---|
| `sync-state-<hash>.json` | Last-synced base per record. One file per remote store; `<hash>` is the first 8 bytes of a SHA-256 over the provider and folder path or endpoint/bucket/prefix, in hex. Removed on connect and disconnect. An older `sync-state.json` is migrated on launch. |
| `sync-deletions.json` | Local deletions not yet pushed. Written only while sync is configured; cleared on connect and disconnect. |
| `seed-manifest.json` | First-launch sample content, so a Mac joining an existing library drops unedited samples. Deleted after any connect. |

### Testing

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

- 149 XCTest cases in `Tests/InkwellSyncTests/`: the planner table, the engine against in-memory and faulty backends, folder backend (including a cross-process lock test), S3 request and response handling with a stubbed URL protocol (including the conditional-request canary), SigV4, list parsing and crypto.
- **Live cloud emulator tests** (`LiveS3EmulatorTests`, skipped by default) run the S3 backend contract, 1,005-key pagination and an encrypted two-Mac sync against a real server. `scripts/live_s3_tests.sh [aws] [gcp]` starts [Floci](https://github.com/floci-io/floci) emulators for Amazon S3 and Google Cloud Storage in Docker, runs the suite against each, and removes the containers. To target another server (e.g. MinIO), set `INKWELL_LIVE_S3_ENDPOINT` and optionally `_REGION`, `_BUCKET`, `_ACCESS_KEY`, `_SECRET` and `_CREATE_BUCKET=1`.
- **Command Line Tools alone don't include XCTest**, so `swift test` fails without Xcode. `DEVELOPER_DIR` points SwiftPM at Xcode's toolchain without changing `xcode-select`.
- The app layer (NoteStore, adapter, seed handling) is covered by the debug-only `INKWELL_SYNC_SELFTEST` mode below.

### Debug & test launch arguments

**Launch arguments are compiled into debug builds only** (`#if DEBUG` in `AppDelegate.swift`). Release builds made by `build_app.sh` ignore them.

| Argument (debug builds only) | Effect |
|---|---|
| `--self-test` | Runs the hotkey self-test and exits with its status |
| `--debug-open-settings [--debug-settings-tab general\|shortcuts\|editor\|sync\|about]` | Opens Settings (optionally a tab) |
| `--debug-preview-bindings` | Shows sample hotkey bindings in the UI without saving them (for screenshots) |
| `--debug-menubar-preview` | Hosts the menu bar panel in a normal window (for screenshots) |
| `--debug-quick-capture` | Opens Quick Capture at launch |
| `--debug-dark` | Forces dark appearance |
| `--debug-show-conflicts` | Selects the Conflicts filter and its first note |
| `--debug-sync-provider <folder\|awsS3\|cloudflareR2\|backblazeB2\|googleCloud\|minio\|customS3>` | Preselects that provider card in Settings › Sync. For `folder` with `INKWELL_DATA_DIR` set, the folder is prefilled as a `remote` sibling of the data dir; for S3 presets, region, path style and endpoint get the preset defaults |
| `--debug-sync-endpoint <url>` | With an S3 `--debug-sync-provider`, prefills the endpoint |

Environment variables (currently read in **all** builds):

| Env var | Effect |
|---|---|
| `INKWELL_DATA_DIR=<path>` | Uses `<path>` instead of `~/Library/Application Support/Inkwell` |
| `INKWELL_EDITOR_SELFTEST=1` | Scripted editor exercise (markdown, lists, toolbar, persistence) logging `SELFTEST …` lines. **It edits real notes, so pair it with `INKWELL_DATA_DIR`** |
| `INKWELL_EDITOR_SELFTEST_DARK=1` | With the above, forces dark appearance |
| `INKWELL_EDITOR_SELFTEST_SHOW=<title prefix>` | With the above, only opens the matching note (for screenshots) |
| `INKWELL_EDITOR_SELFTEST_NARROW=1` | With the above, shrinks the window to 900 pt wide |

Sync environment variables (**debug builds only**, `SyncController.swift` and `AppDelegate.swift`):

| Env var | Effect |
|---|---|
| `INKWELL_SYNC_CONFIG=<json>` | Connects headlessly at launch. The JSON is a `SyncConfiguration` (`provider`, `folderPath` or `s3`, `encrypted`, `deviceName`, …) plus optional `passphrase`, `accessKey` and `secret`. Nothing is written to `UserDefaults` or the keychain. A `folderPath` is created if missing |
| `INKWELL_SYNC_INTERVAL=<seconds>` | Replaces both poll intervals and the 15 s backoff base, and logs a line per non-empty pass |
| `INKWELL_SYNC_SELFTEST=1` | Runs the sync self-test against scratch stores inside `INKWELL_DATA_DIR` (required), prints `SYNCTEST` lines and exits non-zero on failure. `INKWELL_SYNC_SELFTEST_LIBRARY=<path>` also loads a copy of that `library.json` to check that files without revisions still load |
| `INKWELL_DEBUG_EDIT_AFTER=<seconds>` | After the delay, appends "Edited on *device* at *time*" to the selected (or first) note, as if typed. Handy for two-instance tests |
| `INKWELL_DEBUG_UPDATE_CREDENTIALS=<seconds>:<accessKey>:<secret>` | After the delay, runs "Update Credentials…" headlessly |

Example: `swift run Inkwell --debug-open-settings --debug-settings-tab shortcuts`

Headless sync example (scratch library, local folder as the remote):

```sh
INKWELL_DATA_DIR=~/scratch/a INKWELL_SYNC_INTERVAL=5 \
INKWELL_SYNC_CONFIG='{"provider":"folder","folderPath":"~/scratch/remote","encrypted":true,"deviceName":"A","passphrase":"correct horse battery"}' \
swift run Inkwell
```
