import Foundation

/// The contents of `library.json`. Moved out of `NoteStore` in foundations Task 1.3.
public struct LibraryFile: Codable, Sendable {
    public var version: Int
    public var notebooks: [Notebook]
    public var notes: [NoteMeta]

    public init(version: Int, notebooks: [Notebook], notes: [NoteMeta]) {
        self.version = version
        self.notebooks = notebooks
        self.notes = notes
    }
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
