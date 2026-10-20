# Automation — Design

Status: proposed · Date: 2026-10-19 · Companion plan: docs/plans/2026-10-19-automation.md

## Goal

Let other tools on the Mac work with NoteIt without screen scraping: links that create and open notes, Shortcuts actions, notes in Spotlight, "Share → NoteIt" from any app, a `noteit` command for the terminal, and one local HTTP+JSON interface (the **Local API**) that every other integration builds on. The command line tool, the MCP server (`private-ai`) and the browser extension (`web-clipper`) talk to NoteIt only through the Local API. Plugins never hold Local API tokens; they use their own host protocol (`plugins`).

The shared seams this spec defines are built first, in foundations (program design §2, step 5), and this spec stays their reference:

- 5.1: the `NoteItAPI` target with the v1 wire types and `HTTPMessage`, the `NoteItAPITests` target, and the `NoteItCLI` stub (`noteit --version` and `CLIExit`).
- 5.2: `LocalAPIRouteRegistry` with `RouteMatch`, `OriginDecision`, `LocalAPIContext` and `ClientRecord`.
- 5.3: `NoteLink`, `URLCommand` and `AppendPosition` in `NoteItCore`.
- 5.4: `URLRouteRegistry`, a `@MainActor` class in the app target.
- 5.5: the embeds table in `scripts/build_app.sh`.

Automation builds the behaviour on top: the server, auth, handlers, URL handling, the CLI commands and the Share extension.

Everything here runs on the Mac. Nothing listens on the network, nothing needs an account, and the Local API is off until the user turns it on.

## What the user gets

- **Links.** `noteit://new?title=Groceries&text=Milk` creates a note. `noteit://note/<UUID>` (the stored link between notes) and `noteit://open?id=…` open one. Links work from Shortcuts, Raycast, Alfred, Keyboard Maestro, other notes and web pages (the browser asks first). A link from another app that creates a note or adds to one asks first, unless the user turns that off. Links support x-callback-url, so a calling app gets the new note's id back.
- **Copy Note Link.** Edit › Copy Note Link (⌃⌘L) puts `noteit://note/<UUID>` on the clipboard, with the note title as the rich-text link name. It is the one Copy Note Link command; linking's context menu and palette entry call it.
- **Share → NoteIt.** The Share menu in any Mac app offers NoteIt. Shared text, links and images become a new note.
- **Shortcuts.** Create Note, Append to Note, Append to Daily Note, Open Note, Find Notes and Get Note Text show up in the Shortcuts app, in Spotlight's action list and for Siri. They run without bringing NoteIt to the front, except Open Note.
- **Spotlight.** Notes appear in Spotlight by title and text. Choosing one opens it in NoteIt. Notes in Recently Deleted never appear.
- **Command line.** `noteit new "Buy milk"`, `echo "line" | noteit append --today`, `noteit search invoice --json`, `noteit edit <id>` (opens `$EDITOR` with Markdown). Installed from Settings › Integrations or with `brew install --cask noteit` (the cask's `binary` line is `growth`'s). `noteit mcp` arrives with `private-ai` in wave 2.
- **Local API.** Settings › Integrations › **Allow apps on this Mac to use NoteIt**. When on, apps pair with NoteIt by showing a 6-digit code that NoteIt displays. Each paired app is listed with what it may do and when it was last used, and can be removed with **Revoke**.

## Design

### 1. Shared foundation: `AutomationService`

All surfaces (links, Shortcuts, Spotlight open, the Share extension, Local API) call one `@MainActor` facade, `AutomationService`, in the app target. It is the only automation code that touches `NoteStore`. It reads through public `NoteStore` APIs and `NoteBodyStorage`, and changes note text only through `NoteStore.editBody` (organise, built in foundations). It never reads `notes/<uuid>.rtfd` directly, so it keeps working with a Markdown folder library from `markdown-storage`.

Operations:

| Operation | Behaviour |
|---|---|
| create | New note in a notebook (id, or name matched case-insensitively; default is the New Notes notebook from Settings › Editor). Optional title becomes a bold first line, exactly like Quick Capture (`NoteStore.capturedText(title:body:)`). Optional tags are appended as a last line `#a #b`, because tags are parsed from the text. |
| get | Metadata plus body as `markdown` (default), `text` (`NoteStore.plainText(for:)`), `html` (`HTMLWriter`) or `noteit-doc` (`DocConverter.export`). Markdown goes through `NoteItMarkdown` (`markdown-storage`) with its portable profile; there is no Markdown code of automation's own. |
| replace | Replaces the body through `editBody` with `versioning: .recordCurrent`, so `editBody` records the previous body in Version History exactly once (automation never records a version itself) and every replace can be undone from Version History; in an open editor it can also be undone with ⌘Z. Optional `ifRevision` gives optimistic concurrency. |
| append / prepend | Adds text at the end (default) or after the first line, through `editBody`. Separator: one newline. Optional `timestamp` prefixes the line with the time as 24-hour `HH:mm` in `en_US_POSIX`, the clock format of `DailyLogLine`. The appended run uses the editor font size. |
| set title | Replaces the text of the first line through `editBody`, keeping its attributes. |
| move, pin | Same as the UI (`moveNote`, `togglePin`). |
| delete | Moves to Recently Deleted (`moveToRecentlyDeleted`). Permanent deletion (`deleteNow`) is a separate admin-only operation. |
| restore | `recover` from Recently Deleted. |
| list / search | `NoteStore.notes(for:search:)` semantics today (all words match, case and accent folded). When `organise` ships ranked search, the same call returns ranked results with a `score`; the API shape doesn't change. |
| notebooks, tags | `sortedNotebooks`, `createNotebook`, `updateNotebook`, `deleteNotebook` (moves its notes to Recently Deleted, as in the UI); tags with counts from `NoteMeta.tags`, and the tag tree from `organise`. |
| attachments | List and read the attachments in a note body; add a file to the end of a note; stage an upload referenced from Markdown (`noteit-attachment:<id>`). |
| daily | Resolve or create the daily note with `NoteStore.dailyNote(for:createIfMissing:)`, and append with `DailyLogAppender` (both `linking`). Automation has no daily-note code of its own and no fallback. While `DailyNotes.isAvailable` (program §5) is false, these return `dailyNotesUnavailable` (`501 not_implemented` in the Local API); `linking` sets it to true when its daily-note UI ships. |

Rules for every write:

- Notes in Recently Deleted are read-only (`noteDeleted`). Notes whose body couldn't be read (`isBodyWriteBlocked`) refuse writes (`noteUnreadable`).
- Locked notes (`NoteMeta.isLocked`, `sync-security`) refuse every body read and write (`noteLocked`). Their title and metadata stay readable, with an empty preview.
- While the library is still loading, operations return `notReady`.
- Body changes go through `editBody`, which handles a note open in an editor (main window, floating note or cheat sheet), keeps undo working, and marks the note for saving. Automation doesn't call `handOverPendingEdits` or `updateBody` itself.
- Writes are normal local changes: they bump `revision`, post `noteItLocalChange` (edits through `editBody` and note creation or deletion also post `localNoteChange`) and sync like typing.
- Text limits: 1 MB of text per write (title, body and tags together, checked before any parsing), 25 MB per attachment (the same cap as Markdown import images).

Errors are one enum, `AutomationError`, mapped per surface: HTTP status + code (from `APIErrorCode`) for the Local API, `errorCode`/`errorMessage` for x-callback-url, a localized message for Shortcuts and the Share extension.

### 2. Change feed: `LibraryChangeFeed`

The Local API's events need "what changed". `LibraryChangeFeed` subscribes to `NoteStore.$notes` and `$notebooks`, coalesces for 250 ms, and diffs snapshots keyed by id (`NoteMeta` and `Notebook` are `Hashable`). It only observes the published arrays; it adds no hook to `NoteStore.swift`. Spotlight doesn't use it: body and metadata changes reach Spotlight through the `DerivedIndex` registry (§5). It emits `LibraryChange` values:

- notes: `created`, `updated` (body, title, pin or notebook changed), `deleted` (moved to Recently Deleted), `restored`, `purged` (gone for good);
- notebooks: `created`, `updated`, `deleted`.

Remote changes applied by sync show up too, because they change the same published arrays. The diff function is pure (`LibraryDiff.changes(from:to:)`) and unit tested.

### 3. URL scheme `noteit://`

Automation owns all `noteit://` routing. The scheme is registered in `Info.plist` (`CFBundleURLTypes`, scheme `noteit`) by `scripts/build_app.sh`. Links are handled by an Apple Event handler (`kInternetEventClass`/`kAEGetURL`) installed in `applicationWillFinishLaunching`, so SwiftUI never opens an extra window for a URL. The URL is parsed by a pure `URLCommand.parse(_:)` in `NoteItCore`, so the phone uses the same parser; on the phone, hosts that only work on the Mac show "This works in NoteIt for Mac". The command then runs through `AutomationService`.

| URL | Effect |
|---|---|
| `noteit://note/<UUID>` / `noteit://note/<UUID>?heading=<text>` | `URLCommand.note(id:heading:)`. The stored link between notes. Shows the note, scrolled to the heading when there is one. The grammar is `NoteItCore.NoteLink` (`linking`). |
| `noteit://note?title=<text>` (`&heading=` optional) | `URLCommand.noteTitle(title:heading:)`. A link to a note that may not exist yet. Shows the note with that exact title (case-insensitive, most recently edited first); if there is none, `linking`'s rules for missing link targets apply. |
| `noteit://new?title=&text=&notebook=&tags=a,b&open=1` | Create a note. `open=1` shows it; otherwise a capture notice says **Saved to <notebook>** (the existing `CaptureToast`). `inbox=<UUID>` imports a Share extension item instead (§10). |
| `noteit://append?id=…&text=&position=end\|start&timestamp=1` | Append to a note. `title=` instead of `id` matches an exact title (case-insensitive, most recently edited first). `daily=today` targets the daily note through `DailyLogAppender` (unavailable while `DailyNotes.isAvailable` is false). |
| `noteit://open?id=…` / `noteit://open?title=…` | An action that shows the note, the same as `noteit://note/<UUID>`. An unknown title opens the search field with the title typed. |
| `noteit://search?q=…` | Show the main window with that search. |
| `noteit://daily` | Open today's daily note (unavailable while `DailyNotes.isAvailable` is false; it shows **Daily notes aren't available in this version.**). |
| `noteit://settings?tab=integrations` | Open Settings on a tab. Accepts every raw value in the program's Settings table: `general`, `shortcuts`, `editor`, `sync`, `data`, `sharing`, `smart`, `integrations`, `plugins`, `about`. A tab that isn't in this build opens General. |

**Other hosts.** `URLRouteRegistry` (an app-target `@MainActor` class, built in foundations 5.4) has `register(host:handler:)`, which lets another sub-project own an extra host. The handler gets the whole URL, including the fragment. `sharing` registers `join`; `surfaces-polish` uses `noteit://` actions for floating notes and cheat sheets. The reserved core hosts are `new`, `append`, `open`, `note`, `search`, `daily`, `settings` and `x-callback-url` (the prefix for the callback forms below). Registering one of them, a host registered twice, or a host with characters outside `[a-z0-9-]` is a programming error caught by a unit test; `canRegister(host:)` checks this ahead of time. An unknown host shows **NoteIt doesn't know this link.**

x-callback-url: the same actions under `noteit://x-callback-url/<action>?…&x-success=&x-error=&x-cancel=`.

- `x-success` receives `id`, `title` and `url` (the `noteit://note/<UUID>` link). Links never return note text, so a page can't read notes through a callback.
- `x-error` receives `errorCode` (the `AutomationError` code, such as `not_found`) and `errorMessage`.
- `x-cancel` is called when the user answers **Don't Allow** to a confirmation.
- Callbacks with the scheme `http` or `https` never receive a note id, title or link: `x-success` is called with no added parameters, and `x-error` gets only `errorCode`.
- Callback URLs with the schemes `javascript`, `file`, `data` or `noteit` are ignored.

Safety:

- **Links that change notes ask first.** `new` shows **A link wants to create a note in “<notebook>”.** and `append` (by id, by title or to the daily note) shows **A link wants to add text to “<title>”.**, each with **Allow** and **Don't Allow**. Settings › Integrations › Links › **Allow links to change notes without asking** (off by default) skips the question.
- **Links that only open or show something never ask:** `open`, `note`, `search`, `daily` (open) and `settings`.
- **The Share extension's link doesn't ask.** `new?inbox=<UUID>` imports only an item that the Share extension wrote into the app group inbox after the user pressed **Save** (§10), so the user has already confirmed it. Any other `new` link asks as above.
- No URL action deletes, moves or overwrites anything.
- A link's parameter values (`text`, `title`, `notebook`, `tags` and the rest) are limited to 100 KB together.

### 4. Shortcuts actions (App Intents)

App Intents (available on macOS 13+, so fine for macOS 14). All intents run in-process through `AutomationService`. `openAppWhenRun` is false except for Open Note.

| Intent | Parameters | Result |
|---|---|---|
| Create Note | Title (optional), Text, Notebook (optional `NotebookEntity`), Show Note (bool, off) | `NoteEntity` |
| Append to Note | Note (`NoteEntity`), Text, Position (End/Start), Add Time (bool) | `NoteEntity` |
| Append to Daily Note | Text, Add Time (bool) | `NoteEntity`; appends through `DailyLogAppender`. Offered only while `DailyNotes.isAvailable` is true; before that it fails with "Daily notes aren't available in this version." |
| Open Note | Note | opens NoteIt |
| Find Notes | Search text, Notebook (optional), Limit (default 10) | `[NoteEntity]` |
| Get Note Text | Note, Format (Plain Text / Markdown) | `String` |

- `NoteEntity` exposes id, title, notebook name, tags, created and modified dates. Its query (`NoteEntityQuery`, an `EntityStringQuery`) searches with the same semantics as the note list and suggests the 10 most recent notes.
- `NotebookEntity` exposes id and name.
- `NoteItShortcuts: AppShortcutsProvider` registers "Create a note in NoteIt", "Search NoteIt" and "Add to a note in NoteIt".
- No destructive intents in this version.
- Notes in Recently Deleted are never returned. Locked notes are returned by title; Get Note Text and Append to Note fail with "That note is locked."

Build: SwiftPM doesn't run Xcode's App Intents metadata step. `scripts/build_app.sh` compiles the app with `-emit-const-values-path` and runs `xcrun appintentsmetadataprocessor` to write `Contents/Resources/Metadata.appintents`. A spike task (plan T19) proves this first. If it proves unworkable, the intents milestone is held back and `docs/known-limitations.md` says to use the `noteit://` links with Shortcuts' Open URLs action instead. Plugins then expose no intents either; their commands still appear in the Plugins menu and the palette and are only missing from Shortcuts and the Local API. Nothing else depends on App Intents.

### 5. Spotlight (Core Spotlight)

- `SpotlightIndexer` writes to `CSSearchableIndex(name: "notes")`. Each live note is one `CSSearchableItem`:
  - `uniqueIdentifier` = note UUID, `domainIdentifier` = notebook UUID (or `none`);
  - attributes: `title`, `contentDescription` (preview), `textContent` (plain text, first 20,000 characters, only when **Include note text** is on), `keywords` (tags), `contentCreationDate`, `contentModificationDate`, `contentType` `UTType.text`.
- Indexing runs off the main actor in batches of 100. Plain text is read on the main actor one note at a time and handed over, so a 5,000-note library never blocks typing for more than one note read.
- **A derived index.** `SpotlightIndexer` registers with organise's `DerivedIndex` registry like every other indexer (link index, image text, semantic index, tasks). `noteChanged` (a body change or a new note) reindexes the note, `noteRemoved` removes it (it is also called when a note is locked), `metadataChanged` (metadata-only changes, which never call `noteChanged`) reindexes or removes it after a pin, notebook move, tag change, move to Recently Deleted or restore from Recently Deleted, `rebuild` re-adds every note, and `flush` hands pending batches to Core Spotlight. Automation adds no hook to `NoteStore.swift`.
- Spotlight doesn't subscribe to `LibraryChangeFeed`; every change arrives through the registry hooks above. Notebook rename updates nothing (Spotlight shows the notebook only through the domain).
- Full rebuild when the setting is turned on, when **Rebuild Spotlight Index** is pressed, and when `spotlightIndexVersion` (UserDefaults, currently `1`) differs from the stored version.
- Turning **Show notes in Spotlight** off calls `deleteAllSearchableItems`.
- Opening a result arrives as an `NSUserActivity` of type `CSSearchableItemActionType`. `AppDelegate.application(_:continue:restorationHandler:)` reveals the note with `NoteStore.reveal(_:)`.
- Exclusions (`SpotlightItemBuilder.shouldIndex(_:)`): Recently Deleted; locked notes (`NoteMeta.isLocked`; locking a note removes its item through the registry); unbundled runs (`swift run`, no bundle identifier), where the indexer stays off.
- Spotlight is on by default and can be turned off in Settings › Integrations.
- Privacy: the Spotlight index is local to the Mac and to the user account. The footnote says: "Notes are added to this Mac's Spotlight index. They never leave your Mac."

### 6. Local API

#### 6.1 Server

- An HTTP/1.1 server on `127.0.0.1` only, built on Network.framework (`NWListener` with `requiredLocalEndpoint` 127.0.0.1). No third-party dependencies; the request parser is small and fuzz-tested.
- Off by default (`localAPIEnabled = false`). Turning it on starts the listener at once; turning it off stops it, closes open connections and removes the port from the discovery file.
- Binding to loopback doesn't trigger the macOS firewall or Local Network prompt. The app isn't sandboxed (`Resources/NoteIt.entitlements` has only Apple Events), so no new entitlement is needed.
- **Port:** default `47600`. If taken, NoteIt tries `47601`…`47609` and uses the first free one. **Port** in Settings can pin a fixed port (1024–65535); a pinned port that's taken shows **Port 47600 is in use by another app** and the API stays off.
- Keep-alive, request bodies with `Content-Length` only (chunked request bodies get `411`), headers at most 16 KB, idle connections closed after 30 s, at most 32 open connections.
- Request handling runs inside `ProcessInfo.performActivity(options: .userInitiatedAllowingIdleSystemSleep)` so App Nap doesn't stall requests while NoteIt is hidden.
- Logging uses `os.Logger` category `LocalAPI` with method, route pattern (not the concrete path or query), status and duration. Never bodies, query strings, tokens or note text.

#### 6.2 Discovery

The discovery file lets local clients find the port without guessing:

- Location: `~/Library/Application Support/NoteIt/local-api.json`. With `NOTEIT_DATA_DIR` set, `<NOTEIT_DATA_DIR>/local-api.json`. It is independent of where the library lives, so it never lands in a Markdown library's content folder.
- Written atomically with mode `0600` at launch and whenever the API is turned on or off; deleted at quit.
- Contents:

```json
{"version":1,"pid":4312,"appVersion":"0.3.0","apiEnabled":true,"port":47600,"baseURL":"http://127.0.0.1:47600/v1","startedAt":"2026-10-19T07:42:55.365Z"}
```

- `apiEnabled: false` has no `port` or `baseURL`. The file never contains a token.
- A file whose `pid` isn't running (`kill(pid, 0)` fails) is stale and ignored.
- Browsers can't read files, so the extension probes `GET /v1/ping` on 47600–47609.

#### 6.3 Versioning

- All routes live under `/v1`. Within v1, changes are additive only: new routes, new optional request fields, new response fields. Clients must ignore unknown fields.
- `GET /v1/ping` returns `capabilities` so clients can detect optional parts (`daily`, listed only while `DailyNotes.isAvailable` is true, `events`, `attachments`, and those other sub-projects add, such as `meaning-search` or `web-clipper`). Names are kebab-case. Other sub-projects add theirs with `LocalAPIRouteRegistry.addCapability(_:)` and take them away with `removeCapability(_:)`; `ping` lists only the capabilities current at the time of the request. The field is not called `features`, which belongs to the sync manifest.
- A breaking change means `/v2`, served alongside `/v1` for at least two minor app releases.
- `GET /v1/openapi.json` serves the OpenAPI 3.1 document, generated from the same route table, and is the reference for `private-ai`, `web-clipper` and `plugins`.

#### 6.4 Auth, tokens and scopes

- Every route except `GET /v1/ping`, `GET /v1/openapi.json`, `POST /v1/pair/start` and `POST /v1/pair/complete` needs `Authorization: Bearer <token>`.
- Token format: `nit_` + 32 random bytes (`SecRandomCopyBytes`) as base64url without padding, 47 characters in all. Shown once, never stored in clear by the app.
- Scopes (cumulative; `write` includes `read`, `admin` includes both):

| Scope | Allows |
|---|---|
| `read` | All `GET` routes and the event stream |
| `write` | Create, edit, append, move, pin, delete to Recently Deleted, restore, notebooks, attachments upload, daily note create/append |
| `admin` | Permanent delete (`?permanent=true`), empty Recently Deleted, list and revoke clients |

- **Storage.** The app keeps one Keychain generic password, service `io.github.rutbergphilip.noteit.local-api` (`AppIdentity.localAPIKeychainService`), account `clients`, holding a JSON array of `ClientRecord`: `id`, `name`, `kind` (`cli`, `extension`, `mcp`, `script`), `scopes`, `origin` (extension origin, `safari-web-extension:<bundle id>` for Safari, or null), `tokenHash` (SHA-256 hex), `tokenHint` (first 8 characters), `createdAt`. There is no `plugin` kind: plugins never hold tokens. Tokens are verified by hashing and constant-time comparison. `lastUsedAt` is kept in UserDefaults (`localAPIClientLastUsed`, written at most once a minute per client) to avoid Keychain writes on every request.
- **In-process clients.** Code inside the app manages clients through `AutomationService.clients` (`issue`, `list`, `revoke`), without pairing over HTTP. Settings › Integrations, `private-ai`'s AI apps sheet and `web-clipper` use it.
- **Origin binding.** A token issued to a request that had an `Origin` header is bound to that origin. A bound token is accepted only with the same `Origin`. An unbound token (CLI, scripts, MCP) is rejected when any `Origin` header is present. A stolen extension token can't be used from a web page, and a CLI token can't be used from a browser.
- **Safari is bound by scheme and bundle id.** Safari gives a web extension a new origin host between launches, so the host can't be used. A Safari extension sends its bundle identifier in `X-NoteIt-Extension-Bundle` on every request (for example `io.github.rutbergphilip.noteit.clipper`). A token issued to a `safari-web-extension://…` origin is stored with `origin` `safari-web-extension:<bundle id>` and accepted only when the `Origin` has the `safari-web-extension` scheme and the header equals the stored bundle id. A Safari request without the header, or with another bundle id, gets `401 unauthorized`. Chrome and Firefox tokens stay bound to the full origin and ignore the header. Web page origins are still refused before auth (6.6).
- **Revoke.** Settings › Integrations lists every client: name, kind, scopes, last used, and a **Revoke** button. **Revoke All…** asks first. Revoking removes the record, closes that client's event streams with a final `revoked` event, and its next request gets `401 token_revoked`.
- **New Token…** in Settings creates a token for scripts and `curl`. The sheet asks for a name and scopes, then shows the token once with **Copy** and the note "You won't see this token again."

#### 6.5 Pairing

1. The client calls `POST /v1/pair/start` with `{"clientName":"noteit CLI on Studio","kind":"cli","scopes":["read","write"]}`.
2. NoteIt comes to the front and shows the pairing window: **“noteit CLI on Studio” wants to read and change your notes.** Below it is a large code such as **482 913**, the requested scopes and, for extensions, the origin (`chrome-extension://abcd…`, or `safari-web-extension` with the bundle id for Safari). Buttons: **Deny** and, under a disclosure, scope checkboxes to grant less than requested.
3. The response is `{"pairingID":"…","expiresAt":"…"}`. The client asks the user to type the code shown in NoteIt.
4. The client calls `POST /v1/pair/complete` with `{"pairingID":"…","code":"482913"}` and gets `{"token":"nit_…","clientID":"…","scopes":["read","write"]}`. The window closes and shows **Paired with “noteit CLI on Studio”** for 3 seconds.

Rules:

- Codes are 6 random digits from `SecRandomCopyBytes`, valid for 120 seconds. One pairing at a time; a second `start` while one is open gets `409 pairing_in_progress`.
- 5 wrong codes cancel the pairing (`403 pairing_failed`), and the window says **Pairing cancelled after too many wrong codes**.
- Pairing works only while the API is on. Deny gives `403 pairing_denied`.
- Requests with an extension `Origin` can get at most `write`; `admin` is dropped and the window says so.
- A `pair/start` from a `safari-web-extension` origin must send `X-NoteIt-Extension-Bundle` (reverse-DNS, at most 255 characters); without it the request gets `400 bad_request`. `pair/complete` must send the same value.
- `kind` and `clientName` are shown to the user as given (max 64 characters, control characters removed). The window always shows the origin (and, for Safari, the bundle id) for browser clients, because the name is client-supplied.

#### 6.6 Browser rules (CORS and request checks)

Checked before routing, in this order:

1. **Host.** `Host` must be `127.0.0.1:<port>` or `localhost:<port>`. Anything else gets `421` (DNS rebinding protection).
2. **Origin.** No `Origin` header is allowed (CLI and native clients). An `Origin` with scheme `chrome-extension`, `moz-extension` or `safari-web-extension` is allowed. Any other origin, including `null`, `http` and `https`, gets `403 origin_not_allowed` with no CORS headers.
3. **Preflight.** `OPTIONS` from an allowed origin returns `204` with `Access-Control-Allow-Origin: <origin>` (echoed, never `*`), `Access-Control-Allow-Methods: GET, POST, PATCH, DELETE`, `Access-Control-Allow-Headers: Authorization, Content-Type, If-Match, X-NoteIt-Filename, X-NoteIt-Extension-Bundle`, `Access-Control-Max-Age: 600`, `Vary: Origin`. Actual responses repeat `Access-Control-Allow-Origin` and `Vary`. No credentials mode (tokens travel in the header, not cookies).
4. **Content type.** Routes with a JSON body require `Content-Type: application/json` (`415` otherwise). This forces a preflight for any browser request.
5. **Auth and origin binding** (6.4).

#### 6.7 Rate limits and sizes

Token buckets per client (by token; unauthenticated routes share one global bucket):

| Bucket | Rate | Burst |
|---|---|---|
| All requests | 10/s | 60 |
| Writes | 2/s | 20 |
| Attachment uploads | 30/min | 10 |
| Unauthenticated (`ping`, `pair/*`, `openapi.json`) | 30/min | 10 |

- Over the limit: `429` with `Retry-After` (seconds) and `{"error":{"code":"rate_limited"}}`.
- JSON request body max 2 MB (`413`), attachment body max 25 MB, staged uploads max 20 at a time and 100 MB in total, each kept for 1 hour or until quit.
- Event streams: at most 4 per client, 16 in total.
- List and search: `limit` default 50, max 500.

#### 6.8 Conventions

- JSON in and out, UTF-8, `camelCase` keys. Dates are ISO 8601 UTC with milliseconds. Ids are UUID strings (accepted in any case, returned uppercase like `UUID.uuidString`).
- Errors: `{"error":{"code":"not_found","message":"No note with that id."}}`. Codes: `bad_request` 400, `unauthorized` 401, `token_revoked` 401, `forbidden_scope` 403, `origin_not_allowed` 403, `read_only` 403 (a note in a shared notebook the user can only read), `pairing_denied` 403, `pairing_failed` 403, `not_found` 404, `note_deleted` 409, `note_unreadable` 409, `editor_required` 409 (plugins only: the change needs an open editor), `pairing_in_progress` 409, `cursor_expired` 410, `length_required` 411, `revision_mismatch` 412, `too_large` 413, `unsupported_media_type` 415, `misdirected` 421, `note_locked` 423 (any body read or write of a locked note), `rate_limited` 429, `internal` 500, `not_implemented` 501 (not built into this version yet: daily notes while `DailyNotes.isAvailable` is false, the tag tree before `organise` registers it, a body format before its sub-project ships), `not_available` 501 (built but turned off, such as a search mode), `not_ready` 503 (the library is still loading), `api_disabled` 503 (sent only on connections still open while the API turns off).
- Every error, including those from routes other sub-projects register, uses a code from `APIErrorCode` in this nested body. A sub-project that needs a new code adds it here first.
- Concurrency: `PATCH /v1/notes/{id}` accepts `If-Match: "<revision>"`. A different current revision gives `412 revision_mismatch` with the current note in the body. Notes created before sync existed get revisions assigned on API start (`assignMissingRevisions`).
- Pagination: `cursor` is opaque; responses have `nextCursor` (null at the end). Order is the note list order (pinned first, then last edited). The cursor holds the sort position (pinned, last edited to the millisecond, id) of the last note on the page, and the next page starts after that position, so a note edited, moved or deleted between pages never makes another note repeat or go missing.

#### 6.9 Resources

```json
// NoteSummary
{"id":"…","title":"Groceries","notebookID":"…","notebookName":"Inbox","tags":["home"],"pinned":false,
 "createdAt":"…","updatedAt":"…","revision":"…","deletedAt":null,"preview":"Milk, eggs…",
 "conflict":false,"locked":false,"url":"noteit://note/…"}
// Note = NoteSummary + {"format":"markdown","body":"# Groceries\n\n- Milk"}
// Notebook (parentID and path are organise's fields, filled through NotebookDTOExtending (6.11); absent until organise registers)
{"id":"…","name":"Inbox","symbol":"tray","color":"#4A90D9","sortIndex":0,"noteCount":12,"parentID":null,"path":["Inbox"]}
// Tag
{"name":"home","noteCount":4}
// TagNode (GET /v1/tags?tree=1; noteCount = notes with exactly this tag, totalCount = notes with it or a descendant, each note once)
{"name":"work","path":"work","noteCount":6,"totalCount":9,"children":[{"name":"clients","path":"work/clients","noteCount":3,"totalCount":3,"children":[]}]}
// SearchResult (score and highlights are optional)
{"note":NoteSummary,"snippet":"…","score":0.82,"highlights":[{"field":"body","ranges":[[12,7]]}],"matchedBy":["keyword"]}
// Change
{"cursor":"9F2C…:118","kind":"note","id":"…","op":"updated","at":"…"}
// Client
{"id":"…","name":"noteit CLI on Studio","kind":"cli","scopes":["read","write"],"origin":null,
 "tokenHint":"nit_k3Jd","createdAt":"…","lastUsedAt":"…"}
```

- `url` is always the `noteit://note/<UUID>` form. MCP resources and sharing print the same form.
- A locked note (`locked: true`) keeps its title and metadata, has an empty `preview`, and matches search by title only. Any body read or write returns `423 note_locked`.
- `highlights` is a list of `{field, ranges}`. `field` is `title` or `body`; `ranges` are `[start, length]` pairs in UTF-16 code units, sorted and not overlapping, into the note title for `title` and into `snippet` for `body`. `organise`'s ranker fills `score` and `highlights`; keyword search before it ships leaves both out. `private-ai` adds `matchedBy` for its modes.

#### 6.10 Endpoints (frozen for v1)

| Method and path | Scope | Purpose |
|---|---|---|
| `GET /v1/ping` | none | `{"name":"NoteIt","apiVersion":1,"appVersion":"0.3.0","capabilities":[…]}` |
| `GET /v1/openapi.json` | none | OpenAPI document |
| `POST /v1/pair/start` | none | Begin pairing (6.5) |
| `POST /v1/pair/complete` | none | Exchange code for token |
| `GET /v1/me` | read | The calling client (`Client`) |
| `DELETE /v1/me` | read | Revoke the calling token (logout) |
| `GET /v1/notes` | read | List. Query: `notebook` (id or name), `tag`, `q`, `updatedSince`, `deleted=only\|include`, `sort=list\|updated` (`list` = pinned first, then last edited; `updated` = last edited only), `limit`, `cursor` |
| `POST /v1/notes` | write | Create. Body: `title?`, `body`, `format` (`markdown` default, `text`, `noteit-doc`), `notebookID?` or `notebook?`, `tags?`, `pinned?`. `201` + `Note` |
| `GET /v1/notes/{id}` | read | One note. Query: `format` (`markdown`, `text`, `html`, `noteit-doc`). `423 note_locked` for a locked note |
| `PATCH /v1/notes/{id}` | write | Any of `title`, `body`+`format`, `notebookID`, `pinned`. `If-Match` optional |
| `DELETE /v1/notes/{id}` | write | Move to Recently Deleted. `?permanent=true` needs admin and works only on notes already in Recently Deleted |
| `POST /v1/notes/{id}/restore` | write | Recover from Recently Deleted |
| `POST /v1/notes/{id}/append` | write | Body: `text`, `format` (`text` default, `markdown`), `position` (`end`, `start`), `timestamp` (bool), `ifRevision?` (`412 revision_mismatch` with the current note on mismatch) |
| `POST /v1/notes/{id}/open` | read | Bring NoteIt to the front with the note selected. `204` |
| `GET /v1/notes/{id}/attachments` | read | `[{"name":"photo.jpg","contentType":"image/jpeg","size":81234}]` |
| `GET /v1/notes/{id}/attachments/{name}` | read | Raw bytes with `Content-Type` |
| `POST /v1/notes/{id}/attachments` | write | Raw body; `Content-Type` and `X-NoteIt-Filename`. Added at the end of the note. Images show inline, other files as a file icon |
| `POST /v1/attachments` | write | Stage an upload: raw body, same headers. Returns `{"id":"att_…","expiresAt":"…"}`; Markdown in create/replace/append may use `![alt](noteit-attachment:att_…)` |
| `DELETE /v1/trash` | admin | Empty Recently Deleted |
| `GET /v1/search` | read | `q` (required), `notebook`, `tag`, `limit`, `mode=keyword` (default). Other modes are added with `registerSearchMode` (6.11); `private-ai` adds `meaning` and `hybrid`. An unknown mode returns `400 bad_request`; a mode that is turned off returns `501 not_available`. `{"mode":"keyword","results":[SearchResult]}`; snippet is up to 160 characters around the first match |
| `GET /v1/notebooks` | read | `{"notebooks":[Notebook],"defaultNotebookID":"…"}` in sidebar order; `defaultNotebookID` is the New Notes notebook (null for none). Each notebook has `parentID` and `path` once `organise` registers its `NotebookDTOExtending` (6.11; organise owns those fields) |
| `POST /v1/notebooks` | write | `name`, `symbol?`, `color?`. `201` + `Notebook` |
| `PATCH /v1/notebooks/{id}` | write | `name`, `symbol`, `color` |
| `DELETE /v1/notebooks/{id}` | write | Delete; its notes go to Recently Deleted, as in the app |
| `GET /v1/tags` | read | `[Tag]`, sorted by name. `?tree=1` returns `[TagNode]` from the provider `organise` registers with `extendTags(treeProvider:)` (6.11); `501 not_implemented` while none is registered. The plain list doesn't change |
| `GET /v1/daily` | read | Query `date=YYYY-MM-DD` (default today), `create=true` (needs write), `format` (`plain` or `markdown`, default `markdown`). Returns `Note`. `404` if none and not created; `501 not_implemented` while `DailyNotes.isAvailable` is false |
| `POST /v1/daily/append` | write | `{text, timestamp?, date?, format?}`; `format` is `plain` (default) or `markdown`. Plain text is passed as `.plain(text)`; Markdown is parsed with the existing importer (`NoteItMarkdown` + `DocConverter`) into `.attributed(…)`. Either is appended with `DailyLogAppender.append(_:timestamp:to:in:now:)` (`DailyLogContent`, `timestamp: Bool = true`, `now: Date = Date()`), which writes `- HH:mm text` (24-hour, `en_US_POSIX`) when `timestamp` is true (the default). Creates the daily note if needed. `501 not_implemented` while `DailyNotes.isAvailable` is false |
| `GET /v1/changes` | read | `since=<cursor>`, `limit` (max 500). Without `since`, returns no changes and the current cursor. `{"changes":[Change],"cursor":"…","hasMore":false}` |
| `GET /v1/events` | read | Server-Sent Events of the same `Change` objects (`event: change`, `id: <cursor>`). Accepts `Last-Event-ID`. Comment heartbeat every 15 s. `event: revoked` before closing a revoked client |
| `GET /v1/clients` | admin | `[Client]` |
| `DELETE /v1/clients/{id}` | admin | Revoke a client |

Change cursors are `<bootID>:<seq>`. The app keeps the last 5,000 changes in memory per launch. A cursor from an earlier launch or older than the buffer gets `410 cursor_expired`; the client then re-lists with `updatedSince`. Changes are never persisted, so the feed stores no note content.

`POST /v1/notes/{id}/open` is the only UI route. Other UI actions (show a search, open Settings, floating notes and cheat sheets from `surfaces-polish`) use `noteit://` links.

#### 6.11 Routes from other sub-projects

Other sub-projects add routes without touching the server core:

- `LocalAPIRouteRegistry` lives in `NoteItAPI` (`Sources/NoteItAPI/Server/`) and is created in foundations (5.2). Sub-projects call `LocalAPIRouteRegistry.shared.register(_ spec: RouteSpec, handler:)` at launch. The spec gives a route id `<slug>.<name>` (for example `web-clipper.clip`), method, path under `/v1`, an explicit scope, rate-limit bucket and body limit (default 2 MB for JSON, at most 60 MB).
- `registerSearchMode(_ name: String, handler:)` adds a `mode` to `GET /v1/search`. The handler returns `SearchResult`s or an `APIErrorCode` (`not_available` while the mode is turned off).
- `addCapability(_ name: String)` adds a kebab-case name to `ping`'s `capabilities`; `removeCapability(_ name: String)` takes it away again (idempotent), for features the user can turn off.
- `extendTags(treeProvider:)` registers the one provider of the tag tree for `GET /v1/tags?tree=1` (`organise`). A second provider is a programming error.
- `extendNotebooks(with:)` registers a `NotebookDTOExtending`, which fills extra fields of each `Notebook` before it is sent (`organise`: `parentID` and `path`). Extenders run in registration order on the main actor.
- Registered routes go through the same pipeline: Host and Origin checks, CORS, auth, origin binding, scopes, rate limits, error body. Errors use `APIErrorCode` only. They appear in `openapi.json`.
- Path conflicts with an existing route, duplicate route ids and duplicate search modes are programming errors caught by a unit test over the full route table.
- A "needs from automation" list is not enough: the owning plan has a task that registers its route.
- Known additions: `POST /v1/clips` (`web-clipper`, 60 MB, write); the `meaning` and `hybrid` search modes (`private-ai`); `/v1/smart-folders` and `/v1/smart-folders/{id}`, tag and notebook changes, tasks, plus the tag tree provider and the notebook extender (`organise`).

### 7. The `noteit` command

- A separate SwiftPM executable target, `NoteItCLI`, created as a stub in foundations (5.1) and depending on `NoteItAPI` only (wire types and HTTP client; it brings `NoteItCore` and `NoteItSync`, for `AppIdentity` and `AppEnvironment`). Automation builds out the commands in wave 1 without the `mcp` subtree. `private-ai` adds the `NoteItMCP` dependency and `noteit mcp` in wave 2. The executable is renamed when bundled, because `noteit` and `NoteIt` would collide on a case-insensitive disk in `.build` and in `Contents/MacOS`. The CLI ships at `NoteIt.app/Contents/Helpers/noteit`: automation adds that row to the embeds table in `scripts/build_app.sh`, which signs it inside-out before the app.
- No argument-parsing dependency; a small hand-written parser keeps Sparkle the only third-party package.
- Install:
  - **Settings › Integrations › Command line tool › Install…** symlinks `/usr/local/bin/noteit` to the bundled binary. If `/usr/local/bin` isn't writable, macOS asks for an administrator password (`do shell script … with administrator privileges`). Status shows **Installed at /usr/local/bin/noteit** with **Uninstall**, or **Points to another copy of NoteIt** with **Fix**.
  - Homebrew: `growth` adds the cask's `binary` line pointing at `Contents/Helpers/noteit`.
- Finding the app:
  1. `NOTEIT_API_URL` if set.
  2. Otherwise the discovery file (6.2).
  3. No file or a stale `pid`: run `/usr/bin/open -g -b io.github.rutbergphilip.noteit` (launch in the background) and poll the discovery file and `GET /v1/ping` every 200 ms for up to 10 s. `--no-launch` disables this.
  4. `apiEnabled: false`: print "The Local API is off. Turn it on in NoteIt › Settings › Integrations." and, for `noteit auth login` in a terminal, open `noteit://settings?tab=integrations`. Exit code 3.
- Token: `NOTEIT_TOKEN` if set, else the Keychain item service `io.github.rutbergphilip.noteit.cli`, account = the profile name (`default`; `--profile NAME` or `NOTEIT_PROFILE` picks another). Profile names are 1–32 characters of `[a-z0-9-]`. Names matching `mcp(-[a-z0-9]+)*` are the ones `noteit mcp` uses for its own tokens; `--profile` refuses them. The item is created by the bundled `noteit` binary, so the same binary reads it later without a prompt, also when another app launches it. `noteit auth login` runs the pairing flow (scopes `read,write` by default, `--scopes` to change) and prompts "Enter the code shown in NoteIt:". `noteit auth logout` calls `DELETE /v1/me` and removes the item. `noteit auth status` prints the client and scopes.
- Commands:

| Command | Does |
|---|---|
| `noteit new [TEXT\|-] [--title T] [--notebook N] [--tag t]… [--open]` | Create; prints the id. Reads stdin when TEXT is `-` or stdin is piped |
| `noteit append (ID \| --title T \| --today) [TEXT\|-] [--start] [--time]` | Append |
| `noteit show ID [--format markdown\|text\|html]` | Print the body |
| `noteit list [--notebook N] [--tag t] [--limit n]` | One line per note: id, updated, title |
| `noteit search QUERY [--limit n]` | Results with snippets |
| `noteit edit ID` | Opens `$VISUAL`/`$EDITOR` (default `vi`) on the Markdown, then `PATCH` with `If-Match`. On `412` it saves your text as a new note titled "<title> (edited in terminal)" and says so |
| `noteit rm ID [--permanent]` | Move to Recently Deleted (or delete for good, admin) |
| `noteit open ID` | `open noteit://note/ID` |
| `noteit notebooks`, `noteit tags` | Lists |
| `noteit attach ID FILE` | Upload an attachment |
| `noteit today [TEXT\|-]` | Print today's daily note, or append to it. Like `noteit append --today`, it prints "Daily notes aren't available in this version." and exits 1 while `DailyNotes.isAvailable` is false |
| `noteit watch` | Stream changes as JSON lines |
| `noteit api METHOD PATH [--data JSON\|@file]` | Raw request for scripting |
| `noteit auth login\|logout\|status`, `noteit status`, `noteit --version`, `noteit help [COMMAND]` | Housekeeping |
| `noteit mcp …` | The whole `mcp` command tree belongs to `private-ai` (wave 2); automation only reserves the name. In wave 1 it prints "noteit mcp isn't in this version of NoteIt." and exits 2 |

- `--json` on any read command prints the API JSON unchanged. Exit codes: 0 ok, 1 error, 2 usage, 3 app not reachable or API off, 4 not paired or token revoked, 5 not found, 6 revision conflict.

### 8. Settings › Integrations

The **Integrations** tab, position 8 in the program's frozen Settings table, after Smart Features and before Plugins (`SettingsView.Tab.integrations`, raw value `integrations`, symbol `point.3.connected.trianglepath.dotted`). Wave 0 adds the case with `isAvailable` false; automation fills in the view and sets `isAvailable` to true. It holds the Local API, the command line tool, Spotlight, and connected apps, including MCP clients and the web clipper. Other sub-projects add their sections here (for example `web-clipper`'s Web Clipper section).

| Section | Controls |
|---|---|
| Local API | **Allow apps on this Mac to use NoteIt** (off). Status line: **On — 127.0.0.1:47600** or **Off**. **Port:** Automatic / a number. Footnote: "Apps you pair can read and change notes through a connection that only this Mac can reach." |
| Connected apps | Every client from `AutomationService.clients` (CLI, MCP clients, the web clipper, scripts). List: name, kind icon, scopes, "Last used 2 min ago", **Revoke**. Buttons **New Token…** and **Revoke All…**. Empty state: "No apps are paired. Apps ask to pair, and NoteIt shows a code to confirm." |
| Command line tool | Status, **Install…** / **Uninstall**, footnote "Also available with Homebrew: brew install --cask noteit". |
| Links | **Allow links to change notes without asking** (off). Footnote: "Links from other apps that create or add to a note ask first. Links that only open something never ask." |
| Share | Footnote: "Share → NoteIt saves text, links and images from any app as a new note. Turn it on in System Settings › Extensions › Sharing." |
| Spotlight | **Show notes in Spotlight** (on), **Include note text** (on), **Rebuild Spotlight Index**. |

UserDefaults keys (in `PrefKey`): `localAPIEnabled`, `localAPIPort` (0 = automatic), `localAPIClientLastUsed`, `urlSchemeChangesWithoutAsking` (false), `spotlightEnabled`, `spotlightIncludesText`, `spotlightIndexVersion`.

### 9. Menu and command palette

- Edit menu, after Copy as Markdown: **Copy Note Link** (⌃⌘L), a new `MenuShortcutCommand.copyNoteLink`, so it can be changed in Settings › Shortcuts. It copies `noteit://note/<UUID>`, built with `NoteItCore.NoteLink`. It is the only Copy Note Link command; `linking`'s context menu and palette entry call it. Automation updates `MenuShortcutRules` and `docs/keyboard-shortcuts.md` in the same task.
- Palette commands: **Copy Note Link**, **Install Command Line Tool…**, **Integrations Settings…**, **Turn Local API On** / **Turn Local API Off**.
- No new global hotkeys.

### 10. Mac Share extension

"Share → NoteIt" from any Mac app saves what's shared as a new note.

- **What it accepts:** plain text, URLs (with the page title when the host app gives one) and images (up to 10, 25 MB each). Text is capped at 1 MB. Other files aren't offered in this version.
- **The sheet:** a small compose sheet with a **Title** field (filled from the shared title or the first line of text), a preview of what will be saved, and **Cancel** / **Save**. The note goes to the New Notes notebook.
- **How it reaches the app:** the extension is sandboxed and never opens the library. It writes one item into a share inbox in the app group container (`<group>/share-inbox/<UUID>/`: the images first, then `item.json` last), then opens `noteit://new?inbox=<UUID>` (it needs no confirmation, §3). If NoteIt isn't running, that launches it. At launch and on that link, NoteIt imports every complete item through `AutomationService.create` and `addAttachment`, waits for `NoteStore.persistNow` to report the note on disk, and only then deletes the item. If saving to disk fails the item stays, as a failed item (below), and a retry saves the note it already made instead of making a second one. Incomplete items (no `item.json`, left by an interrupted share) older than 7 days are removed. Complete items are never removed by age: one whose import fails stays in the inbox until it imports or the user deletes it, and it shows in the existing failure notice (**Couldn't save a shared item.** with **Show in Finder**).
- **The note:** bold title line, the text, then the link (`<title>` linked to the URL), then the images inline. It doesn't ask for confirmation, because the user already pressed **Save** in the sheet.
- **Build:** like the Safari extension. A script compiles it with `xcrun swiftc` into `Contents/PlugIns/NoteItShare.appex`; `Package.swift` lists the target only so it type-checks. The appex is a row in the embeds table with its own entitlements (App Sandbox, the app group). The app gains the same app group entitlement. The app group needs a Team ID, so ad-hoc builds (no Team ID) skip the appex: its source isn't built, so the embeds table skips its row with a log line, the app gets no app group entitlement and `noteit://new?inbox=` reports **NoteIt doesn't know this link.**
- **Errors:** if NoteIt can't save the item, the next launch shows **Couldn't save a shared item.** with **Show in Finder**.

### 11. Privacy

- The Local API listens only on 127.0.0.1, is off by default, and refuses web page origins. Other user accounts on the same Mac can connect to loopback, which is why every route except ping and pairing needs a token, and pairing needs someone at this Mac's screen to read the code.
- No request content, query string or token is logged.
- Spotlight data stays in the local Spotlight index; links never return note text and give `http(s)` callbacks no id or title; Shortcuts actions run in-process; the Share extension hands items over through a folder only NoteIt and the extension can read.
- The `sync-security` network inventory lists the Local API listener as "loopback only, off by default".

## Dependencies

- **foundations (program design §2):** step 5, from this spec: the `NoteItAPI` target with the wire types, `HTTPMessage`, `ClientRecord`, the `NoteItAPITests` target and the `NoteItCLI` stub (5.1), `LocalAPIRouteRegistry` (5.2), `NoteLink`, `URLCommand` and `AppendPosition` in `NoteItCore` (5.3), `URLRouteRegistry` (5.4) and the embeds table (5.5); `NoteItCore`, `NoteItDoc` and `DocConverter`; `NoteBodyStorage`, `NoteStore.editBody`, the `DerivedIndex` registry, `NoteMeta.isLocked`, the daily-note seams and the `DailyNotes.isAvailable` gate (step 4); the frozen Settings, menu and shortcut tables (step 6).
- **markdown-storage:** `NoteItMarkdown` (`MarkdownCodec`) for every Markdown read and write in the Local API, the CLI and Shortcuts. Automation has no Markdown converter of its own. Automation goes through `NoteStore` and `NoteBodyStorage`, so it works with either library format.
- **linking:** owns the shape of `NoteItCore.NoteLink` (the `noteit://note` grammar used by `URLCommand` and Copy Note Link; built in foundations 5.3); the behaviour of `NoteStore.dailyNote(for:createIfMissing:)` and `DailyLogAppender`, which format lines with `DailyLogLine`; and setting `DailyNotes.isAvailable` to true. While it is false, the daily routes return `501 not_implemented`, and `noteit today`, `noteit append --today`, `noteit://daily`, `noteit://append?daily=today` and the Append to Daily Note intent are unavailable. Linking's Copy Note Link entries call automation's command.
- **organise:** `NoteStore.editBody` and `DerivedIndex` (built in foundations); ranked search (`score`, `highlights`), the tag tree for `GET /v1/tags?tree=1` (through `extendTags(treeProvider:)`), notebook `parentID` and `path` (through `NotebookDTOExtending`), and its own routes (smart folders, tags, notebooks, tasks), which it registers through 6.11.
- **sync-security:** owns locked notes. Automation follows its rules: `locked` on `NoteSummary`, `423 note_locked` for bodies, locked notes left out of Spotlight. The `sync-security` network inventory lists the Local API listener.
- **Consumers of the Local API:** `private-ai` (wave 2: `noteit mcp` and the `NoteItMCP` dependency of `NoteItCLI`, `NoteItAPIClient`, `mcp` profiles, the `meaning` and `hybrid` search modes, `AutomationService.clients` for its setup sheet), `web-clipper` (pairing with an extension origin, `X-NoteIt-Extension-Bundle` from its Safari build, `POST /v1/clips` through 6.11, `open`, notebooks with `defaultNotebookID`, the `web-clipper` capability), `organise` (routes above). New routes go through 6.11 and stay additive within `/v1`.
- **Other `noteit://` users:** `sharing` registers the `join` host and `surfaces-polish` its actions through `URLRouteRegistry`; `mobile` uses `URLCommand` from `NoteItCore`; `capture-plus`'s Append to Today panel calls `DailyLogAppender` in-process.
- **plugins:** no Local API tokens; plugins use their host protocol. If App Intents ship, plugins may expose intents; if the spike fails, they don't, and plugin commands stay in the Plugins menu and the palette, missing only from Shortcuts and the Local API.
- **growth:** the Homebrew cask `binary` line for `Contents/Helpers/noteit`.

## Non-goals

- Listening on anything other than 127.0.0.1, remote access, TLS, or IPv6 loopback.
- OAuth, accounts, or token expiry. Tokens live until revoked.
- A JavaScript or AppleScript dictionary (AppleScript `sdef`) in this version.
- Destructive URL actions or destructive Shortcuts actions.
- Webhooks that call out of the Mac. Scripts subscribe to `/v1/events` instead.
- Spotlight's `IndexedEntity` (macOS 15 only) and interactive widgets.
- Running the CLI against NoteIt on another Mac.
- Appending shared items to an existing note, and sharing arbitrary files, in the Share extension.

## Open questions

1. **Default port.** Default: `47600` with fallback to `47609`. Unregistered with IANA and unused by common developer tools.
2. **Include note text in Spotlight by default?** Default: on, because the index is local and it's what Apple Notes does. Locked notes are never indexed.
3. **Extension tokens with `admin`.** Default: never granted to browser origins, even if requested.
4. **App Intents metadata without Xcode.** Default: generate it in `scripts/build_app.sh` with `appintentsmetadataprocessor`; if the spike (T19) fails, ship everything else and document links as the Shortcuts route.
5. **Token expiry.** Default: none; revocation only, with "Last used" shown so unused clients are easy to spot.
6. **`/usr/local/bin` on Apple Silicon.** Default: still `/usr/local/bin` (on the default `PATH` in macOS), creating it with administrator rights if missing.
7. **Share extension hand-over.** Default: the app group container inbox (§10). It needs a Team ID, so ad-hoc builds have no Share extension.
