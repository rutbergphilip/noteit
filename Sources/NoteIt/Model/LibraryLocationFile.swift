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

    enum LoadResult: Equatable {
        /// No file: an RTFD library in the data folder.
        case missing
        case loaded(LibraryLocationFile)
        /// A damaged file; it has been logged and set aside as `library-location.json.bad`.
        case corrupt
        /// A file NoteIt can't use now (a newer version or format, or a read error); left untouched. The reason is
        /// for the user.
        case unreadable(String)
    }

    static func load(dataDir: URL, fileManager: FileManager = .default,
                     log: (String) -> Void = { NSLog("%@", $0) }) -> LoadResult {
        let url = url(dataDir: dataDir)
        guard fileManager.fileExists(atPath: url.path) else { return .missing }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            log("NoteIt: couldn't read \(fileName): \(error)")
            return .unreadable("\(fileName) couldn't be read: \(error.localizedDescription)")
        }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let number = object["version"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
           let version = Int(exactly: number.doubleValue) {
            guard version == currentVersion else {
                log("NoteIt: \(fileName) has version \(version)")
                return .unreadable("\(fileName) has version \(version), and this version of NoteIt reads only version \(currentVersion).")
            }
            if let format = object["format"] as? String, LibraryFormatKind(rawValue: format) == nil {
                log("NoteIt: \(fileName) has unknown format \(format)")
                return .unreadable("\(fileName) names a library format this version of NoteIt doesn't know (\"\(format)\").")
            }
        }
        do {
            return .loaded(try JSONDecoder().decode(LibraryLocationFile.self, from: data))
        } catch {
            log("NoteIt: \(fileName) is damaged (\(error)); setting it aside and opening the library in the data folder")
            setAside(url, fileManager: fileManager, log: log)
            return .corrupt
        }
    }

    /// Renames `url` to `<name>.bad`, or `.bad-2`, `.bad-3`… so an earlier one is never replaced.
    private static func setAside(_ url: URL, fileManager: FileManager, log: (String) -> Void) {
        var bad = url.appendingPathExtension("bad")
        var attempt = 1
        while (try? fileManager.attributesOfItem(atPath: bad.path)) != nil {
            attempt += 1
            bad = url.appendingPathExtension("bad-\(attempt)")
        }
        do {
            try fileManager.moveItem(at: url, to: bad)
        } catch {
            log("NoteIt: couldn't set aside \(fileName): \(error)")
        }
    }

    /// Atomic.
    func write(dataDir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: Self.url(dataDir: dataDir), options: .atomic)
    }
}
