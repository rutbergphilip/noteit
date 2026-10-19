# NoteIt Sync Security Implementation Plan

**Goal:** Add locked notes (password and Touch ID), a WebDAV sync backend, a side-by-side conflict compare sheet, change passphrase and turn on encryption for existing sync stores, and an enforced no-telemetry network inventory. No NoteIt server; the wire prefix `inkwell/v1/` stays; every remote addition is gated by a manifest feature.

**Architecture:**
- `NoteItSync` gains a `WebDAVBackend` conforming to `StorageBackend`, a resumable `RekeyRunner` with the `rekeyAck` fence, and the lock-key crypto for locked notes (`NoteLockKeyring`, `LockedBody`). The store-session layer (`StoreSession`, manifest features, `ensureFeature`, `RawMetaOverlay`, the `RemoteLayout` registry, `RekeyScope`, `RekeyBlocker`, `Keyring`) is built and owned by foundations step 3; the shapes are repeated below for reference.
- The app gains `NoteStore+Locking` (sealed bodies through `NoteBodyStorage`, crash-safe lock and Remove Lock), a `NoteLockController` (unlock session, Touch ID, auto-relock), `NoteStore+Conflicts` plus a pure `LineDiff` and `ConflictCompareSheet`, a `SyncEncryptionSheet`, WebDAV settings, a Locked Notes section in Settings › Sync, and `docs/network.md` with `NetworkInventoryTests`.

**Tech Stack:** Swift 6.3 toolchain in Swift 5 language mode, SwiftPM, Foundation/URLSession, CryptoKit (AES-GCM, SHA256, `SecureEnclave.P256`), CommonCrypto (PBKDF2), Security (Keychain), LocalAuthentication, SwiftUI/AppKit. No new Swift package dependencies. CI installs WsgiDAV with pip for the live WebDAV suite.

**Spec:** `docs/specs/2026-10-19-sync-security-design.md`. The program contract `docs/specs/2026-10-19-program-design.md` wins over both.

**Waves:** this plan runs in wave 2, except M5 (locked notes). `locked-notes` requires `noteit-doc`, which arrives with web-app Tasks 0.4–0.5 in wave 3, so M5 runs in wave 3 and lands after those tasks (program §1). Task 3.0 (the backend capabilities `atomicConditionalWrites()`/`atomicConditionalDelete()`) is owned by this plan in wave 2; web-app Task 0.4 uses it.

**Moved to foundations:** Milestone M0 (store sessions, manifest features) and the keyring value types of Task 4.1 are built in wave 0 as foundations step 3 (`docs/plans/2026-10-19-foundations.md`, tasks 3.1 to 3.5). It replaces the type definitions of web-app Task 0.4. `NoteMeta.lock` and `NoteMeta.isLocked` land in foundations task 4.3 as data only. Foundations owns those types; where this plan's copy differs, foundations and the program contract win. The web app and the phone consume them.

---

## Conventions for every task

- Test command (run from the repository root): `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter <Suite> 2>&1 | tail -20`
- App build: `swift build 2>&1 | tail -3` and `swift build -c release 2>&1 | tail -3` must both end with `Build complete!` and 0 errors.
- Never touch real user data in `~/Library/Application Support/NoteIt`. When running the app, set `NOTEIT_DATA_DIR=<project>/.selftest/<name>`.
- Never touch the user's real Keychain items in tests: Keychain-dependent types take a `SecretStore` (the existing protocol behind `SecItemStore`) and tests pass an in-memory one.
- Commit after each task with Conventional Commits, e.g. `feat(sync): add webdav backend`. Never amend, rebase or force.
- No `#Preview`. Comments only where something is non-obvious. Plain English in UI strings, no emojis.
- Settings live in the existing tabs; Locked Notes is a section of the Sync tab, next to Encryption. Menu commands get a `MenuShortcutCommand` case (the single source for menu shortcuts) and a palette entry in `PaletteCommandRegistry`. Every task that adds a menu command updates `MenuShortcutRules` and `docs/keyboard-shortcuts.md` in the same task.
- Every manifest write is a read-modify-write through `SyncEngine.updateManifest`. Every feature older apps can't read is added through `SyncEngine.ensureFeature`. Every note or notebook meta write patches through `RawMetaOverlay`.
- Every body file read or write goes through `NoteBodyStorage`. Nothing outside `NoteStore+Locking`, the remote Remove Lock path and the permanent-deletion path (Delete Now, Empty Recently Deleted, the automatic purge) calls `removeSealed`.
- Everything in `NoteItSync` the app needs is `public` and `Sendable`-correct.
- `[P]` marks a task that can run in parallel with the other `[P]` tasks of the same milestone.

## File structure

```
Sources/NoteItSync/
  Storage/StorageBackend.swift                (modify: StorageError.serverFull, .redirected(URL))
  Storage/WebDAVBackend.swift                 new: WebDAVConfig, WebDAVBackend
  Storage/WebDAVMultistatusParser.swift       new: XMLParser-based PROPFIND response parser
  Model/Manifest.swift                        (foundations: features, keyring, rekey field, raw JSON kept)
  Model/SyncTypes.swift                       (foundations: DeviceInfo.platform, .appVersion, .supportedFeatures, .rekeyAck)
  Model/SyncState.swift                       (foundations: keyID)
  Model/RawMetaOverlay.swift                  (foundations)
  Crypto/Keyring.swift                        (foundations: Keyring, Rekey, KeyIdentity, StoreCredential)
  Crypto/KeyDerivation.swift                  (foundations: normalized; legacy path unchanged)
  Engine/RemoteLayout.swift                   (foundations: prefix registry with depth, key grammar; this plan: keys/ row, lockKeyring())
  Engine/RekeyScope.swift                     (foundations: RekeyScope, RekeyBlocker)
  Engine/StoreSession.swift                   (foundations: StoreFeature, StoreSession, StoreSessionRef; this plan adds .lockedNotes to supported)
  Engine/SyncEngine.swift                     (foundations: connectSession, refresh, updateManifest, ensureFeature, SyncError cases)
  Engine/SyncEngine+Passphrase.swift          new: changePassphrase
  Engine/SyncEngine+Rekey.swift               new: RekeyRunner, rekeyAck fence, progress, resume
  Locking/NoteLockKeyring.swift               new: lock key entries, wrap/unwrap, merge
  Locking/LockedBody.swift                    new: sealed file header, seal/open
Sources/NoteItCore/
  Models/NoteLock.swift                       (foundations task 4.3: NoteLock)
  Models/NoteMeta.swift                       (foundations task 4.3: NoteMeta.lock, isLocked; Task 2.2: conflictTitleSuffix)
Sources/NoteIt/
  Model/NoteStore.swift                       (modify: load reconciliation of sealed files)
  Model/NoteBodyStorage.swift                 (modify: sealed file methods, RTFD implementation; Markdown in markdown-storage Task 10.1 (Milestone 10))
  Model/NoteStore+Sync.swift                  (modify: importConflictCopy records suffix; locked body export/apply)
  Model/NoteStore+Locking.swift               new: lock, unlock, removeLock, sealed save, lockAvailability
  Model/NoteStore+Conflicts.swift             new: ConflictResolution, resolveConflict(_:keeping:)
  Model/VersionHistory.swift                  (modify: no recording for locked notes)
  Export/NoteExporter.swift                   (modify: exportableNotes skips locked)
  Export/ExportActions.swift                  (modify: skipped count, plaintext confirmation)
  Locking/NoteLockController.swift            new: unlock session, relock timer, sleep/lock observers
  Locking/BiometricUnlock.swift               new: Secure Enclave key + LAContext, availability trial
  Locking/LockedNoteView.swift                new: placeholder editor for locked notes
  Locking/LockPasswordSheet.swift             new: set/change/enter/reset notes password, lock sheet text
  Conflicts/LineDiff.swift                    new: DiffRow, LineDiff.rows(left:right:)
  Conflicts/ConflictCompareSheet.swift        new
  Sync/SyncConfiguration.swift                (modify: .webdav, WebDAVServerKind, WebDAVConfig wiring, isS3)
  Sync/Keychain.swift                         (modify: Account.webdavPassword, .syncDataKey, .previousDataKey, .notesLockBiometric)
  Sync/SyncController.swift                   (modify: WebDAV destination, StoreCredential, feature confirmation, rekey statuses)
  Settings/SyncSettingsView.swift             (modify: WebDAV form, Encryption actions, Locked Notes section)
  Settings/SyncEncryptionSheet.swift          new: change passphrase / turn on encryption / finish
  Settings/FeatureConfirmationSheet.swift     new: devices that will stop syncing
  Settings/Preferences.swift                  (modify: PrefKey.lockTimeoutMinutes, .lockWithTouchID)
  Views/EditorContainerView.swift             (modify: Compare… in ConflictBadge, LockedNoteView routing)
  Views/NoteListView.swift                    (modify: lock icon, Compare Conflict…, Lock Note / Remove Lock)
  App/MenuShortcuts.swift                     (modify: lockNote, removeLock, lockAllNotes)
  App/NoteCommands.swift                      (modify: Lock Note, Remove Lock, Lock All Notes in the Note group)
  Palette/PaletteCommandRegistry.swift        (modify: lock commands, compareConflict)
Tests/NoteItSyncTests/
  WebDAVMultistatusParserTests.swift, WebDAVBackendTests.swift, LiveWebDAVTests.swift,
  Support/StubURLProtocol.swift, Fixtures/webdav/*.xml (Resources of the test target),
  PassphraseChangeTests.swift, RekeyTests.swift, NoteLockCryptoTests.swift
Tests/NoteItTests/
  NetworkInventoryTests.swift, LineDiffTests.swift, ConflictResolutionTests.swift,
  NoteLockingTests.swift, SealedFileDeletionTests.swift, RelockPolicyTests.swift,
  BiometricAvailabilityTests.swift, LockedExportTests.swift
Tests/NoteItAPITests/
  LockedNoteContractTests.swift
scripts/live_webdav_tests.sh                  new
scripts/webdav-requirements.txt               new (pinned wsgidav + cheroot)
.github/workflows/ci.yml                      (modify: live WebDAV step)
Package.swift                                 (modify: test target resources for fixtures)
docs/network.md                               new
docs/known-limitations.md, SECURITY.md, docs/architecture.md, docs/keyboard-shortcuts.md, docs/roadmap.md   (modify)
```

## Frozen interfaces

The first two blocks are built and owned by foundations step 3 and step 4 (moved there from this plan's M0 and Task 4.1). They are repeated here, matching the foundations plan, so the tasks below can name them. This includes the two optional `Rekey` fields `previousKeyring` and `previousEncryption`: foundations Task 3.2 declares them and keeps them on every manifest rewrite, and this plan's Task 4.3 only fills them in and clears them. The web app's TypeScript types mirror them.

### NoteItSync: manifest, keyring, sessions (foundations step 3)

```swift
// Model/Manifest.swift (all new fields optional; v1 manifests decode unchanged)
public struct Manifest: Codable, Equatable, Sendable {
    public var formatVersion: Int                 // 1, or 2 whenever features is non-empty
    public var encryption: Encryption?            // v1 only; nil whenever keyring != nil
    public var features: [String]?                // StoreFeature raw values, encoded sorted
    public var keyring: Keyring?
    public var rekey: Rekey?                      // a field, not a feature; set exactly while a rekey runs
    public var createdAt: Date
    // Keys this build doesn't know are kept: updateManifest patches the raw JSON object.
}

// Engine/StoreSession.swift
public enum StoreFeature: String, Sendable, CaseIterable {
    case noteItDoc = "noteit-doc"                 // web-app
    case keyring = "keyring"                      // sync-security
    case lockedNotes = "locked-notes"             // sync-security; requires noteItDoc
    case noteItSpace = "noteit-space"             // sharing; space sessions only, sharing owns the check
    public static let known: Set<String>          // all raw values
    /// Features this build reads; connectSession refuses any other. Empty through foundations tasks 3.1–3.2;
    /// task 3.3 adds .keyring together with connectSession and the keyring cipher, so wave 0 ends with [.keyring].
    /// Device records advertise supportedFeatures only from task 3.3 on.
    /// Task 5.6 adds .lockedNotes; web-app adds .noteItDoc. .noteItSpace never joins it: space sessions pass
    /// StoreFeature.supported ∪ [.noteItSpace] as connectSession's supported.
    public static let supported: Set<StoreFeature>
    public var requires: [StoreFeature] { get }   // lockedNotes → [noteItDoc]; ensureFeature adds these first
}
public enum StoreSessionKind: Sendable { case library, space }
public enum BodyEncoding: Sendable { case rtfd, noteItDocV1 }
public struct StoreSession: Sendable {
    public let kind: StoreSessionKind
    public let manifest: Manifest
    public let manifestETag: String               // unquoted
    public let cipher: SyncCipher
    public let keyID: String?                     // nil for unencrypted stores
    public var features: Set<StoreFeature>
    /// The `supported` set passed to connectSession. refreshedSession, updateManifest and updateRekey check
    /// against it and copy it into every session they return.
    public let supported: Set<StoreFeature>
    /// The unwrapped keyring data key: set for a keyring session (opened with .passphrase or .dataKey, or just
    /// created); nil for v1, keyring-pending, plain and passed-cipher sessions. SyncController saves it to
    /// Keychain `syncDataKey` after a passphrase connect. A session derived with the same keyID keeps it;
    /// changePassphrase and RekeyRunner (.personal) set it on the sessions they return.
    public let dataKey: SymmetricKey?
    public var formatVersion: Int { manifest.formatVersion }
    public var bodyEncoding: BodyEncoding { features.contains(.noteItDoc) ? .noteItDocV1 : .rtfd }   // never formatVersion
}
public final class StoreSessionRef: @unchecked Sendable {   // NSLock-protected; the engine swaps it only on the pass queue
    public init(_ session: StoreSession)
    public var current: StoreSession { get }
    public func replace(_ session: StoreSession)
}

// Crypto/Keyring.swift
public struct Keyring: Codable, Equatable, Sendable {
    public var keyID: String                      // 16 hex chars
    public var kdf: String                        // "pbkdf2-sha256"
    public var salt: Data
    public var iterations: Int                    // 600_000 for new keyrings
    public var wrappedKey: Data                   // AES-GCM combined, aad "keyring/<keyID>"
    public var changedAt: Date
    public var changedBy: String
    public static let defaultIterations = 600_000
    public static func make(dataKey: SymmetricKey, passphrase: String, deviceName: String, now: Date,
                            iterations: Int = defaultIterations) throws -> Keyring
    public func unwrap(passphrase: String) throws -> SymmetricKey      // throws SyncError.wrongPassphrase
    public func rewrapped(dataKey: SymmetricKey, newPassphrase: String, deviceName: String, now: Date) throws -> Keyring
}
public struct Rekey: Codable, Equatable, Sendable {
    public var fromKeyID: String?                 // nil: store was unencrypted
    public var toKeyID: String
    public var startedAt: Date
    public var updatedAt: Date
    public var deviceID: String
    public var deviceName: String
    // Declared by foundations Task 3.2 (optional, so older manifests decode unchanged and wave 0/1 builds
    // keep them on any manifest rewrite); only this plan's Task 4.3 writes them. A personal rekey keeps what it
    // replaced until it finishes, so the old passphrase can still recover the old key; both are nil for a
    // plain store and for .spaceEpoch. Cleared together with the field.
    public var previousKeyring: Keyring?          // the keyring the rekey replaced
    public var previousEncryption: Manifest.Encryption?   // the v1 block the rekey replaced
    public static let staleAfter: TimeInterval = 3600
}
public enum KeyIdentity {
    public static func keyID(for key: SymmetricKey) -> String           // SHA256("noteit-key-id" || key)[0..<8] hex
    public static func legacyKeyID(_ encryption: Manifest.Encryption) -> String  // stable id for v1 stores
}
public enum StoreCredential: Sendable {
    case passphrase(String)
    case dataKey(SymmetricKey)
}

// Crypto/KeyDerivation.swift
extension KeyDerivation {
    public static func normalized(_ passphrase: String) -> String       // NFC; used only for keyring and lock keys
}

// Model/RawMetaOverlay.swift (program §4.5; the web app has the same in TypeScript)
public struct RawMetaOverlay: Sendable, Equatable {
    public init(lastDecrypted: Data?)            // the last decrypted note or notebook JSON, nil for a new record
    /// Keys outside `ownedKeys` come from the last decrypted JSON; owned keys come from `encoded`; nil fields are omitted.
    public func merged(with encoded: Data, ownedKeys: Set<String>) throws -> Data
}

// Engine/RemoteLayout.swift (program §4 rules 6 and 8; the depth table is in the spec §1)
public enum RecordSealing: Sendable, Equatable {
    case storeKey                                 // the session's key: the library's data key, or the space key in a space session
    case spaceKey                                 // objects sealed with a space key inside a personal store
    case unsealed                                 // signed logs, HPKE key files, the canary; never re-sealed
}
public struct RemotePrefix: Sendable, Equatable {
    public let path: String                       // full key prefix, e.g. "inkwell/v1/keys/"
    public let depth: Int                         // segments after `path`; "inkwell/v1/keys/locked-notes.json" is 1
    public let sealing: RecordSealing
    public let owner: String                      // sub-project slug
}
extension RemoteLayout {
    /// One literal list; each sub-project adds its rows. Existing: notebooks/, notes/, tombstones/, devices/.
    public static let prefixes: [RemotePrefix]
    public static func prefix(for key: String) -> RemotePrefix?   // longest matching row whose depth equals the key's
    public static let manifestKey: String         // skipped by rekey
    public static let canaryPrefix: String        // "inkwell/.canary/", keys "inkwell/.canary/<UUID>", skipped by rekey
    public static func isValidKey(_ key: String) -> Bool
    public static func isListablePrefix(_ prefix: String) -> Bool
}

// Engine/RekeyScope.swift (program §4 rule 7)
public enum RekeyBlocker: Sendable, Equatable {
    case notIdle
    case pendingBodyVersions(Int)
    case storageCheckFailed(String)
    case unknownPrefix(String)
    case devicesNotSynced([String])               // non-removed devices without rekeyAck
}
public enum RekeyScope {
    public static func action(for key: String, rekeying: RecordSealing = .storeKey,
                              prefixes: [RemotePrefix] = RemoteLayout.prefixes) -> Action
    public enum Action: Equatable, Sendable { case reseal, skip, block }
}

// Model/SyncTypes.swift
public struct DeviceInfo { /* existing */
    public var platform: String?                  // "mac", "ios" or "web"; nil for older apps
    public var appVersion: String?
    public var supportedFeatures: [String]?       // StoreFeature raw values this app reads; nil counts as none
    public var rekeyAck: String?                  // the rekey id (Rekey.toKeyID) this device acknowledged
}

// Model/SyncState.swift
public struct SyncState { /* existing, plus pendingBodyVersions: [UUID: PendingBody] (foundations Task 3.1, web-app's shape; web-app Task 0.4 writes it) */ public var keyID: String? }

// Engine/SyncEngine.swift
public enum SyncError: Error, Equatable {
    // existing: wrongPassphrase, passphraseRequired, unsupportedFormat(Int), encryptionMismatch, invalidManifest(String)
    case unsupportedFeature(String)
    case featureDeclined(String)
    case keyChanged(byDevice: String)
    case rekeyInProgress(deviceName: String)
    case rekeyIncomplete(done: Int, total: Int)
    case rekeyBlocked(RekeyBlocker)
    case manifestChangedConcurrently
}
public struct FeatureAddition: Sendable {     // what ensureFeature did
    public let session: StoreSession
    public let lateBlockers: [FeatureBlocker]     // appeared between the device check and the write; empty if already set
}
public struct FeatureBlocker: Sendable, Equatable {
    public var deviceID: String
    public var deviceName: String
    public var appVersion: String?
    public var lastSync: Date?
}
extension SyncEngine {
    public static let maxFormatVersion = 2
    /// initialFeatures goes into the first manifest only when createIfMissing creates a new store; it is ignored
    /// for an existing store. supported is the feature set this session accepts (space sessions pass
    /// StoreFeature.supported ∪ [.noteItSpace]). A non-nil cipher replaces the legacy, keyring or passthrough
    /// cipher the session would otherwise build (sharing passes its SpaceCipher).
    /// deviceName is written as Keyring.changedBy when this call creates a keyring store; creating one with an
    /// empty deviceName throws invalidManifest and writes nothing. The legacy connect and
    /// connectReportingCreation wrappers pass "" (they never create keyring stores).
    public static func connectSession(backend: StorageBackend, kind: StoreSessionKind, credential: StoreCredential?,
                                      deviceName: String, createIfMissing: Bool, encrypted: Bool,
                                      initialFeatures: Set<StoreFeature> = [],
                                      supported: Set<StoreFeature> = StoreFeature.supported,
                                      cipher: (any SyncCipher)? = nil) async throws -> (session: StoreSession, created: Bool)
    /// Same keyID: the new session keeps `supported`, a passed cipher and `dataKey`.
    public static func refreshedSession(backend: StorageBackend, current: StoreSession,
                                        credential: StoreCredential?) async throws -> StoreSession
    /// Read-modify-write on the raw manifest JSON with If-Match; a 412 re-reads and re-applies `change` (up to 3 times).
    /// Every retry first re-checks rekey == nil, the key ID, the session kind, the current features and the
    /// requires rules; if any no longer holds it throws rekeyInProgress, keyChanged or manifestChangedConcurrently
    /// instead of replaying the change.
    /// Sets formatVersion = 2 whenever features is non-empty.
    public static func updateManifest(backend: StorageBackend, session: StoreSession,
                                      _ change: @Sendable (inout Manifest) throws -> Void) async throws -> StoreSession
    /// The only writer allowed while rekey is set. Every attempt, retries included, requires
    /// rekey?.toKeyID == expectedRekeyToKeyID, else it throws manifestChangedConcurrently and writes nothing.
    /// `change` may update or clear that rekey and the fields that move with it (keyring, encryption,
    /// previousKeyring, previousEncryption). Starting a rekey still goes through updateManifest.
    public static func updateRekey(backend: StorageBackend, session: StoreSession, expectedRekeyToKeyID: String,
                                   _ change: @Sendable (inout Manifest) throws -> Void) async throws -> StoreSession
    public static func devicesBlocking(_ feature: StoreFeature, backend: StorageBackend, session: StoreSession,
                                       currentDeviceID: String) async throws -> [FeatureBlocker]
    /// The only way to add a feature older apps can't read. Calls `confirm` only when devicesBlocking is non-empty;
    /// false throws featureDeclined and writes nothing. The device check is a warning, not a fence: after a
    /// successful write it lists devices again and returns any new blocker in FeatureAddition.lateBlockers,
    /// which the caller shows once as a notice.
    public static func ensureFeature(_ feature: StoreFeature, backend: StorageBackend, session: StoreSession,
                                     currentDeviceID: String,
                                     confirm: @Sendable ([FeatureBlocker]) async -> Bool) async throws -> FeatureAddition
    public init(backend: StorageBackend, session: StoreSessionRef, local: SyncLocalStore,
                stateURL: URL, deviceID: String, deviceName: String, appVersion: String? = nil,
                platform: DevicePlatform = .mac)   // the phone passes .ios
    public func rebaseline(newKeyID: String) async throws          // adopts re-sealed ETags without body downloads
}

// Storage/StorageBackend.swift (capabilities added and owned by this plan, Task 3.0; defaults false; web-app Task 0.4 uses them)
//   func atomicConditionalWrites() async -> Bool
//   func atomicConditionalDelete() async -> Bool
// FolderBackend returns false for both: the .inkwell-lock flock serializes writers on one Mac only.
```

### NoteItCore: lock data (foundations step 4, data only)

```swift
public struct NoteLock: Codable, Hashable, Sendable { public var keyID: String; public var sealedID: UUID }
public struct NoteMeta { /* existing */
    public var lock: NoteLock?                    // foundations step 4; in revision fields only when non-nil
    public var conflictTitleSuffix: String?       // Task 2.2; in revision fields only when non-nil
}
extension NoteMeta { public var isLocked: Bool { lock != nil } }
```

### NoteItSync: added by this plan

```swift
// Engine/SyncEngine+Passphrase.swift
extension SyncEngine {
    /// Re-wraps the current data key. On a v1 store, adds `keyring` through ensureFeature first, passing
    /// `currentDeviceID` on unchanged. SyncController passes the same device ID it gives SyncEngine.init.
    /// The returned session is a keyring session whose `dataKey` equals the returned `dataKey`.
    public static func changePassphrase(backend: StorageBackend, session: StoreSession,
                                        current: String, new: String, deviceName: String, now: Date,
                                        currentDeviceID: String,
                                        confirm: @Sendable ([FeatureBlocker]) async -> Bool)
                                        async throws -> (session: StoreSession, dataKey: SymmetricKey)
}

// Engine/SyncEngine+Rekey.swift (RekeyBlocker and RekeyScope come from foundations' Engine/RekeyScope.swift)
public struct RekeyProgress: Sendable, Equatable {
    public var done: Int
    public var total: Int
    public var lateBlockers: [FeatureBlocker] = []   // reported once by ensureFeature(.keyring) after its write
}
/// What a rekey changes. Both modes share one implementation of the fence, the re-seal pass, the heartbeat,
/// resume and finish; they differ only in the new cipher and in the manifest write that opens the rekey.
public enum RekeyMode: Sendable {
    /// Personal store: turn on encryption or replace the data key. Library session, sealing .storeKey only.
    /// The opening write adds `keyring` through ensureFeature when missing, then in one updateManifest writes
    /// Keyring.make(newKey, newPassphrase), the `rekey` field, and the replaced keyring or v1 `encryption`
    /// block inside `rekey` (previousKeyring / previousEncryption) until the rekey finishes.
    case personal(newKey: SymmetricKey, newPassphrase: String)
    /// Space epoch rotation (sharing): re-seal with the new epoch's cipher. Sharing passes its new-epoch
    /// SpaceCipher, signing as the owner; the type is SyncCipher because this runner ships in wave 2, before
    /// SpaceCipher exists. `newKeyID` is SpaceSession.keyID(epochKey:). The opening write touches only the
    /// `rekey` field: no keyring, passphrase, `encryption` block or feature is written, and previousKeyring /
    /// previousEncryption stay nil. On a space session the finish write replaces the `encryption` key check
    /// with one sealed by newCipher, in the same write that clears `rekey`. On a space session sealing is .storeKey; on a library
    /// session .spaceKey re-seals space-key objects in a personal store.
    case spaceEpoch(newCipher: any SyncCipher, newKeyID: String)
}
public struct RekeyPlan: Sendable {
    public let oldCipher: SyncCipher              // PassthroughCipher when the store was unencrypted; the old-epoch SpaceCipher for .spaceEpoch
    public let mode: RekeyMode
    public let sealing: RecordSealing             // .storeKey (the session's key: the library key, or the space key on a space session); .spaceKey for space-key objects in a personal store
    public let excludedDevices: Set<String>       // device IDs left out of the fence (sharing: removed members' devices)
    public init(oldCipher: SyncCipher, mode: RekeyMode, sealing: RecordSealing = .storeKey, excludedDevices: Set<String> = [])
}
/// What resume needs. The opening manifest write has already happened, so no passphrase is needed.
public enum RekeyResumeKey: Sendable {
    case personal(newKey: SymmetricKey)                           // checked against rekey.toKeyID
    case spaceEpoch(newCipher: any SyncCipher, newKeyID: String)  // newKeyID must equal rekey.toKeyID
}
public actor RekeyRunner {
    /// `deviceID` is the ID this Mac gives SyncEngine.init for the same store. The runner skips its own
    /// record in the fence and passes it as `currentDeviceID` to ensureFeature.
    public init(backend: StorageBackend, deviceID: String, deviceName: String,
                pendingBodyVersions: @escaping @Sendable () async -> Int,
                storageCheck: @escaping @Sendable (StoreSession) async throws -> Void,   // Check Sync Storage
                ackWait: TimeInterval = 600,      // fence wait on every backend
                heartbeatEvery: Int = 200, heartbeatInterval: TimeInterval = 30,
                clock: @escaping @Sendable () -> Date = Date.init)
    /// `confirm` approves adding `keyring` (.personal only; .spaceEpoch never calls it); `removeStale` is
    /// asked, with the names, when non-removed devices haven't acknowledged within ackWait. true removes their
    /// device records and goes ahead; false throws SyncError.rekeyBlocked(.devicesNotSynced).
    public func start(session: StoreSession, plan: RekeyPlan,
                      confirm: @escaping @Sendable ([FeatureBlocker]) async -> Bool,
                      removeStale: @escaping @Sendable ([String]) async -> Bool,
                      progress: @escaping @Sendable (RekeyProgress) -> Void) async throws -> StoreSession
    /// Continues a rekey whose `rekey` field is set: the fence again (acknowledgements already written count,
    /// so it returns at once when every device has acknowledged), then the re-seal pass and finish.
    public func resume(session: StoreSession, oldCipher: SyncCipher, key: RekeyResumeKey,
                       sealing: RecordSealing = .storeKey, excludedDevices: Set<String> = [],
                       removeStale: @escaping @Sendable ([String]) async -> Bool,
                       progress: @escaping @Sendable (RekeyProgress) -> Void) async throws -> StoreSession
    /// Rebuilds both keys of a personal rekey from the manifest when the Keychain lost them. The new key comes
    /// from the manifest keyring and `newPassphrase` (must match rekey.toKeyID). The old cipher comes from
    /// rekey.previousKeyring and `oldPassphrase` (NFC), or from rekey.previousEncryption and the raw
    /// `oldPassphrase` bytes checked against its keyCheck, and must match rekey.fromKeyID; when fromKeyID is
    /// nil the store was plain, the old cipher is PassthroughCipher and `oldPassphrase` may be nil.
    /// Throws wrongPassphrase or keyChanged and writes nothing.
    public static func recoverPersonalKeys(session: StoreSession, oldPassphrase: String?, newPassphrase: String)
                                           throws -> (oldCipher: SyncCipher, newKey: SymmetricKey)
    /// ETags rewritten by this runner, so the engine can update its bases.
    public var rewrittenETags: [String: String] { get }
}

// Engine/RemoteLayout.swift
//   prefixes gains RemotePrefix(path: "inkwell/v1/keys/", depth: 1, sealing: .storeKey, owner: "sync-security")
extension RemoteLayout {
    public static let keysPrefix = root + "keys/"
    public static func lockKeyring() -> String     // "inkwell/v1/keys/locked-notes.json"
}

// Storage/StorageBackend.swift
public enum StorageError { /* existing */ case serverFull; case redirected(URL) }
```

### NoteItSync: WebDAV

```swift
// Storage/WebDAVBackend.swift
public struct WebDAVConfig: Codable, Equatable, Sendable {
    public var baseURL: URL                       // collection URL, always ends in "/"
    public var username: String
    public init(baseURL: URL, username: String)
}
public actor WebDAVBackend: StorageBackend {
    public init(config: WebDAVConfig, password: String, session: URLSession = .shared,
                retryDelays: [TimeInterval] = [0.5, 1.5])
    // StorageBackend conformance: list(prefix:), get(_:), put(_:data:ifMatch:ifNoneMatch:),
    // delete(_:), delete(_:ifMatch:), probe(), atomicConditionalWrites(), atomicConditionalDelete().
    // ETags in RemoteObject and return values are unquoted; weak ones keep "W/".
}

// Storage/WebDAVMultistatusParser.swift
public struct WebDAVEntry: Equatable, Sendable {
    public var href: String                       // percent-decoded path
    public var isCollection: Bool
    public var etag: String?                      // unquoted
    public var size: Int?
}
public enum WebDAVMultistatusParser {
    public static func parse(_ data: Data) throws -> [WebDAVEntry]   // StorageError.invalidResponse on bad XML
}
```

### NoteItSync: lock crypto

```swift
// Locking/NoteLockKeyring.swift
public struct NoteLockKeyEntry: Codable, Equatable, Sendable {
    public var keyID: String
    public var salt: Data
    public var iterations: Int                    // 600_000
    public var wrappedKey: Data                   // AES-GCM, aad "noteit-lock-key/<keyID>"
    public var wrappedAt: Date
}
public struct NoteLockKeyring: Codable, Equatable, Sendable {
    public var entries: [NoteLockKeyEntry]
    public var hint: String?
    public var current: NoteLockKeyEntry? { get }     // latest wrappedAt
    public static func create(password: String, hint: String?, now: Date,
                              iterations: Int = 600_000) throws -> (NoteLockKeyring, SymmetricKey)
    public func unlockAll(password: String) throws -> [String: SymmetricKey]   // keyID -> LK; throws wrongPassword if none open
    public func changingPassword(from old: String, to new: String, now: Date) throws -> NoteLockKeyring
    public func merged(with other: NoteLockKeyring) -> NoteLockKeyring       // union by keyID, later wrappedAt wins
}
public enum NoteLockError: Error, Equatable { case wrongPassword, unknownKey(String), corrupt }

// Locking/LockedBody.swift
public struct SealedNoteHeader: Codable, Equatable, Sendable { public var keyID: String; public var sealedID: UUID }
public enum LockedBody {
    public static let magic = "NOTEIT-LOCKED/1"
    public static let bodyFormat = "noteit-locked/1"          // remote envelope bodyFormat
    /// `container` is a noteit-doc BodyContainer encoded as JSON. Output: magic line, header JSON line,
    /// AES-GCM combined; the two header lines are the AAD.
    public static func seal(_ container: Data, key: SymmetricKey, header: SealedNoteHeader) throws -> Data
    public static func header(of sealed: Data) throws -> SealedNoteHeader                 // no key needed
    public static func open(_ sealed: Data, key: SymmetricKey) throws -> (header: SealedNoteHeader, container: Data)
}
```

### App

```swift
// Model/NoteBodyStorage.swift (protocol from foundations step 4; these methods added by Task 5.2)
protocol NoteBodyStorage {
    /* existing */
    func sealedBodyURL(for id: UUID) -> URL      // RTFD: notes/<uuid>.locked; Markdown: .noteit/locked/<uuid>.sealed
    func readSealed(_ id: UUID) throws -> Data?
    func writeSealed(_ data: Data, for id: UUID) throws   // temp file, verify, atomic move
    func removeSealed(_ id: UUID) throws          // Remove Lock and permanent deletion only (SealedFileDeletionTests)
}

// Model/NoteStore+Locking.swift
enum LockAvailability: Equatable { case available, sharedNotebook, alreadyLocked }
extension NoteStore {
    var lockKeyring: NoteLockKeyring? { get }
    func lockAvailability(_ id: UUID) -> LockAvailability
    func setNotesPassword(_ password: String, hint: String?) throws
    func lock(_ id: UUID, using controller: NoteLockController) throws
    func removeLock(_ id: UUID, using controller: NoteLockController) throws
    func unlockedBody(for id: UUID, using controller: NoteLockController) throws -> NSAttributedString
    func saveLockedBody(_ text: NSAttributedString, for id: UUID, using controller: NoteLockController) throws
    func resetNotesPassword() throws              // deletes keyring, moves locked notes to Recently Deleted
    var lockedNoteCount: Int { get }
}

// Locking/NoteLockController.swift
@MainActor final class NoteLockController: ObservableObject {
    static let shared: NoteLockController
    @Published private(set) var isUnlocked: Bool
    var timeoutMinutes: Int                       // PrefKey.lockTimeoutMinutes, default 5
    func unlock(password: String) throws
    func unlockWithTouchID() async throws
    func key(for keyID: String) -> SymmetricKey?
    func noteActivity()                           // resets the idle timer
    func lockAll()
}
struct RelockPolicy: Equatable {                  // pure, unit-tested
    var timeout: TimeInterval
    func shouldRelock(lastActivity: Date, now: Date) -> Bool
}

// Locking/BiometricUnlock.swift
enum BiometricUnlock {
    static var isAvailable: Bool { get }          // cached result of availabilityTrial()
    /// Creates and deletes a throwaway Secure Enclave key; false on any failure (covers ad-hoc signing).
    static func availabilityTrial(makeKey: () throws -> Void = defaultTrialKey) -> Bool
    static func enable(keys: [String: SymmetricKey], store: SecretStore) throws
    static func unlock(reason: String, store: SecretStore) async throws -> [String: SymmetricKey]
    static func disable(store: SecretStore)
}

// Conflicts/LineDiff.swift
enum DiffRow: Equatable {
    case same(String)
    case removed(String)                          // left only
    case added(String)                            // right only
    case changed(left: String, right: String)
}
enum LineDiff {
    static let maxLines = 20_000
    static func rows(left: String, right: String) -> [DiffRow]?   // nil when either side exceeds maxLines
}

// Model/NoteStore+Conflicts.swift
enum ConflictResolution { case keepOriginal, keepCopy, keepBoth }
extension NoteStore {
    func canCompareConflict(_ copyID: UUID) -> Bool
    func resolveConflict(_ copyID: UUID, keeping: ConflictResolution, undoManager: UndoManager?) throws
}

// Sync/SyncConfiguration.swift
enum WebDAVServerKind: String, Codable, CaseIterable { case nextcloud, owncloud, synology, other }
enum SyncProvider { /* existing */ case webdav }   // still in the app in wave 2; mobile Task 0.8 (wave 3) then moves the
                                                    // whole enum, .webdav included, to Sources/NoteItSync/Pairing/SyncProvider.swift
struct SyncConfiguration { /* existing */ var webdav: WebDAVConfig?; var webdavServerKind: WebDAVServerKind? }

// Sync/Keychain.swift
enum Keychain.Account { /* existing */ case webdavPassword = "webdav-password"
    case syncDataKey = "syncDataKey"; case previousDataKey = "sync-previous-data-key"
    case notesLockBiometric = "notes-lock-biometric" }

// App/MenuShortcuts.swift (program §9; Note group order: Pin, Lock Note, Remove Lock, Lock All Notes, Version History, Delete)
enum MenuShortcutCommand { /* existing */
    case lockNote                                 // no default shortcut
    case removeLock                               // no default shortcut
    case lockAllNotes                             // ⌥⌃⌘L
}
// Compare Conflict… has no menu item: badge, note list context menu and palette (id compareConflict) only.
```

## Tasks

Milestones ship on their own. M1, M2 and M3 are independent of each other and of foundations (run them in parallel). M1–M4 run in wave 2. M0 and the keyring types of Task 4.1 are built by foundations step 3 in wave 0. M4 needs foundations step 3; Task 4.3 also needs markdown-storage Task 7.2 (Check Sync Storage). M5 runs in wave 3, after web-app Tasks 0.4–0.5 (they add `noteit-doc`, which `locked-notes` requires, to `StoreFeature.supported`). It also needs foundations steps 2–4 (`NoteItDoc` body containers, store sessions, `NoteBodyStorage`, `NoteMeta.lock` from task 4.3 and `refreshDerivedIndexes(for:)` from task 4.4). Locked notes in backups are markdown-storage Task 10.2, not this plan.

### M1: No-telemetry network inventory

### Task 1.1: `docs/network.md` and `NetworkInventoryTests` [P]
**Files:** create `docs/network.md`, `Tests/NoteItTests/NetworkInventoryTests.swift`; modify `SECURITY.md` (link to the doc).

Steps:
- [ ] List today's real connections: `grep -rnE "URLSession|URLRequest\(|NWConnection|NWBrowser|NWListener|WKWebView|NSURLConnection|CFStream|CFHTTP" Sources` and `grep -rnoE "https?://[^/\" ')]+" Sources scripts/build_app.sh`. Expected today: `SyncController.urlSession`, `S3Backend` requests, Sparkle's `SUFeedURL` on `github.com`, provider templates in `SyncConfiguration.swift`/`SyncSettingsView.swift`, `example.com` placeholders.
- [ ] Write `docs/network.md`: prose sections (Sync, Updates, Links you open, What is never sent) and the table between `<!-- network-inventory:start -->` / `<!-- network-inventory:end -->` with columns `Kind | Value | Where | Purpose | When`. `Where` is a comma-separated list of repo-relative paths.
- [ ] Add a **Planned connections** section after the end marker (program §12; this plan owns the rows). One row per future connection with its owner and the rule that it moves into the enforced table in the task that adds the code:
  - Local API listener (`NWListener` on `127.0.0.1`), automation;
  - IMAP mail-in, capture-plus;
  - plugin directory, plugins;
  - sharing uploads to the space store, sharing;
  - web clipper image downloads, web-clipper;
  - speech model download, capture-plus.
  The test doesn't read this section.
- [ ] Write the test. Locate the repo root from `#filePath` (three `deletingLastPathComponent()` calls). Parse the table rows. Scan every `.swift` file under `Sources/` plus `scripts/build_app.sh`, skipping `//` comment lines.
  - `testEveryNetworkAPIUseIsListed`: each API match must have a row of kind `api` whose `Where` contains that file. Failure message: `"<path>:<line> uses <API> but docs/network.md doesn't list it"`.
  - `testEveryHostIsListed`: each host literal must equal a `host` row value; `localhost`, `127.0.0.1`, `[::1]`, `example.com` are allowed.
  - `testNoStaleRows`: every `api` row's file still contains the API, every `host` row still appears somewhere.
  - `testParserReadsTable`: a small inline table parses into the expected rows, and rows after the end marker are ignored.
- [ ] Prove it catches regressions: temporarily add `let _ = URL(string: "https://telemetry.invalid")` to a source file, run, expect FAIL naming the file; revert.
- [ ] Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter NetworkInventoryTests 2>&1 | tail -20`; expect `Executed 4 tests, with 0 failures`.
- [ ] Commit `test: enforce the network inventory in docs/network.md`.

### M2: Side-by-side conflict compare

### Task 2.1: `LineDiff` [P]
**Files:** create `Sources/NoteIt/Conflicts/LineDiff.swift`, `Tests/NoteItTests/LineDiffTests.swift`.

Steps:
- [ ] Split on `\n` after replacing `\r\n` and `\r`. Use `right.difference(from: left)`; walk both arrays with the removal and insertion offsets to emit rows in order. Pair a run of k removals directly followed by a run of m insertions into `min(k, m)` `.changed` rows, then the rest as `.removed`/`.added`.
- [ ] Return nil when either side has more than `LineDiff.maxLines` lines.
- [ ] Tests: `testIdenticalTextIsAllSame`, `testInsertedLine`, `testRemovedLine`, `testChangedLinePairs`, `testUnevenChangeRunLeavesAdds`, `testCRLFNormalized`, `testEmptySides`, `testOverLimitReturnsNil`, `testRowsRebuildBothSides` (concatenating left cells gives left text, right cells gives right text, for 200 random edits with a fixed seed).
- [ ] Run `--filter LineDiffTests`; expect PASS.
- [ ] Commit `feat(conflicts): add line diff for conflict compare`.

### Task 2.2: Conflict resolution in `NoteStore` [P]
**Files:** create `Sources/NoteIt/Model/NoteStore+Conflicts.swift`, `Tests/NoteItTests/ConflictResolutionTests.swift`; modify `Sources/NoteItCore/Models/NoteMeta.swift` (`conflictTitleSuffix`), `Model/NoteStore+Sync.swift` (`importConflictCopy` stores the suffix it appends).

Steps:
- [ ] Add `conflictTitleSuffix: String?` to `NoteMeta` in NoteItCore (optional, decodes nil from old files, in revision fields only when non-nil). Sync writes it through `RawMetaOverlay`.
- [ ] `canCompareConflict`: copy has `conflictOriginalID`, original exists and `deletedAt == nil`.
- [ ] `resolveConflict`:
  - `.keepOriginal`: `moveToRecentlyDeleted(copyID, at:, undoManager:)`.
  - `.keepCopy`: take the copy's body, strip `conflictTitleSuffix` from the end of the first line (fallback: regex ` \(conflict — .+\)$` on the first line), apply it to the original through foundations' `editBody` with the default `versioning: .recordCurrent`, which records the original's current body in version history exactly once and keeps the body container; this task never records a version itself, then move the copy to Recently Deleted. Group both in one undo group.
  - `.keepBoth`: `markConflictResolved(copyID)`.
  - Throws when the original is missing or either side is locked and not unlocked.
- [ ] Tests using a temp `NoteStore` (pattern from existing NoteStore tests): `testKeepOriginalTrashesCopy`, `testKeepCopyReplacesBodyAndStripsSuffix`, `testKeepCopyRecordsHistoryOfOriginal`, `testLegacyCopyWithoutStoredSuffixUsesPattern`, `testKeepBothClearsConflictMarker`, `testUndoRestoresBoth`, `testMissingOriginalThrows`.
- [ ] Run `--filter ConflictResolutionTests`; expect PASS. Commit `feat(conflicts): resolve conflict copies by keeping a side`.

### Task 2.3: `ConflictCompareSheet` and entry points
Depends on 2.1 and 2.2.
**Files:** create `Sources/NoteIt/Conflicts/ConflictCompareSheet.swift`; modify `Views/EditorContainerView.swift` (`ConflictBadge` gains `compare` closure and **Compare…**), `Views/NoteListView.swift` (context menu **Compare Conflict…**), `Palette/PaletteCommandRegistry.swift` (id `compareConflict`, keywords "conflict diff merge", available when `canCompareConflict`).

Steps:
- [ ] No menu bar item: program §9 doesn't list Compare Conflict in the Note group, so it is reached from the badge, the note list context menu and the palette only. No `MenuShortcutCommand` case.
- [ ] Sheet layout per Design §5: two headers, a `LazyVStack` of rows in one `ScrollView` (shared scroll), each row an `HStack` of two equal-width `Text` cells with tints for removed/added/changed, `[image]`/`[file: name]` placeholders from attachments. Change count, **Next Change**/**Previous Change**, three buttons with **Keep Both** as `.defaultAction`, Cancel as `.cancelAction`.
- [ ] Over-limit (`rows == nil`): two plain scrolling text views and the "Too long to compare line by line." note.
- [ ] Observe `NoteStore` changes: refresh the left column if the original changes; dismiss with the "resolved on another Mac" alert if the copy disappears or loses its conflict marker.
- [ ] Manual check with `NOTEIT_DATA_DIR=.selftest/conflicts`: make a conflict with two data dirs (`.selftest/a`, `.selftest/b`) syncing to one Folder store, open Compare…, try each button and ⌘Z.
- [ ] `swift build` and `swift build -c release`: `Build complete!`. Run `--filter PaletteCommand`; expect PASS.
- [ ] Commit `feat(conflicts): add side-by-side conflict compare sheet`.

### M3: WebDAV backend

### Task 3.0: Conditional-write capabilities on every backend [P]
Owned wholly by this plan (program §12). Web-app Task 0.4 (wave 3) uses these capabilities and doesn't change them; Task 3.2 implements them for WebDAV.
**Files:** modify `Sources/NoteItSync/Storage/StorageBackend.swift`, `Storage/S3Backend.swift`, `Storage/FolderBackend.swift`, `Tests/NoteItSyncTests/Support/InMemoryBackend.swift`; create `Tests/NoteItSyncTests/S3BackendConditionalTests.swift`; extend `Tests/NoteItSyncTests/FolderBackendTests.swift`.

Steps:
- [ ] Write failing tests in `S3BackendConditionalTests` (a `URLProtocol` stub provider) and `FolderBackendTests`:
  - a conditional `PUT` (`If-Match` and `If-None-Match`) and a conditional `DELETE` whose response is
    dropped after the stub applied it: exactly one request is sent and `.network` is thrown; an
    unconditional `GET`/`PUT` with a dropped response is retried as today;
  - the HEAD-verify fallback: a pre-write mismatch → `preconditionFailed` with no `PUT` sent; a verify
    mismatch after the `PUT` → `.network`;
  - the extended canary: a compliant stub passes and `atomicConditionalWrites()` is true; stubs that
    ignore `If-None-Match`, ignore `If-Match`, answer 501, reissue the first ETag for different bytes, or
    keep accepting the old ETag after an overwrite each end with `conditionalWritesSupported == false` and
    `atomicConditionalWrites() == false`; a canary that fails with `.network` leaves
    `atomicConditionalWrites()` false and runs again next time;
  - the canary's delete steps: a compliant stub gives `atomicConditionalDelete() == true`; a stub whose
    bogus-`If-Match` `DELETE` succeeds (object gone), one that answers it 501, and one that rejects the
    correct `If-Match` `DELETE` each end with `atomicConditionalDelete() == false` while
    `atomicConditionalWrites()` stays as its write steps decide (and the reverse: write steps failing,
    delete steps passing); afterwards `delete(_:ifMatch:)` throws `conditionalDeleteUnsupported` and the
    stub sees no `HEAD` and no `DELETE`; a 501 on a real conditional `DELETE` mid-session does the same;
  - `FolderBackend.atomicConditionalWrites()` and `atomicConditionalDelete()` are false.
- [ ] `StorageBackend` gains `func atomicConditionalWrites() async -> Bool` and `func atomicConditionalDelete() async -> Bool`; the protocol extension defaults both to false. `StorageError` gains `conditionalDeleteUnsupported(String)`, never fatal.
- [ ] `S3Backend`: `send` skips `retryDelays` when `conditional` is set (every request with `If-Match`/`If-None-Match`), so a transport error or 5xx on it throws `.network` after one attempt; unconditional requests keep `retryDelays`. `verifyUnconditionalWrite` throws `.network("unverified conditional write")` instead of `preconditionFailed`; only `checkPreconditions` gives a definite 412.
- [ ] `S3Backend.runConditionalCanary` adds the two ETag steps (an `If-Match` overwrite with the first ETag must succeed with a different ETag; the same `If-Match` again must get 412) and the delete steps (after the bogus `If-Match` `DELETE` got 412, `HEAD` still finds the canary; the final `DELETE` with the current ETag succeeds, then `HEAD` gets 404). It records `writePassed` and `deletePassed`. `atomicConditionalWrites()` awaits `ensureConditionalsVerified()` and returns `writePassed && conditionalWritesSupported`; `atomicConditionalDelete()` returns `deletePassed && conditionalDeletesSupported`. `delete(_:ifMatch:)` loses its `HEAD` fallback and throws `conditionalDeleteUnsupported` when conditional deletes are unsupported, including after a 501 mid-session.
- [ ] `FolderBackend` returns false for both explicitly: the `.inkwell-lock` flock serializes writers on one Mac only.
- [ ] The test `InMemoryBackend` gains `atomic:` and `atomicDelete:` init flags (both default true); with `atomicDelete: false`, `delete(_:ifMatch:)` throws `conditionalDeleteUnsupported`.
- [ ] Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'S3BackendConditionalTests|FolderBackendTests|S3BackendTests|SyncEngineTests' 2>&1 | tail -20`; expect `0 failures`. Commit `feat(sync): report atomic conditional writes and deletes per backend`.

### Task 3.1: Multistatus parser [P]
**Files:** create `Sources/NoteItSync/Storage/WebDAVMultistatusParser.swift`, `Tests/NoteItSyncTests/WebDAVMultistatusParserTests.swift`, `Tests/NoteItSyncTests/Fixtures/webdav/{nextcloud-depth1.xml, synology-depth1.xml, apache-depth1.xml, wsgidav-depth1.xml, propstat-404.xml}`; modify `Package.swift` (`resources: [.copy("Fixtures")]` on `NoteItSyncTests`).

Steps:
- [ ] `XMLParser` delegate with namespace processing on; match local names `response`, `href`, `propstat`, `status`, `getetag`, `getcontentlength`, `resourcetype`/`collection`. Only properties under a `200` propstat count.
- [ ] Percent-decode hrefs; strip scheme and host when absolute. Store ETags unquoted (program §4.7): strip the surrounding quotes, keep a `W/` prefix.
- [ ] Fixtures are hand-written from each server's documented response shape, with fake host names and user `alice`.
- [ ] Tests: one per fixture, plus `testETagUnquoted`, `testWeakETagKeepsPrefix`, `testMissingETagIsNil`, `testMalformedXMLThrowsInvalidResponse`, `testEncodedSpacesAndUnicodeDecoded`.
- [ ] Run `--filter WebDAVMultistatusParserTests`; PASS. Commit `feat(sync): parse webdav multistatus responses`.

### Task 3.2: `WebDAVBackend`
Depends on 3.0 (the `atomicConditionalWrites()`/`atomicConditionalDelete()` protocol methods) and 3.1.
**Files:** create `Sources/NoteItSync/Storage/WebDAVBackend.swift`, `Tests/NoteItSyncTests/Support/StubURLProtocol.swift`, `Tests/NoteItSyncTests/WebDAVBackendTests.swift`; modify `Storage/StorageBackend.swift` (`serverFull`, `redirected`).

Steps:
- [ ] Reject the config in `init` unless scheme is `https`, or `http` with a loopback host (`localhost`, `127.0.0.1`, `::1`): throw `StorageError.insecureConnectionBlocked` from every call.
- [ ] Preemptive `Authorization: Basic` header. A `URLSessionTaskDelegate` returns nil from `willPerformHTTPRedirection` and the backend maps 3xx to `.redirected(location)`.
- [ ] `list(prefix:)`: breadth-first `PROPFIND Depth: 1` from the collection for `prefix` (404 means empty), body requesting `getetag getcontentlength resourcetype`. Skip the self entry, names starting with `.` or `@`, names ending in `.part`. Return keys relative to `baseURL`.
- [ ] `get`: `GET`; ETag from `ETag` or `OC-ETag`, unquoted.
- [ ] ETags: every ETag returned to callers is unquoted; `If-Match` re-adds the quotes (and the `W/` prefix when present). Tests compare stored values with listed values without normalization.
- [ ] `put`: `If-Match`/`If-None-Match: *`; on 409 run `MKCOL` for each missing ancestor (cache created collections; treat 405 as existing) and retry once. Missing ETag in response: `PROPFIND Depth: 0`.
- [ ] `delete(_:ifMatch:)` with `If-Match`; unconditional 404 is success.
- [ ] Status map: 401/403 `unauthorized`; 404 `notFound`; 412 `preconditionFailed`; 423/429/502/503/504 retried with `retryDelays` (429 and 503 honour `Retry-After`, capped at 30 s), then `network`; 507 `serverFull`; 413 `invalidResponse` with a size message; other 4xx/5xx `invalidResponse`. Conditional requests (`If-Match`, `If-None-Match`) are sent once and never retried after a timeout or 5xx: the caller re-reads, because the first attempt may have applied.
- [ ] `probe()` runs the canary at `RemoteLayout.canaryPrefix + UUID`, extended as in S3: `PROPFIND Depth: 0` on the base; `PUT If-None-Match: *` creates; a second `PUT If-None-Match: *` must return 412; `PUT If-Match: RemoteLayout.canaryMismatchETag` must return 412; `PUT If-Match: <real ETag>` must succeed; `DELETE If-Match: <stale ETag>` must return 412; `DELETE`. Strong ETags on every response are required for writes to count.
- [ ] `atomicConditionalWrites()` returns true only when the create and update checks of the last probe passed with strong ETags; `atomicConditionalDelete()` only when the stale-delete check also passed. Neither is assumed from the server kind. When writes aren't verified, conditional `put` uses the check-write-verify fallback (mirror `S3Backend`). Deletes have no fallback: when conditional deletes aren't verified (or a conditional `DELETE` gets 501 mid-session), `delete(_:ifMatch:)` sends no `DELETE` and throws `conditionalDeleteUnsupported`, as in Task 3.0.
- [ ] Tests with `StubURLProtocol` (a scripted queue of request matchers and responses, ephemeral `URLSessionConfiguration` with `protocolClasses`): `testListWalksCollections`, `testListSkipsHiddenAndPartFiles`, `testPutSendsQuotedIfMatchFromUnquotedETag`, `testReturnedETagsUnquoted`, `testPutCreatesMissingCollections`, `testPutWithoutETagFetchesIt`, `testOCETagUsed`, `test412MapsToPreconditionFailed`, `test423And429Retried`, `testConditionalPutNotRetriedAfterTimeout`, `testRedirectRefused`, `testPlainHTTPToLANBlocked`, `testLoopbackHTTPAllowed`, `testCanaryFallbackWhenIfMatchIgnored`, `testCapabilitiesTrueOnlyAfterFullCanary`, `testWeakETagsDisableAtomicWrites`, `testConditionalDeleteCapabilitySeparate`, `testConditionalDeleteUnsupportedSendsNoDelete`, `testBasicAuthHeader`. End-to-end engine behaviour against a real server is covered by Task 3.3.
- [ ] Run `--filter WebDAVBackendTests`; PASS. Commit `feat(sync): add webdav storage backend`.

### Task 3.3: Live WebDAV suite and CI
Depends on 3.2.
**Files:** create `Tests/NoteItSyncTests/LiveWebDAVTests.swift`, `scripts/live_webdav_tests.sh`, `scripts/webdav-requirements.txt`; modify `.github/workflows/ci.yml`, `docs/development.md`.

Steps:
- [ ] `LiveWebDAVTests` mirrors `LiveS3EmulatorTests`: `XCTSkip` unless `NOTEIT_LIVE_WEBDAV_URL` (and `_USER`, `_PASSWORD`) are set via `AppEnvironment.value`; each test uses a unique sub-collection and cleans up. Tests: probe verifies conditionals and reports both capabilities true on WsgiDAV, round trip, 412 on stale ETag, two engines sync and produce a conflict copy, a 300-note initial sync.
- [ ] `scripts/webdav-requirements.txt`: `wsgidav==4.3.5` and its pinned `cheroot` version (take the version pip resolves today, then pin it).
- [ ] `scripts/live_webdav_tests.sh`: create `.selftest/webdav-venv`, `pip install -r scripts/webdav-requirements.txt`, write a WsgiDAV YAML config (root `.selftest/webdav-root`, `simple_dc` user `noteit`/random password, `hotfixes.emulate_win32_lastmod: false`, conditional evaluation on), pick a free port with `python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'`, start `wsgidav --config <file> --host 127.0.0.1 --port <port>` in the background, wait for a 207 from `PROPFIND`, export the env vars, run `swift test --filter LiveWebDAVTests`, kill the server by PID on exit. With `KEEP_SERVER=1` it skips the tests, leaves the server running and prints its URL, user name and password.
- [ ] CI: add a step after `swift test` on macos-15: `actions/setup-python` (3.12) then `scripts/live_webdav_tests.sh`.
- [ ] `docs/development.md`: how to run the script, and an optional Nextcloud run (`docker run -p 8080:80 nextcloud`, then set the env vars to `http://localhost:8080/remote.php/dav/files/<user>/`).
- [ ] Run `scripts/live_webdav_tests.sh`; expect `Executed 5 tests, with 0 failures` and the server process gone afterwards (`lsof -i :<port>` empty).
- [ ] Commit `ci: run the live webdav suite against wsgidav`.

### Task 3.4: WebDAV in Settings and SyncController
Depends on 3.2.
**Files:** modify `Sources/NoteIt/Sync/SyncConfiguration.swift`, `Sync/Keychain.swift`, `Sync/SyncController.swift`, `Settings/SyncSettingsView.swift`, `docs/known-limitations.md`; extend `Tests/NoteItTests` sync configuration tests.

Steps:
- [ ] `SyncProvider.webdav` (title "WebDAV"), `isS3` as an explicit list of the S3 cases (both in `Sources/NoteIt/Sync/SyncConfiguration.swift`, where the enum lives in wave 2; mobile Task 0.8 moves the enum to `Sources/NoteItSync/Pairing/SyncProvider.swift` in wave 3 and keeps both; the phone refuses `.webdav`), `WebDAVServerKind` with URL templates and help text, `SyncConfiguration.webdav`/`webdavServerKind` (optional, old configs decode), `storeKey` `["webdav", baseURL.absoluteString]`, `destination` shows host and path.
- [ ] `Keychain.Account.webdavPassword`; `Disconnect` and `deleteAll` remove it.
- [ ] `makeDestination` builds `WebDAVBackend(config:password:session: SyncController.urlSession)`. Normalize the URL to end in `/`.
- [ ] Settings form: server kind picker, URL (pre-filled template), user name, app password, **Test Connection** (runs `probe()` and shows whether conditional writes were verified), help text per kind, self-signed certificate note. `describe(_:)` gets messages for `redirected`, `serverFull`, `insecureConnectionBlocked` (WebDAV wording).
- [ ] Tests in a new `Tests/NoteItTests/WebDAVSyncConfigurationTests.swift`: `testWebDAVIsNotS3`, `testWebDAVStoreKeyNormalizesTrailingSlash`, `testOldConfigurationDecodesWithoutWebDAV`, `testDisconnectRemovesWebDAVPassword` (in-memory `SecretStore`).
- [ ] `docs/known-limitations.md`: weak-ETag fallback race; no self-signed trust; no digest auth.
- [ ] Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter WebDAVSyncConfigurationTests 2>&1 | tail -20`; expect `Executed 4 tests, with 0 failures`. Run `swift build 2>&1 | tail -3`; expect `Build complete!`.
- [ ] Build and install the app with `NOTEIT_INSTALL_DIR=.selftest/app scripts/build_app.sh`; expect it to finish with exit code 0 and `.selftest/app/NoteIt.app` to exist. Manual check: start `KEEP_SERVER=1 scripts/live_webdav_tests.sh`, launch `.selftest/app/NoteIt.app` with `NOTEIT_DATA_DIR=.selftest/webdav-settings`, add the printed server in Settings › Sync › WebDAV, and **Test Connection** reports conditional writes verified.
- [ ] Commit `feat(sync): offer webdav in sync settings`.

### M0: Store sessions and manifest features

Moved to foundations (docs/plans/2026-10-19-foundations.md), step 3, tasks 3.1 to 3.5. Foundations owns and builds these types, with the program §4 changes (no `rekey` feature, `StoreFeature.supported` and `requires`, `DeviceInfo.platform`, `RecordSealing` `.storeKey`/`.spaceKey`/`.unsealed`, `RemotePrefix.depth`, `RekeyScope`), and replaces web-app Task 0.4's definitions. This plan adds nothing to M0; the tasks below only point to where each piece is built and tested.

### Task 0.1: Manifest fields, `StoreFeature`, version gate
Moved to foundations (task 3.1; `ensureFeature` and `updateManifest` in task 3.4; `RemoteLayout` and `RawMetaOverlay` in task 3.5).

Scope: the optional manifest fields kept on read-modify-write, with `rekey` a field and never a feature; `features` encoded sorted, nil fields omitted so v1 manifests round-trip byte-identical; `connectSession` refuses `formatVersion > maxFormatVersion` and any feature outside `StoreFeature.supported`; `formatVersion` is 2 whenever `features` is non-empty; `locked-notes` without `noteit-doc` is invalid; `DeviceInfo.platform`, `.appVersion`, `.supportedFeatures`, `.rekeyAck`; `SyncState.keyID`; `RawMetaOverlay`; the `RemoteLayout.prefixes` registry with depth and sealing and the key grammar. `RemoteIndex` never treats `keys/` objects as records.

Foundations tests that cover it: `testV1ManifestRoundTripsUnchanged`, `testRefusesVersion3`, `testRefusesUnknownFeature`, `testRefusesKnownButUnsupportedFeature`, `testFeaturesWithoutVersion2AreInvalid`, `testLockedNotesWithoutNoteItDocIsInvalid`, `testRekeyIsNotAFeature`, `testDeviceInfoWithoutNewFieldsDecodes`, `testSyncStateWithoutKeyIDDecodes`, `testKeysFolderIgnoredByIndex`, `testDeviceRecordListsSupportedFeatures` (3.1); `testUpdateManifestKeepsUnknownKeys`, `testUpdateManifestRetriesOn412`, `testAnyFeatureImpliesVersion2`, `testEnsureFeatureAsksOnlyWhenBlocked`, `testEnsureFeatureDeclinedWritesNothing`, `testEnsureFeatureRefusedDuringRekey`, `testLockedNotesAddsNoteItDocFirst`, `testDeviceWithoutSupportedFeaturesBlocks` (3.4); `testEveryListedPrefixIsRegistered`, `testKeyGrammar`, `testListPrefixes`, `testRekeyScope` (3.5).

### Task 0.2: `connectSession`, `StoreSessionRef`, refresh
Moved to foundations (task 3.3).

Scope: `connectSession` returns a `StoreSession` with `kind`, `features` and `keyID` (`KeyIdentity.legacyKeyID` for v1 encrypted, `keyring.keyID` with a keyring, nil for plain); `.dataKey` credentials must match `keyID`. The engine reads `session.current` for every seal and open. At the start of each pass, a changed manifest ETag triggers `refreshedSession`: same keyID and no foreign `rekey` field replaces the session; a fresh foreign `rekey` throws `rekeyInProgress`; a stale one throws `rekeyIncomplete`; a different keyID throws `keyChanged`. `SyncController.ensureSession` prefers the Keychain data key, then the passphrase, and stores the data key after a passphrase connect on a keyring store. The engine writes `DeviceInfo.platform`, `appVersion` and `supportedFeatures` on every pass.

Foundations tests that cover it: `testConnectV1ReturnsLegacyKeyID`, `testConnectPlainHasNoKeyID`, `testDataKeyCredentialMustMatch`, `testLibrarySessionRefusesSpaceFeature`, `testRefreshKeepsSessionWhenOnlyETagChanged`, `testRefreshThrowsKeyChanged`, `testRefreshThrowsRekeyInProgress`, `testStaleRekeyReportsIncomplete`, `testRunningEngineSeesNewFeature`, `testBodyEncodingFollowsFeatureNotVersion`, `testDeviceWritesSupportedFeatures`.

### M4: Change passphrase and turn on encryption

### Task 4.1: `Keyring` and `KeyIdentity`
Moved to foundations (task 3.2), with M0, because `connectSession` needs it.

Scope: `Keyring.make` wraps a caller-supplied 32-byte data key with a KEK from `KeyDerivation.deriveKey(passphrase: normalized(p), salt:, iterations: 600_000)`, aad `keyring/<keyID>`; `unwrap` maps an authentication failure to `wrongPassphrase`; iterations outside `SyncEngine.iterationRange` are `invalidManifest`. `KeyIdentity.legacyKeyID` is SHA256("noteit-legacy-key" || salt || iterations || keyCheck) truncated the same way as `keyID`. v1 stores keep the raw passphrase bytes.

Foundations tests that cover it (`KeyringTests`): make then unwrap, wrong passphrase, NFC and NFD forms both unwrap, `testV1PassphraseKeepsRawBytes`, `rewrapped` keeps `keyID`, stable `legacyKeyID`, the `Rekey.staleAfter` boundary, and the `keyring` cases in `fixtures/golden/manifest.json`.

### Task 4.2: Change passphrase
Depends on foundations step 3.
**Files:** create `Sources/NoteItSync/Engine/SyncEngine+Passphrase.swift`, `Tests/NoteItSyncTests/PassphraseChangeTests.swift`, `Sources/NoteIt/Settings/SyncEncryptionSheet.swift`, `Sources/NoteIt/Settings/FeatureConfirmationSheet.swift`; modify `Settings/SyncSettingsView.swift`, `Sync/SyncController.swift`, `Sync/Keychain.swift` (`syncDataKey`, `previousDataKey`).

Steps:
- [ ] `changePassphrase`: verify `current` (v1 and keyring pending: `checkedKey` against keyCheck; keyring: `unwrap`). The data key is the verified key. On a keyring-pending store (foundations Task 3.3: `features` has `keyring`, no `keyring` object, the legacy `encryption` block still there) skip `ensureFeature` and `confirm` and go straight to the `updateManifest` below, which installs the keyring. On a v1 store, call `ensureFeature(.keyring, backend:session:currentDeviceID:confirm:)` first, passing on the caller's `currentDeviceID` unchanged; it lists the Macs without `keyring` in `supportedFeatures` and writes nothing if the user declines (`featureDeclined`). Never add `keyring` any other way: a v1 store can't silently lock out 0.2 Macs.
- [ ] Then `updateManifest` (read-modify-write on the raw JSON, If-Match): v1 and keyring pending set `encryption = nil` and `keyring = Keyring.make(...)` with the existing key; a keyring store sets `keyring = rewrapped(...)`. The returned session is a keyring session with `dataKey` set to that key (foundations `StoreSession.dataKey`) and the input session's `supported`. The closure re-checks that the read manifest still has the expected keyID and throws `manifestChangedConcurrently` otherwise. Unknown manifest keys and other features are kept.
- [ ] `FeatureConfirmationSheet`: device name, app version (or "0.2 or earlier"), last sync; text "These Macs will stop syncing until they're updated to NoteIt 0.3 or later." with **Continue** and **Cancel**. `SyncController.confirmFeature(_:)` presents it and returns the answer; every `ensureFeature` call in the app uses it. The device check is a warning, not a lock: when `ensureFeature` returns non-empty `lateBlockers` (its second listing after the write), `SyncController.noteLateFeatureBlockers(_:)` shows them once as a notice ("These Macs will stop syncing until they're updated: …"). It never undoes the write.
- [ ] `SyncController.changePassphrase(current:new:)`: pause the scheduler, call the engine with `currentDeviceID` set to the device ID the controller gives `SyncEngine.init`, store `syncDataKey`, delete `passphrase`, `replace` the session ref, resume.
- [ ] Settings › Sync › Encryption: **Change Passphrase…** (encrypted stores) opens `SyncEncryptionSheet(mode: .change)` with current, new, confirm, `PassphraseStrength` meter, the unchecked **Also replace the encryption key** (switches to Task 4.3's flow), and an explanation that other Macs keep syncing once they run 0.3 or later.
- [ ] Tests (InMemoryBackend):
  - `testV1StoreUpgradesToKeyringWithoutRewritingObjects` (only manifest puts);
  - `testV1ChangeGoesThroughEnsureFeature` (a 0.2 device in `devices/` makes `confirm` run; declining throws `featureDeclined` and the manifest is unchanged);
  - `testLateDeviceReportedAfterChange` (a 0.2 device record is written after `confirm` returns and before the manifest write: the change succeeds and that device comes back once in `lateBlockers` for the notice);
  - `testNoConfirmationWhenEveryDeviceSupportsKeyring`;
  - `testOwnStaleRecordNeverBlocks` (this device's own record, written before foundations Task 3.3 without `supportedFeatures`, is skipped because its ID is passed as `currentDeviceID`);
  - `testV2RewrapKeepsKeyID`;
  - `testChangedSessionCarriesDataKey` (after a change on a v1, a keyring-pending and a keyring store, the returned session's `dataKey` equals the returned `dataKey` and its `KeyIdentity.keyID` is the session's `keyID`);
  - `testChangeFinishesKeyringPending` (a manifest with `features: ["keyring"]`, no `keyring` and a v1 `encryption` block, plus a 0.2 device in `devices/`: `confirm` is never called, one `updateManifest` writes the keyring and removes `encryption`, and the new passphrase opens the store);
  - `testUnknownManifestKeysSurvive`;
  - `testOtherDeviceKeepsSyncingWithDataKey`;
  - `testOtherDeviceWithOnlyOldPassphraseGetsWrongPassphrase`;
  - `testWrongCurrentPassphraseWritesNothing`;
  - `testConcurrentManifestChangeAborts`;
  - `testOldBuildRefusesUpgradedStore` (an engine with `maxFormatVersion = 1` gets `unsupportedFormat(2)`).
- [ ] Run `--filter PassphraseChangeTests`; PASS. `swift build`. Commit `feat(sync): change the sync passphrase by re-wrapping the data key`.

### Task 4.3: Rekey runner
Depends on foundations step 3 and markdown-storage Task 7.2 (`RemoteRestoreDrill`, used as `storageCheck`).
**Files:** create `Sources/NoteItSync/Engine/SyncEngine+Rekey.swift`, `Tests/NoteItSyncTests/RekeyTests.swift`; modify `Engine/SyncEngine.swift` (`rebaseline`, bases update from `rewrittenETags`, `rekeyAck`), `Engine/RemoteLayout.swift` (register `keys/`), `fixtures/golden/layout-keys.json` (`keys/` vectors).

Steps:
- [ ] Register `RemotePrefix(path: "inkwell/v1/keys/", depth: 1, sealing: .storeKey, owner: "sync-security")` and add `keysPrefix`/`lockKeyring()`. Add `layout-keys.json` vectors: `inkwell/v1/keys/locked-notes.json` valid with action `reseal`, `inkwell/v1/keys/a/b.json` (too deep) and `inkwell/v1/keys/` listable. Keep the spec §1 depth table in step with the registry.
- [ ] Preconditions in `start`, checked in this order, each throwing `rekeyBlocked` and writing nothing:
  - a sync pass just finished without error (`notIdle` otherwise);
  - `pendingBodyVersions()` is 0 (`pendingBodyVersions(n)`); the controller counts `SyncState.pendingBodyVersions` (foundations Task 3.1), which stays empty until web-app Task 0.4 writes it;
  - `storageCheck(session)` passes (`storageCheckFailed(reason)`): Check Sync Storage, read-only;
  - no key from a full listing of the store root gets `RekeyScope.action(for:rekeying: plan.sealing)` = `.block` (`unknownPrefix(key)`); a store with prefixes this build doesn't know is never re-sealed.
- [ ] `start` then runs the mode's opening manifest write; after it, both modes share the same code for the fence, the re-seal pass, the heartbeat, resume and finish.
  - `.personal(newKey:newPassphrase:)` (library session, `sealing: .storeKey`): add `keyring` through `ensureFeature(.keyring, backend:session:currentDeviceID: deviceID, confirm:)` when `features` doesn't have it (a keyring-pending store, foundations Task 3.3, already has it: skip `ensureFeature` and `confirm` and go straight to the `updateManifest` below), where `deviceID` is the runner's init parameter; its `lateBlockers` go to the caller once in `RekeyProgress.lateBlockers` for the same one-time notice (Task 4.2). Then one `updateManifest` writes `Keyring.make(newKey, newPassphrase)`, sets `encryption = nil`, and sets the `rekey` field with `fromKeyID` (the session's key ID, nil for a plain store), `toKeyID = KeyIdentity.keyID(for: newKey)`, and the replaced `keyring` as `previousKeyring` or the replaced v1 `encryption` block as `previousEncryption` (both nil for a plain store).
  - `.spaceEpoch(newCipher:newKeyID:)` (sharing's rotation): one `updateManifest` sets only the `rekey` field, with `fromKeyID` = the session's key ID and `toKeyID = newKeyID`. It never calls `ensureFeature` or `confirm`, and writes no keyring, passphrase, `encryption` block or feature. `previousKeyring` and `previousEncryption` stay nil. The key check is replaced only at finish (below).
  - Any other combination of mode, session kind and `sealing` is a programming error (precondition). `rekey` is a manifest field, not a feature, so it never goes through `ensureFeature`. While the field is set no device adds a feature or upgrades the store (`testUpgradeToV2RefusedDuringRekey`).
- [ ] Fence (program §4 rule 7), on every backend. Wait for every device record in `devices/`, other than this one and those in `plan.excludedDevices`, to write `rekeyAck == toKeyID` (the engine does this once and stops pushing when it sees a fresh foreign `rekey` field). Devices are identified by record key (the part after `devices/` without `.json`, `<member-id>/<UUID>` in a space store), never by the record's `deviceID` field, and `excludedDevices` and `removeStale` use the same IDs. Poll every 10 s up to `ackWait`. On timeout call `removeStale(names)`: true deletes those device records and goes ahead; false leaves the `rekey` field in place (so **Finish Encryption Change** can continue) and throws `rekeyBlocked(.devicesNotSynced(names))`. The sheet offers **Wait Longer**, **Remove and Continue** and **Cancel**. A removed device's next pass finds no device record, re-registers and must unlock with the new passphrase.
- [ ] Re-seal pass (shared by `start` and `resume`): list everything under the store root (`inkwell/` and `noteit/`). For each key `RekeyScope.action(for:rekeying: sealing)` decides: `.reseal` is re-sealed; `.skip` (manifest, `.unsealed` rows such as canary keys and sharing's log and key files, and rows with the other sealing such as `.spaceKey` during a library rekey) is counted as done; `.block` stops with `unknownPrefix`. Only contents change; keys and body paths stay the same. The new cipher is the keyring cipher for `newKey` (`.personal`) or `newCipher` (`.spaceEpoch`); nothing else in the pass depends on the mode. Per re-sealed object: `get`; try `newCipher.open(data, context:)`; on success skip; else `oldCipher.open`, `newCipher.seal(_, context:)`, `put(ifMatch: etag)`. Use the engine's own AAD context helper for the key. On `preconditionFailed` re-get and retry up to 3 times, then throw `rekeyIncomplete(done:total:)`.
- [ ] Heartbeat after every `heartbeatEvery` objects or `heartbeatInterval` seconds: `updateRekey(backend:session:expectedRekeyToKeyID: toKeyID, _:)` sets `rekey.updatedAt`. `updateManifest` refuses while the `rekey` field is set, so the heartbeat and finish never use it; only the opening write that sets the field does.
- [ ] Finish: run a second full listing and re-seal anything still under the old key; run `storageCheck` with the new key; then one `updateRekey(backend:session:expectedRekeyToKeyID: toKeyID, _:)` clears the `rekey` field, and with it `previousKeyring` and `previousEncryption` (`formatVersion` stays 2 while features remain). For `.spaceEpoch` on a space session, that same `updateRekey` write replaces the `encryption` block's key check with one sealed by `newCipher` (foundations Task 3.3: a passed-cipher open must open it), so the key check and the cleared field change together; a `.spaceKey` run on a library session leaves the library manifest's key material alone. Return the new session with the input session's `supported`: for `.personal` its cipher is the keyring cipher for `newKey` and its `dataKey` is `newKey`; for `.spaceEpoch` its cipher is `newCipher`, its key ID `newKeyID` and its `dataKey` nil (a passed-cipher session).
- [ ] `resume(session:oldCipher:key:sealing:excludedDevices:removeStale:progress:)` requires the `rekey` field to be set and `key`'s key ID to equal `rekey.toKeyID` (else `keyChanged`, nothing written). It runs the fence again, then the same re-seal pass and finish as `start`. `recoverPersonalKeys(session:oldPassphrase:newPassphrase:)` rebuilds `(oldCipher, newKey)` from the manifest alone, for a device whose Keychain lost `previousDataKey` or `syncDataKey`; the caller then resumes with `resume(session:oldCipher: oldCipher, key: RekeyResumeKey.personal(newKey: newKey), …)`.
- [ ] Sharing runs the same runner on a space session: `RekeyPlan(oldCipher: <old-epoch SpaceCipher>, mode: .spaceEpoch(newCipher: <new-epoch SpaceCipher>, newKeyID: SpaceSession.keyID(epochKey:)), sealing: .storeKey, excludedDevices: <removed members' device IDs>)`. One pass re-seals the space store's `inkwell/v1/` records and its profile rows (sealed by the session cipher, which is the space key). The log and key files are `.unsealed` and skipped. The space manifest gets the `rekey` field at the start, and at finish the key check sealed by the new cipher in the write that clears it. No second re-encryption path exists.
- [ ] Engine: after a local rekey, set bases' `remoteMetaETag`/`bodyETag` from `rewrittenETags` and `SyncState.keyID`. `rebaseline(newKeyID:)` for other devices: for each base whose listed meta ETag differs, get and open the meta; same revision → adopt the meta ETag and the listed body ETag without a body download; different revision → leave for the normal pass. Pending body versions recorded against old ETags are none, by the precondition.
- [ ] Tests (InMemoryBackend, `FaultyBackend`, `FolderBackend` on a temp directory):
  - `testPlainStoreBecomesEncrypted` (every object then fails to open with `PassthroughCipher` and opens with the new key);
  - `testRotateKey` (the returned session's `dataKey` is the new key);
  - `testNothingOpensWithOldKeyAfterRekey` (list the whole root; every object except `manifest.json` and `.unsealed` rows fails to open with the old cipher; `.spaceKey` and `.unsealed` objects are unchanged byte for byte);
  - `testNoteItPrefixReSealed` (objects under `noteit/` registered as `.storeKey` are covered);
  - `testUnknownPrefixRefused`;
  - `testRefusesWithPendingBodyVersions`;
  - `testRefusesWhenStorageCheckFails` and `testStorageCheckRunsBeforeAndAfter`;
  - `testFolderStoreWaitsForAcks` (the runner waits until the second device acks, and times out cleanly without one);
  - `testAtomicStoreAlsoWaitsForAcks` (an `InMemoryBackend` with atomic conditional writes still waits for the fence);
  - `testFenceIdentifiesDevicesByRecordKey` (a record at device A's key whose `deviceID` field names device B, with B's ack, doesn't count for B; the fence keeps waiting for B);
  - `testRemoveStaleDevicesContinues` (`removeStale` returns true: the silent device's record is deleted and the rekey finishes);
  - `testDeclinedRemovalBlocksAndKeepsRekeyField` (`removeStale` returns false: `rekeyBlocked(.devicesNotSynced)`, no object touched, the `rekey` field remains);
  - `testExcludedDevicesNotAwaited`;
  - `testSpaceKeyRekeyResealsOnlySpaceRows` (`.spaceEpoch` with `sealing: .spaceKey` on a library session re-seals `.spaceKey` rows, skips `.storeKey` ones and leaves the library keyring alone);
  - `testUnsealedRowsNeverResealed` (`.unsealed` rows are skipped in both a `.storeKey` and a `.spaceKey` run);
  - `testTombstoneBindingFallsBackToDateRule` (after a rekey, a leftover meta bound to a tombstone by `deletedMetaETag` no longer matches its binding and still loses to the tombstone by the date rule, spec §2);
  - `testUpgradeToV2RefusedDuringRekey`;
  - `testFinishClearsRekeyField` (and `features` never contains `rekey`);
  - `testCrashMidwayResumes` (FaultyBackend fails put #N; resume completes; no object sealed twice);
  - `testRekeyKeepsPreviousKeyringUntilFinish` (keyring store: during the rekey `rekey.previousKeyring` equals the replaced keyring and unwraps with the old passphrase to the old key; v1 store: `rekey.previousEncryption` equals the replaced block; plain store: both nil; after finish the `rekey` field, and both, are gone);
  - `testResumeAfterKeychainLossWithBothPassphrases` (for a keyring store and a v1 store: FaultyBackend fails put #N; delete `previousDataKey` and `syncDataKey` from a test Keychain; `recoverPersonalKeys` with the old and new passphrases; `resume` completes; every `.storeKey` object opens with the new key and none with the old; a wrong old passphrase throws `wrongPassphrase` and writes nothing);
  - `testSpaceEpochModeWritesOnlyRekeyField` (on a space-kind session with two test ciphers: the manifest's `keyring`, `encryption` and `features` are byte-for-byte unchanged during the run; `confirm` is never called; resume with `.spaceEpoch` completes an interrupted run);
  - `testSpaceEpochFinishReplacesKeyCheck` (after finish, in the one write that clears `rekey`, the key check opens with the new cipher and not the old one, `keyring` and `features` are unchanged, and `connectSession` with the new cipher succeeds while the old cipher gets `wrongPassphrase`);
  - `testStartPassesRunnerDeviceIDToEnsureFeature` (the runner's own stale record doesn't block adding `keyring`);
  - `testPersonalRekeyFinishesKeyringPending` (a keyring-pending manifest and a 0.2 device in `devices/`: `confirm` is never called, the opening `updateManifest` writes the new keyring, removes `encryption` and keeps it as `rekey.previousEncryption`, and the rekey finishes);
  - `testConcurrentEditDuringRekeyRetries` (on an atomic store a second engine writes a note between list and put → 412 → retried, content preserved);
  - `testHeartbeatWritten` (the heartbeat succeeds while the `rekey` field is set and changes only `rekey.updatedAt`);
  - `testFinishUsesUpdateRekey` (finish clears the `rekey` field through `updateRekey`; the same clear through `updateManifest` throws `rekeyInProgress`);
  - `testHeartbeatStopsWhenRekeyReplaced` (another device rewrites `rekey` with a different `toKeyID` between the first read and the heartbeat: `updateRekey` throws `manifestChangedConcurrently` and the stored manifest is unchanged; finish does the same);
  - `testOtherDeviceWaitsThenRebaselines` (second device gets `rekeyInProgress`, then `keyChanged`, unlocks with the new passphrase, `rebaseline` downloads zero bodies: assert `getCount` delta equals the number of metas);
  - `testStaleRekeyFinishableByOtherDevice`;
  - `testManifestNeverRewrittenByObjectPass`.
- [ ] Run `--filter RekeyTests`; PASS. Commit `feat(sync): re-encrypt the sync store with a new key`.

### Task 4.4: Turn On Encryption and Finish Encryption Change UI
Depends on 4.2 and 4.3.
**Files:** modify `Settings/SyncEncryptionSheet.swift` (modes `.turnOn`, `.change` with replace key, `.finish`), `Settings/SyncSettingsView.swift`, `Sync/SyncController.swift`, `Sync/SyncConfiguration.swift` (`encrypted` set after success), `docs/known-limitations.md`, `SECURITY.md`.

Steps:
- [ ] Preflight: run one sync pass; refuse with its error if it fails. Run Check Sync Storage and show its result. Show `devices()` with last sync and `appVersion`; flag nil or older versions with "Quit NoteIt on these Macs or update them first." Show the `RekeyBlocker` messages: "Some edits haven't finished uploading. Try again after the next sync.", "Check Sync Storage found problems: …", "This store has data from a newer NoteIt.", and for `devicesNotSynced` "Waiting for these Macs to sync: …" with **Wait Longer**, **Remove and Continue** (asks once more, naming the devices that must reconnect) and **Cancel**.
- [ ] `SyncController` passes `storageCheck: { try await checkSyncStorage(session: $0) }` (markdown-storage Task 7.2) and `pendingBodyVersions: { SyncState.load(from: stateURL(for: config)).pendingBodyVersions.count }` (the field foundations Task 3.1 declares), uses `confirmFeature` for `confirm`, and the sheet's answer for `removeStale`.
- [ ] Progress view bound to `RekeyProgress`, "1,240 of 3,100 items", **Pause** (cancels the task; resumable).
- [ ] Keychain: before `start`, write `previousDataKey` (when encrypted) and new `syncDataKey`; after finish, delete `previousDataKey`. On launch with `rekey.deviceID == deviceID`, resume automatically with the Keychain keys. If either key is missing, or on another device, `.finish` mode asks for the new passphrase, and the old one when `rekey.fromKeyID` is set, and builds both keys with `RekeyRunner.recoverPersonalKeys`, which reads the old key from `rekey.previousKeyring` or `rekey.previousEncryption`. The runner is created with the same device ID the controller gives `SyncEngine.init`.
- [ ] Docs: known-limitations gets "encryption can't be turned off" and the device acknowledgement wait; SECURITY.md describes the keyring, 600,000 iterations, NFC, and that the Keychain holds the data key.
- [ ] Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'PassphraseChangeTests|RekeyTests' 2>&1 | tail -20`; expect `0 failures`. Run `swift build 2>&1 | tail -3`; expect `Build complete!`.
- [ ] Build and install the app with `NOTEIT_INSTALL_DIR=.selftest/app scripts/build_app.sh`; expect exit code 0 and `.selftest/app/NoteIt.app`. Manual check with that app on two data dirs (`NOTEIT_DATA_DIR=.selftest/rekey-a` and `.selftest/rekey-b`) and a Folder store: turn on encryption on A while B is running; A waits for B's ack, B pauses, shows the passphrase prompt after the change, unlock, both sync. Kill A mid-rekey (`kill <pid>`), relaunch, it resumes. Kill A again, delete its `sync-previous-data-key` Keychain item, relaunch: **Finish Encryption Change** asks for the old and new passphrases and completes.
- [ ] Commit `feat(sync): turn on encryption and replace the key from settings`.

### M5: Locked notes

Runs in wave 3, after web-app Tasks 0.4–0.5: `locked-notes` requires `noteit-doc`, and only those tasks add `.noteItDoc` to `StoreFeature.supported`.

### Task 5.1: Lock crypto [P]
**Files:** create `Sources/NoteItSync/Locking/NoteLockKeyring.swift`, `Locking/LockedBody.swift`, `Tests/NoteItSyncTests/NoteLockCryptoTests.swift`.

Steps:
- [ ] `create`: random LK, keyID = SHA256("noteit-lock-key-id" || LK)[0..<8] hex, KEK from `KeyDerivation.normalized(password)`, wrap with aad `noteit-lock-key/<keyID>`.
- [ ] `unlockAll` returns every entry that opens; throws `wrongPassword` if none. `changingPassword` re-wraps every entry that opens with `old`, keeps the others untouched.
- [ ] `merged`: union by keyID; same keyID keeps the later `wrappedAt`; hint from the side with the latest entry.
- [ ] `LockedBody.seal`: write `NOTEIT-LOCKED/1\n`, then the header JSON (sorted keys, no spaces) and `\n`; the AAD is exactly those two lines; append `AES.GCM.seal(container, using: key, authenticating: aad).combined`. `header(of:)` parses the two lines without a key and throws `corrupt` on anything else. `open` checks that the header's keyID matches the key's keyID, then opens with the same AAD. The input is the JSON of a `noteit-doc` `BodyContainer`; `LockedBody` doesn't decode it.
- [ ] Tests: `testCreateAndUnlock`, `testWrongPassword`, `testChangePasswordKeepsAllKeys`, `testMergeUnionAndLatestWins`, `testSealOpenRoundTrip`, `testHeaderReadableWithoutKey`, `testChangedHeaderFailsToOpen` (swap the sealedID), `testTamperedBlobFails`, `testWrongMagicIsCorrupt`, `testNFCPassword`.
- [ ] Run `--filter NoteLockCryptoTests`; PASS. Commit `feat(locking): add note lock keyring and sealed bodies`.

### Task 5.2: Locking in `NoteStore`
Depends on 5.1 and foundations steps 2 and 4 (`NoteItDoc`, `DocConverter`, `NoteBodyStorage`, `NoteMeta.lock` from task 4.3, `DerivedIndex` and `refreshDerivedIndexes(for:)` from task 4.4).
**Files:** create `Sources/NoteIt/Model/NoteStore+Locking.swift`, `Sources/NoteIt/Locking/NoteLockController.swift`, `Tests/NoteItTests/NoteLockingTests.swift`, `Tests/NoteItTests/SealedFileDeletionTests.swift`; modify `Model/NoteBodyStorage.swift`, `Model/NoteStore.swift`, `Model/VersionHistory.swift`.

Steps:
- [ ] `NoteBodyStorage` sealed methods (Frozen interfaces). The RTFD implementation uses `notes/<uuid>.locked`; `writeSealed` writes a temp file in the same folder, reads it back and checks `LockedBody.header(of:)`, then moves it into place atomically. Markdown-storage Task 10.1 (Milestone 10) implements the same methods for `.noteit/locked/<uuid>.sealed` and the placeholder; it builds sealed files with this task's `LockedBody`.
- [ ] Keyring file `lock-keys.json` in the data folder (`NoteStore.rootURL`), written atomically.
- [ ] `lockAvailability`: `.sharedNotebook` when the note's notebook is shared (`NoteStore.spaceID(forNotebook:) != nil`, added by sharing Task 25 and read from sharing's `spaces.json`; false until sharing lands), `.alreadyLocked` when locked. Moving a locked note into a shared notebook is refused with "Notes in shared notebooks can't be locked." (sharing Task 25 enforces it in the move path; this task's test covers it once `spaceID(forNotebook:)` exists).
- [ ] `lock`, in this order: build the `BodyContainer` with `DocConverter.export` from the in-memory body; `LockedBody.seal` with header `{keyID: current entry, sealedID: new UUID}`; `writeSealed`; open it again with the key to verify; set `meta.lock`, clear `preview` and `tags`, save `library.json`; delete the plain body through `NoteBodyStorage`; `VersionHistory.removeHistory(of:)`; delete recovery copies; call `refreshDerivedIndexes(for:)`, which sends `noteRemoved` to every `DerivedIndex` indexer (search re-adds a title-only entry); drop `bodyCache`.
- [ ] Load reconciliation per Design §3 "Never lost by accident": a sealed file always wins; `lock` missing is rebuilt from `LockedBody.header(of:)`; a plain body next to a sealed file is deleted; `lock` set with no sealed file and a plain body clears `lock`; `lock` set with neither marks the note "This locked note's file is missing." Reconciliation never calls `removeSealed`.
- [ ] Permanent deletion (Delete Now, Empty Recently Deleted, the automatic purge, all through the private `removeNotes` loop) deletes the note's sealed file with its other files through `removeSealed`. Moving a locked note to Recently Deleted keeps the sealed file.
- [ ] `DerivedIndex` dispatch, `applyDerivedFields`, `prepareRemoteNote` preview, Spotlight and `VersionHistory.record`/`recordSavedBody` skip locked notes. Image text, links, tasks and reminders get nothing from a locked body.
- [ ] `unlockedBody` and `saveLockedBody` keep plaintext in memory only; `saveLockedBody` exports a new container and goes through `writeSealed` with the same header. `body(for:)` returns an empty string for a locked note and `loadError` is not set.
- [ ] `removeLock`: write the plain body through `NoteBodyStorage`, then `removeSealed`, clear `lock` and save, then rebuild the preview and call `refreshDerivedIndexes(for:)`, which sends `noteChanged` to the indexers.
- [ ] `NoteLockController`: holds `[keyID: SymmetricKey]`; `lockAll` clears it and posts a notification the editor observes.
- [ ] Tests (temp store, fake controller):
  - `testLockWritesSealedFileAndRemovesPlainBody`;
  - `testSealedPlaintextIsNoteItDocContainer`;
  - `testLockClearsPreviewTagsAndHistory`;
  - `testLockSendsNoteRemovedToEveryIndexer` (a recording indexer; search keeps a title-only entry; image text and Spotlight entries gone);
  - `testLockedNoteNeverPassedToIndexers`;
  - `testCrashAfterSealedWriteFinishesLock` (sealed file present, meta without `lock`, plain body present: load sets `lock` from the header and deletes the plain body);
  - `testLockRebuiltFromHeader`;
  - `testInterruptedRemoveLockClearsLock`;
  - `testMissingSealedFileDeletesNothing`;
  - `testEditWhileUnlockedNeverWritesPlaintext` (scan the library directory for the note's text);
  - `testRemoveLockRestoresPreviewAndSearch`;
  - `testWrongKeyMarksUnreadable`;
  - `testRecentlyDeletedKeepsSealed` and `testPermanentDeletionRemovesSealedFile` (Empty Recently Deleted and the automatic purge delete the sealed file through the `removeNotes` path, never through Remove Lock code);
  - `testLockRefusedInSharedNotebook` and `testMoveLockedNoteIntoSharedNotebookRefused`.
- [ ] `SealedFileDeletionTests.testRemoveSealedOnlyCalledFromRemoveLockOrPermanentDeletion`: scan `Sources/` for `removeSealed(`; allowed only in `NoteBodyStorage` implementations, `NoteStore+Locking.swift` (`removeLock`), the remote Remove Lock path in `NoteStore+Sync.swift`, and the permanent-deletion `removeNotes` path.
- [ ] Run `--filter NoteLockingTests` and `--filter SealedFileDeletionTests`; PASS. Commit `feat(locking): lock and unlock notes in the store`.

### Task 5.3: Relock policy and Touch ID
Depends on 5.2.
**Files:** create `Sources/NoteIt/Locking/BiometricUnlock.swift`, `Tests/NoteItTests/RelockPolicyTests.swift`, `Tests/NoteItTests/BiometricAvailabilityTests.swift`; modify `Locking/NoteLockController.swift`, `Settings/Preferences.swift`, `Sync/Keychain.swift` (`notesLockBiometric`).

Steps:
- [ ] `RelockPolicy.shouldRelock`; the controller polls once a minute and on `noteActivity()` (called from editor edits and selection changes).
- [ ] Observers: `NSWorkspace.willSleepNotification`, `NSWorkspace.sessionDidResignActiveNotification`, `DistributedNotificationCenter` `com.apple.screenIsLocked`, `NSApplication.willTerminateNotification` → save sealed, then `lockAll`.
- [ ] `BiometricUnlock.enable`: `SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .biometryCurrentSet], nil))`. For each LK: ephemeral P256 key, ECDH with the enclave public key, HKDF-SHA256 (info "noteit-lock-biometric"), AES-GCM seal. Store JSON `{enclaveKey: dataRepresentation, entries: [{keyID, ephemeralPublicKey, sealed}]}` as base64 in `notesLockBiometric`.
- [ ] `unlock`: `LAContext` with `localizedReason`, pass it as `authenticationContext` when restoring the enclave key; on `LAError.biometryNotEnrolled` or a key that no longer opens, `disable` and throw so the UI falls back to the password.
- [ ] `isAvailable`: `LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)` and `SecureEnclave.isAvailable`, and `availabilityTrial()` succeeds: it creates a throwaway Secure Enclave key without biometry flags (no prompt) and deletes it. Any error, including the one an ad-hoc signed build gets, returns false and hides the Touch ID option. The result is cached for the app run.
- [ ] Tests:
  - `RelockPolicyTests`: `testRelocksAfterTimeout`, `testDoesNotRelockBeforeTimeout`, `testTimeoutChoices` (1, 5, 15, 60).
  - `BiometricAvailabilityTests.testTrialFailureHidesTouchID`: inject a `makeKey` that throws; expect false.
  - `BiometricAvailabilityTests.testRealTrialOnThisMac`: `XCTSkip` unless `SecureEnclave.isAvailable` and `canEvaluatePolicy` are true; then run the real `availabilityTrial()`, expect it to return without crashing or prompting and to leave no key behind, and log the result. Under `swift test` the binary is ad-hoc signed, so false is the usual result and is not a failure.
  - Enabling, relocking and unlocking with a fingerprint is verified manually on a signed build; adding a fingerprint in System Settings must trigger the password fallback.
- [ ] Run `--filter RelockPolicyTests` and `--filter BiometricAvailabilityTests`; PASS (the real-trial test may be skipped). Commit `feat(locking): relock automatically and unlock with touch id`.

### Task 5.4: Locked-note UI, menus, palette, settings
Depends on 5.3.
**Files:** create `Sources/NoteIt/Locking/LockedNoteView.swift`, `Locking/LockPasswordSheet.swift`; modify `Views/EditorContainerView.swift`, `Views/NoteListView.swift`, `App/MenuShortcuts.swift`, `App/NoteCommands.swift`, `Palette/PaletteCommandRegistry.swift`, `Settings/SyncSettingsView.swift`, `docs/keyboard-shortcuts.md`.

Steps:
- [ ] `LockPasswordSheet` modes: create (password twice, hint, forgotten-password warning, required "I understand" checkbox), enter, change, reset (shows the locked note count, destructive confirm). The first lock shows the lock sheet text from Design §3: the title stays visible; earlier versions of this note on this Mac will be deleted; reminders in a locked note won't ring; backups and snapshots made before locking may still contain the note.
- [ ] `LockedNoteView`: title, lock symbol, **Unlock**, auto Touch ID prompt when enabled, hint after two wrong attempts.
- [ ] Editor routing: a locked note shows `LockedNoteView` until unlocked, then the normal editor fed by `unlockedBody` and saving through `saveLockedBody`.
- [ ] Note list: `lock.fill` icon, empty preview line; context menu **Lock Note**/**Remove Lock**. Lock Note is disabled with the help text "Notes in shared notebooks can't be locked." when `lockAvailability` is `.sharedNotebook`.
- [ ] Menu (program §9): the Note group in `NoteCommands` reads Pin, Lock Note, Remove Lock, Lock All Notes, Version History, Delete. `MenuShortcutCommand.lockNote` and `.removeLock` have no default shortcut; `.lockAllNotes` is ⌥⌃⌘L. Lock Note and Remove Lock are separate items, each disabled when it doesn't apply; Lock All Notes is enabled while unlocked. Palette entries for all three with the same availability.
- [ ] `MenuShortcutRules`: add the three cases; `testLockAllNotesShortcut` and `testLockNoteHasNoDefaultShortcut`. Verify ⌥⌃⌘L is free in `MenuShortcutRules` and `FormatCommand`.
- [ ] Settings › Sync, a **Locked Notes** section next to Encryption (shown with or without a sync store, since locking doesn't need sync). Its text says so: "Locked notes work whether or not this library syncs." Controls: Change Notes Password…, Lock after (1/5/15/60 minutes), Unlock with Touch ID (hidden when unavailable), Reset Notes Password….
- [ ] `docs/keyboard-shortcuts.md`: Lock All Notes ⌥⌃⌘L; Lock Note and Remove Lock listed without a shortcut.
- [ ] Run `--filter MenuShortcut` and `--filter PaletteCommand`; PASS. Builds pass. Manual check: lock, relaunch, unlock, edit, wait for the timeout. Commit `feat(locking): add locked note views, menus and settings`.

### Task 5.5: Export
Depends on 5.2. [P with 5.3]
**Files:** modify `Sources/NoteIt/Export/NoteExporter.swift`, `Export/ExportActions.swift`, `App/ExportCommands.swift`; create `Tests/NoteItTests/LockedExportTests.swift`.

Steps:
- [ ] `exportableNotes(in:)` drops locked notes; `exportAll`/`exportNotebook` return the skipped count; the completion message adds "N locked notes were skipped." Markdown-storage's ZIP export uses the same function.
- [ ] `exportCurrentNote` on a locked note: disabled while locked; while unlocked, confirm "This exports the note unencrypted." Copy as Markdown and Print follow the same rule.
- [ ] Backups are not in this task. Locked notes in Back Up Everything, automatic backups, Check a Backup and restore (program §8) are owned by markdown-storage Task 10.2, which builds `BackupWriter`, `BackupReader` and `BackupRestorer` support and their tests on top of Task 5.1.
- [ ] Tests: `testBulkExportSkipsLocked`, `testSkippedCountReported`, `testZipExportSkipsLocked`.
- [ ] Run `--filter LockedExportTests`; PASS. Commit `feat(locking): keep locked notes out of exports`.

### Task 5.6: Locked notes in sync
Depends on 5.2 and foundations step 3.
**Files:** modify `Sources/NoteIt/Model/NoteStore+Sync.swift`, `Sync/NoteStoreSyncAdapter.swift`, `Sync/SyncController.swift`, `Sources/NoteItSync/Engine/StoreSession.swift` (`StoreFeature.supported` gains `.lockedNotes`); extend `Tests/NoteItTests/NoteLockingTests.swift` and `Tests/NoteItSyncTests/StoreSessionTests.swift`.

Steps:
- [ ] `exportBodySource` for a locked note returns the sealed file bytes with `bodyFormat: "noteit-locked/1"`; `bodySHA256` is over the sealed file. The body sits at the note's normal body path for the store format with `.locked` replacing the body suffix (program §4 rule 13); since `locked-notes` requires `noteit-doc`, that is `inkwell/v1/bodies/<UUID>.<VERSION>.<TAG>.locked`. `bodyVersion` increments as usual. The engine never decodes it, and the conversion sweep skips it.
- [ ] Add `.lockedNotes` to `StoreFeature.supported` in this task, which ships the reader (program §4 rule 2).
- [ ] Feature gate: before the first locked note is pushed (or on connect with locked notes), if the session lacks `lockedNotes`, call `ensureFeature(.lockedNotes, backend:session:currentDeviceID:confirm:)` with `currentDeviceID` set to the device ID `SyncController` gives `SyncEngine.init` and `SyncController.confirmFeature` and the text "Locked notes need NoteIt 0.3 or later on every Mac". `ensureFeature` adds `noteit-doc` first, in the same manifest write, when the store doesn't have it (`StoreFeature.requires`). Until both are set, locked notes are held back from push (`pendingPushes`); declining leaves them local. Its `lateBlockers` go to `noteLateFeatureBlockers` (Task 4.2).
- [ ] Meta writes use `RawMetaOverlay` with `lock` in the owned keys, so a writer that doesn't know `lock` keeps it.
- [ ] `prepareRemoteNote`/`applyPreparedRemoteNote`: a remote meta with `lock` writes the sealed file through `writeSealed`, then deletes any plain body (Task 5.2 order). A remote revision without `lock` whose parent revision had it is Remove Lock on another Mac: write the plain body, then `removeSealed`. A remote meta without `lock` and no locked parent never touches a sealed file.
- [ ] Keyring sync: before each pass, if the library has a keyring or the store has `locked-notes`, get `RemoteLayout.lockKeyring()`, `merged`, write locally, and put back with If-Match when it changed (retry once on 412). The keyring is fetched before any locked body is applied.
- [ ] `importConflictCopy` keeps `lock` and `sealedID` on locked copies.
- [ ] Tests:
  - `testLockedNoteSyncsSealed` (remote body never contains the plaintext, even with `PassthroughCipher`; `bodyFormat` is `noteit-locked/1`);
  - `testOtherDeviceShowsLocked`;
  - `testKeyringMergesAcrossDevices`;
  - `testLockedNotesHeldBackUntilFeatureSet` and `testDeclinedFeatureKeepsLockedNotesLocal`;
  - `testLockedNotesAddsNoteItDocFirst` (one confirmation, one manifest write with both features);
  - `testLockedBodyPathUsesLockedSuffix`;
  - `testOlderWriterKeepsLockThroughOverlay`;
  - `testRemoteRemoveLockDeletesSealed`;
  - `testRemoteMetaWithoutLockNeverDeletesSealed`;
  - `testConversionSweepSkipsLockedBodies`;
  - `testLockedConflictCopyOpens`.
- [ ] Run `--filter NoteLockingTests` and `--filter StoreSessionTests`; PASS. Commit `feat(locking): sync locked notes as sealed bodies`.

### Task 5.7: Locked-note contract for the Local API, MCP and plugins
Depends on 5.2 and automation's `NoteSummaryDTO.locked` and `423 note_locked` (built from `NoteMeta.isLocked`). Runs once both exist; plugins' read API is covered when plugins lands.
**Files:** create `Tests/NoteItAPITests/LockedNoteContractTests.swift`.

Steps:
- [ ] Set up a temp store with a really locked note (Task 5.2's `lock`) and the in-process API server used by automation's tests.
- [ ] Tests: `testListShowsLockedTrueAndEmptyPreview`, `testSearchMatchesTitleOnly`, `testBodyReadReturns423NoteLocked`, `testBodyWriteReturns423NoteLocked`, `testMCPReadReturnsNoteLocked`, `testPluginReadReturnsNoteLocked` (skipped until the plugins host exists), `testUnlockedSessionDoesNotOpenAPIAccess` (the app being unlocked doesn't change the API answer).
- [ ] Run `--filter LockedNoteContractTests`; PASS. Commit `test(locking): lock the api contract for locked notes`.

### M6: Docs and review

### Task 6.1: Docs, security review, end-to-end check
**Files:** modify `SECURITY.md`, `docs/known-limitations.md`, `docs/architecture.md`, `docs/keyboard-shortcuts.md`, `docs/network.md`.

Steps:
- [ ] SECURITY.md: locked-note threat model (title visible, offline guessing bounded by PBKDF2 600,000, no recovery, snapshots and backups made before locking may hold earlier plaintext), sealed file format, Touch ID design, keyring, rekey fence, WebDAV credential handling.
- [ ] known-limitations: titles of locked notes are visible; one notes password; locked notes can't be in shared notebooks; reminders in locked notes don't ring; encryption can't be turned off; a rekey waits for every Mac to sync, or for the user to remove the ones that don't; WebDAV weak-ETag fallback; no self-signed trust.
- [ ] architecture: `Locking/`, `Conflicts/`, `WebDAVBackend`, `RekeyRunner`, the `keys/` prefix in the `RemoteLayout` registry, and a pointer to foundations for store sessions and features.
- [ ] Re-run `NetworkInventoryTests` after all milestones (WebDAV adds a `URLRequest(` file); move no Planned rows unless their code has landed.
- [ ] Full suite: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | tail -5` ends with `0 failures`; `swift build -c release` ends with `Build complete!`; `scripts/live_webdav_tests.sh` passes.
- [ ] Two-Mac manual run (two data dirs, WebDAV store from the script): turn on encryption, change passphrase, lock a note, make a conflict, compare and keep each side, Remove Lock on one and see the other unlock.
- [ ] Commit `docs: describe locked notes, webdav and the encryption keyring`.

### Task 6.2: Roadmap
**Files:** modify `docs/roadmap.md`.

Steps:
- [ ] Under "Later: depth": tick **Locked notes** with Touch ID when M5 ships, and each item of the **Sync** bullet (WebDAV, conflict compare, passphrase and encryption) as its milestone ships. Add a no-telemetry item for the network inventory when M1 ships.
- [ ] Add a Design line linking `specs/2026-10-19-sync-security-design.md` under the section, in the same form as the other Design links.
- [ ] Verify: `grep -n 'specs/2026-10-19-sync-security-design.md' docs/roadmap.md` prints one line; `grep -n -E '\[x\].*(WebDAV|[Cc]onflict compare|[Pp]assphrase)' docs/roadmap.md` prints a ticked line for each shipped Sync item; `grep -n -i 'network inventory' docs/roadmap.md` prints the no-telemetry item once M1 has shipped; and `grep -n -E '\[x\].*Locked notes' docs/roadmap.md` prints a line only once M5 has shipped.
- [ ] Commit `docs: update the roadmap for sync security`.

## Self-review

- **Spec coverage:**
  - Shared groundwork, Design §1: foundations step 3 (M0 and Task 4.1, moved), with this plan's additions in 4.3 (`keys/` prefix with depth and vectors; the spec §1 depth table) and 5.6 (`lock` in `RawMetaOverlay`, `.lockedNotes` in `supported`).
  - Keyring and rekey, Design §2: change 4.2, rekey 4.3, UI 4.4.
  - Locked notes, Design §3: crypto 5.1, store 5.2, Touch ID and relock 5.3, UI and settings 5.4, export 5.5 (backups, check and restore are markdown-storage Task 10.2), sync 5.6, API contract 5.7, docs 6.1.
  - WebDAV, Design §4: capabilities on every backend 3.0, parser 3.1, backend and capabilities 3.2, live tests and CI 3.3, settings 3.4.
  - Conflict compare, Design §5: diff 2.1, resolution 2.2, sheet and entry points 2.3.
  - Network inventory, Design §6: 1.1, re-run in 6.1.
  - Roadmap: 6.2.
- **Program contract:**
  - §2 step 3: M0 and `Keyring` moved to foundations, which owns the types; the copies in Frozen interfaces match it. `NoteMeta.lock`/`isLocked` are foundations task 4.3 data.
  - §4 rules 1–8 and 13: feature-keyed body encoding (`bodyEncoding`), formatVersion 2 with any feature, `rekey` as a manifest field, `locked-notes` requiring `noteit-doc`, read-modify-write manifest, `ensureFeature` with confirmation (4.2, 4.3, 5.6), `RawMetaOverlay`, the `RemoteLayout` registry with depth, `.storeKey`/`.spaceKey`/`.unsealed` sealing and the depth table (spec §1), rekey over the whole root through `RekeyScope` with the `rekeyAck` fence on every backend, the `.locked` body path (5.6), unquoted ETags (3.1, 3.2).
  - §8: 5.1–5.7, including deletion of sealed files only by Remove Lock or permanent deletion (5.2).
  - §9: Note group order, Lock Note without a shortcut, Lock All Notes ⌥⌃⌘L, Locked Notes in the Sync tab (5.4), Compare Conflict from the palette, context menu and badge only (2.3).
  - §12: Planned rows in `docs/network.md` (1.1); ownership of `atomicConditionalWrites()`/`atomicConditionalDelete()` and the baseline backend behaviour (3.0), used by web-app Task 0.4.
  - §1 and §8 waves: M1–M4 in wave 2; M5 in wave 3 after web-app Tasks 0.4–0.5.
- **Types:** `StoreSession`, `StoreCredential`, `Keyring`, `KeyIdentity`, `RawMetaOverlay`, `RemotePrefix`, `RekeyScope` and `RekeyBlocker` are defined and built by foundations, repeated in Frozen interfaces, and used by 4.2, 4.3 and 5.6. `NoteLock` and `NoteMeta.lock` come from foundations step 4 and are used by 5.2–5.7. `PendingBody` and `SyncState.pendingBodyVersions` are declared by foundations Task 3.1 (written by web-app Task 0.4) and only counted here, in 4.3 and 4.4. `SealedNoteHeader` and `LockedBody` are defined in 5.1 and used by 5.2, 5.6 and markdown-storage Task 10.1 (Milestone 10). `DiffRow` is defined in 2.1 and used by 2.3. `RemoteLayout.lockKeyring()` is defined in 4.3 and used by 5.6.
- **Wire format:** only additive. New optional manifest fields kept by read-modify-write, a new `keys/` prefix in the registry, and `formatVersion 2` plus features, so old builds refuse instead of misreading. The `inkwell/v1/` prefix is unchanged.
- **Crash safety:** lock (verified sealed file before any plain body is deleted; reconciliation never deletes a sealed file), Remove Lock (plain body written before the sealed file is removed), rekey (resume, objects open with exactly one key, storage check before and after), manifest writes (If-Match everywhere).
- **Known gaps:** a pre-0.3 build that is already running during a rekey writes no `rekeyAck` and isn't fenced beyond If-Match; the user removes it or waits (documented). Touch ID itself is verified manually; the availability trial has an injected test and a real one that skips where unsupported.
- **Placeholders:** none. Every task names files, tests, a command and the expected result.
