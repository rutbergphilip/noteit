import Foundation

/// A notebook in the library. Moved from the app in foundations Task 1.1; organise adds `parent` later.
public struct Notebook: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var symbol: String
    public var colorHex: String
    public var sortIndex: Int
    public var revision: UUID? = nil
    public var modifiedAt: Date? = nil
    public var defaultTemplateID: UUID? = nil

    public init(
        id: UUID = UUID(),
        name: String,
        symbol: String,
        colorHex: String,
        sortIndex: Int,
        revision: UUID? = nil,
        modifiedAt: Date? = nil,
        defaultTemplateID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.colorHex = colorHex
        self.sortIndex = sortIndex
        self.revision = revision
        self.modifiedAt = modifiedAt
        self.defaultTemplateID = defaultTemplateID
    }
}
