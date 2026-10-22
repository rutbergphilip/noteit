import Foundation
import NoteItCore

/// What a background scan read of the files and folders it reported, so that applying the scan on the main thread
/// touches nothing in the content folder. Files are parsed here too, since that reads the attachments they show.
struct MarkdownScanReads: @unchecked Sendable {
    struct File {
        var data: Data
        var read: MarkdownBodyStorage.FileRead
        var stat: MarkdownFileStat?
        var created: Date?
        var modified: Date?
    }

    /// The library as the main thread knew it when the scan started.
    struct Known: Sendable {
        var noteIDs: Set<UUID>
        var notebookIDs: Set<UUID>
        var held: Set<UUID>
    }

    /// Content-relative path → the file's bytes, for changed, moved, added and copied files and for files of
    /// notes the library doesn't list yet; a path that couldn't be read is missing.
    var files: [String: File] = [:]
    /// Folder path → the notebook its `.noteit-notebook.json` describes, for folders not yet known as notebooks.
    var notebookFiles: [String: Notebook] = [:]
    /// Paths of removed notes, held notes and notebook folders that were looked for and are there.
    var existing: Set<String> = []

    static func read(_ result: FolderScanResult, storage: MarkdownBodyStorage, known: Known) -> MarkdownScanReads {
        var reads = MarkdownScanReads()
        let root = storage.contentRootURL
        let index = storage.index
        let entries = index.allEntries
        var paths = Set(result.changed.values).union(result.moved.values).union(result.added).union(result.duplicateIDs)
        for (id, entry) in entries where !known.noteIDs.contains(id) && !result.removed.contains(id) {
            paths.insert(entry.path)
        }
        for path in paths {
            let url = root.appendingPathComponent(path, isDirectory: false)
            guard let data = try? Data(contentsOf: url) else { continue }
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            reads.files[path] = File(data: data, read: storage.readFile(data, notePath: path), stat: MarkdownFileStat.of(url),
                                     created: values?.creationDate, modified: values?.contentModificationDate)
        }

        var seenIDs = Set<UUID>()
        var repeated = Set<UUID>()
        for id in result.notebookFolders.values.compactMap(\.id) where !seenIDs.insert(id).inserted { repeated.insert(id) }
        for (path, info) in result.notebookFolders {
            if let id = info.id, known.notebookIDs.contains(id), !repeated.contains(id) { continue }
            let url = root.appendingPathComponent(path, isDirectory: true)
            if let notebook = try? NotebookFolders.read(url).notebook { reads.notebookFiles[path] = notebook }
        }

        var lookedFor = Set<String>()
        for id in result.removed.union(known.held) {
            if let entry = entries[id] { lookedFor.insert(entry.path) }
        }
        let present = Set(result.notebookFolders.compactMap(\.value.id))
        for (id, path) in index.allNotebookFolders where !present.contains(id) { lookedFor.insert(path) }
        let fm = FileManager.default
        for path in lookedFor where fm.fileExists(atPath: root.appendingPathComponent(path).path) {
            reads.existing.insert(path)
        }
        return reads
    }
}
