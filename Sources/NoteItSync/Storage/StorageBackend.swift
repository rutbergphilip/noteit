import Foundation

public struct RemoteObject: Sendable, Hashable, Codable {
    public let key: String
    public let etag: String
    public let size: Int
    /// When the object was last written, if the backend lists it (S3 `LastModified`); nil otherwise. Read only by
    /// `SyncEngine.cleanUpUnusedStorage()` (web-app spec §3.4.9).
    public let lastModified: Date?

    public init(key: String, etag: String, size: Int, lastModified: Date? = nil) {
        self.key = key
        self.etag = etag
        self.size = size
        self.lastModified = lastModified
    }
}

public enum StorageError: Error, Sendable, Equatable {
    case notFound(String)
    case preconditionFailed(String)
    case unauthorized(String)
    case clockSkew(String)
    case insecureConnectionBlocked(String)
    case network(String)
    case invalidResponse(String)
    case io(String)
    /// The storage can't be reached right now (an unmounted or unresponsive network volume). Nothing about its
    /// contents is known, so it must never be read as empty.
    case unavailable(String)
    /// A folder destination is reachable but its NoteIt store is gone: deleted, or the folder was replaced.
    case storeMissing(String)
    /// `delete(_:ifMatch:)` on a store whose conditional deletes aren't atomic (sync-security Task 3.0). Nothing
    /// was sent. Never fatal; the v2 engine checks `atomicConditionalDelete()` first and never triggers it.
    case conditionalDeleteUnsupported(String)
}

public protocol StorageBackend: Sendable {
    /// Returns every object under `prefix`; implementations handle pagination internally.
    func list(prefix: String) async throws -> [RemoteObject]
    func get(_ key: String) async throws -> (data: Data, etag: String)
    /// ifMatch: write only if current etag equals it. ifNoneMatch: write only if key absent. Returns new etag.
    @discardableResult func put(_ key: String, data: Data, ifMatch: String?, ifNoneMatch: Bool) async throws -> String
    func delete(_ key: String) async throws
    /// Deletes only while the current etag equals `ifMatch` (when non-nil), otherwise throws `preconditionFailed`.
    func delete(_ key: String, ifMatch: String?) async throws
    /// Reachability/auth check for "Test connection".
    func probe() async throws
    /// True only when this backend showed, in this session, that `If-Match`/`If-None-Match` writes are enforced
    /// atomically and that an overwrite gets a new ETag the old one no longer matches (web-app spec §3.4.9).
    func atomicConditionalWrites() async -> Bool
    /// True only when a `DELETE` with a wrong `If-Match` was refused and left the object, and one with the right
    /// `If-Match` succeeded, in this session. Without it `delete(_:ifMatch:)` may throw `conditionalDeleteUnsupported`.
    func atomicConditionalDelete() async -> Bool
}

extension StorageBackend {
    public func atomicConditionalWrites() async -> Bool { false }
    public func atomicConditionalDelete() async -> Bool { false }

    /// For backends that can't delete conditionally: `ifMatch` is ignored.
    public func delete(_ key: String, ifMatch: String?) async throws {
        try await delete(key)
    }
}
