import AppKit
import Foundation
import NoteItCore
import NoteItMarkdown

/// What the conversion sheet needs to know about a folder before converting into it (spec §3.6).
struct FolderInspection: Equatable {
    enum CloudService: Equatable {
        case iCloudDrive, dropbox, oneDrive, googleDrive
        case other(String)

        var name: String {
            switch self {
            case .iCloudDrive: return "iCloud Drive"
            case .dropbox: return "Dropbox"
            case .oneDrive: return "OneDrive"
            case .googleDrive: return "Google Drive"
            case .other(let name): return name
            }
        }
    }

    var markdownFileCount: Int
    var isEmpty: Bool
    /// From the folder's `.noteit/library.json`, when NoteIt used it before.
    var libraryID: UUID?
    var cloudService: CloudService?
    var overlapsLibrary: Bool

    /// A folder with Markdown files is adopted: its files keep their names (spec §3.4).
    var adopts: Bool { markdownFileCount > 0 }
}

enum LibraryConversionError: Error, Equatable {
    case destinationOverlapsLibrary
    case alreadyInFormat
    case folderMissing
    case notEnoughSpace(needed: Int64, available: Int64)
    /// Notes whose staged copy doesn't read back the same; nothing outside staging was changed.
    case notRoundTripping([UUID])
    /// A note or notebook changed while converting; nothing was switched.
    case libraryChangedDuringConversion
    /// A file NoteIt would write is already in the folder with other contents.
    case fileInTheWay(String)
    case failed(String)
}

/// `<data>/library-conversion.json`: what a running conversion has done, so a crash can be finished or undone
/// at the next launch (`finishInterrupted`).
struct LibraryConversionJournal: Codable, Equatable {
    static let fileName = "library-conversion.json"

    enum Direction: String, Codable {
        case toMarkdown, toRTFD
    }

    struct Move: Codable, Equatable {
        var path: String
        var sha256: String
    }

    var direction: Direction
    var libraryID: UUID
    var contentRoot: String
    /// Absolute paths of the staging folders.
    var contentStaging: String?
    var dataStaging: String
    /// Files moved into the content folder, relative to it.
    var moves: [Move] = []
    /// Folders created in the content folder, relative to it, parents first.
    var createdFolders: [String] = []
    var wroteLibraryFile = false
    var installedIndex = false
    /// Folders moved into the data folder (`notes`, `body-extras`).
    var movedIntoData: [String] = []
    /// What was moved into those folders, relative to the data folder, with `RTFDBodyStorage.packageDigest`, so a
    /// rollback removes only items that still hold it. Nil in journals written before it was kept: nothing goes.
    var dataMoves: [Move]?
    /// Whether `library-location.json` existed before the conversion. When it did, a missing file is never taken
    /// as "not committed": something else removed it. Nil in older journals, which are treated as true.
    var locationFileExisted: Bool?
    /// Files of this library from an earlier conversion that the new files replace, relative to the content folder,
    /// with their SHA-256; they are moved to `replacedFolder` before the new files go in, back on rollback, and to the
    /// Trash once the conversion is committed.
    var replaced: [Move]?
    /// `.noteit/replaced-<time>`, relative to the content folder.
    var replacedFolder: String?
    /// Set right after the location file is written; from then on the conversion is only ever finished.
    var committed = false

    static func url(dataDir: URL) -> URL { dataDir.appendingPathComponent(fileName) }

    static func load(dataDir: URL) -> LibraryConversionJournal? {
        guard let data = try? Data(contentsOf: url(dataDir: dataDir)) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func save(dataDir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(self).write(to: Self.url(dataDir: dataDir), options: .atomic)
    }
}

/// Converts a library between RTFD and a Markdown folder (markdown-storage Task 5.1, spec §3.6). Bodies are
/// written to staging and read back before anything is moved; writing `library-location.json` is the commit point.
/// Nothing in the user's folder or the old library is deleted before the new library is committed, and the old
/// RTFD bodies are kept as a previous library afterwards.
@MainActor
final class LibraryConverter {
    enum Target: Equatable {
        case markdown(URL)
        case rtfd
    }

    /// The test hook stops after one of these as a crash would.
    enum Step: CaseIterable {
        case staged, verified, moved, committed
    }

    struct Interrupted: Error {
        let step: Step
    }

    struct Result {
        var location: LibraryLocation
        var previousLibrary: URL?
        /// Files of this library that were changed outside NoteIt and are kept beside NoteIt's version under a new
        /// name and id, relative to the Markdown folder.
        var conflictCopies: [String] = []
    }

    nonisolated static func moveToTrash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    nonisolated static let libraryFileName = "library.json"
    nonisolated static let libraryFileFormat = "noteit-markdown"

    let store: NoteStore
    var dataDir: URL { store.rootURL }
    var pauseSync: () async -> Void = { await SyncController.shared.suspendForLibraryConversion() }
    var resumeSync: () -> Void = { SyncController.shared.resumeAfterLibraryConversion() }
    var flush: (NoteStore) -> Void = { $0.flush() }
    var availableSpace: (URL) -> Int64? = LibraryConverter.availableSpace
    /// Whether a staged body reads back as the source; `BodyCodec.semanticallyEqual` by default.
    var verify: (UUID, NSAttributedString, NSAttributedString) -> Bool = { _, a, b in BodyCodec.semanticallyEqual(a, b) }
    var interruption: Step?
    var now: () -> Date = Date.init
    var trash: (URL) throws -> Void = LibraryConverter.moveToTrash
    /// Notes converted so far, of all.
    var progress: ((Int, Int) -> Void)?

    init(store: NoteStore) {
        self.store = store
    }

    // MARK: Inspecting a folder

    nonisolated static func inspect(_ folder: URL, dataDir: URL) -> FolderInspection {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0 != ".DS_Store" }
        return FolderInspection(markdownFileCount: countMarkdownFiles(in: folder), isEmpty: names.isEmpty,
                                libraryID: libraryFileID(in: folder), cloudService: cloudService(of: folder),
                                overlapsLibrary: overlapsLibrary(folder, dataDir: dataDir))
    }

    nonisolated private static func countMarkdownFiles(in folder: URL) -> Int {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return 0 }
        var count = 0
        for name in names where !name.hasPrefix(".") {
            var info = stat()
            let url = folder.appendingPathComponent(name)
            guard lstat(url.path, &info) == 0 else { continue }
            switch info.st_mode & S_IFMT {
            case S_IFDIR: count += countMarkdownFiles(in: url)
            case S_IFREG: if FolderScanner.isMarkdown(name) { count += 1 }
            default: continue
            }
        }
        return count
    }

    nonisolated static func libraryFileURL(in folder: URL) -> URL {
        folder.appendingPathComponent(MarkdownBodyStorage.privateFolder, isDirectory: true)
            .appendingPathComponent(libraryFileName)
    }

    nonisolated static func libraryFileID(in folder: URL) -> UUID? {
        guard let data = try? Data(contentsOf: libraryFileURL(in: folder)),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              raw["format"] as? String == libraryFileFormat else { return nil }
        return (raw["libraryID"] as? String).flatMap(UUID.init(uuidString:))
    }

    nonisolated static func libraryFileData(libraryID: UUID) -> Data {
        Data("{\"format\":\"\(libraryFileFormat)\",\"libraryID\":\"\(libraryID.uuidString)\",\"version\":1}\n".utf8)
    }

    /// iCloud Drive, a File Provider folder in `~/Library/CloudStorage`, or a Dropbox folder.
    nonisolated static func cloudService(of folder: URL) -> FolderInspection.CloudService? {
        let parts = folder.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        for index in parts.indices.dropLast() where parts[index] == "Library" {
            if parts[index + 1] == "Mobile Documents" { return .iCloudDrive }
            if parts[index + 1] == "CloudStorage", index + 2 < parts.count {
                let provider = parts[index + 2]
                if provider.hasPrefix("Dropbox") { return .dropbox }
                if provider.hasPrefix("OneDrive") { return .oneDrive }
                if provider.hasPrefix("GoogleDrive") { return .googleDrive }
                if provider.hasPrefix("iCloud") { return .iCloudDrive }
                return .other(provider.components(separatedBy: "-").first ?? provider)
            }
        }
        var current = folder.resolvingSymlinksInPath().standardizedFileURL
        while current.pathComponents.count > 1 {
            if current.lastPathComponent == "Dropbox",
               FileManager.default.fileExists(atPath: current.appendingPathComponent(".dropbox").path) {
                return .dropbox
            }
            current.deleteLastPathComponent()
        }
        return nil
    }

    /// The folders a content folder may not be equal to, inside, or contain (spec §3.6).
    nonisolated static func managedFolders(dataDir: URL) -> [URL] {
        [dataDir] + ["notes", "backups", "sync-meta-raw", "body-extras", "history"].map {
            dataDir.appendingPathComponent($0, isDirectory: true)
        }
    }

    /// Compared by path components after resolving symlinks and standardising, ignoring case as APFS does.
    nonisolated static func overlapsLibrary(_ folder: URL, dataDir: URL) -> Bool {
        func components(_ url: URL) -> [String] {
            url.resolvingSymlinksInPath().standardizedFileURL.pathComponents.map { $0.lowercased() }
        }
        let candidate = components(folder)
        return managedFolders(dataDir: dataDir).contains { managed in
            let parts = components(managed)
            return candidate.starts(with: parts) || parts.starts(with: candidate)
        }
    }

    nonisolated static func availableSpace(_ url: URL) -> Int64? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe.deleteLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    nonisolated static func size(of url: URL, skippingPrivateFolder: Bool = false) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            if skippingPrivateFolder, file.lastPathComponent == MarkdownBodyStorage.privateFolder,
               file.deletingLastPathComponent().standardizedFileURL == url.standardizedFileURL {
                enumerator.skipDescendants()
                continue
            }
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }

    // MARK: Converting

    func convert(to target: Target) async throws -> Result {
        switch target {
        case .markdown(let folder):
            if Self.overlapsLibrary(folder, dataDir: dataDir) { throw LibraryConversionError.destinationOverlapsLibrary }
            guard store.bodyStorage.kind == .rtfd else { throw LibraryConversionError.alreadyInFormat }
        case .rtfd:
            guard let storage = store.markdownStorage else { throw LibraryConversionError.alreadyInFormat }
            guard storage.contentRootExists else { throw LibraryConversionError.folderMissing }
        }
        flush(store)
        store.libraryConversionInProgress = true
        await pauseSync()
        do {
            let result: Result
            switch target {
            case .markdown(let folder): result = try await convertToMarkdown(folder.standardizedFileURL)
            case .rtfd: result = try await convertToRTFD()
            }
            return result
        } catch let interrupted as Interrupted {
            throw interrupted
        } catch {
            if !store.isClosedForLibrarySwitch {
                Self.finishInterrupted(dataDir: dataDir, trash: trash)
                store.libraryConversionInProgress = false
                resumeSync()
            }
            throw error
        }
    }

    private func stop(after step: Step) throws {
        if interruption == step { throw Interrupted(step: step) }
    }

    private var timestamp: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: now())
    }

    private struct Snapshot: Equatable {
        var notes: [NoteMeta]
        var notebooks: [Notebook]
    }

    private var snapshot: Snapshot { Snapshot(notes: store.notes, notebooks: store.notebooks) }

    /// Called before moving and again right before the commit.
    private func requireUnchanged(since before: Snapshot) throws {
        // Edits saved by other apps reach the store through the watcher's debounce, which can't run in between.
        guard store.rescanMarkdownFolder() else { throw LibraryConversionError.folderMissing }
        flush(store)
        guard snapshot == before, !store.hasUnsavedChanges else { throw LibraryConversionError.libraryChangedDuringConversion }
    }

    private func requireSpace(_ needed: Int64, at url: URL) throws {
        guard let available = availableSpace(url) else { return }
        if available < needed { throw LibraryConversionError.notEnoughSpace(needed: needed, available: available) }
    }

    private func reportProgress(_ done: Int, of total: Int) async {
        progress?(done, total)
        if done % 25 == 0 { await Task.yield() }
    }

    // MARK: RTFD → Markdown

    private func convertToMarkdown(_ folder: URL) async throws -> Result {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let inspection = Self.inspect(folder, dataDir: dataDir)
        let rtfdSize = Self.size(of: dataDir.appendingPathComponent("notes", isDirectory: true))
        try requireSpace(rtfdSize * 2 + 10_000_000, at: folder)
        let before = snapshot
        let libraryID = inspection.libraryID ?? Self.currentLibraryID(dataDir: dataDir) ?? UUID()

        let stamp = "convert-\(timestamp)"
        let privateFolder = folder.appendingPathComponent(MarkdownBodyStorage.privateFolder, isDirectory: true)
        let contentStaging = privateFolder.appendingPathComponent("staging/\(stamp)", isDirectory: true)
        let dataStaging = dataDir.appendingPathComponent("backups/staging-\(stamp)", isDirectory: true)
        var journal = LibraryConversionJournal(direction: .toMarkdown, libraryID: libraryID, contentRoot: folder.path,
                                               contentStaging: contentStaging.path, dataStaging: dataStaging.path)
        journal.locationFileExisted = Self.exists(LibraryLocationFile.url(dataDir: dataDir))
        if !fm.fileExists(atPath: privateFolder.path) { journal.createdFolders.append(MarkdownBodyStorage.privateFolder) }
        try journal.save(dataDir: dataDir)
        try fm.createDirectory(at: contentStaging, withIntermediateDirectories: true)
        try fm.createDirectory(at: dataStaging, withIntermediateDirectories: true)

        // 3. Stage. Placeholders for the folder's own files keep staged names clear of them; files and notebook
        // folders this library wrote there before keep their places.
        var placeholders = try mirrorNames(of: folder, into: contentStaging)
        let staging = MarkdownBodyStorage(contentRoot: contentStaging, dataDir: dataStaging, renameFilesOnTitleChange: false)
        staging.trash = { _ in }
        staging.setNotebooks(store.notebooks)
        let earlier = Self.libraryFiles(in: folder)
        let reusedFolders = Self.reusableNotebookFolders(earlier.notebooks, tree: store.notebooks)
        for (id, path) in reusedFolders { staging.index.setNotebookFolder(path, for: id) }
        try staging.reconcileNotebooks()
        var setAside = Set(earlier.notebooks.filter { reusedFolders[$0.id] == nil && store.notebook(with: $0.id) != nil }
            .map { $0.path + "/" + NotebookFolders.fileName })
        let written = EarlierMarkdownFiles.load(dataDir: dataDir)
        var reusedFiles: [UUID: String] = [:]
        for (id, files) in Dictionary(grouping: earlier.notes, by: \.id) where store.note(with: id) != nil {
            reusedFiles[id] = (files.first { $0.path == written[id]?.path } ?? files[0]).path
        }
        for file in earlier.notes {
            if let note = store.note(with: file.id), reusedFiles[file.id] == file.path {
                var entry = MarkdownFileEntry(path: file.path)
                entry.nameTitle = note.title
                staging.index.set(entry, for: file.id)
                staging.allowRecreatingMissingFile(file.id)
                try? fm.removeItem(at: contentStaging.appendingPathComponent(file.path))
                placeholders.removeAll { $0 == file.path }
            } else if store.note(with: file.id) != nil || store.isTombstoned(file.id) {
                setAside.insert(file.path)
            }
        }
        var failed: [UUID] = []
        var sources: [UUID: StoredBody] = [:]
        let notes = store.notes
        for (offset, note) in notes.enumerated() {
            let source: StoredBody
            do {
                source = try store.readStoredBody(note.id)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                source = StoredBody(text: NSAttributedString())
            } catch {
                failed.append(note.id)
                continue
            }
            guard source.readOnlyReason == nil else {
                failed.append(note.id)
                continue
            }
            sources[note.id] = source
            try staging.write(source.text, extras: source.extras, for: note, notebook: store.notebook(with: note.notebookID))
            await reportProgress(offset + 1, of: notes.count)
        }
        // Links to notes staged later were written as noteit:// links; now they can be written by name.
        for note in notes {
            guard let source = sources[note.id],
                  let data = try? Data(contentsOf: staging.fileURL(for: note.id)),
                  data.range(of: Data("noteit://note".utf8)) != nil else { continue }
            try staging.write(source.text, extras: source.extras, for: note, notebook: store.notebook(with: note.notebookID))
        }
        for (id, path) in reusedFiles where staging.index.entry(id)?.path != path { setAside.insert(path) }
        try staging.index.save()
        try removePlaceholders(placeholders, in: contentStaging)
        try stop(after: .staged)

        // 4. Verify.
        for note in notes {
            guard let source = sources[note.id] else { continue }
            guard let staged = try? staging.read(note.id), staged.readOnlyReason == nil,
                  staged.extras == source.extras, verify(note.id, source.text, staged.text) else {
                failed.append(note.id)
                continue
            }
        }
        if !failed.isEmpty { throw LibraryConversionError.notRoundTripping(failed) }
        try stop(after: .verified)
        try requireUnchanged(since: before)

        // 5. Move into place. This library's earlier files that differ go aside first; one that holds what neither
        // NoteIt wrote there nor would write now is kept beside it as a copy with a new id.
        let files = Self.stagedFiles(in: contentStaging)
        var planned: [LibraryConversionJournal.Move] = []
        var replacing = setAside
        for path in files {
            let staged = contentStaging.appendingPathComponent(path)
            let target = folder.appendingPathComponent(path)
            let sha = AttachmentStore.sha256(try Data(contentsOf: staged))
            if Self.exists(target) {
                guard !Self.isDirectory(target), let existing = try? Data(contentsOf: target) else {
                    throw LibraryConversionError.fileInTheWay(path)
                }
                if AttachmentStore.sha256(existing) == sha {
                    replacing.remove(path)
                    continue
                }
                guard Self.isReplaceable(path, existing: existing, staged: staged, setAside: setAside) else {
                    throw LibraryConversionError.fileInTheWay(path)
                }
                replacing.insert(path)
            }
            planned.append(.init(path: path, sha256: sha))
        }
        var replaced: [LibraryConversionJournal.Move] = []
        var conflictCopies: [String] = []
        var taken = Set(files.map { $0.lowercased() })
        for path in replacing.sorted() {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(path)) else { continue }
            let sha = AttachmentStore.sha256(data)
            replaced.append(.init(path: path, sha256: sha))
            guard FolderScanner.isMarkdown(path), let id = FolderScanner.frontMatterID(data),
                  sha != written[id]?.sha256,
                  sha != (try? Data(contentsOf: staging.fileURL(for: id))).map(AttachmentStore.sha256) else { continue }
            let copy = Self.conflictCopyPath(for: path, in: folder, staging: contentStaging, taken: taken)
            taken.insert(copy.lowercased())
            let copyData = Self.withNewID(data)
            let stagedCopy = contentStaging.appendingPathComponent(copy)
            try fm.createDirectory(at: stagedCopy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try copyData.write(to: stagedCopy)
            planned.append(.init(path: copy, sha256: AttachmentStore.sha256(copyData)))
            conflictCopies.append(copy)
        }
        let replacedFolder = MarkdownBodyStorage.privateFolder + "/replaced-\(stamp)"
        if !replaced.isEmpty {
            journal.replaced = replaced
            journal.replacedFolder = replacedFolder
        }
        journal.moves = planned
        try journal.save(dataDir: dataDir)
        for move in replaced {
            let aside = folder.appendingPathComponent(replacedFolder).appendingPathComponent(move.path)
            try fm.createDirectory(at: aside.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: folder.appendingPathComponent(move.path), to: aside)
        }
        for move in planned {
            let target = folder.appendingPathComponent(move.path)
            try createFolders(for: move.path, in: folder, journal: &journal)
            try fm.moveItem(at: contentStaging.appendingPathComponent(move.path), to: target)
        }
        let libraryFile = Self.libraryFileURL(in: folder)
        let libraryData = Self.libraryFileData(libraryID: libraryID)
        if (try? Data(contentsOf: libraryFile)) != libraryData {
            journal.wroteLibraryFile = true
            try journal.save(dataDir: dataDir)
            try libraryData.write(to: libraryFile, options: .atomic)
        }
        try stop(after: .moved)

        // 6. Commit.
        try requireUnchanged(since: before)
        let index = dataDir.appendingPathComponent(MarkdownPathIndex.fileName)
        journal.installedIndex = true
        try journal.save(dataDir: dataDir)
        if fm.fileExists(atPath: index.path) {
            _ = try fm.replaceItemAt(index, withItemAt: dataStaging.appendingPathComponent(MarkdownPathIndex.fileName))
        } else {
            try fm.moveItem(at: dataStaging.appendingPathComponent(MarkdownPathIndex.fileName), to: index)
        }
        let location = LibraryLocationFile(format: .markdown, path: LibraryLocationFile.displayPath(folder),
                                           bookmark: try? folder.bookmarkData(), libraryID: libraryID,
                                           renameFilesOnTitleChange: !inspection.adopts)
        try location.write(dataDir: dataDir)
        journal.committed = true
        try? journal.save(dataDir: dataDir)
        store.closeForLibrarySwitch()
        try stop(after: .committed)

        // 7. Keep the RTFD bodies as the previous library.
        let previous = Self.finishCommitted(journal, dataDir: dataDir, now: now(), trash: trash)
        return Result(location: LibraryLocation(url: dataDir, seedsFreshLibrary: false, format: .markdown, contentRootURL: folder,
                                                renameFilesOnTitleChange: !inspection.adopts),
                      previousLibrary: previous, conflictCopies: conflictCopies)
    }

    /// Empty files and folders in `staging` for every name in `folder`, so staged names don't clash with them.
    private func mirrorNames(of folder: URL, into staging: URL, relative: String = "") throws -> [String] {
        let fm = FileManager.default
        var created: [String] = []
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names {
            if relative.isEmpty, name == MarkdownBodyStorage.privateFolder { continue }
            if name == NotebookFolders.fileName { continue }
            let path = relative.isEmpty ? name : relative + "/" + name
            let source = folder.appendingPathComponent(name)
            let mirror = staging.appendingPathComponent(path)
            var info = stat()
            guard lstat(source.path, &info) == 0 else { continue }
            if info.st_mode & S_IFMT == S_IFDIR {
                try fm.createDirectory(at: mirror, withIntermediateDirectories: true)
                created += try mirrorNames(of: source, into: staging, relative: path)
            } else if !fm.fileExists(atPath: mirror.path) {
                try Data().write(to: mirror)
                created.append(path)
            }
        }
        return created
    }

    private func removePlaceholders(_ paths: [String], in staging: URL) throws {
        for path in paths {
            let url = staging.appendingPathComponent(path)
            guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
                  size.int64Value == 0 else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Every file in staging except the staging storage's own `.noteit/`, relative to it, sorted.
    nonisolated private static func stagedFiles(in staging: URL, relative: String = "") -> [String] {
        let fm = FileManager.default
        var files: [String] = []
        let folder = relative.isEmpty ? staging : staging.appendingPathComponent(relative, isDirectory: true)
        for name in ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() {
            if relative.isEmpty, name == MarkdownBodyStorage.privateFolder { continue }
            let path = relative.isEmpty ? name : relative + "/" + name
            if isDirectory(folder.appendingPathComponent(name)) {
                files += stagedFiles(in: staging, relative: path)
            } else {
                files.append(path)
            }
        }
        return files
    }

    private func createFolders(for path: String, in root: URL, journal: inout LibraryConversionJournal) throws {
        var relative = ""
        for component in path.split(separator: "/").dropLast() {
            relative = relative.isEmpty ? String(component) : relative + "/" + component
            let url = root.appendingPathComponent(relative, isDirectory: true)
            guard !Self.exists(url) else { continue }
            journal.createdFolders.append(relative)
            try journal.save(dataDir: dataDir)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        }
    }

    nonisolated private static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    nonisolated private static func isDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    nonisolated static func currentLibraryID(dataDir: URL) -> UUID? {
        if case .loaded(let file) = LibraryLocationFile.load(dataDir: dataDir, setsAsideDamaged: false, log: { _ in }) {
            return file.libraryID
        }
        return nil
    }

    // MARK: Markdown → RTFD

    private func convertToRTFD() async throws -> Result {
        let fm = FileManager.default
        guard let storage = store.markdownStorage else { throw LibraryConversionError.alreadyInFormat }
        let folder = storage.contentRootURL
        try requireSpace(Self.size(of: folder, skippingPrivateFolder: true) * 3 + 10_000_000, at: dataDir)
        let before = snapshot
        let libraryID = Self.currentLibraryID(dataDir: dataDir) ?? Self.libraryFileID(in: folder) ?? UUID()
        let dataStaging = dataDir.appendingPathComponent("backups/staging-convert-\(timestamp)", isDirectory: true)
        var journal = LibraryConversionJournal(direction: .toRTFD, libraryID: libraryID, contentRoot: folder.path,
                                               contentStaging: nil, dataStaging: dataStaging.path)
        journal.locationFileExisted = Self.exists(LibraryLocationFile.url(dataDir: dataDir))
        try journal.save(dataDir: dataDir)
        let staging = RTFDBodyStorage(rootURL: dataStaging)
        let extrasFolder = dataStaging.appendingPathComponent("body-extras", isDirectory: true)
        try fm.createDirectory(at: staging.contentRootURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: extrasFolder, withIntermediateDirectories: true)

        // 3. Stage.
        var failed: [UUID] = []
        var sources: [UUID: StoredBody] = [:]
        let notes = store.notes
        for (offset, note) in notes.enumerated() {
            guard let source = try? store.readStoredBody(note.id), source.readOnlyReason == nil else {
                failed.append(note.id)
                continue
            }
            sources[note.id] = source
            try staging.write(source.text, extras: source.extras, for: note, notebook: nil)
            let entry = BodyExtrasEntry(bodySHA256: try RTFDBodyStorage.packageDigest(at: staging.fileURL(for: note.id)),
                                        extras: source.extras, codeLanguageIDs: NoteStore.codeLanguageIDs(of: source.text))
            if !entry.isEmpty {
                try BodyExtrasSidecar(current: entry, previous: nil).encoded()
                    .write(to: extrasFolder.appendingPathComponent("\(note.id.uuidString).json"), options: .atomic)
            }
            await reportProgress(offset + 1, of: notes.count)
        }
        try stop(after: .staged)

        // 4. Verify.
        for note in notes {
            guard let source = sources[note.id] else { continue }
            guard let read = try? staging.read(note.id) else {
                failed.append(note.id)
                continue
            }
            var text = read.text
            var extras = ContainerExtras.empty
            let sidecar = extrasFolder.appendingPathComponent("\(note.id.uuidString).json")
            if let data = try? Data(contentsOf: sidecar) {
                guard let entry = try? BodyExtrasSidecar.decode(data).current,
                      let applied = NoteStore.applyingCodeLanguageIDs(entry.codeLanguageIDs, to: text) else {
                    failed.append(note.id)
                    continue
                }
                text = applied
                extras = entry.extras
            }
            if extras != source.extras || !verify(note.id, source.text, text) { failed.append(note.id) }
        }
        if !failed.isEmpty { throw LibraryConversionError.notRoundTripping(failed) }
        try stop(after: .verified)
        try requireUnchanged(since: before)

        // 5. Move into place.
        let names = ["notes", "body-extras"]
        for name in names {
            let target = dataDir.appendingPathComponent(name, isDirectory: true)
            let contents = ((try? fm.contentsOfDirectory(atPath: target.path)) ?? []).filter { $0 != ".DS_Store" }
            guard contents.isEmpty else { throw LibraryConversionError.fileInTheWay(name) }
        }
        journal.movedIntoData = names
        var dataMoves: [LibraryConversionJournal.Move] = []
        for name in names {
            let folder = dataStaging.appendingPathComponent(name, isDirectory: true)
            for item in ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() {
                dataMoves.append(.init(path: name + "/" + item,
                                       sha256: try RTFDBodyStorage.packageDigest(at: folder.appendingPathComponent(item))))
            }
        }
        journal.dataMoves = dataMoves
        try journal.save(dataDir: dataDir)
        for name in names {
            let target = dataDir.appendingPathComponent(name, isDirectory: true)
            if Self.exists(target) { try fm.removeItem(at: target) }
            try fm.moveItem(at: dataStaging.appendingPathComponent(name, isDirectory: true), to: target)
        }
        try stop(after: .moved)

        // 6. Commit.
        try requireUnchanged(since: before)
        try LibraryLocationFile(format: .rtfd, path: LibraryLocationFile.displayPath(dataDir), libraryID: libraryID)
            .write(dataDir: dataDir)
        journal.committed = true
        try? journal.save(dataDir: dataDir)
        store.closeForLibrarySwitch()
        try stop(after: .committed)

        // 7. NoteIt's own files go; the Markdown files stay as they are.
        _ = Self.finishCommitted(journal, dataDir: dataDir, now: now(), trash: trash)
        return Result(location: LibraryLocation(url: dataDir, seedsFreshLibrary: false), previousLibrary: nil)
    }

    // MARK: Interrupted conversions

    /// Finishes or rolls back a conversion that a crash interrupted; runs before the library is loaded.
    nonisolated static func finishInterrupted(dataDir: URL, trash: (URL) throws -> Void = moveToTrash) {
        guard let journal = LibraryConversionJournal.load(dataDir: dataDir) else { return }
        switch state(of: journal, dataDir: dataDir) {
        case .committed:
            _ = finishCommitted(journal, dataDir: dataDir, now: Date(), trash: trash)
        case .notCommitted:
            rollBack(journal, dataDir: dataDir)
        case .unknown:
            NSLog("NoteIt: an interrupted library conversion was left as it is; the library location file can't be read")
        }
    }

    private enum JournalState { case committed, notCommitted, unknown }

    /// Rolls back only when the location file still shows the library as it was before, or is missing and was
    /// missing before; anything it can't read leaves every file where it is. Reads without changing anything.
    nonisolated private static func state(of journal: LibraryConversionJournal, dataDir: URL) -> JournalState {
        if journal.committed { return .committed }
        switch LibraryLocationFile.load(dataDir: dataDir, setsAsideDamaged: false, log: { _ in }) {
        case .missing:
            return journal.locationFileExisted == false ? .notCommitted : .unknown
        case .loaded(let file):
            switch (journal.direction, file.format) {
            case (.toMarkdown, .markdown): return file.libraryID == journal.libraryID ? .committed : .unknown
            case (.toMarkdown, .rtfd): return .notCommitted
            case (.toRTFD, .rtfd): return .committed
            case (.toRTFD, .markdown): return .notCommitted
            }
        default:
            return .unknown
        }
    }

    /// Removes only what the conversion added: moved files and RTFD bodies that still have the staged bytes, folders
    /// it created that are empty again, and its staging folders. The old library was never changed.
    nonisolated private static func rollBack(_ journal: LibraryConversionJournal, dataDir: URL) {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: journal.contentRoot, isDirectory: true)
        for move in journal.moves.reversed() {
            let url = root.appendingPathComponent(move.path)
            guard !isDirectory(url), let data = try? Data(contentsOf: url), AttachmentStore.sha256(data) == move.sha256 else { continue }
            try? fm.removeItem(at: url)
        }
        if let replacedFolder = journal.replacedFolder {
            let aside = root.appendingPathComponent(replacedFolder, isDirectory: true)
            for move in journal.replaced ?? [] {
                let original = root.appendingPathComponent(move.path)
                let kept = aside.appendingPathComponent(move.path)
                guard !exists(original), let data = try? Data(contentsOf: kept), AttachmentStore.sha256(data) == move.sha256 else { continue }
                try? fm.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.moveItem(at: kept, to: original)
            }
            removeEmptyFolders(aside)
        }
        if journal.wroteLibraryFile, libraryFileID(in: root) == journal.libraryID {
            try? fm.removeItem(at: libraryFileURL(in: root))
        }
        if journal.installedIndex {
            try? fm.removeItem(at: dataDir.appendingPathComponent(MarkdownPathIndex.fileName))
        }
        for move in journal.dataMoves ?? [] {
            let url = dataDir.appendingPathComponent(move.path)
            guard (try? RTFDBodyStorage.packageDigest(at: url)) == move.sha256 else { continue }
            try? fm.removeItem(at: url)
        }
        for name in journal.movedIntoData {
            removeIfEmpty(dataDir.appendingPathComponent(name, isDirectory: true))
        }
        removeStaging(journal)
        for folder in journal.createdFolders.reversed() {
            removeIfEmpty(root.appendingPathComponent(folder, isDirectory: true))
        }
        try? fm.removeItem(at: LibraryConversionJournal.url(dataDir: dataDir))
    }

    nonisolated private static func removeStaging(_ journal: LibraryConversionJournal) {
        let fm = FileManager.default
        if let staging = journal.contentStaging {
            let url = URL(fileURLWithPath: staging, isDirectory: true)
            try? fm.removeItem(at: url)
            removeIfEmpty(url.deletingLastPathComponent())
        }
        let dataStaging = URL(fileURLWithPath: journal.dataStaging, isDirectory: true)
        try? fm.removeItem(at: dataStaging)
        removeIfEmpty(dataStaging.deletingLastPathComponent())
    }

    /// Removes `folder` and the folders in it that hold nothing else.
    nonisolated private static func removeEmptyFolders(_ folder: URL) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] {
            let url = folder.appendingPathComponent(name, isDirectory: true)
            if isDirectory(url) { removeEmptyFolders(url) }
        }
        removeIfEmpty(folder)
    }

    // MARK: Files of an earlier conversion

    struct LibraryFile: Equatable {
        var path: String
        var id: UUID
    }

    /// Markdown files with an id in their front matter (`.trash/` included) and notebook folders with a
    /// `.noteit-notebook.json`, sorted by path.
    nonisolated static func libraryFiles(in folder: URL) -> (notes: [LibraryFile], notebooks: [LibraryFile]) {
        var notes: [LibraryFile] = []
        var notebooks: [LibraryFile] = []
        func walk(_ relative: String, depth: Int) {
            let url = relative.isEmpty ? folder : folder.appendingPathComponent(relative, isDirectory: true)
            guard depth <= NotebookFolders.maxDepth + 1,
                  let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return }
            for name in names.sorted() {
                if name.hasPrefix("."), !(relative.isEmpty && name == FolderScanner.trashFolder) { continue }
                let path = relative.isEmpty ? name : relative + "/" + name
                var info = stat()
                guard lstat(url.appendingPathComponent(name).path, &info) == 0 else { continue }
                switch info.st_mode & S_IFMT {
                case S_IFDIR:
                    if let id = notebookFileID(url.appendingPathComponent(name).appendingPathComponent(NotebookFolders.fileName)) {
                        notebooks.append(LibraryFile(path: path, id: id))
                    }
                    walk(path, depth: depth + 1)
                case S_IFREG where FolderScanner.isMarkdown(name) && Int64(info.st_size) <= FolderScanner.maxFileSize:
                    if let data = try? Data(contentsOf: url.appendingPathComponent(name)), let id = FolderScanner.frontMatterID(data) {
                        notes.append(LibraryFile(path: path, id: id))
                    }
                default:
                    continue
                }
            }
        }
        walk("", depth: 0)
        return (notes, notebooks)
    }

    nonisolated private static func notebookFileID(_ url: URL) -> UUID? {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (raw["id"] as? String).flatMap(UUID.init(uuidString:))
    }

    /// The earlier notebook folders that stay where the tree would put them, so staging writes into them.
    nonisolated static func reusableNotebookFolders(_ folders: [LibraryFile], tree: [Notebook]) -> [UUID: String] {
        let known = Set(tree.map(\.id))
        var kept: [UUID: String] = [:]
        for folder in folders where known.contains(folder.id) && kept[folder.id] == nil { kept[folder.id] = folder.path }
        while true {
            let target = NotebookFolders.layout(tree, existing: kept)
            let staying = kept.filter { target[$0.key] == $0.value }
            if staying.count == kept.count { return kept }
            kept = staying
        }
    }

    /// A differing file may be replaced only when it is one of this library's earlier files, or the notebook file of
    /// a folder whose notebook it already describes.
    nonisolated private static func isReplaceable(_ path: String, existing: Data, staged: URL, setAside: Set<String>) -> Bool {
        if setAside.contains(path) { return true }
        if (path as NSString).lastPathComponent == NotebookFolders.fileName {
            guard let id = notebookFileID(staged) else { return false }
            let raw = try? JSONSerialization.jsonObject(with: existing) as? [String: Any]
            return (raw?["id"] as? String).flatMap(UUID.init(uuidString:)) == id
        }
        guard FolderScanner.isMarkdown(path), let stagedData = try? Data(contentsOf: staged),
              let id = FolderScanner.frontMatterID(stagedData) else { return false }
        return FolderScanner.frontMatterID(existing) == id
    }

    nonisolated private static func removeIfEmpty(_ folder: URL) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return }
        if names.allSatisfy({ $0 == ".DS_Store" }) { try? fm.removeItem(at: folder) }
    }

    /// `<stem> (Edited Outside NoteIt).md` beside `path`, numbered when that name is taken.
    nonisolated private static func conflictCopyPath(for path: String, in folder: URL, staging: URL, taken: Set<String>) -> String {
        let directory = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var number = 1
        while true {
            let candidate = "\(stem) (Edited Outside NoteIt)\(number == 1 ? "" : " \(number)").\(ext)"
            let copy = directory.isEmpty ? candidate : directory + "/" + candidate
            if !taken.contains(copy.lowercased()), !exists(folder.appendingPathComponent(copy)),
               !exists(staging.appendingPathComponent(copy)) { return copy }
            number += 1
        }
    }

    /// `data` with a fresh id in its front matter.
    nonisolated private static func withNewID(_ data: Data) -> Data {
        guard let text = String(data: data, encoding: .utf8), var frontMatter = try? FrontMatter.read(text).0 else { return data }
        frontMatter.id = UUID()
        return MarkdownBodyStorage.patchingFrontMatter(data, with: frontMatter)
    }

    /// Moves `.noteit/replaced-*` folders of `root` to the Trash; one that can't go stays where it is.
    nonisolated private static func trashReplacedFolders(in root: URL, trash: (URL) throws -> Void) {
        let privateFolder = root.appendingPathComponent(MarkdownBodyStorage.privateFolder, isDirectory: true)
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: privateFolder.path)) ?? []).sorted()
        where name.hasPrefix("replaced-") {
            do {
                try trash(privateFolder.appendingPathComponent(name, isDirectory: true))
            } catch {
                NSLog("NoteIt: couldn't move \(name) to the Trash; it stays in \(privateFolder.path): \(error)")
            }
        }
    }

    /// Step 7. Returns the previous library's folder, when one was made. Removes only NoteIt's own files: staging,
    /// the journal and NoteIt's files in `.noteit/`; files set aside by a conversion go to the Trash.
    nonisolated private static func finishCommitted(_ journal: LibraryConversionJournal, dataDir: URL, now: Date,
                                                    trash: (URL) throws -> Void) -> URL? {
        let fm = FileManager.default
        var previous: URL?
        let root = URL(fileURLWithPath: journal.contentRoot, isDirectory: true)
        switch journal.direction {
        case .toMarkdown:
            let leftovers = ["notes", "body-extras"].map { dataDir.appendingPathComponent($0, isDirectory: true) }
                .filter { fm.fileExists(atPath: $0.path) }
            if !leftovers.isEmpty {
                do {
                    let folder = try PreviousLibrary.create(in: dataDir, now: now)
                    for url in leftovers { try fm.moveItem(at: url, to: folder.appendingPathComponent(url.lastPathComponent)) }
                    previous = folder
                } catch {
                    NSLog("NoteIt: couldn't move the previous library aside: \(error)")
                    return nil
                }
            }
            trashReplacedFolders(in: root, trash: trash)
            try? fm.removeItem(at: EarlierMarkdownFiles.url(dataDir: dataDir))
        case .toRTFD:
            EarlierMarkdownFiles.record(MarkdownPathIndex(dataDir: dataDir), dataDir: dataDir)
            if fm.fileExists(atPath: root.path) {
                trashReplacedFolders(in: root, trash: trash)
                let privateFolder = root.appendingPathComponent(MarkdownBodyStorage.privateFolder, isDirectory: true)
                for name in ["staging", libraryFileName, AttachmentStore.sweepStateFileName] {
                    try? fm.removeItem(at: privateFolder.appendingPathComponent(name))
                }
                removeIfEmpty(privateFolder)
            }
            for name in [MarkdownPathIndex.fileName, MassDeletionGuard.fileName] {
                try? fm.removeItem(at: dataDir.appendingPathComponent(name))
            }
        }
        removeStaging(journal)
        try? fm.removeItem(at: LibraryConversionJournal.url(dataDir: dataDir))
        return previous
    }
}

/// What NoteIt last wrote to each note's Markdown file (path and SHA-256), kept in the data folder when a library
/// goes back to RTFD, so converting into that folder again can tell NoteIt's own files from ones edited outside it.
struct EarlierMarkdownFiles {
    struct File: Codable, Equatable {
        var path: String
        var sha256: String
    }

    static let fileName = "earlier-markdown-files.json"

    static func url(dataDir: URL) -> URL { dataDir.appendingPathComponent(fileName) }

    static func load(dataDir: URL) -> [UUID: File] {
        guard let data = try? Data(contentsOf: url(dataDir: dataDir)),
              let raw = try? JSONDecoder().decode([String: File].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: raw.compactMap { key, file in UUID(uuidString: key).map { ($0, file) } })
    }

    static func record(_ index: MarkdownPathIndex, dataDir: URL) {
        let files = index.allEntries.filter { !$0.value.sha256.isEmpty }
        guard !files.isEmpty else { return }
        let raw = Dictionary(uniqueKeysWithValues: files.map { ($0.key.uuidString, File(path: $0.value.path, sha256: $0.value.sha256)) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            try encoder.encode(raw).write(to: url(dataDir: dataDir), options: .atomic)
        } catch {
            NSLog("NoteIt: couldn't keep the list of Markdown files NoteIt wrote: \(error)")
        }
    }
}
