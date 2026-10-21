import Foundation
import NoteItCore

/// What NoteIt last knew about one note file (spec §3.1). `path` is content-relative with `/` separators.
struct MarkdownFileEntry: Codable, Equatable, Sendable {
    var path: String
    var sha256: String
    var size: Int64
    var mtimeNs: Int64
    var inode: UInt64
    var frontMatterExtra: String?
    var formerPaths: [String]
    /// The title the file name was made from; a rename follows only a later title change in NoteIt (spec §3.4).
    var nameTitle: String?
    /// The `NoteMeta` fields last written to the file's front matter or folder (`MarkdownBodyStorage.placement`).
    var placement: String?
    /// `_attachments/` file names the note refers to.
    var attachments: [String]

    init(path: String, sha256: String = "", size: Int64 = 0, mtimeNs: Int64 = 0, inode: UInt64 = 0,
         frontMatterExtra: String? = nil, formerPaths: [String] = [], nameTitle: String? = nil,
         placement: String? = nil, attachments: [String] = []) {
        self.path = path
        self.sha256 = sha256
        self.size = size
        self.mtimeNs = mtimeNs
        self.inode = inode
        self.frontMatterExtra = frontMatterExtra
        self.formerPaths = formerPaths
        self.nameTitle = nameTitle
        self.placement = placement
        self.attachments = attachments
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        sha256 = try c.decodeIfPresent(String.self, forKey: .sha256) ?? ""
        size = try c.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        mtimeNs = try c.decodeIfPresent(Int64.self, forKey: .mtimeNs) ?? 0
        inode = try c.decodeIfPresent(UInt64.self, forKey: .inode) ?? 0
        frontMatterExtra = try c.decodeIfPresent(String.self, forKey: .frontMatterExtra)
        formerPaths = try c.decodeIfPresent([String].self, forKey: .formerPaths) ?? []
        nameTitle = try c.decodeIfPresent(String.self, forKey: .nameTitle)
        placement = try c.decodeIfPresent(String.self, forKey: .placement)
        attachments = try c.decodeIfPresent([String].self, forKey: .attachments) ?? []
    }

    var folder: String { MarkdownPathIndex.folder(of: path) }
    var fileName: String { (path as NSString).lastPathComponent }
    var stem: String { (fileName as NSString).deletingPathExtension }
}

/// A file's size, modification time and inode, as compared with `markdown-files.json` before hashing.
struct MarkdownFileStat: Equatable, Sendable {
    var size: Int64
    var mtimeNs: Int64
    var inode: UInt64

    static func of(_ url: URL) -> MarkdownFileStat? {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let ns = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        return MarkdownFileStat(size: Int64(info.st_size), mtimeNs: ns, inode: UInt64(info.st_ino))
    }

    func matches(_ entry: MarkdownFileEntry) -> Bool {
        size == entry.size && mtimeNs == entry.mtimeNs && inode == entry.inode
    }
}

/// `markdown-files.json` in the data folder: note id → file, notebook id → folder, and the path → id map used to
/// resolve wiki links (spec §3.1, §3.4). Thread-safe; every change is saved atomically unless inside `batch`.
final class MarkdownPathIndex: @unchecked Sendable {
    static let fileName = "markdown-files.json"
    static let maxStemLength = 100
    /// A file name holds 255 bytes; this leaves room for a ` 99999` suffix, `.md` and the `.<name>.noteit-tmp` temp name.
    static let maxStemBytes = 255 - ".".utf8.count - " 99999".utf8.count - ".md".utf8.count - ".noteit-tmp".utf8.count
    static let untitled = "Untitled"

    let url: URL
    private let lock = NSRecursiveLock()
    private var entries: [UUID: MarkdownFileEntry] = [:]
    private var notebookFolders: [UUID: String] = [:]
    private var byPath: [String: UUID] = [:]
    private var batchDepth = 0
    private var dirty = false

    private struct File: Codable {
        var version: Int
        var notes: [String: MarkdownFileEntry]
        var notebooks: [String: String]
    }

    init(dataDir: URL) {
        url = dataDir.appendingPathComponent(Self.fileName)
        if let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data) {
            for (key, entry) in file.notes { if let id = UUID(uuidString: key) { entries[id] = entry } }
            for (key, path) in file.notebooks { if let id = UUID(uuidString: key) { notebookFolders[id] = path } }
            rebuildPaths()
        }
    }

    // MARK: Notes

    func entry(_ id: UUID) -> MarkdownFileEntry? {
        lock.withLock { entries[id] }
    }

    var allEntries: [UUID: MarkdownFileEntry] {
        lock.withLock { entries }
    }

    var ids: [UUID] {
        lock.withLock { Array(entries.keys) }
    }

    /// Case-insensitive, as on APFS and HFS+.
    func id(forPath path: String) -> UUID? {
        lock.withLock { byPath[path.lowercased()] }
    }

    func set(_ entry: MarkdownFileEntry, for id: UUID) {
        lock.withLock {
            if let old = entries[id] { byPath[old.path.lowercased()] = nil }
            entries[id] = entry
            byPath[entry.path.lowercased()] = id
            changed()
        }
    }

    func update(_ id: UUID, _ change: (inout MarkdownFileEntry) -> Void) {
        lock.withLock {
            guard var entry = entries[id] else { return }
            change(&entry)
            set(entry, for: id)
        }
    }

    /// Moves the entry to `path`, keeping the old path in `formerPaths` so wiki links to it still resolve.
    func move(_ id: UUID, to path: String) {
        update(id) { entry in
            guard entry.path != path else { return }
            entry.formerPaths.removeAll { $0.caseInsensitiveCompare(path) == .orderedSame }
            if !entry.formerPaths.contains(entry.path) { entry.formerPaths.append(entry.path) }
            if entry.formerPaths.count > 20 { entry.formerPaths.removeFirst(entry.formerPaths.count - 20) }
            entry.path = path
        }
    }

    func remove(_ id: UUID) {
        lock.withLock {
            guard let old = entries.removeValue(forKey: id) else { return }
            byPath[old.path.lowercased()] = nil
            changed()
        }
    }

    // MARK: Notebooks

    func notebookFolder(_ id: UUID) -> String? {
        lock.withLock { notebookFolders[id] }
    }

    var allNotebookFolders: [UUID: String] {
        lock.withLock { notebookFolders }
    }

    func setNotebookFolder(_ path: String?, for id: UUID) {
        lock.withLock {
            guard notebookFolders[id] != path else { return }
            notebookFolders[id] = path
            changed()
        }
    }

    /// Rewrites every note and notebook path under `old` to sit under `new` (a folder renamed or moved).
    func moveFolder(_ old: String, to new: String) {
        lock.withLock {
            let prefix = old.lowercased() + "/"
            for (id, entry) in entries where entry.path.lowercased().hasPrefix(prefix) {
                var moved = entry
                moved.formerPaths.append(entry.path)
                if moved.formerPaths.count > 20 { moved.formerPaths.removeFirst(moved.formerPaths.count - 20) }
                moved.path = new + "/" + entry.path.dropFirst(prefix.count)
                entries[id] = moved
            }
            for (id, path) in notebookFolders {
                if path.lowercased() == old.lowercased() {
                    notebookFolders[id] = new
                } else if path.lowercased().hasPrefix(prefix) {
                    notebookFolders[id] = new + "/" + path.dropFirst(prefix.count)
                }
            }
            rebuildPaths()
            changed()
        }
    }

    // MARK: Names

    /// The ids whose file name (without `.md`), folded as linking folds names, is `name`.
    func ids(withStem name: String) -> [UUID] {
        let folded = TextFold.fold(name)
        return lock.withLock {
            entries.filter { TextFold.fold($0.value.stem) == folded }.map(\.key)
        }
    }

    /// The ids whose current or former path ends with `components` (folded).
    func ids(withPathSuffix components: [String], former: Bool) -> [UUID] {
        let wanted = components.map { TextFold.fold($0) }
        func matches(_ path: String) -> Bool {
            var parts = path.split(separator: "/").map(String.init)
            guard let last = parts.popLast() else { return false }
            parts.append((last as NSString).deletingPathExtension)
            let folded = parts.map { TextFold.fold($0) }
            return folded.count >= wanted.count && Array(folded.suffix(wanted.count)) == wanted
        }
        return lock.withLock {
            entries.filter { former ? $0.value.formerPaths.contains(where: matches) : matches($0.value.path) }.map(\.key)
        }
    }

    /// `title` as a file stem: `ExportNaming.sanitized`, cut to 100 characters and `maxStemBytes` on a grapheme boundary.
    static func stem(forTitle title: String) -> String {
        var stem = ExportNaming.sanitized(title, fallback: untitled)
        if stem.count > maxStemLength {
            stem = String(stem.prefix(maxStemLength)).trimmingCharacters(in: .whitespaces)
        }
        stem = fitting(stem, maxBytes: maxStemBytes)
        return stem.isEmpty ? untitled : stem
    }

    /// `name` cut on a grapheme boundary so it takes at most `maxBytes` in UTF-8, composed or decomposed (some
    /// file systems store names decomposed).
    static func fitting(_ name: String, maxBytes: Int) -> String {
        func size(_ s: Substring) -> Int { max(s.utf8.count, String(s).decomposedStringWithCanonicalMapping.utf8.count) }
        var cut = Substring(name)
        while size(cut) > maxBytes { cut = cut.dropLast() }
        return cut.count == name.count ? name : String(cut).trimmingCharacters(in: .whitespaces)
    }

    /// A free `<stem>.md` (or `<stem> 2.md` …) in `folder`, case-insensitively, against the index and the disk.
    /// `keeping` is the note being named: its own current path counts as free. A file name another note had before
    /// is never given out, in any folder, so wiki links to that name keep finding that note.
    func uniquePath(stem: String, inFolder folder: String, contentRoot: URL, keeping id: UUID? = nil) -> String {
        let dir = folder.isEmpty ? contentRoot : contentRoot.appendingPathComponent(folder, isDirectory: true)
        var taken = Set(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).map { $0.lowercased() })
        lock.withLock {
            for (other, entry) in entries where other != id {
                if entry.folder.lowercased() == folder.lowercased() { taken.insert(entry.fileName.lowercased()) }
                for former in entry.formerPaths where !former.hasPrefix(MarkdownBodyStorage.trashFolder + "/") {
                    taken.insert((former as NSString).lastPathComponent.lowercased())
                }
            }
            if let id, let own = entries[id], own.folder.lowercased() == folder.lowercased() {
                taken.remove(own.fileName.lowercased())
            }
        }
        let name = ExportNaming.unique(stem, extension: "md", taken: &taken)
        return folder.isEmpty ? name : folder + "/" + name
    }

    static func folder(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    // MARK: Persistence

    /// Runs `body` with saving deferred to its end.
    func batch<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        batchDepth += 1
        defer {
            batchDepth -= 1
            if batchDepth == 0, dirty { try? saveLocked() }
            lock.unlock()
        }
        return try body()
    }

    func save() throws {
        try lock.withLock { try saveLocked() }
    }

    private func changed() {
        dirty = true
        guard batchDepth == 0 else { return }
        do { try saveLocked() } catch { NSLog("NoteIt: couldn't save \(Self.fileName): \(error)") }
    }

    private func saveLocked() throws {
        let file = File(version: 1,
                        notes: Dictionary(uniqueKeysWithValues: entries.map { ($0.key.uuidString, $0.value) }),
                        notebooks: Dictionary(uniqueKeysWithValues: notebookFolders.map { ($0.key.uuidString, $0.value) }))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(file).write(to: url, options: .atomic)
        dirty = false
    }

    private func rebuildPaths() {
        byPath = [:]
        for (id, entry) in entries { byPath[entry.path.lowercased()] = id }
    }
}
