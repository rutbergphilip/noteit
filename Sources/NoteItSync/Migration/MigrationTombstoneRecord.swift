import Foundation

/// What this device knows about one tombstone its `RemoteMigration` copies under `noteit/v1/tombstones/`.
public enum MigrationTombstoneEntry: Equatable, Sendable, Codable {
    /// Saved before the put, with the SHA-256 hex of the bytes. Never proof of ownership: every device's copy
    /// of a legacy tombstone has the same bytes.
    case pending(hash: String)
    /// Saved once the put created the object, with the etag it returned. Owned while the object still has it.
    case confirmed(etag: String)

    private enum CodingKeys: String, CodingKey { case pending, confirmed }

    public init(from decoder: Decoder) throws {
        // Older records held plain strings (a hash or an etag), which prove nothing.
        if let legacy = try? decoder.singleValueContainer().decode(String.self) {
            self = .pending(hash: legacy)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let etag = try container.decodeIfPresent(String.self, forKey: .confirmed) {
            self = .confirmed(etag: etag)
        } else {
            self = .pending(hash: try container.decode(String.self, forKey: .pending))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pending(let hash): try container.encode(hash, forKey: .pending)
        case .confirmed(let etag): try container.encode(etag, forKey: .confirmed)
        }
    }
}

/// The tombstones this device's `RemoteMigration` copies, by key. Kept on this device only, so an interrupted
/// copy can tell its own leftovers from other devices' deletions.
public protocol MigrationTombstoneRecord: AnyObject, Sendable {
    func load() -> [String: MigrationTombstoneEntry]
    /// An empty record clears it.
    func save(_ tombstones: [String: MigrationTombstoneEntry]) throws
}

public final class InMemoryMigrationTombstoneRecord: MigrationTombstoneRecord, @unchecked Sendable {
    private let lock = NSLock()
    private var tombstones: [String: MigrationTombstoneEntry] = [:]

    public init() {}

    public func load() -> [String: MigrationTombstoneEntry] {
        lock.lock()
        defer { lock.unlock() }
        return tombstones
    }

    public func save(_ tombstones: [String: MigrationTombstoneEntry]) throws {
        lock.lock()
        defer { lock.unlock() }
        self.tombstones = tombstones
    }
}

/// A JSON file next to the sync state; missing or corrupt files read as empty.
public final class FileMigrationTombstoneRecord: MigrationTombstoneRecord {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() -> [String: MigrationTombstoneEntry] {
        guard let data = try? Data(contentsOf: url),
              let tombstones = try? JSONDecoder().decode([String: MigrationTombstoneEntry].self, from: data) else { return [:] }
        return tombstones
    }

    public func save(_ tombstones: [String: MigrationTombstoneEntry]) throws {
        let fileManager = FileManager.default
        guard !tombstones.isEmpty else {
            if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
            return
        }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(tombstones).write(to: url, options: .atomic)
    }
}
