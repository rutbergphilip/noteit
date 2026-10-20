import Foundation

/// A note's metadata as stored in `library.json`. Moved from the app in foundations Task 1.1;
/// sync-security adds the lock fields (foundations Task 4.3).
public struct NoteMeta: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var notebookID: UUID?
    public var title: String
    public var preview: String
    public var isPinned: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var tags: [String]
    public var revision: UUID? = nil
    /// Device name when this note is a sync conflict copy.
    public var conflictSource: String? = nil
    /// The note this conflict copy was made from.
    public var conflictOriginalID: UUID? = nil
    /// Set while the note is in Recently Deleted.
    public var deletedAt: Date? = nil

    public init(
        id: UUID,
        notebookID: UUID?,
        title: String,
        preview: String,
        isPinned: Bool,
        createdAt: Date,
        updatedAt: Date,
        tags: [String],
        revision: UUID? = nil,
        conflictSource: String? = nil,
        conflictOriginalID: UUID? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.notebookID = notebookID
        self.title = title
        self.preview = preview
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.tags = tags
        self.revision = revision
        self.conflictSource = conflictSource
        self.conflictOriginalID = conflictOriginalID
        self.deletedAt = deletedAt
    }
}

extension NoteMeta {
    public var displayTitle: String { title.isEmpty ? "New Note" : title }
}
