import Foundation

/// One uncommitted or in-doubt doc-body version of a note. Declared and persisted by foundations Task 3.1; web-app
/// Task 0.4 writes it, sync-security reads its count. The sealed body bytes live in `PendingBodies/<ID>.<VERSION>`.
public struct PendingBody: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable { case uploading, committing, inDoubt }
    public var version: UUID
    public var tag: String
    public var phase: Phase
    public var envelope: RemoteEnvelope

    public init(version: UUID, tag: String, phase: Phase, envelope: RemoteEnvelope) {
        self.version = version
        self.tag = tag
        self.phase = phase
        self.envelope = envelope
    }
}

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
    /// The store's key ID, from the session (nil for unencrypted stores).
    public var keyID: String?
    /// The one uncommitted or in-doubt doc-body version per note; a separate map keeps old state files decodable.
    public var pendingBodyVersions: [UUID: PendingBody] = [:]
    /// Remote versions the local store refused, by the meta etag it refused; not fetched again until the etag changes.
    public var refusedRemotes: [UUID: RefusedRemote] = [:]

    public struct RefusedRemote: Codable, Sendable, Equatable {
        public var metaETag: String
        public var reason: String

        public init(metaETag: String, reason: String) {
            self.metaETag = metaETag
            self.reason = reason
        }
    }

    public init(
        bases: [UUID: Base] = [:], knownTombstones: Set<UUID> = [], lastDeviceWrite: Date? = nil,
        tombstoneDates: [UUID: Date] = [:], pendingPushes: [UUID: UUID] = [:], sidecarFirstSeen: [String: Date] = [:],
        keyID: String? = nil, pendingBodyVersions: [UUID: PendingBody] = [:], refusedRemotes: [UUID: RefusedRemote] = [:]
    ) {
        self.bases = bases
        self.knownTombstones = knownTombstones
        self.lastDeviceWrite = lastDeviceWrite
        self.tombstoneDates = tombstoneDates
        self.pendingPushes = pendingPushes
        self.sidecarFirstSeen = sidecarFirstSeen
        self.keyID = keyID
        self.pendingBodyVersions = pendingBodyVersions
        self.refusedRemotes = refusedRemotes
    }

    private enum CodingKeys: String, CodingKey {
        case bases, knownTombstones, lastDeviceWrite, tombstoneDates, pendingPushes, sidecarFirstSeen, keyID, pendingBodyVersions, refusedRemotes
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
        keyID = try c.decodeIfPresent(String.self, forKey: .keyID)
        pendingBodyVersions = try c.decodeIfPresent([UUID: PendingBody].self, forKey: .pendingBodyVersions) ?? [:]
        refusedRemotes = try c.decodeIfPresent([UUID: RefusedRemote].self, forKey: .refusedRemotes) ?? [:]
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
