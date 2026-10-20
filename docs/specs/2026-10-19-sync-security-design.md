# Sync Security — Design

Status: proposed · Date: 2026-10-19 · Companion plan: docs/plans/2026-10-19-sync-security.md

This spec follows the program contract in [program-design](2026-10-19-program-design.md). Where they disagree, the program contract wins.

## Goal

Make NoteIt sync safer to trust and easier to self-host. Five pieces:

1. **Locked notes**: individual notes encrypted with a notes password, unlockable with Touch ID.
2. **WebDAV backend**: sync to Nextcloud, ownCloud, Synology or any WebDAV server, next to Folder and S3.
3. **Side-by-side conflict compare**: see a conflict copy next to its original and pick a side.
4. **Change passphrase and turn on encryption** for an existing library, safely across devices.
5. **No-telemetry network inventory**: a document that lists every network connection the app can make, enforced by a test.

Pieces 2 to 5 ship in wave 2. Locked notes need the `noteit-doc` store feature, which the web app's Tasks 0.4–0.5 bring in wave 3, so locked notes ship in wave 3 after those tasks (program §1, §8).

Everything stays local-first. There is no NoteIt server. The wire prefix `noteit/v1/` is unchanged; every remote addition in this document is additive and gated by a manifest feature.

The store-session groundwork this sub-project used to start with (store sessions, manifest features, keyring types) is built in wave 0 as foundations step 3 (program §2). The foundations plan freezes those types. This spec still describes their behaviour, and the sync-security plan repeats the shapes for reference; the web app and the phone consume them.

## What the user gets

- Choose **Lock Note** from the Note menu, the note's context menu or the palette, and its body is encrypted on disk and in sync. The title stays in the list with a lock icon. Opening it asks for the notes password or Touch ID. Locked notes relock after 5 minutes idle, on sleep, on screen lock and on quit. **Lock All Notes** (⌥⌃⌘L) relocks at once.
- Settings › Sync offers **WebDAV** as a provider, with presets for Nextcloud, ownCloud and Synology.
- A conflict copy shows a **Compare…** button. The sheet shows both versions side by side with changed lines highlighted, and three buttons: keep this Mac's version, keep the other device's version, keep both.
- Settings › Sync › Encryption offers **Change Passphrase…** and, for unencrypted libraries, **Turn On Encryption…**. Other Macs running NoteIt 0.3 or later keep syncing after a passphrase change without asking for the new one. If a Mac or device on an older version would stop syncing, NoteIt lists it and asks first.
- Settings › Sync has a **Locked Notes** section next to Encryption: change or reset the notes password, the relock time and Touch ID. Its text says that locking works without sync: "Locked notes work whether or not this library syncs."
- `docs/network.md` lists every host and API the app can talk to. A test fails if code adds a new one without listing it.

## Design

### 1. Shared groundwork: store sessions and manifest features

Built in foundations step 3 under the rules of program §4. The types are frozen in the foundations plan (tasks 3.1 to 3.5). The rules that matter here:

- **Features, not version numbers.** Body encoding, the upgrade trigger, the web client's legacy-store check and the phone's store-needs-upgrade check all ask whether `features` contains `noteit-doc`. Nothing checks `formatVersion` directly. `StoreSession.bodyEncoding` is `noteit-doc` exactly when that feature is present.
- **Any feature means version 2.** A manifest with any entry in `features` has `formatVersion: 2`, so NoteIt 0.2 and older stop with "This sync store needs a newer version of NoteIt" (`SyncError.unsupportedFormat`) instead of misreading data. Readers refuse any feature that isn't in `StoreFeature.supported` (`SyncError.unsupportedFeature`). This sub-project adds `locked-notes` to `supported` in the task that ships the locked-body reader. `noteit-space` is accepted only by a shared-notebook (space) session; a library session refuses it. The sharing spec owns that check.
- **`rekey` is a manifest field, not a feature.** It is present only while a re-encryption runs (§2).
- **Manifest writes keep everything.** Every manifest change reads the manifest, changes only its own keys in the raw JSON (so keys this build doesn't know survive) and writes it back with `If-Match` on its ETag. A 412 re-reads the manifest and checks again, before re-applying the change, that `rekey` is not set and that the key ID, the session kind, the current features and the requirement rules still allow it; if not, it stops with `rekeyInProgress`, `keyChanged` or `manifestChangedConcurrently` instead of replaying the change. `upgradeToV2` adds `noteit-doc` and keeps `keyring`, `encryption` and every other feature; it refuses while the `rekey` field is set.
- **One way to add a feature.** `SyncEngine.ensureFeature(_:backend:session:currentDeviceID:confirm:)` (foundations task 3.4) is the only path that adds a feature older apps can't read. Each device record in `devices/` carries `platform` (`mac`, `ios` or `web`), `appVersion`, `supportedFeatures` and `rekeyAck`. The check uses `supportedFeatures`; a record without it counts as supporting no features. If a listed device doesn't support the feature, the user sees the Macs and devices that will stop syncing, with their last sync time, and confirms first. Declining writes nothing (`SyncError.featureDeclined`). The check is a warning, not a lock (program §4): a device can register between the check and the write, so after a successful write `ensureFeature` lists devices again and reports any new blocker, which the app shows once as a notice. Every feature this spec adds goes through it, including a passphrase change that introduces `keyring`. A feature's requirements are added first in the same manifest write: `locked-notes` requires `noteit-doc`, so `ensureFeature(.lockedNotes)` adds `noteit-doc` when the store doesn't have it yet.
- **Unknown keys survive.** Every writer keeps the last decrypted note and notebook JSON and patches only the keys it owns (`RawMetaOverlay`, in `NoteItSync`). `NoteMeta.lock` and `NoteMeta.conflictTitleSuffix` go into the revision fields only when they aren't nil, so existing revisions don't change.
- **One list of remote record kinds.** `RemoteLayout` keeps a registry of every prefix, its owner, its key depth and how it's sealed. There are three sealing kinds: `.storeKey` (sealed with the session's key: the library's data key, or the space key in a space session), `.spaceKey` (objects sealed with a space key inside a personal store) and `.unsealed` (signed logs, HPKE key files and the canary, which `RekeyRunner` never re-seals). This sub-project registers `noteit/v1/keys/` with `.storeKey` and depth 1, and adds its key test vectors to `layout-keys.json` for the web server.
- **WebDAV ETags** are stored without quotes, like every other backend.

**Remote keys.** This spec owns the key grammar and the depth table (program §4 rule 8). `RemoteLayout.isValidKey(_:)` and `isListablePrefix(_:)` (foundations task 3.5) implement them, and the web server accepts only keys that fit.

- Every segment matches `[A-Za-z0-9._-]+` and is not `.` or `..`. Empty segments are refused.
- A segment whose part before the first `.` parses as a UUID must be the uppercase canonical form.
- A key is the manifest, a canary key, or sits under a registered prefix at exactly the depth of a row with that path (the number of segments after the prefix). Two rows may share a path with different depths (`noteit/v1/devices/` below); `prefix(for:)` returns the longest matching row whose depth equals the key's.
- A list request must name a registered prefix, a parent root of one (for example `noteit/v1/`), or `noteit/.canary/`. `isListablePrefix(_:)` allows the parent roots so clients that list the whole root (the sync engine, rclone) keep working, and Inkwell's `inkwell/v1/` and `inkwell/` so `RemoteMigration` can look for a store from before 0.4.0. Keys under `inkwell/` are not valid.

| Prefix | Depth | Sealing | Example key | Owner |
|---|---|---|---|---|
| `noteit/v1/manifest.json` | — | never sealed | `noteit/v1/manifest.json` | core |
| `noteit/.canary/` | 1 | `.unsealed` | `noteit/.canary/<UUID>` | core |
| `noteit/v1/notebooks/` | 1 | `.storeKey` | `noteit/v1/notebooks/<UUID>.json` | core |
| `noteit/v1/notes/` | 1 | `.storeKey` | `noteit/v1/notes/<UUID>.meta`, `noteit/v1/notes/<UUID>.body` | core |
| `noteit/v1/tombstones/` | 1 | `.storeKey` | `noteit/v1/tombstones/<UUID>.json` | core |
| `noteit/v1/devices/` | 1 | `.storeKey` | `noteit/v1/devices/<UUID>.json` | core |
| `noteit/v1/devices/` | 2 (space stores) | `.storeKey` (the space key in a space session) | `noteit/v1/devices/<member-id>/<UUID>.json` | sharing |
| `noteit/v1/bodies/` | 1 | `.storeKey` | `noteit/v1/bodies/<UUID>.<VERSION>.<TAG>.body` | web-app |
| `noteit/v1/smart-folders/` | 1 | `.storeKey` | `noteit/v1/smart-folders/<UUID>.json` | organise |
| `noteit/v1/claims/reminders/` | 1 | `.storeKey` | `noteit/v1/claims/reminders/<UUID>.json` | organise |
| `noteit/v1/keys/` | 1 | `.storeKey` | `noteit/v1/keys/locked-notes.json` | sync-security |
| `noteit/v1/boards/` | 1 | `.storeKey` | `noteit/v1/boards/<UUID>.json` | surfaces-polish |
| `noteit/identity/v1/` | 1 | `.storeKey` | `noteit/identity/v1/identity.sealed` | sharing |
| `noteit/space/v1/log/` | 1 | `.unsealed` (signed) | `noteit/space/v1/log/0000000042.json` | sharing |
| `noteit/space/v1/keys/` | 2 | `.unsealed` (HPKE-wrapped) | `noteit/space/v1/keys/3/<member-id>.key` | sharing |
| `noteit/space/v1/profiles/` | 1 | `.storeKey` (the space key in a space session) | `noteit/space/v1/profiles/<member-id>.json` | sharing |

Locked bodies use the normal body path with `.locked` in place of the body suffix (program §4 rule 13), so they need no row of their own: `noteit/v1/bodies/<UUID>.<VERSION>.<TAG>.locked`. Each owner adds its row and its vectors in the task that adds the prefix. The rows owned by other sub-projects are listed here so the table stays complete; their specs define what the records contain.

Features this sub-project adds:

| Feature string | Meaning | Who sets it |
|---|---|---|
| `keyring` | Manifest carries a wrapped data key instead of `encryption`. | Change passphrase, turn on encryption, or replace the key, through `ensureFeature`. |
| `locked-notes` | Remote contains locked-note bodies (`bodyFormat: "noteit-locked/1"`) and `keys/locked-notes.json`. Requires `noteit-doc`. | First lock of a note in a synced library, after a confirmation, through `ensureFeature`. |

`noteit-doc` belongs to the web-app spec and `noteit-space` to the sharing spec. `rekey` is a manifest field (§2), not a feature.

### 2. Keyring, change passphrase and turning on encryption

**Today.** `Manifest.encryption` holds `salt`, `iterations` (default 210,000, `KeyDerivation.defaultIterations`) and `keyCheck`. The AES-GCM key is the PBKDF2 output of the passphrase. Changing the passphrase therefore means re-encrypting everything, and there is no UI for it. The Keychain stores the passphrase itself (`Keychain.Account.passphrase`).

**Data model.** A data key (DEK) is separated from the passphrase:

```
Manifest {
  formatVersion: 2
  features: ["keyring", ...]
  encryption: nil                    // always nil when keyring is present
  keyring: {
    keyID: "a1b2c3d4e5f60718"        // hex of first 8 bytes of SHA256("noteit-key-id" || DEK)
    kdf: "pbkdf2-sha256"
    salt: <16 bytes base64>
    iterations: 600000
    wrappedKey: <AES-GCM(KEK, DEK, aad: "keyring/<keyID>")>
    changedAt, changedBy (device name)
  }
  rekey: { fromKeyID?, toKeyID, startedAt, updatedAt, deviceID, deviceName,
           previousKeyring?, previousEncryption? }?   // a manifest field, present only while a rekey runs
  createdAt
  ...                                // keys this build doesn't know are kept on every write
}
```

- KEK = PBKDF2-SHA256(NFC-normalized passphrase, salt, 600,000). New and changed passphrases are NFC-normalized so the same passphrase typed on different keyboards derives the same key. The legacy v1 derivation is left exactly as is.
- For a v1 store the DEK is the existing PBKDF2 output, so moving to a keyring does not touch any object.
- The Keychain stores the DEK (new account `syncDataKey`) instead of the passphrase. After a successful unlock the stored passphrase item is deleted. A passphrase change on one Mac therefore does not interrupt other 0.3 Macs: they hold the DEK, which has not changed.
- While a personal rekey runs, `rekey` keeps what it replaced: `previousKeyring` (the old keyring) or `previousEncryption` (the old v1 `encryption` block), both absent when the store was plain. They go away with the `rekey` field when the rekey finishes. Until then the old passphrase can always recover the old key from the manifest, so losing the Keychain mid-rekey never strands objects still sealed with it. A space rotation never sets them.
- `StoreCredential` replaces the bare passphrase string when connecting: `.passphrase(String)` or `.dataKey(SymmetricKey)`. A data key is accepted only if its keyID matches the manifest's.
- The session carries the unwrapped DEK (`StoreSession.dataKey`) only for a keyring store, whether it was opened with the passphrase or the data key or just created; v1, keyring-pending, plain and space sessions have none. The Mac saves `syncDataKey` from it after a passphrase connect, so a v1 store keeps its stored passphrase until it moves to a keyring. A passphrase change returns a session carrying the unchanged DEK, and a personal rekey one carrying the new DEK.
- Creating a keyring store records the creating device's name in `keyring.changedBy`, so `connectSession` takes the device name; an empty one creates nothing.

**Change passphrase** (re-wrap only):

1. Settings › Sync › Encryption › **Change Passphrase…** opens `SyncEncryptionSheet`: current passphrase, new passphrase twice, the existing `PassphraseStrength` meter.
2. Verify the current passphrase against the manifest (keyCheck for v1, unwrap for keyring).

   **Keyring pending.** A manifest whose `features` has `keyring` but which has no `keyring` object and still has the legacy `encryption` block is a valid intermediate state: a change or rekey added the feature and stopped before writing the keyring. It opens through the v1 path (keyCheck). Change passphrase and a personal rekey detect it and skip straight to the manifest write that installs the keyring, with no second `ensureFeature` or confirmation. `features` with `keyring` but neither a `keyring` object nor an `encryption` block stays `invalidManifest`.
3. If the store's `features` has no `keyring` yet (not a keyring-pending store), call `ensureFeature(.keyring)`, passing this Mac's device ID (the one it gives `SyncEngine`) as `currentDeviceID` so its own record never blocks. `changePassphrase` takes that `currentDeviceID` from `SyncController` and passes it on. When a listed device runs 0.2 or older, the sheet shows "These Macs will stop syncing until they're updated to NoteIt 0.3:" with the list, and **Change Passphrase** stays disabled until the user confirms. Declining changes nothing. The device list is a warning, not a lock: after the write `ensureFeature` lists devices again, and any Mac it reports that wasn't listed before is shown once as a notice ("These Macs will stop syncing until they're updated: …").
4. Wrap the same DEK under the new KEK with a fresh salt and write the manifest with a read-modify-write. A 412 re-reads; if the keyID is unchanged the change is re-applied once, otherwise it stops with "Another Mac changed the encryption settings. Try again."
5. No objects are re-uploaded. Running sessions continue; other devices' refresh sees the same keyID and does nothing.

The sheet has an unchecked option **Also replace the encryption key**. Use it if the old passphrase may have leaked together with a copy of the store. It runs a rekey (below).

**Rekey** (turn on encryption, or replace the key). One `RekeyRunner` in `NoteItSync` re-seals the store. Which keys it touches comes from `RekeyScope` (foundations task 3.5), which states program §4 rule 7. It has two modes that share one fence, re-seal pass, heartbeat, resume and finish, and differ only in the new cipher and the manifest write that opens the rekey:

- `.personal(newKey:newPassphrase:)`: a personal store. Opens by adding `keyring` if needed and writing the new keyring (steps 2 and 3).
- `.spaceEpoch(newCipher:newKeyID:)`: sharing's rotation of a space to a new epoch. The new cipher is the new epoch's `SpaceCipher`. Opens by setting only the `rekey` field in the space manifest; there is no passphrase, keyring or feature. At finish, the write that clears `rekey` also replaces the `encryption` block's key check with one sealed by the new cipher, because opening a space with its cipher must open that key check (foundations task 3.3).

The runner is created with this Mac's device ID (the one it gives `SyncEngine`), which it skips in the fence and passes as `currentDeviceID` to `ensureFeature`.

1. **Preconditions.** All must hold, or the sheet says which one failed in plain words. Each failure is a `RekeyBlocker` case:
   - sync is idle and one full pass just succeeded (`notIdle`);
   - no body versions are waiting to upload (`SyncState.pendingBodyVersions` is empty): "Wait until all notes have finished uploading." (`pendingBodyVersions`);
   - **Check Sync Storage** (markdown-storage) passes on the current store (`storageCheckFailed`);
   - every object under the store root belongs to a prefix in the `RemoteLayout` registry; otherwise "This sync store has data from a newer version of NoteIt. Update NoteIt first." (`unknownPrefix`).
2. The sheet lists other devices from `devices/` with their platform, last sync time and app version. Devices without a version, or older than this release, are flagged: "Quit NoteIt on these Macs or update them first." Adding `keyring` goes through `ensureFeature`, which shows the same list and the same one-time notice for a device that appears after the confirmation.
3. Generate a new DEK, wrap it, and write the manifest (read-modify-write): new `keyring`, the `rekey` field `{fromKeyID (nil when the store was plain), toKeyID, ..., previousKeyring or previousEncryption}` holding the keyring or v1 `encryption` block being replaced, feature `keyring` added through `ensureFeature` (skipped for a keyring-pending store, which already has it), `formatVersion = 2`. Keychain gets `syncDataKey` = new key and `previousDataKey` = old key (when there was one).

   **Fence.** The runner then waits on every backend, whether or not it reports `atomicConditionalWrites()`. Each other device that sees the `rekey` field pauses and writes its device record once with `rekeyAck` = the rekey id (`toKeyID`). A device is identified by its record's key (the part after `devices/` without `.json`), never by the `deviceID` field inside it, so a record can only acknowledge for the device at its own key; in a space store that key includes the owning member (sharing spec §4.4). The runner goes ahead when every device that hasn't been removed has acknowledged. If one hasn't after the sheet's wait, the sheet lists them: "Encryption can't be changed until every Mac has synced: <names>. Open NoteIt on them, or remove them." **Remove and Continue** removes those device records (they must then reconnect with the passphrase) and the runner goes ahead; otherwise the rekey stops with `SyncError.rekeyBlocked(.devicesNotSynced)`. The manifest keeps the `rekey` field, and **Finish Encryption Change** continues later.
4. List everything under the store root (`noteit/`). A copy left under `inkwell/v1/` by the 0.4.0 store move is outside the store root: the rekey never lists or re-seals it, so it still opens with the old key until the user deletes it, as the 0.4.0 release notes suggest once every Mac is updated. For each key `RekeyScope.action(for:rekeying: .storeKey)` decides:
   - `.reseal` (a `.storeKey` prefix): try to open with the new cipher and skip it if that works (resume case); otherwise open it with the old cipher (passthrough when the store was plain) and seal it with the new cipher in the same context; `put` with `ifMatch` on the listed ETag. On `preconditionFailed`, re-get and retry, up to 3 times, then fail the rekey with a resumable error;
   - `.skip`: `manifest.json`, `.unsealed` rows (`.canary/` keys and sharing's signed log and wrapped key files) and `.spaceKey` prefixes. A personal store rekey leaves `.spaceKey` objects alone; sharing runs the same runner on a space session, where `.storeKey` means the space key, when a space key changes;
   - `.block`: a key under no registered prefix. The runner stops before touching anything (`unknownPrefix`).

   Only contents are re-encrypted; keys and body paths stay the same. Re-sealing changes every meta's ETag, so a tombstone bound to a leftover meta through `deletedMetaETag` (web-app spec §3.4 item 9) no longer matches it and the pair falls back to the date rule (`modifiedAt <= deletedAt`), which the tombstone still wins because the meta wasn't edited. This is accepted.
5. Update this device's `SyncState` bases with the new ETags so the next pass does not see every record as remotely changed.
6. Every 200 objects or 30 seconds, rewrite `rekey.updatedAt` as a heartbeat through `SyncEngine.updateRekey` (foundations task 3.4), the only manifest writer allowed while the `rekey` field is set. It re-checks on every retry that `rekey.toKeyID` is still this rekey's and stops otherwise. Step 3, which sets the field, uses the ordinary read-modify-write.
7. When every object opens with the new key, write the manifest without the `rekey` field, again through `updateRekey` (which also drops `previousKeyring` and `previousEncryption`), delete `previousDataKey`, and run Check Sync Storage again. Its result is shown in the sheet. A test lists the store afterwards and checks that nothing still opens with the old key.

**Crash safety.** Each object is self-describing: it opens with exactly one of the two keys. Crashes leave a mix that step 4 resumes. On next launch the same device sees `rekey.deviceID == self` and resumes automatically. If the heartbeat is older than 1 hour, any 0.3 device may finish the rekey (Settings shows **Finish Encryption Change**). It needs the new key (from its Keychain or the new passphrase) and the old key (from its Keychain or the old passphrase, which unwraps `rekey.previousKeyring` or derives from `rekey.previousEncryption`); for a plain-to-encrypted rekey no old key is needed. The manifest is always written before the objects, so a device never finds objects under a key that the manifest does not describe.

**Other devices.** On manifest refresh (ETag changed) a 0.3 device:

- sees the `rekey` field set by another device: pauses sync with `SyncError.rekeyInProgress(deviceName)`, writes `rekeyAck` once, and shows "Waiting for <Mac> to finish changing encryption". Retries on the normal schedule.
- sees a different keyID with no `rekey` field: `SyncError.keyChanged`; status `needsPassphrase` with "Encryption was changed on <Mac>. Enter the sync passphrase." After unlock it re-baselines: for each record whose meta ETag differs from its base, get and open the meta; if the revision equals the base revision, adopt the new meta and body ETags without downloading the body. `SyncState` gains `keyID` so this check survives restarts.
- sees the same keyID: no change (passphrase change).

Old builds (0.2 and earlier) refuse `formatVersion 2` on their next connect. A copy of an old build that is already running does not re-read the manifest and could write records sealed with the old key after a rekey. Those records fail to open on new devices, which treat them as unreadable (existing per-record error) and keep the local copy; the old device's next launch stops with "update NoteIt". The device list and the acknowledgement wait are the mitigation; this residual risk is documented in `docs/known-limitations.md`.

**Turning encryption off** is not offered (non-goal).

**Edge cases and errors.**

| Case | Behaviour |
|---|---|
| Wrong current passphrase | "That passphrase doesn't match this sync store." Nothing written. |
| Manifest 412 during change | Re-read; if the keyID changed, stop with the message above; otherwise re-apply once. |
| Network drops during rekey | Status shows "Encryption change paused — 1,240 of 3,100 items"; resumes on the next pass. |
| Keychain lost `previousDataKey` (or both keys) mid-rekey | Ask for the previous passphrase, and the new one if `syncDataKey` is also gone: "Enter the previous passphrase to finish". The old key is recovered from `rekey.previousKeyring` (or `previousEncryption` for a v1 store), the new key from the manifest keyring. A wrong passphrase writes nothing. For a plain-to-encrypted rekey no old key is needed. |
| Store over 10,000 objects | Allowed; progress shown; heartbeat keeps other devices waiting rather than racing. |
| Folder backend | `FolderBackend.atomicConditionalWrites()` is false: its `.noteit-lock` flock only serializes writers on one Mac, and synced folders (iCloud Drive, Dropbox) don't share locks between Macs. The fence in step 3 is the same as on every other backend. |
| A listed device never acknowledges | The rekey stops before touching objects with `SyncError.rekeyBlocked(.devicesNotSynced)`; the message names the device. The user can remove it and continue. |
| Unknown prefix in the store | Refused before anything is written (`rekeyBlocked(.unknownPrefix)`). |
| Body versions waiting to upload | Refused until the queue is empty. |

**Privacy.** The passphrase never leaves the Mac and is no longer stored at rest; only the DEK is kept, in the login Keychain with `kSecAttrAccessibleAfterFirstUnlock` (unchanged accessibility, not synchronizable).

### 3. Locked notes

Program §8 is the contract; this section adds the details.

**What is encrypted.** The note body, including its attachments, is encrypted. The title stays readable so the note can be found and listed; it shows with a lock icon. The preview and tags are cleared while locked (the preview would leak body text; tags are cleared to keep the rule simple: "only the title is visible").

**The lock sheet** is shown on the first lock and says:

- "The title stays visible. Everything else is encrypted."
- "Earlier versions of this note on this Mac will be deleted."
- "Reminders in a locked note won't ring."
- "Backups and snapshots made before locking may still contain the note."

**Kept out of derived data.** Locked notes are left out of every derived index: search body text, links, semantic index, image text, Spotlight, tasks and reminders. The `DerivedIndex` registry (organise, foundations step 4) never passes a locked note's body to an indexer. Locking a note calls `refreshDerivedIndexes(for:)` (foundations task 4.4), which sends `noteRemoved` to every registered indexer, so what they already had is removed; search keeps a title-only entry, so the note matches on its title. Unlocking a note does not add it back; Remove Lock calls `refreshDerivedIndexes(for:)` again, which sends `noteChanged`.

**Local API, MCP, plugins and smart features.** Lists, search results and the Local API show the note with `locked: true` and an empty preview (`NoteSummaryDTO.locked`, automation). Any body read or write returns `423 note_locked`. MCP, plugins and smart features follow the same rule. Automation implements the flag and the error from `NoteMeta.isLocked`, which exists from foundations step 4; this sub-project adds the contract tests that use a really locked note.

**Shared notebooks.** **Lock Note** is disabled for notes in a shared notebook, with "Notes in shared notebooks can't be locked." Moving a locked note into a shared notebook is refused with the same message. Share links and published notebooks refuse locked notes (sharing).

**Keys.**

- One notes password per library, separate from the sync passphrase (a note can be locked without sync).
- A random 256-bit lock key (LK) encrypts bodies. LK is wrapped with KEK = PBKDF2-SHA256(NFC(password), salt, 600,000) using AES-GCM, AAD `noteit-lock-key/<keyID>`. `keyID` is the hex of the first 8 bytes of SHA256("noteit-lock-key-id" || LK).
- The lock keyring is a list of entries `{keyID, salt, iterations, wrappedKey, wrappedAt}` so that a password change, or two Macs setting a password independently before syncing, never orphans a note. The current entry is the one with the latest `wrappedAt`. Changing the notes password re-wraps every LK the user can unwrap with the old password under the new one.
- Stored locally at `lock-keys.json` in the data folder (`NoteStore.rootURL`, program §7) and, when synced, at `noteit/v1/keys/locked-notes.json` sealed with the store cipher (context `keys/locked-notes`). Remote updates merge as a union by keyID with `If-Match`; for the same keyID the later `wrappedAt` wins.

**Sealed file.** The plaintext inside the lock is always a `noteit-doc` body container (`BodyContainer` from `NoteItDoc`, foundations step 2, produced by `DocConverter.export`), so the same sealed bytes work in RTFD libraries, Markdown libraries, the web app and the phone. The file is:

```
NOTEIT-LOCKED/1\n
{"keyID":"<16 hex>","sealedID":"<UUID>"}\n
<AES-GCM combined: nonce | ciphertext | tag>
```

The first two lines are the cleartext header and also the AAD, so a changed header fails to open. `sealedID` is fixed at lock time, so conflict copies, which get a new note ID, still open. `NoteMeta.lock` is `{keyID, sealedID}` and is rebuilt from the header if the metadata lost it.

**Where it lives.** All body file access goes through `NoteBodyStorage` (foundations step 4):

| Library | Sealed file |
|---|---|
| RTFD library, and the phone | `notes/<uuid>.locked` |
| Markdown library | `.noteit/locked/<uuid>.sealed` |

Converting a library moves sealed files as they are (markdown-storage).

**Never lost by accident.** A sealed file is deleted only by Remove Lock (on this Mac or synced from another one) or by permanent deletion of the note (emptying Recently Deleted, Delete Now, or the automatic purge). This holds on every platform. Moving a locked note to Recently Deleted keeps it. Reconciliation at load never deletes one:

| On disk at load | Result |
|---|---|
| Sealed file, `lock` set or not | `lock` is taken from the metadata, or rebuilt from the header. Any plain body file for the note is deleted (the sealed file was verified before it was moved into place). |
| `lock` set, no sealed file, plain body present | Remove Lock was interrupted: clear `lock`. |
| `lock` set, no sealed file, no plain body | "This locked note's file is missing." Nothing is deleted; the note can be moved to Recently Deleted. |

**Lock and unlock.**

1. **Lock Note** (Note menu, context menu, palette; no default shortcut): if no notes password exists, `LockPasswordSheet` asks for one twice with a hint field (stored in plaintext, shown on unlock) and the warning "If you forget this password, locked notes can't be recovered. NoteIt can't reset it." The user must tick "I understand". The lock sheet text above is shown on the first lock.
2. Crash-safe order: seal to a temporary file, open it again with the key to verify, move it into place atomically; save the metadata with `lock` set and preview and tags cleared; delete the plain body file; delete the note's version history on this Mac (`VersionHistory.removeHistory(of:)`) and recovery copies; call `refreshDerivedIndexes(for:)`, which sends `noteRemoved` to every derived indexer.
3. Opening a locked note shows `LockedNoteView` (title, lock icon, **Unlock** button, Touch ID prompt if enabled). Once unlocked the body decrypts into memory only. Edits are sealed and written to the sealed file on save; no plaintext touches disk. Version history is not recorded while locked.
4. **Remove Lock** asks for the password (or Touch ID), writes the plain body, deletes the sealed file, clears `lock` and saves, then rebuilds the preview and calls `refreshDerivedIndexes(for:)`, which sends `noteChanged`.

**Touch ID.** Optional, off until enabled in Settings. Creates a CryptoKit `SecureEnclave.P256.KeyAgreement.PrivateKey` with access control `[.privateKeyUsage, .biometryCurrentSet]`; every LK is wrapped to its public key (ECDH + HKDF + AES-GCM) and stored in the Keychain generic password `notes-lock-biometric` (service `AppIdentity.keychainService`, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`). Unlocking uses `LAContext` with reason "unlock your locked notes". If the fingerprint set changes, the key becomes unusable; NoteIt deletes the item and asks for the password, then offers to turn Touch ID back on. The Secure Enclave key needs no extra entitlement. Availability is decided by a one-time trial key creation; if it fails (unsupported Mac or ad-hoc signing), the Touch ID option is hidden.

**Auto-relock.** One unlock unlocks all locked notes (they share the session LK set). Relock after inactivity of 5 minutes by default (choices: 1, 5, 15, 60 minutes), and always on sleep, screen lock, fast user switch and quit, and on **Lock All Notes**. Relock drops LKs and decrypted bodies from memory, saves pending edits sealed first, and swaps any open locked editor back to `LockedNoteView`.

**Sync.**

- The remote body of a locked note is the sealed file as is, with `bodyFormat: "noteit-locked/1"`, then sealed again by the store cipher (two layers when the store is encrypted, one when it is not). `bodySHA256` is over the sealed file. It sits at the same path as the note's normal body for that store format, with `.locked` replacing the body suffix (program §4 rule 13). Because `locked-notes` requires `noteit-doc`, that is the versioned body path: `noteit/v1/bodies/<UUID>.<VERSION>.<TAG>.locked`. `bodyVersion` increments as usual.
- `noteit-locked/1` is allowed only when the store has `locked-notes`. Before the first locked note is pushed the user confirms "Locked notes need NoteIt 0.3 or later on every Mac", through `ensureFeature(.lockedNotes)` with this Mac's device ID as `currentDeviceID`; if the store doesn't have `noteit-doc` yet, `ensureFeature` adds it first in the same manifest write, under the same confirmation. Until then locked notes are held back from push. An already-connected library with locked notes asks the same on connect. If `ensureFeature` reports a Mac that appeared after the confirmation, the same one-time notice as for a passphrase change names it.
- The conversion sweep (web-app) skips `noteit-locked/1` bodies.
- The remote meta carries `lock`, written through `RawMetaOverlay`, so writers that don't know it keep it.
- Other devices download the keyring first, then the body; without the password they show the note as locked. A remote revision that drops `lock` from a locked parent revision is Remove Lock on another Mac and deletes the local sealed file the same way.
- Conflicts on a locked note produce a locked conflict copy with the same `sealedID`.

**Export.** Bulk export (**Export All Notes…** and notebook export, both through `NoteExporter.exportableNotes(in:)`) and markdown-storage's ZIP export skip locked notes and report "3 locked notes were skipped." A single unlocked note can be exported as plaintext after the confirmation "This exports the note unencrypted." Print works only while unlocked.

**Backups.** Markdown-storage owns backups, their check and restore for locked notes (its plan's Task 10.2); this sub-project only supplies the sealed-file format and `NoteLockKeyring`. Back Up Everything and automatic backups include sealed files as they are and `lock-keys.json`. Checking a backup verifies sealed files by hash without opening them and reports "N locked notes (sealed, not opened)". Restoring a backup restores sealed files as they are.

**Recently Deleted and recovery.** A locked note moved to Recently Deleted stays sealed; recovery copies are never written for locked notes. Deleting it for good deletes the sealed file with it.

**The phone** shows locked notes as locked in its first releases (mobile).

**Edge cases and errors.**

| Case | Behaviour |
|---|---|
| Wrong password | Shake; "Wrong password." Hint shown after two attempts. No lockout (offline brute force is bounded by PBKDF2 only, stated in SECURITY.md). |
| Forgotten password | Not recoverable. Locked notes remain and can be deleted. Settings › Sync › Locked Notes › **Reset Notes Password…** deletes the keyring only after the user confirms that all N locked notes become permanently unreadable; they are moved to Recently Deleted. |
| Sealed file fails to open (corrupt or unknown keyID) | Note shows "This note can't be opened with your notes password." Sync never pushes it (same rule as `NoteStoreSyncError.unreadableBody`). The file is kept. |
| Metadata lost `lock` | Rebuilt from the sealed file's header at load. |
| Note locked on Mac A, edited on Mac B before sync | Ordinary conflict: the locked version and an unlocked conflict copy. The user is told the copy is unlocked. |
| Note in a shared notebook | Lock Note disabled: "Notes in shared notebooks can't be locked." |
| Time Machine, APFS snapshots, earlier sync history | May hold plaintext from before the lock. The lock sheet says so; not fixable by the app. |

**Privacy.** Plaintext of a locked note lives only in memory while unlocked. The notes password and LKs are never written to disk unwrapped and never synced unwrapped.

### 4. WebDAV backend

**Provider.** `SyncProvider.webdav`, with `WebDAVServerKind {nextcloud, owncloud, synology, other}` used only for URL templates and help text. `SyncConfiguration.webdav: WebDAVConfig? {baseURL, username}` plus `webdavServerKind`; the password is Keychain account `webdavPassword`. `storeKey` is `["webdav", normalized baseURL]`. `SyncProvider.isS3` changes from `self != .folder` to an explicit list so WebDAV is not treated as S3.

URL templates: Nextcloud `https://<host>/remote.php/dav/files/<user>/NoteIt/`, ownCloud the same path, Synology `https://<host>:5006/<shared-folder>/NoteIt/`. Help text recommends a Nextcloud app password ("Settings › Security › Devices & sessions").

**Protocol mapping** onto `StorageBackend`:

| Backend call | WebDAV |
|---|---|
| `list(prefix:)` | `PROPFIND Depth: 1` on each collection under the prefix, walking subcollections (about 6 requests per pass for the `noteit/v1/` layout). `Depth: infinity` is not used; most servers disable it. Requests `getetag`, `getcontentlength`, `resourcetype`. |
| `get` | `GET`; ETag from the response (`ETag`, or `OC-ETag` on Nextcloud/ownCloud). |
| `put(ifMatch:ifNoneMatch:)` | `PUT` with `If-Match: "<etag>"` or `If-None-Match: *`. Parent collections are created lazily with `MKCOL` (405 means it exists; 409 means create the parent first), cached per session. If the response has no ETag, `PROPFIND Depth: 0` fetches it. |
| `delete(ifMatch:)` | `DELETE` with `If-Match`. 404 counts as success for unconditional deletes, as on S3. |
| `probe()` | `PROPFIND Depth: 0` on the base URL, then the conditional canary under `noteit/.canary/`. |
| `atomicConditionalWrites()`, `atomicConditionalDelete()` | Answered from the canary of this session, like `S3Backend`. This sub-project owns both capabilities (below). |

`MOVE` is not used. PUT is atomic on Sabre (Nextcloud, ownCloud) and Apache mod_dav, and MOVE has no portable precondition on the destination, so write-then-move would lose the conditional guarantee.

**Capabilities on every backend.** This sub-project owns `atomicConditionalWrites()` and `atomicConditionalDelete()` on `StorageBackend` (defaults false) and the baseline behaviour of the existing backends, in wave 2 (program §12): `S3Backend` sends conditional requests once, reports a failed fallback verification as a network error, runs the extended canary with its delete steps and has no delete fallback; `FolderBackend` reports false for both. The web app's Task 0.4 uses them and doesn't change them.

**Conditional writes.** The canary runs the same steps as `S3Backend`'s extended canary: create with `If-None-Match: *`, overwrite with the right `If-Match` (must succeed with a new ETag), overwrite with a stale `If-Match` (must get 412), delete with a wrong `If-Match` (must get 412 and leave the object), delete with the right one. Write steps passing make `atomicConditionalWrites()` true; delete steps passing make `atomicConditionalDelete()` true. Weak ETags (`W/`) make both false. Without atomic writes the backend uses the same check-write-verify fallback as `S3Backend`, with the known small race documented in `docs/known-limitations.md`; features that need atomic writes (Clean Up Unused Storage) treat the store like a folder. A conditional request is sent once: a transport error or 5xx on it is reported as a network error, not retried.

**Server quirks.**

- Hrefs are percent-decoded and compared after stripping the base path; both absolute and relative hrefs are accepted.
- Names starting with `.` or `@` (Synology `@eaDir`), and names ending in `.part` (Nextcloud chunk uploads), are skipped.
- ETags are stored without quotes, like every other backend, and quoted again only in `If-Match` headers. A weak ETag keeps its `W/` marker so it is never sent as a strong precondition.
- 423 Locked and 429 (honouring `Retry-After`, capped at 30 s) and 503 are retried with the existing retry delays, because the server didn't apply the request. 507 Insufficient Storage maps to "The server is full." 413 is a per-record error ("This note is too large for the server").
- Redirects are refused: "The server redirected to <url>. Enter that address instead." This keeps credentials from following a redirect.

**Security.** Basic auth, sent preemptively, over HTTPS only. Plain `http://` is accepted only for loopback hosts (tests and local servers), surfaced as `StorageError.insecureConnectionBlocked` otherwise. No custom certificate trust: a self-signed server must be trusted in Keychain Access first; the error text says so. Uses the existing ephemeral `SyncController.urlSession` (no cookies, no cache).

**Errors.** 401/403 → `StorageError.unauthorized` ("Check the user name and app password"); 404 on the base URL during setup → "That folder doesn't exist on the server"; malformed multistatus → `StorageError.invalidResponse`.

**Testing.** URLProtocol-stubbed unit tests with recorded Nextcloud and Synology multistatus fixtures; a live suite `LiveWebDAVTests` skipped unless `NOTEIT_LIVE_WEBDAV_URL` is set; CI runs it against WsgiDAV (Python, installed with pip on the macos-15 runner, conditionals enabled) through `scripts/live_webdav_tests.sh`. A Docker Nextcloud run is documented for local use only, because the CI runner has no Docker.

**Privacy.** Connects only to the user-entered server. The password lives in the Keychain.

### 5. Side-by-side conflict compare

**Today.** `NoteStore+Sync.importConflictCopy` creates a copy with `conflictSource` and `conflictOriginalID` and appends " (conflict — <device>, <date>)" to the first line. The editor shows `ConflictBadge` (in `Views/EditorContainerView.swift`) with **Mark Resolved**; merging is manual.

**Entry points.** A **Compare…** button in `ConflictBadge`, **Compare Conflict…** in the note list context menu, and the palette command **Compare Conflict…**. There is no menu bar item, so the Note group keeps the order in program §9. All are available only on a conflict copy whose original still exists and is not in Recently Deleted. Otherwise the badge keeps only **Mark Resolved**.

**Sheet.** `ConflictCompareSheet`, about 900 × 600, resizable:

- Left column "On this Mac" (the original, with its last edit date). Right column "From <device>" (the copy, title suffix hidden).
- Rows aligned side by side from a line diff of the plain text (`NoteStore.plainText(for:)`). Unchanged lines are plain; removed lines tinted on the left, added lines on the right, changed lines on both. Attachments show as `[image]` or `[file: name]`. Scrolling is shared; **Next Change** / **Previous Change** buttons (⌥⌘↓ / ⌥⌘↑ inside the sheet only) jump between differences. A summary line reads "4 changes".
- Notes over 20,000 lines on either side skip the diff and show both texts unaligned, with "Too long to compare line by line."
- Locked notes must be unlocked first; the sheet shows `LockedNoteView` on a locked side.

**Diff.** A pure function `LineDiff.rows(left:right:) -> [DiffRow]` built on Swift's `[String].difference(from:)` (Myers). Adjacent removal and insertion runs pair up row by row as `.changed`; leftovers become `.removed` or `.added`. Line endings are normalized to `\n`; trailing whitespace is compared as is.

**Buttons.**

| Button | Effect |
|---|---|
| **Keep This Mac's Version** | Moves the copy to Recently Deleted (`moveToRecentlyDeleted`, undoable). |
| **Keep <device>'s Version** | Replaces the original's body with the copy's body through `NoteStore.editBody` (default `versioning: .recordCurrent`), which saves the original's previous body in version history once; nothing else records a version; strips the conflict suffix from the title line; moves the copy to Recently Deleted. |
| **Keep Both** (default) | Calls `markConflictResolved` on the copy, as the badge does today. |

The suffix is stripped using a new `NoteMeta.conflictTitleSuffix` (added in `NoteItCore`) recorded by `importConflictCopy`; for copies made before this release a pattern match on " (conflict — …)" at the end of the first line is used. Each action is one undo step in the main window's undo manager. The resolution syncs as ordinary edits and deletions.

**Edge cases.** The original is edited on another Mac while the sheet is open: the sheet refreshes the left column and keeps the selection. The copy was already resolved elsewhere: the sheet closes with "This conflict was resolved on another Mac."

**Privacy.** Local only.

### 6. No-telemetry network inventory

**Doc.** New `docs/network.md`: what NoteIt sends, to whom, and when, and a statement that there is no analytics, crash reporting or usage tracking. It ends with a machine-readable table between `<!-- network-inventory:start -->` and `<!-- network-inventory:end -->`:

| Kind | Value | Where | Purpose | When |
|---|---|---|---|---|
| api | `URLSession` | `Sources/NoteIt/Sync/SyncController.swift` | S3 and WebDAV sync | Only when sync is set up |
| api | `URLRequest(` | `Sources/NoteItSync/Storage/S3Backend.swift`, `Sources/NoteItSync/Storage/WebDAVBackend.swift` | Sync requests | Only when sync is set up |
| host | `github.com` | `scripts/build_app.sh` (`SUFeedURL`) | Sparkle update check | Automatic checks on, or Check for Updates |
| host | user-entered | Settings › Sync | Sync endpoint | Only when sync is set up |
| host | provider templates (`s3.<region>.amazonaws.com`, `<account-id>.r2.cloudflarestorage.com`, `s3.<region>.backblazeb2.com`, `storage.googleapis.com`, `<nas-host>`) | `Sources/NoteIt/Sync/SyncConfiguration.swift` | Pre-filled endpoints, not contacted unless chosen | Only when sync is set up |

The table is filled with the exact rows found when implementing; the ones above are the known set. User-initiated `NSWorkspace.open` of links and System Settings panes is described in prose and not listed as a connection.

**Planned connections.** This sub-project owns the inventory, including rows for connections other sub-projects will add (program §12). They are listed in a separate "Planned" table, outside the machine-readable markers, so the test doesn't call them stale before their code exists. The sub-project that adds the code moves its row into the inventory in the same task, and the test enforces that.

| Connection | Owner | Kind |
|---|---|---|
| Local API listener, loopback only | automation | api `NWListener` |
| IMAP mail capture | capture-plus | api, user-entered host |
| Plugin directory | plugins | host |
| Sharing uploads | sharing | api, user's own storage |
| Web clipper image downloads | web-clipper | api, the clipped page's hosts |
| Speech model download | capture-plus | host, Apple's on-device asset service |

Private-ai's local model endpoints are loopback and allowed by the test, but the API use is listed by private-ai when it lands.

**Test.** `Tests/NoteItTests/NetworkInventoryTests.swift` walks `Sources/` (located from `#filePath`) and `scripts/build_app.sh` and:

- finds network APIs: `URLSession`, `URLRequest(`, `NWConnection`, `NWBrowser`, `NWListener`, `WKWebView`, `NSURLConnection`, `CFStream`, `CFHTTP`, `URL(string: "http`;
- finds host literals with the pattern `https?://([^/\s"'\\)]+)`, compared as written so placeholders such as `s3.<region>.amazonaws.com` are rows of their own; a literal that is only a prefix (`"https://s3."`) is listed as is;
- fails, naming the file and line, for any API whose file is not in that API's `Where` cell, and for any host not in the `host` rows (`localhost`, `127.0.0.1`, `::1` and `example.com` in comments are allowed).

Removing an entry that no longer appears in code also fails ("stale inventory row"), so the doc stays accurate. Runs in the normal `swift test` on CI; no network needed.

## Dependencies

- **Foundations** (program §2):
  - step 2: `NoteItDoc` (`BodyContainer`, `DocConverter`), the plaintext inside every sealed file;
  - step 3 (tasks 3.1 to 3.5): store sessions, manifest features with `StoreFeature.supported` and `requires`, `DeviceInfo` with `platform` and `rekeyAck`, read-modify-write, `SyncEngine.ensureFeature(_:backend:session:currentDeviceID:confirm:)`, `SyncEngine.updateRekey(backend:session:expectedRekeyToKeyID:_:)` for the rekey heartbeat and finish, `RawMetaOverlay`, the `RemoteLayout` registry with key depth and the three sealing kinds, `RekeyScope` and `RekeyBlocker`, and the keyring types. Foundations owns and freezes them; this sub-project's M0 and the keyring value types of its task 4.1 moved there. `RekeyRunner` and the `rekeyAck` fence stay here. Foundations task 3.2 also declares the optional `Rekey` fields `previousKeyring` and `previousEncryption` and keeps them on every manifest rewrite; this sub-project's rekey only fills them in and clears them (§2);
  - step 4: `NoteBodyStorage` (sealed file paths per library format), `NoteStore.editBody`, the `DerivedIndex` registry with `refreshDerivedIndexes(for:)` (task 4.4), and `NoteMeta.lock` / `isLocked` as data only (task 4.3);
  - step 6: the frozen menu, shortcut and Settings tables (Lock Note, Remove Lock, Lock All Notes in the Note group; Locked Notes in the Sync tab).
- **web-app**: consumes the frozen session and keyring interfaces, and the backend capabilities this sub-project builds in wave 2. Its Task 0.4 keeps the v2 body format, `upgradeToV2` and the conversion sweep, with these rules from program §4. Locked notes land after its Tasks 0.4–0.5, because `locked-notes` requires `noteit-doc`:
  1. `bodyEncoding` keys on the `noteit-doc` feature, not on `formatVersion`.
  2. Manifest refresh compares key identity (`keyring.keyID`, or the v1 salt, iterations and keyCheck) instead of failing with `encryptionMismatch` whenever the manifest changes.
  3. `upgradeToV2` adds `noteit-doc` through `ensureFeature`, keeps every other feature, and refuses while the `rekey` field is set. Web-app adds `noteit-doc` to `StoreFeature.supported` in the task that ships its reader.
  4. The conversion sweep skips `noteit-locked/1` bodies, and the envelope pairing rule allows `bodyVersion` with `noteit-locked/1`.
  5. The web reader understands `keyring` (unwrap with the passphrase) and shows locked notes as locked (title only).
- **markdown-storage**: Check Sync Storage (run before and after a rekey); Back Up Everything and Check a Backup (include and verify sealed files and `lock-keys.json`); library conversion moves sealed files as they are; ZIP export skips locked notes.
- **automation**: `NoteSummaryDTO.locked`, empty preview, `423 note_locked` on body reads and writes, from `NoteMeta.isLocked`; the Spotlight indexer registers through `DerivedIndex`, so it never sees locked bodies; moves the Local API row into `docs/network.md` when the listener lands.
- **organise**: the `DerivedIndex` registry; tasks and reminders skip locked notes.
- **capture-plus, private-ai**: their indexers register through `DerivedIndex`; smart features never read locked bodies; they move their planned rows into `docs/network.md`.
- **sharing**: refuses locked notes in share links and published notebooks; disables locking in shared notebooks; reuses `RekeyRunner` in `.spaceEpoch(newCipher:newKeyID:)` mode, with the old and new epoch `SpaceCipher`s, for space rotation (the fence leaves out removed members' devices; the space manifest gets the `rekey` field, and at finish a key check sealed by the new cipher in the write that clears it) and the `Keyring` wrap format; its prefixes are in the `RemoteLayout` registry: `noteit/identity/v1/` with `.storeKey`, `noteit/space/v1/profiles/` with `.storeKey` (the space key in a space session), and the signed log and wrapped key files with `.unsealed`. It owns the check that accepts `noteit-space` only in a space session.
- **plugins**: plugin reads and writes of a locked note get `note_locked`.
- **mobile**: shows locked notes as locked; stores sealed files at `notes/<uuid>.locked`.

## Non-goals

- Turning encryption off for a synced store.
- Per-note passwords, or locking notebooks.
- Encrypting titles of locked notes.
- Recovering a forgotten notes password or sync passphrase.
- Locking notes in shared notebooks.
- WebDAV with digest, NTLM, OAuth or client certificates; custom certificate trust; plain HTTP to non-loopback hosts.
- Three-way merge or editing inside the compare sheet.
- Fencing a running pre-0.3 build during a rekey.

## Open questions

| Question | Default |
|---|---|
| Does a Secure Enclave key work in ad-hoc-signed builds? | Try at enable time; hide the Touch ID option if creation fails. A test skipped on Macs without a Secure Enclave runs the same trial. |
| Keep locked-note titles visible? | Yes. Encrypting titles breaks the list, sort and search; stated in the lock sheet. |
| Store the data key instead of the passphrase in the Keychain? | Yes; the passphrase item is deleted after the first successful unlock. |
| How long does a rekey wait for device acknowledgements? | While the sheet is open, up to 10 minutes; then the sheet offers to remove the devices that haven't acknowledged, or stops, and Finish Encryption Change continues later. |
| Allow WebDAV over plain HTTP on a LAN? | No. Loopback only. |
| WsgiDAV version for CI? | Pin WsgiDAV 4.3.5 and its cheroot dependency in `scripts/webdav-requirements.txt`. |
| PBKDF2 iterations for new keyrings | 600,000 (OWASP 2023 guidance for PBKDF2-SHA256); stored per keyring so it can rise later. |
| Default auto-relock | 5 minutes. |
