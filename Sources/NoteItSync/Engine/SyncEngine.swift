import CryptoKit
import Foundation

public protocol SyncLocalStore: Sendable {
    func records() async -> [LocalRecord]
    func deletions() async -> [UUID: LocalDeletion]
    func export(_ id: UUID, kind: RecordKind) async throws -> RecordPayload
    /// Inserts or replaces the record, keeping `payload.revision`.
    func apply(_ payload: RecordPayload) async throws
    func applyDeletion(_ id: UUID, kind: RecordKind) async throws
    /// Imports the payload as a new record with a new id and a new revision.
    func importConflictCopy(_ payload: RecordPayload, fromDevice name: String) async throws
    func clearDeletion(_ id: UUID) async
    func revision(of id: UUID, kind: RecordKind) async -> UUID?
    func passDidFinish() async
}

extension SyncLocalStore {
    public func revision(of id: UUID, kind: RecordKind) async -> UUID? {
        await records().first { $0.id == id && $0.kind == kind }?.revision
    }
    public func passDidFinish() async {}
}

public struct LocalDeletion: Sendable, Equatable {
    public var kind: RecordKind
    public var deletedAt: Date

    public init(kind: RecordKind, deletedAt: Date) {
        self.kind = kind
        self.deletedAt = deletedAt
    }
}

/// Thrown by `SyncLocalStore.apply` or `importConflictCopy` for a remote record this device can't keep. The engine
/// reports `reason` and doesn't fetch that remote version again; the record syncs again once the remote changes.
public struct SyncRecordRefused: Error, Sendable, Equatable {
    public var reason: String

    public init(reason: String) {
        self.reason = reason
    }
}

/// Thrown by `SyncLocalStore` for a record it can't export or apply yet. The engine skips it quietly, without an
/// error, and tries it again on the next pass.
public struct SyncRecordDeferred: Error, Sendable, Equatable {
    public var reason: String

    public init(reason: String) {
        self.reason = reason
    }
}

public struct SyncReport: Sendable, Equatable {
    public var pushed = 0, pulled = 0, deleted = 0, conflicts = 0, skipped = 0
    public var errors: [String] = []

    public init(pushed: Int = 0, pulled: Int = 0, deleted: Int = 0, conflicts: Int = 0, skipped: Int = 0, errors: [String] = []) {
        self.pushed = pushed
        self.pulled = pulled
        self.deleted = deleted
        self.conflicts = conflicts
        self.skipped = skipped
        self.errors = errors
    }

    /// Adds another pass's counts and errors (the upgrade's pass inside the same `sync()`).
    public mutating func merge(_ other: SyncReport) {
        pushed += other.pushed
        pulled += other.pulled
        deleted += other.deleted
        conflicts += other.conflicts
        skipped += other.skipped
        errors += other.errors
    }
}

public enum SyncError: Error, Equatable, Sendable {
    case wrongPassphrase, passphraseRequired, unsupportedFormat(Int), encryptionMismatch, invalidManifest(String)
    // foundations step 3; each owner plan replaces the app's text for its cases.
    case unsupportedFeature(String)
    case featureDeclined(String)
    case keyChanged(byDevice: String)
    case rekeyInProgress(deviceName: String)
    case rekeyIncomplete(done: Int, total: Int)
    case rekeyBlocked(RekeyBlocker)
    case manifestChangedConcurrently
    // web-app Task 0.4.
    /// A record that breaks the body-format wire rule; per record, never fatal (it lands in `SyncReport.errors`).
    case invalidPayload(String)
    /// `cleanUpUnusedStorage()` on a store without atomic conditional writes; nothing was listed or sent.
    case cleanupUnavailable
}

/// A device whose record says it can't read a feature (foundations step 3; shown by the feature's owner plan).
public struct FeatureBlocker: Sendable, Equatable {
    public var deviceID: String
    public var deviceName: String
    public var appVersion: String?
    public var lastSync: Date?

    public init(deviceID: String, deviceName: String, appVersion: String? = nil, lastSync: Date? = nil) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.appVersion = appVersion
        self.lastSync = lastSync
    }
}

/// Runs sync passes against one remote store. Passes are serialized; each one resumes from the
/// persisted `SyncState`, so an interrupted pass is simply completed by the next.
///
/// Write ordering (deliberately different from the plan; see the T5 report):
/// - push: conditional meta put first, body second. The meta's ETag is the per-record lock, so a
///   writer that loses the race never overwrites the winner's body.
/// - pushDeletion: tombstone first (carrying the meta etag the decision saw), then a conditional meta
///   delete, then the body. A crash in between leaves a meta plus a tombstone naming that same meta,
///   which every device resolves as "finish the deletion".
/// - resurrectPush: delete the tombstone first, then push.
public actor SyncEngine {
    static let keyCheckPlaintext = Data("noteit-key-check".utf8)
    /// What stores created by Inkwell (NoteIt's former name) sealed; still accepted when verifying a passphrase.
    static let legacyKeyCheckPlaintext = Data("inkwell-key-check".utf8)
    static let keyCheckContext = "manifest"
    static let iterationRange = 100_000...10_000_000
    static let defaultIterations = 210_000
    static let deviceWriteInterval: TimeInterval = 10 * 60
    static let tombstoneRetention: TimeInterval = 30 * 24 * 60 * 60
    static let sidecarRetention: TimeInterval = 30 * 24 * 60 * 60
    /// The highest `formatVersion` this build opens (foundations step 3).
    public static let maxFormatVersion = 2

    let backend: StorageBackend
    let session: StoreSessionRef
    let local: SyncLocalStore
    let stateURL: URL
    let deviceID: String
    let deviceName: String
    private let appVersion: String?
    private let platform: DevicePlatform
    let now: @Sendable () -> Date
    /// Fresh `<VERSION>` for each versioned body publish; injectable so golden traces are reproducible.
    let newVersion: @Sendable () -> UUID

    var state = SyncState()
    private var tail: Task<Void, Never>?
    /// Asked by `upgradeToV2` only when a device can't read noteit-doc (web-app Task 0.4). It must never wait for
    /// the user inside a pass; the default declines, so nothing is added without an app that asks.
    var featureConfirm: @Sendable ([FeatureBlocker]) async -> Bool = { _ in false }
    /// Told once about devices that registered between the device check and the manifest write.
    var lateBlockersHandler: @Sendable ([FeatureBlocker]) async -> Void = { _ in }
    /// Runs between the clean pass and the upgrade's manifest write (tests model a racing old client here).
    var beforeUpgradeHook: (@Sendable () async -> Void)?
    /// Whether a clean pass is followed by `upgradeToV2()`. Engines built around a caller's cipher (tests and
    /// tools that predate sessions) never upgrade a store; they still read and write one that has noteit-doc.
    let upgradesAutomatically: Bool

    /// The engine reads `session.current` for every seal and open, and replaces it when the manifest changes.
    public init(backend: StorageBackend, session: StoreSessionRef, local: SyncLocalStore, stateURL: URL,
                deviceID: String, deviceName: String, appVersion: String? = nil, platform: DevicePlatform = .mac) {
        self.init(backend: backend, session: session, local: local, stateURL: stateURL, deviceID: deviceID, deviceName: deviceName,
                  appVersion: appVersion, platform: platform, now: { Date() })
    }

    /// Wraps `cipher` in a v1 session; the first pass adopts the store's manifest without checking its key.
    public init(backend: StorageBackend, cipher: SyncCipher, local: SyncLocalStore, stateURL: URL, deviceID: String, deviceName: String) {
        self.init(backend: backend, cipher: cipher, local: local, stateURL: stateURL, deviceID: deviceID, deviceName: deviceName, now: { Date() })
    }

    init(backend: StorageBackend, cipher: SyncCipher, local: SyncLocalStore, stateURL: URL, deviceID: String, deviceName: String,
         appVersion: String? = nil, now: @escaping @Sendable () -> Date) {
        let wrapped = StoreSession(kind: .library, manifest: Manifest(), manifestETag: "", cipher: cipher, keyID: nil, features: [],
                                   supported: StoreFeature.supported, dataKey: nil)
        self.init(backend: backend, session: StoreSessionRef(wrapped), local: local, stateURL: stateURL, deviceID: deviceID,
                  deviceName: deviceName, appVersion: appVersion, platform: .mac, now: now, upgradesAutomatically: false)
    }

    init(backend: StorageBackend, session: StoreSessionRef, local: SyncLocalStore, stateURL: URL, deviceID: String,
         deviceName: String, appVersion: String? = nil, platform: DevicePlatform = .mac, now: @escaping @Sendable () -> Date,
         newVersion: @escaping @Sendable () -> UUID = { UUID() }, upgradesAutomatically: Bool = true) {
        self.upgradesAutomatically = upgradesAutomatically
        self.backend = backend
        self.session = session
        self.local = local
        self.stateURL = stateURL
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.appVersion = appVersion
        self.platform = platform
        self.now = now
        self.newVersion = newVersion
    }

    /// The `confirm` closure `upgradeToV2` passes to `ensureFeature`; SyncController sets it.
    public func setFeatureConfirm(_ confirm: @escaping @Sendable ([FeatureBlocker]) async -> Bool) {
        featureConfirm = confirm
    }

    public func setLateBlockersHandler(_ handler: @escaping @Sendable ([FeatureBlocker]) async -> Void) {
        lateBlockersHandler = handler
    }

    func setBeforeUpgradeHook(_ hook: (@Sendable () async -> Void)?) {
        beforeUpgradeHook = hook
    }

    /// Throws only fatal errors (unauthorized, clock skew, blocked plain HTTP, unreachable storage, listing failures, missing manifest).
    /// A clean pass on a session without noteit-doc is followed, in the same call, by `upgradeToV2()` (web-app spec
    /// §3.4 item 6); its non-fatal failures are logged and never make `sync()` throw.
    public func sync() async throws -> SyncReport {
        try await serialized {
            var report = try await self.runPass()
            if await self.canUpgrade(after: report), let upgraded = try await self.runUpgrade() {
                report.merge(upgraded)
            }
            return report
        }
    }

    /// Runs `work` on the pass queue: after every earlier `sync()` (or upgrade) finished.
    func serialized<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let pass = Task { () async throws -> T in
            await previous?.value
            do {
                let value = try await work()
                await self.local.passDidFinish()
                return value
            } catch {
                await self.local.passDidFinish()
                throw error
            }
        }
        tail = Task { _ = try? await pass.value }
        return try await pass.value
    }

    public func devices() async throws -> [DeviceInfo] {
        var result: [DeviceInfo] = []
        for object in try await backend.list(prefix: RemoteLayout.root + "devices/") {
            let data = try await backend.get(object.key).data
            result.append(try Self.decode(DeviceInfo.self, from: try open(data, key: object.key)))
        }
        return result.sorted { ($0.name, $0.deviceID) < ($1.name, $1.deviceID) }
    }

    public static func connect(backend: StorageBackend, passphrase: String?, encryptNew: Bool) async throws -> (Manifest, SyncCipher) {
        let result = try await connectReportingCreation(backend: backend, passphrase: passphrase, encryptNew: encryptNew)
        return (result.manifest, result.cipher)
    }

    /// Like `connect`, and also reports whether this call created the store (`false` when joining an existing one).
    public static func connectReportingCreation(backend: StorageBackend, passphrase: String?, encryptNew: Bool) async throws
        -> (manifest: Manifest, cipher: SyncCipher, created: Bool) {
        try await connectReportingCreation(backend: backend, passphrase: passphrase, encryptNew: encryptNew, makeCipher: defaultCipherFactory)
    }

    static func connect(backend: StorageBackend, passphrase: String?, encryptNew: Bool, makeCipher: CipherFactory) async throws -> (Manifest, SyncCipher) {
        let result = try await connectReportingCreation(backend: backend, passphrase: passphrase, encryptNew: encryptNew, makeCipher: makeCipher)
        return (result.manifest, result.cipher)
    }

    /// `connectSession` for a library store; never creates a keyring store, so it passes no device name.
    static func connectReportingCreation(backend: StorageBackend, passphrase: String?, encryptNew: Bool, makeCipher: CipherFactory) async throws
        -> (manifest: Manifest, cipher: SyncCipher, created: Bool) {
        let result = try await connectSession(backend: backend, kind: .library, credential: passphrase.map(StoreCredential.passphrase),
                                              deviceName: "", createIfMissing: true, encrypted: encryptNew,
                                              makeCipher: makeCipher, now: Date())
        return (result.session.manifest, result.session.cipher, result.created)
    }

    /// The one gate for opening a store (program §4), shared by the engine and the app's inspection.
    public static func checkOpenable(_ manifest: Manifest, supported: Set<StoreFeature> = StoreFeature.supported) throws {
        guard manifest.formatVersion <= maxFormatVersion else { throw SyncError.unsupportedFormat(manifest.formatVersion) }
        let names = manifest.features ?? []
        var features: Set<StoreFeature> = []
        for name in names {
            guard let feature = StoreFeature(rawValue: name), supported.contains(feature) else {
                throw SyncError.unsupportedFeature(name)
            }
            features.insert(feature)
        }
        if !names.isEmpty, manifest.formatVersion != 2 {
            throw SyncError.invalidManifest("features without formatVersion 2")
        }
        for feature in StoreFeature.allCases where features.contains(feature) {
            for required in feature.requires where !features.contains(required) {
                throw SyncError.invalidManifest("\(feature.rawValue) without \(required.rawValue)")
            }
        }
    }

    // MARK: - Pass

    final class Pass {
        var report = SyncReport()
        let index: RemoteIndex
        var records: [UUID: LocalRecord]
        let deletions: [UUID: LocalDeletion]
        /// The backend's capabilities, read once per pass (web-app spec §3.4.9).
        let atomicWrites: Bool
        let atomicDeletes: Bool
        var seen: Set<UUID> = []
        var importedCopies = false
        /// Tombstones written or deleted during this pass; the listing is stale for them.
        var touchedTombstones: Set<UUID> = []
        /// Notes whose meta this pass wrote or resolved; the listing is stale for them.
        var touched: Set<UUID> = []
        /// In-doubt entries whose meta moved on: the planner gets the note first, then the entry is dropped.
        var staleInDoubt: Set<UUID> = []

        init(index: RemoteIndex, records: [UUID: LocalRecord], deletions: [UUID: LocalDeletion], atomicWrites: Bool, atomicDeletes: Bool) {
            self.index = index
            self.records = records
            self.deletions = deletions
            self.atomicWrites = atomicWrites
            self.atomicDeletes = atomicDeletes
        }
    }

    func runPass() async throws -> SyncReport {
        let index = RemoteIndex(try await backend.list(prefix: RemoteLayout.root))
        // A missing manifest means the store was wiped; syncing against it would delete everything.
        guard let manifestETag = index.manifestETag else { throw StorageError.notFound(RemoteLayout.manifest()) }
        try await refreshSession(listedETag: manifestETag)
        // Checked on every pass, not only when the manifest changed: a session opened by connectSession, or one
        // adopted from a caller's cipher, already holds the manifest with another device's rekey.
        try Self.checkNoForeignRekey(session.current.manifest, currentDeviceID: deviceID, now: now())

        state = SyncState.load(from: stateURL)
        state.keyID = session.current.keyID
        let records = await local.records()
        let pass = Pass(
            index: index,
            records: Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            deletions: await local.deletions(),
            atomicWrites: await backend.atomicConditionalWrites(),
            atomicDeletes: await backend.atomicConditionalDelete()
        )
        let docSession = session.current.features.contains(.noteItDoc)
        if docSession {
            state.passCount += 1
            try saveState()
        }

        // Each pass first settles this device's uncommitted or in-doubt versioned bodies (spec §3.4.9).
        for id in state.pendingBodyVersions.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            try await guardedRecord(id, pass) { try await self.resolvePendingBody(id, pass) }
        }

        var ids = Set(pass.records.keys)
        ids.formUnion(pass.deletions.keys)
        ids.formUnion(index.metas.keys)
        ids.formUnion(index.tombstones.keys)
        ids.formUnion(state.bases.keys)
        ids.subtract(pass.touched)
        for id in ordered(ids, pass) {
            try await processSafely(id, pass)
        }
        try await dropStaleInDoubtEntries(pass)
        try await guarded(pass) { try await self.resolveSidecars(pass) }

        // Push conflict copies in the same pass so devices converge one round sooner.
        if pass.importedCopies {
            let fresh = await local.records().filter { !pass.seen.contains($0.id) }
            for record in fresh { pass.records[record.id] = record }
            for id in ordered(Set(fresh.map(\.id)), pass) {
                try await processSafely(id, pass)
            }
        }

        try await guarded(pass) { try await self.sweepTombstones(pass) }
        if docSession {
            try await convertLegacyBodies(pass)
            try await guarded(pass) { try await self.sweepOrphanBodies(pass) }
        }
        try await guarded(pass) { try await self.writeDeviceRecordIfDue() }
        return pass.report
    }

    /// Runs one record's work with `processSafely`'s error rules, without marking it seen.
    func guardedRecord(_ id: UUID, _ pass: Pass, _ work: () async throws -> Void) async throws {
        do {
            try await work()
        } catch is SyncRecordDeferred {
            pass.report.skipped += 1
        } catch let error as StorageError {
            if Self.isFatal(error) { throw error }
            pass.report.errors.append("\(id.uuidString): \(error)")
        } catch {
            pass.report.errors.append("\(id.uuidString): \(error)")
        }
    }

    /// Replaces the session when the manifest changed since it was read (foundations step 3). The listing's
    /// ETag decides, so an unchanged pass still makes one request.
    private func refreshSession(listedETag: String) async throws {
        let current = session.current
        guard Self.unquoted(listedETag) != current.manifestETag else { return }
        let (data, rawETag) = try await backend.get(RemoteLayout.manifest())
        let etag = Self.unquoted(rawETag)
        if current.manifestETag.isEmpty {
            // A session wrapped around a caller's cipher: adopt the manifest; the caller already checked the key.
            guard let manifest = try? Self.decode(Manifest.self, from: data) else {
                throw StorageError.invalidResponse("Unreadable manifest")
            }
            try Self.checkOpenable(manifest, supported: current.supported)
            session.replace(StoreSession(kind: current.kind, manifest: manifest, manifestETag: etag, cipher: current.cipher,
                                         keyID: try Self.keyID(of: manifest), features: StoreSession.features(of: manifest),
                                         supported: current.supported, dataKey: current.dataKey, passedCipher: current.passedCipher))
            return
        }
        session.replace(try Self.refreshedSession(current: current, manifestData: data, etag: etag, currentDeviceID: deviceID, now: now()))
    }

    func ordered(_ ids: Set<UUID>, _ pass: Pass) -> [UUID] {
        func rank(_ id: UUID) -> Int {
            switch pass.records[id]?.kind ?? pass.deletions[id]?.kind ?? pass.index.metas[id]?.kind {
            case .notebook: 0
            case .smartFolder: 1
            case .note, nil: 2
            }
        }
        return ids.sorted { (rank($0), $0.uuidString) < (rank($1), $1.uuidString) }
    }

    func guarded(_ pass: Pass, _ work: () async throws -> Void) async throws {
        do {
            try await work()
        } catch is SyncRecordDeferred {
            pass.report.skipped += 1
        } catch let error as StorageError {
            if Self.isFatal(error) { throw error }
            pass.report.errors.append(String(describing: error))
        } catch {
            pass.report.errors.append(String(describing: error))
        }
    }

    /// Errors that would fail every request, so the pass stops instead of collecting one per record.
    static func isFatal(_ error: StorageError) -> Bool {
        switch error {
        case .unauthorized, .clockSkew, .insecureConnectionBlocked, .unavailable, .storeMissing: return true
        default: return false
        }
    }

    func processSafely(_ id: UUID, _ pass: Pass) async throws {
        pass.seen.insert(id)
        do {
            try await process(id, pass)
        } catch is SyncRecordDeferred {
            pass.report.skipped += 1
        } catch let error as StorageError {
            if Self.isFatal(error) { throw error }
            pass.report.errors.append("\(id.uuidString): \(error)")
        } catch {
            pass.report.errors.append("\(id.uuidString): \(error)")
        }
    }

    private func process(_ id: UUID, _ pass: Pass) async throws {
        let localRecord = pass.records[id]
        let deletion = pass.deletions[id]
        let remoteMeta = pass.index.metas[id]
        var metaETag = remoteMeta?.etag
        let kind = localRecord?.kind ?? deletion?.kind ?? remoteMeta?.kind ?? .note

        var tombstone: Tombstone?
        /// A leftover meta that lost to the tombstone but couldn't be deleted (no atomic conditional deletes).
        var leftoverMetaETag: String?
        if let tombstoneETag = pass.index.tombstones[id] {
            if localRecord == nil, let remoteMeta, let binding = state.tombstoneBindings[id], binding.tombstoneETag == tombstoneETag,
               let seen = binding.deletedMetaETag, seen == remoteMeta.etag {
                // A leftover pair resolved before: with no local record, the binding is all the rules below read.
                tombstone = Tombstone(id: id, kind: kind, deletedAt: .distantPast, deviceID: "", deletedMetaETag: seen)
            } else if localRecord != nil || remoteMeta != nil {
                tombstone = try await fetchTombstone(id)
                if !pass.atomicDeletes, remoteMeta != nil, let tombstone {
                    state.tombstoneBindings[id] = .init(tombstoneETag: tombstoneETag, deletedMetaETag: tombstone.deletedMetaETag)
                    try saveState()
                }
            } else {
                // Rows 14/15 don't depend on the tombstone's contents, so skip the get.
                tombstone = Tombstone(id: id, kind: kind, deletedAt: .distantPast, deviceID: "")
            }
        }

        if let remoteMeta, let current = tombstone {
            // A meta and a tombstone together arise from an unfinished deletion or a race; the loser is removed,
            // and where conditional deletes aren't atomic it stays and keeps losing (spec §3.4.9).
            let tombstoneWins: Bool
            if let seen = current.deletedMetaETag {
                // The deleter saw exactly this meta, so it is mid-deletion; any other meta is newer than its decision.
                tombstoneWins = seen == remoteMeta.etag
            } else {
                let envelope = try await fetchEnvelope(id, kind: remoteMeta.kind).envelope
                tombstoneWins = envelope.modifiedAt <= current.deletedAt
            }
            if tombstoneWins {
                if pass.atomicDeletes {
                    do {
                        try await backend.delete(RemoteLayout.meta(remoteMeta.kind, id), ifMatch: remoteMeta.etag)
                    } catch StorageError.notFound {
                    } catch StorageError.preconditionFailed {
                        pass.report.skipped += 1
                        return
                    }
                    // Versioned bodies of a note with a tombstone and no meta are the orphan sweep's.
                    if remoteMeta.kind == .note, pass.atomicWrites, let bodyETag = pass.index.bodies[id] {
                        try await deleteIfUnchanged(RemoteLayout.body(id), listedETag: bodyETag)
                    }
                } else {
                    leftoverMetaETag = remoteMeta.etag
                }
                metaETag = nil
            } else {
                if pass.atomicDeletes, let tombstoneETag = pass.index.tombstones[id] {
                    try await deleteIfUnchanged(RemoteLayout.tombstone(id), listedETag: tombstoneETag)
                    forgetTombstoneDate(id, pass)
                }
                tombstone = nil
            }
        }

        let base = state.bases[id]
        let action = SyncPlanner.decide(
            local: localRecord,
            localDeletedAt: deletion?.deletedAt,
            remote: RemoteInfo(metaETag: metaETag, tombstone: tombstone),
            base: base
        )

        if let refused = state.refusedRemotes[id] {
            if refused.metaETag != metaETag {
                state.refusedRemotes[id] = nil
                try saveState()
            } else if action == .pull || action == .conflict {
                pass.report.skipped += 1
                pass.report.errors.append("\(id.uuidString): \(refused.reason)")
                return
            }
        }

        switch action {
        case .none:
            guard let base, let localRecord, kind == .note, base.revision == localRecord.revision, metaETag == base.remoteMetaETag else { return }
            if let version = base.bodyVersion {
                try await repairDocBodyIfMissing(id, version: version, base: base, pass)
            } else {
                if session.current.features.contains(.noteItDoc), !state.legacyBodies.contains(id) {
                    state.legacyBodies.insert(id)
                    try saveState()
                }
                if base.bodyETag != nil, base.bodyETag != pass.index.bodies[id] {
                    try await repairLegacyBody(id, base: base, pass)
                }
            }
        case .push:
            guard let localRecord else { return }
            try await push(id, kind: localRecord.kind, remoteETag: metaETag, pass)
        case .pull:
            guard let metaKind = remoteMeta?.kind else { return }
            if try await pull(id, kind: metaKind, expectedLocalRevision: localRecord?.revision, pass), deletion != nil {
                await local.clearDeletion(id)
            }
        case .conflict:
            guard let localRecord else { return }
            try await resolveConflict(id, local: localRecord, pass)
        case .pushDeletion:
            guard let deletion else { return }
            try await pushDeletion(id, deletion, metaETag: metaETag, pass)
        case .applyRemoteDeletion:
            guard let localRecord else { return }
            guard await currentRevision(id) == localRecord.revision else {
                pass.report.skipped += 1
                return
            }
            try await local.applyDeletion(id, kind: localRecord.kind)
            state.bases[id] = nil
            state.pendingPushes[id] = nil
            try saveState()
            pass.report.deleted += 1
        case .resurrectPush:
            guard let localRecord else { return }
            if pass.atomicDeletes, let tombstoneETag = pass.index.tombstones[id] {
                try await deleteIfUnchanged(RemoteLayout.tombstone(id), listedETag: tombstoneETag)
                forgetTombstoneDate(id, pass)
            }
            // A leftover meta (no atomic deletes) is overwritten with If-Match; the tombstone then loses to it.
            try await push(id, kind: localRecord.kind, remoteETag: leftoverMetaETag, pass)
        case .forgetBase:
            if base != nil || state.pendingPushes[id] != nil {
                state.bases[id] = nil
                state.pendingPushes[id] = nil
                try saveState()
            }
            if deletion != nil { await local.clearDeletion(id) }
        }
    }

    // MARK: - Actions

    /// Conditional on `remoteETag` (or on absence when nil). Returns false when another writer got there first.
    /// The wire rule (spec §3.4 item 8) runs right after `export`, before anything is persisted or sent, so a bad
    /// record causes no remote write and no state change. A noteit-doc body takes the versioned publish.
    /// `requireDoc`: conversion and body repair publish only a noteit-doc body; a legacy export is skipped quietly.
    @discardableResult
    func push(_ id: UUID, kind: RecordKind, remoteETag: String?, _ pass: Pass, requireDoc: Bool = false) async throws -> Bool {
        let payload = try await local.export(id, kind: kind)
        let features = session.current.features
        try BodyFormat.validateForPublish(payload.bodyFormat, features: features)
        if requireDoc, payload.bodyFormat == nil { return false }
        if let format = payload.bodyFormat {
            guard kind == .note, payload.body != nil else { throw SyncError.invalidPayload("bodyFormat: \(format) without a note body") }
            // Old clients can't read it, so a versioned body never goes to a store without the feature.
            guard features.contains(.noteItDoc) else { throw SyncError.invalidPayload("bodyFormat: \(format) in a store without noteit-doc") }
            return try await publishDoc(id, payload: payload, remoteETag: remoteETag, pass)
        }
        if state.pendingBodyVersions[id] != nil {
            // An in-doubt versioned body could still be committed; nothing else is published for the note meanwhile.
            pass.report.skipped += 1
            return false
        }
        let envelope = RemoteEnvelope(
            id: id, kind: kind, revision: payload.revision, modifiedAt: payload.modifiedAt,
            deviceID: deviceID, deviceName: deviceName, meta: payload.meta,
            bodySHA256: payload.body.map(Self.sha256Hex)
        )
        state.pendingPushes[id] = payload.revision
        try saveState()
        let newETag: String
        do {
            newETag = try await backend.put(
                RemoteLayout.meta(kind, id), data: try seal(try Self.encode(envelope), key: RemoteLayout.meta(kind, id)),
                ifMatch: remoteETag, ifNoneMatch: remoteETag == nil
            )
        } catch StorageError.preconditionFailed {
            state.pendingPushes[id] = nil
            try saveState()
            pass.report.skipped += 1
            return false
        }
        var bodyETag: String?
        if let body = payload.body {
            bodyETag = try await backend.put(RemoteLayout.body(id), data: try seal(body, key: RemoteLayout.body(id)), ifMatch: nil, ifNoneMatch: false)
        }
        state.bases[id] = .init(revision: payload.revision, remoteMetaETag: newETag, replacedMetaETag: remoteETag, bodyETag: bodyETag)
        state.pendingPushes[id] = nil
        if kind == .note, features.contains(.noteItDoc) { state.legacyBodies.insert(id) }
        pass.touched.insert(id)
        try saveState()
        pass.report.pushed += 1
        return true
    }

    /// Returns false (skipped) when the remote is mid-upload or the local record changed during the pass.
    private func pull(_ id: UUID, kind: RecordKind, expectedLocalRevision: UUID?, _ pass: Pass) async throws -> Bool {
        let fetched = try await fetchEnvelope(id, kind: kind)
        // A meta refresh (spec §3.4.9): same revision and body version under a new ETag. Nothing to download.
        if try adoptRefreshedMeta(id, fetched) { return false }
        let remote = try await fetchRemote(id, kind: kind, pass, fetched: fetched)
        guard let payload = remote.payload, await currentRevision(id) == expectedLocalRevision else {
            pass.report.skipped += 1
            return false
        }
        do {
            try await adopt(payload, envelope: remote.envelope, etag: remote.etag)
        } catch let refusal as SyncRecordRefused {
            try refuse(id, metaETag: remote.etag, refusal, pass)
            return false
        }
        pass.report.pulled += 1
        return true
    }

    private func refuse(_ id: UUID, metaETag: String, _ refusal: SyncRecordRefused, _ pass: Pass) throws {
        state.refusedRemotes[id] = .init(metaETag: metaETag, reason: refusal.reason)
        try saveState()
        pass.report.skipped += 1
        pass.report.errors.append("\(id.uuidString): \(refusal.reason)")
    }

    private func adopt(_ payload: RecordPayload, envelope: RemoteEnvelope, etag: String) async throws {
        try await local.apply(payload)
        state.bases[payload.id] = .init(revision: payload.revision, remoteMetaETag: etag, bodyVersion: envelope.bodyVersion)
        state.pendingPushes[payload.id] = nil
        noteBodyFormat(of: envelope)
        try saveState()
    }

    /// Keeps `legacyBodies` and the pending entry in step with the envelope this device now holds as its base. Our own
    /// in-doubt commit that landed is adopted here (pull or the same-revision branch), which clears its entry.
    func noteBodyFormat(of envelope: RemoteEnvelope) {
        let id = envelope.id
        guard envelope.kind == .note else { return }
        if envelope.bodyFormat == nil { state.legacyBodies.insert(id) } else { state.legacyBodies.remove(id) }
        state.bodyMissingSince[id] = nil
        if let pending = state.pendingBodyVersions[id], pending.version == envelope.bodyVersion {
            clearPendingBody(id)
        }
    }

    /// A noteit-doc envelope with the base's revision and body version under a new ETag is another device's meta
    /// refresh, not an edit: only `base.remoteMetaETag` moves. True when that is what `fetched` is.
    private func adoptRefreshedMeta(_ id: UUID, _ fetched: (envelope: RemoteEnvelope, etag: String)) throws -> Bool {
        let envelope = fetched.envelope
        guard envelope.kind == .note, let base = state.bases[id], let version = base.bodyVersion,
              envelope.bodyFormat != nil, envelope.revision == base.revision, envelope.bodyVersion == version,
              base.remoteMetaETag != fetched.etag else { return false }
        state.bases[id]?.remoteMetaETag = fetched.etag
        noteBodyFormat(of: envelope)
        try saveState()
        return true
    }

    private func resolveConflict(_ id: UUID, local localRecord: LocalRecord, _ pass: Pass) async throws {
        let kind = localRecord.kind
        let fetched = try await fetchEnvelope(id, kind: kind)
        if fetched.envelope.revision != localRecord.revision, try adoptRefreshedMeta(id, fetched) {
            // The remote didn't change: push the local edit against the refreshed ETag, with no conflict copy.
            try await push(id, kind: kind, remoteETag: fetched.etag, pass)
            return
        }
        let remote = try await fetchRemote(id, kind: kind, pass, fetched: fetched)
        let envelope = remote.envelope

        if envelope.revision == localRecord.revision {
            // Our own write from an interrupted pass: finish it instead of copying ourselves.
            var bodyETag = remote.bodyETag
            if remote.payload == nil, envelope.bodyFormat == nil {
                let payload = try await local.export(id, kind: kind)
                guard payload.revision == envelope.revision, payload.bodyFormat == nil else {
                    try await push(id, kind: kind, remoteETag: remote.etag, pass)
                    return
                }
                if let body = payload.body, pass.atomicWrites {
                    bodyETag = try await putLegacyBody(id, body: body, replacing: pass.index.bodies[id])
                }
            }
            let owned = envelope.deviceID == deviceID
            state.bases[id] = .init(revision: envelope.revision, remoteMetaETag: remote.etag, bodyETag: owned ? bodyETag : nil,
                                    bodyVersion: envelope.bodyVersion)
            state.pendingPushes[id] = nil
            noteBodyFormat(of: envelope)
            if remote.payload == nil, envelope.bodyFormat != nil, state.bodyMissingSince[id] == nil {
                // A noteit-doc body is never rewritten in place; the note is left to body repair.
                state.bodyMissingSince[id] = now()
            }
            try saveState()
            return
        }

        // Same revision as our base under a new etag (the store was copied, e.g. from `inkwell/v1/`):
        // the remote never changed, so this is a plain push.
        if let base = state.bases[id], base.revision == envelope.revision {
            try await push(id, kind: kind, remoteETag: remote.etag, pass)
            return
        }

        // We wrote this remote revision and then kept editing before the pass finished, so local descends from it.
        // Without a base (an interrupted first push) the pending record, or a never-uploaded body, proves it.
        if envelope.deviceID == deviceID,
           state.bases[id] != nil || state.pendingPushes[id] == envelope.revision || remote.payload == nil {
            try await push(id, kind: kind, remoteETag: remote.etag, pass)
            return
        }

        if kind.usesLastWriterWins {
            let remoteWins = envelope.modifiedAt != localRecord.modifiedAt
                ? envelope.modifiedAt > localRecord.modifiedAt
                : envelope.deviceID > deviceID
            pass.report.conflicts += 1
            if remoteWins {
                guard let payload = remote.payload, await currentRevision(id) == localRecord.revision else {
                    pass.report.skipped += 1
                    return
                }
                do {
                    try await adopt(payload, envelope: envelope, etag: remote.etag)
                } catch let refusal as SyncRecordRefused {
                    try refuse(id, metaETag: remote.etag, refusal, pass)
                    return
                }
                pass.report.pulled += 1
            } else {
                try await push(id, kind: kind, remoteETag: remote.etag, pass)
            }
            return
        }

        guard let payload = remote.payload else {
            pass.report.skipped += 1
            return
        }
        do {
            try await local.importConflictCopy(payload, fromDevice: envelope.deviceName)
        } catch let refusal as SyncRecordRefused {
            try refuse(id, metaETag: remote.etag, refusal, pass)
            return
        }
        // Base becomes the remote version we just preserved, so the next pass sees a plain push
        // (ΔL, !ΔR) and never copies this remote revision again.
        state.bases[id] = .init(revision: envelope.revision, remoteMetaETag: remote.etag, bodyVersion: envelope.bodyVersion)
        try saveState()
        pass.report.conflicts += 1
        pass.importedCopies = true
        try await push(id, kind: kind, remoteETag: remote.etag, pass)
    }

    /// Legacy-body repair (spec §3.4.9): the meta is still the one this device wrote, and its RTFD body is missing
    /// or isn't the one it uploaded. Only where conditional writes are atomic, and only conditionally, so a request
    /// that lands late can never replace a body written meanwhile. Elsewhere nothing is written and the conversion
    /// sweep republishes the note once the store has noteit-doc.
    private func repairLegacyBody(_ id: UUID, base: SyncState.Base, _ pass: Pass) async throws {
        guard pass.atomicWrites else {
            // Counted, not an error: it mustn't hold back the upgrade whose conversion republishes the note.
            pass.report.skipped += 1
            return
        }
        let payload = try await local.export(id, kind: .note)
        guard payload.revision == base.revision, payload.bodyFormat == nil, let body = payload.body else { return }
        guard let etag = try await putLegacyBody(id, body: body, replacing: pass.index.bodies[id]) else { return }
        state.bases[id]?.bodyETag = etag
        try saveState()
        pass.report.pushed += 1
    }

    /// `PUT notes/<id>.body` with `If-None-Match: *` when none is listed, else `If-Match` on the listed (stale)
    /// body. Deviation from spec §3.4.9, which only re-creates a missing body: replacing exactly the object this pass
    /// listed keeps v1's crash recovery for a meta written without its body, and a 412 means another writer got
    /// there first, which is left alone.
    private func putLegacyBody(_ id: UUID, body: Data, replacing listedETag: String?) async throws -> String? {
        do {
            return try await backend.put(RemoteLayout.body(id), data: try seal(body, key: RemoteLayout.body(id)),
                                         ifMatch: listedETag, ifNoneMatch: listedETag == nil)
        } catch StorageError.preconditionFailed {
            return nil
        }
    }

    /// Imports sync-tool conflict copies of metas, deletes duplicates, and ages out anything it can't use.
    private func resolveSidecars(_ pass: Pass) async throws {
        let sidecars = pass.index.sidecars
        let listed = Set(sidecars.map(\.key))
        var changed = false
        for key in state.sidecarFirstSeen.keys where !listed.contains(key) {
            state.sidecarFirstSeen[key] = nil
            changed = true
        }
        for key in state.consumedSidecars.keys where !listed.contains(key) {
            state.consumedSidecars[key] = nil
            changed = true
        }
        var consumed: Set<String> = []
        for sidecar in sidecars {
            guard case .meta(let kind) = sidecar.role else { continue }
            // Without atomic deletes a used sidecar stays; it is imported once, by key and ETag.
            if state.consumedSidecars[sidecar.key] == sidecar.etag { continue }
            do {
                if let used = try await resolveSidecar(sidecar, kind: kind, bodies: sidecars.filter { $0.id == sidecar.id && $0.role == .body }, pass) {
                    consumed.insert(sidecar.key)
                    consumed.formUnion(used)
                }
            } catch let error as StorageError where Self.isFatal(error) {
                throw error
            } catch {
                pass.report.errors.append("\(sidecar.key): \(error)")
            }
        }
        let cutoff = now().addingTimeInterval(-Self.sidecarRetention)
        for sidecar in sidecars {
            if consumed.contains(sidecar.key) {
                if pass.atomicDeletes {
                    try await deleteIfUnchanged(sidecar.key, listedETag: sidecar.etag)
                } else {
                    state.consumedSidecars[sidecar.key] = sidecar.etag
                }
                state.sidecarFirstSeen[sidecar.key] = nil
                changed = true
            } else if state.consumedSidecars[sidecar.key] != nil {
                continue
            } else if let first = state.sidecarFirstSeen[sidecar.key] {
                guard first < cutoff, pass.atomicDeletes else { continue }
                try await deleteIfUnchanged(sidecar.key, listedETag: sidecar.etag)
                state.sidecarFirstSeen[sidecar.key] = nil
                changed = true
            } else {
                state.sidecarFirstSeen[sidecar.key] = now()
                changed = true
            }
        }
        if changed { try saveState() }
    }

    /// Returns the sidecar keys to delete, or nil to leave the sidecar for later (or for aging out).
    private func resolveSidecar(_ sidecar: RemoteIndex.Sidecar, kind: RecordKind, bodies: [RemoteIndex.Sidecar], _ pass: Pass) async throws -> [String]? {
        let id = sidecar.id
        let canonical = RemoteLayout.meta(kind, id)
        // Sync tools copy bytes, so the sidecar is still sealed for its canonical key.
        guard let envelope = try? Self.decode(RemoteEnvelope.self, from: try open(try await backend.get(sidecar.key).data, key: canonical)),
              envelope.id == id, envelope.kind == kind else { return nil }
        let localRevision = await local.revision(of: id, kind: kind)
        var remote: RemoteEnvelope?
        if pass.index.metas[id]?.kind == kind {
            remote = try await fetchEnvelope(id, kind: kind).envelope
        }
        if envelope.revision == remote?.revision { return [] }
        if envelope.revision == localRevision {
            // Our own copy is only safe once nothing remote is about to overwrite it; otherwise keep the
            // sidecar so it becomes a conflict copy after the pending pull lands.
            let baseETag = state.bases[id]?.remoteMetaETag
            return baseETag != nil && baseETag == pass.index.metas[id]?.etag ? [] : nil
        }

        guard (try? BodyFormat.validateEnvelope(envelope, features: session.current.features)) != nil else { return nil }
        var body: Data?
        var usedBodies: [String] = []
        if let version = envelope.bodyVersion, let expected = envelope.bodySHA256 {
            // A copied noteit-doc meta still names its versioned body, which no sync tool copies.
            guard let object = pass.index.docBodies[id]?[version],
                  let opened = try? open(try await backend.get(object.object.key).data, key: object.object.key),
                  Self.sha256Hex(opened) == expected else { return nil }
            body = opened
        } else if let expected = envelope.bodySHA256 {
            for candidate in [RemoteLayout.body(id)] + bodies.map(\.key) {
                guard let sealed = try? await backend.get(candidate).data,
                      let opened = try? open(sealed, key: RemoteLayout.body(id)),
                      Self.sha256Hex(opened) == expected else { continue }
                body = opened
                if candidate != RemoteLayout.body(id) { usedBodies = [candidate] }
                break
            }
            guard body != nil else { return nil }
        }
        let payload = RecordPayload(
            id: id, kind: kind, revision: envelope.revision, modifiedAt: envelope.modifiedAt,
            deviceID: envelope.deviceID, meta: envelope.meta, body: body, bodyFormat: envelope.bodyFormat
        )
        if kind.usesLastWriterWins {
            // Notebooks have no conflict copies; like resolveConflict, the newer edit wins.
            let localRecord = await local.records().first { $0.id == id && $0.kind == kind }
            guard let localRecord, localRecord.revision == localRevision else { return [] }
            if envelope.modifiedAt > localRecord.modifiedAt, envelope.modifiedAt > remote?.modifiedAt ?? .distantPast {
                try await local.apply(payload)
                pass.report.pulled += 1
                pass.report.conflicts += 1
            }
            return []
        }
        try await local.importConflictCopy(payload, fromDevice: envelope.deviceName)
        pass.report.conflicts += 1
        pass.importedCopies = true
        return usedBodies
    }

    /// `metaETag` is the remote meta this decision was based on (nil when there was none). The tombstone goes
    /// first and the meta is deleted only if it is still that version; otherwise someone edited it meanwhile, so
    /// the tombstone is withdrawn and the next pass pulls the edit (row 9).
    ///
    /// The tombstone write is conditional on the listing (a late-landing one loses, spec §3.4 item 10). Without atomic
    /// conditional deletes only the tombstone is written: the pair then reads as deleted while the meta keeps the
    /// ETag the tombstone names. Bodies are deleted only where both conditional writes and deletes are atomic.
    private func pushDeletion(_ id: UUID, _ deletion: LocalDeletion, metaETag: String?, _ pass: Pass) async throws {
        let tombstoneKey = RemoteLayout.tombstone(id)
        let tombstone = Tombstone(id: id, kind: deletion.kind, deletedAt: deletion.deletedAt, deviceID: deviceID, deletedMetaETag: metaETag)
        let listedTombstone = pass.index.tombstones[id]
        let tombstoneETag: String
        do {
            tombstoneETag = try await backend.put(tombstoneKey, data: try seal(try Self.encode(tombstone), key: tombstoneKey),
                                                  ifMatch: listedTombstone, ifNoneMatch: listedTombstone == nil)
        } catch StorageError.preconditionFailed {
            pass.report.skipped += 1
            return
        }
        pass.touchedTombstones.insert(id)
        var metaGone = metaETag == nil
        if let metaETag, pass.atomicDeletes {
            do {
                try await backend.delete(RemoteLayout.meta(deletion.kind, id), ifMatch: metaETag)
            } catch StorageError.notFound {
            } catch StorageError.preconditionFailed {
                try await deleteIfUnchanged(tombstoneKey, listedETag: tombstoneETag)
                pass.report.skipped += 1
                return
            }
            metaGone = true
        } else if let metaETag {
            metaGone = try await deleteMetaBestEffort(RemoteLayout.meta(deletion.kind, id), listedETag: metaETag)
        }
        // Deleted content doesn't stay in storage (security review): once the meta is gone, so is every body of the
        // note this pass listed. Versioned keys are immutable, so a plain delete removes exactly the listed version;
        // a version uploaded after the listing (a resurrection) isn't touched. If the meta moved on, nothing is
        // deleted: the tombstone loses to the edit.
        if deletion.kind == .note, metaGone {
            if let bodyETag = pass.index.bodies[id] {
                if pass.atomicDeletes {
                    try await deleteIfUnchanged(RemoteLayout.body(id), listedETag: bodyETag)
                } else {
                    try await deleteBestEffort(RemoteLayout.body(id))
                }
            }
            let pending = state.pendingBodyVersions[id]?.version
            for (version, body) in (pass.index.docBodies[id] ?? [:]).sorted(by: { $0.key.uuidString < $1.key.uuidString })
            where version != pending {
                if pass.atomicDeletes {
                    try await deleteIfUnchanged(body.object.key, listedETag: body.object.etag)
                } else {
                    try await deleteBestEffort(body.object.key)
                }
            }
        }
        state.tombstoneDates[id] = deletion.deletedAt
        state.bases[id] = nil
        state.pendingPushes[id] = nil
        try saveState()
        await local.clearDeletion(id)
        pass.report.deleted += 1
    }

    private func sweepTombstones(_ pass: Pass) async throws {
        let cutoff = now().addingTimeInterval(-Self.tombstoneRetention)
        var changed = false
        // Older builds filled knownTombstones without ever reading it; drop it so state files stop growing.
        if !state.knownTombstones.isEmpty {
            state.knownTombstones = []
            changed = true
        }
        // Retention deletes need atomic conditional deletes: a plain delete could remove a tombstone written meanwhile.
        for (id, etag) in pass.index.tombstones.sorted(by: { $0.key.uuidString < $1.key.uuidString })
        where pass.atomicDeletes && !pass.touchedTombstones.contains(id) {
            guard let deletedAt = state.tombstoneDates[id], deletedAt < cutoff else { continue }
            try await deleteIfUnchanged(RemoteLayout.tombstone(id), listedETag: etag)
            state.tombstoneDates[id] = nil
            changed = true
        }
        for id in state.tombstoneBindings.keys where pass.index.tombstones[id] != state.tombstoneBindings[id]?.tombstoneETag {
            state.tombstoneBindings[id] = nil
            changed = true
        }
        let live = Set(pass.index.tombstones.keys).union(pass.touchedTombstones)
        let stale = state.tombstoneDates.keys.filter { !live.contains($0) }
        if !stale.isEmpty {
            for id in stale { state.tombstoneDates[id] = nil }
            changed = true
        }
        if changed { try saveState() }
    }

    private func writeDeviceRecordIfDue() async throws {
        let date = now()
        if let last = state.lastDeviceWrite, date.timeIntervalSince(last) < Self.deviceWriteInterval, date >= last { return }
        let supported = session.current.supported.map(\.rawValue).sorted()
        let info = DeviceInfo(deviceID: deviceID, name: deviceName, lastSync: date, platform: platform.rawValue,
                              appVersion: appVersion, supportedFeatures: supported.isEmpty ? nil : supported)
        try await backend.put(RemoteLayout.device(deviceID), data: try seal(try Self.encode(info), key: RemoteLayout.device(deviceID)), ifMatch: nil, ifNoneMatch: false)
        state.lastDeviceWrite = date
        try saveState()
    }

    // MARK: - Remote helpers

    struct FetchedRemote {
        var envelope: RemoteEnvelope
        var etag: String
        /// nil when the body is missing or doesn't match `bodySHA256` (an upload in progress).
        var payload: RecordPayload?
        /// The etag of the matching body, when there is one.
        var bodyETag: String? = nil
    }

    func fetchEnvelope(_ id: UUID, kind: RecordKind) async throws -> (envelope: RemoteEnvelope, etag: String) {
        let (data, etag) = try await backend.get(RemoteLayout.meta(kind, id))
        let envelope = try Self.decode(RemoteEnvelope.self, from: try open(data, key: RemoteLayout.meta(kind, id)))
        guard envelope.id == id, envelope.kind == kind else {
            throw StorageError.invalidResponse("Envelope at \(RemoteLayout.meta(kind, id)) describes another record")
        }
        return (envelope, etag)
    }

    /// A noteit-doc envelope's body is the listed `bodies/<id>.<bodyVersion>.<TAG>.body`; a version missing from the
    /// listing, a 404 or a hash mismatch all leave `payload` nil, as for a legacy body mid-upload. An envelope that
    /// breaks the pairing rule is a per-record `invalidPayload` and nothing is applied.
    func fetchRemote(_ id: UUID, kind: RecordKind, _ pass: Pass,
                     fetched: (envelope: RemoteEnvelope, etag: String)? = nil) async throws -> FetchedRemote {
        let (envelope, etag): (RemoteEnvelope, String)
        if let fetched { (envelope, etag) = fetched } else { (envelope, etag) = try await fetchEnvelope(id, kind: kind) }
        try BodyFormat.validateEnvelope(envelope, features: session.current.features)
        var body: Data?
        var bodyETag: String?
        if let expected = envelope.bodySHA256 {
            let key: String
            if let version = envelope.bodyVersion {
                guard let object = pass.index.docBodies[id]?[version] else {
                    return FetchedRemote(envelope: envelope, etag: etag, payload: nil)
                }
                key = object.object.key
            } else {
                key = RemoteLayout.body(id)
            }
            let sealed: Data
            do {
                (sealed, bodyETag) = try await backend.get(key)
            } catch StorageError.notFound {
                return FetchedRemote(envelope: envelope, etag: etag, payload: nil)
            }
            let opened = try open(sealed, key: key)
            guard Self.sha256Hex(opened) == expected else {
                return FetchedRemote(envelope: envelope, etag: etag, payload: nil)
            }
            body = opened
        }
        let payload = RecordPayload(
            id: id, kind: kind, revision: envelope.revision, modifiedAt: envelope.modifiedAt,
            deviceID: envelope.deviceID, meta: envelope.meta, body: body, bodyFormat: envelope.bodyFormat
        )
        return FetchedRemote(envelope: envelope, etag: etag, payload: payload, bodyETag: bodyETag)
    }

    private func fetchTombstone(_ id: UUID) async throws -> Tombstone {
        let data = try await backend.get(RemoteLayout.tombstone(id)).data
        let tombstone = try Self.decode(Tombstone.self, from: try open(data, key: RemoteLayout.tombstone(id)))
        guard tombstone.id == id else {
            throw StorageError.invalidResponse("Tombstone at \(RemoteLayout.tombstone(id)) describes another record")
        }
        if state.tombstoneDates[id] != tombstone.deletedAt {
            state.tombstoneDates[id] = tombstone.deletedAt
            try saveState()
        }
        return tombstone
    }

    func forgetTombstoneDate(_ id: UUID, _ pass: Pass) {
        pass.touchedTombstones.insert(id)
        state.tombstoneDates[id] = nil
    }

    /// Deletes `key` only while it still has the ETag this pass listed (spec §3.4 item 10). Gone or changed: left for
    /// the next pass. Callers check `atomicDeletes` first; without it nothing whose safety depends on the condition
    /// is deleted.
    /// A user delete's meta on a store without atomic conditional deletes, as the v1 engine did it there: the
    /// backend's own check (a folder's lock) or a re-read of the ETag, then the delete. Deviation from spec §3.4.9,
    /// which keeps the meta; asked for by the security review so deleted notes don't stay in storage. A write that
    /// lands between the check and the delete is still protected: the tombstone names the meta it deleted, so the
    /// writer's next pass resurrects its edit (`SyncPlanner` row 11 with a base). Returns whether the meta is gone.
    private func deleteMetaBestEffort(_ key: String, listedETag: String) async throws -> Bool {
        do {
            try await backend.delete(key, ifMatch: listedETag)
            return true
        } catch StorageError.notFound {
            return true
        } catch StorageError.preconditionFailed {
            return false
        } catch StorageError.conditionalDeleteUnsupported {
            let current: String
            do {
                current = try await backend.get(key).etag
            } catch StorageError.notFound {
                return true
            }
            guard Self.unquoted(current) == Self.unquoted(listedETag) else { return false }
            try await deleteBestEffort(key)
            return true
        }
    }

    private func deleteBestEffort(_ key: String) async throws {
        do {
            try await backend.delete(key)
        } catch StorageError.notFound {}
    }

    func deleteIfUnchanged(_ key: String, listedETag: String) async throws {
        do {
            try await backend.delete(key, ifMatch: listedETag)
        } catch StorageError.notFound {
        } catch StorageError.preconditionFailed {}
    }

    func currentRevision(_ id: UUID) async -> UUID? {
        for kind in [RecordKind.note, .notebook, .smartFolder] {
            if let revision = await local.revision(of: id, kind: kind) { return revision }
        }
        return nil
    }

    func seal(_ plain: Data, key: String) throws -> Data {
        try session.current.cipher.seal(plain, context: Self.context(key))
    }

    func open(_ sealed: Data, key: String) throws -> Data {
        try session.current.cipher.open(sealed, context: Self.context(key))
    }

    /// The cipher context for an object: its key relative to the remote root.
    static func context(_ key: String) -> String {
        key.hasPrefix(RemoteLayout.root) ? String(key.dropFirst(RemoteLayout.root.count)) : key
    }

    func saveState() throws {
        try state.save(to: stateURL)
    }

    // MARK: - Coding

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// One `list` of the remote root, indexed by record id.
struct RemoteIndex {
    /// A copy that a file-sync tool (iCloud Drive, Dropbox, Syncthing) left next to a record, e.g. `<id> 2.meta`.
    struct Sidecar: Equatable {
        enum Role: Equatable { case meta(RecordKind), body, other }
        var key: String
        var id: UUID
        var role: Role
        var etag: String = ""
    }

    /// A listed versioned body (web-app spec §3.4.9).
    struct DocBodyObject: Equatable {
        var tag: String
        var locked: Bool
        var object: RemoteObject
    }

    var metas: [UUID: (kind: RecordKind, etag: String)] = [:]
    var bodies: [UUID: String] = [:]
    var tombstones: [UUID: String] = [:]
    var sidecars: [Sidecar] = []
    /// note → version → listed body. `.locked` names are parsed too and are never stray.
    var docBodies: [UUID: [UUID: DocBodyObject]] = [:]
    /// Unparsable names under `bodies/`.
    var strayBodies: [RemoteObject] = []
    var manifestETag: String?
    var hasManifest: Bool { manifestETag != nil }

    init(_ objects: [RemoteObject]) {
        for object in objects {
            guard object.key.hasPrefix(RemoteLayout.root) else { continue }
            let path = String(object.key.dropFirst(RemoteLayout.root.count))
            if path == "manifest.json" {
                manifestETag = object.etag
                continue
            }
            let parts = path.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let name = parts[1]
            func id(_ suffix: String) -> UUID? {
                name.hasSuffix(suffix) ? UUID(uuidString: String(name.dropLast(suffix.count))) : nil
            }
            func sidecar(_ role: Sidecar.Role) {
                guard name.count > 36, let id = UUID(uuidString: String(name.prefix(36))) else { return }
                sidecars.append(Sidecar(key: object.key, id: id, role: role, etag: object.etag))
            }
            switch parts[0] {
            case "bodies":
                if let parsed = RemoteLayout.parseDocBody(object.key) {
                    docBodies[parsed.id, default: [:]][parsed.version] = DocBodyObject(tag: parsed.tag, locked: parsed.locked, object: object)
                } else {
                    strayBodies.append(object)
                }
            case "notebooks":
                if let id = id(".json") { metas[id] = (.notebook, object.etag) }
                else { sidecar(name.hasSuffix(".json") ? .meta(.notebook) : .other) }
            case "notes":
                if let id = id(".meta") { metas[id] = (.note, object.etag) }
                else if let id = id(".body") { bodies[id] = object.etag }
                else { sidecar(name.hasSuffix(".meta") ? .meta(.note) : name.contains(".body") ? .body : .other) }
            case "smart-folders":
                if let id = id(".json") { metas[id] = (.smartFolder, object.etag) }
                else { sidecar(name.hasSuffix(".json") ? .meta(.smartFolder) : .other) }
            case "tombstones":
                if let id = id(".json") { tombstones[id] = object.etag }
            case "keys":
                // Key files (sync-security, sharing) are not records.
                break
            default:
                break
            }
        }
    }
}
