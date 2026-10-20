import Foundation

/// `library-location.json` in the data folder: which format the library has and, for Markdown, where its content
/// folder is (markdown-storage spec §3.1). A missing file means an RTFD library in the data folder.
struct LibraryLocationFile: Codable, Equatable {
    static let fileName = "library-location.json"
    static let currentVersion = 1

    var version: Int
    var format: LibraryFormatKind
    /// The content folder, with `~` for the home folder.
    var path: String
    var bookmark: Data?
    var libraryID: UUID
    /// True for a folder NoteIt created, false for an adopted folder.
    var renameFilesOnTitleChange: Bool

    init(version: Int = Self.currentVersion, format: LibraryFormatKind, path: String, bookmark: Data? = nil,
         libraryID: UUID, renameFilesOnTitleChange: Bool = true) {
        self.version = version
        self.format = format
        self.path = path
        self.bookmark = bookmark
        self.libraryID = libraryID
        self.renameFilesOnTitleChange = renameFilesOnTitleChange
    }

    private enum CodingKeys: String, CodingKey {
        case version, format, path, bookmark, libraryID, renameFilesOnTitleChange
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        format = try c.decode(LibraryFormatKind.self, forKey: .format)
        path = try c.decode(String.self, forKey: .path)
        bookmark = try c.decodeIfPresent(Data.self, forKey: .bookmark)
        libraryID = try c.decode(UUID.self, forKey: .libraryID)
        renameFilesOnTitleChange = try c.decodeIfPresent(Bool.self, forKey: .renameFilesOnTitleChange) ?? true
    }

    var contentRootURL: URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    static func displayPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    static func url(dataDir: URL) -> URL {
        dataDir.appendingPathComponent(fileName)
    }

    /// nil when the file is missing (an RTFD library in `dataDir`) or unreadable. An unreadable file is logged and
    /// renamed `library-location.json.bad`.
    static func load(dataDir: URL, fileManager: FileManager = .default,
                     log: (String) -> Void = { NSLog("%@", $0) }) -> LibraryLocationFile? {
        let url = url(dataDir: dataDir)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            return try JSONDecoder().decode(LibraryLocationFile.self, from: Data(contentsOf: url))
        } catch {
            log("NoteIt: \(fileName) is unreadable (\(error)); opening the library in the data folder")
            let bad = url.appendingPathExtension("bad")
            do {
                if fileManager.fileExists(atPath: bad.path) { try fileManager.removeItem(at: bad) }
                try fileManager.moveItem(at: url, to: bad)
            } catch {
                log("NoteIt: couldn't set aside \(fileName): \(error)")
            }
            return nil
        }
    }

    /// Atomic.
    func write(dataDir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: Self.url(dataDir: dataDir), options: .atomic)
    }
}
