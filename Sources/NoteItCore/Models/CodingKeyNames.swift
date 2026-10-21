import Foundation

/// The JSON keys this build writes for each synced model, for `RawMetaOverlay` ownedKeys (foundations Task 3.5).
/// A stored property added to a model must be added here; `ModelCodingTests` checks both sets.
extension NoteMeta {
    public static let ownedCodingKeys: Set<String> = [
        "id", "notebookID", "title", "preview", "isPinned", "createdAt", "updatedAt", "tags", "revision",
        "conflictSource", "conflictOriginalID", "deletedAt", "lock",
    ]
}

extension Notebook {
    public static let ownedCodingKeys: Set<String> = [
        "id", "name", "symbol", "colorHex", "sortIndex", "revision", "modifiedAt", "defaultTemplateID", "parent",
    ]
}

extension SmartFolder {
    public static let ownedCodingKeys: Set<String> = [
        "id", "name", "query", "symbol", "sortIndex", "revision", "modifiedAt",
    ]
}
