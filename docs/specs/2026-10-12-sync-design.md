# NoteIt Sync — Design (draft for approval)

## Goal
Let a user keep their NoteIt library in **storage they choose** — an S3 bucket, a NAS, or any synced folder — and use it from several Macs, with no NoteIt-hosted server. Setup takes about a minute, and a note is never lost to a conflict.

## Non-goals (v1)
- An NoteIt-hosted cloud or user accounts.
- Real-time co-editing or character-level merging.
- An iOS app. The design keeps this possible, but it isn't built.
- Sharing notes with other people.

## Approaches considered

| | Approach | Pros | Cons |
|---|---|---|---|
| A | **"Library folder"**: move the existing library into any folder (iCloud Drive, Dropbox, a mounted NAS share) and let that tool sync it | Tiny amount of work | Two Macs both write the single `library.json`, so one silently overwrites the other. No conflict handling. Doesn't reach S3. |
| **B (recommended)** | **NoteIt sync engine + pluggable storage backends**: a sync protocol that stores one item per note, with backends for S3-compatible storage and folders | Works with S3, MinIO/Synology (NAS), Backblaze B2, Cloudflare R2, Wasabi, SMB/AFP mounts, iCloud Drive and Dropbox. Proper conflict handling. Optional end-to-end encryption. Future iOS app can reuse it. | Real engineering: a sync engine, S3 request signing and a storage refactor |
| C | **CloudKit** | Apple-native, free for the user | Not "custom storage". Needs a paid developer account and entitlements. Tied to iCloud only. |

**Recommendation: B.** It is the only option that really delivers "S3 or my NAS, synced between devices", and it's a strong commercial differentiator ("your notes, your storage").

## Architecture (B)

```
NoteStore (UI state, unchanged public API)
   │ local change events / apply remote changes
   ▼
LocalRepository  ── per-note files on disk (replaces the monolithic library.json as source of truth)
   ▲
SyncEngine  ── diff local vs remote vs last-synced base; push/pull; conflicts
   │ StorageBackend protocol
   ├── S3Backend      (S3-compatible: AWS, MinIO, R2, B2, Wasabi, Synology C2 / MinIO on NAS) — SigV4 via CryptoKit + URLSession, no deps
   ├── FolderBackend  (any directory: SMB/AFP NAS mount, iCloud Drive, Dropbox, external disk)
   └── (later) WebDAVBackend
```

### Storage refactor (prerequisite)
- Split today's ~1,000-line `NoteStore` into `NoteStore` (UI state) and `LocalRepository` (disk I/O).
- **Per-note metadata.** Note metadata moves from the single `library.json` into each note's own record. Notebooks become individual records too. `library.json` stays only as a cache that can be rebuilt.
- Every record gets a `revision` (UUID) and a `modifiedAt`, so changes can be compared without reading content.
- **Migration** from the current layout is automatic and one-time, with a backup made first.

### Remote layout (`<bucket or folder>/inkwell/v1/`)

`inkwell` is the protocol name from before the app was renamed to NoteIt. It, `inkwell/.canary/`, `.inkwell-lock`, the `inkwell-key-check` plaintext and the manifest fields are part of the wire format and stay unchanged, so existing stores keep working.

```
manifest.json                         format version, encryption info (salt, KDF params), created
notebooks/<uuid>.json                 Notebook record + revision
notes/<uuid>.meta.json                NoteMeta + revision + contentHash
notes/<uuid>.body                     flattened RTFD Data (NSAttributedString → rtfd Data), possibly encrypted
tombstones/<uuid>.json                deletion marker (deletedAt, deviceID); swept after 30 days
devices/<deviceID>.json               device name, last sync (for "Synced devices" UI)
```

### Sync algorithm
- **When it runs:** on launch, after local edits (debounced about 2 s), every 60 s while the app is active, on wake, and when you click "Sync now".
- **What it compares:** a local `sync-state.json` stores, for each record, the revision/ETag last synced (the "base").
- **List** remote metadata: S3 `ListObjectsV2` with ETags, or directory enumeration for folders.
- **Decide per record:**
  - Changed locally only → push.
  - Changed remotely only → pull.
  - Changed on both sides (a conflict) → keep both:
    - The local version stays in place.
    - The remote version arrives as a copy titled "Title (conflict — <Device>, <date>)".
    - A badge shows on both notes.
    - Notebooks: the most recently modified wins (they're tiny).
  - Deletions: a tombstone wins over an edit that's older than it. An edit newer than the tombstone brings the note back.
- **Writes:**
  - Push the body first, then the metadata. The metadata references the body's `contentHash`, so a half-finished upload is never visible to other devices.
  - On S3, use `If-Match` / `If-None-Match` conditional writes where supported, so two devices can't overwrite each other unnoticed.
  - On folders, write atomically (temporary file, then rename).

### End-to-end encryption (optional, recommended on)
- **Key:** derived from a passphrase with HKDF over PBKDF2 (CryptoKit + CommonCrypto). The KDF parameters and salt are stored in `manifest.json`.
- **Encryption:** each body and metadata file is encrypted with AES-GCM. Without the passphrase, the storage provider sees only file names that are UUIDs and opaque sizes.
- **Storage of the passphrase:** keychain only. If it's lost, the data can't be recovered, and the UI says so clearly.

### Credentials & settings
- Settings get a new **Sync** tab:
  - Provider picker with presets: Amazon S3, Cloudflare R2, Backblaze B2, MinIO / Synology NAS, Custom S3, and Folder.
  - Fields for endpoint, region, bucket, access key and secret, with a "Test connection" button.
  - For Folder: a folder picker that keeps access across restarts (security-scoped bookmark).
  - Encryption toggle and passphrase.
- Secrets are stored in the keychain, never in UserDefaults, under the service `io.github.rutbergphilip.noteit.sync`. Secrets saved under the legacy Inkwell service `com.inkwell.app.sync` are moved to it on first read.
- **Status UI:**
  - A sync status icon in the sidebar footer: synced, syncing, offline or error.
  - A "Last synced 2 min ago" line in the menu bar panel.
  - A list of conflicts.
  - A list of synced devices.

### Error handling
- **Offline or provider errors:** queue the change, retry with backoff, and show the status, without blocking editing.
- **Authentication failure:** pause sync and show a banner with a "Fix in Settings" button.
- **Unknown format version:** refuse to sync and ask the user to update the app.
- **A remote record that fails to decode:** skip it, log it, and don't delete anything.

### Testing
- Unit-style self-tests for the sync decision table: every combination of local/remote change and delete, against an `InMemoryBackend`.
- Two-device simulation: two repositories sharing one `FolderBackend` directory, with scripted concurrent edits and deletes.
- S3 tested against a local MinIO (`brew install minio`), if allowed, or a recorded fake. SigV4 checked against AWS's published test vectors.

## Phasing
1. Storage refactor plus migration to per-note records (no visible change).
2. Sync engine plus FolderBackend, which already covers a NAS mounted over SMB/AFP and iCloud Drive/Dropbox. Sync settings and status UI.
3. S3Backend (S3-compatible presets) plus encryption.
4. Later: a WebDAV backend, a conflict comparison view, and a Trash UI.

## Decisions (approved 2026-10-12)
1. Approach B approved; build phases 1–3 now.
2. End-to-end encryption **on by default** when connecting remote storage (user can opt out at setup; cannot be toggled later without re-uploading — v1: choose at connect time).
3. Polling accepted with a strict performance budget:
   - Sync runs off the main thread at `.utility` QoS; never blocks typing.
   - Poll every 60 s only while the app is active (frontmost or a window is visible). In the background or menu-bar-only and idle, poll every 10 min. Coalesce triggers: never more than one sync running at a time.
   - Before downloading anything, do a cheap change check: a single `ListObjectsV2` (S3) or one directory enumeration (folder), comparing ETags or modification dates against `sync-state.json`. Download only records that changed.
   - Bodies are streamed one at a time and nothing is kept in memory after applying. Target: idle sync adds < 5 MB resident memory and < 1% CPU averaged.
   - No timers while sync is not configured.

## Implementation notes & deviations (2026-10-12)

What shipped differs from the design above in these ways. Code references are to `Sources/NoteItSync/` and `Sources/NoteIt/`.

### Storage and revisions
- **No local layout migration.** There's no `LocalRepository` and no per-note record files on disk; `library.json` stays the source of truth. `NoteMeta` and `Notebook` gained optional `revision: UUID?` fields (plus `conflictSource` / `conflictOriginalID` on notes), so older files load unchanged. A user edit sets a new random revision.
- **Deterministic legacy revisions.** Records without a revision get one when sync first reads them: SHA-256 over a version tag, the id, stable metadata fields and the body package files, as a v8 UUID (`NoteStore.contentRevisions`). Identical libraries on two Macs therefore get equal revisions and adopt each other instead of producing conflict copies.
- **Deletion journal.** While sync is configured, local deletions go to `sync-deletions.json`; remote deletions and pruned seed content are never journaled.
- **Per-store state file.** The base lives in `sync-state-<hash>.json`, keyed by a hash of the store identity (provider plus folder path, or endpoint/bucket/prefix), so a pass still finishing for an old store can't feed a new one. Connect starts from a fresh state file; disconnect deletes it. A legacy `sync-state.json` is migrated on launch.

### Decision table (`SyncPlanner`)
Implements the plan's 17-row table with these changes:
- A live local record makes any journaled deletion for the same id stale.
- **Row 12 (resurrection):** a local edit since the base always resurrects (delete tombstone, then push), whatever the timestamps, because the deleter never saw that edit.
- Row 11 with a base also resurrects when the tombstone's `deletedMetaETag` equals the etag our own push replaced (the deleter decided before our push landed). Without a base, row 11 compares `local.modifiedAt` with `tombstone.deletedAt`.
- No local record, no journal entry, remote meta and a base (missing from the table): pull, so nothing is lost.
- A meta and a tombstone coexisting are reconciled before planning: the tombstone wins if its `deletedMetaETag` names that exact meta (or, for older tombstones, if the meta isn't newer than `deletedAt`); otherwise the tombstone is removed.

### Write order (`SyncEngine`)
- **push:** conditional meta put first (`If-Match` the base etag, or `If-None-Match` for creates), body second. The meta's etag is the per-record lock, so a writer that loses the race never overwrites the winner's body. The meta carries `bodySHA256`; readers treat a missing or mismatched body as an upload in progress and skip it. A `pendingPushes` entry lets an interrupted push be recognized and finished rather than copied as a conflict.
- **pushDeletion:** tombstone first, carrying `deletedMetaETag` (the meta etag the decision saw), then a conditional meta delete (`If-Match` that etag), then the body. If the conditional delete fails, the tombstone is withdrawn and the next pass pulls the edit (row 9). A crash in between leaves a meta plus a tombstone naming it, which every device finishes as a deletion.
- **resurrectPush:** delete the tombstone, then push.

### Safety
- **Missing manifest aborts the pass.** The engine refuses to sync if `inkwell/v1/manifest.json` isn't in the listing, and the controller won't recreate a vanished store; the user sees "Sync storage was reset or moved" and sync pauses.
- **Fatal vs per-record errors.** Unauthorized, clock skew and blocked plain HTTP stop the pass; other errors are collected per record and retried next pass.

### Folder backend
- **Content-hash etags** for files ≤ 256 KB (every meta, tombstone and the manifest), because coarse-mtime volumes (FAT/exFAT, some SMB) give same-size rewrites equal stat etags. Larger bodies use mtime/size/inode, with a stat-keyed hash cache to keep listings cheap.
- **Cross-process lock.** Writes and deletes run under an in-process lock plus an advisory `flock` on `<root>/.inkwell-lock` (falls back to in-process only if the volume can't lock). Create-if-absent uses `renamex_np(RENAME_EXCL)`.
- **Sync-tool sidecar import.** Copies left by iCloud Drive, Dropbox or Syncthing (e.g. `<id> 2.meta`) are opened with the canonical key's AAD. Unseen note revisions are imported as conflict copies (with a matching body found by hash); notebooks use newest-wins. Consumed sidecars are deleted; unusable ones are deleted after 30 days.

### Encryption
- PBKDF2-HMAC-SHA256 with 210,000 iterations and a 16-byte salt, used directly as the AES-256 key (no HKDF step). The manifest stores salt, iterations (accepted range 100,000–10,000,000) and a key check sealed with context `manifest`.
- **AAD binding.** Every object is sealed with its key relative to `inkwell/v1/` as AES-GCM additional data, so an object can't be swapped or replayed under another key.
- Encryption covers metas, bodies, tombstones and device records; only the manifest is plaintext. It's chosen at connect time, and joining an unencrypted store with encryption requested is refused (`encryptionMismatch`).

### App integration
- **Seed dedupe on join.** First-launch sample IDs and revisions are kept in `seed-manifest.json`. When joining an existing store, unedited sample notes and then unedited, now-empty sample notebooks are removed locally without journaling, before the first pass. Creating a new store keeps them. The manifest is deleted after any connect.
- **Staged editor snapshots.** Editor commits made during a SwiftUI update are staged in `NoteStore`. Before applying a remote change to a note, the adapter commits staged and open-editor edits; if the revision moved since the engine read it, the apply is refused and the next pass resolves it as a conflict.
- **Scheduling.** Passes run at `.utility` QoS: every 60 s while active or with a visible window, 600 s otherwise, 2 s after local edits (10 s max), 5 s after wake, and on Sync Now. Failures back off from 15 s to 10 min. Nothing is scheduled while sync isn't configured.
- **S3 without conditional writes.** On 501/`NotImplemented`, the backend falls back to HEAD-check, PUT, HEAD-verify, and reports a lost race when the verify fails.
- **Conditional-request canary.** Some servers accept `If-Match` / `If-None-Match` but ignore them; Floci's GCS emulator does, as does GCS's S3-compatible XML API, which uses `x-goog-if-generation-match` instead. Before its first conditional request, `S3Backend` writes a throwaway `inkwell/.canary/<uuid>` object. It then repeats the create with `If-None-Match: *`, writes with a bogus `If-Match`, and deletes with a bogus `If-Match`. Any of these succeeding switches writes or deletes to the verified fallback. The probe runs once per backend instance, and runs again after a network or auth failure.
- **Google Cloud preset.** `storage.googleapis.com`, region `auto`, path-style addressing, with HMAC interoperability keys. It goes through the same SigV4 S3 path; the canary routes it onto the fallback if needed.
- **Emulator testing.** `LiveS3EmulatorTests` plus `scripts/live_s3_tests.sh` run against Floci (AWS S3 on :4566, GCS on :4588) in Docker. Floci AWS honours conditional requests natively; Floci GCS passes using the fallback.

### Remaining known limitations
- Folder sync through a sync tool (iCloud Drive, Dropbox) relies on advisory locking that doesn't span Macs; races are caught later through sidecar import rather than prevented.
- S3 providers without conditional writes get best-effort protection only (the check-write-verify window isn't atomic).
- No WebDAV backend, no side-by-side conflict compare view, no Trash UI.
- No passphrase change or switching encryption on/off without a new store.
- No iOS app.
- Unit tests cover `NoteItSync` only (149 tests, plus 3 opt-in live emulator tests); the app layer relies on the debug `NOTEIT_SYNC_SELFTEST` mode.
