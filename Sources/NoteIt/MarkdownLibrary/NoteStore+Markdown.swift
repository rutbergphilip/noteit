import AppKit
import Foundation
import NoteItCore
import NoteItMarkdown

/// A Markdown library in `NoteStore`: folders follow notebooks on every flush, files are renamed after their
/// title when the note is left alone, and changes made outside NoteIt are applied from folder scans
/// (markdown-storage spec §3.4–§3.5).
extension NoteStore {
    static let outsideNoteItSource = "Outside NoteIt"
    static let missingFileReason = "This note’s file is missing from the folder."
    /// A file is renamed after its title once the note has been left alone this long.
    static let idleRenameDelay: TimeInterval = 5

    var markdownStorage: MarkdownBodyStorage? { bodyStorage as? MarkdownBodyStorage }

    // MARK: Layout

    /// Folders and front matter follow notebooks and note metadata; files follow titles once idle. Called by
    /// `flush()` after the body writes.
    func syncMarkdownLayout() {
        guard let storage = markdownStorage, storage.contentRootExists else { return }
        storage.setNotebooks(notebooks)
        do { try storage.reconcileNotebooks() } catch { NSLog("NoteIt: couldn't update notebook folders: \(error)") }
        if libraryDirty {
            for meta in notes where !isBodyDirty(meta.id) && !isBodyWriteBlocked(meta.id) && storage.needsMetadataWrite(meta) {
                do {
                    try storage.writeMetadataOnly(for: meta, notebook: notebook(with: meta.notebookID))
                } catch {
                    handleMarkdownWriteError(error, for: meta.id)
                }
            }
            for id in storage.index.allNotebookFolders.keys where notebook(with: id) == nil {
                do { try storage.removeNotebook(id: id) } catch { NSLog("NoteIt: couldn't remove a notebook folder: \(error)") }
            }
        }
        renameIdleMarkdownFiles()
        try? storage.index.save()
    }

    private func renameIdleMarkdownFiles() {
        guard let storage = markdownStorage else { return }
        let now = markdownClock()
        var waiting: TimeInterval?
        for meta in notes where storage.wantsRename(meta) && !isBodyDirty(meta.id) && !isBodyWriteBlocked(meta.id) {
            let idle = now.timeIntervalSince(meta.updatedAt)
            if meta.id == selectedNoteID, idle < Self.idleRenameDelay {
                waiting = min(waiting ?? .infinity, Self.idleRenameDelay - idle)
                continue
            }
            do { try storage.renameForTitle(meta) } catch { handleMarkdownWriteError(error, for: meta.id) }
        }
        hasPendingMarkdownRenames = waiting != nil
        if let waiting { scheduleSave(after: max(waiting, 0.5)) }
    }

    /// Leaving a note renames its file after the title right away.
    func markdownSelectionChanged(from old: UUID?) {
        guard let old, let storage = markdownStorage, let meta = note(with: old), storage.wantsRename(meta) else { return }
        scheduleSave()
    }

    private func handleMarkdownWriteError(_ error: Error, for id: UUID) {
        NSLog("NoteIt: couldn't update the file of note \(id): \(error)")
        switch error as? MarkdownStorageError {
        case .unreadable: blockMarkdownBodyWrites(id, reason: MarkdownBodyStorage.unreadableReason)
        case .externallyChanged: markdownFolderNeedsScan()
        case .folderMissing, nil: break
        }
    }

    // MARK: Scans

    /// Rescans the content folder on the next turn of the main queue; repeated calls before then scan once.
    func markdownFolderNeedsScan() {
        guard markdownStorage != nil, !markdownScanScheduled else { return }
        markdownScanScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.markdownScanScheduled = false
                self.rescanMarkdownFolder()
            }
        }
    }

    /// Scans the content folder and applies what changed outside NoteIt. Nothing happens while it is missing.
    func rescanMarkdownFolder() {
        guard let storage = markdownStorage, !isClosedForLibrarySwitch else { return }
        guard storage.contentRootExists else { return markdownFolderWentMissing() }
        markdownFolderReportedMissing = false
        let result = FolderScanner.scan(contentRoot: storage.contentRootURL, index: storage.index)
        guard storage.contentRootExists else { return markdownFolderWentMissing() }
        applyExternalChanges(result, atLaunch: false)
    }

    /// Starts the FSEvents watcher; the app calls this once the library is loaded.
    func startWatchingMarkdownFolder() {
        guard let storage = markdownStorage, markdownWatcher == nil else { return }
        let watcher = MarkdownFolderWatcher(root: storage.contentRootURL, ledger: storage.ledger,
                                            onChange: { [weak self] in self?.rescanMarkdownFolder() },
                                            onRootChanged: { [weak self] in self?.rescanMarkdownFolder() })
        guard watcher.start() else { return NSLog("NoteIt: couldn't watch \(storage.contentRootURL.path) for changes") }
        markdownWatcher = watcher
        rescanMarkdownFolder()
    }

    func stopWatchingMarkdownFolder() {
        markdownWatcher?.stop()
        markdownWatcher = nil
    }

    private func markdownFolderWentMissing() {
        guard let storage = markdownStorage, !markdownFolderReportedMissing else { return }
        markdownFolderReportedMissing = true
        NSLog("NoteIt: the library folder \(storage.contentRootURL.path) is missing; nothing is written until it is back")
        onMarkdownFolderMissing?(storage.contentRootURL)
    }

    /// At load: the folder is scanned and everything in it becomes the library, `library.json` filling in what
    /// files don't say (spec §3.3).
    func loadMarkdownFolder() {
        guard let storage = markdownStorage else { return }
        heldMarkdownDeletions = MassDeletionGuard.load(dataDir: rootURL)
        storage.setNotebooks(notebooks)
        guard storage.contentRootExists else { return }
        let result = FolderScanner.scan(contentRoot: storage.contentRootURL, index: storage.index)
        applyExternalChanges(result, atLaunch: true)
        let tombstones = Set(syncDeletions().keys)
        let orphans = storage.index.ids.filter { note(with: $0) == nil && !tombstones.contains($0) && !isTombstoned($0) }
        if !orphans.isEmpty {
            importFiles(orphans.compactMap { id in storage.index.entry(id).map { NewFile(id: id, path: $0.path, assign: false) } },
                        atLaunch: true)
        }
    }

    /// Applies one scan: notebook folders first, so new files land in their notebooks, then files, then
    /// notebook folders that are gone. At launch nothing is versioned or flushed; the load saves the result.
    func applyExternalChanges(_ result: FolderScanResult, atLaunch: Bool, confirmsMassDeletion: Bool = false) {
        guard let storage = markdownStorage, storage.contentRootExists else { return }
        storage.setSkippedFiles(result.skipped.map(storage.url(of:)))
        var metadataChanged = applyNotebookFolders(result.notebookFolders)
        storage.setNotebooks(notebooks)

        for (id, path) in result.moved.sorted(by: { $0.value < $1.value }) {
            metadataChanged = applyMove(id, to: path, changed: result.changed[id] != nil, atLaunch: atLaunch) || metadataChanged
        }
        for (id, path) in result.changed.sorted(by: { $0.value < $1.value }) where result.moved[id] == nil {
            applyContentChange(id, at: path, atLaunch: atLaunch)
        }
        var newFiles: [NewFile] = result.added.sorted().map { NewFile(id: nil, path: $0, assign: true) }
        newFiles += result.duplicateIDs.sorted().map { NewFile(id: nil, path: $0, assign: true) }
        importFiles(atLaunch ? newFiles : settledFiles(newFiles), atLaunch: atLaunch)
        releaseReturnedDeletions()

        let removed = result.removed.filter { id in
            guard let entry = storage.index.entry(id) else { return false }
            return !FileManager.default.fileExists(atPath: storage.url(of: entry.path).path)
        }
        if !removed.isEmpty, !holdRemovals(removed, atLaunch: atLaunch, confirmed: confirmsMassDeletion) {
            metadataChanged = applyRemovals(removed, atLaunch: atLaunch) || metadataChanged
        }
        metadataChanged = removeNotebooksWithoutFolders(result.notebookFolders) || metadataChanged
        try? storage.index.save()
        if metadataChanged { commitOutsideMetadataChange() }
    }

    // MARK: Notebook folders

    /// New folders become notebooks; renamed and moved folders rename and move theirs.
    private func applyNotebookFolders(_ folders: [String: NotebookFolderInfo]) -> Bool {
        guard let storage = markdownStorage else { return false }
        var changed = false
        var idByFolder: [String: UUID] = [:]
        let recorded = storage.index.allNotebookFolders
        let journaled = Set(syncDeletions().keys)
        var claimed = Set<UUID>()
        let ordered = folders.keys.sorted { (MarkdownBodyStorage.depth(of: $0), $0) < (MarkdownBodyStorage.depth(of: $1), $1) }
        for path in ordered {
            guard let info = folders[path] else { continue }
            let parentPath = MarkdownPathIndex.folder(of: path)
            let parent = parentPath.isEmpty ? nil : idByFolder[parentPath.lowercased()]
            if let id = info.id, notebook(with: id) != nil, claimed.insert(id).inserted {
                idByFolder[path.lowercased()] = id
                guard recorded[id] != path, let index = notebooks.firstIndex(where: { $0.id == id }) else { continue }
                let name = (path as NSString).lastPathComponent
                var renamed = notebooks[index]
                let oldPath = notebookTree.path(of: id)
                if renamed.name != name || renamed.parent != parent {
                    renamed.name = name
                    renamed.parent = parent
                    renamed.revision = UUID()
                    renamed.modifiedAt = Date()
                    notebooks[index] = renamed
                    rewriteSmartFoldersForNotebookRename(oldPath: oldPath, newPath: notebookTree.path(of: id))
                    changed = true
                }
                if let old = recorded[id] { storage.index.moveFolder(old, to: path) }
                storage.index.setNotebookFolder(path, for: id)
                continue
            }
            let folderURL = storage.url(of: path)
            guard var found = try? NotebookFolders.read(folderURL).notebook else { continue }
            if info.id == nil || notebook(with: found.id) != nil || journaled.contains(found.id) || claimed.contains(found.id) {
                found.id = UUID()
            }
            claimed.insert(found.id)
            found.parent = parent
            found.sortIndex = (notebooks.filter { $0.parent == parent }.map(\.sortIndex).max() ?? -1) + 1
            found.revision = UUID()
            found.modifiedAt = Date()
            notebooks.append(found)
            storage.index.setNotebookFolder(path, for: found.id)
            idByFolder[path.lowercased()] = found.id
            changed = true
        }
        return changed
    }

    /// Notebooks whose own folder is gone are deleted as in NoteIt (their notes go to Recently Deleted), unless
    /// a held batch of deletions is waiting for the user.
    private func removeNotebooksWithoutFolders(_ folders: [String: NotebookFolderInfo]) -> Bool {
        guard let storage = markdownStorage, heldMarkdownDeletions.isEmpty else { return false }
        let present = Set(folders.compactMap(\.value.id))
        var removed = false
        let tree = notebookTree
        for (id, path) in storage.index.allNotebookFolders where notebook(with: id) != nil && !present.contains(id) {
            guard tree.depth(of: id) <= NotebookFolders.maxDepth,
                  !FileManager.default.fileExists(atPath: storage.url(of: path).path) else { continue }
            guard notebook(with: id) != nil else { continue }
            storage.index.setNotebookFolder(nil, for: id)
            deleteNotebook(id)
            removed = true
        }
        return removed
    }

    /// The notebook a file in `folder` belongs to: the deepest notebook folder that holds it.
    func notebookID(forFolder folder: String) -> UUID? {
        guard let storage = markdownStorage, !folder.isEmpty, !FolderScanner.isTrash(folder + "/x") else { return nil }
        let byPath = Dictionary(storage.index.allNotebookFolders.map { ($0.value.lowercased(), $0.key) }, uniquingKeysWith: { a, b in
            (notebookTree.depth(of: a) <= notebookTree.depth(of: b)) ? a : b
        })
        var components = folder.split(separator: "/").map(String.init)
        if components.count > NotebookFolders.maxDepth { components = Array(components.prefix(NotebookFolders.maxDepth)) }
        while !components.isEmpty {
            if let id = byPath[components.joined(separator: "/").lowercased()], notebook(with: id) != nil { return id }
            components.removeLast()
        }
        return nil
    }

    // MARK: Files

    /// A file moved or renamed outside NoteIt: the note keeps its id; another folder means another notebook, and
    /// a move into or out of `.trash/` deletes or recovers it.
    private func applyMove(_ id: UUID, to path: String, changed: Bool, atLaunch: Bool) -> Bool {
        guard let storage = markdownStorage, noteIndex(id) != nil else { return false }
        if changed {
            storage.index.move(id, to: path)
            applyContentChange(id, at: path, atLaunch: atLaunch)
        } else {
            do { try storage.adopt(id, at: path, assignID: false) } catch { return false }
        }
        guard let current = noteIndex(id) else { return false }
        var meta = notes[current]
        let folder = MarkdownPathIndex.folder(of: path)
        let inTrash = FolderScanner.isTrash(path)
        var moved = false
        if inTrash != (meta.deletedAt != nil) {
            meta.deletedAt = inTrash ? Date() : nil
            moved = true
        }
        if !inTrash {
            let notebookID = notebookID(forFolder: folder)
            if notebookID != meta.notebookID, !(notebookID == nil && meta.notebookID.map { notebook(with: $0) == nil } == true) {
                meta.notebookID = notebookID
                moved = true
            }
        }
        if moved {
            meta.revision = UUID()
            notes[current] = meta
            dispatchDerivedIndexes(.metadata(meta))
            if meta.deletedAt != nil, selectedNoteID == id, !atLaunch { selectNeighbor(of: id) }
        }
        storage.markPlaced(notes[current])
        return moved
    }

    /// A file whose content changed outside NoteIt. A clean note reloads through `editBody` (its previous body is
    /// kept in Version History); a note with unsaved edits keeps them and the file's text becomes a conflict
    /// copy "<title> (Outside NoteIt)".
    private func applyContentChange(_ id: UUID, at path: String, atLaunch: Bool) {
        guard let storage = markdownStorage, let meta = note(with: id) else { return }
        if let entry = storage.index.entry(id), entry.path == path,
           MarkdownFileStat.of(storage.url(of: path))?.matches(entry) == true { return }
        if !atLaunch { handOverPendingEdits(id) }
        let unsaved = hasUnsavedBody(id)
        let old = cachedBody(id) ?? storage.lastKnownBody(id)?.text
        let adopted: MarkdownBodyStorage.Adopted
        do {
            adopted = try storage.adopt(id, at: path, assignID: false)
        } catch {
            NSLog("NoteIt: couldn't read the changed file of note \(id): \(error)")
            return
        }
        let body = adopted.body
        if unsaved {
            if body.readOnlyReason == nil || body.readOnlyReason == MarkdownBodyStorage.missingAttachmentsReason {
                makeOutsideConflictCopy(of: meta, text: body.text, extras: body.extras, frontMatter: adopted.frontMatter,
                                        modified: adopted.modified)
            }
            scheduleSave()
            return
        }
        if let reason = body.readOnlyReason {
            dropCachedBody(id)
            blockMarkdownBodyWrites(id, reason: reason)
            refreshDerivedMetadata(id, from: body.text, frontMatter: adopted.frontMatter, modified: adopted.modified, atLaunch: atLaunch)
            externallyUpdatedNoteID = id
            return
        }
        unblockMarkdownBodyWrites(id, reason: MarkdownBodyStorage.unreadableReason)
        unblockMarkdownBodyWrites(id, reason: MarkdownBodyStorage.missingAttachmentsReason)
        unblockMarkdownBodyWrites(id, reason: Self.missingFileReason)
        if atLaunch || meta.deletedAt != nil || meta.isLocked || old == nil {
            dropCachedBody(id)
            setBodyExtras(body.extras, for: id)
            refreshDerivedMetadata(id, from: body.text, frontMatter: adopted.frontMatter, modified: adopted.modified, atLaunch: atLaunch)
            if !atLaunch { externallyUpdatedNoteID = id }
            return
        }
        if let old { seedCachedBody(id, old) }
        externalEditDate = adopted.modified ?? Date()
        defer { externalEditDate = nil }
        do {
            try editBody(id, actionName: "Edit Outside NoteIt", extras: body.extras) { text in
                text.setAttributedString(body.text)
            }
        } catch {
            NSLog("NoteIt: couldn't reload note \(id) from its file: \(error)")
            dropCachedBody(id)
        }
        if let pinned = adopted.frontMatter?.pinned, let index = noteIndex(id), notes[index].isPinned != pinned {
            notes[index].isPinned = pinned
            notes[index].revision = UUID()
            dispatchDerivedIndexes(.metadata(notes[index]))
            commitOutsideMetadataChange()
        }
        if let current = note(with: id) { storage.markPlaced(current) }
    }

    /// Title, preview, tags, pinned and date from a file read without `editBody`.
    private func refreshDerivedMetadata(_ id: UUID, from text: NSAttributedString, frontMatter: FrontMatter?, modified: Date?,
                                        atLaunch: Bool) {
        guard let storage = markdownStorage, let index = noteIndex(id) else { return }
        var meta = notes[index]
        Self.applyDerivedFields(to: &meta, from: text)
        if let frontMatter { meta.isPinned = frontMatter.pinned }
        meta.updatedAt = modified ?? Date()
        meta.revision = UUID()
        notes[index] = meta
        dispatchDerivedIndexes(.changed(meta, text))
        storage.markPlaced(meta)
        commitOutsideMetadataChange()
        if !atLaunch { postLocalNoteChange(id, .edited) }
    }

    private func makeOutsideConflictCopy(of meta: NoteMeta, text: NSAttributedString, extras: ContainerExtras,
                                         frontMatter: FrontMatter?, modified: Date?) {
        let body = Self.appendingToTitleLine(text, " (\(Self.outsideNoteItSource))")
        let created = createNote(in: meta.notebookID, initial: body)
        guard let index = noteIndex(created.id) else { return }
        notes[index].conflictSource = Self.outsideNoteItSource
        notes[index].conflictOriginalID = meta.id
        notes[index].isPinned = frontMatter?.pinned ?? false
        notes[index].updatedAt = modified ?? notes[index].updatedAt
        setBodyExtras(extras, for: created.id)
        dispatchDerivedIndexes(.metadata(notes[index]))
    }

    /// New files (and copies whose id another file has) become notes; `known` entries already in
    /// `markdown-files.json` keep their id. A file whose front matter names a note that has no file is that note.
    struct NewFile {
        var id: UUID?
        var path: String
        var assign: Bool
    }

    /// The files unchanged for `newFileSettleDelay`; a scan is scheduled for the others, which an app may still be
    /// writing.
    private func settledFiles(_ files: [NewFile]) -> [NewFile] {
        guard let storage = markdownStorage else { return [] }
        let now = markdownClock()
        var wait: TimeInterval?
        let settled = files.filter { file in
            guard let stat = MarkdownFileStat.of(storage.url(of: file.path)) else { return true }
            let age = now.timeIntervalSince(Date(timeIntervalSince1970: Double(stat.mtimeNs) / 1e9))
            guard age < newFileSettleDelay else { return true }
            wait = min(wait ?? .infinity, newFileSettleDelay - max(age, 0))
            return false
        }
        if let wait {
            DispatchQueue.main.asyncAfter(deadline: .now() + wait + 0.1) { [weak self] in
                MainActor.assumeIsolated { self?.markdownFolderNeedsScan() }
            }
        }
        return settled
    }

    private func importFiles(_ files: [NewFile], atLaunch: Bool) {
        guard let storage = markdownStorage, !files.isEmpty else { return }
        var metas: [NoteMeta] = []
        var bodies: [UUID: NSAttributedString] = [:]
        let journaled = Set(syncDeletions().keys)
        var relinked = false
        for file in files {
            if file.id == nil, storage.index.id(forPath: file.path) != nil { continue }
            let url = storage.url(of: file.path)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            var id = file.id ?? UUID()
            var assign = file.assign
            if file.id == nil, let data = try? Data(contentsOf: url), let named = FolderScanner.frontMatterID(data) {
                if let existing = note(with: named), storage.index.entry(named) == nil, !metas.contains(where: { $0.id == named }) {
                    do { try storage.adopt(named, at: file.path, assignID: false) } catch { continue }
                    applyContentChangeAfterRelink(existing.id, atLaunch: atLaunch)
                    relinked = true
                    continue
                }
                if note(with: named) == nil, storage.index.entry(named) == nil, !journaled.contains(named), !isTombstoned(named),
                   !metas.contains(where: { $0.id == named }) {
                    id = named
                    assign = false
                }
            }
            let adopted: MarkdownBodyStorage.Adopted
            do {
                adopted = try storage.adopt(id, at: file.path, assignID: assign)
            } catch {
                NSLog("NoteIt: couldn't add \(file.path): \(error)")
                continue
            }
            let meta = importedMeta(id, path: file.path, adopted: adopted)
            metas.append(meta)
            bodies[id] = adopted.body.text
            setBodyExtras(adopted.body.extras, for: id)
            storage.markPlaced(meta)
        }
        if !metas.isEmpty {
            addLoadedNotes(metas, bodies: bodies)
            if !atLaunch { for meta in metas { postLocalNoteChange(meta.id, .created) } }
        }
        if !metas.isEmpty || relinked { commitOutsideMetadataChange() }
    }

    private func applyContentChangeAfterRelink(_ id: UUID, atLaunch: Bool) {
        guard let storage = markdownStorage, let index = noteIndex(id), let body = try? storage.read(id) else { return }
        var meta = notes[index]
        Self.applyDerivedFields(to: &meta, from: body.text)
        notes[index] = meta
        dropCachedBody(id)
        setBodyExtras(body.extras, for: id)
        dispatchDerivedIndexes(.changed(meta, body.text))
        storage.markPlaced(meta)
        if !atLaunch { externallyUpdatedNoteID = id }
    }

    private func importedMeta(_ id: UUID, path: String, adopted: MarkdownBodyStorage.Adopted) -> NoteMeta {
        let frontMatter = adopted.frontMatter
        let inTrash = FolderScanner.isTrash(path)
        let now = Date()
        var meta = NoteMeta(id: id, notebookID: inTrash ? nil : notebookID(forFolder: MarkdownPathIndex.folder(of: path)),
                            title: "", preview: "", isPinned: frontMatter?.pinned ?? false,
                            createdAt: frontMatter?.created ?? adopted.created ?? adopted.modified ?? now,
                            updatedAt: frontMatter?.updated ?? adopted.modified ?? now, tags: [], revision: UUID())
        if inTrash { meta.deletedAt = frontMatter?.deleted ?? adopted.modified ?? now }
        meta.conflictSource = frontMatter?.conflictSource
        meta.conflictOriginalID = frontMatter?.conflictOf
        Self.applyDerivedFields(to: &meta, from: adopted.body.text)
        return meta
    }

    // MARK: Deletions

    /// Holds `removed` instead of deleting when the batch is large, or joins a batch already held. Held notes stay
    /// in the library, read-only, with no tombstone, until the user confirms or their files come back.
    private func holdRemovals(_ removed: Set<UUID>, atLaunch: Bool, confirmed: Bool) -> Bool {
        guard let storage = markdownStorage, !confirmed else { return false }
        guard !heldMarkdownDeletions.isEmpty
                || MassDeletionGuard.mustHold(removed: removed.count, totalFiles: storage.index.ids.count) else { return false }
        let added = removed.subtracting(heldMarkdownDeletions)
        heldMarkdownDeletions.formUnion(removed)
        for id in removed {
            if !atLaunch { handOverPendingEdits(id) }
            blockMarkdownBodyWrites(id, reason: Self.missingFileReason)
        }
        MassDeletionGuard.save(heldMarkdownDeletions, dataDir: rootURL)
        if !added.isEmpty {
            NSLog("NoteIt: \(removed.count) note files disappeared from the folder; waiting for the user before deleting them")
            if !atLaunch { onManyNotesDisappeared?(heldMarkdownDeletions.count) }
        }
        return true
    }

    /// Held notes whose files are back (or which are gone from the library) leave the batch.
    private func releaseReturnedDeletions() {
        guard let storage = markdownStorage, !heldMarkdownDeletions.isEmpty else { return }
        let returned = heldMarkdownDeletions.filter { id in
            guard note(with: id) != nil, let entry = storage.index.entry(id) else { return true }
            return FileManager.default.fileExists(atPath: storage.url(of: entry.path).path)
        }
        guard !returned.isEmpty else { return }
        heldMarkdownDeletions.subtract(returned)
        for id in returned {
            unblockMarkdownBodyWrites(id, reason: Self.missingFileReason)
            dropCachedBody(id)
        }
        MassDeletionGuard.save(heldMarkdownDeletions, dataDir: rootURL)
    }

    /// Asks about a batch still held from an earlier session; the app calls this after launch.
    func askAboutHeldDeletions() {
        guard !heldMarkdownDeletions.isEmpty else { return }
        onManyNotesDisappeared?(heldMarkdownDeletions.count)
    }

    /// **Move to Recently Deleted**: the held notes whose files are still missing are deleted as usual.
    func confirmHeldDeletions() {
        guard let storage = markdownStorage, storage.contentRootExists, !heldMarkdownDeletions.isEmpty else { return }
        let held = heldMarkdownDeletions
        heldMarkdownDeletions = []
        MassDeletionGuard.save([], dataDir: rootURL)
        for id in held { unblockMarkdownBodyWrites(id, reason: Self.missingFileReason) }
        let result = FolderScanner.scan(contentRoot: storage.contentRootURL, index: storage.index)
        guard storage.contentRootExists else { return markdownFolderWentMissing() }
        applyExternalChanges(result, atLaunch: false, confirmsMassDeletion: true)
    }

    /// What a held note shows: its last known text, since its file is missing.
    func heldMarkdownBody(_ id: UUID) -> StoredBody? {
        guard heldMarkdownDeletions.contains(id), let storage = markdownStorage else { return nil }
        if let known = storage.lastKnownBody(id) { return known }
        guard let version = history.versions(of: id).first, let loaded = try? history.load(version) else { return nil }
        return StoredBody(text: loaded.text, extras: loaded.extras ?? .empty)
    }

    /// Files deleted outside NoteIt: their notes go to Recently Deleted, with their last known text written to
    /// `.trash/` so Recover works. A batch the mass-deletion guard holds is kept for the user instead.
    private func applyRemovals(_ removed: Set<UUID>, atLaunch: Bool) -> Bool {
        guard let storage = markdownStorage else { return false }
        let date = Date()
        var moved: [UUID] = []
        for id in removed.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let meta = note(with: id) else {
                storage.forget(id)
                continue
            }
            if !atLaunch { handOverPendingEdits(id) }
            var deleted = meta
            deleted.deletedAt = meta.deletedAt ?? date
            let lastKnown = storage.lastKnownBody(id)
            var text = cachedBody(id) ?? lastKnown?.text
            if text == nil, let version = history.versions(of: id).first, let loaded = try? history.load(version) {
                text = loaded.text
            }
            let extras = bodyExtras[id] ?? lastKnown?.extras ?? .empty
            do {
                try storage.writeDeletedCopy(text ?? NSAttributedString(string: meta.title), extras: extras, for: deleted)
            } catch {
                NSLog("NoteIt: couldn't keep the text of note \(id), whose file was deleted: \(error)")
                continue
            }
            if meta.deletedAt == nil { moved.append(id) }
        }
        guard !moved.isEmpty else { return false }
        for id in moved {
            if selectedNoteID == id, !atLaunch { selectNeighbor(of: id) }
            guard let index = noteIndex(id) else { continue }
            notes[index].deletedAt = date
            notes[index].revision = UUID()
            dispatchDerivedIndexes(.metadata(notes[index]))
            if !atLaunch { postLocalNoteChange(id, .deleted) }
        }
        return true
    }
}
