# Inkwell Web — Self-Hostable Web App Design

Status: proposed · Date: 2026-10-13 · Companion plan: `docs/plans/2026-10-13-web-app.md`

## 1. Goal

Ship a **self-hostable Inkwell web app** (Nuxt) that is a *full sync peer* of the native macOS app: same
end-to-end-encrypted remote store, same conflict semantics, same notebooks/pins/tags, and an editor that
round-trips every formatting feature the native editor produces. The pitch for the AGPL-3.0 open-source
release is **native app + self-hosted web app + sync**, deployable on a homelab with one Docker image.

Design principles:

1. **The storage format is the contract.** The web app is a second implementation of
   `InkwellSync` plus the note model, not a client of a server-side API that understands notes.
2. **Zero knowledge server.** The Inkwell server only ever stores and relays ciphertext. Passphrase and key
   live only in the browser (and on native devices).
3. **One image, one volume** for homelabs; the same server also gives native apps a no-cloud sync target.

### Non-goals (v1)

- Menu bar icon, global hotkeys, Quick Capture panel, launch at login (OS features; a PWA share target may come later).
- Multi-user / multi-tenant servers (one store, one user per instance).
- Direct browser→S3 mode (architecturally possible later because `@inkwell/core` is isomorphic; see §6.4).
- Real-time collaborative editing; CRDTs. Inkwell's model stays "conflict copies, never silent merge".
- Rollback/freshness protection against a malicious store (same as native today).
- Server-side search, previews, or any server-side plaintext.
- iOS/Android native apps (the PWA is the mobile story).

## 2. Existing format — byte-level reference (verified against Swift source)

Everything in this section is a fact about the code at the time of writing, cited `file:line`. A TypeScript
implementer must be able to interoperate from this section alone. "Double2001" means a JSON number of
seconds since 2001-01-01T00:00:00Z (Apple reference date; `Date.timeIntervalSinceReferenceDate`), i.e.
`unixSeconds - 978307200`.

### 2.1 Key layout

`RemoteLayout.root = "inkwell/v1/"` (`Sources/InkwellSync/Engine/RemoteLayout.swift:4`).

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
(`Sources/Inkwell/Model/NoteStore.swift:798-808`): `.prettyPrinted`, `.sortedKeys`, **`.iso8601`** dates.
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

### 2.6 Inner metas (`Sources/Inkwell/Model/Models.swift`)

`NoteMeta` (`Models.swift:14-28`): `conflictOriginalID?: UUID`, `conflictSource?: string`, `createdAt: ISO`,
`id: UUID`, `isPinned: bool`, `notebookID?: UUID` (nil = no notebook), `preview: string`,
`revision?: UUID`, `tags: [string]`, `title: string`, `updatedAt: ISO`.

`Notebook` (`Models.swift:4-12`): `colorHex: "#RRGGBB"`, `id`, `modifiedAt?: ISO`, `name`,
`revision?: UUID`, `sortIndex: Int`, `symbol: string` (an SF Symbol name from the curated picker; the palette
has 10 colors — see HANDOFF §6).

### 2.7 Bodies today

A note body is the **flattened RTFD** of the editor's `NSAttributedString`
(`Sources/Inkwell/Model/NoteStore+Sync.swift:127-139`; `serializeBody` uses `rtfd(from:)`, bytes start with
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
| Sanitized HTML subset | good via `NSAttributedString(html:)`, but import is WebKit-backed, slow, main-thread, and lossy (lists become `NSTextList`, not Inkwell markers; sentinels lost) | data URIs / cid | must sanitize every render (XSS surface) | poor | custom writer + parser anyway |
| Markdown + extensions | cannot express text color, highlight, underline, alignment, font size, column widths without HTML escapes | links to files | good | best | custom parser |
| **ProseMirror/TipTap JSON with an Inkwell schema** | exact: we define one node/mark per native feature | content-addressed map | rendered through a schema, no HTML parsing | good (structured) | Codable types + converter |

**Decision: "inkwell-doc" — a versioned, ProseMirror-compatible JSON document with an Inkwell-specific
schema.** It is the editor's native model on the web (TipTap), maps 1:1 onto the native block/mark
model, needs no HTML sanitization on render, and is easy to validate (`Node.fromJSON` + `check()`).
Markdown export stays a separate, lossy feature.

### 3.2 Body container (plaintext before sealing)

UTF-8 JSON:

```json
{
  "format": "inkwell-doc",
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

### 3.3 Schema (`inkwell-doc` v1)

Nodes (block):

| Node | Attrs | Content | Native equivalent |
|---|---|---|---|
| `doc` | — | `block+` | whole attributed string |
| `paragraph` | `align?: "left"\|"center"\|"right"\|"justify"`, `indent?: 0-8` | inline* | body paragraph (sentinel 29) |
| `heading` | `level: 1\|2\|3`, `align?`, `indent?` | inline* | 1 = Title (37), 2 = Heading (39), 3 = Subheading (41) |
| `codeBlock` | `align?`, `indent?` | inline* (all marks, `hardBreak`, `image`, `attachment`) | **one** code paragraph (31), monospaced base font; consecutive `codeBlock` nodes render as one visual block |
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

  | `FormatCommand` | Native effect in a code paragraph | inkwell-doc result |
  |---|---|---|
  | `bold`, `italic` | font trait on the monospaced font (`:99-115`) | `bold` / `italic` mark |
  | `underline`, `strikethrough` | line attribute (`:117-130`) | mark |
  | `inlineCode` | **no-op**: guarded by `blockKind != .code` (`:132-135`) | unchanged; the toolbar shows it off (`:72`) |
  | `textColor(c)`, `textColor(nil)`, `customColor` (color panel → `NSTextView.changeColor`) | `.foregroundColor` set or removed | `textColor` mark set or removed |
  | `highlight(c)`, `highlight(nil)`, `toggleHighlight` | `.backgroundColor` set or removed | `highlight` mark |
  | `fontBigger`, `fontSmaller` | size ±1 clamped to 8–96 (`:169-182`) | `fontSize{delta}` relative to the code base size |
  | `align(.left/.center/.right/.justified)` | paragraph alignment (`:472-486`) | `codeBlock.align` `left/center/right/justify` |
  | `indent`, `outdent` | **no-op**: code paragraphs get an identity edit (`:423-433`) | unchanged. `codeBlock.indent` exists only because `block(.code)` keeps the level of an indented paragraph it converts (`:290-294`, `EditorStyles.swift:282-285`). |
  | `list(_)`, `toggleCheckbox` | **no-op**: code paragraphs are filtered out (`:305-309`), and there is no checkbox marker | unchanged |
  | `block(.code)` again | toggles the paragraphs back to body (`:273`); the font goes to body and keeps italic only (`:234-240`) | `paragraph`, keeps marks except bold-from-font |
  | `block(.title/.heading/.subheading/.body/.quote)` | converts the paragraph out of code | that block |
  | `link` | `.link` on the range (`:666-731`) | `link` mark |
  | `image` | inline attachment at the caret (`:754-776`) | inline `image` / `attachment` inside `codeBlock` |
  | `divider`, `block(.divider)`, `table(r,c)` | inserted *after* the paragraph (`blockInsertionPoint`, `:506-530`) | sibling block; the code block is unchanged |
  | `clearFormatting` | removes colors/lines, sets the body font, resets the paragraph style to body with natural alignment (`:778-806`) | the paragraph **leaves** the code block: a plain `paragraph` without marks |
  | `addRowAbove`, `addRowBelow`, `deleteRow` | table-only; no effect outside a table | unchanged |
- Absent attrs mean defaults (`align` natural/left, `indent` 0).

### 3.4 Versioning and migration

1. **Envelope** gains optional `bodyFormat: string` — `"inkwell-doc/1"`. Absent ⇒ legacy RTFD. Old engines
   ignore it (unknown key) and drop it when they re-publish — which is correct, because they only ever
   publish RTFD.
2. **`RecordPayload`** (engine ↔ app boundary) gains `bodyFormat` so the engine stays body-agnostic: the
   adapter sets it on export and receives it on pull.
3. **Manifest** gains `formatVersion: 2` and optional `features: [string]` (initially `["inkwell-doc"]`).
   Readers refuse `formatVersion > 2` or any unknown feature. Old (v1-only) native clients refuse new
   connections to a v2 store with their existing "unsupported format — update Inkwell" message.
4. **Native v2** accepts `formatVersion ≤ 2`. In a **v1 store it writes RTFD** (unchanged behavior, so mixed
   native fleets keep working); in a **v2 store it writes inkwell-doc**. It reads both body formats in both
   stores, dispatching on the envelope's `bodyFormat` (with an RTFD magic-byte sniff as a fallback).
5. **The store format travels with the session.** `connect` returns a `StoreSession`:
   - `manifest`;
   - `manifestETag`;
   - `formatVersion`;
   - the cipher.

   The engine and `NoteStoreSyncAdapter` share one `StoreSessionRef`, and `export` reads its body encoding
   from it (RTFD for v1, inkwell-doc for v2). Today `SyncController.ensureSession` keeps only the cipher
   and discards the manifest (`SyncController.swift:603-620`); v2 keeps the whole session.

   Every pass already lists the root, and the listing includes the manifest's ETag. When that ETag differs
   from `session.manifestETag`, a v2 engine re-reads the manifest before processing any record. It then
   checks that salt, iterations and keyCheck are unchanged; if they changed, the pass fails with
   `encryptionMismatch`. Finally it swaps the session. A v2 Mac with a long-lived session therefore
   notices an upgrade made by another device on its next pass. Running *v1* binaries still can't notice
   (§2.12), which is what item 8 handles.
6. **Upgrade is explicit**: native Settings → Sync → "Enable web access". The web app's legacy-store screen
   explains how to do it. `SyncEngine.upgradeToV2()` is serialized with passes, on the same queue as
   `sync()`, so no pass can observe a half-upgraded session. It runs these steps:
   1. Run a sync pass. If it reports errors, abort the upgrade.
   2. Send a conditional `PUT manifest.json` with `If-Match: <session.manifestETag>`. The body keeps the
      same `createdAt`, salt, iterations and keyCheck, and sets `formatVersion: 2` and
      `features: ["inkwell-doc"]`. On 412, re-read the manifest:
      - If it is already v2 with the same encryption, adopt it, because another device upgraded first.
      - Otherwise, abort with "store changed, try again".
   3. Replace the shared `StoreSessionRef` with the new manifest and ETag. Only then does any export
      produce inkwell-doc.
   4. Run the **conversion sweep** (item 7) and then a normal pass.
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
      `revision`, this device's `deviceID`/`deviceName`, `bodyFormat: "inkwell-doc/1"` and a new
      `bodySHA256`.
   3. Sends `PUT notes/<id>.body` with the inkwell-doc container.
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
   3. `importConflictCopy` fails to decode the inkwell-doc body (§2.12 fact 2) and the record is retried
      every pass.

   The edit stays safe on that Mac, unsynced, until it is updated. The upgrade confirmation dialog states
   this.
8. **Web app**: refuses v1 stores with an explanatory screen ("Open Inkwell on your Mac → Settings → Sync →
   Enable web access"); creates new stores directly at v2 (always encrypted). Legacy-RTFD notes found in a v2
   store are shown **read-only** with a placeholder ("Formatted on an older Mac — open Inkwell on macOS to
   convert") plus the meta title/preview; pin/move/delete are allowed and re-push the opaque body bytes
   **without** `bodyFormat`. The web never converts bodies (it cannot parse RTFD).

   **Wire rule (both implementations):** the envelope's `bodyFormat` key is either `"inkwell-doc/1"` or
   **omitted**. It is never `null`, `""` or any legacy marker such as `"rtfd"`. Local stores keep exactly
   the wire value: `undefined`/`nil` means legacy, and there is no internal `'rtfd'` tag that could leak.
   The envelope builder (`encodeEnvelope` in TS; in Swift, the engine's envelope construction, which only assigns `bodyFormat` from the adapter's `RecordPayload`) rejects any other value
   with an internal error and never publishes it.

### 3.5 Native converter

New SwiftPM library target **`InkwellDoc`** (depends on AppKit; used by the `Inkwell` app):

- `Codable` schema types, container encode/decode, validation (unknown types → `.readOnly`).
- `DocConverter.export(NSAttributedString, styles:) -> BodyContainer` and
  `DocConverter.import(BodyContainer, styles:) -> NSAttributedString`, with an injected `DocStyleProvider`
  (fonts, colors, base size) so the converter is testable headless.
- The block-kind sentinel constants (29…41) move from `EditorStyle` into `InkwellDoc` so both sides share them;
  legacy font-based classification is reused for pre-sentinel content.
- Image export: PNG/JPEG/GIF/WebP pass through; TIFF/BMP → PNG; HEIC/HEIF → JPEG (q 0.9); anything else →
  `attachment` (download chip). Foreign rich-paste attributes (arbitrary fonts, kerning, shadows) degrade to
  the nearest supported mark or are dropped — documented in the converter's README comment table.

Fidelity tests (`Tests/InkwellDocTests`):

- **doc → NSAS → doc is exact** for fixtures and for a seeded random doc generator (every node/mark/attr).
- **NSAS → doc → NSAS is semantically equal**: block kind, marker, level, alignment, marks, colors, links,
  attachment hash per paragraph range (not byte-equal RTFD).
- Corpus: the app's seed notes, every `FormatCommand` applied to sample text, tables, mixed lists, images,
  and a code-block set that covers **every row of the §3.3 code-block table**, including the no-ops
  (`inlineCode`, `indent`/`outdent`, lists, `toggleCheckbox`, table row commands), justify, `block(.code)`
  toggling back to body, `clearFormatting` leaving the block, and a link and an inline image inside it.
  The unit fixtures reproduce the attribute edits (tests can't import the app target). The real
  `TextFormatter.perform(_:)` runs the same list in the §12.6 real-app gate.
- Derivations: title/preview/tags computed from the NSAS equal those computed from the doc (feeds TS vectors).

### 3.6 Keep RTFD alongside? — No

Storing RTFD next to inkwell-doc would double image bytes, create two sources of truth that can disagree
(which wins on a conflicting web edit?), and need sidecar GC. The schema covers everything the native editor
*produces*; only foreign paste attributes are lossy, and those are equally lost to the web. A note's local
native cache remains RTFD on disk, so nothing changes for offline native use.

## 4. Architecture

```
Browser (PWA)                                   Nuxt/Nitro server (Docker)
┌──────────────────────────────┐               ┌───────────────────────────────┐
│ Vue UI (3 panes, TipTap)     │               │ /api/auth, /api/server-info   │
│   ⇅ Comlink                  │  HTTPS        │ /api/storage/*  (browser REST)│
│ Sync Worker: @inkwell/core   │──ciphertext──▶│ /s3/*  (S3 subset, SigV4)     │◀── native apps
│  WebCrypto, planner, engine  │               │ StoreDriver: disk | upstream S3│
│  IndexedDB (sealed cache)    │               └──────────────┬────────────────┘
└──────────────────────────────┘                              ▼
                                               /data/store  or  S3/MinIO/R2 bucket
```

### 4.1 Nuxt app

- Nuxt 4, `ssr: false` (SPA; nothing to render server-side since the server holds no plaintext), Nitro
  `node-server` preset. Vue 3, Pinia for UI state, VueUse, `@vite-pwa/nuxt` for the app-shell service worker.
- No UI component framework; hand-written CSS custom properties implementing HANDOFF §6 tokens.

### 4.2 Browser as the sync client

- **Crypto**: WebCrypto `importKey(raw passphrase, "PBKDF2")` → `deriveKey({name:"PBKDF2", hash:"SHA-256",
  salt, iterations}, …, {name:"AES-GCM", length:256}, extractable: false, ["encrypt","decrypt"])`.
  Golden vectors also need raw bits, so tests use `deriveBits`; production code never exports the key.
- **Key caching**: default **in memory only** (re-enter passphrase per browser session; Locked state in the
  pill). Opt-in "Remember on this device" stores the non-extractable `CryptoKey` in IndexedDB (structured-clone
  of CryptoKey keeps it non-extractable: script on this origin can *use* it but not read it). "Lock" deletes it.
- **Engine in a Web Worker**: crypto, planner, storage I/O and the search index run off the main thread
  (PBKDF2 210k ≈ 100-300 ms; large bodies). UI talks to it via Comlink.
- **Multi-tab**: Web Locks (`navigator.locks.request("inkwell-sync")`) guarantee one pass at a time across
  tabs; `BroadcastChannel("inkwell")` fans out "records changed"/"status" events. (SharedWorker is not used:
  missing on Chrome Android.)
- **Local cache (IndexedDB, via `idb`)**: stores `records` (each value sealed with the store key under context
  `local/<storeName>/<id>`), `deletions`, `syncState`, `trash` (deleted bodies kept locally — native moves them
  to `.trash` and never deletes them outright, `NoteStore.swift:481, 1091-1099`; the web caps this at 30 days
  because browser quota is finite), `settings`.
  Locking makes the cache unreadable; wiping is "Sign out & forget this device".
- **Offline**: edits apply to IDB immediately; sync passes run after local changes (2 s debounce, 10 s max
  delay), every 60 s while visible and 600 s while hidden, and on `online`/focus — the native constants
  (`SyncController.swift:71-74`); failures show "Offline"/"Sync Issue".
- **Device identity**: one uppercase UUID per browser profile in IDB; name defaults to
  `"Web — <Browser> on <OS>"`, editable in Settings (it appears in other devices' conflict copies).
- **Dates**: envelopes carry Double2001 numbers (kept raw, converted at the edge); inner metas written as
  second-precision ISO `Z`.
- The web app never seeds sample notes into a synced store.

### 4.3 Sharing logic: TypeScript port + golden vectors (recommended) vs WASM

| | TS port + golden vectors | SwiftWasm build of InkwellSync |
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
  packages/core/    @inkwell/core — crypto, formats, layout, planner, engine, StorageBackend, S3 (SigV4) — no DOM
  packages/doc/     @inkwell/doc  — schema, container, TipTap extensions, derivations, sanitize
  apps/web/         Nuxt 4 app (SPA) + Nitro server routes
  e2e/              Playwright
  Dockerfile, docker-compose.yml
fixtures/golden/    shared vectors (Swift writes, TS reads; from-web/ the reverse)
```

Justification: the storage format, vectors, Swift engine and TS port must change **atomically in one PR**,
validated by one CI run, under one AGPL license and one issue tracker. A separate repo would need vector
publishing and version pinning for no benefit. `web/` keeps Node tooling out of the SwiftPM root.

## 6. Storage access

### 6.1 Options

| | Direct browser → S3 | **Server proxy (Nitro)** |
|---|---|---|
| Bucket CORS | required (many homelab users can't/won't) | not needed |
| S3 credentials | in the browser (IDB), exposed to XSS and to anyone with the device | stay on the server |
| No-cloud homelab | needs MinIO | built-in disk store |
| Native app target | user's bucket | user's bucket **or** the Inkwell server itself |
| Server trust | none for storage | sees ciphertext + metadata only |

**Decision: server proxy is the default and only v1 mode.** The server holds no keys and never sees plaintext.

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

- `disk` (default): files under `/data/store/<key>`; ETag = hex(SHA-256(bytes))[0..32] (unquoted);
  per-key async mutex; writes go temp file → `fsync` → `rename`; in-memory ETag index revalidated by
  `stat` (mtime/size); single-instance only (documented). Conditional semantics identical to S3.
- `s3` (upstream): server uses `@inkwell/core`'s `S3Backend` (same SigV4 code the browser *could* use) with
  credentials from env; supports any provider the native app supports.

### 6.3 Front doors

**(a) Browser REST — `/api/storage`** (session cookie + `X-Inkwell: 1` header + `Origin` check):

| Method & path | Request | Response |
|---|---|---|
| `GET /api/storage/list?prefix=inkwell/v1/&continuationToken=` | — | `200 {objects:[{key,etag,size}], nextContinuationToken?}` (etags unquoted, ≤1000/page) |
| `GET /api/storage/object/<key>` | — | `200` bytes, header `ETag: "<etag>"` (quoted on the wire); `404` |
| `PUT /api/storage/object/<key>` | bytes; `If-Match: "<etag>"` (bare accepted) or `If-None-Match: *` | `200 {etag}` (JSON, unquoted) + header `ETag: "<etag>"`; `412` precondition failed |
| `DELETE /api/storage/object/<key>` | optional `If-Match` | `204`; `404`; `412` |

Keys must match `^inkwell/(v1/(manifest\.json|notebooks/[0-9A-F-]{36}\.json|notes/[0-9A-F-]{36}\.(meta|body)|tombstones/[0-9A-F-]{36}\.json|devices/[0-9A-Za-z-]{1,64}\.json)|\.canary/[0-9A-F-]{36})$`
(case-insensitive hex accepted for reads, writes uppercase-only). Body limit `INKWELL_MAX_OBJECT_MB` (default 50).
Errors are JSON `{error: code, message}`; `401` → client shows login.

**(b) S3-compatible subset — `/s3`** for native apps and backup tools (rclone), so **no new Swift sync code** is
needed: native adds an "Inkwell Server" provider preset (endpoint = server URL + `/s3`, path-style, bucket
`inkwell`, region `us-east-1`, credentials generated in the web Settings).

- Operations: `ListObjectsV2` (`list-type=2`, `prefix`, `continuation-token`, `max-keys`; XML
  `ListBucketResult` with `Contents/Key/ETag/Size`, `IsTruncated`, `NextContinuationToken`), `GetObject`,
  `HeadObject`, `PutObject`, `DeleteObject`; `If-Match` / `If-None-Match: *` → `412 PreconditionFailed` XML.
- Auth: SigV4 `Authorization` header only (no presigned URLs), signed headers incl. `host`, `x-amz-date`,
  `x-amz-content-sha256` (`UNSIGNED-PAYLOAD` or hex payload hash, verified when hex; `aws-chunked` rejected with
  `NotImplemented`), `if-match`/`if-none-match` (`SigV4Signer.swift:31-39`). Clock skew > 15 min →
  `RequestTimeTooSkewed`; bad key → `InvalidAccessKeyId`; bad signature → `SignatureDoesNotMatch` (these map
  to the native fatal errors, `S3Backend.swift:293-295`).
- Must accept the canary (`inkwell/.canary/<UUID>` PUT/DELETE).
- Credentials: `/api/credentials` creates/revokes access key pairs; secrets stored in `/data/config.json`
  (mode 0600) because SigV4 verification needs the plaintext secret. They grant storage access only (still
  ciphertext).

**Other endpoints**: `GET /api/health` → `{ok: true, needsSetup}` (always 200, unauthenticated), `GET /api/server-info` → `{version, commit, sourceUrl, authMode, storage:
"disk"|"s3", needsSetup}` (self-reported; carries no integrity claims, see §11.1), `POST /api/setup`,
`POST /api/login`, `POST /api/logout`, `GET /api/session`, `GET|POST|DELETE /api/credentials`.

### 6.4 Future: direct mode

Because `@inkwell/core` contains an isomorphic `S3Backend` (fetch + WebCrypto HMAC), a later "static web app,
bring your own CORS bucket" mode is a configuration change, not a rewrite.

## 7. Auth

`INKWELL_AUTH` selects one mode:

- `password` (default): single user with an argon2id password hash. There are two ways to set it:
  - **`INKWELL_PASSWORD_HASH`** (or `INKWELL_PASSWORD_HASH_FILE` for Docker secrets). Setup is skipped
    entirely: `needsSetup` is false and `/api/setup` returns 404.
  - **First-run setup, guarded by a one-time bootstrap token.** The server must not be claimable by
    whoever reaches it first.
    - At startup, when no hash is configured and `/data/config.json` holds none, the server takes its
      token from `INKWELL_SETUP_TOKEN` or `INKWELL_SETUP_TOKEN_FILE`.
    - If neither is set, it generates 32 random bytes (base64url), writes them to `/data/setup-token`
      (mode 0600), and prints them once to the container log:
      `Inkwell setup token: … (docker logs <container>)`.
    - `POST /api/setup {token, password}` compares the token in constant time and is rate-limited like
      login. It runs under a process-wide mutex, so two concurrent requests cannot both succeed.
    - On success it writes the hash to `/data/config.json` with temp + rename and mode 0600, deletes
      `/data/setup-token`, and clears the in-memory token. The token is **single-use**: any later setup
      call returns 404.
    - While setup is pending, every `/api/*` and `/s3` route returns 503 `setupRequired`, **except**
      `GET /api/health`, `GET /api/server-info` and `POST /api/setup`. Health must stay green so the
      Docker `HEALTHCHECK` doesn't mark a fresh container unhealthy. It returns 200
      `{ok: true, needsSetup}`.

  Session = signed, `HttpOnly; Secure; SameSite=Strict` cookie
  (`INKWELL_SESSION_SECRET` or generated), 30-day sliding; login rate limiting with exponential backoff per IP.
- `forward-auth`: trust `Remote-User` (configurable header) **only** from `INKWELL_TRUSTED_PROXIES` CIDRs —
  Authelia/Authentik/Traefik forward-auth friendly.
- `oidc`: generic OIDC authorization code + PKCE (`openid-client`), optional `INKWELL_OIDC_ALLOWED_SUBS`.

The server login is **separate from the encryption passphrase** and never derives keys. The `/s3` front door
uses its own SigV4 credentials regardless of mode.

## 8. Deployment & licensing

- One image `ghcr.io/<owner>/inkwell-web` built from `web/Dockerfile`: multi-stage, `node:24-alpine`,
  `pnpm build` → `.output/`, runs `node .output/server/index.mjs` as uid 1000, `PORT=3000`, `VOLUME /data`,
  `HEALTHCHECK` → `/api/health`.
- `docker-compose.yml`: one service, named volume `inkwell-data:/data`, env file; documented reverse-proxy
  examples (Caddy/Traefik) because WebCrypto requires a secure context (HTTPS or `localhost`).
- **AGPL-3.0 §13**: every page footer links "Source" to `INKWELL_SOURCE_URL` (default: the canonical repo) plus
  version/commit; `/api/server-info` exposes the same. Operators who modify the code must point it at their fork
  — stated in the deployment docs.

## 9. Editor (TipTap) — native feature mapping

| Native feature (HANDOFF §5.3, `FormatCommand.swift`) | Native representation | inkwell-doc | TipTap |
|---|---|---|---|
| Title / Heading / Subheading / Body | sentinel 37/39/41/29 | `heading 1/2/3`, `paragraph` | `Heading` (levels 1-3), `Paragraph` + align/indent attrs |
| Code block | sentinel 31 per paragraph, mono base font, all marks allowed | `codeBlock{align?,indent?}` with inline content | custom `InkwellCodeBlock` node (`marks: '_'`, `whitespace: 'pre'`, inline images); not the stock `CodeBlock`, which forbids marks |
| Quote | sentinel 33 | `blockquote` | `Blockquote` |
| Divider | sentinel 35 + NBSP | `horizontalRule` | `HorizontalRule` |
| Bulleted / numbered / checklist, nesting | text marker + indent | `listItem{kind,level,number,checked}` | custom flat `InkwellListItem` node, Tab/Shift-Tab change `level`, Enter continues, empty Enter exits |
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

Native bindings verified in `Sources/Inkwell/Editor/FormatCommand.swift:125-152` (editor) and
`Sources/Inkwell/App/InkwellApp.swift:36-70` (menus). "Mod" = ⌘ on macOS, Ctrl elsewhere; "Alt" = ⌥.

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

## 10. UX parity (HANDOFF §5-6)

- **Three panes**: sidebar 190/220/320 (min/ideal/max px), note list 240/300/440, editor content max-width
  760, resizable splitters persisted; below 900 px collapses to two panes, below 600 px one pane with back
  navigation (PWA on phones).
- **Sidebar**: Library rows All Notes / Pinned / Recent (7 days) / Conflicts (only when any exist); Notebooks
  with color dot + icon (SF Symbol → Lucide-style inline SVG mapping table for the 32 curated symbols, fallback
  `book`), drag-to-reorder (`sortIndex`), rename, recolor; Tags section from derived tags.
- **Note list**: cards with title, preview, date, pin, conflict badge; sort by `updatedAt` desc with pinned first;
  empty states copied from HANDOFF.
- **Search**: fold rules of §2.8, in the worker.
- **Conflicts**: badge "Conflict" + source device on copies; "Mark Resolved" clears fields with a new revision;
  Conflicts library filter.
- **Sync pill** (HANDOFF §5.10; labels from `Views/SyncStatusView.swift:19-28`): Synced / Syncing / Offline /
  Sync Issue / Locked / Sync Off, with the same 700 ms delay before showing "Syncing" for background passes
  (`SyncController.swift:509-515`) and click → details popover (last sync, error, "Sync now").
- **Dark mode**: `prefers-color-scheme` plus manual override; stored light text colors are adapted at render
  time by the same luminance inversion native uses (`usesAdaptiveColorMappingForDarkAppearance`,
  `InkwellTextView.swift:54`) approximated by an OKLCH lightness flip, tested with snapshots.
- **Typography**: system font stack (`-apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui`), body
  size setting default 15 (HANDOFF; native code default is 14 — open question).

## 11. Security

### 11.1 Threat model

| Actor | Can | Cannot |
|---|---|---|
| Storage (bucket/disk, backups) — **untrusted** | see sizes, counts, timing, UUIDs, device IDs in key names, the plaintext manifest; delete or roll back objects | read or undetectably modify content (AES-GCM + key-bound AAD) |
| Inkwell server, honest operator — **semi-trusted** | all of the above; see login identity, IPs and access patterns | read content |
| Inkwell server, **compromised** (or a malicious operator) | everything above, plus serve modified HTML/JS/service worker, and capture the passphrase and every note the next time a user unlocks in the browser | read content of users who only use the native app, or who don't unlock in the browser while it is compromised |
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
   project's minisign key. The public key is committed in the repo (`scripts/inkwell-release.pub`) and
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

A separately hosted, version-pinned static client is the real fix. It would be loaded from a different
origin than the storage server, with the server acting only as a ciphertext store, which is the §6.4
direct/proxy mode. It is recorded as future work and as an open question (§15), not as a v1 guarantee.

### 11.2 Controls

- CSP via `nuxt-security`: `default-src 'none'; script-src 'self' 'strict-dynamic' 'nonce-…'; style-src 'self'
  'unsafe-inline'` (ProseMirror writes `style` attributes for alignment/colors; inline *scripts* remain
  forbidden); `img-src 'self' blob: data:; connect-src 'self'; worker-src 'self' blob:; manifest-src 'self';
  font-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'; object-src 'none'`. Plus HSTS,
  `X-Content-Type-Options`, `Referrer-Policy: no-referrer`, COOP/CORP. Trusted Types is a stretch goal.
- No third-party scripts, fonts, analytics or CDNs; all assets self-hosted.
- Note content never goes through `innerHTML`: documents are parsed with `Node.fromJSON`, `doc.check()`; invalid
  docs fall back to read-only plain text. Link `href` allowlist `http:`, `https:`, `mailto:`, `tel:`; colors must
  match `^#[0-9A-Fa-f]{6}$`; images render only from `blob:` URLs created from attachment bytes with an
  allowlisted image MIME; SVG is never rendered inline (download chip).
- Paste: HTML clipboard data goes through DOMPurify (strict profile) *before* ProseMirror's DOM parser.
- Server: CSRF via `SameSite=Strict` + `X-Inkwell` header + `Origin` check; key regex; size limits; rate limits;
  no directory traversal (keys never become paths without validation).
- Playwright asserts no request body/URL/header contains the passphrase or raw key bytes, and that CSP reports
  zero violations.

## 12. Testing

1. **Golden vectors** (`fixtures/golden/*.json`), written by Swift tests when `INKWELL_WRITE_VECTORS=1`, verified
   otherwise: `pbkdf2.json` (incl. 210 000 iterations), `aesgcm.json` (fixed nonces via CryptoKit directly),
   `manifest.json` (key check), `envelopes.json` (envelope/tombstone/device/inner metas, ISO + Double2001),
   `planner.json` (exhaustive cartesian product of planner inputs → action), `store-snapshot.json` (a small sealed
   store + passphrase), `engine-scenarios.json` (scripted multi-device traces), `derive.json` (title/preview/tags/
   search fold), `doc-convert.json` (inkwell-doc fixtures + expected derived text).
2. **Reverse vectors** `fixtures/golden/from-web/*.json` written by Vitest, decoded by a Swift test (catches date/UUID
   case/base64 drift).
3. **Swift**:
   - `InkwellSyncTests` (existing 149).
   - New format-v2 tests:
     - session refresh when the manifest ETag changes;
     - `upgradeToV2` 412 handling;
     - conversion as a revision-preserving meta+body rewrite, which peers see as `.pull` and never as a
       conflict;
     - a conversion 412 leaves the record in `legacyBodies` and it converts on a later pass;
     - **an old-client race**: a simulated v1 engine edits a note between the upgrade's clean pass and its
       conversion. The conversion gets 412, the next pass pulls the old client's RTFD edit, and the pass
       after that converts it. No revision is lost and no conflict copy is created. The reverse order is
       also tested: an old client editing *after* conversion gets 412 and then a non-fatal per-record
       `importConflictCopy` error. Its local edit survives.
   - `InkwellDocTests` fidelity suite, including the §3.3 code-block command table, a link and an image.
4. **TS unit** (Vitest): core against all vectors; engine scenarios ported from the 53 `SyncEngineTests` using an
   `InMemoryBackend`; fast-check property tests for derivations and doc validation; server routes with
   `@nuxt/test-utils`.
5. **Playwright E2E**: first-run setup (rejected without the bootstrap token; the token can't be reused), login, create store, unlock/lock, CRUD notes/notebooks, formatting
   round-trip, offline edit → reconnect, two browser contexts producing a conflict copy, shortcuts, CSP, no
   passphrase on the wire.
6. **Interop** (`scripts/interop_tests.sh`, opt-in, mirrors `scripts/live_s3_tests.sh` with Floci on :4566):
   config A — server `disk` store, native `SyncEngine` via `/s3`, web via `/api/storage`; config B — server upstream
   Floci S3, native direct to Floci, web via the proxy. Two native drivers run in both configs:
   - **Engine level:** opt-in `LiveInteropTests`, using `SyncEngine`, `FakeLocalStore` and InkwellDoc
     bodies. It is fast and covers protocol edge cases.
   - **Real app (release gate):** the app binary in the existing debug self-test mode, extended as
     `INKWELL_SYNC_SELFTEST=interop`, with `INKWELL_DATA_DIR=<repo>/.selftest/interop-<config>` and
     `INKWELL_SYNC_CONFIG` pointing at the store.
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
   - v1→v2 upgrade, including peers pulling converted notes without conflicts.

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
| S3-subset incompatibilities with other clients | only Inkwell + rclone are supported; conformance tests reuse Swift `S3Backend` |
| Shortcut collisions per browser/OS | Playwright matrix (Chromium/WebKit/Firefox) |

## 14. Assumptions

- A1: Native users will accept an explicit one-time upgrade to format v2 to enable web access.
- A2: Homelab users terminate TLS at a reverse proxy (WebCrypto needs a secure context).
- A3: Single user per instance covers the target audience for v1.
- A4: Notes rarely exceed tens of MB including images (inline attachments).
- A5: The curated SF Symbol list (32) can be mapped to open-licensed SVG icons compatible with AGPL.

## 15. Open questions for the owner

1. Canonical public repo URL for `INKWELL_SOURCE_URL` and the image registry name.
2. Multi-user per instance (families) — v1 non-goal OK?
3. Upgrade to format v2: explicit button (proposed) or automatic once all known devices run v2?
4. Normalize passphrases to NFC? Requires a KDF version field in the manifest; affects existing stores.
5. Minimum native version that understands v2 — and should v2 native auto-reconnect when it sees `unsupportedFormat`?
6. Should a direct browser→S3 (CORS) mode ship in v1 for users without a server?
7. Attachment size cap per note (proposed 25 MB) and whether to build content-addressed attachments in v1.
8. HEIC→JPEG and TIFF→PNG conversion on export — acceptable quality/size trade-off?
9. Should the web create sample notes for brand-new stores?
10. OIDC in v1 or post-v1 (password + forward-auth may suffice)?
11. Priority of Safari/iOS PWA support.
12. Web trash UI (restore deleted notes from the local trash) in v1?
13. Default body font size: 15 (HANDOFF) or 14 (code)?
14. Should the project host a version-pinned static web client on a separate origin, for users who don't
    fully trust their server host (§11.1)? Who holds the release-signing (minisign) key?
15. Is a one-time full re-download of every note by every peer acceptable during the v2 conversion
    (§3.4.7)? For large libraries with images, this can be hundreds of MB.
