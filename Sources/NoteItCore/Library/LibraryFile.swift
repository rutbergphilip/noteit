import Foundation

/// The contents of `library.json`. Moved out of `NoteStore` in foundations Task 1.3.
public struct LibraryFile: Codable, Sendable {
    public var version: Int
    public var notebooks: [Notebook]
    public var notes: [NoteMeta]
    /// Local only, never synced (foundations Task 3.5). The `RecordPayload.revision` of the last remote meta
    /// applied to each record, saved in the same library write as the applied record. nil (omitted) when
    /// nothing has been applied, so libraries without it keep their bytes.
    public var appliedRemoteRevisions: AppliedRemoteRevisions?

    public init(version: Int, notebooks: [Notebook], notes: [NoteMeta], appliedRemoteRevisions: AppliedRemoteRevisions? = nil) {
        self.version = version
        self.notebooks = notebooks
        self.notes = notes
        self.appliedRemoteRevisions = appliedRemoteRevisions
    }
}

/// One map per raw-meta kind kept in library.json, keyed by uppercase `uuidString` (foundations Task 3.5). A later
/// raw-meta kind keeps its map in its own data-folder file, saved in the same write as its records, and adds no
/// field here.
public struct AppliedRemoteRevisions: Codable, Sendable, Equatable {
    public var notes: [String: UUID]
    public var notebooks: [String: UUID]

    public init(notes: [String: UUID] = [:], notebooks: [String: UUID] = [:]) {
        self.notes = notes
        self.notebooks = notebooks
    }

    public var isEmpty: Bool { notes.isEmpty && notebooks.isEmpty }
}

/// Best-effort salvage of a `library.json` that failed strict decoding. Moved out of `NoteStore` in
/// foundations Task 1.3.
public struct PartialLibrary: Decodable, Sendable {
    public var notebooks: [Notebook]?
    public var notes: [NoteMeta]?

    enum CodingKeys: String, CodingKey { case notebooks, notes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        notebooks = try? c.decode([Notebook].self, forKey: .notebooks)
        notes = try? c.decode([NoteMeta].self, forKey: .notes)
    }
}
