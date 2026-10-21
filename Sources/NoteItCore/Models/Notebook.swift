import Foundation

/// A notebook in the library. `parent` nil is top level; it is always encoded (`null` at the top level), so a
/// record without the key can be told apart as one written by NoteIt 0.2 or earlier.
public struct Notebook: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var symbol: String
    public var colorHex: String
    public var sortIndex: Int
    public var revision: UUID? = nil
    public var modifiedAt: Date? = nil
    public var defaultTemplateID: UUID? = nil
    public var parent: UUID? = nil

    public init(
        id: UUID = UUID(),
        name: String,
        symbol: String,
        colorHex: String,
        sortIndex: Int,
        revision: UUID? = nil,
        modifiedAt: Date? = nil,
        defaultTemplateID: UUID? = nil,
        parent: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.colorHex = colorHex
        self.sortIndex = sortIndex
        self.revision = revision
        self.modifiedAt = modifiedAt
        self.defaultTemplateID = defaultTemplateID
        self.parent = parent
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(symbol, forKey: .symbol)
        try container.encode(colorHex, forKey: .colorHex)
        try container.encode(sortIndex, forKey: .sortIndex)
        try container.encodeIfPresent(revision, forKey: .revision)
        try container.encodeIfPresent(modifiedAt, forKey: .modifiedAt)
        try container.encodeIfPresent(defaultTemplateID, forKey: .defaultTemplateID)
        try container.encode(parent, forKey: .parent)
    }

    /// Whether a notebook record's JSON says where the notebook sits; NoteIt 0.2 and earlier leave `parent` out.
    public static func recordHasParentKey(_ json: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return false }
        return object.keys.contains("parent")
    }
}
