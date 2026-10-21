import Foundation
import NoteItCore
import NoteItSync

/// `smart-folders.json` in `rootURL` (never in a Markdown library's content folder). `appliedRemoteRevisions` is the
/// smartFolders kind's raw-meta applied-revision map; `pendingDeletions` is this kind's sync deletion journal. Both
/// are local only and omitted when empty. Deletions live here rather than in `sync-deletions.json`, whose closed set
/// of kinds older versions decode as a whole.
struct SmartFolderFile: Codable {
    var version: Int
    var smartFolders: [SmartFolder]
    var appliedRemoteRevisions: [String: UUID]?
    var pendingDeletions: [String: Date]?
}

struct SmartFolderState {
    var dirty = false
    var applied: [String: UUID] = [:]
    var deletions: [UUID: Date] = [:]
    /// IDs in the last saved file; nil when unknown (an unreadable file), which counts as listed.
    var idsOnDisk: Set<UUID>?
    /// An unreadable file that couldn't be copied aside is never overwritten.
    var writeBlocked = false
}

enum SmartFolderError: Error, Equatable {
    case emptyName, nameTooLong, emptyQuery, queryTooLong, tooMany, notFound
}

extension NoteStore {
    var smartFoldersURL: URL { rootURL.appendingPathComponent("smart-folders.json") }

    func smartFolder(with id: UUID) -> SmartFolder? {
        smartFolders.first { $0.id == id }
    }

    /// Sidebar order.
    var sortedSmartFolders: [SmartFolder] {
        smartFolders.sorted {
            ($0.sortIndex, $0.name.localizedLowercase, $0.id.uuidString) < ($1.sortIndex, $1.name.localizedLowercase, $1.id.uuidString)
        }
    }

    /// Trimmed name and query, or the first limit they break.
    static func validatedSmartFolder(name: String, query: String) throws -> (name: String, query: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { throw SmartFolderError.emptyName }
        if name.count > SmartFolder.maxNameLength { throw SmartFolderError.nameTooLong }
        if query.isEmpty { throw SmartFolderError.emptyQuery }
        if query.count > SmartFolder.maxQueryLength { throw SmartFolderError.queryTooLong }
        return (name, query)
    }

    @discardableResult
    func createSmartFolder(name: String, query: String, symbol: String = SmartFolder.defaultSymbol) throws -> SmartFolder {
        let valid = try Self.validatedSmartFolder(name: name, query: query)
        guard smartFolders.count < SmartFolder.maxCount else { throw SmartFolderError.tooMany }
        let folder = SmartFolder(name: valid.name, query: valid.query, symbol: symbol.isEmpty ? SmartFolder.defaultSymbol : symbol,
                                 sortIndex: (smartFolders.map(\.sortIndex).max() ?? -1) + 1,
                                 revision: UUID(), modifiedAt: Date())
        changeSmartFolders(local: true) { $0.append(folder) }
        clearSmartFolderDeletion(folder.id)
        return folder
    }

    func updateSmartFolder(_ id: UUID, name: String, query: String, symbol: String) throws {
        let valid = try Self.validatedSmartFolder(name: name, query: query)
        guard let index = smartFolders.firstIndex(where: { $0.id == id }) else { throw SmartFolderError.notFound }
        var updated = smartFolders[index]
        updated.name = valid.name
        updated.query = valid.query
        updated.symbol = symbol.isEmpty ? SmartFolder.defaultSymbol : symbol
        guard updated != smartFolders[index] else { return }
        updated.revision = UUID()
        updated.modifiedAt = Date()
        changeSmartFolders(local: true) { $0[index] = updated }
    }

    func deleteSmartFolder(_ id: UUID) {
        guard smartFolder(with: id) != nil else { return }
        changeSmartFolders(local: true) { $0.removeAll { $0.id == id } }
        smartFolderState.applied[id.uuidString] = nil
        if Self.syncJournalEnabled { smartFolderState.deletions[id] = Date() }
        queueRawMetaDeletion(id, kind: .smartFolders)
        if selection == .smartFolder(id) {
            selection = .allNotes
            reconcileSelection()
        }
    }

    /// Reorders like `List.onMove` over `sortedSmartFolders`; only folders whose index changes get a new revision.
    func moveSmartFolders(fromOffsets source: IndexSet, toOffset destination: Int) {
        var ordered = sortedSmartFolders
        ordered.move(fromOffsets: source, toOffset: destination)
        let now = Date()
        var changed: [UUID: Int] = [:]
        for (index, folder) in ordered.enumerated() where folder.sortIndex != index { changed[folder.id] = index }
        guard !changed.isEmpty else { return }
        changeSmartFolders(local: true) { folders in
            for i in folders.indices {
                guard let index = changed[folders[i].id] else { continue }
                folders[i].sortIndex = index
                folders[i].revision = UUID()
                folders[i].modifiedAt = now
            }
        }
    }

    /// Runs `rewrite` over every smart folder's query and saves the ones that changed.
    func rewriteSmartFolderQueries(_ rewrite: (String) -> String) {
        let now = Date()
        var updates: [Int: String] = [:]
        for (index, folder) in smartFolders.enumerated() {
            let query = rewrite(folder.query)
            if query != folder.query, query.count <= SmartFolder.maxQueryLength { updates[index] = query }
        }
        guard !updates.isEmpty else { return }
        changeSmartFolders(local: true) { folders in
            for (index, query) in updates {
                folders[index].query = query
                folders[index].revision = UUID()
                folders[index].modifiedAt = now
            }
        }
    }

    /// Keeps `notebook:` values pointing at a renamed notebook: its full path and, for a single name, the name.
    func rewriteSmartFoldersForNotebookRename(oldPath: [String], newPath: [String]) {
        guard let oldName = oldPath.last, let newName = newPath.last, oldPath != newPath else { return }
        let from = oldPath.joined(separator: "/"), to = newPath.joined(separator: "/")
        rewriteSmartFolderQueries { query in
            var result = QueryRewriter.renamingNotebook(from, to: to, in: query)
            if oldName != newName { result = QueryRewriter.renamingNotebook(oldName, to: newName, in: result) }
            return result
        }
    }

    // MARK: File

    func loadSmartFolders() {
        let url = smartFoldersURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            smartFolderState.idsOnDisk = []
            return
        }
        do {
            let file = try Self.decoder.decode(SmartFolderFile.self, from: Data(contentsOf: url))
            changeSmartFolders(local: false) { $0 = file.smartFolders }
            smartFolderState.applied = file.appliedRemoteRevisions ?? [:]
            smartFolderState.deletions = Dictionary((file.pendingDeletions ?? [:]).compactMap { key, date in
                UUID(uuidString: key).map { ($0, date) }
            }, uniquingKeysWith: { a, _ in a })
            smartFolderState.idsOnDisk = Set(file.smartFolders.map(\.id))
            smartFolderState.dirty = false
        } catch {
            NSLog("NoteIt: smart-folders.json is unreadable (\(error)); starting with no smart folders")
            smartFolderState.idsOnDisk = nil
            backUpUnreadableSmartFolders()
        }
    }

    private func backUpUnreadableSmartFolders() {
        let backup = RTFDBodyStorage.uniqueURL(rootURL.appendingPathComponent("smart-folders.corrupt-\(RTFDBodyStorage.timestamp()).json"))
        do {
            try FileManager.default.copyItem(at: smartFoldersURL, to: backup)
            smartFolderState.writeBlocked = false
        } catch {
            NSLog("NoteIt: couldn’t copy the unreadable smart-folders.json aside: \(error)")
            smartFolderState.writeBlocked = true
        }
    }

    /// Writes the file atomically. On failure the state stays dirty and the next flush retries.
    @discardableResult
    func saveSmartFolders() -> Bool {
        if smartFolderState.writeBlocked {
            backUpUnreadableSmartFolders()
            if smartFolderState.writeBlocked { return false }
        }
        let ids = Set(smartFolders.map(\.id))
        let applied = smartFolderState.applied.filter { key, _ in UUID(uuidString: key).map(ids.contains) == true }
        let deletions = smartFolderState.deletions.filter { !ids.contains($0.key) }
        let file = SmartFolderFile(
            version: 1, smartFolders: smartFolders,
            appliedRemoteRevisions: applied.isEmpty ? nil : applied,
            pendingDeletions: deletions.isEmpty ? nil : Dictionary(uniqueKeysWithValues: deletions.map { ($0.key.uuidString, $0.value) })
        )
        do {
            try Self.encoder.encode(file).write(to: smartFoldersURL, options: .atomic)
        } catch {
            NSLog("NoteIt: failed to save smart folders: \(error)")
            return false
        }
        smartFolderState.applied = applied
        smartFolderState.deletions = deletions
        smartFolderState.idsOnDisk = ids
        smartFolderState.dirty = false
        return true
    }

    /// True while smart-folders.json lags behind memory; sync must not record a base for a smart folder then.
    var hasUnsavedSmartFolders: Bool { smartFolderState.dirty }

    // MARK: Sync

    var smartFolderSyncDeletions: [UUID: LocalDeletion] {
        var result: [UUID: LocalDeletion] = [:]
        for (id, date) in smartFolderState.deletions where smartFolder(with: id) == nil {
            result[id] = LocalDeletion(kind: .smartFolder, deletedAt: date)
        }
        return result
    }

    func clearSmartFolderDeletion(_ id: UUID) {
        guard smartFolderState.deletions.removeValue(forKey: id) != nil else { return }
        smartFolderState.dirty = true
        saveSmartFolders()
    }

    func clearAllSmartFolderDeletions() {
        guard !smartFolderState.deletions.isEmpty else { return }
        smartFolderState.deletions = [:]
        smartFolderState.dirty = true
        saveSmartFolders()
    }

    /// `revision` is recorded as applied in the same save; its raw meta must already be written.
    func applyRemoteSmartFolder(_ remote: SmartFolder) {
        guard let revision = remote.revision else { return }
        changeSmartFolders(local: false) { folders in
            if let index = folders.firstIndex(where: { $0.id == remote.id }) {
                folders[index] = remote
            } else {
                folders.append(remote)
            }
        }
        smartFolderState.applied[remote.id.uuidString] = revision
        smartFolderState.deletions[remote.id] = nil
        saveSmartFolders()
    }

    func removeSmartFolderForRemote(_ id: UUID) {
        let hadDeletion = smartFolderState.deletions.removeValue(forKey: id) != nil
        guard smartFolder(with: id) != nil else {
            if hadDeletion {
                smartFolderState.dirty = true
                saveSmartFolders()
            }
            return
        }
        changeSmartFolders(local: false) { $0.removeAll { $0.id == id } }
        smartFolderState.applied[id.uuidString] = nil
        queueRawMetaDeletion(id, kind: .smartFolders)
        if saveSmartFolders() { drainRawMetaDeletionQueue() }
        if selection == .smartFolder(id) {
            selection = .allNotes
            reconcileSelection()
        }
    }
}
