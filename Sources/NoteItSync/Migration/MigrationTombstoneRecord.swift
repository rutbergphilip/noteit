import Foundation

/// The tombstones this device's `RemoteMigration` created under `noteit/v1/tombstones/`, by key, with the etag of
/// the put. Kept on this device only, so an interrupted copy can tell its own leftovers from other devices' deletions.
public protocol MigrationTombstoneRecord: AnyObject, Sendable {
    func load() -> [String: String]
    /// An empty record clears it.
    func save(_ tombstones: [String: String]) throws
}

public final class InMemoryMigrationTombstoneRecord: MigrationTombstoneRecord, @unchecked Sendable {
    private let lock = NSLock()
    private var tombstones: [String: String] = [:]

    public init() {}

    public func load() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return tombstones
    }

    public func save(_ tombstones: [String: String]) throws {
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

    public func load() -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let tombstones = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return tombstones
    }

    public func save(_ tombstones: [String: String]) throws {
        let fileManager = FileManager.default
        guard !tombstones.isEmpty else {
            if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
            return
        }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(tombstones).write(to: url, options: .atomic)
    }
}
