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

// T1 stub; the sync pass and `connect` are implemented in T5.
public actor SyncEngine {
    private let backend: StorageBackend
    private let cipher: SyncCipher
    private let local: SyncLocalStore
    private let stateURL: URL
    private let deviceID: String
    private let deviceName: String

    public init(backend: StorageBackend, cipher: SyncCipher, local: SyncLocalStore, stateURL: URL, deviceID: String, deviceName: String) {
        self.backend = backend
        self.cipher = cipher
        self.local = local
        self.stateURL = stateURL
        self.deviceID = deviceID
        self.deviceName = deviceName
    }

    /// Throws only fatal errors (unauthorized, manifest problems).
    public func sync() async throws -> SyncReport {
        fatalError("T5")
    }

    public func devices() async throws -> [DeviceInfo] {
        fatalError("T5")
    }

    public static func connect(backend: StorageBackend, passphrase: String?, encryptNew: Bool) async throws -> (Manifest, SyncCipher) {
        fatalError("T5")
    }
}
