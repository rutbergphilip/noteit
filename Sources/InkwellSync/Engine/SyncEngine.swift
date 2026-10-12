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
}

public struct LocalDeletion: Sendable, Equatable {
    public var kind: RecordKind
    public var deletedAt: Date

    public init(kind: RecordKind, deletedAt: Date) {
        self.kind = kind
        self.deletedAt = deletedAt
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
}

public enum SyncError: Error, Equatable, Sendable {
    case wrongPassphrase, passphraseRequired, unsupportedFormat(Int), encryptionMismatch
}

/// Runs sync passes against one remote store. Passes are serialized; each one resumes from the
/// persisted `SyncState`, so an interrupted pass is simply completed by the next.
///
/// Write ordering (deliberately different from the plan; see the T5 report):
/// - push: conditional meta put first, body second. The meta's ETag is the per-record lock, so a
///   writer that loses the race never overwrites the winner's body.
/// - pushDeletion: delete meta and body first, tombstone last.
/// - resurrectPush: delete the tombstone first, then push.
/// With this ordering a crash never leaves both a meta and a tombstone behind; only a race does.
public actor SyncEngine {
    static let keyCheckPlaintext = Data("inkwell-key-check".utf8)
    static let defaultIterations = 210_000
    static let deviceWriteInterval: TimeInterval = 10 * 60
    static let tombstoneRetention: TimeInterval = 30 * 24 * 60 * 60

    private let backend: StorageBackend
    private let cipher: SyncCipher
    private let local: SyncLocalStore
    private let stateURL: URL
    private let deviceID: String
    private let deviceName: String
    private let now: @Sendable () -> Date

    private var state = SyncState()
    private var tail: Task<Void, Never>?

    public init(backend: StorageBackend, cipher: SyncCipher, local: SyncLocalStore, stateURL: URL, deviceID: String, deviceName: String) {
        self.init(backend: backend, cipher: cipher, local: local, stateURL: stateURL, deviceID: deviceID, deviceName: deviceName, now: { Date() })
    }

    init(backend: StorageBackend, cipher: SyncCipher, local: SyncLocalStore, stateURL: URL, deviceID: String, deviceName: String, now: @escaping @Sendable () -> Date) {
        self.backend = backend
        self.cipher = cipher
        self.local = local
        self.stateURL = stateURL
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.now = now
    }

    /// Throws only fatal errors (unauthorized, listing failures, missing manifest).
    public func sync() async throws -> SyncReport {
        let previous = tail
        let pass = Task { () async throws -> SyncReport in
            await previous?.value
            return try await self.runPass()
        }
        tail = Task { _ = try? await pass.value }
        return try await pass.value
    }

    public func devices() async throws -> [DeviceInfo] {
        var result: [DeviceInfo] = []
        for object in try await backend.list(prefix: RemoteLayout.root + "devices/") {
            let data = try await backend.get(object.key).data
            result.append(try Self.decode(DeviceInfo.self, from: try cipher.open(data)))
        }
        return result.sorted { ($0.name, $0.deviceID) < ($1.name, $1.deviceID) }
    }

    public static func connect(backend: StorageBackend, passphrase: String?, encryptNew: Bool) async throws -> (Manifest, SyncCipher) {
        try await connect(backend: backend, passphrase: passphrase, encryptNew: encryptNew, makeCipher: defaultCipherFactory)
    }

    static func connect(backend: StorageBackend, passphrase: String?, encryptNew: Bool, makeCipher: CipherFactory) async throws -> (Manifest, SyncCipher) {
        if let existing = try await readManifest(backend) {
            return (existing, try openExisting(existing, passphrase: passphrase, encryptNew: encryptNew, makeCipher: makeCipher))
        }
        let manifest: Manifest
        let cipher: SyncCipher
        if encryptNew {
            guard let passphrase, !passphrase.isEmpty else { throw SyncError.passphraseRequired }
            let salt = makeSalt()
            cipher = makeCipher(passphrase, salt, defaultIterations)
            let check = try cipher.seal(keyCheckPlaintext)
            manifest = Manifest(encryption: .init(salt: salt, iterations: defaultIterations, keyCheck: check))
        } else {
            cipher = plaintextCipher()
            manifest = Manifest()
        }
        do {
            try await backend.put(RemoteLayout.manifest(), data: try encode(manifest), ifMatch: nil, ifNoneMatch: true)
            return (manifest, cipher)
        } catch StorageError.preconditionFailed {
            // Another device created the store first; join theirs.
            guard let existing = try await readManifest(backend) else { throw StorageError.notFound(RemoteLayout.manifest()) }
            return (existing, try openExisting(existing, passphrase: passphrase, encryptNew: encryptNew, makeCipher: makeCipher))
        }
    }

    private static func readManifest(_ backend: StorageBackend) async throws -> Manifest? {
        let data: Data
        do {
            data = try await backend.get(RemoteLayout.manifest()).data
        } catch StorageError.notFound {
            return nil
        }
        guard let manifest = try? decode(Manifest.self, from: data) else {
            throw StorageError.invalidResponse("Unreadable manifest")
        }
        return manifest
    }

    private static func openExisting(_ manifest: Manifest, passphrase: String?, encryptNew: Bool, makeCipher: CipherFactory) throws -> SyncCipher {
        guard manifest.formatVersion <= 1 else { throw SyncError.unsupportedFormat(manifest.formatVersion) }
        guard let encryption = manifest.encryption else {
            // Never silently downgrade a user who asked for encryption to a plaintext store.
            if encryptNew { throw SyncError.encryptionMismatch }
            return plaintextCipher()
        }
        guard let passphrase, !passphrase.isEmpty else { throw SyncError.passphraseRequired }
        let cipher = makeCipher(passphrase, encryption.salt, encryption.iterations)
        guard (try? cipher.open(encryption.keyCheck)) == keyCheckPlaintext else { throw SyncError.wrongPassphrase }
        return cipher
    }

    // MARK: - Pass

    private final class Pass {
        var report = SyncReport()
        let index: RemoteIndex
        var records: [UUID: LocalRecord]
        let deletions: [UUID: LocalDeletion]
        var seen: Set<UUID> = []
        var importedCopies = false
        /// Tombstones written or deleted during this pass; the listing is stale for them.
        var touchedTombstones: Set<UUID> = []

        init(index: RemoteIndex, records: [UUID: LocalRecord], deletions: [UUID: LocalDeletion]) {
            self.index = index
            self.records = records
            self.deletions = deletions
        }
    }

    private func runPass() async throws -> SyncReport {
        let index = RemoteIndex(try await backend.list(prefix: RemoteLayout.root))
        // A missing manifest means the store was wiped; syncing against it would delete everything.
        guard index.hasManifest else { throw StorageError.notFound(RemoteLayout.manifest()) }

        state = SyncState.load(from: stateURL)
        let records = await local.records()
        let pass = Pass(
            index: index,
            records: Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            deletions: await local.deletions()
        )

        var ids = Set(pass.records.keys)
        ids.formUnion(pass.deletions.keys)
        ids.formUnion(index.metas.keys)
        ids.formUnion(index.tombstones.keys)
        ids.formUnion(state.bases.keys)
        for id in ordered(ids, pass) {
            try await processSafely(id, pass)
        }

        // Push conflict copies in the same pass so devices converge one round sooner.
        if pass.importedCopies {
            let fresh = await local.records().filter { !pass.seen.contains($0.id) }
            for record in fresh { pass.records[record.id] = record }
            for id in ordered(Set(fresh.map(\.id)), pass) {
                try await processSafely(id, pass)
            }
        }

        try await guarded(pass) { try await self.sweepTombstones(pass) }
        try await guarded(pass) { try await self.writeDeviceRecordIfDue() }
        return pass.report
    }

    private func ordered(_ ids: Set<UUID>, _ pass: Pass) -> [UUID] {
        func rank(_ id: UUID) -> Int {
            (pass.records[id]?.kind ?? pass.deletions[id]?.kind ?? pass.index.metas[id]?.kind) == .notebook ? 0 : 1
        }
        return ids.sorted { (rank($0), $0.uuidString) < (rank($1), $1.uuidString) }
    }

    private func guarded(_ pass: Pass, _ work: () async throws -> Void) async throws {
        do {
            try await work()
        } catch let error as StorageError {
            if case .unauthorized = error { throw error }
            pass.report.errors.append(String(describing: error))
        } catch {
            pass.report.errors.append(String(describing: error))
        }
    }

    private func processSafely(_ id: UUID, _ pass: Pass) async throws {
        pass.seen.insert(id)
        do {
            try await process(id, pass)
        } catch let error as StorageError {
            if case .unauthorized = error { throw error }
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
        if pass.index.tombstones[id] != nil {
            if localRecord != nil || remoteMeta != nil {
                tombstone = try await fetchTombstone(id)
            } else {
                // Rows 14/15 don't depend on the tombstone's contents, so skip the get.
                tombstone = Tombstone(id: id, kind: kind, deletedAt: .distantPast, deviceID: "")
            }
        }

        if let remoteMeta, let current = tombstone {
            // A meta and a tombstone together only arise from a race; the newer one wins and the loser is removed.
            let envelope = try await fetchEnvelope(id, kind: remoteMeta.kind).envelope
            if envelope.modifiedAt > current.deletedAt {
                try await deleteIfPresent(RemoteLayout.tombstone(id))
                forgetTombstoneDate(id, pass)
                tombstone = nil
            } else {
                try await deleteRemoteRecord(id, kind: remoteMeta.kind)
                metaETag = nil
            }
        }

        let base = state.bases[id]
        let action = SyncPlanner.decide(
            local: localRecord,
            localDeletedAt: deletion?.deletedAt,
            remote: RemoteInfo(metaETag: metaETag, tombstone: tombstone),
            base: base
        )

        switch action {
        case .none:
            break
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
            try await pushDeletion(id, deletion, pass)
        case .applyRemoteDeletion:
            guard let localRecord else { return }
            guard await currentRevision(id) == localRecord.revision else {
                pass.report.skipped += 1
                return
            }
            try await local.applyDeletion(id, kind: localRecord.kind)
            state.bases[id] = nil
            try saveState()
            pass.report.deleted += 1
        case .resurrectPush:
            guard let localRecord else { return }
            try await deleteIfPresent(RemoteLayout.tombstone(id))
            forgetTombstoneDate(id, pass)
            try await push(id, kind: localRecord.kind, remoteETag: nil, pass)
        case .forgetBase:
            if base != nil {
                state.bases[id] = nil
                try saveState()
            }
            if deletion != nil { await local.clearDeletion(id) }
        }
    }

    // MARK: - Actions

    /// Conditional on `remoteETag` (or on absence when nil). Returns false when another writer got there first.
    @discardableResult
    private func push(_ id: UUID, kind: RecordKind, remoteETag: String?, _ pass: Pass) async throws -> Bool {
        let payload = try await local.export(id, kind: kind)
        let envelope = RemoteEnvelope(
            id: id, kind: kind, revision: payload.revision, modifiedAt: payload.modifiedAt,
            deviceID: deviceID, deviceName: deviceName, meta: payload.meta,
            bodySHA256: payload.body.map(Self.sha256Hex)
        )
        let newETag: String
        do {
            newETag = try await backend.put(
                RemoteLayout.meta(kind, id), data: try cipher.seal(try Self.encode(envelope)),
                ifMatch: remoteETag, ifNoneMatch: remoteETag == nil
            )
        } catch StorageError.preconditionFailed {
            pass.report.skipped += 1
            return false
        }
        if let body = payload.body {
            try await backend.put(RemoteLayout.body(id), data: try cipher.seal(body), ifMatch: nil, ifNoneMatch: false)
        }
        state.bases[id] = .init(revision: payload.revision, remoteMetaETag: newETag)
        try saveState()
        pass.report.pushed += 1
        return true
    }

    /// Returns false (skipped) when the remote is mid-upload or the local record changed during the pass.
    private func pull(_ id: UUID, kind: RecordKind, expectedLocalRevision: UUID?, _ pass: Pass) async throws -> Bool {
        let remote = try await fetchRemote(id, kind: kind)
        guard let payload = remote.payload, await currentRevision(id) == expectedLocalRevision else {
            pass.report.skipped += 1
            return false
        }
        try await adopt(payload, etag: remote.etag)
        pass.report.pulled += 1
        return true
    }

    private func adopt(_ payload: RecordPayload, etag: String) async throws {
        try await local.apply(payload)
        state.bases[payload.id] = .init(revision: payload.revision, remoteMetaETag: etag)
        try saveState()
    }

    private func resolveConflict(_ id: UUID, local localRecord: LocalRecord, _ pass: Pass) async throws {
        let kind = localRecord.kind
        let remote = try await fetchRemote(id, kind: kind)
        let envelope = remote.envelope

        if envelope.revision == localRecord.revision {
            // Our own write from an interrupted pass: finish it instead of copying ourselves.
            if remote.payload == nil {
                let payload = try await local.export(id, kind: kind)
                guard payload.revision == envelope.revision else {
                    try await push(id, kind: kind, remoteETag: remote.etag, pass)
                    return
                }
                if let body = payload.body {
                    try await backend.put(RemoteLayout.body(id), data: try cipher.seal(body), ifMatch: nil, ifNoneMatch: false)
                }
            }
            state.bases[id] = .init(revision: envelope.revision, remoteMetaETag: remote.etag)
            try saveState()
            return
        }

        if state.bases[id] != nil, envelope.deviceID == deviceID {
            // We wrote this remote revision and then kept editing before the pass finished, so local descends from it.
            try await push(id, kind: kind, remoteETag: remote.etag, pass)
            return
        }

        if kind == .notebook {
            let remoteWins = envelope.modifiedAt != localRecord.modifiedAt
                ? envelope.modifiedAt > localRecord.modifiedAt
                : envelope.deviceID > deviceID
            pass.report.conflicts += 1
            if remoteWins {
                guard let payload = remote.payload, await currentRevision(id) == localRecord.revision else {
                    pass.report.skipped += 1
                    return
                }
                try await adopt(payload, etag: remote.etag)
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
        try await local.importConflictCopy(payload, fromDevice: envelope.deviceName)
        // Base becomes the remote version we just preserved, so the next pass sees a plain push
        // (ΔL, !ΔR) and never copies this remote revision again.
        state.bases[id] = .init(revision: envelope.revision, remoteMetaETag: remote.etag)
        try saveState()
        pass.report.conflicts += 1
        pass.importedCopies = true
        try await push(id, kind: kind, remoteETag: remote.etag, pass)
    }

    private func pushDeletion(_ id: UUID, _ deletion: LocalDeletion, _ pass: Pass) async throws {
        try await deleteRemoteRecord(id, kind: deletion.kind)
        let tombstone = Tombstone(id: id, kind: deletion.kind, deletedAt: deletion.deletedAt, deviceID: deviceID)
        try await backend.put(RemoteLayout.tombstone(id), data: try cipher.seal(try Self.encode(tombstone)), ifMatch: nil, ifNoneMatch: false)
        pass.touchedTombstones.insert(id)
        state.tombstoneDates[id] = deletion.deletedAt
        state.bases[id] = nil
        try saveState()
        await local.clearDeletion(id)
        pass.report.deleted += 1
    }

    private func sweepTombstones(_ pass: Pass) async throws {
        let cutoff = now().addingTimeInterval(-Self.tombstoneRetention)
        var changed = false
        for id in pass.index.tombstones.keys.sorted(by: { $0.uuidString < $1.uuidString }) where !pass.touchedTombstones.contains(id) {
            state.knownTombstones.remove(id)
            guard let deletedAt = state.tombstoneDates[id], deletedAt < cutoff else { continue }
            try await deleteIfPresent(RemoteLayout.tombstone(id))
            state.tombstoneDates[id] = nil
            state.knownTombstones.insert(id)
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
        let info = DeviceInfo(deviceID: deviceID, name: deviceName, lastSync: date)
        try await backend.put(RemoteLayout.device(deviceID), data: try cipher.seal(try Self.encode(info)), ifMatch: nil, ifNoneMatch: false)
        state.lastDeviceWrite = date
        try saveState()
    }

    // MARK: - Remote helpers

    private struct FetchedRemote {
        var envelope: RemoteEnvelope
        var etag: String
        /// nil when the body is missing or doesn't match `bodySHA256` (an upload in progress).
        var payload: RecordPayload?
    }

    private func fetchEnvelope(_ id: UUID, kind: RecordKind) async throws -> (envelope: RemoteEnvelope, etag: String) {
        let (data, etag) = try await backend.get(RemoteLayout.meta(kind, id))
        let envelope = try Self.decode(RemoteEnvelope.self, from: try cipher.open(data))
        guard envelope.id == id, envelope.kind == kind else {
            throw StorageError.invalidResponse("Envelope at \(RemoteLayout.meta(kind, id)) describes another record")
        }
        return (envelope, etag)
    }

    private func fetchRemote(_ id: UUID, kind: RecordKind) async throws -> FetchedRemote {
        let (envelope, etag) = try await fetchEnvelope(id, kind: kind)
        var body: Data?
        if let expected = envelope.bodySHA256 {
            let sealed: Data
            do {
                sealed = try await backend.get(RemoteLayout.body(id)).data
            } catch StorageError.notFound {
                return FetchedRemote(envelope: envelope, etag: etag, payload: nil)
            }
            let opened = try cipher.open(sealed)
            guard Self.sha256Hex(opened) == expected else {
                return FetchedRemote(envelope: envelope, etag: etag, payload: nil)
            }
            body = opened
        }
        let payload = RecordPayload(
            id: id, kind: kind, revision: envelope.revision, modifiedAt: envelope.modifiedAt,
            deviceID: envelope.deviceID, meta: envelope.meta, body: body
        )
        return FetchedRemote(envelope: envelope, etag: etag, payload: payload)
    }

    private func fetchTombstone(_ id: UUID) async throws -> Tombstone {
        let data = try await backend.get(RemoteLayout.tombstone(id)).data
        let tombstone = try Self.decode(Tombstone.self, from: try cipher.open(data))
        if state.tombstoneDates[id] != tombstone.deletedAt {
            state.tombstoneDates[id] = tombstone.deletedAt
            try saveState()
        }
        return tombstone
    }

    private func forgetTombstoneDate(_ id: UUID, _ pass: Pass) {
        pass.touchedTombstones.insert(id)
        state.tombstoneDates[id] = nil
    }

    private func deleteRemoteRecord(_ id: UUID, kind: RecordKind) async throws {
        try await deleteIfPresent(RemoteLayout.meta(kind, id))
        if kind == .note { try await deleteIfPresent(RemoteLayout.body(id)) }
    }

    private func deleteIfPresent(_ key: String) async throws {
        do {
            try await backend.delete(key)
        } catch StorageError.notFound {}
    }

    private func currentRevision(_ id: UUID) async -> UUID? {
        await local.records().first { $0.id == id }?.revision
    }

    private func saveState() throws {
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
    var metas: [UUID: (kind: RecordKind, etag: String)] = [:]
    var bodies: [UUID: String] = [:]
    var tombstones: [UUID: String] = [:]
    var hasManifest = false

    init(_ objects: [RemoteObject]) {
        for object in objects {
            guard object.key.hasPrefix(RemoteLayout.root) else { continue }
            let path = String(object.key.dropFirst(RemoteLayout.root.count))
            if path == "manifest.json" {
                hasManifest = true
                continue
            }
            let parts = path.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let name = parts[1]
            func id(_ suffix: String) -> UUID? {
                name.hasSuffix(suffix) ? UUID(uuidString: String(name.dropLast(suffix.count))) : nil
            }
            switch parts[0] {
            case "notebooks":
                if let id = id(".json") { metas[id] = (.notebook, object.etag) }
            case "notes":
                if let id = id(".meta") { metas[id] = (.note, object.etag) }
                else if let id = id(".body") { bodies[id] = object.etag }
            case "tombstones":
                if let id = id(".json") { tombstones[id] = object.etag }
            default:
                break
            }
        }
    }
}
