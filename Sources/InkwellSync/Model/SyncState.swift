import Foundation

/// Per-device sync base state: what each record looked like at the last successful sync.
public struct SyncState: Codable, Sendable, Equatable {
    public struct Base: Codable, Sendable, Equatable {
        public var revision: UUID
        public var remoteMetaETag: String

        public init(revision: UUID, remoteMetaETag: String) {
            self.revision = revision
            self.remoteMetaETag = remoteMetaETag
        }
    }

    public var bases: [UUID: Base] = [:]
    public var knownTombstones: Set<UUID> = []
    public var lastDeviceWrite: Date?

    public init(bases: [UUID: Base] = [:], knownTombstones: Set<UUID> = [], lastDeviceWrite: Date? = nil) {
        self.bases = bases
        self.knownTombstones = knownTombstones
        self.lastDeviceWrite = lastDeviceWrite
    }

    /// Missing or corrupt files yield an empty state.
    public static func load(from url: URL) -> SyncState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(SyncState.self, from: data) else {
            return SyncState()
        }
        return state
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: .atomic)
    }
}
