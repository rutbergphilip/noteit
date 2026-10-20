# Growth — Design

Status: proposed · Date: 2026-10-19 · Companion plan: docs/plans/2026-10-19-growth.md

## Goal

Help people find NoteIt, trust it, switch to it and contribute to it, without adding a server, an account, tracking or anything that contradicts what the app promises. This sub-project is repo-level and non-code: a small static website, a public roadmap with voting, issue and discussion templates, a launch kit, a demo video, a press kit, contributor onboarding, the official Homebrew cask, and a way to measure all of it without telemetry.

Growth runs alongside the delivery waves in the [program design](2026-10-19-program-design.md). The public launch happens after the first full release that contains all of wave 1 (automation, markdown-storage, linking, organise), which itself comes after the wave 0 foundations. In this spec, "the wave 1 release" always means that release. Everything that has to exist on launch day is ready about two weeks before it.

## What the user gets

- **A website** at `https://rutbergphilip.github.io/noteit/` with a home page, features, a dated comparison table, five "switch from" guides, a privacy promise, a download page and a press kit. Plain HTML and CSS. No JavaScript, no cookies, no analytics, no web fonts, no third-party requests. Every page works with images off and in dark mode.
- **A download button that always points at the current DMG**, with its size, SHA-256 and the macOS requirement next to it, plus the Homebrew command.
- **A public roadmap they can vote on.** Ideas live in GitHub Discussions › Ideas, where anyone with a GitHub account can upvote. `docs/roadmap.md` stays the single written roadmap and links each item to its discussion.
- **Clear ways to report things**: bug, import problem, website or docs fix, and ideas (which go to Discussions instead of issues).
- **An honest launch**: one Show HN, one post each in r/macapps and r/selfhosted, one Product Hunt launch and Mastodon posts, spread over about a week, all written by the maintainer, with the maintainer around to answer.
- **A 60-second demo video** that works muted.
- **A press kit**: icon, screenshots in light and dark, a one-paragraph description, facts, and the brand rules.
- **A friendly way in for contributors**: labelled good first issues, a 20-minute architecture tour, and a short "your first pull request" section.
- **`brew install --cask noteit`** once NoteIt meets Homebrew's notability rules. Until then, the existing tap keeps working. Once automation's command line tool ships, the cask also puts `noteit` on the `PATH`.
- **Honest claims.** The website lists only features that have shipped. Anything planned is marked "planned" and links to `docs/roadmap.md`.

## Design

### 1. Website

#### 1.1 Hosting and build

- Source lives in `site/` at the repo root. GitHub Pages serves it through a new workflow, `.github/workflows/pages.yml`, using `actions/upload-pages-artifact` and `actions/deploy-pages`. Branch-based Pages can only serve `/` or `/docs`, so a workflow is needed for `site/`.
- There is no static site generator. Pages are hand-written HTML files sharing one stylesheet, `site/assets/site.css`. The header and footer are repeated in each file; `scripts/check_site.py` fails the build if they drift (see 1.4).
- The workflow does three small things before uploading:
  1. Copies `site/` to `_site/`.
  2. Replaces `@@VERSION@@`, `@@DMG_URL@@`, `@@DMG_SIZE@@`, `@@DMG_SHA256@@` and `@@RELEASE_DATE@@` in `_site/download/index.html` and `_site/index.html` with values from the latest full release (`gh release view --json tagName,publishedAt,assets`; the asset `digest` field gives the SHA-256). Pre-releases are never used, because `releases/latest` skips them.
  3. Builds `_site/press/noteit-press-kit.zip` from `site/press/` and the icon files (see 7).
- It runs on pushes to `main` that touch `site/**`, `design/press/**` or the workflow itself, on `workflow_dispatch`, and at the end of a full release. A release created with `GITHUB_TOKEN` doesn't trigger `release: published` in other workflows, so `release.yml` gets a final step in its `publish` job: `gh workflow run pages.yml` (needs `actions: write` on that job). Web-clipper also edits `release.yml` (Safari build steps before **Build NoteIt.app**); growth's change is rebased on top of web-clipper's and touches only the end of the `publish` job. The Pages trigger stays in `release.yml` for good, including after the `homebrew` job is removed (see 6).
- If the release lookup fails, the deploy fails and the previous site stays up. A half-stamped page is never published: `check_site.py` rejects any `@@` left in `_site/`.
- Custom domain: none at launch (see Open questions). The cask, README and repo "Website" field all use the github.io URL.

#### 1.2 Pages and URLs

| URL path | File | Purpose |
|---|---|---|
| `/` | `site/index.html` | Home |
| `/features/` | `site/features/index.html` | Everything NoteIt does in the current release, grouped like the README |
| `/compare/` | `site/compare/index.html` | Comparison table |
| `/switch/` | `site/switch/index.html` | Index of switch guides |
| `/switch/apple-notes/` | `site/switch/apple-notes/index.html` | Switch from Apple Notes |
| `/switch/evernote/` | `site/switch/evernote/index.html` | Switch from Evernote |
| `/switch/notion/` | `site/switch/notion/index.html` | Switch from Notion |
| `/switch/obsidian/` | `site/switch/obsidian/index.html` | Switch from Obsidian |
| `/switch/bear/` | `site/switch/bear/index.html` | Switch from Bear |
| `/privacy/` | `site/privacy/index.html` | The promise |
| `/download/` | `site/download/index.html` | Download, Homebrew, requirements, checksums |
| `/press/` | `site/press/index.html` | Press kit |
| `/404.html` | `site/404.html` | Not found, links home |
| `/plugins/` | `site/plugins/index.html` | Plugins: install, write and submit. Owned by `plugins`, not growth (see Dependencies) |

The roadmap and contributing pages are not copied to the site. The header links **Roadmap** to `docs/roadmap.md` on GitHub and **Contribute** to `CONTRIBUTING.md`, so there's one copy of each.

Header: logo + **NoteIt**, then **Features · Compare · Switch · Privacy · Roadmap · Download** and a GitHub link. Footer: "Free software under the AGPL-3.0-or-later. No cookies, no tracking on this site." plus links to Press, Contribute, Security (`SECURITY.md`) and the changelog.

#### 1.3 Page content

**Home.** Title tag: `NoteIt: fast, private notes for Mac`. Hero:

> **Notes at the speed of thought.**
> A native Mac notes app with Apple Notes speed, power-user formatting and capture from any app. Sync end-to-end encrypted through a folder or bucket you own. Free, no account, no telemetry.
> [Download for Mac] [View on GitHub]
> macOS 14 Sonoma or later · Apple silicon and Intel · Version @@VERSION@@

Then four blocks, each one screenshot and three lines: **Capture from anywhere**, **Format like a power user**, **Your storage, your keys**, **Built to switch to** (import from Apple Notes, Bear, Obsidian, Markdown; link to `/switch/`). Once the wave 1 release is out, a fifth block, **Link and organise**, covers `[[links]]`, backlinks, nested tags and smart folders. Then the demo video (`<video controls preload="none" poster=…>`, no autoplay) and a three-item "Why trust it" row: Open source (AGPL), No account, No telemetry, each linking to `/privacy/`.

**Features.** Mirrors the README's feature list, one section per group, with the keyboard shortcut next to each feature where one exists. Items from later sub-projects appear only once they are in a full release. The page ends with one line, "What's planned: see the roadmap", linking to `docs/roadmap.md`; planned items are not listed on the page itself.

**Rule for every claim about NoteIt** (home, features, compare, switch guides, press kit, launch copy): a feature is described as something NoteIt does only if it is in the current full release. Anything else is written as "planned" and links to `docs/roadmap.md` on GitHub. "Coming soon", "in beta" or dates are never used.

**Compare.** One table, a short intro and a sources list. Rules:

- Only facts that can be checked on the vendor's own site or docs. No ratings, no ticks-vs-crosses scoring, no adjectives.
- NoteIt's cells follow the claim rule above: planned items say "planned" and link to `docs/roadmap.md`.
- A **Checked on 2026-MM-DD** line above the table and a numbered source link per product. Each cell that isn't obvious has a footnote number.
- "Tell us if something here is wrong or out of date" links to the website issue template. Corrections are applied within a week.
- Re-check every cell before each launch post and at least every 6 months.

Rows and the starting values, to be verified against the sources before publishing:

| | NoteIt | Apple Notes | Obsidian | Bear | Joplin | Notion | Standard Notes |
|---|---|---|---|---|---|---|---|
| Price | Free | Free | Free; paid Sync and Publish add-ons | Free; Bear Pro subscription for sync | Free; optional paid Joplin Cloud | Free plan; paid plans | Free plan; paid plans |
| Source code | Open, AGPL-3.0 | Closed | Closed | Closed | Open, AGPL-3.0 | Closed | Open, AGPL-3.0 |
| Account needed | No | Apple Account for sync | Only for paid add-ons | No (sync uses iCloud) | Only for Joplin Cloud | Yes | Only for sync |
| Platforms | Mac (web app and iPhone: planned, linked to the roadmap) | Apple devices, iCloud.com | Mac, Windows, Linux, iOS, Android | Mac, iPhone, iPad | Mac, Windows, Linux, iOS, Android | Web, Mac, Windows, iOS, Android | Web, Mac, Windows, Linux, iOS, Android |
| Mac app | Native (SwiftUI, AppKit) | Native | Electron | Native | Electron | Electron | Electron |
| Where notes live | Files on your Mac (RTFD; Markdown folder: planned until markdown-storage ships, linked to the roadmap) | Notes database | Markdown files | Local database | Local database | Notion's servers | Local encrypted database |
| Sync options | A folder (NAS, iCloud Drive, Dropbox) or any S3-compatible bucket | iCloud | Obsidian Sync, or third-party tools | iCloud | Joplin Cloud, Dropbox, OneDrive, Nextcloud, WebDAV, S3, folder | Notion | Standard Notes servers or self-hosted server |
| End-to-end encrypted sync | On by default | With Advanced Data Protection | With Obsidian Sync | With Advanced Data Protection | Optional | No | Always |
| Sync to storage you run | Yes | No | Through third-party tools | No | Yes | No | Yes |

Sources (one per column, listed under the table): `apple.com/icloud` and Apple's Advanced Data Protection support article; `obsidian.md/pricing`; `bear.app/faq`; `joplinapp.org/help`; `notion.com/pricing`; `standardnotes.com/plans`. NoteIt's column links to the README and `docs/known-limitations.md`, and lists what NoteIt doesn't have (no iPhone app yet, Mac only) in the same plain terms.

**Switch guides.** Same structure on every page, each under 600 words:

1. *What carries over* and *what doesn't*, taken from `docs/known-limitations.md#import`.
2. *Steps*, numbered, with menu paths exactly as in the app.
3. *Things that work differently in NoteIt* (three to five bullets).
4. *If something went wrong*: link to the import problem template.

| Guide | Today | After wave 1 |
|---|---|---|
| Apple Notes | File › Import… › **Apple Notes**, approve the Automation prompt. Checklists become bullets, non-image attachments and locked notes are skipped. | Unchanged; onboarding from surfaces-polish adds the 30-second path, and the guide links to it when it ships. |
| Bear | Bear › File › Export Notes as TextBundle or Markdown, then File › Import… › **Bear** in NoteIt. Tags `#a/b` are kept as typed. | Nested tags from organise make `#a/b` a real hierarchy. |
| Obsidian | File › Import… › **Markdown & Obsidian** and pick the vault folder. `.obsidian` and `.trash` are skipped. `[[links]]` become plain text. | `[[links]]` stay links (linking). Optional Markdown folder library (markdown-storage) can open the files in place. |
| Notion | Export as Markdown & CSV, unzip, File › Import… › **Markdown & Obsidian**. Databases become plain notes, CSVs are skipped. | The Notion importer from markdown-storage replaces these steps. |
| Evernote | No direct import. The page says so plainly and links to the Ideas discussion. Workaround: convert `.enex` to Markdown with the open-source `yarle` tool, then import the folder. | The `.enex` importer from markdown-storage replaces the workaround. |

The "After wave 1" column describes the guide once those features are in a full release; until then the guide describes only today's steps, and may mention the coming change once as "planned" with a link to `docs/roadmap.md`. The Evernote and Notion pages are rewritten when markdown-storage ships its importers; the plan has a task for it.

**Privacy.** Title: **Our promise**. The page is short and every line is checkable:

> 1. **No account.** NoteIt never asks you to sign up, and nothing in it needs a NoteIt server. There isn't one.
> 2. **No telemetry.** NoteIt doesn't collect usage data, crash reports or analytics. It doesn't phone home. Every host the app can talk to is listed in [docs/network.md](…), and a test fails if the code adds one without listing it.
> 3. **Your storage, your keys.** Sync goes only to a folder or bucket you choose, encrypted on your Mac before it leaves. Your passphrase stays in your Keychain.
> 4. **Free, with no paid tier.** There's no Pro version and no features held back. NoteIt is AGPL-3.0-or-later, so if the project ever changed course, anyone could keep the last free version going.
> 5. **Your notes stay yours.** Export everything as Markdown, HTML, PDF, RTFD or plain text at any time.

Then **What NoteIt connects to**. `docs/network.md` (owned by sync-security) is the source for this section and for the "No telemetry" promise; the page links to it on GitHub and doesn't keep its own inventory. It summarises the two calls most people ask about in one sentence each, both taken from `docs/network.md`: the update check (Sparkle fetching `appcast.xml` from GitHub Releases; turn off **Check for Updates Automatically** in Settings › General; it sends no system profile) and sync (only when you connect it, only to your storage). If `docs/network.md` isn't merged yet when the page goes live, the page carries just those two sentences and gains the link in the same week `docs/network.md` lands. Then **This website**: no cookies, no analytics, no external requests; GitHub Pages keeps standard server logs that the project can't see. Then **What we can see**: GitHub's public counts of stars and downloads, including how often the update feed is downloaded, as totals only.

**Download.** One button, `Download NoteIt @@VERSION@@ (@@DMG_SIZE@@)`, linking to `@@DMG_URL@@`. Below it: requirements, the Homebrew command, `SHA-256: @@DMG_SHA256@@` with a one-line `shasum -a 256` example, "Signed and notarized by Apple", "Updates arrive through Check for Updates…", links to the release notes and all releases, and "Build from source" linking to the README section.

#### 1.4 Rules every page follows

- `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'self'; img-src 'self' data:; media-src 'self'; base-uri 'none'; form-action 'none'">`. With `script-src` unset, no script can run.
- System font stack only. Colours from the brand gradient (`#6E5BFF`, `#3A3FD9`, `#1E2470`) with text contrast of at least 4.5:1 in both schemes. `prefers-color-scheme` for dark mode.
- Every `<img>` has `alt`, `width` and `height`. Site screenshots are PNG, 1600 px wide (resized from the press kit originals with `sips`), under 400 KB each.
- Open Graph and Twitter card tags use `.github/assets/noteit-social-preview.png` (1280 x 640), copied to `site/assets/social.png`.
- `site/robots.txt` allows all and points to `site/sitemap.xml`, which is hand-maintained and checked by `check_site.py`.
- `scripts/check_site.py <dir>` (Python 3 standard library only, like `scripts/make_appcast.py`) checks: every internal link and asset resolves; no `http://` or external `src`/`href` for scripts, styles, fonts, images or media; no `<script>`; every page has the shared header and footer blocks byte-identical between `<!-- header -->` markers; every page has a title, description, canonical URL and the CSP meta; every page is in the sitemap; no `@@` placeholders remain when run with `--stamped`. It prints `OK: <n> pages` or one line per problem and exits 1.

### 2. Public roadmap and voting

- Turn on Discussions (`gh repo edit --enable-discussions`). Categories, created by hand in Settings (there's no API for categories):

| Category | Format | Who can start | Purpose |
|---|---|---|---|
| Announcements | Announcement | Maintainers | Releases, monthly roadmap update, launch |
| Ideas | Open-ended | Anyone | One idea per discussion; upvote to vote |
| Q&A | Question / Answer | Anyone | How do I…, with marked answers |
| Show and tell | Open-ended | Anyone | Setups, workflows, plugins later |
| General | Open-ended | Anyone | Everything else |

- `.github/DISCUSSION_TEMPLATE/ideas.yml` asks for: the problem, the current workaround, and an Area dropdown matching the `area:` labels. It says: "Vote with the up arrow on the idea. Please don't add +1 comments."
- **Voting rule.** Discussion upvotes are the vote count. Once a month, the maintainer posts **Roadmap update – <Month YYYY>** in Announcements: the 10 most upvoted open ideas with a status for each, and what shipped.
- **Labels** (defined in `.github/labels.yml`, applied with `scripts/sync_labels.sh`, used on both issues and discussions):
  - `area: editor`, `area: capture`, `area: organise`, `area: linking`, `area: automation`, `area: storage`, `area: sync`, `area: import-export`, `area: private-ai`, `area: clipper`, `area: plugins`, `area: mobile`, `area: web`, `area: site`, `area: docs`
  - `status: planned`, `status: in progress`, `status: shipped`, `status: not planned`, `status: needs design`
  - kept as they are: `bug`, `enhancement`, `documentation`, `good first issue`, `help wanted`, `accessibility`, `dependencies`, `github_actions`, `duplicate`, `invalid`, `question`, `wontfix`
  - new: `import problem`, `launch`
- **Flow.** Idea in Discussions → maintainer adds `status: planned` and links it from `docs/roadmap.md` → when work starts, an issue is opened (or the idea is converted with "Create issue from discussion"), labelled `status: in progress` → on release, `status: shipped` and the discussion is closed with a link to the changelog. `status: not planned` always comes with one sentence saying why.
- `docs/roadmap.md` keeps its Now / Next / Later shape. Each unchecked item gains a "Discuss" link to its Ideas discussion. The intro says how voting works.
- No GitHub Projects board. It would be a third copy of the roadmap.

### 3. Issue templates

- `.github/ISSUE_TEMPLATE/config.yml`: keep `blank_issues_enabled: false` and the security link. Add contact links **Suggest an idea** (Discussions › Ideas) and **Ask a question** (Discussions › Q&A).
- `feature_request.yml` is removed. Ideas go to Discussions so they can be voted on. Maintainers still open `enhancement` issues directly.
- `bug_report.yml`: add **WebDAV** to the sync provider list once sync-security ships it (not before); add an **Area** dropdown with the `area:` values that apply to the app; add "How did you install NoteIt?" (DMG, Homebrew, built from source).
- New `import_problem.yml` (label `import problem`): source app and version, what was imported (folder, TextBundle, Apple Notes), how many notes, what went wrong, the import summary text, and an optional small sample file with a warning to remove anything private.
- New `site_or_docs.yml` (label `area: site`): page URL, what's wrong or out of date, the correct information and a source. Used by the comparison table's "Tell us" link.
- `.github/PULL_REQUEST_TEMPLATE.md`: add a checklist line "Changelog updated under `## [Unreleased]` if users will notice".

### 4. Launch

#### 4.1 Gate

Launch week starts only when all of these are true:

- The wave 1 release is out: the first full release that contains all of wave 1 (automation, markdown-storage, linking, organise), built on the wave 0 foundations. It is at least 7 days old with no open `bug` issue that loses data or blocks launch.
- Every claim on the website and in the launch copy is true for that release; anything else is marked "planned" and links to `docs/roadmap.md`.
- The website is live, the comparison table has been checked in the last 14 days, and every switch guide has been walked through on a clean scratch library.
- The demo video and press kit are published.
- Discussions are on, and at least 6 good first issues are open and labelled.
- The name check in 4.5 is done.
- The maintainer has blocked out launch day and the day after to answer.

#### 4.2 Sequence

Day L is a Tuesday that isn't in the week of a US public holiday or a major Apple event. Default: the second Tuesday after the wave 1 release.

| When | What |
|---|---|
| L − 21 days | Site, Discussions, labels, templates, contributor docs live. Seed good first issues. |
| L − 14 | Demo video recorded, press kit published. Pre-release build to a few existing users for a last check. |
| L − 7 | Copy frozen. Feature claims checked against the release. Comparison table re-checked. |
| L, 15:00 UTC (08:00 US Pacific) | Show HN. Mastodon announcement. Announcements post in Discussions. Maintainer answers HN comments for at least 6 hours. |
| L + 1 | r/macapps post. |
| L + 3 (Friday) | r/selfhosted, in whatever form its rules ask for that week (own post with the right flair, or the weekly self-promotion thread). |
| L + 7 (Tuesday), 00:01 US Pacific | Product Hunt. Mastodon reminder post. |
| L + 14 | Short write-up in Announcements: what people asked for, what changes next. Ideas from the launch threads are copied into Discussions › Ideas. |
| L + 30 or later | Homebrew official cask, if the thresholds in 6 are met. |

Rules for every channel:

- Posts are written and sent by the maintainer, from the maintainer's own long-standing accounts, and say so ("I made this").
- Never ask anyone to upvote, star or comment, on any channel. No voting rings, no sockpuppets, no paid promotion.
- Check each community's current rules the day before posting; the r/macapps and r/selfhosted rules below are what they were in October 2026 and change often.
- Answer every on-topic question. Disagree politely, never argue about other apps.
- Every claim in a post must be true for the release people will download that day.

#### 4.3 Post copy

These are drafts. Replace the bracketed feature list with what the wave 1 release actually contains.

**Show HN.** Title (79 characters max): `Show HN: NoteIt – a native Mac notes app with encrypted sync to storage you own`. URL: the GitHub repo (people on HN prefer the code). Text field empty; the first comment, posted right away:

> Hi HN, I built NoteIt because I wanted Apple Notes' speed with real formatting and keyboard-driven capture, and I didn't want my notes on someone else's server.
>
> It's a native SwiftUI/AppKit app for macOS 14+. Notes are files on your Mac. A global hotkey captures selected text from any app with a link back to the page. There's a command palette, Markdown shortcuts as you type, code blocks with highlighting, and [wave 1: wiki links and backlinks, nested tags, smart folders, a URL scheme, Shortcuts actions and a CLI].
>
> Sync is optional. Point it at a folder (a NAS share, iCloud Drive) or any S3-compatible bucket, such as MinIO on your NAS. Everything is encrypted with AES-GCM on your Mac before it leaves, with a key from your passphrase. There's no NoteIt server and no account, and the app sends no telemetry; the only other network call is the update check, which you can turn off.
>
> It's AGPL-3.0, and the only dependency is Sparkle. The sync design is written up in docs/specs. Things it doesn't do yet are listed in docs/known-limitations.md: no iPhone app, Mac only for now.
>
> I'd especially like feedback on the sync design and on what stops you from switching.

**r/macapps.** Title: `NoteIt: a free, open-source native notes app with global capture and encrypted sync to your own storage`. Flair: the developer/self-promotion flair the sub uses. Body:

> I'm the developer. NoteIt is a native Mac notes app (SwiftUI and AppKit, macOS 14+). It's free with no paid tier, open source (AGPL), needs no account, and has no telemetry.
>
> What it's good at:
> - Capture: global hotkeys for Quick Capture, a menu bar panel, and Capture Selection, which saves selected text from any app with a link back to the page.
> - Writing: Markdown shortcuts as you type, checklists, tables, code blocks with syntax highlighting, a command palette, and editable shortcuts.
> - [wave 1 highlights]
> - Switching: imports from Apple Notes, Bear, Obsidian and Markdown folders.
> - Sync (optional): end-to-end encrypted, through a folder or an S3-compatible bucket you own.
>
> Not there yet: no iPhone app, and the full list is in known-limitations.
>
> Download (signed and notarized) or `brew install --cask rutbergphilip/tap/noteit`: [site link]. Happy to answer anything.

**r/selfhosted.** Title: `NoteIt: Mac notes that sync end-to-end encrypted to your own MinIO, NAS or S3 bucket, no server needed`. Body:

> I'm the developer. NoteIt is a native Mac notes app whose sync talks straight to storage you run: a MinIO bucket on your NAS, any S3-compatible service, or a plain folder on an SMB share. There's no NoteIt server in between and no account.
>
> How it works: each note, notebook and tombstone is its own object under a versioned prefix. Everything except a small format manifest is encrypted with AES-GCM using a key derived from your passphrase (PBKDF2-HMAC-SHA256, 210,000 iterations). Conflicts are kept as copies, never dropped. `http://` is allowed for LAN endpoints. It lists the bucket once a minute while you use it and every 10 minutes in the background.
>
> It's AGPL-3.0, and the sync spec is in the repo if you want to check it. The client is Mac only today. A self-hostable web app (one Docker image) is planned and on the roadmap ([link to docs/roadmap.md]); that's where Linux and Windows come in.
>
> Repo: [link]. Feedback on the sync design is very welcome.

**Product Hunt.**

- Name: `NoteIt`
- Tagline (60 characters max): `Fast, private Mac notes that sync to storage you own`
- Description (260 characters max): `A native Mac notes app with Apple Notes speed, rich formatting and capture from any app. Sync is end-to-end encrypted through a folder or S3 bucket you own. Free, open source (AGPL), no account and no telemetry.`
- Topics: Mac, Productivity, Note taking, Open Source, Privacy.
- Thumbnail: the app icon at 240 x 240. Gallery: 5 images at 1270 x 760 (home hero, Quick Capture, Capture Selection, command palette, Sync settings), plus the demo video.
- Pricing: Free. Links: website, GitHub.
- Maker's first comment: the Show HN comment, shortened to three paragraphs, ending with "What would stop you from switching?"
- Self-hunted. No "hunter" is recruited.

**Mastodon** (500 characters; posted from the maintainer's account, with alt text on every image):

> I've released NoteIt, a native Mac notes app. Global capture from any app, Markdown shortcuts, a command palette, and optional sync that's end-to-end encrypted through a folder or S3 bucket you own. No account, no telemetry, free and AGPL-licensed.
>
> [site link]
>
> #macOS #OpenSource #Privacy #SelfHosted #NoteTaking

Follow-up in the same thread: one post each on capture, sync, and importing, each with one screenshot.

#### 4.4 Demo video

- 60 seconds, 1920 x 1080, 30 fps, H.264 MP4, no audio track. Captions are burned in, so it works muted everywhere. Target size 12 MB or less, so it can be committed as `site/media/noteit-demo.mp4` with `site/media/noteit-demo-poster.png`.
- Recorded on a clean scratch library (`NOTEIT_DATA_DIR`) filled from `design/press/demo-notes/` via File › Import…, with the menu bar cleaned, Do Not Disturb on, a plain wallpaper, light mode except shot 7, and keystroke overlay text added in editing (not a third-party keystroke app).
- Recorded with macOS screen recording (⇧⌘5) and edited in any editor; `ffmpeg` (installed with Homebrew) does the final encode and size check. The project file isn't committed.

| # | Time | Shot | Caption |
|---|---|---|---|
| 1 | 0–5 s | Safari article. Select a paragraph, press the Capture Selection hotkey. Toast "Saved to Inbox". | Capture from any app. |
| 2 | 5–11 s | NoteIt opens on the new note: quote and "From … in Safari" link. | It keeps a link back to where it came from. |
| 3 | 11–17 s | Quick Capture over a full-screen app, type two lines, Esc. | Quick Capture floats over everything. |
| 4 | 17–27 s | Editor: type `# `, `- [ ] `, ```` ```swift ````, `**bold**`; formatting appears as typed. | Markdown as you type. Real formatting. |
| 5 | 27–35 s | ⌘O, type "gro", open a note; ⇧⌘P, run a command. | Everything is a few keys away. |
| 6 | 35–43 s | Wave 1: type `[[` and pick a note; open the backlinks panel; click a nested tag. | Link your notes. Organise without folders. |
| 7 | 43–52 s | Dark mode. Settings › Sync, MinIO preset, "End-to-end encryption" on, status "Up to date". | Sync through storage you own. Encrypted on your Mac. |
| 8 | 52–60 s | Logo on the brand gradient, URL, "Free · Open source · No account · No telemetry". | NoteIt for Mac. |

#### 4.5 Name risk

There are several unrelated iOS apps called "noteit" or "Noteit Widget" (couples drawing widgets), at least one with a large user base, and some run on Apple silicon Macs. Searching "noteit" today mostly returns them. NoteIt is a different product category, but the clash costs discoverability and could become a trademark question.

Options:

1. **Keep NoteIt, add a descriptor.** Use "NoteIt for Mac" or "NoteIt notes" in titles, the site title and store-like listings. Cost: nothing. Risk: search confusion stays.
2. **Rename before launch.** The Inkwell → NoteIt migration code (`Sources/NoteItSync/Migration/`) shows a rename is doable, and it's cheapest now, with no stars and few installs. Cost: a second migration, new bundle ID, new tap token, new brand assets, and a second "formerly called" note. The sync prefix `noteit/v1/` is unaffected.
3. **Keep the name, prepare a rename only if challenged.** Cost: nothing now; a forced rename after launch would cost the launch's search traffic.

Recommendation: before L − 21, search the USPTO, EUIPO and WIPO Global Brand Database for "NOTEIT" in Nice classes 9 and 42. If a live registration covers software, take option 2 before launch. Otherwise take option 1, and re-check yearly. The decision belongs to the maintainer; this spec doesn't rename anything.

### 5. Press kit

- Page `/press/` and a zip, `noteit-press-kit.zip`, built by the Pages workflow.
- Contents:
  - The shipping app icon: `Resources/AppIcon.iconset/icon_512x512@2x.png` (1024 px) and `icon_512x512.png`. The Swift Page mark in `design/assets/logo/` is alternative artwork and isn't in the kit.
  - The README banners from `.github/assets/` (hero light and dark PNGs, social preview).
  - Screenshots in `design/press/screenshots/`, 2880 x 1800 PNG, light and dark: main window, Quick Capture, menu bar panel, command palette, Capture Selection toast, Settings › Sync, plus wave 1 shots (backlinks, smart folder).
  - `design/press/README.txt`: the description, facts and brand rules in plain text.
- One-paragraph description (also on the page):

  > NoteIt is a free, open-source notes app for the Mac. It's built natively with SwiftUI and AppKit, opens instantly, and is made for the keyboard: global hotkeys capture text from any app with a link back to its source, a command palette reaches every note and command, and Markdown shortcuts format as you type. Notes are files on your Mac. Optional sync goes through a folder or an S3-compatible bucket you own and is end-to-end encrypted. There's no account, no NoteIt server and no telemetry. NoteIt is licensed under the AGPL-3.0-or-later.

- Facts: name (and how to write it, from `design/BRAND.md`), platform and requirement, price, license, first release (0.1.0) date, current version, maintainer, repository, contact (GitHub Discussions; no email is published).
- Screenshots are made with debug launch arguments from `docs/development.md` (`--debug-menubar-preview`, `--debug-quick-capture`, `--debug-open-settings --debug-settings-tab sync`, `--debug-dark`) on a scratch library, so they're reproducible. `design/press/screenshots.md` lists the exact command for each file.

### 6. Official Homebrew cask

Current state: `Casks/noteit.rb` in `rutbergphilip/homebrew-tap`, written by `scripts/update_cask.sh` and pushed by the `homebrew` job in `release.yml`. The `noteit` token is free in `homebrew/cask` (checked 2026-10-19).

Homebrew's rules, from docs.brew.sh *Acceptable Casks* and *Package Acceptance Policy* (October 2026):

- Notability: at least 30 forks, 30 watchers or 75 stars; for a submission by the repository owner, at least 90 forks, 90 watchers or 225 stars.
- The repository must be at least 30 days old (NoteIt's is from 2026-10-12, so 2026-11-11 or later).
- A working `livecheck`, a homepage that explains the project, active maintenance, Gatekeeper must pass, and the cask must work on the latest macOS.
- For unrelated apps with the same name, the more widely known one keeps the plain token.

Decision:

- Don't submit before the thresholds are met. Don't ask anyone else to submit it to get around the higher self-submission bar. If a user opens a request on their own, the maintainer supports it in the PR.
- Before submitting, align the tap cask with homebrew/cask style so the submission is a copy: `homepage` becomes the website, `desc` stays under 80 characters and doesn't start with the name or an article, `depends_on macos: ">= :sonoma"`, add `uninstall quit: "io.github.rutbergphilip.noteit"`, keep `auto_updates true`, and add the legacy Inkwell paths to `zap` (`~/Library/Application Support/Inkwell`, `~/Library/Preferences/com.inkwell.app.plist`). `scripts/update_cask.sh` is changed to match, and `brew audit --cask --new --online` and `brew style` must pass on the tap.
- **The `noteit` command line tool.** Growth owns the cask's `binary` line (program design §12); automation owns the tool itself, `NoteItCLI`, shipped inside the app as `Contents/Helpers/noteit`. The line is:

  ```ruby
  binary "#{appdir}/NoteIt.app/Contents/Helpers/noteit"
  ```

  It goes right after `app "NoteIt.app"`. It is gated on automation's command line milestone (M4): `scripts/update_cask.sh` writes the line only for a release whose app contains `Contents/Helpers/noteit`, so the cask never points at a missing file. Releases before that keep the cask without it. Once the line is in, it is part of the alignment above, it is in the official homebrew/cask submission, and `brew audit` and `brew style` must pass with it. If automation's M4 hasn't shipped when the official cask is submitted, the submission goes in without the line and a follow-up PR to homebrew/cask adds it with the first release that has the tool.
- After acceptance:
  - The tap gets `tap_migrations.json` with `{ "noteit": "homebrew/cask" }` and its `Casks/noteit.rb` is removed, so `brew upgrade` moves tap users over.
  - The `homebrew` job and the `HOMEBREW_TAP_DEPLOY_KEY` secret are removed from `release.yml` and `docs/releasing.md`. homebrew/cask updates the cask itself through its autobump, which uses the `livecheck`. The Pages deploy step at the end of the `publish` job stays.
  - README, site and launch copy switch to `brew install --cask noteit`.

### 7. Contributor onboarding

- **`docs/architecture-tour.md`**: a guided, 20-minute read that follows three paths through real files, linking to `docs/architecture.md` for the full map instead of repeating it. It opens with a short "How the project is organised" step that links to the [program design](2026-10-19-program-design.md): the sub-projects, the delivery waves, the target graph and the frozen tables, and the rule that the program design wins when a sub-project spec disagrees with it. Then the three paths:
  1. *A keystroke*: `Editor/NoteItTextView.swift` → `MarkdownShortcuts.swift` → `RichTextEditor.swift` → `Model/NoteStore.swift` autosave.
  2. *A capture*: `Hotkeys/HotkeyManager.swift` → `Capture/CaptureController.swift` → `SelectionReader`, `SourceResolver`, `CaptureFormatter` → `NoteStore`.
  3. *A sync pass*: `Sync/SyncController.swift` → `NoteStoreSyncAdapter.swift` → `NoteItSync/Engine/SyncEngine.swift` → `SyncPlanner.swift` → a backend in `Storage/`.

  Each step names the test file that covers it, and the tour ends with "Where to start" pointing at `good first issue`.
- **CONTRIBUTING.md** gains a **Your first pull request** section (fork, scratch library, pick a `good first issue`, comment to claim it, open a draft PR early) and a **Where things are discussed** section (Ideas, Q&A, issues).
- **Good first issues.** Each one names the files to look at, the test to add and what "done" looks like. They must not overlap work owned by another sub-project. Seeds:
  1. Apple Notes checklists import as checklists, with ticked items marked done (`Import/AppleNotesImporter.swift`, fixture test).
  2. A note info popover with word count and created date (`Views/`, `Model/Models.swift`).
  3. Another code block theme, with a license that allows it (`Editor/CodeTheme.swift`).
  4. Add screenshots to `docs/keyboard-shortcuts.md`.
  5. Website: an accessibility pass on one page with VoiceOver.
  6. A debug launch argument, `--debug-open-palette`, that opens the command palette at launch, for screenshots (`App/AppDelegate.swift`, `Palette/`, `docs/development.md`).
  7. A switch guide walk-through on a fresh library, fixing anything unclear.
- **Response times.** New issues and PRs get a first reply within 3 days; this is stated in CONTRIBUTING.md.
- `.github/FUNDING.yml` is not added (see Open questions).

### 8. Metrics without telemetry

Only public, aggregate numbers that GitHub and Homebrew already publish. Nothing is added to the app or the site to measure people.

| Metric | Source | Notes |
|---|---|---|
| Stars, forks, watchers | `gh api repos/rutbergphilip/noteit` (`stargazers_count`, `forks_count`, `subscribers_count`) | Also the Homebrew notability numbers |
| DMG downloads per release | `gh api repos/rutbergphilip/noteit/releases` asset `download_count` | Includes Homebrew installs from the tap, which download the same DMG |
| Update feed downloads | `download_count` of `appcast.xml` on the latest release | A rough count of update checks; one install can check many times |
| Repo traffic and referrers | `gh api repos/rutbergphilip/noteit/traffic/views` and `traffic/popular/referrers` (14 days, needs push access) | Shows which launch channel sent people |
| Homebrew installs | `https://formulae.brew.sh/api/analytics/cask-install/homebrew-cask/30d.json` | Only after the official cask exists; Homebrew doesn't publish numbers for third-party taps |
| Community | Open/closed issues, Discussions, first-time contributors | From the GitHub UI |

- `scripts/project_stats.sh` prints these as a Markdown table, for the maintainer to run by hand. It writes nothing to the repo.
- The privacy page says what the project can see (section 1.3).
- Launch targets, used only to decide what to do next, not published as goals: 75 stars by L + 14 (the regular Homebrew bar), 225 by L + 90.

## Dependencies

- **Program design:** the delivery order, the launch timing and the ownership table (§12) come from it. If this spec disagrees with it, the program design wins.
- **automation, markdown-storage, linking, organise (wave 1, after wave 0 foundations):** the launch waits for the first full release that contains all four. Their features appear on the Features page, in the demo (shot 6), and in launch copy only once shipped.
- **automation (command line tool, M4):** ships `NoteItCLI` as `Contents/Helpers/noteit`. Growth adds the cask `binary` line only for releases that contain it.
- **web-clipper:** edits `release.yml` for the Safari build. Growth's Pages trigger is rebased on top of that change.
- **markdown-storage:** its Evernote and Notion importers replace the workarounds in the Evernote and Notion switch guides; its Markdown folder option is mentioned in the Obsidian guide and the comparison table.
- **linking:** `[[links]]` change the Obsidian guide.
- **organise:** nested tags change the Bear guide.
- **sync-security:** owns `docs/network.md`, which the privacy page links as the source for "no telemetry" and for what the app connects to; WebDAV joins the bug template and comparison table when it ships.
- **surfaces-polish:** its onboarding (import from Apple Notes in about 30 seconds) is linked from the Apple Notes guide; its published performance numbers can be quoted on the home page once they exist.
- **plugins:** owns the `noteit-plugins` directory repository, its contribution guide, and the site's `/plugins/` page (plugins plan Task 19). Growth doesn't create them. The page uses growth's shared header, footer and stylesheet, is in `sitemap.xml`, and must pass `scripts/check_site.py` and the claim rule (§1.3). It isn't in the site header.
- **web-app (existing spec) and mobile:** the comparison table and r/selfhosted copy mention them only as "planned", linked to `docs/roadmap.md`, until they ship.
- **Local API:** none needed. Nothing in this sub-project talks to the app.

## Non-goals

- Analytics, tracking pixels, cookies, newsletters, email capture or a mailing list.
- A blog, a forum outside GitHub, a Discord or a Slack.
- A static site generator, a JavaScript framework or any client-side script on the site.
- Paid promotion, giveaways, review exchanges, or asking for votes or stars.
- Localising the website.
- In-app changes. The About tab and Help menu are left alone.
- A Mac App Store listing.
- A GitHub Projects board.
- Deciding a rename (section 4.5 recommends; the maintainer decides).

## Open questions

1. **Custom domain?** Default: no, use `rutbergphilip.github.io/noteit` at launch. A domain can be added later with a `site/CNAME` file and redirects keep working.
2. **Launch version number.** Default: whatever version the wave 1 release gets in the normal flow. Don't call it 1.0 just for the launch.
3. **Launch date.** Default: the second Tuesday after the wave 1 release, avoiding US holiday weeks and Apple event weeks.
4. **Rename.** Default: keep NoteIt with the "for Mac" descriptor, unless the trademark search in 4.5 finds a live registration covering software.
5. **GitHub Sponsors / FUNDING.yml.** Default: not at launch, so the "free, no paid tier" message isn't muddied. Revisit after L + 90.
6. **Video hosting.** Default: commit the MP4 to `site/media/` (12 MB or less). If it's re-shot more than twice, move it to a release asset to keep the repo small.
7. **r/selfhosted fit.** A Mac client alone is borderline for that community. Default: post once at L + 3 framed around self-hosted sync, and post again only when the web app ships.
8. **Comparison table competitors.** Default: the six named. Evernote has a switch guide but isn't in the table, to keep it to apps people commonly weigh against a local-first notes app.
