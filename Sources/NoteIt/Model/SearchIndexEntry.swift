import Foundation
import NoteItCore

/// One note in `search-index.json`. Version 1 files only have `text` and `updatedAt`; their other fields decode as
/// nil and are rebuilt in the background.
struct SearchIndexEntry: Codable, Equatable {
    var text: String
    var plain: String?
    var tasks: [TaskLine]?
    var reminders: [ReminderLine]?
    var hasAttachment: Bool?
    var updatedAt: Date

    /// False for entries read from a version 1 file.
    var isComplete: Bool { plain != nil && tasks != nil && reminders != nil && hasAttachment != nil }
}

/// `search-index.json` in `NoteStore.rootURL`; never synced.
struct SearchIndexFile: Codable {
    static let currentVersion = 2
    var version: Int
    var entries: [String: SearchIndexEntry]
}
