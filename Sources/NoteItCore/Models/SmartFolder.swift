import Foundation

/// A saved search shown in the sidebar. Synced like a notebook: no body, the newer edit wins.
public struct SmartFolder: Identifiable, Codable, Hashable, Sendable {
    public static let defaultSymbol = "folder.badge.gearshape"
    public static let maxNameLength = 60
    public static let maxQueryLength = 500
    public static let maxCount = 200

    public var id: UUID
    public var name: String
    public var query: String
    public var symbol: String
    public var sortIndex: Int
    public var revision: UUID? = nil
    public var modifiedAt: Date? = nil

    public init(id: UUID = UUID(), name: String, query: String, symbol: String = SmartFolder.defaultSymbol,
                sortIndex: Int, revision: UUID? = nil, modifiedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.query = query
        self.symbol = symbol
        self.sortIndex = sortIndex
        self.revision = revision
        self.modifiedAt = modifiedAt
    }
}
