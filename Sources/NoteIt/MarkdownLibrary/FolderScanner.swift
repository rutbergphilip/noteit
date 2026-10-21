import Foundation
import NoteItMarkdown

struct NotebookFolderInfo: Equatable, Sendable {
    /// The id in the folder's `.noteit-notebook.json`, nil when it has none (a folder made outside NoteIt).
    var id: UUID?
    var depth: Int
}

struct FolderScanResult: Equatable, Sendable {
    /// id → path; the file's content differs from `markdown-files.json`.
    var changed: [UUID: String] = [:]
    /// Paths of Markdown files without a known id.
    var added: [String] = []
    /// id → new path.
    var moved: [UUID: String] = [:]
    var removed: Set<UUID> = []
    /// Paths of copies whose id another file already has; they must get a new id.
    var duplicateIDs: [String] = []
    /// Content-relative folder path → its notebook id and depth, for folders up to `NotebookFolders.maxDepth`.
    var notebookFolders: [String: NotebookFolderInfo] = [:]
    /// Markdown files seen, Recently Deleted ones excluded.
    var fileCount = 0
    /// More Markdown files than the large-library threshold; the scan still covers them all.
    var largeLibrary = false
    /// Files left alone: too large, symbolic links, and files iCloud hasn't downloaded.
    var skipped: [String] = []

    var hasNoteChanges: Bool {
        !changed.isEmpty || !added.isEmpty || !moved.isEmpty || !removed.isEmpty || !duplicateIDs.isEmpty
    }
}

/// Compares the content folder with `markdown-files.json` (spec §3.5): size, mtime and inode first, the SHA-256
/// only when they differ, so an unchanged library is scanned without reading a file. A file that was only
/// touched gets its new stat recorded in the index; nothing else is changed.
enum FolderScanner {
    static let largeLibraryThreshold = 50_000
    static let maxFileSize: Int64 = 10 * 1024 * 1024
    static let trashFolder = ".trash"

    static func scan(contentRoot: URL, index: MarkdownPathIndex, largeLibraryThreshold: Int = largeLibraryThreshold,
                     maxFileSize: Int64 = maxFileSize) -> FolderScanResult {
        var result = FolderScanResult()
        var files: [(path: String, stat: MarkdownFileStat)] = []
        var placeholders = Set<String>()
        walk(contentRoot, relative: "", depth: 0, result: &result, files: &files, placeholders: &placeholders,
             maxFileSize: maxFileSize)
        result.fileCount = files.count
        result.largeLibrary = files.count > largeLibraryThreshold

        let entries = index.allEntries
        var idByKey: [String: UUID] = [:]
        for (id, entry) in entries { idByKey[key(entry.path)] = id }
        let inodes = Dictionary(entries.map { ($0.value.inode, $0.key) }, uniquingKeysWith: { a, _ in a })

        var seen = Set<UUID>()
        var unknown: [(path: String, stat: MarkdownFileStat)] = []
        for file in files {
            guard let id = idByKey[key(file.path)], let entry = entries[id] else {
                unknown.append(file)
                continue
            }
            seen.insert(id)
            compare(file, id: id, entry: entry, contentRoot: contentRoot, index: index, result: &result)
        }

        var claimed = Set<UUID>()
        for file in unknown {
            let data = try? readData(contentRoot.appendingPathComponent(file.path))
            var id = data.flatMap(frontMatterID)
            if id == nil, let inodeID = inodes[file.stat.inode], file.stat.inode != 0, !seen.contains(inodeID),
               let entry = entries[inodeID], !exists(entry.path, in: contentRoot) {
                id = inodeID
            }
            guard let id else {
                result.added.append(file.path)
                continue
            }
            if let entry = entries[id] {
                if seen.contains(id) || claimed.contains(id) || (exists(entry.path, in: contentRoot) && !isTrash(entry.path)) {
                    result.duplicateIDs.append(file.path)
                    continue
                }
                claimed.insert(id)
                result.moved[id] = file.path
                if let data, AttachmentStore.sha256(data) != entry.sha256 { result.changed[id] = file.path }
            } else if claimed.contains(id) {
                result.duplicateIDs.append(file.path)
            } else {
                claimed.insert(id)
                result.added.append(file.path)
            }
        }

        for (id, entry) in entries where !seen.contains(id) && !claimed.contains(id) {
            if isTrash(entry.path) {
                if !exists(entry.path, in: contentRoot) { result.removed.insert(id) }
            } else if placeholders.contains(key(entry.path)) {
                result.skipped.append(entry.path)
            } else if !exists(entry.path, in: contentRoot) {
                result.removed.insert(id)
            }
        }
        result.added.sort()
        result.duplicateIDs.sort()
        result.skipped.sort()
        return result
    }

    private static func compare(_ file: (path: String, stat: MarkdownFileStat), id: UUID, entry: MarkdownFileEntry,
                                contentRoot: URL, index: MarkdownPathIndex, result: inout FolderScanResult) {
        if file.path != entry.path { result.moved[id] = file.path }
        guard !file.stat.matches(entry) else { return }
        guard let data = try? readData(contentRoot.appendingPathComponent(file.path)) else { return }
        if AttachmentStore.sha256(data) == entry.sha256 {
            index.update(id) { stored in
                stored.size = file.stat.size
                stored.mtimeNs = file.stat.mtimeNs
                stored.inode = file.stat.inode
            }
        } else {
            result.changed[id] = file.path
        }
    }

    private static func walk(_ folder: URL, relative: String, depth: Int, result: inout FolderScanResult,
                             files: inout [(path: String, stat: MarkdownFileStat)], placeholders: inout Set<String>,
                             maxFileSize: Int64) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names.sorted() {
            let path = relative.isEmpty ? name : relative + "/" + name
            if name.hasPrefix(".") {
                if name.hasSuffix(".icloud"), name.count > ".icloud".count + 1 {
                    let original = String(name.dropFirst().dropLast(".icloud".count))
                    if isMarkdown(original) {
                        let placeholder = relative.isEmpty ? original : relative + "/" + original
                        placeholders.insert(key(placeholder))
                    }
                }
                continue
            }
            var info = stat()
            guard lstat(folder.appendingPathComponent(name).path, &info) == 0 else { continue }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                guard NotebookFolders.isNotebookFolderName(name) else { continue }
                if depth + 1 <= NotebookFolders.maxDepth {
                    result.notebookFolders[path] = NotebookFolderInfo(id: notebookID(in: folder.appendingPathComponent(name)),
                                                                      depth: depth + 1)
                }
                walk(folder.appendingPathComponent(name, isDirectory: true), relative: path, depth: depth + 1,
                     result: &result, files: &files, placeholders: &placeholders, maxFileSize: maxFileSize)
            case S_IFREG:
                guard isMarkdown(name) else { continue }
                guard Int64(info.st_size) <= maxFileSize else {
                    result.skipped.append(path)
                    continue
                }
                let ns = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
                files.append((path, MarkdownFileStat(size: Int64(info.st_size), mtimeNs: ns, inode: UInt64(info.st_ino))))
            case S_IFLNK:
                if isMarkdown(name) { result.skipped.append(path) }
            default:
                continue
            }
        }
    }

    static func isMarkdown(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ext == "md" || ext == "markdown"
    }

    /// Case- and normalization-insensitive, as APFS and HFS+ compare names.
    static func key(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }

    static func isTrash(_ path: String) -> Bool {
        path.hasPrefix(trashFolder + "/")
    }

    static func frontMatterID(_ data: Data) -> UUID? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return (try? FrontMatter.read(text))?.0.id
    }

    private static func notebookID(in folder: URL) -> UUID? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(NotebookFolders.fileName)),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (raw["id"] as? String).flatMap(UUID.init(uuidString:))
    }

    private static func readData(_ url: URL) throws -> Data {
        try Data(contentsOf: url, options: .uncached)
    }

    private static func exists(_ path: String, in contentRoot: URL) -> Bool {
        MarkdownFileStat.of(contentRoot.appendingPathComponent(path)) != nil
    }
}
