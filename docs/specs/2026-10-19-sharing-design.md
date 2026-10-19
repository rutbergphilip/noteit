# Sharing — Design

Status: proposed · Date: 2026-10-19 · Companion plan: docs/plans/2026-10-19-sharing.md

## Goal

Let people share notes without NoteIt running a server and without giving up end-to-end encryption:

1. **Share links.** Send one note to anyone as a link. The note is encrypted, uploaded to storage the user owns, and the key travels only in the link.
2. **Published notebooks.** Turn a notebook into a plain static website, hosted on a folder, a bucket or GitHub Pages.
3. **Shared notebooks.** Keep a notebook in sync between several people, encrypted so that the storage never sees the contents, with read and write roles and real removal.

All three are opt-in and send data only to destinations the user configures. This is the most complex sub-project in the program, so the plan splits it into five milestones that each ship on their own.

## What the user gets

### Destinations (Settings › Sharing)

- A new **Sharing** tab in Settings, the sixth tab, after Your Data and before Smart Features, with the `person.2` symbol. `noteit://settings?tab=sharing` opens it.
- **Destinations** is a list of places NoteIt may publish to. **Add Destination…** offers:
  - **Folder** — any folder a web server serves, such as a NAS web root or a mounted hosting share.
  - **Amazon S3, Cloudflare R2, Backblaze B2, MinIO / NAS, Custom S3** — the same presets as Sync, for a bucket that allows public reads.
  - **GitHub Pages** (from milestone 3) — a repository and branch, with a personal access token.
- Each destination has a name, the provider fields, and a **Public address**: the web address where the destination's files appear, for example `https://notes.example.com` or `https://share.example.r2.dev`. GitHub Pages fills it in as `https://<owner>.github.io/<repo>/`, and it can be changed for a custom domain.
- **Test** uploads a small page, fetches it from the public address without credentials, checks that it comes back as a web page, and deletes it. Results read:
  - **Ready to share.**
  - **Uploaded, but the page isn't public at <address>.** with a hint to allow public reads on the bucket or the folder.
  - **The page is public, but your server sends it as a download.** (wrong content type, folder destinations only).
  - The same storage errors Sync shows for credentials and connections.
- A destination with Sync's exact bucket and prefix, or Sync's folder, is refused: **Use a different bucket, prefix or folder from the one you sync to. Shared files must be public, and your library must not be.**

### Share a note with a link (milestone 1)

- **File › Share ▸ Create Share Link…** (⌥⌘L, changeable in Settings › Shortcuts), the toolbar Share button's menu, the note list's context menu, and the command palette command **Create Share Link…** open the **Share Link** sheet for the selected note.
- Locked notes can't be shared. For a locked note the command is disabled with the tooltip **Locked notes can't be shared. Remove the lock to share it.**
- The sheet has:
  - **Destination** — a pop-up of destinations that support links (Folder and S3 presets; GitHub Pages is not offered, see §2.6). With none configured, the sheet shows **Add a destination in Settings › Sharing to create links.** and a button that opens it.
  - **Expires** — Never, 1 day, **7 days** (default), 30 days, or On date…
  - **Require a passphrase** — off by default. When on, a passphrase field (8 characters or more) with the hint "Send the passphrase separately from the link."
  - **Keep the shared copy up to date** — off by default. When on, edits to the note are uploaded about 30 seconds after you stop typing.
  - **Create Link**. While uploading the button shows a spinner; then the sheet shows the link with **Copy Link** (selected and focused) and **Done**. The link is also copied to the clipboard and a notice says **Link copied**.
- A note that has a link shows a small link badge in the note list and the editor header. Clicking it opens the note's **Share Link** sheet in its management state: the link, **Copy Link**, **Update Now**, the expiry (changeable), **Keep the shared copy up to date**, and **Delete Link…**.
- **Delete Link…** confirms with **Delete the shared copy? People who have the link won't be able to open it anymore.** and removes the uploaded file.
- Settings › Sharing › **Shared Links** lists every link created on this Mac: note title, destination, created, expires, with Copy Link, Update Now and Delete. Expired links are deleted automatically (§2.5) and disappear from the list. A footnote says **Links created on your other Macs are listed there.**
- The recipient opens the link in any modern browser, including phones. The page shows the note with its formatting and images, a **Copy Text** button, the expiry date if there is one, and a footer "Shared from NoteIt". With a passphrase, it first asks **This note is protected. Enter the passphrase you were given.**

### Publish a notebook as a website (milestones 2 and 3)

- **File › Share ▸ Publish…** (for the selected notebook), **Publish Notebook…** in the notebook's context menu in the sidebar, and the palette open the **Publish** sheet:
  - **Destination** (any destination, including GitHub Pages from milestone 3) and **Path** inside it, default `sites/<notebook-slug>/` for Folder and S3, and the repository root for GitHub Pages.
  - **Site title** (default: the notebook name), **Description**, **Author**.
  - **Appearance**: Light, Dark or **Automatic** (default), and an **Accent** color (default: the notebook's color).
  - **Leave out notes tagged** — default `draft`.
  - **Include an RSS feed** — on by default; needs the public address.
  - **Republish automatically when notes change** — off by default.
  - A warning line that does not go away: **Anyone with the address can read every published note. Published notes aren't encrypted.**
  - **Preview** opens the site from a local folder in the default browser. **Publish** uploads it and shows the address with **Copy Address** and **Open**.
- Locked notes are never published. They are left out of the site, and locking a note in a published notebook removes its page (§3.1).
- After publishing, the notebook's row in the sidebar shows a globe badge. Its context menu gains **Republish Now**, **Copy Site Address** and **Stop Publishing…** (which deletes the published files after a confirmation).
- Settings › Sharing › **Published Sites** lists sites with their address, last published time and the same actions.

### Share a notebook with people (milestones 4 and 5)

- **File › Share ▸ Share Notebook…** (for the selected notebook), **Share Notebook…** in the notebook's context menu and the palette open the **Share Notebook** sheet.
- The first time, it explains in two sentences: **Everyone you invite gets their own copy that stays in sync, encrypted so that the storage can't read it. Shared notebooks need storage that all of you can reach.** It then asks for:
  - **Your name**, as others will see it (default: the macOS user's full name).
  - **Where to keep it**: an S3-compatible bucket, a folder all of you can reach (such as a NAS share), or, from milestone 5, your self-hosted NoteIt Server.
- **Invite…** asks for the role (**Can edit** or **Can read**) and, for S3 storage, the storage keys this person will use (a checkbox **Give them my storage keys** is off by default, with the warning **Anyone with your keys can also delete files in this bucket. Create separate keys at your provider if you can.**). It then shows:
  - an **invitation link** with **Copy Link**, and
  - a **code** in the form `XXXX-XXXX-XXXX` with **Copy Code**, and the line **Send the code another way than the link, for example in a call or a different app. Each invitation works once and expires in 7 days.**
- The person invited clicks the link (or chooses **File › Share ▸ Join Shared Notebook…** and pastes it), types the code and their name, and the notebook appears in their sidebar after the first sync, with a people badge on its row.
- The sheet then lists **People**: name, role, and safety code (`1234 5678 9012`), plus pending invitations. The owner can change a role, **Remove…** a person, and **Cancel Invitation**. Everyone can compare safety codes to make sure they're talking to the right person.
- Read-only members see the notebook's notes as read-only with a banner **You can read this notebook. Ask <owner> for edit access.**; formatting tools are disabled, and **Duplicate to My Notes** is offered.
- Members can **Leave Shared Notebook…**, with **Keep a copy in My Notes** on by default. The owner can **Stop Sharing…**, which turns it back into a private notebook for the owner and removes it for everyone else.
- Conflicts work like Sync: both versions are kept, the copy is titled "Title (conflict — <member name> on MacBook Air, 19 Oct 2026 10:12)".
- Notes in shared notebooks can't be locked. **Lock Note** is disabled for them with **Notes in shared notebooks can't be locked.**, and moving a locked note into a shared notebook is refused with the same message. A notebook that contains locked notes can't be shared: **Share Notebook…** is disabled with the tooltip **Notebooks with locked notes can't be shared. Remove the lock from those notes first.**
- Until shared notebooks have been used by real groups for one release, the Share Notebook sheet labels them **Shared notebooks (preview)**.

## Design

### 1. Destinations

- `PublishDestination` (app target) is a non-secret record stored as a JSON array in UserDefaults under `publishDestinations`:
  - `id: UUID`, `name: String`, `kind`, `publicBaseURL: URL?`.
  - `kind` is one of `folder(bookmark: Data?, path: String)`, `s3(provider: SyncProvider, config: S3Config)` and `githubPages(GitHubPagesConfig)`. `S3Config` and `SyncProvider` are the existing sync types; the S3 `prefix` is the destination's root inside the bucket.
- Secrets live in the keychain under the new service `<bundleID>.sharing` (`AppIdentity.bundleID + ".sharing"`), accounts `dest-<UUID>-access-key`, `dest-<UUID>-secret` and `dest-<UUID>-token`. They are never written to UserDefaults or logs.
- Backends are the existing `FolderBackend` and `S3Backend`. Public files need a content type and cache headers, which `StorageBackend.put` doesn't send, so `NoteItSync` gains a small `PublicObjectWriter` protocol (`putPublic(_:data:contentType:cacheControl:)`), implemented by `S3Backend` (sends `Content-Type` and `Cache-Control`, unconditional PUT) and `FolderBackend` (atomic write, headers ignored).
- Plain `http` endpoints are allowed only for the MinIO / NAS and Custom S3 presets, as in Sync. The public address must be `https`, except for `http://` addresses on `.local` hosts or private IP ranges, which get a warning **Links to this address only work on your network.**
- The sync-store guard compares the destination with `SyncConfiguration.storeKey` inputs (provider, endpoint, bucket, prefix, or the standardized folder path), and also refuses a destination nested inside the sync folder or prefix.
- **Test** writes `s/.noteit-test-<uuid>.html` (object style) or `s/.noteit-test-<uuid>/index.html` (folder style), GETs it from the public address with an ephemeral `URLSession` (no cookies, no cache), checks status 200, a `text/html` content type and a marker string, then deletes it.

### 2. Share links

#### 2.1 What gets uploaded

- One self-contained HTML file per link. It holds a small viewer (inline script and style, no third-party code, no network requests) and the encrypted note as a base64 data block: `<script type="application/noteit-share" id="noteit-share">…</script>`. A data block isn't executed.
- Keys on the destination:
  - S3 destinations, **object style**: `s/<id>` with `Content-Type: text/html; charset=utf-8`. Link: `<public address>/s/<id>#k=<key>`.
  - Folder destinations, **folder style**: `s/<id>/index.html`, because most web servers don't serve extensionless files as HTML. Link: `<public address>/s/<id>/#k=<key>`.
- `Cache-Control: no-cache` so that updates and deletions take effect at the next load. A CDN in front of the destination may still cache; the Settings help says so.
- One file instead of a viewer plus a separate ciphertext object means no CORS, no second request, revocation is one delete, and a saved copy of the page still works offline.
- The plain page reveals nothing about the note: the `<title>` is "Shared note" until it's decrypted, and the page has `<meta name="robots" content="noindex, nofollow">` and `<meta name="referrer" content="no-referrer">`.

#### 2.2 Identifiers and keys

- `id`: 16 random bytes, RFC 4648 base32, lowercase, no padding (26 characters). It is unguessable, so listing the bucket is the only way to find links; the help text says to keep public listing off.
- `key`: 32 random bytes, base64url without padding (43 characters), only in the URL fragment. Browsers never send the fragment to the server, so the destination's logs never contain it.

#### 2.3 Encryption format (`noteit-share` v1)

Plaintext payload, UTF-8 JSON (`SharePayload`):

```json
{ "v": 1, "title": "Trip plan", "html": "<!DOCTYPE html>…", "text": "Trip plan\n…",
  "createdAt": "2026-10-19T09:00:00Z", "expiresAt": "2026-10-26T09:00:00Z" }
```

- `html` is the exact output of the existing `HTMLWriter.write(_:title:code:)`: a full page with images embedded as data URLs and the code stylesheet. `text` is `NoteExporter.plainText(_:)`, used by Copy Text. `expiresAt` is omitted for links that never expire.
- Sealed bytes:

```
"NTS1" (4) | flags (1, bit 0 = passphrase) | [salt (16) | iterations (u32, big-endian)] | nonce (12) | ciphertext | tag (16)
```

- Content key:
  - Without a passphrase: `HKDF-SHA256(ikm: key, salt: empty, info: "noteit-share-v1 content", 32 bytes)`.
  - With a passphrase: `p = PBKDF2-HMAC-SHA256(NFC(passphrase), salt, iterations = 210 000, 32 bytes)`, then `HKDF-SHA256(ikm: key ‖ p, salt: salt, info: "noteit-share-v1 content", 32 bytes)`. Both the link and the passphrase are needed. Passphrases are NFC-normalized here because this is a new format; Sync keeps its raw bytes.
- AES-256-GCM, random nonce, AAD = UTF-8 `"noteit-share-v1:" + id`, so a file can't be moved to another id.
- Limit: sealed size up to **50 MB**. Larger notes are refused with **“<title>” is too large to share as a link (<size>). Links can be up to 50 MB, including images.**
- All of this lives in `NoteItSync/Sharing/ShareLinkCodec.swift` (Foundation and CryptoKit only), so the iPhone app from `mobile` can reuse it.

#### 2.4 The viewer

- About 8 KB of plain JavaScript using WebCrypto (`crypto.subtle`: `importKey`, `deriveBits` for PBKDF2 and HKDF, `decrypt` for AES-GCM).
- Content Security Policy in a `<meta>` tag: `default-src 'none'; script-src 'sha256-<hash of the viewer script>'; style-src 'unsafe-inline'; img-src data: blob:; frame-src about:; base-uri 'none'; form-action 'none'`. The hash is computed when the page is generated, so it always matches the script.
- The decrypted `html` is shown in an `<iframe sandbox="allow-popups allow-popups-to-escape-sandbox">` through `srcdoc`, with `<base target="_blank">` added. Scripts can't run inside the note even if one were smuggled in, and links open in a new tab. The iframe inherits the page's CSP.
- After decrypting, the viewer sets `document.title` to the note title and replaces the URL fragment with `history.replaceState` only if the user chose **Hide the key from the address bar** — off by default, because people expect to copy the address again.
- Messages, all plain:
  - No fragment: **This link is incomplete. Ask for the whole link, including the part after “#”.**
  - Expired (`expiresAt` in the past): **This shared note has expired.** The note isn't shown.
  - Wrong passphrase: **That passphrase didn't work.** Up to unlimited retries; PBKDF2 makes each one slow.
  - Bad key or damaged file: **This note couldn't be opened. The link may be incomplete or damaged.**
  - No WebCrypto (very old browsers, or `http` pages outside localhost): **Your browser can't open encrypted notes on this page. Try a current browser, or ask for an https link.**
- Light and dark appearance follow the reader's system. The layout is one column, readable on a phone.

#### 2.5 Expiry, update and revoke

- A static file can't delete itself, so expiry has two layers:
  1. The viewer refuses to show a payload past `expiresAt`. This is authenticated (inside the ciphertext), so nobody can extend it without the key.
  2. NoteIt deletes expired links: at launch and every hour while running, `ShareSweeper` deletes the files of links whose `expiresAt` has passed. Failures retry at the next run, and the list shows **Waiting to delete** for them.
- The Settings help explains the gap honestly: **If this Mac is off when a link expires, the file is deleted the next time NoteIt runs. Someone who saved the page before it expired can still open their copy.** For a hard cut-off it suggests a lifecycle rule on the `s/` prefix at the provider; NoteIt doesn't create it.
- **Update** re-renders the note and uploads to the same id with the same key, so the link doesn't change. With **Keep the shared copy up to date**, `ShareLinkController` watches the note's revision and uploads 30 seconds after the last edit (at most once a minute per link), only while NoteIt runs.
- **Delete** removes the file and the registry entry. A note moved to Recently Deleted keeps its links; deleting it for good deletes its links first, after the same confirmation explains it.
- Changing the expiry or turning the passphrase on or off re-uploads with a new id and key (so old links stop working), and says so: **This creates a new link. The old link stops working.**
- A protected link whose passphrase isn't kept (**Keep the shared copy up to date** off) needs the passphrase again for **Update Now** (in the sheet and in Settings) and for an expiry change. NoteIt asks **Enter the passphrase for this link.** with **Cancel** and **Continue**, and checks it against the link's key check (§2.7) before rendering or uploading anything. A wrong passphrase shows **That passphrase doesn't match this link.** and changes nothing; **Cancel** changes nothing (the expiry stays as it was). The passphrase is used for that one change and isn't stored. A changed expiry keeps the same passphrase on the new link.

#### 2.6 Where links can and can't go

- GitHub Pages is not offered for links: every published file stays in the repository's history, so deleting a link wouldn't remove it. The destination row says **Can publish sites only.**
- Locked notes (from `sync-security`, program §8) are never shared. `ShareLinkController` checks `NoteMeta.isLocked` and refuses them, and the menu item is disabled with the tooltip from "What the user gets". When a note that has links is locked, NoteIt deletes its links and shows **The share links for “<title>” were deleted because the note is locked.**

#### 2.7 Local registry

- `shares.json` in the data folder (`NoteStore.rootURL`, never a Markdown library's content folder, program §7), written atomically:
  `{ id, noteID, destinationID, layout, createdAt, updatedAt, expiresAt?, hasPassphrase, keepUpdated, uploadedRevision?, pendingDeletion }`.
- The link key is in the keychain (`<bundleID>.sharing`, account `share-<id>-key`), and the passphrase too when **Keep the shared copy up to date** is on (`share-<id>-passphrase`), since updates need it. Every protected link also has a key check (`share-<id>-check`): an `NTS1` sealing of empty plaintext under the link key and passphrase with AAD `"noteit-share-check-v1:" + id`, used to verify a re-entered passphrase (§2.5) without the network.
- The registry is per Mac and isn't synced: each Mac lists and manages the links it created. A synced, encrypted registry in the personal store could follow later, next to the identity backup.

#### 2.8 Errors and privacy

- Upload errors show in the sheet with the storage error text and a **Try Again** button. Nothing is recorded in the registry until an upload succeeds.
- A destination deleted in Settings while it still has links asks **Delete its <n> links first?** with **Delete Links and Destination** or **Keep Links** (the links stay listed, but can't be updated or deleted until the destination is added back).
- Network calls: PUT and DELETE to the destination, and one unauthenticated GET for Test. They are added to the network inventory owned by `sync-security`.

### 3. Published sites

#### 3.1 What gets published

- Notes of the notebook that aren't in Recently Deleted, aren't conflict copies (`conflictSource == nil`), aren't locked (`NoteMeta.isLocked`), and aren't tagged with the exclusion tag (default `draft`, compared case-insensitively against `NoteMeta.tags`). With nested notebooks from `organise`, sub-notebooks are included as sections; a sub-notebook's own Publish setting is independent.
- Locked notes are never published. When a note in a published notebook is locked, `SiteController` republishes that site right away, whether or not **Republish automatically** is on, so the note's page and index entry are removed.
- Bodies are read through `NoteStore.body(for:)`, never from files, so this works with the RTFD library and the Markdown library from `markdown-storage`. Publishing never changes note text.

#### 3.2 Site layout

```
index.html                 site title, description, notes newest first (pinned first), sections per sub-notebook
notes/<slug>.html          one page per note
assets/<sha256-16>.<ext>   images and files, deduplicated by content
style.css                  the theme, with the chosen appearance and accent
feed.xml                   RSS 2.0, newest 20 notes (only with a public address)
404.html                   simple not-found page
.noteit-site.json          site manifest: generator version and path → SHA-256 of every file
```

- Pages are rendered with `HTMLWriter`, extended (§3.4) to write an article fragment that references images at `../assets/…` instead of data URLs, and to rewrite links.
- Each note page shows the title, the last edited date, the body, a **Linked from** list built from `linking`'s link index, and links to the index and to the previous and next note.
- `index.html` lists each note with title, date and the first two preview lines (`NoteMeta.preview`).
- No JavaScript anywhere on the site. Pages include `<meta name="generator" content="NoteIt">` and no analytics.

#### 3.3 Slugs and stable addresses

- `Slug.make(title)`: fold to ASCII, lowercase, runs of other characters become `-`, trimmed, at most 60 characters, `untitled` when empty; a numeric suffix (`-2`, `-3`) when taken.
- The slug of a note is remembered in the local site state and kept while the title is unchanged. When a note is renamed, its new page is written at the new slug and the old slug gets a small redirect page (`<meta http-equiv="refresh">` plus a link), so shared addresses keep working. Redirects are kept for 90 days.

#### 3.4 Links between notes

- Links between notes are stored as `noteit://note/<UUID>`, optionally with `?heading=<text>` (program §3). The site parses them with `NoteItCore.NoteLink`; it doesn't define its own link format or routing.
- A `noteit://note/<UUID>` link becomes a relative link to that note's page when the target is published in this site (a `?heading=` part is dropped, so the link opens the top of the page), and plain text otherwise. Links to notes that don't exist yet (`noteit://note?title=`) and every other `noteit://` link, such as `noteit://open?id=` actions, become plain text. Nothing about unpublished notes leaks, not even their titles.
- `HTMLWriter` gains `HTMLWriter.Options`: `attachments` (`.inline` as today, or `.external(resolver)`), `linkRewriter: ((URL) -> URL?)?` and `fragmentOnly: Bool`. Defaults keep today's output byte-for-byte, so export and share links don't change.

#### 3.5 RSS

- RSS 2.0 at `feed.xml` with channel title, link, description, `lastBuildDate`, and 20 items (title, absolute link, `guid` = the note UUID with `isPermaLink="false"`, `pubDate` = `updatedAt`, `description` = the page article as escaped HTML with absolute asset URLs). `index.html` links to it with `<link rel="alternate" type="application/rss+xml">`.
- Without a public address RSS is turned off and the toggle says **Needs the destination's public address.**

#### 3.6 Uploading only what changed

- The builder produces every file in memory, one note at a time. `SiteDiff.plan(files:previous:)` compares SHA-256 values with the previous manifest and returns uploads and deletions. The new manifest is uploaded last, so an interrupted publish is retried in full on the next run.
- The previous manifest comes from the local site state (`sites/<siteID>.json` in the data folder, `NoteStore.rootURL`). If that's missing, NoteIt downloads `.noteit-site.json` from the destination; if that's missing too, it uploads everything and deletes nothing it didn't write.
- Folder and S3: `PublicObjectWriter.putPublic` with content types for `.html`, `.css`, `.xml` and asset types, `Cache-Control: max-age=300` for pages and `max-age=31536000, immutable` for assets.
- **Republish automatically**: `SiteController` listens to `NoteStore` changes for notes in published notebooks and republishes 60 seconds after the last change, at most once every 5 minutes per site, only while NoteIt runs.

#### 3.7 GitHub Pages (milestone 3)

- `GitHubPagesConfig`: `owner`, `repo`, `branch` (default `gh-pages`), `path` (default empty). The token is a fine-grained personal access token with **Contents: Read and write** on that one repository, stored in the keychain.
- Publishing uses the REST Git Data API, one commit per publish, no `git` binary: read the branch ref (create the branch from an empty tree if it doesn't exist), create blobs for changed files only, create a tree with `base_tree`, entries with `sha: null` for deletions, create a commit "Publish <site title> from NoteIt", and update the ref (not forced). A rejected ref update (someone pushed meanwhile) retries once from the new head.
- Test checks the token, the repository and push access with `GET /repos/{owner}/{repo}`, and reports whether GitHub Pages is enabled for the branch (`GET /repos/{owner}/{repo}/pages`); if not it says **Turn on GitHub Pages for the <branch> branch in the repository's settings.** NoteIt doesn't change repository settings.
- Limits: a file over 100 MB or a site over 1 GB is refused before uploading, matching GitHub's limits.

#### 3.8 Errors and privacy

- A failed publish keeps the previous site online (manifest last), shows **Couldn't publish <site>: <reason>** in the sheet and in Settings, and the next automatic run retries with backoff (1, 5, 15 minutes, then hourly).
- Published sites are plaintext by design. The warning in §"What the user gets" is always visible in the Publish sheet, and turning on **Republish automatically** shows it again in a confirmation.

### 4. Shared notebooks

#### 4.1 Model

- A **space** is a separate remote store holding one shared notebook. It isn't part of anyone's personal sync store, because members don't share each other's sync keys.
- A space's root, chosen by the owner:
  - S3: `<bucket>/<prefix>/noteit-spaces/<SPACE-UUID>/`.
  - Folder: `<folder>/noteit-spaces/<SPACE-UUID>/`.
  - Your self-hosted NoteIt Server (milestone 5): the server's space bucket `space-<SPACE-UUID>` (§4.11).
- Inside the root:

```
inkwell/v1/…                      an ordinary NoteIt sync store: manifest, notebook, notes, bodies, tombstones
inkwell/v1/devices/<member-id>/<UUID>.json          a member's device record, including its rekeyAck
noteit/space/v1/log/<seq>.json    the signed membership log, seq zero-padded to 10 digits
noteit/space/v1/keys/<epoch>/<member-id>.key        the notebook key for an epoch, wrapped for a member
noteit/space/v1/keys/<epoch>/invite-<invite-id>.key  …or for a pending invitation
noteit/space/v1/profiles/<member-id>.json           the member's display name, sealed with the notebook key
```

- The data part is a normal sync store, so the existing `SyncEngine`, planner, conflict copies, tombstones and `RawMetaOverlay` are reused unchanged. The cipher is new (§4.5). Everything else is under the new, additive `noteit/space/v1/` prefix; the frozen `inkwell/v1/` record formats are not changed. The one layout difference, device records one level deeper (`inkwell/v1/devices/<member-id>/<UUID>.json`, below), is an additive registry row.
- **Manifest and session.** The `Manifest`, `StoreFeature` and `StoreSession` types are owned and built by foundations (step 3); sharing doesn't define them. Program §4 applies to space stores as it does to personal stores:
  - The space's `inkwell/v1/manifest.json` has `formatVersion: 2` and `features` containing `noteit-space`, because a manifest with any feature is version 2. Creating the space writes `features: ["noteit-space"]` directly in its first manifest: `SpaceSession.connect` passes `initialFeatures: [.noteItSpace]` to foundations' `connectSession` when it creates the space. The program's creation rule allows this: a brand-new store or space gets its initial features in the first manifest, and `ensureFeature` is only for adding a feature to an existing store. A space that doesn't exist yet has no members whose Macs could stop syncing. Body encoding follows `features` (`noteit-doc`), never `formatVersion`.
  - `noteit-space` is in the foundations `StoreFeature` registry and is accepted only in a space session (program §4 rule 2). Foundations builds only the generic check against the `supported` set a session is opened with. Sharing owns the space-session acceptance logic: `noteit-space` never joins `StoreFeature.supported`, and `SpaceSession.connect` opens every space through `connectSession(backend:, kind: .space, credential: nil, deviceName: "", createIfMissing: create, encrypted: true, initialFeatures:, supported: StoreFeature.supported ∪ [.noteItSpace], cipher: spaceCipher)`; the credential is nil because the space cipher is supplied. A personal session refuses a manifest that has it (`unsupportedFeature`), and a space session refuses a manifest without it. The `encryption` block's key check is sealed with the space cipher when the space is created, and opening a space with its cipher must open that key check: if it doesn't, `connectSession` throws `wrongPassphrase` and returns no session. `SpaceClient` treats that as a stale space key: it refreshes the log and key files, unwraps the latest epoch key and tries once more with that cipher; if it still fails, the space reports the error and is retried on the next pass. A rotation replaces the key check with one sealed by the new epoch's cipher in the same manifest write that clears the `rekey` field (§4.8). Ordinary Sync pointed at a space still fails safely: its passphrase can't open that key check, and a personal session refuses `noteit-space` anyway.
  - Manifest changes read the manifest, change only their own keys and write it back with a conditional write. A later feature in an existing space (for example `noteit-doc`) is added only through `SyncEngine.ensureFeature(_:backend:session:currentDeviceID:confirm:)`, which lists the members' Macs that would stop syncing and asks first. `currentDeviceID` is this Mac's device ID in the space: `SpaceSession.connect` takes it, and the same ID goes to the space's `SyncEngine` and `RekeyRunner`.
- **Remote layout.** Sharing registers its prefixes in the `RemoteLayout` registry (program §4 rules 6 and 8) with their key depth, and adds key test vectors for the web server. The depth table itself is in the sync-security spec §1.
  - In a space store, `inkwell/v1/` records are `.storeKey`, sealed with the session's key, which in a space session is the space key (`SpaceCipher`).
  - Device records in a space store are one level deeper than in a personal store: `inkwell/v1/devices/<member-id>/<UUID>.json` (depth 2), so the member who owns a device is part of its key. Sharing registers `RemotePrefix(path: "inkwell/v1/devices/", depth: 2, sealing: .storeKey, owner: "sharing")` next to the core depth-1 row. The engine needs no change: a space's device ID is the string `<member-id>/<UUID>`, given to the space's `SyncEngine.init`, `SpaceSession.connect`, `RekeyRunner` and `ensureFeature`, so the existing device-record key builder produces that key, and the engine's recursive listing of `inkwell/v1/devices/` finds every member's records. `rekeyAck` is a field of that record, so an acknowledgement always sits under its member's path too.
  - `noteit/space/v1/log/` (depth 1) and `noteit/space/v1/keys/` (depth 2) are `.unsealed`: log entries are signed plaintext and key files are HPKE-wrapped and signed. A rekey never re-seals them.
  - `noteit/space/v1/profiles/` (depth 1) is `.storeKey`, sealed with the session's key, which is the space key in a space session.
  - `noteit/identity/v1/` (depth 1) in personal stores is `.storeKey`, sealed with the personal store key (§4.10).

#### 4.2 Identity

- Each person has a `MemberIdentity`: an X25519 key pair (`Curve25519.KeyAgreement`) for receiving keys and an Ed25519 key pair (`Curve25519.Signing`) for signing.
- **Member ID** = first 16 bytes of `SHA-256("noteit-member-v1" ‖ x25519 public ‖ ed25519 public)`, as 32 lowercase hex characters.
- **Safety code** = the member ID's first 60 bits as 12 decimal digits shown `1234 5678 9012`. Both people seeing the same code for each other proves the keys weren't swapped.
- Private keys are in the keychain (`<bundleID>.sharing`, accounts `identity-agreement` and `identity-signing`), created the first time the user shares or joins a notebook.
- Milestone 4: each Mac has its own identity, so a person's second Mac joins with its own invitation. Milestone 5: the identity is backed up, encrypted with the sync key, to the personal store at `noteit/identity/v1/identity.sealed`, so the user's other Macs use the same identity and join their spaces automatically (§4.10).

#### 4.3 Membership log

- Every change to membership is an entry appended to `noteit/space/v1/log/`, created with `If-None-Match` so two writers can't take the same sequence number.
- Entry file: `{ "body": "<base64 JSON>", "signer": "<member-id | invite:<invite-id>>", "sig": "<base64 Ed25519 signature over the body bytes>" }`. Signing raw body bytes avoids JSON canonicalization between Swift and the future TypeScript port.
- Body fields: `v` (1), `space` (UUID), `seq`, `prev` (base64 SHA-256 of the previous entry file's bytes; empty for seq 0), `at` (ISO date), `type`, and per type:

| Type | Signed by | Fields | Effect |
|---|---|---|---|
| `create` | owner | owner public keys, `epoch: 0`, `keyCommitment` | space exists; owner is a member with role `owner` |
| `invite` | owner | `inviteID`, `role`, invite public keys (X25519, Ed25519), `expiresAt` | pending invitation |
| `revokeInvite` | owner | `inviteID` | invitation can't be used |
| `join` | invite key | `inviteID`, member public keys | first valid join per invitation adds the member with the invited role |
| `setRole` | owner | `member`, `role` | role change; a downgrade to `read` must be followed by `rotate` |
| `remove` | owner | `member` | member removed; must be followed by `rotate` |
| `leave` | the member | `member` | member removed; the owner's app follows with `rotate` |
| `rotate` | owner | `epoch`, `keyCommitment` | new notebook key epoch |

- `keyCommitment` = `SHA-256("noteit-space-key-v1" ‖ space ‖ epoch ‖ key)`. Any unwrapped key is checked against it, so a substituted wrapped key is detected.
- `SpaceLog.replay` verifies every signature, the `prev` chain, sequence continuity, signer rights per the table, and invitation expiry and single use, and produces `SpaceState` (members and roles, pending invitations, current epoch and commitment, head seq and hash). An invalid entry stops replay at that point: the space is shown as **This shared notebook's storage has unexpected changes** and sync pauses. Nothing local is deleted.
- **Rollback and fork detection.** Each Mac stores the last verified `(seq, hash)` per space. A listing that ends earlier, or a different hash at a known seq, pauses the space with the same message. Freezing (hiding new entries) can't be detected without a server; this is documented, like Sync.
- Logs are tiny (one entry per membership change), so there is no compaction.

#### 4.4 Roles

- `owner` (exactly one, the creator): everything, including invitations, roles, removal and **Stop Sharing**.
- `write`: read and edit notes, create and delete notes in the notebook, rename the notebook.
- `read`: read only.
- Enforcement:
  - **Cryptographic**, everywhere: every object in the data store is signed by its writer (§4.5), and readers check the signer against the object's key (its context):

    | Object | Who may sign it |
    |---|---|
    | `noteit/space/v1/profiles/<member-id>.json` | that member, any role |
    | `inkwell/v1/devices/<member-id>/<UUID>.json`, including its `rekeyAck` | the member whose ID is `<member-id>` in the key, any role, while the signed membership log lists them as a member. Ownership comes from the key alone: a record signed by anyone else, or a device record at any other depth, is rejected. Nothing is learned from the order records arrive in. |
    | everything else: notes, notebooks, tombstones, boards, attachments and any later record | a current `owner` or `write` member |

    So a read-only member can join, register their devices, show their name and acknowledge a key rotation, but can't change anyone's notes, even with storage write access.
  - **Storage**, where possible: spaces on your self-hosted NoteIt Server enforce roles on writes and deletes (§4.11). A read-only member still writes a few objects of their own (the `join` entry, their wrapped key copy, their profile and their device records), so on S3 and folders they need write access to the space's storage and roles there rest on the cryptographic check; the invitation sheet says so.
- A storage-level delete can't be prevented cryptographically: someone with delete access to the bucket can remove files. Deleted notes reach Recently Deleted on each Mac like any synced deletion, so they can be restored for 30 days. This limit is in the Settings help and in `docs/known-limitations.md`.

#### 4.5 Encryption of the data store (`SpaceCipher`)

- `SpaceCipher` implements the existing `SyncCipher` protocol. A space session (§4.1) carries it (`SpaceSession.connect` hands it to `connectSession` as `cipher:`, so the session never builds its own), so `SyncEngine` and `RekeyRunner` use it like `AESGCMCipher`.
- Sealed object:

```
"NSP1" (4) | epoch (u32 BE) | signer member ID (16) | nonce (12) | ciphertext | tag (16) | Ed25519 signature (64)
```

- AES-256-GCM with the epoch's notebook key. AAD = `"noteit-space-v1" ‖ space UUID bytes ‖ epoch ‖ context`, where `context` is the object key relative to `inkwell/v1/`, as in Sync.
- The signature covers `"noteit-space-v1" ‖ space ‖ context ‖ every byte before the signature`.
- `open` throws unless the epoch is the current one, the signer is a current member allowed to sign that context by the table in §4.4, and the signature and tag verify. `SyncEngine` already treats an object that fails to open as skipped for this pass and never deletes anything because of it.
- Device records and tombstones are sealed the same way. Devices are named "<member name> on <Mac name>", so conflict copies say who made the other version.

#### 4.6 Key wrapping

- The notebook key is 32 random bytes per epoch.
- It is wrapped with HPKE (RFC 9180, CryptoKit `HPKE`, available on macOS 14): base mode, `DHKEM(X25519, HKDF-SHA256)`, `HKDF-SHA256`, `AES-256-GCM`; `info` = `"noteit-space-key-v1|<space>|<epoch>|<recipient id>"`.
- Key file: `{ "v": 1, "epoch", "recipient", "enc": "<base64>", "ct": "<base64>", "wrapper": "<member-id>", "sig": "<base64>" }`, signed by the wrapper (the owner, or the member for their own copy after joining). The unwrapped key must match the epoch's `keyCommitment`.
- **Staged key changes.** Creating a space and rotating its key are staged, so a crash never commits an epoch whose key the owner doesn't have:
  1. Generate the epoch key and store it in this Mac's keychain as a pending entry keyed by space and epoch (`<bundleID>.sharing`, account `space-<UUID>-epoch-<n>-pending`).
  2. Upload the owner's wrapped key file for that epoch (`noteit/space/v1/keys/<n>/<owner-id>.key`), read it back and unwrap it with the owner's identity. It must give the pending key; if it doesn't, the upload is retried and nothing is committed.
  3. Only then commit. For a new space: append the `create` entry (seq 0), then write the space manifest through `SpaceSession.connect(create: true)` (§4.1). For a rotation: append the `remove` or `setRole` entry, if there is one, and the `rotate` entry (§4.8). The log append is the commit point; the pending entry then becomes the current one (account `space-<UUID>-epoch-<n>`).
- On launch, each pending entry is checked against the log:
  - The log has the `create` or `rotate` entry for that epoch with the pending key's commitment: the entry is committed, so the pending entry becomes current and the operation continues where it stopped (a new space writes its manifest if it's missing; a rotation wraps the key for the others and resumes the runner, §4.8).
  - The log has that epoch with another commitment (another of the owner's Macs rotated first, milestone 5): the pending entry is deleted. The epoch's key files belong to the committed key and are kept.
  - The log has no entry for that epoch: the operation resumes from step 2. While it does, the owner sees **Finishing sharing “<notebook>”…** or **Finishing removing <name>…** with **Cancel**. Cancel deletes the pending entry and the epoch's orphan key files (`noteit/space/v1/keys/<n>/`); a cancelled new space also loses its `spaces.json` entry and the notebook stays personal. Cancel isn't offered once a `remove`, `setRole` downgrade or `leave` entry is in the log, because replay requires the `rotate` that follows it (§4.3); the app resumes instead.

#### 4.7 Invitations

- The owner creates an invitation:
  1. Random `inviteID` (16 bytes, base32), invite key pairs (X25519 + Ed25519), and a **code** of 12 Crockford base32 characters (60 bits), shown as `XXXX-XXXX-XXXX`.
  2. Appends an `invite` entry and writes `keys/<epoch>/invite-<invite-id>.key`.
  3. Builds the **invitation payload**: space UUID, notebook name, location (provider kind, endpoint, region, bucket, prefix, path style; or folder hint; or server URL), the invitee's storage keys if given, the owner's public keys (the trust anchor for the log), the role, `inviteID`, the invite private keys, and `expiresAt` (7 days, at most 30).
  4. Seals the payload with `PBKDF2-HMAC-SHA256(code, salt: inviteID, 600 000 iterations)` as the AES-256-GCM key, AAD `"noteit-invite-v1:" + inviteID`.
  5. Link: `noteit://join#v1.<inviteID>.<base64url(sealed)>`. A typical S3 invitation is about 700 characters.
- The code is what makes an intercepted link useless: 60 bits behind 600 000 PBKDF2 rounds can't be guessed offline in practice. The help says to send the code another way.
- Joining (invitee):
  1. Decrypt with the code. A wrong code says **That code doesn't match this invitation.**
  2. Connect to the storage, read the log, verify it from the `create` entry against the owner key in the payload, and check the invitation is pending and unexpired.
  3. Append a `join` entry signed with the invite key, containing the invitee's public keys. If another `join` for that invitation already exists, show **This invitation was already used. Ask for a new one.**
  4. Unwrap the notebook key from `invite-<invite-id>.key`, write a wrapped copy for themselves, write their sealed profile, and start syncing.
- A folder location can't be carried in a link (each Mac mounts it differently), so a folder invitation asks the invitee to **Choose the shared folder** and checks that it contains the space.
- Invitations expire after 7 days.
- Expired and cancelled invitations: the owner's app deletes their key files on the next refresh.

#### 4.8 Removal and key rotation

- **Remove** (and a downgrade to `read`, and a `leave`) is done by the owner's app:
  1. Refresh and sync the space so the owner's copy is current.
  2. Stage the epoch + 1 key (§4.6): a pending keychain entry, then the owner's key file, uploaded and read back. Only then record the rotation state (the new epoch and `preRemovalHead`, the log head just before the `remove`, `setRole` or `leave` entry) in `spaces.json`, and append `remove` (or `setRole`), then `rotate` with epoch + 1. If another entry takes the next seq first, the state is rewritten with the new head before retrying. From this moment readers reject objects signed by the removed person.
  3. Wrap the new key for every remaining member and pending invitation.
  4. Re-seal the space store with sync-security's `RekeyRunner`, the same runner Sync uses (program §4 rule 7), in its `.spaceEpoch(newCipher:newKeyID:)` mode. Sharing has no re-encryption code of its own. The old cipher is the space cipher for the old epoch whose signer rules come from replaying the log only through `preRemovalHead`, so records last signed by the removed person still open and are re-sealed rather than skipped; the new cipher is the space cipher for the new epoch with the post-removal state, signing as the owner; the new key ID is the new epoch key's `SpaceSession.keyID(epochKey:)`. In this mode the runner opens by writing only the `rekey` field to the space manifest, with no passphrase, keyring or feature, and its finish replaces the `encryption` key check with one sealed by the new cipher in the same write that clears the field. It sets that field, re-seals the `.storeKey` records (`inkwell/v1/**` and `noteit/space/v1/profiles/`) with the space ciphers, never the `.unsealed` log or key files, keeps envelope revisions, resumes after a crash (both ciphers rebuilt from the log, the key files and the persisted `preRemovalHead`, never from the current head alone), and clears the `rekey` field when done. It runs only when no body versions are waiting to upload, and the space's storage check runs before and after it.
  5. Delete the old epoch's key files and clear the rotation state.
- On every kind of storage, the runner's fence waits until every non-removed member device has written `rekeyAck` for the new key, or the owner confirms removing the stale ones (program §4 rule 7). The removed person's devices, every record under `inkwell/v1/devices/<removed-id>/`, are excluded from the fence, and the fence counts an acknowledgement only from a record that opens under its own member's path, so one member can't acknowledge for another's device. Until the others have acknowledged, the owner sees **Re-encrypting is waiting for <names> to sync.** with the runner's **Wait Longer** and **Remove and Continue**.
- While the space manifest has the `rekey` field, the other members' apps pause the space the way Sync does (`rekeyInProgress`) and show **Waiting for <owner> to finish re-encrypting “<notebook>”.** After the rotation each member's app calls `SyncEngine.rebaseline(newKeyID:)` with the new epoch's key ID, which adopts the re-sealed ETags without downloading bodies or making conflict copies. Unsynced edits are then pushed under the new epoch. The engine needs no sharing-specific change.
- What removal does and doesn't do, stated in the Remove confirmation: **<name> won't see new changes. They keep anything they already had on their Mac. Also remove their access to the storage if you gave them their own keys.**
- Rotation re-uploads every object in the space, including bodies with images. That is accepted because it happens only on removal or a downgrade, and the owner sees progress: **Re-encrypting 120 of 431…**.
- Only the owner can remove people or rotate keys. If the owner's Mac is gone, the notebook can't be managed, but it keeps syncing for its members, and a member can duplicate it into a new space they own. More than one owner would be a later change to the log (an `addOwner` entry).

#### 4.9 The notebook on each Mac

- Which notebook belongs to which space is kept only in `spaces.json` (next item), read through `NoteStore.spaceID(forNotebook:)`. `Notebook` gains no field for it, so the link is never written to a remote notebook record, to `library.json` or to a Markdown library's `.noteit-notebook.json`. Shared notebooks and their notes are synced only to their space, and never to the personal store.
- Local space configuration (`spaces.json` in the data folder, `NoteStore.rootURL`, program §7): space UUID, notebook ID, location, role, own member ID and last verified log head, plus `creating: true` until the `create` entry is committed (§4.6) and, during a rotation, `rotation` (new epoch and `preRemovalHead`, §4.8). Per-space state lives in `NoteStore.rootURL/spaces/<id>/` (`sync-state.json`, `deletions.json`). Storage secrets for the space are in the keychain (`space-<UUID>-access-key`, `space-<UUID>-secret`), next to the owner's epoch keys (`space-<UUID>-epoch-<n>` and, during a staged change, `space-<UUID>-epoch-<n>-pending`).
- Sync scopes: `NoteStoreSyncAdapter` gains a `LibrarySyncScope`, `.personal` or `.space(UUID)`. The personal scope excludes shared notebooks and their notes; a space scope includes only its notebook and notes. Deletion journals are per scope.
- **Moving notes.** Moving a note into a shared notebook journals a deletion in the personal scope and creates it in the space with the same UUID. Moving it out does the reverse and, for members, asks first: **Move “<title>” out of “<notebook>”? It will be removed for everyone in the notebook.** Read-only members can't move notes out; they get **Duplicate to My Notes**.
- **Changing note text.** Sharing never writes note text directly. Any change it makes to a note's text goes through `NoteStore.editBody` (program §6). Remote changes arrive through the same `NoteStore+Sync` path as personal Sync.
- **Read-only** members: `NoteStore.isBodyWriteBlocked(_:)` returns true for notes in read spaces, which already makes the editor read-only, and `editBody` refuses them, so automation, plugins and other callers can't change them either. The Local API returns `403 read_only` for such writes (program §10). Metadata changes (pin, move, delete) are disabled for them too.
- Version history stays local, as today.
- Scheduling follows `SyncController`'s rules (after local edits, every 60 s while active, 600 s otherwise, on wake), one pass at a time per space, at `.utility` QoS, with a log refresh before every pass. Shared notebooks work without personal Sync being configured.
- Sub-notebooks (from `organise`) can't be inside a shared notebook in v1. **Share Notebook…** is disabled for a notebook with sub-notebooks, with the tooltip **Notebooks with sub-notebooks can't be shared yet.**
- **Locked notes** (program §8, implemented by `sync-security`): locked notes can't be in shared notebooks.
  - Moving a locked note into a shared notebook is refused with **Notes in shared notebooks can't be locked.** (program §8).
  - **Share Notebook…** is disabled for a notebook that contains locked notes (wording in "What the user gets").
  - `sync-security` disables **Lock Note** for notes in a notebook that belongs to a space (`NoteStore.spaceID(forNotebook:)` isn't nil), with **Notes in shared notebooks can't be locked.**

#### 4.10 Your other Macs (milestone 5)

- When personal Sync is configured, the identity and the list of joined spaces (location and storage secrets) are written to the personal store, sealed with the personal sync cipher:
  - `noteit/identity/v1/identity.sealed`
  - `noteit/identity/v1/spaces.sealed`
- Another Mac of the same person picks them up on its next sync, uses the same identity and joins the same spaces without an invitation. The sidebar shows the notebooks after their first space sync.
- Both objects are outside `inkwell/v1/`, so existing `SyncEngine` passes don't see them. `noteit/identity/v1/` is registered in `RemoteLayout` as `.storeKey` (§4.1), and the web server accepts it (program §4.8).
- When the personal store key is replaced, the `RekeyRunner` re-seals `identity.sealed` and `spaces.sealed` with the rest of the store, because they are `.storeKey` records. Sharing does nothing extra.

#### 4.11 Spaces on your self-hosted NoteIt Server (milestone 5)

- When the group uses your self-hosted NoteIt Server from `web-app`, a space lives in that server's space namespace and each person signs in with their own user on it, so nobody shares storage keys and the server enforces roles.
- The native app talks to it only through the server's S3-compatible `/s3` front door with the user's own keys. What it needs from the server is listed under Dependencies.
- Invitations to a space on your self-hosted NoteIt Server take the invitee's user name on that server; the owner's app grants them storage access with the invited role when the invitation is created.
- The server still sees only ciphertext and the plaintext log (public keys, roles, counts and times, but no names).

#### 4.12 What the storage can see

- For share links: one HTML file of about the note's size, its id, and when it was written. Never the key or the content.
- For sites: everything, by design.
- For shared notebooks: the number of members and their public keys and roles, the number and sizes of notes, when they change, and which member wrote each object. Names, titles and contents are encrypted.

### 5. Settings, menus and commands

| Where | Item |
|---|---|
| Settings › Sharing | Destinations (Add, Edit, Test, Remove) |
| Settings › Sharing | Shared Links (Copy Link, Update Now, Delete) |
| Settings › Sharing | Published Sites (Republish Now, Copy Address, Stop Publishing) |
| Settings › Sharing | Shared Notebooks (status, People…, Leave or Stop Sharing) and **Your name** with your safety code |
| File › Share ▸ | Create Share Link… (⌥⌘L), Share Notebook…, Publish…, Join Shared Notebook…, then the existing system share services |
| Sidebar notebook context menu | Publish Notebook…, Share Notebook…, and for published or shared notebooks their actions |
| Sidebar notebook rows | Globe badge for published notebooks, people badge for shared notebooks |
| Note list context menu, toolbar Share button | Create Share Link… / Share Link… |
| Command palette | Create Share Link…, Publish Notebook…, Republish Notebook, Share Notebook…, Join Shared Notebook…, Show Shared Links |

- `MenuShortcutCommand` gains `createShareLink` with the default ⌥⌘L, and `MenuShortcutRules` and `docs/keyboard-shortcuts.md` are updated in the same change (program §9). The other commands have no default shortcut and get none (they are not in `MenuShortcutCommand`).
- Palette command IDs are camelCase: `createShareLink`, `publishNotebook`, `republishNotebook`, `shareNotebook`, `joinSharedNotebook`, `showSharedLinks`.
- The Settings tab is the frozen row from program §9: order 6, raw value `sharing`, symbol `person.2`.
- No new global hotkeys.
- UserDefaults keys: `publishDestinations`, `sharingDisplayName`, `shareViewerHidesKey` (bool, default false; when on, the viewer removes the key from the address bar after opening the note). Everything else is in files in the data folder (`NoteStore.rootURL`: `shares.json`, `spaces.json`, `sites/`, `spaces/<id>/`) or in the keychain.

### 6. Links and the Local API

- **`noteit://join`.** Sharing registers the `join` host with `URLRouteRegistry.register(host:handler:)` from `automation` (program §3). The handler gets the whole URL, including the fragment that carries the invitation, and calls `SpaceController.openInvitation(_:)`, which opens the Join sheet with the link filled in. **File › Share ▸ Join Shared Notebook…** also accepts a pasted link. On the phone, `mobile` shows "This works in NoteIt for Mac" for this host.
- **Note links.** Wherever sharing prints a link to a note (the Local API, Settings), it uses the `noteit://note/<UUID>` form from `NoteItCore.NoteLink`.
- **Local API routes.** Sharing registers its own routes with `LocalAPIRouteRegistry.shared.register` (program §10). Errors use `APIErrorCode` only, in the nested error body. No space management over the API in v1.

| Route id | Method and path | Scope | Result |
|---|---|---|---|
| `sharing.listShares` | `GET /v1/shares` | `read` | `[{id, noteID, noteLink, destinationID, createdAt, expiresAt?, hasPassphrase, keepUpdated}]`. No link keys. |
| `sharing.createShareLink` | `POST /v1/notes/{id}/share-link` with `{destinationID, expiresInDays?, keepUpdated?}` | `write` | `{id, url}`. No passphrase over the API. |
| `sharing.deleteShare` | `DELETE /v1/shares/{id}` | `write` | `204` |
| `sharing.publishSite` | `POST /v1/sites/{notebookID}/publish` | `write` | `{address, publishedAt}` for a notebook that is already published |

- Error mapping: unknown note, share, destination or site `404 not_found`; note in Recently Deleted `409 note_deleted`; locked note `423 note_locked`; note too large for a link `413 too_large`; a destination that can't hold links (GitHub Pages) `bad_request`; library still loading `503 not_ready`; upload failures `internal` with the storage error text.

## Dependencies

Sharing is in wave 3, so foundations and the wave 1 and wave 2 sub-projects it uses are in place before milestone 1 starts. Locked notes (sync-security milestone 5) also land in wave 3, after web-app Tasks 0.4–0.5. Sharing reads locked state only through foundations' `NoteMeta.isLocked`, so its locked-note checks are tested with fixture notes and don't wait for that milestone.

- **foundations (00)**:
  - `Manifest`, `StoreFeature` (including the `noteit-space` case), `StoreSession` with its space kind, and `SyncEngine.ensureFeature(_:backend:session:currentDeviceID:confirm:)`. `SyncEngine.connectSession` with its `initialFeatures`, `supported` and `cipher` parameters. Foundations implements the generic check against `supported`; sharing owns the check that accepts `noteit-space` only in a space session, by passing `StoreFeature.supported ∪ [.noteItSpace]` for space sessions only (§4.1).
  - The `RemoteLayout` registry with `.storeKey`/`.spaceKey`/`.unsealed` sealing, key depth and `RekeyScope`, where sharing registers `noteit/identity/v1/`, `noteit/space/v1/` and the depth-2 `inkwell/v1/devices/` row for space device records (§4.1), with key test vectors for the web server. That row needs one registry rule from foundations: several rows may share a path with different depths, a key is valid at the depth of any row with its path, and `prefix(for:)` returns the longest matching row whose depth equals the key's.
  - `SyncEngine.rebaseline(newKeyID:)` (§4.8).
  - `NoteStore.editBody` (§4.9), `NoteMeta.isLocked`, `Notebook` in `NoteItCore`, and the frozen Settings tab, menu and sidebar tables (§5).
  - `URLRouteRegistry` and `LocalAPIRouteRegistry`, through which sharing registers its own link host and routes (§6).
- **automation (01)**: owns `noteit://` routing and the Local API. Sharing registers the `join` host and the `sharing.*` routes itself (§6); automation needs nothing else from sharing.
- **linking (03)**: the `noteit://note/<UUID>` format in `NoteItCore.NoteLink` (§3.4) and the link index for **Linked from**.
- **organise (04)**: nested notebooks (published as sections; not allowed inside shared notebooks in v1) and tag lists (the exclusion tag).
- **markdown-storage (02)**: no direct dependency; everything reads through `NoteStore`, and sharing's files live in `NoteStore.rootURL`.
- **sync-security (08)**:
  - Owns locked notes (program §8). Locked notes are never shared, published or moved into a shared notebook, and sync-security disables **Lock Note** for notes in shared notebooks.
  - Owns `RekeyRunner` and the `rekeyAck` fence, used for every re-encryption after a removal (§4.8): in `.spaceEpoch(newCipher:newKeyID:)` mode the runner takes the old and new space ciphers, writes the `rekey` field to the space manifest (and, at finish, a key check sealed by the new cipher in the write that clears it), re-seals the space store's `.storeKey` records, skips `.unsealed` ones, and leaves the removed person's devices out of the fence. Its personal rekey re-seals `noteit/identity/v1/` along with the rest of the personal store.
  - Owns the key depth table (sync-security spec §1), which lists sharing's prefixes.
  - Lists the calls from §2.8, §3.7 and §4 in the network inventory. A WebDAV backend can later become a destination.
- **web-app**:
  - The web server accepts `noteit/(identity|space)/v1/…` keys (program §4.8). Sharing's key test vectors cover `noteit/space/v1/(log/\d{10}\.json|keys/\d+/(invite-)?[0-9a-z]{26,32}\.key|profiles/[0-9a-f]{32}\.json)` and `inkwell/v1/devices/[0-9a-f]{32}/<UUID>\.json` in space stores and `noteit/identity/v1/(identity|spaces)\.sealed` in personal stores.
  - Needs, for milestone 5, on your self-hosted NoteIt Server: a space namespace (`/data/store/spaces/<SPACE-UUID>/`) exposed in `/s3` as bucket `space-<SPACE-UUID>`; `PUT /s3/space-<UUID>` (CreateBucket) creating a space owned by the caller; an owner-only `PUT /s3/space-<UUID>?noteit-members` with `[{"username", "role": "read" | "write"}]` that sets who may read and write; and role checks on every write and delete: `write` users may write and delete anything in the space; `read` users may only create new `noteit/space/v1/log/` entries, write files under `noteit/space/v1/keys/` and `noteit/space/v1/profiles/` and write records under `inkwell/v1/devices/`, and may delete nothing. Signatures (§4.4) decide whose objects these are.
  - Web support for share links needs nothing (the viewer is static). Web support for shared notebooks needs a TypeScript port of `SpaceLog`, `SpaceCipher` and HPKE unwrap; the Swift tests write golden vectors for it to `fixtures/golden/space/`.
- **mobile (11)**: `ShareLinkCodec` and the space code live in `NoteItSync` with no AppKit, so the iPhone app can reuse them.

## Non-goals

- A NoteIt-hosted share service, short links or link analytics.
- Comments, real-time co-editing or presence.
- Sharing a single note with edit rights. Edit rights come with shared notebooks.
- Opening a share link inside NoteIt or importing it ("Save to my notes"). The recipient copies text from the page.
- Custom site templates or themes beyond appearance, accent and the built-in layout. Search on published sites.
- Publishing to services that need an SDK or OAuth app (Netlify, Vercel, Cloudflare Pages API). A folder or bucket they serve works.
- Creating buckets, public-read policies, lifecycle rules or IAM users at providers.
- Transferring ownership, more than one owner, or nested sharing.
- Syncing the Shared Links list between your Macs.
- Setting provider lifecycle rules for expired links; expiry is the viewer's refusal plus deletion at the next run (§2.5).
- A per-note "publish" opt-in for sites; notes tagged with the exclusion tag (default `draft`) are left out (§3).
- Per-epoch objects that would let a rotation avoid re-uploading everything.
- Protection against a storage provider that hides new membership entries (freezing).
- Shared notebooks in the web app (needs the TypeScript port, owned by `web-app` follow-up work).

## Open questions

1. **Invitation lifetime.** v1 invitations expire after 7 days (§4.7). Should the owner be able to choose a longer lifetime, up to 30 days, in the Invite sheet?
