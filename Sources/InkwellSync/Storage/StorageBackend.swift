import Foundation

public struct RemoteObject: Sendable, Hashable, Codable {
    public let key: String
    public let etag: String
    public let size: Int

    public init(key: String, etag: String, size: Int) {
        self.key = key
        self.etag = etag
        self.size = size
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
}

public protocol StorageBackend: Sendable {
    /// Returns every object under `prefix`; implementations handle pagination internally.
    func list(prefix: String) async throws -> [RemoteObject]
    func get(_ key: String) async throws -> (data: Data, etag: String)
    /// ifMatch: write only if current etag equals it. ifNoneMatch: write only if key absent. Returns new etag.
    @discardableResult func put(_ key: String, data: Data, ifMatch: String?, ifNoneMatch: Bool) async throws -> String
    func delete(_ key: String) async throws
    /// Reachability/auth check for "Test connection".
    func probe() async throws
}
