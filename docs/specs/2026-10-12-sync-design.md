# Inkwell Sync — Design (draft for approval)

## Goal
Let a user keep their Inkwell library in **storage they choose** — an S3 bucket, a NAS, or any synced folder — and use it from several Macs, with no Inkwell-hosted server. Setup takes about a minute, and a note is never lost to a conflict.

## Non-goals (v1)
- An Inkwell-hosted cloud or user accounts.
- Real-time co-editing or character-level merging.
- An iOS app. The design keeps this possible, but it isn't built.
- Sharing notes with other people.

## Approaches considered

| | Approach | Pros | Cons |
|---|---|---|---|
| A | **"Library folder"**: move the existing library into any folder (iCloud Drive, Dropbox, a mounted NAS share) and let that tool sync it | Tiny amount of work | Two Macs both write the single `library.json`, so one silently overwrites the other. No conflict handling. Doesn't reach S3. |
| **B (recommended)** | **Inkwell sync engine + pluggable storage backends**: a sync protocol that stores one item per note, with backends for S3-compatible storage and folders | Works with S3, MinIO/Synology (NAS), Backblaze B2, Cloudflare R2, Wasabi, SMB/AFP mounts, iCloud Drive and Dropbox. Proper conflict handling. Optional end-to-end encryption. Future iOS app can reuse it. | Real engineering: a sync engine, S3 request signing and a storage refactor |
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
- Secrets are stored in the keychain, never in UserDefaults.
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
