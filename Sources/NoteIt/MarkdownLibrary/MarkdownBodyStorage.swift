import AppKit
import Darwin
import Foundation
import NoteItCore
import NoteItDoc
import NoteItMarkdown

enum MarkdownStorageError: Error, Equatable {
    /// The file changed on disk since NoteIt last read or wrote it; the external change is handled first.
    case externallyChanged(UUID)
    /// The file can't be read as Markdown, so NoteIt won't change it.
    case unreadable(UUID)
    /// The content folder isn't there.
    case folderMissing
}

/// A Markdown library: one `.md` file per note in the content folder, notebooks as folders, attachments in
/// `_attachments/`, Recently Deleted in `.trash/` (markdown-storage spec §3.3–§3.7). Paths, hashes and folder
/// names are kept in `<data>/markdown-files.json` (`MarkdownPathIndex`).
final class MarkdownBodyStorage: NoteBodyStorage, @unchecked Sendable {
    static let trashFolder = ".trash"
    static let privateFolder = ".noteit"
    static let unreadableReason = "This file can’t be read as Markdown. NoteIt won’t change it."
    static let missingAttachmentsReason =
        "This note shows images or files that aren’t in the folder, so edits to it won’t be saved. The file was left as it is."

    let kind: LibraryFormatKind = .markdown
    let contentRootURL: URL
    let dataDir: URL
    let index: MarkdownPathIndex
    let attachments: AttachmentStore
    let ledger: WriteLedger
    let links: MarkdownLinkResolver
    var renameFilesOnTitleChange: Bool
    /// Moves a file to the macOS Trash; injected by tests.
    var trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    var now: () -> Date = Date.init
    /// Files over 10 MB, from the last scan.
    var skippedFiles: [URL] { lock.withLock { skipped } }

    private let lock = NSRecursiveLock()
    private var notebooks: [UUID: Notebook] = [:]
    private var keepsMissingFolders = false

    /// While the mass-deletion guard holds a batch, notebook folders that went missing aren't recreated.
    func setKeepsMissingFolders(_ keeps: Bool) {
        lock.withLock { keepsMissingFolders = keeps }
    }
    private var previous: [UUID: ParsedMarkdown] = [:]
    private var pendingTemps: [String: String] = [:]
    private var skipped: [URL] = []
    /// Notes whose file was adopted from outside and not written by NoteIt since.
    private var acceptedExternal: Set<UUID> = []

    init(contentRoot: URL, dataDir: URL, renameFilesOnTitleChange: Bool = true, ledger: WriteLedger = WriteLedger()) {
        contentRootURL = contentRoot.standardizedFileURL
        self.dataDir = dataDir
        self.renameFilesOnTitleChange = renameFilesOnTitleChange
        self.ledger = ledger
        index = MarkdownPathIndex(dataDir: dataDir)
        attachments = AttachmentStore(contentRoot: contentRootURL, index: index)
        links = MarkdownLinkResolver(index: index)
    }

    var stagingURL: URL { contentRootURL.appendingPathComponent(Self.privateFolder + "/staging", isDirectory: true) }

    func url(of path: String) -> URL {
        contentRootURL.appendingPathComponent(path, isDirectory: false)
    }

    var contentRootExists: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: contentRootURL.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Nothing is written while the content folder is gone (an unmounted disk): creating it again would put notes
    /// on the wrong volume.
    func requireContentRoot() throws {
        guard contentRootExists else { throw MarkdownStorageError.folderMissing }
    }

    func setSkippedFiles(_ urls: [URL]) {
        lock.withLock { skipped = urls }
    }

    // MARK: Notebooks

    /// The whole notebook tree; folders follow it on the next `reconcileNotebooks()`.
    func setNotebooks(_ list: [Notebook]) {
        lock.withLock { notebooks = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }
    }

    var knownNotebooks: [Notebook] {
        lock.withLock { Array(notebooks.values) }
    }

    func folderOfNotebook(_ id: UUID) -> String? {
        lock.withLock {
            if let recorded = index.notebookFolder(id) { return recorded }
            guard notebooks[id] != nil else { return nil }
            return NotebookFolders.layout(Array(notebooks.values), existing: index.allNotebookFolders)[id]
        }
    }

    /// Creates, renames and moves notebook folders to match the tree, parents first, and writes each folder's
    /// `.noteit-notebook.json`. Folders of notebooks no longer in the tree are left to `removeNotebook`.
    func reconcileNotebooks() throws {
        try lock.withLock {
            try requireContentRoot()
            let tree = Array(notebooks.values)
            var firstError: Error?
            for notebook in tree.sorted(by: { depth(of: $0.id) < depth(of: $1.id) }) {
                do { try placeNotebook(notebook.id, in: tree) } catch { firstError = firstError ?? error }
            }
            if let firstError { throw firstError }
        }
    }

    private func placeNotebook(_ id: UUID, in tree: [Notebook]) throws {
        guard let notebook = notebooks[id] else { return }
        if keepsMissingFolders, let recorded = index.notebookFolder(id), !FileManager.default.fileExists(atPath: url(of: recorded).path) {
            return
        }
        let layout = NotebookFolders.layout(tree, existing: index.allNotebookFolders)
        guard let target = layout[id] else { return }
        let owns = depth(of: id) <= NotebookFolders.maxDepth
        if owns, let old = index.notebookFolder(id), old != target {
            let from = url(of: old), to = url(of: target)
            if FileManager.default.fileExists(atPath: from.path) {
                try Self.move(from, to: to)
            }
            index.moveFolder(old, to: target)
        }
        index.setNotebookFolder(target, for: id)
        guard owns else { return }
        let folder = url(of: target)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let raw = (try? NotebookFolders.read(folder))?.raw ?? [:]
        let wanted = try NotebookFolders.data(for: notebook, raw: raw)
        let file = folder.appendingPathComponent(NotebookFolders.fileName)
        if (try? Data(contentsOf: file)) != wanted {
            try NotebookFolders.write(notebook, raw: raw, to: folder)
        }
    }

    private func depth(of id: UUID) -> Int {
        var depth = 1
        var seen: Set<UUID> = [id]
        var current = notebooks[id]?.parent
        while let parent = current, notebooks[parent] != nil, seen.insert(parent).inserted {
            depth += 1
            current = notebooks[parent]?.parent
        }
        return depth
    }

    func renameNotebook(_ notebook: Notebook, from oldName: String) throws {
        try lock.withLock {
            notebooks[notebook.id] = notebook
            let tree = Array(notebooks.values)
            try placeNotebook(notebook.id, in: tree)
            for child in tree where child.id != notebook.id && isDescendant(child.id, of: notebook.id) {
                try placeNotebook(child.id, in: tree)
            }
        }
    }

    private func isDescendant(_ id: UUID, of ancestor: UUID) -> Bool {
        var seen: Set<UUID> = [id]
        var current = notebooks[id]?.parent
        while let parent = current, seen.insert(parent).inserted {
            if parent == ancestor { return true }
            current = notebooks[parent]?.parent
        }
        return false
    }

    /// Forgets the notebook. Its folder goes to the macOS Trash only when nothing but NoteIt's own file is left in
    /// it; a folder that still holds anything else stays.
    func removeNotebook(_ notebook: Notebook) throws {
        try removeNotebook(id: notebook.id)
    }

    func removeNotebook(id: UUID) throws {
        try lock.withLock {
            notebooks[id] = nil
            guard let path = index.notebookFolder(id) else { return }
            let sharing = index.allNotebookFolders.contains { $0.key != id && $0.value.lowercased() == path.lowercased() }
            if !sharing {
                let folder = url(of: path)
                let items = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
                if FileManager.default.fileExists(atPath: folder.path), Set(items).isSubset(of: [NotebookFolders.fileName, ".DS_Store"]) {
                    try trash(folder)
                }
            }
            index.setNotebookFolder(nil, for: id)
        }
    }

    // MARK: Reading

    func idsOnDisk() -> [UUID] {
        index.ids
    }

    func fileURL(for id: UUID) -> URL {
        if let entry = index.entry(id) { return url(of: entry.path) }
        return contentRootURL.appendingPathComponent(Self.privateFolder + "/missing/\(id.uuidString).md")
    }

    func revisionInputURL(for id: UUID) -> URL? {
        index.entry(id).map { url(of: $0.path) }
    }

    func read(_ id: UUID) throws -> StoredBody {
        guard let entry = index.entry(id) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: fileURL(for: id).path])
        }
        let fileURL = url(of: entry.path)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: fileURL.path])
        }
        let data = try Data(contentsOf: fileURL)
        let result = readFile(data, notePath: entry.path)
        lock.withLock {
            previous[id] = result.parsed
            if let names = result.attachmentNames, names != entry.attachments {
                index.update(id) { $0.attachments = names }
            }
        }
        return result.body
    }

    struct FileRead {
        var body: StoredBody
        var parsed: ParsedMarkdown?
        var attachmentNames: [String]?
    }

    /// A note file's bytes as a body; a file that isn't valid UTF-8 or has front matter that can't be parsed is
    /// shown as plain text and read-only.
    func readFile(_ data: Data, notePath: String) -> FileRead {
        guard let text = String(data: data, encoding: .utf8) else {
            return FileRead(body: StoredBody(text: NSAttributedString(string: String(decoding: data, as: UTF8.self)),
                                             readOnlyReason: Self.unreadableReason))
        }
        do {
            let parsed = try MarkdownCodec.parse(text) { [links] in links.noteID(for: $0, fromNoteAt: notePath) }
            var result = try BodyCodec.libraryBody(from: parsed, notePath: notePath, contentRoot: contentRootURL)
            result.body.extras.frontMatter = parsed.frontMatter.extra.isEmpty ? nil : parsed.frontMatter.extra
            if result.unresolved > 0 { result.body.readOnlyReason = Self.missingAttachmentsReason }
            return FileRead(body: result.body, parsed: parsed, attachmentNames: result.attachmentNames)
        } catch {
            return FileRead(body: StoredBody(text: NSAttributedString(string: text), readOnlyReason: Self.unreadableReason))
        }
    }

    /// Whether `data` is a note file NoteIt may rewrite.
    static func isWritable(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return (try? FrontMatter.read(text)) != nil
    }

    // MARK: Writing

    func write(_ text: NSAttributedString, extras: ContainerExtras, for note: NoteMeta, notebook: Notebook?) throws {
        let temp = try lock.withLock { () -> URL in
            if let notebook { notebooks[notebook.id] = notebook }
            return try prepareTemp(text, extras: extras, meta: note)
        }
        try installTemp(temp, for: note, notebook: notebook)
    }

    func prepareTemp(_ text: NSAttributedString, extras: ContainerExtras, meta: NoteMeta) throws -> URL {
        try requireContentRoot()
        let (path, before) = lock.withLock { (plannedPath(for: meta), previous[meta.id]) }
        let frontMatter = BodyCodec.frontMatter(meta, extras: extras)
        let rendered = try BodyCodec.libraryMarkdown(of: text, extras: extras, frontMatter: frontMatter, notePath: path,
                                                     attachments: attachments, links: links, previous: before)
        try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        let temp = stagingURL.appendingPathComponent("\(UUID().uuidString).md")
        try Self.writeSynced(Data(rendered.text.utf8), to: temp)
        lock.withLock { pendingTemps[temp.lastPathComponent] = path }
        return temp
    }

    func installTemp(_ temp: URL, for note: NoteMeta, notebook: Notebook?) throws {
        defer {
            try? FileManager.default.removeItem(at: temp)
            lock.withLock { pendingTemps[temp.lastPathComponent] = nil }
        }
        try lock.withLock {
            try requireContentRoot()
            if let notebook { notebooks[notebook.id] = notebook }
            let renderedPath = pendingTemps[temp.lastPathComponent]
            let existing = try verifiedFile(note.id)
            let path = try plannedPathCreatingFolders(for: note)
            var data = try Data(contentsOf: temp)
            if let renderedPath, Self.depth(of: renderedPath) != Self.depth(of: path) {
                data = try rerender(data, from: renderedPath, to: path, meta: note)
            }
            try install(data, for: note, at: path, existing: existing, nameTitle: nil)
        }
    }

    private func rerender(_ data: Data, from oldPath: String, to newPath: String, meta: NoteMeta) throws -> Data {
        let read = readFile(data, notePath: oldPath)
        guard read.parsed != nil, read.body.readOnlyReason == nil else { return data }
        let rendered = try BodyCodec.libraryMarkdown(of: read.body.text, extras: read.body.extras,
                                                     frontMatter: BodyCodec.frontMatter(meta, extras: read.body.extras),
                                                     notePath: newPath, attachments: attachments, links: links,
                                                     previous: read.parsed)
        return Data(rendered.text.utf8)
    }

    /// Writes `data` as the note's file at `path`: the existing file is renamed there first when it moves, then
    /// replaced through `.<name>.noteit-tmp`. Skips the write when the bytes are already there.
    private func install(_ data: Data, for meta: NoteMeta, at path: String, existing: Data?, nameTitle: String?) throws {
        let entry = index.entry(meta.id)
        var currentPath = entry?.path
        if let old = currentPath, old != path {
            try Self.move(url(of: old), to: url(of: path))
            index.move(meta.id, to: path)
            currentPath = path
        }
        var data = data
        if acceptedExternal.remove(meta.id) != nil, let existing, onlyDatesDiffer(data, existing: existing) {
            data = existing
        }
        let sha = AttachmentStore.sha256(data)
        if currentPath == nil || existing.map(AttachmentStore.sha256) != sha {
            ledger.record(path: path, sha256: sha)
            try Self.writeAtomically(data, to: url(of: path), replacing: currentPath != nil)
        }
        let read = readFile(data, notePath: path)
        let stat = MarkdownFileStat.of(url(of: path))
        var updated = index.entry(meta.id) ?? MarkdownFileEntry(path: path)
        updated.path = path
        updated.sha256 = sha
        updated.size = stat?.size ?? Int64(data.count)
        updated.mtimeNs = stat?.mtimeNs ?? 0
        updated.inode = stat?.inode ?? 0
        updated.frontMatterExtra = read.parsed.flatMap { $0.frontMatter.extra.isEmpty ? nil : $0.frontMatter.extra }
        updated.attachments = read.attachmentNames ?? updated.attachments
        updated.placement = placement(of: meta, folder: MarkdownPathIndex.folder(of: path), extra: updated.frontMatterExtra)
        if entry == nil || nameTitle != nil { updated.nameTitle = nameTitle ?? meta.title }
        index.set(updated, for: meta.id)
        previous[meta.id] = read.parsed
    }

    /// The bytes of the note's file when it still matches `markdown-files.json` (size, mtime and inode, else its
    /// SHA-256); nil for a note with no file yet. Throws `.externallyChanged` for a changed or missing file and
    /// `.unreadable` for a file NoteIt mustn't rewrite.
    private func verifiedFile(_ id: UUID) throws -> Data? {
        guard let entry = index.entry(id) else { return nil }
        let fileURL = url(of: entry.path)
        guard let stat = MarkdownFileStat.of(fileURL), let data = try? Data(contentsOf: fileURL) else {
            throw MarkdownStorageError.externallyChanged(id)
        }
        if !stat.matches(entry) {
            guard AttachmentStore.sha256(data) == entry.sha256 else { throw MarkdownStorageError.externallyChanged(id) }
            index.update(id) { $0.size = stat.size; $0.mtimeNs = stat.mtimeNs; $0.inode = stat.inode }
        }
        guard Self.isWritable(data) else { throw MarkdownStorageError.unreadable(id) }
        return data
    }

    /// Where the note's file belongs: `.trash/` while it's in Recently Deleted, else its notebook's folder; the
    /// current file name when it stays in that folder, else a free name in it.
    private func plannedPath(for meta: NoteMeta) -> String {
        let folder = targetFolder(for: meta)
        if let entry = index.entry(meta.id) {
            if entry.folder.lowercased() == folder.lowercased() { return entry.path }
            return index.uniquePath(stem: entry.stem, inFolder: folder, contentRoot: contentRootURL, keeping: meta.id)
        }
        return index.uniquePath(stem: MarkdownPathIndex.stem(forTitle: meta.title), inFolder: folder,
                                contentRoot: contentRootURL, keeping: meta.id)
    }

    private func plannedPathCreatingFolders(for meta: NoteMeta) throws -> String {
        if meta.deletedAt == nil, let id = meta.notebookID, notebooks[id] != nil {
            let tree = Array(notebooks.values)
            var chain: [UUID] = []
            var current: UUID? = id
            var seen = Set<UUID>()
            while let next = current, notebooks[next] != nil, seen.insert(next).inserted {
                chain.insert(next, at: 0)
                current = notebooks[next]?.parent
            }
            for notebook in chain { try placeNotebook(notebook, in: tree) }
        }
        let path = plannedPath(for: meta)
        try FileManager.default.createDirectory(at: url(of: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        return path
    }

    private func targetFolder(for meta: NoteMeta) -> String {
        if meta.deletedAt != nil { return Self.trashFolder }
        guard let id = meta.notebookID else { return "" }
        if let recorded = index.notebookFolder(id) { return recorded }
        guard notebooks[id] != nil else { return "" }
        return NotebookFolders.layout(Array(notebooks.values), existing: index.allNotebookFolders)[id] ?? ""
    }

    /// What the note's file was last written for: its folder and front matter.
    private func placement(of meta: NoteMeta, folder: String, extra: String?) -> String {
        folder + "\n" + BodyCodec.frontMatter(meta, extras: ContainerExtras(frontMatter: extra)).written()
    }

    /// True when the note's file is in another folder or its front matter differs from `meta`.
    func needsMetadataWrite(_ meta: NoteMeta) -> Bool {
        lock.withLock {
            guard let entry = index.entry(meta.id) else { return false }
            return entry.placement != placement(of: meta, folder: targetFolder(for: meta), extra: entry.frontMatterExtra)
        }
    }

    /// Moves the file to the note's folder and rewrites its front matter, leaving the body's bytes as they are
    /// (re-rendered only when the folder depth changes and the note refers to attachments). Never creates a file.
    func writeMetadataOnly(for note: NoteMeta, notebook: Notebook?) throws {
        try lock.withLock {
            try requireContentRoot()
            if let notebook { notebooks[notebook.id] = notebook }
            guard let entry = index.entry(note.id) else { return }
            let existing = try verifiedFile(note.id)
            let path = try plannedPathCreatingFolders(for: note)
            guard var data = existing else { return }
            if Self.depth(of: path) != Self.depth(of: entry.path), !entry.attachments.isEmpty {
                data = try rerender(data, from: entry.path, to: path, meta: note)
            }
            try install(Self.patchingFrontMatter(data, with: BodyCodec.frontMatter(note, extras: ContainerExtras(frontMatter: entry.frontMatterExtra))),
                        for: note, at: path, existing: existing, nameTitle: nil)
        }
    }

    /// Whether the idle rename has work for the note.
    func wantsRename(_ meta: NoteMeta) -> Bool {
        guard renameFilesOnTitleChange, meta.deletedAt == nil, let entry = index.entry(meta.id) else { return false }
        return entry.nameTitle != meta.title
    }

    /// Renames the file after the note's title when the library renames files and the title changed since the
    /// name was given. Called by `NoteStore`'s idle rename only.
    @discardableResult
    func renameForTitle(_ meta: NoteMeta) throws -> Bool {
        try lock.withLock {
            try requireContentRoot()
            guard renameFilesOnTitleChange, meta.deletedAt == nil, let entry = index.entry(meta.id),
                  entry.nameTitle != meta.title else { return false }
            let stem = MarkdownPathIndex.stem(forTitle: meta.title)
            guard stem != entry.stem else {
                index.update(meta.id) { $0.nameTitle = meta.title }
                return false
            }
            let existing = try verifiedFile(meta.id)
            let path = index.uniquePath(stem: stem, inFolder: entry.folder, contentRoot: contentRootURL, keeping: meta.id)
            guard let data = existing else { return false }
            try install(data, for: meta, at: path, existing: existing, nameTitle: meta.title)
            return true
        }
    }

    /// `data` with its front matter replaced by `frontMatter`; every byte after it stays as it is.
    static func patchingFrontMatter(_ data: Data, with frontMatter: FrontMatter) -> Data {
        guard let text = String(data: data, encoding: .utf8), let (_, bodyStart) = try? FrontMatter.read(text) else { return data }
        let header = frontMatter.written()
        if bodyStart == text.startIndex {
            return Data((header + (header.isEmpty ? "" : "\n") + text).utf8)
        }
        return Data((header + text[bodyStart...]).utf8)
    }

    // MARK: Outside changes

    /// Takes the file at `path` as the note's file, as a scan found it: after an edit, rename or move outside
    /// NoteIt, or for a new file. The entry moves there (the old path stays in `formerPaths`) and records the file
    /// as it is now. With `assignID`, the note's id is written into the file's front matter first; nothing else in
    /// the file changes. The next body write of the note leaves the file alone when only `created` or `updated` would change.
    struct Adopted {
        var body: StoredBody
        /// Nil for a file that can't be read as Markdown.
        var frontMatter: FrontMatter?
        var modified: Date?
        var created: Date?
    }

    @discardableResult
    func adopt(_ id: UUID, at path: String, assignID: Bool) throws -> Adopted {
        try lock.withLock {
            try requireContentRoot()
            let fileURL = url(of: path)
            let before = MarkdownFileStat.of(fileURL)
            var data = try Data(contentsOf: fileURL)
            if assignID, let text = String(data: data, encoding: .utf8), var frontMatter = try? FrontMatter.read(text).0 {
                frontMatter.id = id
                let patched = Self.patchingFrontMatter(data, with: frontMatter)
                guard MarkdownFileStat.of(fileURL) == before else { throw MarkdownStorageError.externallyChanged(id) }
                ledger.record(path: path, sha256: AttachmentStore.sha256(patched))
                try Self.writeAtomically(patched, to: fileURL, replacing: true)
                data = patched
            }
            if let entry = index.entry(id), entry.path != path {
                index.move(id, to: path)
            }
            let read = readFile(data, notePath: path)
            let stat = MarkdownFileStat.of(fileURL)
            var entry = index.entry(id) ?? MarkdownFileEntry(path: path)
            entry.path = path
            entry.sha256 = AttachmentStore.sha256(data)
            entry.size = stat?.size ?? Int64(data.count)
            entry.mtimeNs = stat?.mtimeNs ?? 0
            entry.inode = stat?.inode ?? 0
            entry.frontMatterExtra = read.parsed.flatMap { $0.frontMatter.extra.isEmpty ? nil : $0.frontMatter.extra }
            entry.attachments = read.attachmentNames ?? entry.attachments
            index.set(entry, for: id)
            previous[id] = read.parsed
            acceptedExternal.insert(id)
            let values = try? fileURL.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            return Adopted(body: read.body, frontMatter: read.parsed?.frontMatter,
                           modified: values?.contentModificationDate, created: values?.creationDate)
        }
    }

    /// After `adopt`: the note's file is taken as written for `meta` (its folder and front matter are not
    /// rewritten until something else changes), and its name as given for `meta.title`.
    func markPlaced(_ meta: NoteMeta) {
        lock.withLock {
            index.update(meta.id) { entry in
                entry.placement = placement(of: meta, folder: targetFolder(for: meta), extra: entry.frontMatterExtra)
                entry.nameTitle = meta.title
            }
        }
    }

    /// The body as NoteIt last read or wrote it, for a file that is gone.
    func lastKnownBody(_ id: UUID) -> StoredBody? {
        lock.withLock {
            guard let parsed = previous[id], let entry = index.entry(id),
                  var result = try? BodyCodec.libraryBody(from: parsed, notePath: entry.path, contentRoot: contentRootURL)
            else { return nil }
            result.body.extras.frontMatter = parsed.frontMatter.extra.isEmpty ? nil : parsed.frontMatter.extra
            return result.body
        }
    }

    /// For a note whose file was deleted outside NoteIt: writes `text` as a new file in `.trash/` for `meta` (in
    /// Recently Deleted), or forgets the file when there's no text to keep.
    func writeDeletedCopy(_ text: NSAttributedString?, extras: ContainerExtras, for meta: NoteMeta) throws {
        try lock.withLock {
            try requireContentRoot()
            guard let entry = index.entry(meta.id) else { return }
            guard let text else {
                index.remove(meta.id)
                previous[meta.id] = nil
                return
            }
            let path = index.uniquePath(stem: entry.stem, inFolder: Self.trashFolder, contentRoot: contentRootURL, keeping: nil)
            let rendered = try BodyCodec.libraryMarkdown(of: text, extras: extras, frontMatter: BodyCodec.frontMatter(meta, extras: extras),
                                                         notePath: path, attachments: attachments, links: links, previous: nil)
            let data = Data(rendered.text.utf8)
            ledger.record(path: path, sha256: AttachmentStore.sha256(data))
            try Self.writeAtomically(data, to: url(of: path), replacing: false)
            index.move(meta.id, to: path)
            let read = readFile(data, notePath: path)
            let stat = MarkdownFileStat.of(url(of: path))
            index.update(meta.id) { stored in
                stored.sha256 = AttachmentStore.sha256(data)
                stored.size = stat?.size ?? Int64(data.count)
                stored.mtimeNs = stat?.mtimeNs ?? 0
                stored.inode = stat?.inode ?? 0
                stored.attachments = read.attachmentNames ?? []
                stored.placement = placement(of: meta, folder: Self.trashFolder, extra: stored.frontMatterExtra)
            }
            previous[meta.id] = read.parsed
        }
    }

    /// Forgets a note whose file is gone, keeping nothing.
    func forget(_ id: UUID) {
        lock.withLock {
            index.remove(id)
            previous[id] = nil
            acceptedExternal.remove(id)
        }
    }

    /// Whether a body write would change only `created` or `updated` in the front matter of a file adopted from
    /// outside; those are written on the next change of the note.
    /// True when the prepared temp file and the note's file have the same text after the front matter.
    func tempHasSameBody(_ temp: URL, as id: UUID) -> Bool {
        guard let entry = index.entry(id), let new = try? Data(contentsOf: temp),
              let old = try? Data(contentsOf: url(of: entry.path)) else { return false }
        return Self.bodies(new, old).map { $0.0 == $0.1 } ?? false
    }

    private static func bodies(_ data: Data, _ existing: Data) -> ((FrontMatter, Substring), (FrontMatter, Substring))? {
        guard let new = String(data: data, encoding: .utf8), let old = String(data: existing, encoding: .utf8),
              let newRead = try? FrontMatter.read(new), let oldRead = try? FrontMatter.read(old) else { return nil }
        func body(_ text: String, _ start: String.Index) -> Substring {
            var rest = text[start...]
            if start != text.startIndex, rest.first == "\n" { rest = rest.dropFirst() }
            return rest
        }
        return ((newRead.0, body(new, newRead.1)), (oldRead.0, body(old, oldRead.1)))
    }

    private func onlyDatesDiffer(_ data: Data, existing: Data) -> Bool {
        guard let ((newFrontMatter, newBody), (oldFrontMatter, oldBody)) = Self.bodies(data, existing) else { return false }
        var newFM = newFrontMatter, oldFM = oldFrontMatter
        guard newBody == oldBody else { return false }
        newFM.created = nil
        newFM.updated = nil
        oldFM.created = nil
        oldFM.updated = nil
        return newFM.written() == oldFM.written()
    }

    // MARK: Recently Deleted and removal

    /// The note leaves the library: its file goes to `.trash/` (with `deleted:`) if it isn't there yet and stays
    /// there, and the note is dropped from `markdown-files.json`.
    func moveToTrash(_ id: UUID) throws {
        try lock.withLock {
            try requireContentRoot()
            guard let entry = index.entry(id) else { return }
            let file = url(of: entry.path)
            guard FileManager.default.fileExists(atPath: file.path) else {
                index.remove(id)
                previous[id] = nil
                return
            }
            var path = entry.path
            if entry.folder != Self.trashFolder {
                path = index.uniquePath(stem: entry.stem, inFolder: Self.trashFolder, contentRoot: contentRootURL, keeping: nil)
                try FileManager.default.createDirectory(at: url(of: Self.trashFolder), withIntermediateDirectories: true)
                try Self.move(file, to: url(of: path))
            }
            let trashed = url(of: path)
            if let data = try? Data(contentsOf: trashed), let text = String(data: data, encoding: .utf8),
               var frontMatter = try? FrontMatter.read(text).0, frontMatter.deleted == nil {
                frontMatter.deleted = now()
                let patched = Self.patchingFrontMatter(data, with: frontMatter)
                ledger.record(path: path, sha256: AttachmentStore.sha256(patched))
                try Self.writeAtomically(patched, to: trashed, replacing: true)
            }
            index.remove(id)
            previous[id] = nil
        }
    }

    /// The newest file in `.trash/` with the note's id.
    func recover(_ id: UUID) throws -> StoredBody? {
        let folder = url(of: Self.trashFolder)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var best: (deleted: Date, mtime: Int64, url: URL, data: Data)?
        for name in names where !name.hasPrefix(".") && ["md", "markdown"].contains((name as NSString).pathExtension.lowercased()) {
            let file = folder.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8),
                  let frontMatter = try? FrontMatter.read(text).0, frontMatter.id == id else { continue }
            let candidate = (frontMatter.deleted ?? .distantPast, MarkdownFileStat.of(file)?.mtimeNs ?? 0, file, data)
            if best.map({ ($0.deleted, $0.mtime) < (candidate.0, candidate.1) }) ?? true { best = candidate }
        }
        guard let best else { return nil }
        return readFile(best.data, notePath: Self.trashFolder + "/" + best.url.lastPathComponent).body
    }

    /// Moves the note's file to the macOS Trash (never deletes it).
    func removePermanently(_ id: UUID) throws {
        try lock.withLock {
            try requireContentRoot()
            guard let entry = index.entry(id) else { return }
            let file = url(of: entry.path)
            if FileManager.default.fileExists(atPath: file.path) { try trash(file) }
            index.remove(id)
            previous[id] = nil
        }
    }

    func recoveryCopy(_ text: NSAttributedString, for id: UUID, in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = RTFDBodyStorage.uniqueURL(directory.appendingPathComponent("\(id.uuidString)-\(RTFDBodyStorage.timestamp()).md"))
        let container = try BodyCodec.noteItDoc(of: text, imagePolicy: .keepOriginal)
        let folder = directory.appendingPathComponent(AttachmentPaths.folder, isDirectory: true)
        for (sha, attachment) in container.attachments {
            let file = folder.appendingPathComponent(AttachmentPaths.fileName(sha256: sha, originalName: attachment.name))
            guard !FileManager.default.fileExists(atPath: file.path) else { continue }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try attachment.data.write(to: file, options: .atomic)
        }
        var markdown = MarkdownCodec.serialize(container, frontMatter: FrontMatter(id: id), profile: .library, attachmentPath: { sha in
            AttachmentPaths.folder + "/" + AttachmentPaths.fileName(sha256: sha, originalName: container.attachments[sha]?.name ?? "")
        }, noteLinkName: { [links] in links.target(for: $0) }, previous: nil)
        if !markdown.hasSuffix("\n") { markdown += "\n" }
        try Self.writeAtomically(Data(markdown.utf8), to: url, replacing: false)
        return url
    }

    // MARK: Files

    static func depth(of path: String) -> Int {
        path.split(separator: "/").count
    }

    /// Writes `data` to `.<name>.noteit-tmp` beside `url`, fsyncs it and renames it over `url`. Without
    /// `replacing`, fails rather than replace a file that appeared at `url`.
    static func writeAtomically(_ data: Data, to url: URL, replacing: Bool) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temp = folder.appendingPathComponent(".\(url.lastPathComponent).noteit-tmp")
        try writeSynced(data, to: temp)
        do {
            let result = replacing ? rename(temp.path, url.path) : renamex_np(temp.path, url.path, UInt32(RENAME_EXCL))
            if result != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    static func writeSynced(_ data: Data, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var finished = false
        defer {
            close(fd)
            if !finished { unlink(url.path) }
        }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                offset += written
            }
        }
        guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        finished = true
    }

    /// Renames `from` to `to`, never over an existing item; a change of case only is a plain rename.
    static func move(_ from: URL, to: URL) throws {
        guard from.standardizedFileURL.path != to.standardizedFileURL.path else { return }
        try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        let caseOnly = from.standardizedFileURL.path.lowercased() == to.standardizedFileURL.path.lowercased()
        let result = caseOnly ? rename(from.path, to.path) : renamex_np(from.path, to.path, UInt32(RENAME_EXCL))
        if result != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
