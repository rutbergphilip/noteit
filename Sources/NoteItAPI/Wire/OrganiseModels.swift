import Foundation

// Organise's Local API shapes (organise spec §8). Within v1 they only gain optional fields.

public struct TagRenameRequest: Codable, Sendable, Equatable {
    public var from: String
    public var to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

public struct TagDeleteRequest: Codable, Sendable, Equatable {
    public var tag: String

    public init(tag: String) {
        self.tag = tag
    }
}

public struct SkippedNoteDTO: Codable, Sendable, Equatable {
    public var noteID: UUID
    /// An `APIErrorCode` raw value, such as `note_unreadable`.
    public var reason: String

    public init(noteID: UUID, reason: String) {
        self.noteID = noteID
        self.reason = reason
    }
}

public struct TagEditResponseDTO: Codable, Sendable, Equatable {
    public var changed: [UUID]
    public var skipped: [SkippedNoteDTO]

    public init(changed: [UUID], skipped: [SkippedNoteDTO]) {
        self.changed = changed
        self.skipped = skipped
    }
}

public struct NotebookMoveRequest: Codable, Sendable, Equatable {
    /// nil or missing moves the notebook to the top level.
    public var parentID: UUID?
    /// Position among its new siblings; the end when missing.
    public var index: Int?

    public init(parentID: UUID?, index: Int? = nil) {
        self.parentID = parentID
        self.index = index
    }
}

public struct SmartFolderDTO: Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var query: String
    public var symbol: String
    public var sortIndex: Int

    public init(id: UUID, name: String, query: String, symbol: String, sortIndex: Int) {
        self.id = id
        self.name = name
        self.query = query
        self.symbol = symbol
        self.sortIndex = sortIndex
    }
}

public struct SmartFoldersResponseDTO: Codable, Sendable, Equatable {
    public var smartFolders: [SmartFolderDTO]

    public init(smartFolders: [SmartFolderDTO]) {
        self.smartFolders = smartFolders
    }
}

/// Create needs `name` and `query`; update changes only the fields given.
public struct SmartFolderRequest: Codable, Sendable, Equatable {
    public var name: String?
    public var query: String?
    public var symbol: String?

    public init(name: String? = nil, query: String? = nil, symbol: String? = nil) {
        self.name = name
        self.query = query
        self.symbol = symbol
    }
}

public struct SmartFolderNotesDTO: Codable, Sendable, Equatable {
    public var smartFolder: SmartFolderDTO
    public var notes: [NoteSummaryDTO]

    public init(smartFolder: SmartFolderDTO, notes: [NoteSummaryDTO]) {
        self.smartFolder = smartFolder
        self.notes = notes
    }
}

public struct TaskDTO: Codable, Sendable, Equatable {
    public var noteID: UUID
    public var noteTitle: String
    public var notebookID: UUID?
    /// The task's paragraph index in the note; with `textHash` it names the task in complete and due requests.
    public var paragraph: Int
    public var textHash: String
    /// The task as the Tasks view shows it, without its checkbox and date tokens.
    public var text: String
    public var checked: Bool
    /// `"2026-10-21"` or `"2026-10-21 14:00"`, local time.
    public var due: String?
    public var remind: String?
    /// `noteit://note/<UUID>`.
    public var url: String

    public init(noteID: UUID, noteTitle: String, notebookID: UUID?, paragraph: Int, textHash: String, text: String,
                checked: Bool, due: String?, remind: String?, url: String) {
        self.noteID = noteID
        self.noteTitle = noteTitle
        self.notebookID = notebookID
        self.paragraph = paragraph
        self.textHash = textHash
        self.text = text
        self.checked = checked
        self.due = due
        self.remind = remind
        self.url = url
    }
}

public struct TaskGroupDTO: Codable, Sendable, Equatable {
    /// `overdue`, `today`, `upcoming`, `later`, `noDate` or `completed`.
    public var group: String
    public var tasks: [TaskDTO]

    public init(group: String, tasks: [TaskDTO]) {
        self.group = group
        self.tasks = tasks
    }
}

public struct TasksResponseDTO: Codable, Sendable, Equatable {
    public var groups: [TaskGroupDTO]

    public init(groups: [TaskGroupDTO]) {
        self.groups = groups
    }
}

public struct TaskCompleteRequest: Codable, Sendable, Equatable {
    public var noteID: UUID
    public var paragraph: Int
    public var textHash: String
    public var checked: Bool

    public init(noteID: UUID, paragraph: Int, textHash: String, checked: Bool) {
        self.noteID = noteID
        self.paragraph = paragraph
        self.textHash = textHash
        self.checked = checked
    }
}

public struct TaskDueRequest: Codable, Sendable, Equatable {
    public var noteID: UUID
    public var paragraph: Int
    public var textHash: String
    /// `"2026-10-21"`, `"2026-10-21 14:00"` or `"2026-10-21T14:00"`; null removes the due date.
    public var due: String?

    public init(noteID: UUID, paragraph: Int, textHash: String, due: String?) {
        self.noteID = noteID
        self.paragraph = paragraph
        self.textHash = textHash
        self.due = due
    }
}
