import Foundation

/// The JSON coding used for `library.json` and the other data-folder files. Moved out of `NoteStore` in
/// foundations Task 1.3.
public enum LibraryCoding {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public static func decode(_ data: Data) throws -> LibraryFile {
        try decoder.decode(LibraryFile.self, from: data)
    }

    /// Whatever notebooks and notes still decode from a library that failed `decode`.
    public static func salvage(_ data: Data) -> PartialLibrary? {
        try? decoder.decode(PartialLibrary.self, from: data)
    }
}
