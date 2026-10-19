# Web Clipper — Design

Status: proposed · Date: 2026-10-19 · Companion plan: docs/plans/2026-10-19-web-clipper.md

## Goal

Save what you're reading in a browser as a NoteIt note in two clicks or one shortcut: the article without the clutter, a selection, the whole page, a screenshot or just a bookmark. The note keeps its images and links back to the page. One extension codebase serves Safari, Chrome, Edge, Brave and Firefox on the Mac. It talks only to the NoteIt app on the same Mac, through the Local API (`automation`), with a paired token. Nothing goes to a NoteIt server, because there isn't one.

## What the user gets

### Installing

- **Safari:** the clipper ships inside `NoteIt.app`. After the first launch of a version that includes it, **Safari › Settings › Extensions** lists **NoteIt Clipper**. Settings › Integrations › Web Clipper in NoteIt shows whether it's turned on and has an **Open Safari Extensions…** button.
- **Chrome, Edge, Brave:** **NoteIt Clipper** in the Chrome Web Store. Edge and Brave install it from there too.
- **Firefox:** **NoteIt Clipper** on addons.mozilla.org (AMO).
- Settings › Integrations › Web Clipper links to the three store pages. The store listings say plainly: "Requires NoteIt for Mac."

### Connecting (once per browser)

1. The first time you click the toolbar button, the popup says **Connect to NoteIt** with two steps:
   - "Open NoteIt and turn on **Allow apps on this Mac to use NoteIt** in Settings › Integrations."
   - "Click **Connect**, then type the 6-digit code NoteIt shows."
2. **Connect** asks NoteIt to pair (`automation`'s pairing). NoteIt comes to the front with its pairing window: **“NoteIt Clipper in Chrome” wants to read and change your notes.** It shows the code as `482 913`, the extension's origin (`chrome-extension://…`) and a **Deny** button.
3. You type the code into the popup. The popup says **Connected** and moves on to the clip form.
4. A wrong code says **That code doesn't match.** After 5 wrong codes NoteIt cancels the pairing, and after 2 minutes the code expires. Both say **Pairing was cancelled. Click Connect to get a new code.** If NoteIt denies it: **NoteIt didn't allow this browser.**
5. Connected browsers appear under **Connected apps** in Settings › Integrations (`automation`), where **Revoke** disconnects them. The extension's options page has **Disconnect**, which also revokes the token in NoteIt.

### The popup

Click the toolbar button or press **⌃⇧S** (Alt+Shift+S on other platforms). The manifest declares the Mac shortcut as `MacCtrl+Shift+S`, which is ⌃⇧S, the Control key. In a WebExtension manifest `Ctrl` means ⌘ on a Mac, so the manifest keeps `MacCtrl` and never uses `Ctrl` for the Mac key. Quick clip is `MacCtrl+Shift+A` (⌃⇧A) the same way.

```
[Article] Selection  Page  Screenshot  Bookmark
Title     [How SQLite stores pages            ]
Notebook  [Inbox v]     Tags [reading x] [+]
Note      [Add a note...                      ]
-----------------------------------------------
2,340 words · 6 images · sqlite.org
"SQLite stores its database in fixed-size..."
-----------------------------------------------
Options                        [Save to NoteIt]
```

- **Modes:** Article, Selection, Page, Screenshot, Bookmark. The popup picks the starting mode:
  1. **Selection** when text is selected on the page;
  2. else **Article** when the page looks like an article;
  3. else **Bookmark**.

  The options page can fix the default to Article, Page or Bookmark instead of **Automatic**. Selection is disabled when nothing is selected. Unavailable modes are greyed out with a tooltip that says why.
- **Title:** prefilled from the article title, the page's `og:title`, or the tab title. One line, at most 200 characters.
- **Notebook:** your notebooks from NoteIt, with nested notebooks indented once `organise` ships them. It starts on the last notebook you used from this browser, or, the first time, the notebook for new notes from Settings › Editor › New Notes (Inbox by default).
- **Tags:** chips with autocomplete from your existing tags. Return or comma adds a tag. It starts with the tags you used last time, when **Remember last tags** is on (off by default).
- **Note:** an optional comment that goes above the clipped content.
- **Preview:** word count, image count, the site, and the first 200 characters of the text, or a thumbnail in Screenshot mode.
- **Save to NoteIt** (⌘↩). While saving, the button reads **Saving…**, and **Downloading 6 images…** when images take longer than a second.
- **Saved:** **Saved to Inbox**, with **Open in NoteIt** and **Done**. Open in NoteIt brings NoteIt to the front with the note selected. When some images failed, the line below says **2 images couldn't be downloaded; they're saved as links.**
- Esc closes the popup. A save already in progress finishes, because the background script sends it, not the popup.

### Quick clip, context menu and the in-page notice

- **Quick clip**, **⌃⇧A** by default: saves straight away in the automatic mode, to the last-used notebook with no tags, without opening the popup.
- The page context menu has a **NoteIt** submenu:
  - **Clip Article**, **Clip Full Page**, **Clip Screenshot**, **Save Bookmark** on any page;
  - **Clip Selection** when text is selected;
  - **Save Link as Bookmark** on a link;
  - **Save Image** on an image.
- Quick clip and context menu saves show a small notice in the page's top-right corner, like NoteIt's capture notice: **Saved to Inbox · Open in NoteIt**. It fades after 3 seconds and stays while hovered. Errors stay 8 seconds: **Couldn't save: NoteIt isn't reachable · Open NoteIt**.
- Where a page can't be scripted (browser pages, store pages, the PDF viewer), the notice can't be shown. The toolbar badge shows a check mark for 2 seconds on success, and a red **!** on failure, which opens the popup with the error when clicked.
- Chrome and Firefox let you change both shortcuts, in `chrome://extensions/shortcuts` and Firefox's **Manage Extension Shortcuts**. Safari uses the defaults. They're browser commands, not NoteIt global hotkeys, so they don't appear in Settings › Shortcuts.

### When NoteIt can't be reached

- **NoteIt isn't running, or the Local API is off:** the popup says **Can't reach NoteIt**, "Make sure NoteIt is open and **Allow apps on this Mac to use NoteIt** is on in Settings › Integrations." Two buttons: **Open NoteIt** and **Try Again**.
  - **Open NoteIt** opens `noteit://settings?tab=integrations`, which launches NoteIt if needed and shows the switch you may have to turn on. The browser may ask once whether to open NoteIt.
  - The popup then checks every second for 20 seconds and returns to the clip form, with your title, notebook, tags and note kept, as soon as NoteIt answers.
  - Both cases look the same from the browser, because a server that's off doesn't answer, so the message names both.
- **The token was revoked:** **This browser is no longer connected to NoteIt.** with **Connect Again**. The prepared clip is kept.
- **NoteIt is too old** (no clipper support in its Local API): **Update NoteIt to use the clipper.** with a link to the releases page.
- **The library isn't ready** (still loading, or a library switch in progress): **Your library is still opening. Try again in a moment.**
- **Too many requests** (`automation`'s rate limit): **NoteIt is busy. Try again in a moment.**
- **The notebook was deleted in the meantime:** the notebook list reloads and the popup says **That notebook no longer exists. Choose another.**
- **The notebook is read-only** (a shared notebook you can only read): **You can only read that notebook. Choose another.**
- Clips are never queued in the background. If a save fails, the popup keeps the prepared clip until it's closed, and Try Again resends it.

### The note

Every clip makes one new note. It never appends to an existing one.

| Mode | Note layout |
|---|---|
| Article | Title · your note · source line · byline line · the article |
| Page | Title · your note · source line · the simplified page |
| Selection | Title · your note · the selection, quoted · source line (the same layout as capture) |
| Screenshot | Title · your note · source line · the screenshot image |
| Bookmark | Title · your note · source line · description · preview image |
| Image | Title (alt text or file name) · your note · source line · the image |

- The **source line** uses capture's wording and link format from `CaptureFormatter`: **From \<page title\> in Chrome**, with the page title linked to the page. The browser is named when it can be told apart (Safari, Chrome, Edge, Brave, Firefox, Opera, Vivaldi, Arc). Otherwise the " in …" part is left out.
- The **byline line**, for articles that have one: **By Jane Doe · 18 October 2026**, as a body paragraph. Either part may be missing.
- **Tags** are added as a last line of hashtags, `#reading #databases`, the way the Markdown importer adds front matter tags. When `organise` ships tag chips, they become chips.
- Formatting maps to NoteIt's own styles, so a clipped note edits like a typed one:
  - `h1`–`h2` become Heading and `h3`–`h6` Subheading. The note's own title is the only Title.
  - Lists, checklists, quotes, code blocks (with the language when the page marks it), tables, links, bold, italic, strikethrough and inline code are kept.
  - Embedded videos become a link line: **Video: \<title\>**.
- Tracking parameters are removed from the saved address: `utm_*`, `fbclid`, `gclid`, `dclid`, `msclkid`, `mc_cid`, `mc_eid`, `igshid`, `_hsenc`, `_hsmi`, `ref_src`.

### Settings in NoteIt

| Where | What |
|---|---|
| Settings › Integrations › Web Clipper | A section after **Connected apps** in `automation`'s Integrations tab (raw value `integrations`, so `noteit://settings?tab=integrations` opens it). Safari: **On** / **Off in Safari** / **Not available** (dev builds without the extension), and an **Open Safari Extensions…** button |
| Settings › Integrations › Web Clipper | **Get the clipper for Chrome, Edge and Brave** and **Get the clipper for Firefox** links |
| Settings › Integrations › Web Clipper | A footnote: "The clipper connects through the Local API above. Turn it on, then click Connect in the clipper." |
| Settings › Integrations (`automation`) | **Allow apps on this Mac to use NoteIt**, and **Connected apps** with **Revoke** |
| Settings › Editor › New Notes | The default notebook, used by clips until you pick another in the popup |
| Command palette | **Set Up Web Clipper…** opens Settings › Integrations |

### Options page in the extension

- **Connection:** **Connected to NoteIt on port 47600** (the port in use) with **Disconnect**, or **Not connected** with **Connect**.
- **Default clip:** Automatic, Article, Page or Bookmark.
- **Save images in the note:** on by default. Off saves images as links.
- **Remember last tags:** off by default.
- **Advanced › Port:** **Automatic** (tries 47600–47609) or a number. Only needed if a fixed port outside that range is set in NoteIt.
- **Shortcuts:** shows the current ones, with a link to the browser's shortcut settings.
- A privacy line: "The clipper reads a page only when you clip it, and sends it only to NoteIt on this Mac."

## Design

### 1. Repository layout and build

- `clipper/` at the repository root holds one TypeScript WebExtension, Manifest V3. It has its own `package.json` and `pnpm-lock.yaml`, built with pnpm and Node 24 like `web/` in the web-app spec. It's a separate project, not part of the `web/` workspace, so either can build without the other.
- Dependencies are kept to three runtime libraries, all bundled at build time:
  - `@mozilla/readability` (Apache-2.0) for article extraction;
  - `turndown` (MIT) and `turndown-plugin-gfm` (MIT) for HTML to Markdown.

  Development tools: `typescript`, `esbuild`, `vitest`, `jsdom`, `web-ext`. The popup and options page are plain TypeScript and DOM, without a UI framework.
- `clipper/scripts/build.mjs <target>` writes `clipper/dist/<target>/` for `chrome`, `firefox` and `safari`. The manifest is `clipper/manifest/base.json` merged with `clipper/manifest/<target>.json`, with `version` from `package.json`:
  - Chrome: `background.service_worker`, `minimum_chrome_version: "120"`.
  - Firefox: `background.scripts` (Firefox has no MV3 service worker), `browser_specific_settings.gecko.id: "clipper@noteit.rutbergphilip.github.io"`, `strict_min_version: "128.0"`.
  - Safari: `background.service_worker`. Safari 17 or later, which every supported macOS has.
- No remote code: everything is bundled, and the extension pages' CSP is MV3's default.
- Icons are rendered from `design/assets/logo/noteit-mark.svg` at 16, 32, 48 and 128 px into `clipper/icons/`, committed, with a toolbar template variant for Safari.

### 2. Permissions

```json
"permissions": ["activeTab", "contextMenus", "storage", "scripting"]
```

- `activeTab` gives temporary access to the current tab, and only after a user action: the toolbar button, a shortcut or the context menu. The clipper never reads a page you didn't clip. It works with `scripting` to inject the extractor and with `tabs.captureVisibleTab` for screenshots.
- No content scripts are declared in the manifest. Nothing runs on pages until you clip.
- No host permissions. The Local API answers CORS preflights from `chrome-extension://`, `moz-extension://` and `safari-web-extension://` origins (`automation` §6.6), so the background script reaches `http://127.0.0.1:<port>` with plain `fetch`. If a browser turns out to block that, the fallback is adding `http://127.0.0.1/*` as an optional host permission requested from the **Connect** click; see Open questions.
- No `tabs`, `<all_urls>`, `downloads`, `notifications`, `cookies`, `history` or `webRequest`. Image downloads happen in NoteIt (§6), so the extension needs no access to image hosts.
- `clipper/test/manifest.test.ts` checks the generated manifests, so a new permission fails CI until the test is changed on purpose.

### 3. Extension structure

| Part | File | Job |
|---|---|---|
| Background | `src/background/index.ts` | Registers menus and commands, routes popup messages, sends every Local API request, sets the badge |
| API client | `src/api/client.ts` | `LocalApiClient`: ping and port lookup, pairing, notebooks, tags, clips, open note. Maps failures to `ApiError` kinds |
| Extractor | `src/content/extract.ts` | Injected on demand with `scripting.executeScript`. Returns a `ClipDraft` for a mode |
| Converters | `src/convert/*.ts` | Turndown setup and rules, image collection, URL cleaning, browser name |
| Toast | `src/content/toast.ts` | The in-page notice, in a closed shadow root |
| Popup | `src/popup/*` | The form and its states |
| Options | `src/options/*` | Connection, preferences |
| Shared | `src/shared/*` | `ext` (the `browser`/`chrome` namespace shim), typed storage, messages |

- The background script sends every request, so a save survives the popup closing. Chrome keeps a service worker alive while its fetch is pending.
- Content extraction runs in the page, where the DOM is. Chrome's service worker has no DOM.
- Messages between popup and background are typed. In `src/shared/messages.ts`: `prepare(mode)`, `save(draft, choices)`, `status()`, `connect()`, `completePairing(code)`, `openNote(id)`, `openApp()`.

### 4. Clip modes (in the extension)

All modes produce a `ClipDraft`: `mode`, `url`, `title`, `markdown?`, `images[]`, `siteName?`, `byline?`, `publishedAt?`, `excerpt?`, `wordCount`.

- **Article:**
  - Runs `isProbablyReaderable(document)` for the automatic choice, then `new Readability(document.cloneNode(true), { charThreshold: 500, keepClasses: false }).parse()`.
  - Fills `title`, `byline`, `siteName`, `publishedTime` and `excerpt` from Readability, falling back to `og:*` and `article:published_time` meta tags.
  - If Readability returns nothing, the draft falls back to Page, and the popup says **Couldn't find an article on this page. Clipping the full page instead.**
- **Selection:**
  - Clones the selection's ranges (`getRangeAt(i).cloneContents()`) into one container and converts it. Selections in same-origin frames are read with `allFrames: true`.
  - Inputs and textareas give their selected text.
  - An empty result says **Couldn't read the selection on this page. Try Bookmark or Screenshot.**, which happens with canvas editors such as Google Docs.
- **Page (simplified):**
  - On the live document, first marks hidden elements (`hidden`, `aria-hidden="true"`, computed `display: none` or `visibility: hidden`) with a temporary attribute, then clones.
  - From the clone it removes `script`, `style`, `link`, `meta`, `noscript`, `template`, `iframe` (except recognised video embeds), `object`, `embed`, `canvas`, `form` controls, `dialog`, comments and the marked hidden elements, then converts.
  - Navigation and footers stay. That's the difference from Article.
- **Screenshot:**
  - `tabs.captureVisibleTab(windowId, { format: "png" })` from the background. The visible area only.
  - The data URL becomes one inline image, and the Markdown is `![Screenshot of <title>](noteit-image:i1)`.
- **Bookmark:**
  - Title, cleaned URL, description (`og:description`, then `meta[name=description]`, at most 500 characters) and the preview image (`og:image`, absolute, http(s) only).
  - When scripting isn't allowed on the page, it uses the tab's title and URL only. `activeTab` gives those.
  - **Save Link as Bookmark** uses the link's URL and text, and never visits the link.
- **Image** (context menu only): the clicked image's `srcUrl`, as one image; the title is its alt text or file name.

**Markdown conversion** (`src/convert/markdown.ts`), Turndown with ATX headings, `-` bullets, fenced code and the GFM plugin (tables, strikethrough, task lists), plus these rules:

- **Headings:** `h1`/`h2` → `##`, `h3`–`h6` → `###`, so the note keeps one Title.
- **Images:**
  - `img` and `picture` become `![alt](noteit-image:iN)` and add an entry to `images[]`.
  - The image URL is the largest `srcset` candidate up to 2,000 px wide. Otherwise it's `src`, falling back to `data-src`, `data-original` or `data-lazy-src` for lazy-loaded images. Relative URLs are made absolute against `document.baseURI`.
  - Images whose `width` or `height` attribute is 2 or less are dropped as tracking pixels.
  - `data:` images up to 10 MB go in `images[]` with their bytes, base64.
  - After 50 images, the rest become `[Image: alt](url)` links.
- **Code:** `pre > code` keeps its language from `class="language-x"` or `lang-x`.
- **Links:** `javascript:` and `data:` links keep their text and lose the link.
- **Video:** YouTube, Vimeo and `video` elements become `[Video: <title>](<page or src URL>)`.
- **Text limit:** text over 1,000,000 characters is cut at the last block boundary. The draft is marked `shortened`.

**Limits in the extension:** extraction gives up after 10 seconds with **This page took too long to read.** The draft must stay under 60 MB once encoded. A bigger draft says **This clip is too large to save.** and suggests Bookmark.

### 5. Transport: the Local API

The clipper consumes `automation`'s Local API and adds one route to it. The route is registered from the app with `LocalAPIRouteRegistry.register`, route id `web-clipper.clips`, scope `write`, and errors from `APIErrorCode` only, in the nested error body. At the same time the app calls `addCapability("web-clipper")`, which advertises the route in the `capabilities` field of `GET /v1/ping` (program §10). The clipper changes no `automation` code. Base URL `http://127.0.0.1:<port>`. Authenticated requests carry `Authorization: Bearer <token>`. JSON bodies use `Content-Type: application/json`. The Safari build also sends `X-NoteIt-Extension-Bundle: io.github.rutbergphilip.noteit.clipper` on every request, pairing included. No other custom headers are sent, because the API's CORS allow-list is `Authorization, Content-Type, If-Match, X-NoteIt-Filename, X-NoteIt-Extension-Bundle`.

| Call | Purpose | Scope | Owner |
|---|---|---|---|
| `GET /v1/ping` | Reachability: `{ name: "NoteIt", apiVersion, appVersion, capabilities }` | none | automation |
| `POST /v1/pair/start` | Body `{ clientName: "NoteIt Clipper in Chrome", kind: "extension", scopes: ["read", "write"] }`. Returns `{ pairingID, expiresAt }` | none | automation |
| `POST /v1/pair/complete` | Body `{ pairingID, code }`. Returns `{ token, clientID, scopes }` | none | automation |
| `DELETE /v1/me` | Disconnect: revokes the calling token | read | automation |
| `GET /v1/notebooks` | `{ notebooks: [{ id, name, symbol, color, sortIndex, noteCount, parentID? }], defaultNotebookID }` | read | automation |
| `GET /v1/tags` | `[{ name, noteCount }]` | read | automation |
| `POST /v1/notes/{id}/open` | Bring NoteIt to the front with the note selected | read | automation |
| `POST /v1/clips` | Save a clip (below). Route id `web-clipper.clips` | write | **web-clipper** |

- **Finding the port:** with **Port** set to Automatic, the background script tries `GET /v1/ping` on 47600 to 47609 in order and takes the first answer whose `name` is `"NoteIt"`. The port is saved with the connection and tried first next time. A connection error on a saved port probes again once before giving up.
- **Connection storage:** `storage.local` key `connection`: `{ port, token, clientID, pairedAt }`. Never `storage.sync`, so a token never leaves this browser profile. Preferences are in `storage.local` key `prefs`, and the last notebook and tags in `recent`.
- **Origin binding:** `automation` binds the token to the extension's `Origin`, so it can't be replayed from a web page. Chrome and Firefox keep a fixed origin per install, and their tokens are bound to the full origin. Safari's `safari-web-extension://<id>` origin changes between Safari launches, so `automation`'s spec binds Safari extension tokens by the origin scheme plus the extension's bundle identifier, `io.github.rutbergphilip.noteit.clipper`, which the Safari build sends in the `X-NoteIt-Extension-Bundle` header (program §10). Other extensions can't read the clipper's storage, so the token still can't leak to them. The clipper has no Safari-specific re-pairing.
- **Timeouts:** 1 s per port while probing, 10 s for other reads, 90 s for `POST /v1/clips`, which includes image downloads.
- **Error mapping** (`ApiError.kind`, from `automation`'s body `{ "error": { "code", "message" } }`):
  - connection refused or timeout on every probed port → `unreachable`;
  - 401 `unauthorized` or `token_revoked`, and 403 `origin_not_allowed` or `forbidden_scope` → `unauthorized`, shown as Connect Again;
  - 403 `pairing_failed` → `pairingCancelled`; 403 `pairing_denied` → `pairingDenied`; 409 `pairing_in_progress` → `pairingBusy`, **NoteIt is already pairing with another app. Finish that first.**;
  - any other error from `pair/complete` → `pairingWrongCode`;
  - 404 `not_found` on `/v1/clips` → `notebookGone`;
  - 403 `read_only` on `/v1/clips` → `notebookReadOnly`, which reloads the notebook list like `notebookGone`;
  - 413 `too_large` → `tooLarge`;
  - 429 `rate_limited` → `busy`; a save is retried once after `Retry-After`;
  - 503 `not_ready` → `notReady`, shown as **Your library is still opening. Try again in a moment.**;
  - `ping` without `"web-clipper"` in `capabilities` → `appTooOld`;
  - anything else → `failed`, showing the server's `message`.
- **Pairing state:** the background script keeps the `pairingID` while the popup is open. If the popup closes mid-pairing, Connect starts over; the open pairing in NoteIt expires on its own after 2 minutes.

**`POST /v1/clips` request** (JSON, at most 60 MB):

```json
{
  "clientClipID": "5f0c…",            // UUID made by the extension; repeats return the first result
  "mode": "article",                  // article | selection | page | screenshot | bookmark | image
  "url": "https://sqlite.org/fileformat.html",
  "title": "How SQLite stores pages",
  "markdown": "## Pages\n\n…![Diagram](noteit-image:i1)…",
  "images": [
    { "id": "i1", "url": "https://sqlite.org/images/pages.png", "alt": "Diagram" },
    { "id": "i2", "data": "<base64>", "mimeType": "image/png", "alt": "Screenshot" }
  ],
  "comment": "Read before the storage refactor",
  "siteName": "SQLite", "byline": "D. Richard Hipp", "publishedAt": "2026-10-18",
  "browser": "Chrome",
  "notebookID": "8E1D…",              // omitted → the default notebook for new notes
  "tags": ["reading", "databases"],
  "downloadImages": true
}
```

**Response** `201`: `{ "noteID", "notebookID", "notebookName", "title", "imagesSaved", "imagesFailed", "shortened" }`.

**Errors**, using `automation`'s codes and error body `{ "error": { "code": "…", "message": "<plain sentence>" } }`:

- 400 `bad_request`, with the field in `message`;
- 403 `read_only`: the notebook is a shared notebook the user can only read;
- 404 `not_found`: the notebook doesn't exist;
- 413 `too_large`;
- 503 `not_ready`, message **Your library is still opening. Try again in a moment.** (program §10), when the library isn't ready after waiting 10 s;
- 500 `internal` only for unexpected failures.

### 6. Saving a clip (in NoteIt)

All app code is in `Sources/NoteIt/Clipper/`. The clip route runs on the main actor only for the final `NoteStore` call. Decoding, validation and downloads happen off the main actor.

1. **Decode and validate** (`ClipRequest.validated()`):
   - `url` must be http(s) with a host.
   - `title` is made one line: whitespace collapsed, at most 200 characters, cut with an ellipsis. An empty title becomes the page host.
   - `comment` at most 10,000 characters; `tags` at most 20.
   - `images` at most 50, each with exactly one of `url` or `data`. Inline `data` is at most 10 MB per image and 40 MB in total.
   - `markdown` over 1,000,000 characters is cut at the last blank line before the limit and marked `shortened`.
   - `markdown` is required for article, selection and page. Screenshot and image need one image.
2. **Idempotency:** `ClipService` remembers the last 50 `clientClipID`s for 10 minutes, in memory. A repeat returns the saved response and creates nothing. That covers a retry after a timeout whose first attempt did save.
3. **Images** (`ClipImageFetcher`):
   - Inline `data` images are checked and stored without any network use.
   - URL images are downloaded only when `downloadImages` is true:
     - `PinnedImageFetcher`, not `URLSession`: a thin wrapper over the shared `PinnedHTTPClient` (`Sources/NoteIt/Net/`, in the `NoteIt` app target), which the clipper owns and `plugins` also uses for its network requests. One `NWConnection` per request with no cookies, no cache and no credentials, a minimal HTTP/1.1 `GET` with a `Host` header;
     - `Referer` set to the page's origin, because many image hosts refuse requests without one;
     - 4 at a time, 8 s per image, 20 s for the whole clip. Images still pending at 20 s are cancelled and count as failed.
   - Only `http`/`https`, and only public addresses, so a page can't point NoteIt at its own API, other loopback services or anything else on the local network:
     - the URL check (`isAllowed`) rejects `localhost`, `*.localhost` and any IP literal that isn't public;
     - before each request the host is resolved once (`getaddrinfo`), and the image fails as `notAllowed` if it resolves to nothing or any address isn't public;
     - the connection goes to the first checked address itself, with no second lookup, so a DNS answer that changes between the check and the connect (DNS rebinding) can't redirect it. For `https`, TLS uses the original host as the server name and the system's normal certificate validation against it, so a certificate for another name fails;
     - redirects are followed by NoteIt itself, at most 3; every target goes through the same checks and the same pinned connection, and a rejected one, or a 4th, fails as `notAllowed`;
     - only a `200` response with an `image/*` `Content-Type` is kept; another status fails as `http(<code>)`, another type as `notAnImage`;
     - not public: `0.0.0.0/8`, `10.0.0.0/8`, `100.64.0.0/10`, `127.0.0.0/8`, `169.254.0.0/16`, `172.16.0.0/12`, `192.168.0.0/16`, `224.0.0.0/4` and above, `::`, `::1`, `fc00::/7`, `fe80::/10`, `ff00::/8`, and IPv4-mapped or IPv4-compatible IPv6 addresses (`::ffff:a.b.c.d`, `::a.b.c.d`) whose IPv4 part isn't public.
     Images on a private network (a NAS) are therefore not downloaded; they stay as links like any other failed image.
   - At most 10 MB per image, enforced while streaming, so a large response is cancelled early.
   - The saved type comes from the first bytes, not the `Content-Type` (which only has to be `image/*`): PNG, JPEG, GIF, WebP, HEIC, TIFF, BMP, or SVG (an XML start with an `<svg` root). Anything else fails as `notAnImage`.
   - Saved images stay in memory as bytes, named `clip-image-<n>.<ext>` in request order. Nothing is written to disk before the note is saved.
4. **Markdown rewrite** (`ClipMarkdownRewriter`), for each `![alt](noteit-image:<id>)`:
   - saved → `![alt](clip-image-<n>.<ext>)`;
   - not saved, with a URL → `[Image: <alt or file name>](<url>)`;
   - not saved, without a URL → removed.
5. **Convert the Markdown** (`ClipBodyConverter`), through `NoteItMarkdown` (`markdown-storage`), the only Markdown path for the Local API, MCP, plugins and the clipper (program §6). The old `MarkdownReader` is not used.
   - `MarkdownCodec.parse` reads the rewritten Markdown in the `portable` flavour, the one program §6 sets for web clipper input, and turns it into a `noteit-doc` body. A blank line is put in front first, so a page that starts with `---` is never read as front matter; any front matter the parser still reports is ignored.
   - Images come in through `MarkdownImportOptions.resolveImage: (URL) async -> Data?` (program §6). The clipper's closure answers from the images step 3 already holds: a saved `clip-image-<n>.<ext>` returns its bytes, and every other URL returns nil, so the image is dropped. It never touches the network or the file system, so API input never reads files and downloads keep the limits of step 3.
   - `DocConverter.importDocument` (`NoteItDocAppKit`) turns the body into editor text, so clips get the same block styles, tables, checklists and code blocks as every other Markdown that comes into NoteIt.
6. **Build the body** (`ClipNoteBuilder.build`):
   - The builder assembles the layout from the table in "The note", around the converted content. The title is an `EditorStyle.paragraph(_, kind: .title)`, the comment body paragraphs.
   - The source line comes from `CaptureFormatter.sourceLine(linkingTo:label:appName:)`, which `capture-plus` extracts for this reuse. The clipper passes the page's URL, the page title as `label` and the browser name as `appName` (nil leaves out " in …"), and doesn't change `CaptureFormatter`.
   - In Selection mode, body paragraphs are restyled as `.quote`, matching capture. Lists, tables and code keep their styles.
   - The tag line is built from tags normalised by `ClipNoteBuilder.normalizedTag`: a leading `#` is dropped, spaces become `-`, and characters `NoteStore.parseTags` doesn't accept are removed, so every tag survives as a real tag. Empty results are dropped. Once `organise` adds nested tags, `/` is kept.
   - A shortened clip ends with the paragraph **Clip shortened: the page was longer than NoteIt saves in one note.**
7. **Save:**
   - The note is created through the store API, `NoteStore.createNote(in:initial:)`, with the request's notebook. The store writes the body through `NoteBodyStorage`, so the clipper never touches body files. A missing notebook gives `not_found`, and a shared notebook the user can only read gives `read_only`; an omitted one uses `defaultNotebookIDForNewNotes`.
   - The note isn't selected and the window isn't brought forward. The browser keeps focus.
   - NoteIt shows its capture notice (`CaptureToast`): **Clipped to Inbox**, which opens the note when clicked, unless NoteIt is the frontmost app.
8. **Respond:** `201` with the counts. The library is saved by the store's normal debounce. Sync then picks up the note like any other.

**Body format:** this goes only through `NoteItMarkdown`, `DocConverter` and the `NoteStore` API. Whether the library stores RTFD, `noteit-doc` or Markdown files is decided by the store's `NoteBodyStorage`, and the clipper needs no change for any of them.

**Large clips:** building a 1,000,000-character note takes about as long as importing a Markdown file of that size. The route keeps a single clip in flight. A second request waits rather than running in parallel.

### 7. Safari packaging

SwiftPM can't build an app extension bundle (`.appex`). As program §1 sets out, the Safari extension is built by a script with `xcrun swiftc`, and `Package.swift` lists its source only so it type-checks.

- **Source:** `Sources/NoteItClipperExtension/`, one file, `SafariWebExtensionHandler.swift`, an `NSObject, NSExtensionRequestHandling` class. It answers every native message with `{"error": "unsupported"}`, because the clipper uses the Local API, never native messaging.
- **Type-checking:** `Package.swift` has a `NoteItClipperExtension` target over that folder, compiled with `-application-extension`. Nothing depends on it, it has no product, and its build output is never packaged.
- **Building:** `scripts/build_safari_extension.sh` is the one way the appex binary is built. It compiles the same file with `xcrun swiftc -application-extension -module-name NoteItClipperExtension`, linked with `-e _NSExtensionMain -application_extension`, for each architecture the app is built for (`lipo` for universal builds), with macOS 14 as the deployment target.
- **Bundle:** `NoteIt.app/Contents/PlugIns/NoteItClipper.appex`.
  - `Contents/MacOS/NoteItClipperExtension`.
  - `Contents/Info.plist`:
    - `CFBundleIdentifier` `io.github.rutbergphilip.noteit.clipper` (`AppIdentity.bundleID + ".clipper"`);
    - `CFBundlePackageType` `XPC!`;
    - `CFBundleDisplayName` `NoteIt Clipper`;
    - `LSMinimumSystemVersion` `14.0`;
    - versions equal to the app's;
    - `NSExtension`: `NSExtensionPointIdentifier` `com.apple.Safari.web-extension`, `NSExtensionPrincipalClass` `NoteItClipperExtension.SafariWebExtensionHandler`.
  - `Contents/Resources/` holds a copy of `clipper/dist/safari/`.
- **Signing:**
  - `automation` owns the embeds table in `scripts/build_app.sh` (program §10, foundations task 5.5). The clipper adds one row, with the program's columns (path in bundle, source, build step, entitlements):

    | Column | Value |
    |---|---|
    | path in bundle | `Contents/PlugIns/NoteItClipper.appex` |
    | source | `NoteItClipper.appex`, assembled by the build step |
    | build step | `scripts/build_safari_extension.sh` |
    | entitlements file | `Resources/NoteItClipperExtension.entitlements` (`com.apple.security.app-sandbox` = true; app extensions must be sandboxed) |

  - Signing is inside-out, without `--deep`: the table signs the appex, then the main app last. The app isn't a row.
  - It uses the same identity, hardened runtime and timestamp as the app.
  - Ad-hoc builds sign it ad-hoc. Safari then needs **Develop › Allow Unsigned Extensions**, which `docs/development.md` explains.
  - Release builds are Developer ID signed and notarized with the app, which Safari accepts outside the Mac App Store.
- **Build switches:**
  - The script builds `clipper/dist/safari` with pnpm when it's missing.
  - It skips the extension with a warning when pnpm or Node is missing, or when `NOTEIT_SKIP_CLIPPER=1`. The embeds table then skips the row, whose source wasn't built, with a log line.
  - It fails instead when `NOTEIT_REQUIRE_CLIPPER=1`. The release workflow sets that only after the Safari spike (plan T14) has passed: a `swiftc`-built, signed appex that Safari lists and that clips a page. Until then `release.yml` doesn't set it.
- **Updates:** Sparkle replaces the whole app, so the Safari clipper updates with NoteIt. Its manifest `version` is the clipper's own version, which can differ from the app's.
- **Status in Settings** (`SafariClipperStatus`):
  - `SFSafariExtensionManager.getStateOfSafariExtension(withIdentifier:)` gives On / Off in Safari. An error, or no extension in the bundle, shows Not available.
  - `SFSafariApplication.showPreferencesForExtension(withIdentifier:)` backs **Open Safari Extensions…**.
  - SafariServices is linked by the main target.

### 8. Distribution and releases

- **Chrome Web Store:** one listing for Chrome, Edge and Brave. Edge users accept Edge's "Allow extensions from other stores" prompt. **Firefox:** a listed AMO add-on. **Safari:** bundled only. No Mac App Store build.
- **Versions:** the clipper has its own semver, starting at 0.1.0, in `clipper/package.json` and `clipper/CHANGELOG.md`. Tags are `clipper-vX.Y.Z`, separate from the app's `vX.Y.Z`. The app tags keep driving `release.yml` unchanged, except for the Safari build steps.
- **Compatibility:** the extension checks for `"web-clipper"` in the `capabilities` field of `GET /v1/ping`, never the app's version. A newer clipper with an older app says **Update NoteIt**. A newer app always keeps `/v1/clips` request version 1 working, and changes are additive.
- **`clipper-release.yml`**, on a `clipper-v*.*.*` tag or a manual `dry_run`:
  1. Check that the tag matches `package.json`; install, typecheck, test, build all targets; `web-ext lint` the Firefox build.
  2. Zip `noteit-clipper-chrome-X.Y.Z.zip`, `noteit-clipper-firefox-X.Y.Z.zip` and `noteit-clipper-source-X.Y.Z.zip`. AMO requires the source for bundled code; the source zip has `clipper/` without `node_modules`, plus a `BUILD.md`.
  3. Create the GitHub release **NoteIt Clipper X.Y.Z** with the zips and the changelog section.
  4. Upload to the Chrome Web Store through its API and submit for review. Secrets: `CWS_CLIENT_ID`, `CWS_CLIENT_SECRET`, `CWS_REFRESH_TOKEN`, `CWS_EXTENSION_ID`.
  5. Submit to AMO with `web-ext sign --channel=listed --upload-source-code`. Secrets: `AMO_JWT_ISSUER`, `AMO_JWT_SECRET`.
  6. The store steps skip with a notice when their secrets are missing. A dry run never uploads.
- **`release.yml`** gains Node 24 and pnpm setup and `pnpm --dir clipper build:safari` before **Build NoteIt.app**. It sets `NOTEIT_REQUIRE_CLIPPER=1` only once the Safari spike has passed (§7). Notarization already covers everything in the app bundle. `growth` also edits `release.yml` (the Pages trigger, and later dropping the Homebrew job); the clipper's changes land first and `growth` rebases its edits on top.
- **`ci.yml`** gains a `clipper` job on `ubuntu-latest`, the browser-extension CI job that program §1 allows: pnpm install, typecheck, test, build all three targets, `web-ext lint`. Extension tests run only there; the app-side `Clip*` tests stay in `swift test`. The macOS job builds `clipper/dist/safari`, then runs `NOTEIT_INSTALL_DIR="$RUNNER_TEMP/apps" ./scripts/build_app.sh` and checks that the appex exists and passes `codesign --verify --deep --strict`.
- **Store listing text** lives in `clipper/store/` (description, screenshots' captions, permission justifications), so it's reviewed like code.

### 9. Privacy

- No analytics, crash reporting, remote configuration or third-party requests in the extension. Its only network destination is `http://127.0.0.1:<port>`.
- Page content is read only after a user action on that tab (`activeTab`), and only the mode you chose. It goes to NoteIt on the same Mac and nowhere else.
- NoteIt's image downloads go to the image hosts of the page you clipped, without cookies, and only when **Save images in the note** is on. This call is listed in the network inventory owned by `sync-security`.
- The token sits in the browser profile's extension storage, which other extensions and web pages can't read. It's scoped `read` + `write`, never `admin`. It works only against 127.0.0.1, and can be revoked in NoteIt.
- `clipper/PRIVACY.md` is the privacy policy linked from both store listings. The store privacy forms declare "website content: used only to create the note on the user's Mac, not sold, not transferred."

## Dependencies

- **automation (01).** Required for everything. Its spec freezes the names used here (§6.10), and program §10 sets the registration rules. The clipper changes none of `automation`'s code; it only registers its route, advertises its capability and adds rows to tables `automation` owns. Uses from 01:
  1. The Local API on 127.0.0.1, default port 47600 with fallback up to 47609, and the Integrations tab (raw value `integrations`) with **Connected apps** and **Revoke**.
  2. `GET /v1/ping`, `POST /v1/pair/start`, `POST /v1/pair/complete`, `DELETE /v1/me`, `GET /v1/notebooks` (with `defaultNotebookID`), `GET /v1/tags` and `POST /v1/notes/{id}/open`, as frozen in its §6.10.
  3. Pairing as in its §6.5: 6-digit code, 120 s, 5 wrong codes, one pairing at a time, extension scopes capped at `write`, and the origin shown in the window.
  4. Browser rules as in its §6.6: CORS preflight answered for `chrome-extension`, `moz-extension` and `safari-web-extension` origins; `http(s)` and `null` origins rejected.
  5. `LocalAPIRouteRegistry.register` (§6.11; built in foundations task 5.2), used for `POST /v1/clips` with route id `web-clipper.clips`, 60 MB, scope `write`, bucket `write`; `addCapability("web-clipper")`, shown in `ping`'s `capabilities` field; and `APIErrorCode` codes `bad_request`, `read_only`, `not_found`, `too_large` and `not_ready` (`503`, message "Your library is still opening. Try again in a moment.").
  6. Safari extension tokens bound by the origin scheme plus the extension's bundle identifier, sent in the `X-NoteIt-Extension-Bundle` header and allowed in CORS preflights, which `automation`'s spec states (program §10). Chrome and Firefox tokens stay bound to the full origin.
  7. `noteit://settings?tab=integrations` (§3), used by **Open NoteIt**.
  8. The embeds table in `scripts/build_app.sh` (foundations task 5.5), where the clipper adds the `PlugIns/NoteItClipper.appex` row.
- **markdown-storage (02).** Required. `NoteItMarkdown`'s `MarkdownCodec.parse`, in the `portable` flavour with `MarkdownImportOptions.resolveImage`, turns clip Markdown into a `noteit-doc` body (program §6), and `NoteBodyStorage` writes the note's body. `DocConverter` comes from `NoteItDocAppKit` (foundations).
- **capture-plus (05).** Required for the source line: it extracts `CaptureFormatter.sourceLine(linkingTo:label:appName:)`, and the clipper calls it. Both are in wave 2; capture-plus's extraction ships before the clipper task that calls it (program §2). Optional beyond that: screenshots and saved images become searchable through its image text recognition.
- **organise (04).** Optional. Nested notebooks (`parentID`) in the picker, and nested tags (`/`) kept by `normalizedTag`. The clipper works without them.
- **sync-security (08).** Lists NoteIt's image downloads in the network inventory.
- **web-app** (`noteit-doc`). No direct dependency. Clips go through `NoteStore`, so they work with any body format.
- **plugins (10).** Wave 3. Sends every `net.fetch` through the clipper's `PinnedHTTPClient` with its own policy (its methods, body and response limits, and loopback only for a host the user granted as `localhost` or `127.0.0.1`). The clipper's rules (GET only, no loopback, 3 redirects) stay in `PinnedImageFetcher`, not in the shared client.
- **growth (13).** Links to the store listings from the website. Its `release.yml` edits rebase on top of the clipper's.

## Non-goals

- Full-page (scrolling) screenshots. Visible area only in v1, because stitching needs `<all_urls>` or `debugger`.
- Clipping on iPhone or iPad Safari. `mobile` covers capture there with its share extension.
- Clipping into the self-hosted web app, and clipping on Windows or Linux. The clipper needs NoteIt for Mac.
- An offline queue in the browser. Clips that can't be delivered stay in the open popup only.
- Appending to an existing note, highlights or annotations on the page, PDF text extraction, and saving page archives (HTML, WARC).
- Duplicate detection ("you clipped this page before").
- Native messaging to the Safari app extension, or any transport other than the Local API.
- Edge Add-ons, Opera Add-ons and Mac App Store listings.

## Open questions

| Question | Default chosen |
|---|---|
| Download images in NoteIt or keep remote URLs? | Download in NoteIt, without cookies, with limits. Failures and the off switch keep a link. The extension then needs no host permissions for image hosts, and notes work offline and sync whole. |
| Who converts HTML: the extension or NoteIt? | The extension, to Markdown with Turndown. NoteIt reads it with `NoteItMarkdown`, like all Markdown that comes in through the Local API. `NSAttributedString`'s HTML import needs the main thread and WebKit, and would run untrusted HTML in the app. |
| Should Safari skip pairing, since it ships with the app? | No. The same pairing for every browser, so there's one security model and one code path. |
| Which port does the clipper use? | `automation`'s range: probe 47600 to 47609 with `GET /v1/ping`, remember the port that answered. A fixed port can be typed in Advanced options. |
| Host permission for `http://127.0.0.1/*`? | None. `automation` answers CORS for extension origins, so the four permissions are enough. If a browser blocks the request in testing (plan T12), add it as an `optional_host_permissions` entry requested from the **Connect** click. |
| Keep the token in `storage.local` or `storage.session`? | `storage.local`, so pairing survives restarts. The token is loopback-only and revocable. |
| Minimum browsers? | Chrome 120, Firefox 128 (ESR), Safari 17. |
| Edge Add-ons listing? | Not in v1. Edge installs from the Chrome Web Store. Reconsider after launch. |
| Default shortcuts? | Popup ⌃⇧S, quick clip ⌃⇧A, declared as `MacCtrl+Shift+S` and `MacCtrl+Shift+A` (`MacCtrl` is Control on a Mac; `Ctrl` would be ⌘); Alt+Shift+S and Alt+Shift+A elsewhere. Users can change both in the browser. |
| Can the Safari appex be built without Xcode? | Planned as `xcrun swiftc` from `scripts/build_safari_extension.sh` (§7). The plan's T14 spike proves it; until it passes, releases don't require the clipper. |
| Add a "Clipped" date line? | No. The note's created date already records it. |
| Should NoteIt show a notice for each clip? | Yes, the capture notice, but only when NoteIt isn't frontmost. The browser shows its own confirmation too, so this mainly tells you the note arrived. |
