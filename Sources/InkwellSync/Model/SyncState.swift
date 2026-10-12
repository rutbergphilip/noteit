import Foundation

/// Per-device sync base state: what each record looked like at the last successful sync.
public struct SyncState: Codable, Sendable, Equatable {
    public struct Base: Codable, Sendable, Equatable {
        public var revision: UUID
        public var remoteMetaETag: String
        /// Set only when this device pushed the record: the remote meta etag its push overwrote (nil for a create).
        public var replacedMetaETag: String?
        /// Set only when this device pushed the record: the etag of the body it uploaded.
        public var bodyETag: String?

        public init(revision: UUID, remoteMetaETag: String, replacedMetaETag: String? = nil, bodyETag: String? = nil) {
            self.revision = revision
            self.remoteMetaETag = remoteMetaETag
            self.replacedMetaETag = replacedMetaETag
            self.bodyETag = bodyETag
        }
    }

    public var bases: [UUID: Base] = [:]
    public var knownTombstones: Set<UUID> = []
    public var lastDeviceWrite: Date?
    /// `deletedAt` of remote tombstones this device has read or written, so the 30-day sweep needs no extra gets.
    public var tombstoneDates: [UUID: Date] = [:]
    /// Revisions whose meta this device is about to write; kept until a base records the outcome.
    public var pendingPushes: [UUID: UUID] = [:]
    /// Sync-tool conflict files this device couldn't use, by key, with when it first listed them.
    public var sidecarFirstSeen: [String: Date] = [:]

    public init(
        bases: [UUID: Base] = [:], knownTombstones: Set<UUID> = [], lastDeviceWrite: Date? = nil,
        tombstoneDates: [UUID: Date] = [:], pendingPushes: [UUID: UUID] = [:], sidecarFirstSeen: [String: Date] = [:]
    ) {
        self.bases = bases
        self.knownTombstones = knownTombstones
        self.lastDeviceWrite = lastDeviceWrite
        self.tombstoneDates = tombstoneDates
        self.pendingPushes = pendingPushes
        self.sidecarFirstSeen = sidecarFirstSeen
    }

    private enum CodingKeys: String, CodingKey {
        case bases, knownTombstones, lastDeviceWrite, tombstoneDates, pendingPushes, sidecarFirstSeen
    }

    // Every key is optional so state files written by older builds keep their bases.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bases = try c.decodeIfPresent([UUID: Base].self, forKey: .bases) ?? [:]
        knownTombstones = try c.decodeIfPresent(Set<UUID>.self, forKey: .knownTombstones) ?? []
        lastDeviceWrite = try c.decodeIfPresent(Date.self, forKey: .lastDeviceWrite)
        tombstoneDates = try c.decodeIfPresent([UUID: Date].self, forKey: .tombstoneDates) ?? [:]
        pendingPushes = try c.decodeIfPresent([UUID: UUID].self, forKey: .pendingPushes) ?? [:]
        sidecarFirstSeen = try c.decodeIfPresent([String: Date].self, forKey: .sidecarFirstSeen) ?? [:]
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
