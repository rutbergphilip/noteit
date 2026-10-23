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
        /// Notes with an edit in `recovery/`: their files are read so restoring it can tell what it would replace.
        var recovering: Set<UUID> = []
        /// Notes whose copies are restored again after the launch (`NoteStore.retryMarkdownRecovery`), and the
        /// `recovery/` folder their copies are read from.
        var recoveryRetry: Set<UUID> = []
        var recoveryURL: URL?
    }

    /// Content-relative path → the file's bytes, for changed, moved, added and copied files, for files of
    /// notes the library doesn't list yet and of notes with an edit in `recovery/`; a path that couldn't be read is missing.
    var files: [String: File] = [:]
    /// Folder path → the notebook its `.noteit-notebook.json` describes, for folders not yet known as notebooks.
    var notebookFiles: [String: Notebook] = [:]
    /// Paths of removed notes, held notes and notebook folders that were looked for and are there.
    var existing: Set<String> = []
    /// The newest copy in `recovery/` of each note being restored, as read and parsed off the main thread.
    var recoveryCopies: [URL: Result<StoredBody, Error>] = [:]
    /// `Known.recoveryRetry`, and the notes whose copies those are (the keys `NoteStore` restores).
    var recoveryRetry: Set<UUID> = []
    var recoverySources: Set<UUID> = []

    func recoveryCopy(_ url: URL, storage: MarkdownBodyStorage) throws -> StoredBody {
        if let read = recoveryCopies[url] { return try read.get() }
        return try storage.readRecoveryCopy(url)
    }

    static func read(_ result: FolderScanResult, storage: MarkdownBodyStorage, known: Known) -> MarkdownScanReads {
        var reads = MarkdownScanReads()
        let root = storage.contentRootURL
        let index = storage.index
        let entries = index.allEntries
        var paths = Set(result.changed.values).union(result.moved.values).union(result.added).union(result.duplicateIDs)
        for (id, entry) in entries where !known.noteIDs.contains(id) && !result.removed.contains(id) {
            paths.insert(entry.path)
        }
        for id in known.recovering { if let entry = entries[id] { paths.insert(entry.path) } }
        if let directory = known.recoveryURL, !known.recovering.isEmpty || !known.recoveryRetry.isEmpty {
            let groups = Dictionary(grouping: MarkdownBodyStorage.recoveryCopies(in: directory), by: \.id)
            var wanted = Set<UUID>()
            for (id, found) in groups {
                guard let newest = found.max(by: { $0.order < $1.order }) else { continue }
                let recovered = NoteStore.recoveredNoteID(of: id, copy: newest.url)
                guard known.recovering.contains(id) || known.recoveryRetry.contains(id) || known.recoveryRetry.contains(recovered)
                else { continue }
                wanted.formUnion([id, recovered])
                if known.recoveryRetry.contains(id) || known.recoveryRetry.contains(recovered) { reads.recoverySources.insert(id) }
                if let entry = entries[id] { paths.insert(entry.path) }
            }
            for key in wanted {
                guard let newest = groups[key]?.max(by: { $0.order < $1.order }) else { continue }
                reads.recoveryCopies[newest.url] = Result { try storage.readRecoveryCopy(newest.url) }
            }
            reads.recoveryRetry = known.recoveryRetry
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
