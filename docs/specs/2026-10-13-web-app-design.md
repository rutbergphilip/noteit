# NoteIt Web — Self-Hostable Web App Design

Status: proposed · Date: 2026-10-13 · Companion plan: `docs/plans/2026-10-13-web-app.md`

## 1. Goal

Ship a **self-hostable NoteIt web app** (Nuxt) that is a *full sync peer* of the native macOS app: same
end-to-end-encrypted remote store, same conflict semantics, same notebooks/pins/tags, and an editor that
round-trips every formatting feature the native editor produces. The pitch for the AGPL-3.0 open-source
release is **native app + self-hosted web app + sync**, deployable on a homelab with one Docker image.
NoteIt was developed under the working name Inkwell; the product name everywhere user-facing is now
**NoteIt** (`BRAND.md`).

v1 ships three ways to use the web app:

1. **Server mode** (default): the Docker image runs the web client plus a Nitro server that stores
   ciphertext on disk or in an upstream S3 bucket. One instance serves **several people** (a family or a
   small group). Each person has an isolated store and their own encryption passphrase (§7).
2. **Direct mode**: the same web client, served by any static host or by the image with the server turned
   off, talks straight to the user's own S3-compatible bucket over CORS (§6.4).
3. The server also gives native apps a no-cloud sync target through an S3-compatible endpoint (§6.3b).

Design principles:

1. **The storage format is the contract.** The web app is a second implementation of
   `NoteItSync` plus the note model, not a client of a server-side API that understands notes.
2. **Zero knowledge server.** The NoteIt server only ever stores and relays ciphertext. Passphrases and keys
   live only in browsers and on native devices. This holds for every user on the instance, and for the
   instance admin too (§7.4, §11.1).
3. **One image, one volume** for homelabs; the same server also gives native apps a no-cloud sync target.

### Non-goals (v1)

- Menu bar icon, global hotkeys, Quick Capture panel, launch at login (OS features; a PWA share target may come later).
- **Shared notebooks between users.** Every user's store is encrypted with that user's own key, so sharing
  needs key sharing (wrapping a notebook key for several users) and a new store layout. Future work (§16).
- Horizontal scaling: a server instance owns its data directory; run one replica.
- Real-time collaborative editing; CRDTs. NoteIt's model stays "conflict copies, never silent merge".
- Rollback/freshness protection against a malicious store (same as native today).
- Server-side search, previews, or any server-side plaintext.
- iOS/Android native apps (the PWA is the mobile story).
- Forward-auth (trusting a `Remote-User` header from a reverse proxy). It was considered and dropped (§7.3).

## 2. Existing format — byte-level reference (verified against Swift source)

Everything in this section is a fact about the code at the time of writing, cited `file:line`. A TypeScript
implementer must be able to interoperate from this section alone. "Double2001" means a JSON number of
seconds since 2001-01-01T00:00:00Z (Apple reference date; `Date.timeIntervalSinceReferenceDate`), i.e.
`unixSeconds - 978307200`.

**Legacy protocol identifiers.** The `inkwell/v1/` key prefix, the `inkwell/.canary/` canary prefix, the
manifest field names, the AAD contexts and the KDF and key-check parameters (including the
`inkwell-key-check` plaintext) are legacy protocol identifiers from the working name; they already shipped
and are kept unchanged for compatibility, and are never shown to users. Everything that has not shipped,
including the portable body format `noteit-doc` (§3), uses the NoteIt name.

### 2.1 Key layout

`RemoteLayout.root = "inkwell/v1/"` (`Sources/NoteItSync/Engine/RemoteLayout.swift:4`).

| Key (relative to the backend root) | Content | Encrypted? |
|---|---|---|
| `inkwell/v1/manifest.json` | `Manifest` | **No** (plaintext JSON) |
| `inkwell/v1/notebooks/<UUID>.json` | sealed `RemoteEnvelope` (kind `notebook`) | yes |
| `inkwell/v1/notes/<UUID>.meta` | sealed `RemoteEnvelope` (kind `note`) | yes |
| `inkwell/v1/notes/<UUID>.body` | sealed note body | yes |
| `inkwell/v1/tombstones/<UUID>.json` | sealed `Tombstone` | yes |
| `inkwell/v1/devices/<deviceID>.json` | sealed `DeviceInfo` | yes |

Notes:

- The meta key ends in **`.meta`**, not `.meta.json` as the older sync design doc says (`RemoteLayout.swift`).
- `<UUID>` is Swift `UUID.uuidString`: **uppercase** hex with hyphens. The listing parser (`RemoteIndex`,
  `SyncEngine.swift:787`) is lenient, and Swift's `UUID` decoder accepts lowercase (verified), but keys are
  always *rebuilt* from the parsed UUID in uppercase. A web client that wrote lowercase keys would create
  objects that native clients never address directly (they'd delete/overwrite the uppercase twin).
  **Rule: TS always writes uppercase UUIDs, in keys and in JSON.**
- S3 backends may add a user prefix: `prefix + "/"` before `inkwell/` (`Storage/S3Backend.swift:72-73`).
  The S3 connectivity canary writes and deletes `inkwell/.canary/<UUID>` (`S3Backend.swift:166`).
- Device IDs appear in cleartext key names (`devices/<deviceID>.json`).

### 2.2 JSON encoding rules

Outer objects (manifest, envelope, tombstone, device) use `SyncEngine.encode`
(`SyncEngine.swift:771-779`): `JSONEncoder` with `.sortedKeys`, default strategies. Verified behavior:

| Swift type | JSON |
|---|---|
| `Date` | number, Double2001 (e.g. `781948800.25`) — fractional allowed |
| `Data` | standard base64 **with** padding (`+`, `/`) |
| `UUID` | uppercase string |
| `nil` optional | key omitted |
| `/` in strings | escaped as `\/` (harmless; any JSON parser accepts it) |

Decoders ignore unknown keys (standard `Decodable`). TS writers need not reproduce key order or `\/`
escaping: every object is either sealed (compared by revision/SHA, never by bytes) or the plaintext
manifest (compared by ETag only).

**Inner metas** (the `meta` field inside an envelope) use `NoteStore.encoder`
(`Sources/NoteIt/Model/NoteStore.swift:798-808`): `.prettyPrinted`, `.sortedKeys`, **`.iso8601`** dates.
Swift writes `"2025-10-09T08:53:20Z"` (second precision, `Z`, fractional seconds dropped). The Swift
`.iso8601` decoder on current macOS accepted fractional seconds and offsets in a probe, but this varies
with Foundation versions. **Rule: TS writes `YYYY-MM-DDTHH:MM:SSZ` exactly (truncate milliseconds).**
Because inner dates are second-precision, a note's `updatedAt` round-trips with truncation; the envelope's
`modifiedAt` keeps sub-second precision (see §2.5).

### 2.3 Crypto

- **KDF** (`Crypto/KeyDerivation.swift`): PBKDF2-HMAC-SHA256 over the passphrase's raw UTF-8 bytes
  (**no Unicode normalization**), 16-byte random salt, 32-byte output used **directly** as the AES-256-GCM
  key (no HKDF). Default iterations **210 000**. A manifest is accepted only if `iterations ∈
  100 000…10 000 000` (`SyncEngine.swift:66`), `salt.count == 16` (`SyncEngine.swift:190`), and `keyCheck`
  is non-empty.
- **AEAD** (`Crypto/SyncCipher.swift:18-33`): AES-256-GCM, random 96-bit nonce, output is CryptoKit's
  `combined` = `nonce(12) ‖ ciphertext ‖ tag(16)` (a 1-byte plaintext seals to 29 bytes, verified).
  WebCrypto's `encrypt` returns `ciphertext ‖ tag` with a 128-bit tag, so
  `sealed = nonce ‖ webcryptoOutput`.
- **AAD = context** = UTF-8 of the object key with the `inkwell/v1/` prefix stripped
  (`SyncEngine.context`, `SyncEngine.swift:761`), e.g. `notes/0A0B…01.meta`, `notebooks/<UUID>.json`,
  `tombstones/<UUID>.json`, `devices/<id>.json`. This binds each ciphertext to its key: swapping objects
  fails to open. The S3 user prefix is **not** part of the context.
- **Key check**: `seal("inkwell-key-check", context: "manifest")` (`SyncEngine.swift:64`), base64 into
  `manifest.encryption.keyCheck`. Opening it with the wrong key fails → "wrong passphrase".
- **Plaintext stores**: a manifest without `encryption` means objects are stored as plain bytes (the
  "identity cipher"). The web app supports joining them with a warning but never creates them.

### 2.4 Manifest (`Model/Manifest.swift`)

```json
{"createdAt":781948800.123,"encryption":{"iterations":210000,"keyCheck":"<b64>","salt":"<b64 16 bytes>"},"formatVersion":1}
```

Created with `If-None-Match: *`; a 412 means another device created it first → re-read and join. Readers
refuse `formatVersion > 1` (`SyncEngine.swift:181` → `SyncError.unsupportedFormat`; also
`Sync/SyncController.swift:698`).

### 2.5 Envelope (`RemoteEnvelope`, `Model/SyncTypes.swift:42-62`)

Sealed at the meta key (`notes/<UUID>.meta` or `notebooks/<UUID>.json`).

| Field | Type | Meaning |
|---|---|---|
| `bodySHA256` | string? | lowercase hex SHA-256 of the **plaintext** body; omitted for notebooks |
| `deviceID` | string | writer's device ID (uppercase UUID) |
| `deviceName` | string | writer's display name (used in conflict-copy titles) |
| `id` | UUID | record id |
| `kind` | `"note"` \| `"notebook"` | |
| `meta` | base64 | bytes of the inner meta JSON (§2.6) |
| `modifiedAt` | Double2001 | notes: `meta.updatedAt`; notebooks: `modifiedAt` |
| `revision` | UUID | the record revision being published |

`Tombstone`: `{deletedAt: Double2001, deletedMetaETag?: string, deviceID, id, kind}`.
`DeviceInfo`: `{deviceID, lastSync: Double2001, name}`, rewritten at most every 10 min.

### 2.6 Inner metas (`Sources/NoteIt/Model/Models.swift`)

`NoteMeta` (`Models.swift:14-28`): `conflictOriginalID?: UUID`, `conflictSource?: string`, `createdAt: ISO`,
`id: UUID`, `isPinned: bool`, `notebookID?: UUID` (nil = no notebook), `preview: string`,
`revision?: UUID`, `tags: [string]`, `title: string`, `updatedAt: ISO`.

`Notebook` (`Models.swift:4-12`): `colorHex: "#RRGGBB"`, `id`, `modifiedAt?: ISO`, `name`,
`revision?: UUID`, `sortIndex: Int`, `symbol: string` (an SF Symbol name from the curated picker; the palette
has 10 colors — see HANDOFF §6).

### 2.7 Bodies today

A note body is the **flattened RTFD** of the editor's `NSAttributedString`
(`Sources/NoteIt/Model/NoteStore+Sync.swift:127-139`; `serializeBody` uses `rtfd(from:)`, bytes start with
ASCII `rtfd\0\0\0\0`; `deserializeBody` throws "body is not RTFD"). Images are `NSTextAttachment`
file wrappers inside the RTFD, often TIFF (pasteboard) and possibly HEIC. Browsers can neither parse
nor render this → Phase 0 (§3).

### 2.8 Derived fields (receiver re-derives)

On receive, `prepareRemoteNote` (`NoteStore.swift:1267`) **re-derives title, preview and tags from the body**;
the sender's values in the meta are informational. Rules (`NoteStore.swift:642-772`):

- `clean(line)`: remove U+FFFC (attachment char), tabs→spaces, trim whitespace.
- **Title** = first non-blank cleaned line, truncated to 120 grapheme clusters; "" if none.
- **Preview** = remaining non-blank cleaned lines joined by `" "`, truncated to 140 graphemes.
- List markers remain part of the text (`"•\t"`, `"1.\t"`, `"☐\t"` → `"• "` after cleaning).
- Tables: header row skipped, cells joined `" · "`, rows joined `"  "` (`NoteStore.swift:655-728`).
- **Tags**: regex `(?<![^\s\p{Ps}\p{Pi},;"'])#([\p{L}_][\p{L}\p{M}\p{N}_\-]*)` on NFC text, lowercased,
  de-duplicated in first-occurrence order, with ranges in monospaced font (inline code/code blocks) and
  links masked (`NoteStore.swift:738-772`).
- **Search fold**: case-, diacritic- and width-insensitive on NFC; every whitespace-separated term must match.

The web must implement identical derivations (golden vectors, §9) so that list rows match across peers.

### 2.9 Revisions and conflicts

- Every user change mints a **random revision UUID**: body edit (also clears conflict fields), pin, move,
  "Mark Resolved", notebook rename/recolor/reorder (`NoteStore.swift:1155-1255`). Native-only legacy
  records got a deterministic v8 UUID; the web never needs to generate those.
- Deleting a notebook locally moves its notes to `notebookID = nil` with new revisions; *receiving* a notebook
  deletion moves notes to nil **without** new revisions.
- **Note conflict** → `importConflictCopy` (`NoteStore+Sync.swift:107-122, 160-183`): a new note with a new
  id and revision whose body is the remote body with the first line suffixed
  `" (conflict — <deviceName>, <short date short time of envelope.modifiedAt>)"` (blank body → `"Untitled"` + suffix),
  copying remote `isPinned`, `createdAt`, `updatedAt`, `notebookID`, with `conflictSource = deviceName`,
  `conflictOriginalID = remote id`. The local note wins in place; the copy is pushed as a new record.
- **Notebook conflict** → last-writer-wins by `modifiedAt`, ties broken by `deviceID` string comparison (`>` wins).
- Deleting an original clears `conflictSource/conflictOriginalID` on its copies (new revision if local).

### 2.10 Engine pass (pseudo-code of `SyncEngine.runPass`, `SyncEngine.swift:217-700`)

```
list(prefix "inkwell/v1/") → RemoteIndex; if no manifest → abort ("store missing")
state ← loadState(); records ← localRecords(); deletions ← localDeletions()
ids ← union(local ids, remote meta ids, tombstone ids, base ids, deletion ids)
for id in ordered(ids)  # notebooks first, then by uuidString (SyncEngine.swift:254)
  process(id):                                   # SyncEngine.swift:292
    reconcile meta vs tombstone (tombstone wins if deletedMetaETag == meta.etag
      else if envelope.modifiedAt <= deletedAt)  # :314-317
    action ← SyncPlanner.decide(local, base, remote, deletion)   # SyncPlanner.swift:26-69
    switch action:
      push            → pendingPushes += id; PUT meta (If-Match base etag | If-None-Match *);
                         PUT body; base ← {revision, metaETag, bodyETag}; pendingPushes -= id
      pull            → GET meta, GET body; require sha256(body)==bodySHA256 else skip;
                         apply only if local revision unchanged; base ← remote
      conflict        → resolveConflict (:445): same revision ⇒ finish push;
                         own deviceID & (pending|base|missing body) ⇒ push;
                         notebook ⇒ LWW (:478); note ⇒ importConflictCopy, base ← remote, push local
      pushDeletion    → PUT tombstone; DELETE meta If-Match (412 ⇒ withdraw tombstone); DELETE body (:618)
      applyRemoteDeletion / resurrectPush / forgetBase
      none            → if this device owns the meta and the body ETag changed ⇒ repushBody (:511)
resolveSidecars (:521); push conflict copies created this pass
sweepTombstones older than 30 days (:647); writeDeviceRecordIfDue every 10 min (:670)
fatal (abort pass): unauthorized, clockSkew, insecureConnectionBlocked (:273)
```

`SyncState` (`Model/SyncState.swift:4-44`) persists: `bases[id] = {revision, remoteMetaETag, replacedMetaETag?,
bodyETag?}`, `knownTombstones`, `tombstoneDates`, `pendingPushes` (id → revision), `sidecarFirstSeen`,
`lastDeviceWrite`. It is device-local (never uploaded), so the web may store it in its own shape. The planner is a 17-row
decision table plus the deviations listed in `2026-10-12-sync-design.md` "Implementation notes &
deviations"; the TS port reproduces it exactly and is tested against an exhaustively generated table (§9).

### 2.11 ETags

- S3: ETag header with quotes (and `W/`) stripped (`S3ListParser.swift:37-38`); conditional requests send
  `If-Match: "<etag>"` and `If-None-Match: *`. 412 (and 409 on conditional) → precondition failed; 501 /
  `NotImplemented` → conditional writes unsupported (`S3Backend.swift:285-306`).
- Folder: `"h" + hex(first 16 bytes of SHA-256)` for files ≤ 256 KB, else `mtimeNs-size-inode`
  (`Storage/FolderBackend.swift:190-243`). ETags are opaque to the engine; only equality matters.

### 2.12 Surprising facts that shape the design

1. **Running native sessions do not re-read the manifest.** `SyncController.ensureSession`
   (`SyncController.swift:588`) reads it only when creating a session, which then lives until an error or
   reconnect. A `formatVersion` bump therefore does **not** fence an already-running old client; it can
   keep pushing RTFD bodies into an upgraded store. → v2 readers must handle legacy bodies **per record** (§3.4).
2. An old client that pulls a non-RTFD body fails `deserializeBody` with a per-record error and retries
   forever; it does not overwrite or lose data (and `importConflictCopy` throws before pushing). Safe, but noisy.
3. Titles include list markers and table text collapsing — the web derivation must mimic native text
   extraction, not "natural" HTML text.
4. Device IDs leak in cleartext key names; object sizes and counts leak (inherent).
5. The passphrase is not NFC-normalized: "é" typed as precomposed vs combining produces different keys.

## 3. Phase 0 — Portable note format

### 3.1 Options

| Option | Fidelity vs NSAttributedString | Attachments | Safety in browser | Diffability | Native cost |
|---|---|---|---|---|---|
| Sanitized HTML subset | good via `NSAttributedString(html:)`, but import is WebKit-backed, slow, main-thread, and lossy (lists become `NSTextList`, not NoteIt markers; sentinels lost) | data URIs / cid | must sanitize every render (XSS surface) | poor | custom writer + parser anyway |
| Markdown + extensions | cannot express text color, highlight, underline, alignment, font size, column widths without HTML escapes | links to files | good | best | custom parser |
| **ProseMirror/TipTap JSON with a NoteIt schema** | exact: we define one node/mark per native feature | content-addressed map | rendered through a schema, no HTML parsing | good (structured) | Codable types + converter |

**Decision: "noteit-doc" — a versioned, ProseMirror-compatible JSON document with a NoteIt-specific
schema.** It is the editor's native model on the web (TipTap), maps 1:1 onto the native block/mark
model, needs no HTML sanitization on render, and is easy to validate (`Node.fromJSON` + `check()`).
Markdown export stays a separate, lossy feature.

### 3.2 Body container (plaintext before sealing)

UTF-8 JSON:

```json
{
  "format": "noteit-doc",
  "version": 1,
  "doc": { "type": "doc", "content": [ ... ] },
  "attachments": {
    "<sha256 hex of data>": { "mime": "image/png", "name": "Pasted.png", "data": "<base64>" }
  }
}
```

- Attachments are inline so the body stays one atomic object covered by `bodySHA256` (no orphan
  GC, no new key types). Content-addressed attachment objects are future work (§12).
- Unknown top-level fields must be preserved by readers that re-save (forward compatibility), and unknown
  node/mark types make a reader treat the note as **read-only** rather than dropping content.
- No byte-level canonicalization is required: ETags/`bodySHA256` are computed over whatever bytes the
  writer produced; vectors compare parsed structure.

### 3.3 Schema (`noteit-doc` v1)

Nodes (block):

| Node | Attrs | Content | Native equivalent |
|---|---|---|---|
| `doc` | — | `block+` | whole attributed string |
| `paragraph` | `align?: "left"\|"center"\|"right"\|"justify"`, `indent?: 0-8` | inline* | body paragraph (sentinel 29) |
| `heading` | `level: 1\|2\|3`, `align?`, `indent?` | inline* | 1 = Title (37), 2 = Heading (39), 3 = Subheading (41) |
| `codeBlock` | `align?` | inline* (all marks, `hardBreak`, `image`, `attachment`) | **one** code paragraph (31), monospaced base font; consecutive `codeBlock` nodes render as one visual block |
| `blockquote` | `indent?` | `paragraph+` | quote (33) |
| `horizontalRule` | — | — | divider (35, NBSP text) |
| `listItem` | `kind: "bullet"\|"ordered"\|"task"`, `level: 0-8`, `number?: int` (ordered), `checked?: bool` (task), `align?` | inline* | paragraph with marker `•/◦/▪\t`, `N.\t`, `☐/☑\t`; level = (firstLineHeadIndent − 4)/24 |
| `table` | `columnWidths?: number[]` (percent) | `tableRow+` | `NSTextTable` |
| `tableRow` | — | `(tableHeader\|tableCell)+` | row |
| `tableHeader` / `tableCell` | — | `paragraph+` | header row = row 0 with background or bold |

Inline: `text`, `hardBreak` (U+2028), `image {sha, name, mime, width?}`, `attachment {sha, name, mime}`
(non-image file chip).

Marks: `bold`, `italic`, `underline`, `strike`, `code` (inline code), `link {href}`,
`textColor {color: "#RRGGBB"}` (light-appearance value, as native stores it — `EditorStyles.swift:97`),
`highlight {color: "#RRGGBB"}`, `fontSize {delta: int}` (points relative to the block's base size, so
users' different base font sizes still look right; clamped to native's 8-96 pt absolute range).

Decisions:

- **Lists are flat** (`listItem` with `level`), deliberately unlike TipTap's nested `bulletList>listItem`,
  because native lists are paragraphs with markers and indent; flat items round-trip exactly and make
  mixed-kind sequences and level skips representable. Bullet glyph is derived from `level % 3`;
  ordered `number` is stored (native stores literal "N."), renumbering is an editor command.
- Checked styling (strikethrough + gray `checkedTextColor`) is **derived** from `checked`, not stored as
  marks; the converter strips those attributes on export and re-applies them on import.
- **Code blocks keep full formatting.** Native applies every character and paragraph command inside a code
  block: bold/italic toggle font traits on the monospaced font, underline/strike/color/highlight/size are
  plain attributes, alignment is per paragraph, and links and pasted images can land there
  (`Editor/TextFormatter.swift:12-29, 158-181, 472-486`). Normalizing on export would silently strip
  formatting that users see on the Mac, the first time they open the note on the web. So `codeBlock` uses the
  same inline content and mark model as `paragraph`, with three differences:
  - The base font is monospaced.
  - Whitespace is preserved (`whitespace: pre`).
  - The `code` mark is redundant inside a code block, so export drops it and import ignores it.

  One `codeBlock` node is one native code paragraph, mirroring the per-paragraph sentinel. This keeps
  per-line alignment and makes Enter behave like native, where it creates the next code paragraph. Tag
  derivation masks the whole code block, as native does for monospaced ranges. The cost is a custom TipTap
  node instead of the stock `CodeBlock`, which only allows unmarked text. Syntax highlighting is
  therefore out of scope for v1.
- **What each `FormatCommand` does inside a code block.** These outcomes were verified against
  `Editor/FormatCommand.swift:4-21` and `Editor/TextFormatter.swift`, and the web editor matches them:

  | `FormatCommand` | Native effect in a code paragraph | noteit-doc result |
  |---|---|---|
  | `bold`, `italic` | font trait on the monospaced font (`:99-115`) | `bold` / `italic` mark |
  | `underline`, `strikethrough` | line attribute (`:117-130`) | mark |
  | `inlineCode` | **no-op**: guarded by `blockKind != .code` (`:132-135`) | unchanged; the toolbar shows it off (`:72`) |
  | `textColor(c)`, `textColor(nil)`, `customColor` (color panel → `NSTextView.changeColor`) | `.foregroundColor` set or removed | `textColor` mark set or removed |
  | `highlight(c)`, `highlight(nil)`, `toggleHighlight` | `.backgroundColor` set or removed | `highlight` mark |
  | `fontBigger`, `fontSmaller` | size ±1 clamped to 8–96 (`:169-182`) | `fontSize{delta}` relative to the code base size |
  | `align(.left/.center/.right/.justified)` | paragraph alignment (`:472-486`) | `codeBlock.align` `left/center/right/justify` |
  | `indent`, `outdent` | **no-op**: code paragraphs get an identity edit (`:423-433`) | unchanged. Code paragraphs have no indent levels at all: `paragraphStyle(for: .code)` skips the level (`EditorStyles.swift:194`), so `block(.code)` on an indented paragraph drops its level. `codeBlock` therefore has no `indent` attr. |
  | `list(_)`, `toggleCheckbox` | **no-op**: code paragraphs are filtered out (`:305-309`), and there is no checkbox marker | unchanged |
  | `block(.code)` again | toggles the paragraphs back to body (`:273`). `convertFonts` resets the font to body and re-applies italic only (`:234-240`). Other character attributes and the alignment are kept (`EditorStyles.swift:198-199`). | `paragraph{align}`, keeping `italic`, `underline`, `strike`, `textColor`, `highlight`, `link`, `image`; **dropping** `bold` and `fontSize` |
  | `block(.title/.heading/.subheading)` | converts out of code; heading font with italic re-applied (`:228-233`), alignment kept | `heading{level, align}` with the same kept/dropped marks as the row above |
  | `block(.quote)` | converts out of code; same font rule as body | `blockquote > paragraph`, same kept/dropped marks |
  | `link` | `.link` on the range (`:666-731`) | `link` mark |
  | `image` | inline attachment at the caret (`:754-776`) | inline `image` / `attachment` inside `codeBlock` |
  | `divider`, `block(.divider)`, `table(r,c)` | inserted *after* the paragraph (`blockInsertionPoint`, `:506-530`) | sibling block; the code block is unchanged |
  | `clearFormatting` | On the selection (or the whole paragraphs if empty), it removes foreground/background color, underline, strikethrough and other visual attributes, and sets the body font (`:784-790`). It does **not** remove `.link` or `.attachment`. Every touched paragraph is then rewritten with a body paragraph style, natural alignment and no list marker (`:792-798`), and `makeEdit` keeps the remaining character attributes (`:196-214`). | The paragraph **leaves** the code block and becomes `paragraph` with no `align`. Cleared text keeps `link` marks and inline `image`/`attachment` nodes, and loses every other mark. With a partial selection, unselected characters keep their marks *and the monospaced code font*, so they export as the `code` mark in the new paragraph. Native behavior is matched, not changed. |
  | `addRowAbove`, `addRowBelow`, `deleteRow` | table-only; no effect outside a table | unchanged |

  Entering a code block works differently. `block(.code)` on other text sets the code font on the whole
  paragraph and removes `.backgroundColor` (`:225-227`), so bold, italic, `fontSize` and `highlight` are
  dropped, while underline, strikethrough, color, link and images are kept. Formatting applied
  *after* entering is preserved as in the table. The web editor's "Code Block" command performs the same
  normalization.
- Absent attrs mean defaults (`align` natural/left, `indent` 0).

### 3.4 Versioning and migration

1. **Envelope** gains optional `bodyFormat: string` — `"noteit-doc/1"`. Absent ⇒ legacy RTFD. Old engines
   ignore it (unknown key) and drop it when they re-publish — which is correct, because they only ever
   publish RTFD.
2. **`RecordPayload`** (engine ↔ app boundary) gains `bodyFormat` so the engine stays body-agnostic: the
   adapter sets it on export and receives it on pull.
3. **Manifest** gains `formatVersion: 2` and optional `features: [string]` (initially `["noteit-doc"]`).
   Readers refuse `formatVersion > 2` or any unknown feature. Old (v1-only) native builds refuse new
   connections to a v2 store with their existing "unsupported format — update NoteIt" message
   (`SyncError.unsupportedFormat`). They fail safely and lose nothing. Locking them out is acceptable
   because NoteIt has not been released: only pre-release builds lack v2 support.
4. **Native v2** accepts `formatVersion ≤ 2` and creates new stores directly at v2. On a **v1 store it
   writes RTFD** only until its first clean pass, which upgrades the store automatically (item 6); in a
   **v2 store it writes noteit-doc**. It reads both body formats in both stores, dispatching on the
   envelope's `bodyFormat` (with an RTFD magic-byte sniff as a fallback).
5. **The store format travels with the session.** `connect` returns a `StoreSession`:
   - `manifest`;
   - `manifestETag`;
   - `formatVersion`;
   - the cipher.

   The engine and `NoteStoreSyncAdapter` share one `StoreSessionRef`, and `export` reads its body encoding
   from it (RTFD for v1, noteit-doc for v2). Today `SyncController.ensureSession` keeps only the cipher
   and discards the manifest (`SyncController.swift:603-620`); v2 keeps the whole session.

   Every pass already lists the root, and the listing includes the manifest's ETag. When that ETag differs
   from `session.manifestETag`, a v2 engine re-reads the manifest before processing any record. It then
   checks that salt, iterations and keyCheck are unchanged; if they changed, the pass fails with
   `encryptionMismatch`. Finally it swaps the session. A v2 Mac with a long-lived session therefore
   notices an upgrade made by another device on its next pass. Running *v1* binaries still can't notice
   (§2.12), which is what item 8 handles.
6. **Upgrade is automatic.** There is no button and no setting. A native build that supports noteit-doc
   (a "v2 client") upgrades a v1 store by itself, with no user action:
   - **When.** `SyncEngine.sync()` on a v1 session runs the normal pass first. If that pass finished
     without a fatal error and `report.errors` is empty (a *clean pass*), the same `sync()` call then runs
     `upgradeToV2()`. The first pass after connecting is usually clean, so a v2 client normally upgrades
     on connect. If the pass had errors, the store stays v1 and the next clean pass tries again. The clean
     pass first publishes every pending local edit as RTFD, so nothing is left behind in the old format.
   - **Serialized.** `upgradeToV2()` runs inside that `sync()` call, on the pass queue, so no other pass
     can observe a half-upgraded session. It is not exposed to the UI; it is public only for tests.

   `upgradeToV2()` runs these steps:
   1. Precondition: the pass that just finished was clean (above).
   2. Send a conditional `PUT manifest.json` with `If-Match: <session.manifestETag>`. The body keeps the
      same `createdAt`, salt, iterations and keyCheck (or no `encryption` for a plaintext store), and sets
      `formatVersion: 2` and `features: ["noteit-doc"]`. On 412, re-read the manifest:
      - If it is already v2 with the same encryption, adopt it, because another device upgraded first.
        Two v2 clients upgrading at the same time therefore end with one write and one adoption.
      - If it is v2 with different encryption, fail with `encryptionMismatch`, as a session refresh would.
      - If it is still v1, leave the store as it is and try again after the next clean pass.
   3. Replace the shared `StoreSessionRef` with the new manifest and ETag. Only then does any export
      produce noteit-doc.
   4. Run the **conversion sweep** (item 7) and then a normal pass.

   A non-fatal failure in steps 2–4 (network, 412) does not make `sync()` throw. It is logged, and the
   next pass continues from the state that was reached: still v1 if the manifest PUT did not land, or v2
   with the remaining notes converted by later sweeps. Fatal errors (`unauthorized`, `clockSkew`,
   `insecureConnectionBlocked`) propagate as for any pass. The web app and the server never upgrade a
   store (item 8).

   **What users see** (plain words, reused in the web notice, `web/README.md` and native help text):

   > Notes on your Mac are saved in Apple's rich text format (RTFD), which web browsers can't read. The
   > first time an up-to-date NoteIt for Mac syncs with your storage, it switches the storage to a
   > portable format that both the Mac and the browser understand, and converts your notes in the
   > background. You don't need to do anything. While this happens, each of your devices downloads every
   > note once, which can take a while for a large library with images. After that, the web app can open
   > all your notes. Older NoteIt builds stop syncing with that storage and ask you to update NoteIt;
   > nothing on those Macs is lost.
7. **Conversion sweep — a revision-preserving meta rewrite, intentionally pulled by peers.** Adding
   `bodyFormat` changes the envelope bytes, so the meta ETag changes. A body-only re-upload
   (`repushBody`, `SyncEngine.swift:511-519`) can't publish `bodyFormat`, and peers would never learn the
   new format. So conversion re-publishes **meta and body** through the normal push path
   (`SyncEngine.swift:394-424`), with **the same revision**. A record is a *conversion candidate* when all
   of these hold:
   - this is a v2 session;
   - the last envelope seen for the note had no `bodyFormat`; the engine tracks this in the new
     `SyncState.legacyBodies: Set<UUID>`, filled on pull and on `.none` with a legacy remote;
   - the local revision equals `base.revision`, meaning no unpushed local edit;
   - no `pendingPushes` entry exists.

   For each candidate, the engine:
   1. Records the candidate in `pendingPushes` (revision unchanged), so a crash resumes like any push.
   2. Sends `PUT notes/<id>.meta` with **`If-Match: base.remoteMetaETag`**. The new envelope has the same
      `revision`, this device's `deviceID`/`deviceName`, `bodyFormat: "noteit-doc/1"` and a new
      `bodySHA256`.
   3. Sends `PUT notes/<id>.body` with the noteit-doc container.
   4. Sets `base = {revision (unchanged), remoteMetaETag: new, replacedMetaETag: old, bodyETag}` and removes
      the id from `legacyBodies` and `pendingPushes`.

   **Peers:** the meta ETag changed and their local revision didn't, so `SyncPlanner.decide` yields
   **`.pull`** (row 5, `SyncPlanner.swift:35-38`). The peer fetches meta and body, checks `bodySHA256`, and
   applies the payload with the unchanged revision. No conflict copy is created, but every peer
   re-downloads each converted note once. This is the intended cost.

   **412 on the meta PUT:** another device changed the record after our pass, for example an old client
   that edited it. The engine:
   - abandons the conversion of that record and clears `pendingPushes`, exactly as `push` does;
   - does **not** retry immediately;
   - leaves the id in `legacyBodies`.

   The next pass handles the record through the planner, as `.pull` or `.conflict`. If the body it then
   holds is still legacy, the record becomes a candidate again. Conversion runs at the end of **every**
   v2 pass, not only during the upgrade. That is also how legacy bodies are lazily converted after the
   upgrade, when they come from an old session still running (§2.12). It is capped at 200 records per
   pass to bound pass time. Retries are therefore bounded by the planner's own progress: a record is
   converted once its meta stops changing between two passes.

   **Old (v1) client that edits a note after its conversion:**
   1. Its push gets 412 because its base ETag is stale.
   2. Its planner then reports `.conflict`.
   3. `importConflictCopy` fails to decode the noteit-doc body (§2.12 fact 2) and the record is retried
      every pass.

   The edit stays safe on that Mac, unsynced, until NoteIt on it is updated. That Mac shows the record in
   its existing "N items will be retried" line. Only pre-release builds can be in this state.
8. **Web app**: never upgrades or converts a store; a browser can't parse RTFD, so it must not try. When
   it connects to a v1 store (through the server or in direct mode) it shows **"Open NoteIt on your Mac
   once to finish setting up web access"**, followed by the plain-words explanation from item 6, and
   re-checks the manifest every 60 s and on focus, so it continues on its own once a Mac has upgraded the
   store. The server never parses the manifest (it stays zero-knowledge; §6.2), so the check lives in
   `connect` in `@noteit/core`. The web creates new stores directly at v2 (always encrypted). Legacy-RTFD notes found in a v2
   store are shown **read-only** with a placeholder ("Formatted on an older Mac — open NoteIt on macOS to
   convert") plus the meta title/preview; pin/move/delete are allowed and re-push the opaque body bytes
   **without** `bodyFormat`. The web never converts bodies (it cannot parse RTFD).

   **Wire rule (both implementations):** the envelope's `bodyFormat` key is either `"noteit-doc/1"` or
   **omitted**. It is never `null`, `""` or any legacy marker such as `"rtfd"`. Local stores keep exactly
   the wire value: `undefined`/`nil` means legacy, and there is no internal `'rtfd'` tag that could leak.
   Any other value is rejected **per record** with `invalidPayload`. In TS the check is in
   `encodeEnvelope`; in Swift it is `BodyFormat.validateForPublish`, called in `SyncEngine.push` right after
   `local.export`. Either way it runs before `pendingPushes` is written, the envelope is built, or any
   backend call is made, so the bad note causes no remote write and no sync-state change.
   - The error is **not** fatal for the pass. It is a non-`StorageError`, so the existing per-record catch
     (`processSafely`, `SyncEngine.swift:280-290`) records `"<UUID>: invalidPayload(…)"` in
     `SyncReport.errors`, and every other record keeps syncing. `sync()` returns normally.
   - The conversion sweep applies the same per-record catch to each note it converts.
   - The note is retried on every pass. The fix is a code change, and an upgraded client syncs the note
     normally.
   - **UI:**
     - Native uses the existing per-record failure path: Settings → Sync shows "N items will be retried
       on the next sync" with the error lines as a tooltip (`SyncSettingsView.swift:636-641`). The status
       stays idle, so one bad note doesn't turn the pill into "Sync Issue".
     - The web `SyncDetailsPopover` shows the same count and lists each failed note by title, linking
       to it.

### 3.5 Native converter

New SwiftPM library target **`NoteItDoc`** (depends on AppKit; used by the `NoteIt` app):

- `Codable` schema types, container encode/decode, validation (unknown types → `.readOnly`).
- `DocConverter.export(NSAttributedString, styles:) -> BodyContainer` and
  `DocConverter.import(BodyContainer, styles:) -> NSAttributedString`, with an injected `DocStyleProvider`
  (fonts, colors, base size) so the converter is testable headless.
- The block-kind sentinel constants (29…41) move from `EditorStyle` into `NoteItDoc` so both sides share them;
  legacy font-based classification is reused for pre-sentinel content.
- Image export: PNG/JPEG/GIF/WebP pass through; TIFF/BMP → PNG; HEIC/HEIF → JPEG (q 0.9); anything else →
  `attachment` (download chip). Foreign rich-paste attributes (arbitrary fonts, kerning, shadows) degrade to
  the nearest supported mark or are dropped — documented in the converter's README comment table.

Fidelity tests (`Tests/NoteItDocTests`):

- **doc → NSAS → doc is exact** for fixtures and for a seeded random doc generator (every node/mark/attr).
- **NSAS → doc → NSAS is semantically equal**: block kind, marker, level, alignment, marks, colors, links,
  attachment hash per paragraph range (not byte-equal RTFD).
- Corpus: the app's seed notes, every `FormatCommand` applied to sample text, tables, mixed lists, images,
  and a code-block set that covers **every row of the §3.3 code-block table**, including the no-ops
  (`inlineCode`, `indent`/`outdent`, lists, `toggleCheckbox`, table row commands), justify, `block(.code)`
  toggling back to body, `clearFormatting` leaving the block (including a cleared link that survives), and a link and an inline image inside it.
  The unit fixtures reproduce the attribute edits (tests can't import the app target). The real
  `TextFormatter.perform(_:)` runs the same list in the §12.6 real-app gate.
- Derivations: title/preview/tags computed from the NSAS equal those computed from the doc (feeds TS vectors).

### 3.6 Keep RTFD alongside? — No

Storing RTFD next to noteit-doc would double image bytes, create two sources of truth that can disagree
(which wins on a conflicting web edit?), and need sidecar GC. The schema covers everything the native editor
*produces*; only foreign paste attributes are lossy, and those are equally lost to the web. A note's local
native cache remains RTFD on disk, so nothing changes for offline native use.

## 4. Architecture

```
Browser (PWA)                                   Nuxt/Nitro server (Docker, NOTEIT_MODE=server)
┌──────────────────────────────┐               ┌─────────────────────────────────────┐
│ Vue UI (3 panes, TipTap)     │               │ /api/setup, login, oidc, session    │
│   ⇅ Comlink                  │  HTTPS        │ /api/account, /api/admin, invites   │
│ Sync Worker: @noteit/core    │──ciphertext──▶│ /api/storage/*  (per-user namespace)│
│  WebCrypto, planner, engine  │               │ /s3/*  (S3 subset, per-user SigV4)  │◀── native apps, rclone
│  IndexedDB (sealed cache)    │               │ StoreDriver: disk | upstream S3     │
└──────────────┬───────────────┘               └──────────────┬──────────────────────┘
               │ direct mode (§6.4):                          ▼
               │ SigV4 over CORS, no server     /data/store/users/<USER-UUID>/…
               ▼                                or <NOTEIT_S3_PREFIX>/users/<USER-UUID>/…
   the user's own S3-compatible bucket
```

### 4.1 Nuxt app

- Nuxt 4, `ssr: false` (SPA; nothing to render server-side since the server holds no plaintext), Nitro
  `node-server` preset. Vue 3, Pinia for UI state, VueUse, `@vite-pwa/nuxt` for the app-shell service worker.
- **One client build, two storage modes.** The client reads `/noteit-client.json` at startup
  (`{mode: "server" | "direct", sourceUrl?}`, §6.4) and the sync worker's `backendFactory` builds either a
  `ServerBackend` (`/api/storage`, server mode) or an `S3Backend` (direct mode). Everything above the
  `StorageBackend` interface is identical in both modes.
- **Design system.** The web UI follows the NoteIt design system, kept in the repository as `design/`
  (copied unchanged from the design handoff: `README.md`, `BRAND.md`, `tokens.md`, `tokens.css`,
  `components/`, `assets/icons/`).
  - `design/tokens.css` is the handoff's CSS export, which it designates for the website. The web app
    imports it **unchanged** as the only source of color, type, spacing, radius, shadow and motion values,
    including its light/dark theme switch. Web components reference token names only. This spec and the
    plan never restate token values.
  - `design/BRAND.md` governs naming and copy: the product is always "NoteIt" with that exact casing, and
    UI labels use Title Case. Brand colors are for the logo, the app icon and marketing only, never for
    app chrome or note content.
  - `design/components/*.md` specify each component the web reuses (sidebar row, note card, notebook glyph
    and chip, toolbar button, editor blocks, empty state, toast, checkbox, keycap). Their previews are
    visual specs, not code to port.
  - Chrome icons use the NoteIt icon set (`design/assets/icons`, `components/IconSet.md`), which exists
    for places where SF Symbols can't be used, such as the web.
  - No UI component framework. `docs/design/HANDOFF.md` remains the reference for native *behaviour* the
    web mirrors (§10).

### 4.2 Browser as the sync client

- **Crypto**: WebCrypto `importKey(raw passphrase, "PBKDF2")` → `deriveKey({name:"PBKDF2", hash:"SHA-256",
  salt, iterations}, …, {name:"AES-GCM", length:256}, extractable: false, ["encrypt","decrypt"])`.
  Golden vectors also need raw bits, so tests use `deriveBits`; production code never exports the key.
- **Key caching**: default **in memory only** (re-enter passphrase per browser session; Locked state in the
  pill). Opt-in "Remember on this device" stores the non-extractable `CryptoKey` in IndexedDB (structured-clone
  of CryptoKey keeps it non-extractable: script on this origin can *use* it but not read it). "Lock" deletes it.
- **Engine in a Web Worker**: crypto, planner, storage I/O and the search index run off the main thread
  (PBKDF2 210k ≈ 100-300 ms; large bodies). UI talks to it via Comlink.
- **Multi-tab**: Web Locks (`navigator.locks.request("noteit-sync")`) guarantee one pass at a time across
  tabs; `BroadcastChannel("noteit")` fans out "records changed"/"status" events. (SharedWorker is not used:
  missing on Chrome Android.)
- **Local cache (IndexedDB, via `idb`)**: stores `records` (each value sealed with the store key under context
  `local/<storeName>/<id>`), `deletions`, `syncState`, `trash` (deleted bodies kept locally — native moves them
  to `.trash` and never deletes them outright, `NoteStore.swift:481, 1091-1099`; the web caps this at 30 days
  because browser quota is finite), `settings`.
  Locking makes the cache unreadable; wiping is "Sign out & forget this device".
- **Offline**: edits apply to IDB immediately; sync passes run after local changes (2 s debounce, 10 s max
  delay), every 60 s while visible and 600 s while hidden, and on `online`/focus — the native constants
  (`SyncController.swift:71-74`); failures show "Offline"/"Sync Issue".
- **One cache per account.** The IndexedDB database is named per account so that two people who share a
  browser profile never share a cache: `noteit-<USER-UUID>` in server mode, and
  `noteit-direct-<hex(SHA-256(endpoint, bucket, prefix))[0..16]>` in direct mode. Signing out keeps the
  database sealed; "Sign out & forget this device" deletes it.
- **Direct-mode credential vault** (§6.4): the S3 access key and secret are stored only inside an
  AES-GCM-sealed IDB record under a key derived from the user's passphrase. They are never written to
  `localStorage`, `sessionStorage`, cookies or URLs.
- **Device identity**: one uppercase UUID per browser profile in IDB; name defaults to
  `"Web — <Browser> on <OS>"`, editable in Settings (it appears in other devices' conflict copies).
- **Dates**: envelopes carry Double2001 numbers (kept raw, converted at the edge); inner metas written as
  second-precision ISO `Z`.
- The web app never seeds sample notes into a synced store.

### 4.3 Sharing logic: TypeScript port + golden vectors (recommended) vs WASM

| | TS port + golden vectors | SwiftWasm build of NoteItSync |
|---|---|---|
| Crypto | WebCrypto (native speed, non-extractable keys) | CryptoKit unavailable; swift-crypto/BoringSSL in WASM, keys in WASM memory |
| Bundle | ~tens of KB | multi-MB runtime |
| Concurrency | async/await maps directly | Swift actors/async on WASM still fragile |
| Storage | `fetch` | URLSession unavailable; needs bridge |
| Drift risk | mitigated by vectors generated from Swift in the same repo/CI | none for engine, but the note model (NoteStore, AppKit) isn't portable anyway |

**Decision: TS port**, kept honest by **golden vectors exported by the Swift tests** into `fixtures/golden/`
and a reverse set (`fixtures/golden/from-web/`) written by TS and decoded by Swift tests. Both suites run in
one CI workflow, so a format change in Swift that is not mirrored in TS fails the build.

## 5. Monorepo layout

`web/` inside this repository (pnpm workspace):

```
web/
  package.json, pnpm-workspace.yaml, tsconfig.base.json
  packages/core/    @noteit/core — crypto, formats, layout, planner, engine, StorageBackend, S3 (SigV4) — no DOM
  packages/doc/     @noteit/doc  — schema, container, TipTap extensions, derivations, sanitize
  apps/web/         Nuxt 4 app (SPA) + Nitro server routes (accounts, OIDC, admin, storage, /s3)
  e2e/              Playwright (server mode, multi-user, direct mode)
  Dockerfile, docker-compose.yml
design/             NoteIt design system (tokens.css, BRAND.md, tokens.md, components/, assets/icons/)
fixtures/golden/    shared vectors (Swift writes, TS reads; from-web/ the reverse)
```

Justification: the storage format, vectors, Swift engine and TS port must change **atomically in one PR**,
validated by one CI run, under one AGPL license and one issue tracker. A separate repo would need vector
publishing and version pinning for no benefit. `web/` keeps Node tooling out of the SwiftPM root.

## 6. Storage access

### 6.1 Options

| | **Server mode** (default) | **Direct mode** (browser → S3) |
|---|---|---|
| Bucket CORS | not needed | required (§6.4) |
| S3 credentials | stay on the server; each user gets `/s3` keys for native apps | in the browser, sealed in IDB under the passphrase |
| No-cloud homelab | built-in disk store | needs a self-hosted S3 (MinIO, Garage) |
| Several people | yes: accounts, isolated stores, quotas (§7) | one person per bucket or prefix; no accounts |
| Native app target | user's bucket **or** the NoteIt server's `/s3` | the same bucket |
| Who serves the code | the server | any static host, or the image with `NOTEIT_MODE=static` |
| Server trust | sees ciphertext and metadata only | no server; trust moves to the static host |

**Decision: both modes ship in v1, from one client build.** Server mode is the default and the recommended
setup. Direct mode is for people who already have a bucket, can set its CORS rules, and don't want to run a
server. Neither mode gives anyone but the user's own devices the keys or the plaintext.

### 6.2 Server store drivers

**ETag rule (all server code):**
- *Inside* the server, every ETag is an **unquoted opaque string**. This covers `StoreDriver` results,
  the in-memory index, `/api/storage` JSON bodies and the TS `StorageBackend` API. It matches the Swift
  convention: `S3Backend` strips quotes on read and `S3ListParser.stripQuotes` removes `W/` and quotes
  (`S3ListParser.swift:31-38`).
- Quotes appear **only on the wire in HTTP**: in the `ETag` response header (`ETag: "<etag>"`) and in S3
  XML `<ETag>"<etag>"</ETag>`.
- Incoming `If-Match` values are normalized exactly once, at the route boundary: strip an optional `W/`,
  then one pair of surrounding quotes. Accept a quoted or a bare value, since Swift sends it quoted
  (`S3Backend.swift:104-110, 128-134`).
- `If-None-Match` is accepted only as `*`. Any other value gets 400 `badRequest`.
- Drivers never see quotes.

- `disk` (default): files under `/data/store/users/<USER-UUID>/<key>` (per-user namespaces, below); ETag = hex(SHA-256(bytes))[0..32] (unquoted);
  per-key async mutex; writes go temp file → `fsync` → `rename`; in-memory ETag index revalidated by
  `stat` (mtime/size); single-instance only (documented). Conditional semantics identical to S3.
- `s3` (upstream): server uses `@noteit/core`'s `S3Backend` (same SigV4 code the browser uses in direct
  mode) with credentials from env (§8); supports any provider the native app supports.

**Per-user namespaces.** Every user has a fully isolated store. Each storage operation, REST or `/s3`, runs
for exactly one authenticated user and reaches a driver only through one choke point,
`namespacedKey(user, key)` in `server/utils/namespace.ts`:
1. The key (or list prefix) is validated first, against the key regex of §6.3 for objects, and for list
   prefixes against "starts with `inkwell/`, no `..` segment, no NUL, no `\`" after percent-decoding.
   Anything else is 400 `badRequest` before a driver is called.
2. The namespace comes only from the user's immutable id (an uppercase UUID assigned at creation), never
   from the username, the display name or any request input:
   - disk: `/data/store/users/<USER-UUID>/<key>`, for example
     `/data/store/users/<USER-UUID>/inkwell/v1/manifest.json`;
   - upstream S3: `<NOTEIT_S3_PREFIX>/users/<USER-UUID>/<key>` in `NOTEIT_S3_BUCKET` (an empty prefix gives
     `users/<USER-UUID>/<key>`).
3. Drivers have no un-namespaced entry point. List results are returned with the namespace stripped and
   can only enumerate inside it.

Each namespace is a complete, independent NoteIt store, with its own manifest, salt and key check and so its
own passphrase and E2E key. There is no server-wide store. The server is the only writer to its upstream
prefix; this is documented.

**Quotas.** An optional per-user `quotaBytes`, set by an admin (default `NOTEIT_DEFAULT_QUOTA_MB`; unset
means unlimited).
- Usage is the sum of object sizes in the namespace. It is computed by listing at startup, kept in memory
  and updated after every successful write or delete.
- A PUT is admitted under a per-user lock when `used − size(existing object) + size(new) ≤ quota`. The
  bytes are reserved before the driver write and adjusted or released after it, so concurrent uploads can't
  overshoot.
- Over quota: REST returns `507 {error: "quotaExceeded"}`; `/s3` returns `400 QuotaExceeded` XML.
  - TS adds `StorageErrorKind` `quotaExceeded`. It is non-fatal: the per-record catch records it and the
    other records keep syncing.
  - Native classifies the unknown 400 code as `invalidResponse`, which is also a non-fatal per-record error
    (`S3Backend.swift` `classify`; `SyncEngine.swift:280-290`).
  - The web shows "Storage full — delete notes or ask your admin for more space" in the sync details.
- DELETE is always allowed, so a full user can free space. The control objects `manifest.json`,
  `tombstones/*`, `devices/*` and `.canary/*` are exempt from the quota, so a full user can still connect,
  run the canary and sync deletions, but each of them is capped at 64 KB.

### 6.3 Front doors

**(a) Browser REST — `/api/storage`** (session cookie + `X-NoteIt: 1` header + `Origin` check). Every key is
relative to the signed-in user's namespace (§6.2):

| Method & path | Request | Response |
|---|---|---|
| `GET /api/storage/list?prefix=inkwell/v1/&continuationToken=` | — | `200 {objects:[{key,etag,size}], nextContinuationToken?}` (etags unquoted, ≤1000/page) |
| `GET /api/storage/object/<key>` | — | `200` bytes, header `ETag: "<etag>"` (quoted on the wire); `404` |
| `PUT /api/storage/object/<key>` | bytes; `If-Match: "<etag>"` (bare accepted) or `If-None-Match: *` | `200 {etag}` (JSON, unquoted) + header `ETag: "<etag>"`; `412` precondition failed; `507` quotaExceeded |
| `DELETE /api/storage/object/<key>` | optional `If-Match` | `204`; `404`; `412` |

Keys must match `^inkwell/(v1/(manifest\.json|notebooks/[0-9A-F-]{36}\.json|notes/[0-9A-F-]{36}\.(meta|body)|tombstones/[0-9A-F-]{36}\.json|devices/[0-9A-Za-z-]{1,64}\.json)|\.canary/[0-9A-F-]{36})$`
(case-insensitive hex accepted for reads, writes uppercase-only). Body limit `NOTEIT_MAX_OBJECT_MB` (default 50).
Errors are JSON `{error: code, message}`; `401` → client shows login.

**(b) S3-compatible subset — `/s3`** for native apps and backup tools (rclone), so **no new Swift sync code** is
needed: native adds a "NoteIt Server" provider preset (endpoint = server URL + `/s3`, path-style, bucket
`noteit`, region `us-east-1`). Each person enters **their own** access key from the web app's Settings →
Account and their own sync passphrase, so every Mac in a family syncs with its owner's store only.

- Operations: `ListObjectsV2` (`list-type=2`, `prefix`, `continuation-token`, `max-keys`; XML
  `ListBucketResult` with `Contents/Key/ETag/Size`, `IsTruncated`, `NextContinuationToken`), `GetObject`,
  `HeadObject`, `PutObject`, `DeleteObject`; `If-Match` / `If-None-Match: *` → `412 PreconditionFailed` XML.
- Auth: SigV4 `Authorization` header only (no presigned URLs), signed headers incl. `host`, `x-amz-date`,
  `x-amz-content-sha256` (`UNSIGNED-PAYLOAD` or hex payload hash, verified when hex; `aws-chunked` rejected with
  `NotImplemented`), `if-match`/`if-none-match` (`SigV4Signer.swift:31-39`). Clock skew > 15 min →
  `RequestTimeTooSkewed`; bad key → `InvalidAccessKeyId`; bad signature → `SignatureDoesNotMatch` (these map
  to the native fatal errors, `S3Backend.swift:293-295`).
- **Key → user mapping.** The access key id in the `Credential` scope selects exactly one key record, and so
  exactly one user. The signature is verified with that key's secret before anything else happens.
  - Unknown or revoked key, or a key of a deleted user: `403 InvalidAccessKeyId`.
  - Key of a disabled user: `403 AccessDenied`. Both are `unauthorized` (fatal) in native, which shows its
    existing credentials error.
  - The only bucket is `noteit` (path-style `/s3/noteit/<key>`); any other bucket name gets
    `404 NoSuchBucket`. The bucket is virtual and always maps to the caller's own namespace, so two users
    who both use bucket `noteit` see disjoint stores. No request parameter can name another namespace.
  - Over quota: `400 QuotaExceeded` (§6.2).
- Must accept the canary (`inkwell/.canary/<UUID>` PUT/DELETE).
- **Per-user keys.** Each user manages their own keys in Settings → Account → S3 Access Keys (up to 10):
  - Create: `POST /api/account/s3-keys {label}` returns `{accessKeyId, secretAccessKey}` once. The id is
    `NIK` plus 17 random base32 characters; the secret is 40 base64url characters (30 random bytes).
  - List: `GET /api/account/s3-keys` shows label, id, created and last used, never the secret.
  - Revoke: `DELETE /api/account/s3-keys/<id>`.
  - Rotate: "Replace" creates a new key and revokes the old one in one step,
    `POST /api/account/s3-keys/<id>/rotate`.
  - Secrets are stored in `/data/accounts.json` (mode 0600), because SigV4 verification needs the
    plaintext secret. A key grants access to its owner's ciphertext only.

**Other endpoints** (all non-GET routes also need `X-NoteIt: 1` and a matching `Origin`):

| Route | Auth | Purpose |
|---|---|---|
| `GET /api/health` | none | always 200 `{ok: true, mode: "server"\|"static", needsSetup}` |
| `GET /api/server-info` | none | `ServerInfo` (below) |
| `POST /api/setup` | setup token | create the first admin (§7.1) |
| `POST /api/login`, `POST /api/logout` | — / session | password login; logout |
| `GET /api/session` | session | `{user: {id, username, displayName, role, mustChangePassword, oidcLinked}, quota: {usedBytes, limitBytes?}}` |
| `PATCH /api/account`, `POST /api/account/password`, `POST /api/account/logout-everywhere` | session | display name; change password; end all sessions |
| `GET\|POST\|DELETE /api/account/s3-keys…` | session | per-user `/s3` keys (above) |
| `POST /api/oidc/start`, `GET /api/oidc/callback`, `POST /api/account/oidc/unlink` | varies | OIDC (§7.2) |
| `POST /api/invites/redeem` | invite token | redeem an invite with a password (§7.4) |
| `GET\|POST /api/admin/users`, `PATCH\|DELETE /api/admin/users/<id>`, `POST /api/admin/users/<id>/reset-password` | admin | user management (§7.4) |
| `GET\|POST /api/admin/invites`, `DELETE /api/admin/invites/<id>` | admin | invites (§7.4) |

`ServerInfo` = `{version, commit, sourceUrl, needsSetup, storage: "disk"|"s3", auth: {password: boolean,
oidc: {label: string} | null}}`. It is self-reported, carries no integrity claims (§11.1), and lists no
users.

### 6.4 Direct mode (browser → S3, no server)

**How it ships.** Every release builds the client once (`nuxi generate`) and ships the same files two ways:
1. `noteit-web-static-<version>.tar.gz`, a release asset for any static host (Caddy, nginx, Cloudflare
   Pages, an S3 static website). It contains `noteit-client.json` = `{"mode": "direct"}`.
2. Inside the Docker image. With `NOTEIT_MODE=static` the image serves only those files plus
   `GET /api/health`: no other `/api` routes, no `/s3`, nothing written to `/data`. The server generates
   `noteit-client.json` from `NOTEIT_MODE` (`direct` in static mode, `server` otherwise).

`noteit-client.json` is the only runtime configuration: `{mode: "server" | "direct", sourceUrl?: string}`,
validated strictly (unknown keys or values make the client refuse to start). It is excluded from the signed
file hashes of §11.1 because operators edit it; the verifier checks it against the schema instead. A
direct-mode client has no accounts, no quota and no `/s3`: it is one person's client for one bucket (or one
prefix of a bucket). Families use one bucket or prefix per person, with separate keys.

**Connect wizard.** The user enters endpoint, region, bucket, path-style on/off, an optional key prefix (as
in native), the access key id and secret, then the sync passphrase. The wizard runs a **CORS check** before
saving anything:
1. `ListObjectsV2` on the prefix: proves the origin is allowed and the credentials work.
2. `PUT inkwell/.canary/<UUID>` with `If-None-Match: *`, then read the `ETag` response header: proves PUT,
   the allowed request headers and the exposed `ETag`.
3. The rest of the canary sequence (below), ending with its DELETE.

A CORS rejection reaches script as a `TypeError` with no status. Each step maps it to a specific hint
("origin not allowed", "PUT or If-None-Match not allowed", "ETag not exposed"). After the check, `connect`
runs as in server mode: an empty bucket gets a new v2 store; a v1 store shows the §3.4 item 8 notice.

**Conditional writes in the browser.** Direct mode uses the same `S3Backend` as the server's upstream
driver, which ports the native one:
- Before the first conditional request of a session it runs the native canary once
  (`S3Backend.swift:160-190`) on `inkwell/.canary/<UUID>`: a `PUT If-None-Match: *`; a second one, which must
  get 412; a `PUT` with the bogus `If-Match: "inkwell-canary-mismatch"`, which must get 412; and a `DELETE`
  with the same bogus `If-Match`, which must get 412. Then it deletes the canary. A provider that ignores
  the write preconditions (or answers `501`/`400 NotImplemented`) is marked "conditional writes
  unsupported"; one that ignores the delete precondition is marked "conditional deletes unsupported".
  Whether a provider supports them is decided by this probe at runtime, never assumed per provider. If the
  canary itself fails (network, credentials), nothing is marked and it runs again next time.
- When unsupported, writes use the native fallback (`S3Backend.swift:104-121`): a `HEAD` precondition check,
  an unconditional `PUT`, and a `HEAD` that verifies the stored ETag (a mismatch is `preconditionFailed`).
  Deletes check the precondition with `HEAD` and then delete unconditionally. As in native, this narrows the
  race window but can't close it; Settings shows "Conditional Writes: Not Supported".
- Error classification is the native `classify` (`S3Backend.swift:285-305`): `501` or `400 NotImplemented`
  on a conditional request → unsupported (fallback); `RequestTimeTooSkewed` → `clockSkew` (the browser signs
  with the device clock); `InvalidAccessKeyId`/`SignatureDoesNotMatch`/401/403 → `unauthorized`; 404 →
  `notFound`; 412 and conditional 409 → `preconditionFailed`; 5xx → `network`; anything else →
  `invalidResponse`. A CORS rejection (`TypeError`, no status) → `network`.
- Every request uses `fetch` with `cache: "no-store"`, `credentials: "omit"` and `redirect: "error"`, so no
  HTTP cache can serve a stale manifest or object.
- A 2xx response without a readable `ETag` falls back to a `HEAD`, as native `upload` does. If that is also
  empty, the record fails with `invalidResponse("ETag not exposed")` and the hint to add `ETag` to the
  bucket's CORS expose headers.

**Required CORS configuration.** Allowed origin: exactly the web app's origin (avoid `*`). Methods: `GET`,
`PUT`, `HEAD`, `DELETE`. Request headers: `authorization`, `content-type`, `if-match`, `if-none-match`,
`x-amz-content-sha256`, `x-amz-date`. **Expose header: `ETag`.** Max age 3600.

- **AWS S3**: `aws s3api put-bucket-cors --bucket my-notes --cors-configuration file://cors.json` with

  ```json
  {"CORSRules": [{
    "AllowedOrigins": ["https://notes.example.com"],
    "AllowedMethods": ["GET", "PUT", "HEAD", "DELETE"],
    "AllowedHeaders": ["authorization", "content-type", "if-match", "if-none-match",
                       "x-amz-content-sha256", "x-amz-date"],
    "ExposeHeaders": ["ETag"],
    "MaxAgeSeconds": 3600
  }]}
  ```
- **Cloudflare R2**: bucket → Settings → CORS Policy in the dashboard, which takes the rule list without the
  wrapper:

  ```json
  [{"AllowedOrigins": ["https://notes.example.com"], "AllowedMethods": ["GET", "PUT", "HEAD", "DELETE"],
    "AllowedHeaders": ["authorization", "content-type", "if-match", "if-none-match",
                       "x-amz-content-sha256", "x-amz-date"],
    "ExposeHeaders": ["ETag"], "MaxAgeSeconds": 3600}]
  ```
  or the AWS command above with `--endpoint-url https://<account-id>.r2.cloudflarestorage.com`.
- **MinIO** (community edition): per-bucket CORS (`PutBucketCors`) is not implemented. CORS is server-wide:
  set `MINIO_API_CORS_ALLOW_ORIGIN=https://notes.example.com` (the default is `*`) and restart. MinIO's
  built-in CORS handler already allows the S3 methods and exposes `ETag`; the wizard's check confirms it.
- **Backblaze B2**: B2 CORS rules, for example with the `b2` CLI (v4):

  ```sh
  b2 bucket update --cors-rules '[{"corsRuleName": "noteit",
    "allowedOrigins": ["https://notes.example.com"],
    "allowedOperations": ["s3_get", "s3_head", "s3_put", "s3_delete"],
    "allowedHeaders": ["authorization", "content-type", "if-match", "if-none-match",
                       "x-amz-content-sha256", "x-amz-date"],
    "exposeHeaders": ["ETag"], "maxAgeSeconds": 3600}]' my-notes allPrivate
  ```
- **Garage**: `PutBucketCors` through the S3 API with a key that has the owner flag on the bucket
  (`garage bucket allow --owner my-notes --key <admin-key>`), then the AWS command with
  `--endpoint-url http://garage.lan:3900`. Use a separate, non-owner key in the browser.

**Credential storage in the browser.**
- The vault record in IDB is `{v: 1, salt, iv, ciphertext}`. The plaintext is
  `{endpoint, region, bucket, prefix, pathStyle, accessKeyId, secretAccessKey}`.
- `credKey = PBKDF2-SHA256(passphrase, salt, 210 000)` as a non-extractable AES-GCM-256 key. `salt` is 16
  random bytes created on this device, so the vault opens without network access. AAD is
  `local/credentials/v1`.
- Unlock runs two derivations in the worker: `credKey` to open the vault, then the store key from the
  manifest's salt, as in server mode. A wrong passphrase fails the GCM tag and shows "Wrong passphrase".
  For a plaintext store (a native option), the user picks a device passphrase that protects only the vault.
- The S3 secret is never written to `localStorage`, `sessionStorage`, cookies or URLs, and never leaves
  the device; requests carry only SigV4 signatures.
- "Remember on this device" stores the non-extractable `credKey` and store key in IDB, as in §4.2. Lock
  deletes them. "Sign out & forget this device" deletes the vault and the cache.

**Threat model differences** (also in §11.1). The S3 key lives in the browser. Script running on the app's
origin, a malicious static host, or someone with the unlocked device can use it, and with it delete or roll
back objects (as the storage actor can), but can't read notes without the passphrase. Users should create a
**bucket-scoped key** with object read, write, delete and list rights on that one bucket only: an AWS IAM
policy on `arn:aws:s3:::my-notes` and `arn:aws:s3:::my-notes/*`; an R2 API token with Object Read & Write
for one bucket; a B2 application key restricted to the bucket (optionally `--name-prefix`); a MinIO user with
a bucket policy; a Garage key with `garage bucket allow --read --write`. Trust in the code moves from the
NoteIt server to whoever serves the static files.

## 7. Accounts and auth

One server instance serves several people (a family or small group). Every person has their own account,
their own isolated store (§6.2) and their own sync passphrase.

**Login and the sync passphrase are separate.** Your NoteIt account — a password or a sign-in through your
identity provider — only lets you into the server. Your notes are encrypted with a separate sync passphrase
that never leaves your devices. The server, its admin and the identity provider never see it, resetting a
login password doesn't change or reveal it, and nobody can recover notes if it's forgotten. The server
never derives keys from login credentials.

### 7.1 Accounts, first admin and sessions

- **Account store.** `/data/accounts.json` (mode 0600; written temp + `fsync` + rename under a process-wide
  mutex; has a `schemaVersion`). A user record holds:
  - `id`: an uppercase UUID, immutable, used for the namespace;
  - `username`: `^[a-z0-9][a-z0-9._-]{1,31}$`, unique;
  - `displayName` (≤ 64 characters, always rendered as text);
  - `role`: `admin` or `user`; `status`: `active` or `disabled`;
  - `passwordHash` (argon2id) or none; `oidc: {issuer, sub}` or none;
  - `sessionEpoch`, `mustChangePassword`, `quotaBytes?`, `s3Keys[]`, `createdAt`, `lastSeenAt`.

  Invites live in the same file (§7.4).
- **Passwords.** argon2id (`@node-rs/argon2`) with the OWASP parameters m = 19 MiB, t = 2, p = 1; 10 to 256
  characters, no composition rules. `POST /api/login {username, password}` gives the same 401
  `invalidCredentials` for an unknown user, a wrong password and a disabled account, and hashes a dummy
  password for unknown users so timing doesn't reveal which. Login is rate-limited per IP and per username
  with exponential backoff. `NOTEIT_PASSWORD_LOGIN=false` turns password login off (OIDC only), which
  requires OIDC to be configured.
- **First account = first admin, through the bootstrap token.** The server must not be claimable by
  whoever reaches it first. `needsSetup` is true while no account exists.
  - At startup, when there are no accounts, the server takes its token from `NOTEIT_SETUP_TOKEN` or
    `NOTEIT_SETUP_TOKEN_FILE`. If neither is set, it generates 32 random bytes (base64url), writes them to
    `/data/setup-token` (mode 0600), and prints them once to the container log:
    `NoteIt setup token: … (docker logs <container>)`.
  - `POST /api/setup {token, username, password}` compares the token in constant time and is rate-limited
    like login. It runs under the accounts mutex, so two concurrent requests cannot both succeed. On
    success it creates the user with role `admin`, deletes `/data/setup-token`, clears the in-memory token
    and signs the admin in. The token is **single-use**: any later setup call returns 404.
  - With OIDC configured, the setup page also offers "Set Up With <label>": `POST /api/oidc/start
    {intent: "setup", token}` checks the token, and the callback creates the admin bound to the OIDC
    identity and consumes the token under the same mutex. The allowed-groups rule doesn't apply here,
    because the token already proves control of the server.
  - While setup is pending, every `/api/*` and `/s3` route returns 503 `setupRequired`, **except**
    `GET /api/health`, `GET /api/server-info`, `POST /api/setup`, `POST /api/oidc/start` (setup intent
    only) and `GET /api/oidc/callback`. Health stays green so the Docker `HEALTHCHECK` doesn't mark a fresh
    container unhealthy.
  - **Pre-seeding.** If `NOTEIT_PASSWORD_HASH` (or `NOTEIT_PASSWORD_HASH_FILE` for Docker secrets) is set
    and no account exists at startup, the server creates the admin `NOTEIT_ADMIN_USERNAME` (default
    `admin`) with that hash and skips setup: `needsSetup` is false and `/api/setup` returns 404. Once
    accounts exist the variable is ignored, with a log line.
- **Sessions.** A signed cookie `noteit_session` = HMAC (key `NOTEIT_SESSION_SECRET`, or one generated into
  `/data/session-secret`) over `{uid, epoch, iat, exp}`; `HttpOnly; Secure; SameSite=Strict; Path=/`;
  30-day sliding, re-issued when older than a day.
  - Every authenticated request loads the user and rejects the session with 401 `unauthorized` if the
    user no longer exists, isn't `active`, or `epoch ≠ user.sessionEpoch`.
  - The epoch is bumped by disable, delete, password change, admin password reset and
    "Sign Out Everywhere", so those end every existing session on its next request.
  - While `mustChangePassword` is set, every route except `GET /api/session`,
    `POST /api/account/password` and `POST /api/logout` returns 403 `passwordChangeRequired`.

### 7.2 OIDC sign-in (optional)

Generic OpenID Connect for homelab identity providers (Authentik, Authelia, Pocket ID, Keycloak), using
`openid-client`. It is enabled when `NOTEIT_OIDC_ISSUER` is set; the configuration is validated at startup
through the issuer's discovery document, and the issuer must be HTTPS (except `localhost`).

- **Flow: authorization code + PKCE (S256).** `POST /api/oidc/start {intent, token?}` with
  `intent ∈ {login, link, invite, setup}` creates `state`, `nonce` and the PKCE verifier. It stores them,
  with the intent (and for `link` the current user id, for `invite` the invite id and chosen username), in
  an encrypted, signed `noteit_oidc` cookie (`HttpOnly; Secure; SameSite=Lax; Path=/api/oidc`, 10 minutes),
  and returns the authorization URL; the client navigates to it.
- `GET /api/oidc/callback` checks `state`, redeems the code with the verifier, validates the ID token
  (signature via JWKS, `iss`, `aud`, `exp`, `nonce`) and clears the cookie. Groups are read from the ID
  token, or from userinfo when the claim is missing there.
- The session cookie is `SameSite=Strict`, so the browser won't send it on the cross-site redirect into the
  callback. The callback therefore sets the session cookie and returns a small same-origin page that
  navigates to the app (`<meta http-equiv="refresh">`, no script); the next request is same-site and
  carries the cookie.
- **Users are mapped by `(issuer, sub)`**, never by email or `preferred_username`, which can change or be
  reused. Those only seed the display name and a suggested username.
- **Unknown identity.**
  - `invite` or `setup` intent: the account is created as described for invites (§7.4) or setup (§7.1).
  - `login` intent with `NOTEIT_OIDC_AUTO_PROVISION=true`: an account is created only if the groups claim
    contains one of `NOTEIT_OIDC_ALLOWED_GROUPS`. Auto-provisioning without allowed groups is a startup
    error, so NoteIt never provisions "anyone the IdP knows".
  - Otherwise: "No NoteIt account is linked to this sign-in. Ask your admin for an invite."
- **Admin role from a group claim.** `NOTEIT_OIDC_GROUPS_CLAIM` is a dot path (default `groups`).
  When `NOTEIT_OIDC_ADMIN_GROUPS` is set, the role of an OIDC-linked user is re-evaluated at each OIDC
  login: admin if the claim contains one of those groups, user otherwise. A demotion that would leave no
  active admin is skipped and logged. When it is unset, roles are managed only in NoteIt.
- Disabled users can't sign in through OIDC either.
- **Linking.** A signed-in user links one OIDC identity in Settings → Account → Sign-In Methods (`link`
  intent). Unlinking requires a password on the account, so nobody locks themselves out.
- Scopes: `NOTEIT_OIDC_SCOPES` (default `openid profile`); add the scope your IdP uses to release groups
  (for example `groups` for Authelia and Pocket ID). Keycloak needs a Group Membership mapper on the client.
  The login button reads "Sign In With <NOTEIT_OIDC_LABEL>" (default "Single Sign-On").
- Logout is local; RP-initiated logout is future work (§16).

### 7.3 Forward-auth: dropped

Trusting a `Remote-User` header from a reverse proxy was considered and **dropped** for v1:
- OIDC covers the same identity providers (Authentik and Authelia both act as OIDC providers).
- Doing it safely needs every request to reach the server only through the proxy, plus a trusted-proxy CIDR
  list. A single mistake, such as a published container port or Docker's userland proxy rewriting source
  addresses, lets anyone send the header and sign in as any account, including an admin.
- It would also need a separate answer for `/s3` and for invites.

### 7.4 Multi-user administration and isolation

- **Roles.** `admin` and `user`. Admins have everything a user has, plus Settings → Users.
- **Creating users.** An admin either:
  - creates a user directly (username, display name, role, optional quota); a temporary password is shown
    once and the user must change it at first sign-in; or
  - creates an **invite**.
- **Invites.** `POST /api/admin/invites {role, quotaBytes?, ttlHours?}` returns `{id, token, expiresAt}`.
  - The token is 32 random bytes (base64url). Only its SHA-256 is stored.
  - The link is `<origin>/invite#<token>`, built by the client. The token sits in the URL fragment, so it
    never reaches server logs or `Referer` headers.
  - Expiry: `ttlHours`, default `NOTEIT_INVITE_TTL_HOURS` (72), at most 720.
  - **Single-use.** `POST /api/invites/redeem {token, username, password}`, or the OIDC `invite` intent,
    marks the invite used under the accounts mutex *before* the account is created. An unknown, used,
    expired or revoked token always gets the same 410 `inviteInvalid`. Redemption is rate-limited like
    login.
  - Admins list invites (pending, used, expired) and revoke pending ones.
- **Disable / enable.** Disabling bumps the epoch: sessions get 401 on their next request, the user's `/s3`
  keys get `403 AccessDenied`, and OIDC sign-in is refused. Data is kept. Enabling restores the keys, but
  the user has to sign in again.
- **Delete.** The admin types the username to confirm. The account is marked deleted (all auth fails), its
  keys are removed, the namespace is purged (disk `rm -r`; upstream S3 list + delete), and the record is
  removed. An interrupted purge resumes at startup.
- **Last admin.** Any change that would leave no active admin — disabling, demoting or deleting the last
  one, including yourself — returns 409 `lastAdmin`, checked under the accounts mutex.
- **Password reset.** An admin sets a temporary password; the epoch is bumped and the user must change it.
  The dialog says: "This doesn't give you access to their notes. Notes stay encrypted with their own sync
  passphrase."
- **Quotas.** Per user, set at creation, in an invite or later (§6.2).
- **What admins see**: username, display name, role, status, sign-in methods, quota, used bytes, object
  count and last seen. Never note content, titles or notebook names, which are encrypted with keys the
  server never has.
- **Isolation.** The namespace is derived from the session or the `/s3` key alone (§6.2), keys are validated
  before they're namespaced, and nothing in a request can select another user's namespace. §12 lists the
  tests that guard this.

## 8. Deployment & licensing

- One image `ghcr.io/rutbergphilip/noteit` built from `web/Dockerfile`: multi-stage, `node:24-alpine`,
  `pnpm build` → `.output/`, runs `node .output/server/index.mjs` as uid 1000, `PORT=3000`, `VOLUME /data`,
  `HEALTHCHECK` → `/api/health`. The same image serves the static direct-mode client with
  `NOTEIT_MODE=static` (§6.4). The static tarball `noteit-web-static-<version>.tar.gz` is a release asset
  built from the same commit.
- `docker-compose.yml`: one service, named volume `noteit-data:/data`, env file; documented reverse-proxy
  examples (Caddy/Traefik) because WebCrypto requires a secure context (HTTPS or `localhost`).
- **Environment** (every `…_SECRET`, `…_HASH` and `…_TOKEN` variable also has a `…_FILE` form for Docker
  secrets):

  | Variable | Default | Purpose |
  |---|---|---|
  | `NOTEIT_MODE` | `server` | `server`, or `static` (direct-mode client only; every other variable is ignored except `PORT` and `NOTEIT_SOURCE_URL`) |
  | `NOTEIT_PUBLIC_URL` | — (required in server mode) | external origin; used for the `Origin` check and the default OIDC redirect |
  | `NOTEIT_SOURCE_URL` | `https://github.com/rutbergphilip/noteit` | AGPL source link |
  | `NOTEIT_DATA_DIR` | `/data` | accounts, setup token, session secret and the disk store |
  | `NOTEIT_STORE` | `disk` | `disk` or `s3` |
  | `NOTEIT_S3_ENDPOINT`, `_REGION`, `_BUCKET`, `_PREFIX`, `_PATH_STYLE`, `_ACCESS_KEY_ID`, `_SECRET_ACCESS_KEY` | — | upstream S3 driver |
  | `NOTEIT_SETUP_TOKEN` | generated | bootstrap token for the first admin |
  | `NOTEIT_ADMIN_USERNAME`, `NOTEIT_PASSWORD_HASH` | `admin`, — | pre-seed the first admin |
  | `NOTEIT_PASSWORD_LOGIN` | `true` | allow password login |
  | `NOTEIT_SESSION_SECRET` | generated | session cookie key |
  | `NOTEIT_OIDC_ISSUER`, `_CLIENT_ID`, `_CLIENT_SECRET`, `_REDIRECT_URL`, `_SCOPES`, `_LABEL` | —, —, —, `<PUBLIC_URL>/api/oidc/callback`, `openid profile`, `Single Sign-On` | OIDC (§7.2) |
  | `NOTEIT_OIDC_GROUPS_CLAIM`, `_AUTO_PROVISION`, `_ALLOWED_GROUPS`, `_ADMIN_GROUPS` | `groups`, `false`, —, — | provisioning and roles (§7.2) |
  | `NOTEIT_INVITE_TTL_HOURS` | `72` | invite lifetime (max 720) |
  | `NOTEIT_DEFAULT_QUOTA_MB` | unlimited | quota for new users |
  | `NOTEIT_MAX_OBJECT_MB` | `50` | body limit per object |

- **AGPL-3.0 §13**: every page footer links "Source" to `NOTEIT_SOURCE_URL` (default: the canonical repo
  `https://github.com/rutbergphilip/noteit`) plus version/commit; `/api/server-info` exposes the same, and in
  direct mode `noteit-client.json`'s `sourceUrl` overrides the built-in default. Operators who modify the
  code must point it at their fork — stated in the deployment docs.

## 9. Editor (TipTap) — native feature mapping

| Native feature (HANDOFF §5.3, `FormatCommand.swift`) | Native representation | noteit-doc | TipTap |
|---|---|---|---|
| Title / Heading / Subheading / Body | sentinel 37/39/41/29 | `heading 1/2/3`, `paragraph` | `Heading` (levels 1-3), `Paragraph` + align/indent attrs |
| Code block | sentinel 31 per paragraph, mono base font, all marks allowed | `codeBlock{align?}` with inline content | custom `NoteItCodeBlock` node (`marks: '_'`, `whitespace: 'pre'`, inline images); not the stock `CodeBlock`, which forbids marks |
| Quote | sentinel 33 | `blockquote` | `Blockquote` |
| Divider | sentinel 35 + NBSP | `horizontalRule` | `HorizontalRule` |
| Bulleted / numbered / checklist, nesting | text marker + indent | `listItem{kind,level,number,checked}` | custom flat `NoteItListItem` node, Tab/Shift-Tab change `level`, Enter continues, empty Enter exits |
| Toggle checkbox / strike-through checked | ☐/☑, derived style | `checked` | click on marker toggles; CSS derives style |
| Bold/italic/underline/strike | font traits / attrs | marks | starter-kit marks + `Underline` |
| Inline code | mono + background | `code` | `Code` |
| Link | `.link` | `link{href}` | `Link` (autolink, `openOnClick` with ⌘/Ctrl) |
| Highlight (6 swatches) | `.backgroundColor` | `highlight{color}` | `Highlight` multicolor |
| Text color (9 + custom) | `.foregroundColor` (light values) | `textColor{color}` | `TextStyle` + `Color`, dark-mode mapping in CSS |
| Bigger/smaller font | absolute pt 8-96 | `fontSize{delta}` | custom mark |
| Alignment | paragraph style | `align` attr | `TextAlign` |
| Indent/outdent | head indent step 24 | `indent` attr | custom commands |
| Tables (header row, widths) | `NSTextTable` | `table…` | `@tiptap/extension-table` + header row, column resize → `columnWidths` |
| Images / files | `NSTextAttachment` | `image`/`attachment` | custom node views rendering `blob:` URLs |
| Markdown-as-you-type (`Editor/MarkdownShortcuts.swift`) | prefix + space at paragraph start; inline closers | — | input rules: `#`/`##`/`###` → title/heading/subheading; `>` quote; `-` `*` `+` `•` bullet; `N.`/`N)` (1-3 digits) numbered; `[]` `[ ]` checklist, `[x]` checked; a line that is ```` ``` ```` → code block; `---` `***` `___` `—` → divider; `**x**` bold, `*x*` italic, `` `x` `` code, `~~x~~` strike |
| Hashtags | derived | text | decoration plugin styling `#tag` |

### 9.1 Shortcuts (browser-safe)

Native bindings verified in `Sources/NoteIt/Editor/FormatCommand.swift:125-152` (editor) and
`Sources/NoteIt/App/NoteItApp.swift:36-70` (menus). "Mod" = ⌘ on macOS, Ctrl elsewhere; "Alt" = ⌥.

| Action | Native | Web | Reason for change |
|---|---|---|---|
| New note | ⌘N | Alt+N (macOS: ⌃⌥N) + toolbar button | Mod+N opens a browser window and can't be intercepted |
| New notebook | ⌘⇧N | Alt+Shift+N | Mod+Shift+N = incognito window |
| Search notes | ⌘F | Mod+F focuses search (second press passes through to browser find) | |
| Find in note / next / previous | ⌥⌘F / ⌘G / ⇧⌘G | browser find (Mod+F twice) | native find bar has no web equivalent in v1 |
| Bold / italic / underline | ⌘B / ⌘I / ⌘U | same | |
| Strikethrough | ⇧⌘X | same | |
| Inline code | ⇧⌘E | same | |
| Title / Heading / Subheading / Body | ⌥⌘1 / 2 / 3 / 0 | Mod+Alt+1 / 2 / 3 / 0 | |
| Code block / Quote | ⌥⌘4 / ⌥⌘5 | Mod+Alt+4 / 5 | |
| Bulleted / numbered / checklist | ⇧⌘8 / ⇧⌘7 / ⇧⌘L | same | |
| Toggle checkbox | ⇧⌘U | same | |
| Indent / outdent | ⌘] / ⌘[ | same + Tab / Shift+Tab in lists | Mod+[ ] is history navigation in some browsers; handler calls `preventDefault` while the editor has focus (verified in Playwright) |
| Align left / center / right | ⇧⌘{ / ⇧⌘\| / ⇧⌘} | Mod+Alt+Shift+[ / \\ / ] | ⇧⌘[ ] switch tabs in Chrome/Safari |
| Link | ⌘K | same | |
| Highlight | ⇧⌘H | Mod+Alt+H | ⇧⌘H opens Home in Safari/Chrome on macOS |
| Bigger / smaller text | ⌘= / ⌘− | Mod+Alt+= / Mod+Alt+− | Mod± is page zoom |
| Divider | ⌥⇧⌘D | same | |
| Clear formatting | ⌥⌘\ | same | |
| Show notes window | ⌘0 | — | not applicable |
| Settings | ⌘, (menu bar popover) | gear button | Mod+, unreliable in browsers |

A Playwright test (plan task 3.8) asserts every web binding fires in Chromium, WebKit and Firefox and that no
binding uses a browser-reserved combination (Mod+N/T/W/Q, Mod+Shift+N/T/W, Mod+Shift+[ ], Mod+L, Mod+±).

## 10. UX parity (HANDOFF §5-6, NoteIt design system)

- **Three panes**: sidebar and note list sized by the layout tokens `sidebar-w` and `note-list-w` (ideal width
  and min–max range as documented in `design/tokens.md`), editor content max-width 760 (HANDOFF), resizable
  splitters persisted; below 900 px collapses to two panes, below 600 px one pane with back
  navigation (PWA on phones).
- **Sidebar**: Library rows All Notes / Pinned / Recent (7 days) / Conflicts (only when any exist); Notebooks
  shown as `NotebookGlyph` (`design/components/NotebookGlyph.md`; SF Symbol → open-licensed inline SVG mapping
  table for the 32 curated symbols, fallback `book`), drag-to-reorder (`sortIndex`), rename, recolor; Tags
  section from derived tags.
- **Note list**: cards with title, preview, date, pin, conflict badge; sort by `updatedAt` desc with pinned first;
  empty states copied from HANDOFF, laid out as `design/components/EmptyState.md`.
- **Search**: fold rules of §2.8, in the worker.
- **Conflicts**: badge "Conflict" + source device on copies; "Mark Resolved" clears fields with a new revision;
  Conflicts library filter.
- **Sync pill** (HANDOFF §5.10; labels from `Views/SyncStatusView.swift:19-28`): Synced / Syncing / Offline /
  Sync Issue / Locked / Sync Off, with the same 700 ms delay before showing "Syncing" for background passes
  (`SyncController.swift:509-515`) and click → details popover (last sync, error, "Sync now").
- **Dark mode**: `prefers-color-scheme` plus manual override; stored light text colors are adapted at render
  time by the same luminance inversion native uses (`usesAdaptiveColorMappingForDarkAppearance`,
  `NoteItTextView.swift:54`) approximated by an OKLCH lightness flip, tested with snapshots.
- **Look and copy**: the NoteIt design system (§4.1). Colors, type, spacing, radii, shadows and motion come
  from `design/tokens.css` and its light/dark themes; components follow `design/components/`; labels and
  messages follow `design/BRAND.md` (Title Case, "NoteIt"). Where HANDOFF and the design system differ on
  appearance, the design system wins; HANDOFF still defines behaviour.
- **Typography**: the type tokens in `design/tokens.css`. The editor body size setting defaults to **15**,
  adjustable from 11 to 24, and every editor style scales from it (`design/tokens.md`, Editor `body`;
  native `PrefDefault.editorFontSize = 15`, `Settings/Preferences.swift:13`).

## 11. Security

### 11.1 Threat model

| Actor | Can | Cannot |
|---|---|---|
| Storage (bucket/disk, backups) — **untrusted** | see sizes, counts, timing, UUIDs, device IDs in key names, the plaintext manifest; delete or roll back objects | read or undetectably modify content (AES-GCM + key-bound AAD) |
| NoteIt server, honest operator — **semi-trusted** | all of the above for every user; see login identities, IPs and access patterns; read `/data/accounts.json` (password hashes, `/s3` secrets), so reach any user's ciphertext | read content |
| Another user on the same instance | use their own store and `/s3` keys | list, read, write or delete another user's objects through REST or `/s3`; see the user list (admins only); decrypt anything |
| Instance admin (app role) | create, disable and delete users (deleting destroys that user's data); set quotas; reset a login password and so sign in as that user and fetch their ciphertext | decrypt it: the sync passphrase is separate from login (§7) and never reaches the server |
| Identity provider admin (OIDC) | sign in as any OIDC-linked user, like an instance admin; with an admin group claim, become an instance admin | decrypt content |
| NoteIt server, **compromised** (or a malicious operator) | everything above, plus serve modified HTML/JS/service worker, and capture the passphrase and every note the next time a user unlocks in the browser | read content of users who only use the native app, or who don't unlock in the browser while it is compromised |
| Static host of a direct-mode client (§6.4) — trusted like the server above | serve modified code that captures the passphrase and the S3 key the next time a user unlocks | read anything for users who don't unlock in the browser while it is compromised |
| Holder of a direct-mode S3 key (script on the app origin, an unlocked device with "Remember" on) | list, delete or roll back objects in the buckets that key reaches, like the storage actor | read content without the passphrase; reach other buckets if the key is bucket-scoped (recommended, §6.4) |
| Network attacker | nothing with valid HTTPS | — |
| Malicious note content (from a peer device or a tampered-but-validly-encrypted store) | — | run script: rendering goes through the schema, plus CSP (§11.2) |

**Honest limitation:** web E2EE protects against the *storage*, not against the server that delivers the
code. A compromised server can serve JavaScript that captures the passphrase. No in-browser mechanism
prevents this:
- **SRI** only guards against accidental corruption or a tampered sub-resource. The same server serves the
  HTML that declares the hashes, so it can change both.
- **Self-reported hashes** (for example in `/api/server-info`) are worthless for the same reason, so the
  server publishes none.
- An installed **PWA's service worker** is replaced whenever the server serves a new one.

The native app, a signed binary, is the trust anchor. Users who don't trust their server host should not
unlock in the browser.

What v1 does provide (plan task 4.6), as **detection** only:
1. **Signed release manifest.** CI builds the client reproducibly. It publishes `web-client-<version>.json`,
   listing the SHA-256 of every file in `.output/public`, as a GitHub release asset signed with the
   project's minisign key. The public key is committed in the repo (`scripts/noteit-release.pub`) and
   printed in each release's notes.
2. **Out-of-band verifier.** `node scripts/verify-web-client.mjs https://notes.example.com --expect <version>`
   (or `--latest`) runs from any machine.
   - **The expected version comes from the user, never from the server.** `--expect` takes it on the
     command line. `--latest` reads the newest non-prerelease tag from the GitHub releases API for the
     canonical repo. Without either flag, the verifier refuses to run.
   - It downloads and verifies the signed manifest for the *expected* version. It checks that the
     `version` field inside the signed manifest equals the expected version, so a renamed older manifest
     is rejected.
   - It fetches the served `index.html`, every referenced asset and `sw.js`, and compares them with that
     manifest.
   - `/api/server-info` is only read to report the claimed version. If it differs from the expected
     version, or if the served files match a different signed release, the verifier fails with
     `version mismatch (possible rollback)`. This blocks serving an older, legitimately signed release
     with known vulnerabilities.
   - `--allow-older` downgrades that failure to a warning, for operators who pin a release on purpose.
     The files must still match the signed manifest of the version the server claims.

   The verifier can only detect *untargeted* tampering. A server that fingerprints clients could serve
   honest files to the verifier and malicious ones to the victim. The docs say so.

A version-pinned static client on an origin the user trusts is the real fix. Direct mode (§6.4) makes this
possible in v1 for bucket users: anyone can verify the signed `noteit-web-static-<version>.tar.gz` and host it
on an origin they control. The same files are covered by the signed release manifest and the verifier. An
official, project-hosted pinned client, and a pinned client that talks to a NoteIt server on another origin,
remain open (§15) and are not v1 guarantees.

### 11.2 Controls

- CSP via `nuxt-security` (server mode, sent as a header): `default-src 'none'; script-src 'self' 'strict-dynamic' 'nonce-…'; style-src 'self'
  'unsafe-inline'` (ProseMirror writes `style` attributes for alignment/colors; inline *scripts* remain
  forbidden); `img-src 'self' blob: data:; connect-src 'self'; worker-src 'self' blob:; manifest-src 'self';
  font-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'; object-src 'none'`. Plus HSTS,
  `X-Content-Type-Options`, `Referrer-Policy: no-referrer`, COOP/CORP. Trusted Types is a stretch goal.
- **Direct mode.** A static host can't add per-request nonces, so the generated HTML carries a `<meta>` CSP
  with **hash-based** `script-src` and `connect-src 'self' https: http://localhost:* http://127.0.0.1:*`
  (the bucket endpoint is user-chosen); the rest matches the server policy. `frame-ancestors` can't be set
  from `<meta>`: `NOTEIT_MODE=static` sends the full policy as a header, and the deployment docs give the
  header for Caddy and nginx. In server mode the header policy also applies, and browsers enforce both, so
  `connect-src` stays `'self'`.
- No third-party scripts, fonts, analytics or CDNs; all assets self-hosted.
- Note content never goes through `innerHTML`: documents are parsed with `Node.fromJSON`, `doc.check()`; invalid
  docs fall back to read-only plain text. Link `href` allowlist `http:`, `https:`, `mailto:`, `tel:`; colors must
  match `^#[0-9A-Fa-f]{6}$`; images render only from `blob:` URLs created from attachment bytes with an
  allowlisted image MIME; SVG is never rendered inline (download chip).
- Paste: HTML clipboard data goes through DOMPurify (strict profile) *before* ProseMirror's DOM parser.
- Server: CSRF via `SameSite=Strict` + `X-NoteIt` header + `Origin` check against `NOTEIT_PUBLIC_URL`;
  OIDC `state`, `nonce` and PKCE; key regex; size limits; rate limits on login, setup and invite
  redemption; no directory traversal (keys never become paths without validation, and only through
  `namespacedKey`, §6.2).
- Playwright asserts no request body/URL/header contains the passphrase or raw key bytes, and that CSP reports
  zero violations.

## 12. Testing

1. **Golden vectors** (`fixtures/golden/*.json`), written by Swift tests when `NOTEIT_WRITE_VECTORS=1`, verified
   otherwise: `pbkdf2.json` (incl. 210 000 iterations), `aesgcm.json` (fixed nonces via CryptoKit directly),
   `manifest.json` (key check), `envelopes.json` (envelope/tombstone/device/inner metas, ISO + Double2001),
   `planner.json` (exhaustive cartesian product of planner inputs → action), `store-snapshot.json` (a small sealed
   store + passphrase), `engine-scenarios.json` (scripted multi-device traces), `derive.json` (title/preview/tags/
   search fold), `doc-convert.json` (noteit-doc fixtures + expected derived text).
2. **Reverse vectors** `fixtures/golden/from-web/*.json` written by Vitest, decoded by a Swift test (catches date/UUID
   case/base64 drift).
3. **Swift**:
   - `NoteItSyncTests` (existing 149).
   - New format-v2 tests:
     - session refresh when the manifest ETag changes;
     - **automatic upgrade on connect**: a v2 client's first clean pass on a v1 store upgrades it with no
       user action, swaps the session before the sweep, and the first note it then exports is noteit-doc;
     - a pass with errors leaves the store at v1, and the next clean pass upgrades it;
     - a plaintext v1 store upgrades without gaining `encryption`;
     - two v2 clients upgrading at once: one PUT wins, the other gets 412 and adopts the v2 manifest;
       412 with different encryption gives `encryptionMismatch`; 412 on a still-v1 manifest retries later;
     - new stores are created at v2; a v1-only build refuses a v2 store with `unsupportedFormat`;
     - conversion as a revision-preserving meta+body rewrite, which peers see as `.pull` and never as a
       conflict;
     - a conversion 412 leaves the record in `legacyBodies` and it converts on a later pass;
     - **an old-client race**: a simulated v1 engine edits a note between the upgrade's clean pass and its
       conversion. The conversion gets 412, the next pass pulls the old client's RTFD edit, and the pass
       after that converts it. No revision is lost and no conflict copy is created. The reverse order is
       also tested: an old client editing *after* conversion gets 412 and then a non-fatal per-record
       `importConflictCopy` error. Its local edit survives.
   - `NoteItDocTests` fidelity suite, including the §3.3 code-block command table, a link and an image.
4. **TS unit** (Vitest): core against all vectors; engine scenarios ported from the 53 `SyncEngineTests` using an
   `InMemoryBackend`; fast-check property tests for derivations and doc validation; server routes with
   `@nuxt/test-utils`. Also:
   - `connect` on a v1 store returns the "Open NoteIt on your Mac…" state and never writes;
   - `S3Backend` with a mocked `fetch`: the canary (supported, ignored `If-None-Match`, ignored `If-Match`,
     `501`/`NotImplemented`), the HEAD-verify fallback, `cache: "no-store"` on every request, the
     missing-`ETag` HEAD fallback and `invalidResponse("ETag not exposed")`, and CORS `TypeError` → `network`;
   - the credential vault: round trip, wrong passphrase, nothing in `localStorage`/`sessionStorage`;
   - **isolation**: user A can't read, write, delete or list user B's keys through REST or `/s3`,
     including `..`, percent-encoded, mixed-case and other-bucket attempts; fast-check over random keys
     asserts every driver path stays under the caller's namespace;
   - a disabled user's sessions get 401 and `/s3` keys get `AccessDenied`; a deleted user's keys get
     `InvalidAccessKeyId`; revoked and rotated keys stop working; password change and "Sign Out
     Everywhere" end other sessions;
   - invites: single use (two concurrent redemptions, one wins), expiry, revoke, one error for every
     invalid token;
   - quota: REST 507 and `/s3` `QuotaExceeded` at the limit, DELETE always allowed, exempt control objects,
     concurrent uploads can't overshoot;
   - last admin: disabling, demoting or deleting the last active admin (including yourself) returns 409,
     and an OIDC admin-group demotion of the last admin is skipped;
   - OIDC against a mock provider: PKCE S256, `state`/`nonce` mismatch rejected, mapping by `(iss, sub)`
     even when the email changes, auto-provisioning only for allowed groups, admin from the group claim,
     startup error for auto-provisioning without allowed groups;
   - setup: token required and single-use (also via OIDC), pre-seeded admin, `needsSetup` gating.
5. **Playwright E2E**: first-run setup (rejected without the bootstrap token; the token can't be reused), login, create store, unlock/lock, CRUD notes/notebooks, formatting
   round-trip, offline edit → reconnect, two browser contexts producing a conflict copy, shortcuts, CSP, no
   passphrase on the wire. Also:
   - `multiuser.spec.ts`: an admin invites a second user, who redeems the link, creates a store with a
     different passphrase and syncs; neither sees the other's notes; the admin disables the user, whose open
     tab drops to the login screen; the admin can't delete themselves as last admin; a quota-limited user
     sees "Storage full";
   - `oidc.spec.ts` against a mock provider: sign in, link from Settings, invite through OIDC;
   - the v1-store notice: a store written by a v1 engine shows "Open NoteIt on your Mac once to finish
     setting up web access", and the app continues by itself after the store is upgraded;
   - **`direct-s3.spec.ts`** (`scripts/direct_s3_e2e.sh`, opt-in, Floci on :4566): the static build with
     `{"mode": "direct"}` connects to a Floci bucket with CORS configured, passes the wizard's CORS check,
     creates a store, syncs between two browser contexts and survives a reload (vault unlock). Negative
     cases: missing `ETag` exposure, wrong origin, and a bucket without CORS each show the matching hint.
     The script first checks that Floci enforces bucket CORS; if it doesn't, the negative cases run against
     MinIO with `MINIO_API_CORS_ALLOW_ORIGIN` instead.
6. **Interop** (`scripts/interop_tests.sh`, opt-in, mirrors `scripts/live_s3_tests.sh` with Floci on :4566):
   config A — server `disk` store, two users, each with their own native client via `/s3` (own key) and web via
   `/api/storage`; config B — server upstream Floci S3, native direct to Floci, web via the proxy; config C —
   direct mode: native and the static web client both direct to a CORS-enabled Floci bucket. Two native drivers run in both configs:
   - **Engine level:** opt-in `LiveInteropTests`, using `SyncEngine`, `FakeLocalStore` and NoteItDoc
     bodies. It is fast and covers protocol edge cases.
   - **Real app (release gate):** the app binary in the existing debug self-test mode, extended as
     `NOTEIT_SYNC_SELFTEST=interop`, with `NOTEIT_DATA_DIR=<repo>/.selftest/interop-<config>` and
     `NOTEIT_SYNC_CONFIG` pointing at the store.
     - It drives a real `NoteStore` through `NoteStoreSyncAdapter` and `SyncController`'s session code.
     - It authors notes through the real editor formatting path (`TextFormatter` applying every
       `FormatCommand` through `perform(_:)`, a table, every list kind, the full §3.3 code-block command
       list, a link, PNG and TIFF attachments).
     - It syncs, then waits for the web side's step file. It pulls the web-authored notes and asserts on
       the resulting `NSAttributedString`: block sentinels, list markers and levels, fonts and traits,
       colors, alignment, attachments by hash.
     - It exits non-zero on any failure.

   Web side = Playwright. Scenarios:
   - create on each side and read on the other, with formatted content and attachments compared
     structurally;
   - concurrent edit → one conflict copy on each side;
   - delete → tombstone;
   - a legacy RTFD note is read-only on the web until a native v2 pass converts it;
   - automatic v1→v2 upgrade: the web shows the notice on a v1 store, the native app upgrades on connect
     with no user action, the web then reads every note, and peers pull converted notes without conflicts;
   - config A only: user B's native client, with B's key, never sees user A's objects.

## 13. Risks

| Risk | Mitigation |
|---|---|
| NSAttributedString ⇄ doc fidelity gaps (foreign paste) | documented fallbacks; random-doc round-trip tests; read-only for unknown nodes |
| Old native session keeps writing RTFD after upgrade (§2.12) | per-record `bodyFormat`, lazy reconversion, web read-only fallback |
| Planner/engine drift between Swift and TS | exhaustive planner vectors + scenario traces in one CI |
| Large inline images bloat bodies and re-uploads | size cap with warning; content-addressed attachments later |
| Browser storage eviction | `navigator.storage.persist()`; remote is source of truth |
| Safari ITP clears IDB after 7 days without interaction | documented; installed PWA exempt; re-sync is lossless |
| Compromised server serves malicious JS | cannot be prevented in-browser; honest threat model, signed release manifest + out-of-band verifier (detection only), native app as anchor, pinned static client as future work |
| S3-subset incompatibilities with other clients | only NoteIt + rclone are supported; conformance tests reuse Swift `S3Backend` |
| Shortcut collisions per browser/OS | Playwright matrix (Chromium/WebKit/Firefox) |
| A namespace bug leaks one user's ciphertext to another | one `namespacedKey` choke point fed only by the session or `/s3` key; key validation first; property tests and cross-user E2E (§12); content stays encrypted per user |
| Admin or IdP misconfiguration grants access | auto-provisioning requires allowed groups; last-admin guard; invites single-use and expiring; forward-auth dropped (§7.3) |
| Direct mode: CORS misconfigured or `ETag` not exposed | connect wizard CORS check with specific hints; provider examples (§6.4) |
| Direct mode: S3 key stolen from the browser | sealed vault, never plaintext storage; bucket-scoped keys recommended; data stays encrypted |
| Upstream-S3 usage drifts if something else writes the prefix | server documented as the only writer; usage recomputed at startup |

## 14. Assumptions

- A1: Upgrading a store automatically when an up-to-date NoteIt for Mac connects is acceptable. Pre-release
  builds without v2 support stop syncing with that store until updated (§3.4); this is fine because NoteIt
  has not been released.
- A2: Homelab users terminate TLS at a reverse proxy (WebCrypto needs a secure context).
- A3: An instance serves a family or small group (up to about 20 users), so a JSON account file and in-memory
  usage counters are enough.
- A4: Notes rarely exceed tens of MB including images (inline attachments).
- A5: The curated SF Symbol list (32) can be mapped to open-licensed SVG icons compatible with AGPL; web
  chrome uses the NoteIt icon set (`design/assets/icons`).
- A6: Direct-mode users can set CORS rules on their bucket, or on their MinIO server.

## 15. Open questions for the owner

1. Attachment size cap per note (proposed 25 MB), and whether to build content-addressed attachments in v1.
2. HEIC→JPEG and TIFF→PNG conversion on export — acceptable quality/size trade-off?
3. Should the web create sample notes for brand-new stores?
4. Priority of Safari/iOS PWA support.
5. Web trash UI (restore deleted notes from the local trash) in v1?
6. Should the project host an official version-pinned static web client on a separate origin, and should a
   pinned client be able to use a NoteIt server on another origin (§11.1)? Who holds the release-signing
   (minisign) key?
7. Normalize passphrases to NFC? Requires a KDF version field in the manifest; affects existing stores.

Resolved since the previous revision: repository and image names (§8), multi-user (§7), the format upgrade
(automatic, §3.4), direct mode (§6.4), OIDC (§7.2), the default body size (15, §10), the minimum native
version (any v2 build; pre-release builds without v2 get `unsupportedFormat`), and the one-time re-download
during conversion (accepted, explained to users in §3.4 item 6).

## 16. Future work

- **Shared notebooks between users.** Each store is encrypted with its owner's key, so sharing needs key
  sharing: a per-notebook key wrapped for each member (which needs per-user public keys), a store layout for
  shared notebooks, and a new conflict and revocation story. Out of scope for v1.
- OIDC RP-initiated logout and back-channel logout.
- An official pinned static client (§15 question 6).
- Content-addressed attachments (§15 question 1).
- A PWA share target.
