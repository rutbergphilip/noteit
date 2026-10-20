import Foundation
import NoteItCore

// The Local API v1 data shapes (automation spec §6.9). Shapes owned by the automation plan; built in foundations
// Task 5.1. Within v1 they only gain optional fields.

public enum BodyFormatDTO: String, Codable, Sendable { case markdown, text, html, noteitDoc = "noteit-doc" }

/// No plugin kind: plugins never hold tokens.
public enum ClientKind: String, Codable, Sendable, CaseIterable { case cli, `extension`, mcp, script }

public struct NoteSummaryDTO: Codable, Sendable, Equatable {
    public var id: UUID
    public var title: String
    public var notebookID: UUID?
    public var notebookName: String?
    public var tags: [String]
    public var pinned: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var revision: UUID?
    public var deletedAt: Date?
    /// Empty for a locked note.
    public var preview: String
    public var conflict: Bool
    public var locked: Bool
    /// `noteit://note/<UUID>`.
    public var url: String

    public init(id: UUID, title: String, notebookID: UUID?, notebookName: String?, tags: [String], pinned: Bool,
                createdAt: Date, updatedAt: Date, revision: UUID?, deletedAt: Date?, preview: String, conflict: Bool,
                locked: Bool, url: String) {
        self.id = id
        self.title = title
        self.notebookID = notebookID
        self.notebookName = notebookName
        self.tags = tags
        self.pinned = pinned
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.revision = revision
        self.deletedAt = deletedAt
        self.preview = preview
        self.conflict = conflict
        self.locked = locked
        self.url = url
    }
}

/// A `NoteSummaryDTO` plus `format` and `body`, encoded flat in one object.
public struct NoteDTO: Codable, Sendable, Equatable {
    public var summary: NoteSummaryDTO
    public var format: BodyFormatDTO
    public var body: String

    public init(summary: NoteSummaryDTO, format: BodyFormatDTO, body: String) {
        self.summary = summary
        self.format = format
        self.body = body
    }

    private enum CodingKeys: String, CodingKey { case format, body }

    public init(from decoder: Decoder) throws {
        summary = try NoteSummaryDTO(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decode(BodyFormatDTO.self, forKey: .format)
        body = try container.decode(String.self, forKey: .body)
    }

    public func encode(to encoder: Encoder) throws {
        try summary.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(format, forKey: .format)
        try container.encode(body, forKey: .body)
    }
}

public struct NotebookDTO: Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var symbol: String
    public var color: String
    public var sortIndex: Int
    public var noteCount: Int
    /// Organise's; nil until it ships nested notebooks. `parentID` is the API name for `Notebook.parent`.
    public var parentID: UUID?
    public var path: [String]?

    public init(id: UUID, name: String, symbol: String, color: String, sortIndex: Int, noteCount: Int,
                parentID: UUID? = nil, path: [String]? = nil) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.color = color
        self.sortIndex = sortIndex
        self.noteCount = noteCount
        self.parentID = parentID
        self.path = path
    }
}

public struct TagDTO: Codable, Sendable, Equatable {
    public var name: String
    public var noteCount: Int

    public init(name: String, noteCount: Int) {
        self.name = name
        self.noteCount = noteCount
    }
}

/// `GET /v1/tags?tree=1`, built by organise's provider. `noteCount` counts notes with exactly this tag,
/// `totalCount` notes with it or a descendant, each note once.
public struct TagNodeDTO: Codable, Sendable, Equatable {
    public var name: String
    public var path: String
    public var noteCount: Int
    public var totalCount: Int
    public var children: [TagNodeDTO]

    public init(name: String, path: String, noteCount: Int, totalCount: Int, children: [TagNodeDTO]) {
        self.name = name
        self.path = path
        self.noteCount = noteCount
        self.totalCount = totalCount
        self.children = children
    }
}

public enum ChangeKind: String, Codable, Sendable { case note, notebook }
public enum ChangeOp: String, Codable, Sendable { case created, updated, deleted, restored, purged }

public struct ChangeDTO: Codable, Sendable, Equatable {
    public var cursor: String
    public var kind: ChangeKind
    public var id: UUID
    public var op: ChangeOp
    public var at: Date

    public init(cursor: String, kind: ChangeKind, id: UUID, op: ChangeOp, at: Date) {
        self.cursor = cursor
        self.kind = kind
        self.id = id
        self.op = op
        self.at = at
    }
}

public struct ChangesPage: Codable, Sendable, Equatable {
    public var changes: [ChangeDTO]
    public var cursor: String
    public var hasMore: Bool

    public init(changes: [ChangeDTO], cursor: String, hasMore: Bool) {
        self.changes = changes
        self.cursor = cursor
        self.hasMore = hasMore
    }
}

public struct Page<T: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    public var items: [T]
    public var nextCursor: String?

    public init(items: [T], nextCursor: String?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

public struct ClientDTO: Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var kind: ClientKind
    public var scopes: [APIScope]
    public var origin: String?
    public var tokenHint: String
    public var createdAt: Date
    public var lastUsedAt: Date?

    public init(id: UUID, name: String, kind: ClientKind, scopes: [APIScope], origin: String?, tokenHint: String,
                createdAt: Date, lastUsedAt: Date?) {
        self.id = id
        self.name = name
        self.kind = kind
        self.scopes = scopes
        self.origin = origin
        self.tokenHint = tokenHint
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }
}

/// `GET /v1/ping`. The optional parts are `capabilities`, never `features` (that name belongs to the sync manifest).
public struct PingDTO: Codable, Sendable, Equatable {
    public var name: String
    public var apiVersion: Int
    public var appVersion: String
    public var capabilities: [String]

    public init(name: String, apiVersion: Int, appVersion: String, capabilities: [String]) {
        self.name = name
        self.apiVersion = apiVersion
        self.appVersion = appVersion
        self.capabilities = capabilities
    }
}

public struct CreateNoteRequest: Codable, Sendable, Equatable {
    public var title: String?
    public var body: String
    public var format: BodyFormatDTO?
    public var notebookID: UUID?
    public var notebook: String?
    public var tags: [String]?
    public var pinned: Bool?

    public init(title: String? = nil, body: String, format: BodyFormatDTO? = nil, notebookID: UUID? = nil,
                notebook: String? = nil, tags: [String]? = nil, pinned: Bool? = nil) {
        self.title = title
        self.body = body
        self.format = format
        self.notebookID = notebookID
        self.notebook = notebook
        self.tags = tags
        self.pinned = pinned
    }
}

public struct PatchNoteRequest: Codable, Sendable, Equatable {
    public var title: String?
    public var body: String?
    public var format: BodyFormatDTO?
    public var notebookID: UUID?
    public var pinned: Bool?

    public init(title: String? = nil, body: String? = nil, format: BodyFormatDTO? = nil, notebookID: UUID? = nil,
                pinned: Bool? = nil) {
        self.title = title
        self.body = body
        self.format = format
        self.notebookID = notebookID
        self.pinned = pinned
    }
}

/// Declared in `NoteItCore` (foundations 5.3), so the URL parser and the API share it.
public typealias AppendPosition = NoteItCore.AppendPosition

public struct AppendRequest: Codable, Sendable, Equatable {
    public var text: String
    public var format: BodyFormatDTO?
    public var position: AppendPosition?
    public var timestamp: Bool?
    public var ifRevision: UUID?

    public init(text: String, format: BodyFormatDTO? = nil, position: AppendPosition? = nil, timestamp: Bool? = nil,
                ifRevision: UUID? = nil) {
        self.text = text
        self.format = format
        self.position = position
        self.timestamp = timestamp
        self.ifRevision = ifRevision
    }
}

public enum DailyFormat: String, Codable, Sendable { case plain, markdown }

public struct DailyAppendRequest: Codable, Sendable, Equatable {
    public var text: String
    public var timestamp: Bool?
    public var date: String?
    /// Default `plain`.
    public var format: DailyFormat?

    public init(text: String, timestamp: Bool? = nil, date: String? = nil, format: DailyFormat? = nil) {
        self.text = text
        self.timestamp = timestamp
        self.date = date
        self.format = format
    }
}

public struct NotebookRequest: Codable, Sendable, Equatable {
    public var name: String?
    public var symbol: String?
    public var color: String?

    public init(name: String? = nil, symbol: String? = nil, color: String? = nil) {
        self.name = name
        self.symbol = symbol
        self.color = color
    }
}

public enum HighlightField: String, Codable, Sendable { case title, body }

/// `[start, length]` pairs in UTF-16 code units, sorted and not overlapping: into the note title for `.title`,
/// into the snippet for `.body`.
public struct HighlightDTO: Codable, Sendable, Equatable {
    public var field: HighlightField
    public var ranges: [[Int]]

    public init(field: HighlightField, ranges: [[Int]]) {
        self.field = field
        self.ranges = ranges
    }
}

/// `score` and `highlights` are filled by organise's ranker, `matchedBy` by private-ai's modes.
public struct SearchResultDTO: Codable, Sendable, Equatable {
    public var note: NoteSummaryDTO
    public var snippet: String
    public var score: Double?
    public var highlights: [HighlightDTO]?
    public var matchedBy: [String]?

    public init(note: NoteSummaryDTO, snippet: String, score: Double? = nil, highlights: [HighlightDTO]? = nil,
                matchedBy: [String]? = nil) {
        self.note = note
        self.snippet = snippet
        self.score = score
        self.highlights = highlights
        self.matchedBy = matchedBy
    }
}

public struct SearchResponseDTO: Codable, Sendable, Equatable {
    public var mode: String
    public var results: [SearchResultDTO]

    public init(mode: String, results: [SearchResultDTO]) {
        self.mode = mode
        self.results = results
    }
}

public struct NotebooksResponseDTO: Codable, Sendable, Equatable {
    public var notebooks: [NotebookDTO]
    public var defaultNotebookID: UUID?

    public init(notebooks: [NotebookDTO], defaultNotebookID: UUID?) {
        self.notebooks = notebooks
        self.defaultNotebookID = defaultNotebookID
    }
}

public struct AttachmentDTO: Codable, Sendable, Equatable {
    public var name: String
    public var contentType: String
    public var size: Int

    public init(name: String, contentType: String, size: Int) {
        self.name = name
        self.contentType = contentType
        self.size = size
    }
}

public struct StagedUploadDTO: Codable, Sendable, Equatable {
    public var id: String
    public var expiresAt: Date

    public init(id: String, expiresAt: Date) {
        self.id = id
        self.expiresAt = expiresAt
    }
}

public struct PairStartRequest: Codable, Sendable, Equatable {
    public var clientName: String
    public var kind: ClientKind
    public var scopes: [APIScope]

    public init(clientName: String, kind: ClientKind, scopes: [APIScope]) {
        self.clientName = clientName
        self.kind = kind
        self.scopes = scopes
    }
}

public struct PairStartResponse: Codable, Sendable, Equatable {
    public var pairingID: UUID
    public var expiresAt: Date

    public init(pairingID: UUID, expiresAt: Date) {
        self.pairingID = pairingID
        self.expiresAt = expiresAt
    }
}

public struct PairCompleteRequest: Codable, Sendable, Equatable {
    public var pairingID: UUID
    public var code: String

    public init(pairingID: UUID, code: String) {
        self.pairingID = pairingID
        self.code = code
    }
}

public struct PairCompleteResponse: Codable, Sendable, Equatable {
    public var token: String
    public var clientID: UUID
    public var scopes: [APIScope]

    public init(token: String, clientID: UUID, scopes: [APIScope]) {
        self.token = token
        self.clientID = clientID
        self.scopes = scopes
    }
}
