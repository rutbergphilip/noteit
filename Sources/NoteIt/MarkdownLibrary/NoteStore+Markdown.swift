import AppKit
import Foundation
import NoteItCore
import NoteItMarkdown
import NoteItSync

/// A Markdown library in `NoteStore`: folders follow notebooks on every flush, files are renamed after their
/// title when the note is left alone, and changes made outside NoteIt are applied from folder scans
/// (markdown-storage spec §3.4–§3.5).
extension NoteStore {
    static let outsideNoteItSource = "Outside NoteIt"
    static let missingFileReason = "This note’s file is missing from the folder."
    /// Posted (object: the store) when a scan succeeds after the Markdown folder was checked or didn't answer.
    static let markdownFolderAnswered = Notification.Name("NoteItMarkdownFolderAnswered")
    /// A file is renamed after its title once the note has been left alone this long.
    static let idleRenameDelay: TimeInterval = 5

    var markdownStorage: MarkdownBodyStorage? { bodyStorage as? MarkdownBodyStorage }

    // MARK: Layout

    /// Folders and front matter follow notebooks and note metadata; files follow titles once idle. Planned by
    /// `flush()` after the body writes and run with them on the IO queue.
    func planMarkdownLayout(_ pass: inout MarkdownWritePass) {
        guard let storage = markdownStorage else { return }
        storage.setNotebooks(notebooks)
        pass.layout = true
        pass.notebookIDs = Set(notebooks.map(\.id))
        if libraryDirty {
            for meta in notes where !isBodyDirty(meta.id) && !isBodyWriteBlocked(meta.id) && storage.needsMetadataWrite(meta) {
                pass.metadata.append((meta, notebook(with: meta.notebookID)))
            }
        }
        let now = markdownClock()
        var waiting: TimeInterval?
        let writing = Set(pass.bodies.map(\.meta.id))
        for meta in notes where storage.wantsRename(meta) && (writing.contains(meta.id) || !isBodyDirty(meta.id))
            && !isBodyWriteBlocked(meta.id) {
            let idle = now.timeIntervalSince(meta.updatedAt)
            if meta.id == selectedNoteID, idle < Self.idleRenameDelay {
                waiting = min(waiting ?? .infinity, Self.idleRenameDelay - idle)
                continue
            }
            pass.renames.append(meta)
        }
        hasPendingMarkdownRenames = waiting != nil
        if let waiting { scheduleSave(after: max(waiting, 0.5)) }
    }

    /// Leaving a note renames its file after the title right away.
    func markdownSelectionChanged(from old: UUID?) {
        guard let old, let storage = markdownStorage, let meta = note(with: old), storage.wantsRename(meta) else { return }
        scheduleSave()
    }

    func handleMarkdownWriteError(_ error: Error, for id: UUID) {
        NSLog("NoteIt: couldn't update the file of note \(id): \(error)")
        switch error as? MarkdownStorageError {
        case .unreadable: blockMarkdownBodyWrites(id, reason: MarkdownBodyStorage.unreadableReason)
        case .externallyChanged: markdownFolderNeedsScan()
        case .folderMissing, .unresponsive, nil: break
        }
    }

    // MARK: Scans

    /// Rescans the content folder off the main thread and applies the result on it; calls while a scan runs ask
    /// for one more after it. A scan that doesn't finish within `markdownScanTimeout` makes the folder unavailable.
    func markdownFolderNeedsScan() {
        guard let storage = markdownStorage, !isClosedForLibrarySwitch else { return finishScanWaiters(markdownStorage == nil) }
        guard !markdownScanRunning else {
            markdownScanAgain = true
            return
        }
        markdownScanRunning = true
        let waiters = markdownScanWaiters
        markdownScanWaiters = []
        let entries = storage.index.allEntries
        let folders = storage.index.allNotebookFolders
        let timeout = markdownLaunchScanPending ? markdownLaunchScanTimeout : markdownScanTimeout
        let job = MarkdownIOJob()
        markdownScanJob = job
        BoundedFileAccess.shared.run(key: "markdown-scan:" + storage.contentRootURL.path, timeout: timeout,
                                     markdownScanWork(storage)) { outcome in
            job.finished { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.markdownScanJob === job { self.markdownScanJob = nil }
                    self.markdownScanRunning = false
                    guard self.markdownStorage === storage else {
                        waiters.forEach { $0(false) }
                        return
                    }
                    let applied = self.finishMarkdownScan(outcome, since: (entries, folders))
                    if let applied {
                        waiters.forEach { $0(applied) }
                    } else {
                        // Left for a scan after the queued writes, or a stale result: the waiters wait for that one.
                        self.markdownScanWaiters.insert(contentsOf: waiters, at: 0)
                        if !self.markdownScanAfterWrites { self.markdownScanAgain = true }
                    }
                    if self.markdownScanAgain {
                        self.markdownScanAgain = false
                        self.markdownFolderNeedsScan()
                    }
                }
            }
        }
    }

    private func finishScanWaiters(_ applied: Bool) {
        let waiters = markdownScanWaiters
        markdownScanWaiters = []
        waiters.forEach { $0(applied) }
    }

    /// Scans off the main thread and applies the result after any queued writes, then calls `done`: for a caller
    /// that needs the library caught up with the folder before it goes on (a conversion). False when the folder
    /// is missing or doesn't answer.
    func rescanMarkdownFolder(then done: @escaping (Bool) -> Void) {
        guard markdownStorage != nil, !isClosedForLibrarySwitch else { return done(true) }
        markdownScanWaiters.append(done)
        markdownFolderNeedsScan()
    }

    func rescanMarkdownFolder() async -> Bool {
        await withCheckedContinuation { continuation in
            rescanMarkdownFolder { continuation.resume(returning: $0) }
        }
    }

    enum MarkdownScanOutcome {
        case missing
        case scanned(FolderScanResult, MarkdownScanReads)
    }

    private func markdownScanWork(_ storage: MarkdownBodyStorage) -> () -> MarkdownScanOutcome {
        let root = storage.contentRootURL
        let index = storage.index
        let check = storage.rootCheck
        let ledger = storage.ledger
        let scan = markdownFolderScan
        let known = MarkdownScanReads.Known(noteIDs: Set(notes.map(\.id)), notebookIDs: Set(notebooks.map(\.id)),
                                            held: heldMarkdownDeletions)
        return {
            guard check(root) else { return .missing }
            let result = scan(root, index, ledger)
            let reads = MarkdownScanReads.read(result, storage: storage, known: known)
            return check(root) ? .scanned(result, reads) : .missing
        }
    }

    /// `since`: the index when a background scan started. Notes NoteIt wrote meanwhile are left to the next scan,
    /// and a notebook folder NoteIt renamed meanwhile makes the whole result stale. Whether the scan was applied;
    /// nil when it is left for a later scan.
    @discardableResult
    private func finishMarkdownScan(_ outcome: MarkdownScanOutcome?,
                                    since before: (entries: [UUID: MarkdownFileEntry], folders: [UUID: String])?) -> Bool? {
        guard let storage = markdownStorage, !isClosedForLibrarySwitch else { return false }
        switch outcome {
        case nil:
            markdownConfirmingHeldDeletions = false
            markdownFolderBecameUnavailable()
            return false
        case .missing:
            markdownConfirmingHeldDeletions = false
            markdownFolderUnavailable = false
            markdownFolderChecking = false
            markdownFolderWentMissing()
            return false
        case .scanned(var result, let reads):
            // Writes still on the IO queue may be half recorded; the scan is applied once they finish.
            if before != nil, !markdownIOJobs.isEmpty {
                markdownScanAfterWrites = true
                if markdownFolderUnavailable, !markdownFolderChecking { markdownFolderBecameUnavailable() }
                return nil
            }
            let wasUnavailable = markdownFolderUnavailable
            markdownFolderUnavailable = false
            markdownFolderChecking = false
            markdownFolderReportedMissing = false
            if let before {
                guard storage.index.allNotebookFolders == before.folders else { return nil }
                let now = storage.index.allEntries
                let written = Set(before.entries.keys).symmetricDifference(now.keys)
                    .union(now.filter { id, entry in
                        before.entries[id].map { $0.path != entry.path || $0.sha256 != entry.sha256 } ?? false
                    }.keys)
                result.leaveOut(written)
            }
            let confirming = markdownConfirmingHeldDeletions && !heldMarkdownDeletions.isEmpty
            markdownConfirmingHeldDeletions = false
            if confirming {
                let held = heldMarkdownDeletions
                heldMarkdownDeletions = []
                MassDeletionGuard.save([], dataDir: rootURL)
                for id in held { unblockMarkdownBodyWrites(id, reason: Self.missingFileReason) }
            }
            if markdownLaunchScanPending {
                applyLaunchScan(result, reads: reads, confirmsMassDeletion: confirming)
            } else {
                applyExternalChanges(result, reads: reads, atLaunch: false, confirmsMassDeletion: confirming)
            }
            if wasUnavailable {
                scheduleSave()
                // The open note stays unread (read-only) until the editor reads it again.
                let unread = markdownBodiesNotRead
                markdownBodiesNotRead = unread.filter { $0 == selectedNoteID }
                if let selected = selectedNoteID, unread.contains(selected), cachedBody(selected) == nil {
                    externallyUpdatedNoteID = selected
                }
                readDeferredMarkdownBodies()
                NotificationCenter.default.post(name: Self.markdownFolderAnswered, object: self)
            }
            startMarkdownWatcherIfReady()
            return true
        }
    }

    /// The folder doesn't answer (a network volume that hangs): notes stay as they are and read-only, nothing is
    /// treated as removed, and the folder is tried again every `markdownUnavailableRetryInterval`.
    func markdownFolderBecameUnavailable() {
        guard let storage = markdownStorage else { return }
        if !markdownFolderUnavailable || markdownFolderChecking {
            markdownFolderUnavailable = true
            markdownFolderChecking = false
            NSLog("NoteIt: the library folder \(storage.contentRootURL.path) doesn't respond; nothing is written until it does")
        }
        guard !markdownUnavailableRetryScheduled else { return }
        markdownUnavailableRetryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + markdownUnavailableRetryInterval) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.markdownUnavailableRetryScheduled = false
                if self.markdownFolderUnavailable { self.markdownFolderNeedsScan() }
            }
        }
    }

    /// Starts the FSEvents watcher; the app calls this once the library is loaded. While the folder doesn't
    /// respond the watcher waits for the first scan that succeeds; starting it touches the folder, so that runs
    /// off the main thread too.
    func startWatchingMarkdownFolder() {
        guard markdownStorage != nil else { return }
        markdownWatchWanted = true
        startMarkdownWatcherIfReady()
        markdownFolderNeedsScan()
    }

    func startMarkdownWatcherIfReady() {
        guard let storage = markdownStorage, markdownWatchWanted, markdownWatcher == nil, markdownWatcherStarting == nil,
              !markdownFolderUnavailable, !isClosedForLibrarySwitch else { return }
        let watcher = MarkdownFolderWatcher(root: storage.contentRootURL,
                                            onChange: { [weak self] in self?.markdownFolderNeedsScan() },
                                            onRootChanged: { [weak self] in self?.markdownFolderNeedsScan() })
        markdownWatcherStarting = watcher
        // A start that finishes after the timeout finds the watcher stopped and tears its stream down again.
        BoundedFileAccess.shared.run(key: "markdown-watch:" + storage.contentRootURL.path, timeout: storage.rootTimeout,
                                     { watcher.start() }) { started in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.markdownWatcherStarting === watcher else { return watcher.stop() }
                    self.markdownWatcherStarting = nil
                    guard let started else {
                        watcher.stop()
                        return self.markdownFolderBecameUnavailable()
                    }
                    guard started, self.markdownStorage === storage, self.markdownWatchWanted, !self.isClosedForLibrarySwitch else {
                        watcher.stop()
                        if !started { NSLog("NoteIt: couldn't watch \(storage.contentRootURL.path) for changes") }
                        return
                    }
                    self.markdownWatcher = watcher
                    self.startAttachmentSweepTimer(storage)
                }
            }
        }
    }

    private func startAttachmentSweepTimer(_ storage: MarkdownBodyStorage) {
        guard attachmentSweepTimer == nil else { return }
        let attachments = storage.attachments
        let timer = Timer(timeInterval: Self.attachmentSweepInterval, repeats: true) { _ in attachments.scheduleSweep() }
        timer.tolerance = 5 * 60
        RunLoop.main.add(timer, forMode: .common)
        attachmentSweepTimer = timer
    }

    func stopWatchingMarkdownFolder() {
        markdownWatchWanted = false
        markdownWatcherStarting = nil
        markdownWatcher?.stop()
        markdownWatcher = nil
        attachmentSweepTimer?.invalidate()
        attachmentSweepTimer = nil
    }

    /// How often unused attachments are looked for when nothing else is written.
    static let attachmentSweepInterval: TimeInterval = 60 * 60

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
        storage.onRootUnresponsive = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.markdownFolderBecameUnavailable() } }
        }
        // The folder may be on a volume that hangs: the library opens from library.json, read-only, and the folder is
        // scanned off the main thread.
        markdownLaunchScanPending = true
        markdownFolderUnavailable = true
        markdownFolderChecking = true
        markdownFolderNeedsScan()
    }

    /// The first scan: new files take their ids right away, files whose notes aren't in `library.json` become notes,
    /// and the notes it changed are kept for indexes that start later. Nothing is versioned.
    private func applyLaunchScan(_ result: FolderScanResult, reads: MarkdownScanReads, confirmsMassDeletion: Bool) {
        guard let storage = markdownStorage else { return }
        markdownLaunchScanPending = false
        let before = notes
        applyExternalChanges(result, reads: reads, atLaunch: true, confirmsMassDeletion: confirmsMassDeletion)
        let tombstones = Set(syncDeletions().keys)
        let orphans = storage.index.ids.filter { note(with: $0) == nil && !tombstones.contains($0) && !isTombstoned($0) }
        if !orphans.isEmpty {
            importFiles(orphans.compactMap { id in storage.index.entry(id).map { NewFile(id: id, path: $0.path, assign: false) } },
                        reads: reads, atLaunch: true)
        }
        let beforeByID = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var changed = Set(notes.filter { beforeByID[$0.id] != $0 }.map(\.id))
        changed.formUnion(Set(beforeByID.keys).subtracting(notes.map(\.id)))
        changed.formUnion(result.changed.keys)
        changed.formUnion(result.moved.keys)
        notesChangedBeforeDerivedIndexes.formUnion(changed)
        if note(with: selectedNoteID) == nil { selectedNoteID = notes(for: selection, search: "").first?.id }
        flush()
    }

    /// Applies one scan: notebook folders first, so new files land in their notebooks, then files, then
    /// notebook folders that are gone. At launch nothing is versioned or flushed; the load saves the result.
    func applyExternalChanges(_ result: FolderScanResult, reads: MarkdownScanReads, atLaunch: Bool,
                              confirmsMassDeletion: Bool = false) {
        guard let storage = markdownStorage else { return }
        storage.setSkippedFiles(result.skipped.map(storage.url(of:)))
        var metadataChanged = applyNotebookFolders(result.notebookFolders, reads: reads)
        storage.setNotebooks(notebooks)

        for (id, path) in result.moved.sorted(by: { $0.value < $1.value }) {
            metadataChanged = applyMove(id, to: path, changed: result.changed[id] != nil, reads: reads, atLaunch: atLaunch)
                || metadataChanged
        }
        for (id, path) in result.changed.sorted(by: { $0.value < $1.value }) where result.moved[id] == nil {
            applyContentChange(id, at: path, reads: reads, atLaunch: atLaunch)
        }
        var newFiles: [NewFile] = result.added.sorted().map { NewFile(id: nil, path: $0, assign: true) }
        newFiles += result.duplicateIDs.sorted().map { NewFile(id: nil, path: $0, assign: true) }
        importFiles(atLaunch ? newFiles : settledFiles(newFiles, reads: reads), reads: reads, atLaunch: atLaunch)
        releaseReturnedDeletions(reads: reads)

        let removed = result.removed.filter { id in
            guard let entry = storage.index.entry(id) else { return false }
            return !reads.existing.contains(entry.path)
        }
        if !removed.isEmpty, !holdRemovals(removed, atLaunch: atLaunch, confirmed: confirmsMassDeletion) {
            metadataChanged = applyRemovals(removed, atLaunch: atLaunch) || metadataChanged
        }
        metadataChanged = removeNotebooksWithoutFolders(result.notebookFolders, reads: reads) || metadataChanged
        try? storage.index.save()
        if metadataChanged { commitOutsideMetadataChange() }
        storage.attachments.scheduleSweep()
    }

    // MARK: Notebook folders

    /// New folders become notebooks; renamed and moved folders rename and move theirs.
    private func applyNotebookFolders(_ folders: [String: NotebookFolderInfo], reads: MarkdownScanReads) -> Bool {
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
            guard var found = reads.notebookFiles[path] else { continue }
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
    private func removeNotebooksWithoutFolders(_ folders: [String: NotebookFolderInfo], reads: MarkdownScanReads) -> Bool {
        guard let storage = markdownStorage, heldMarkdownDeletions.isEmpty else { return false }
        let present = Set(folders.compactMap(\.value.id))
        var removed = false
        let tree = notebookTree
        for (id, path) in storage.index.allNotebookFolders where notebook(with: id) != nil && !present.contains(id) {
            guard tree.depth(of: id) <= NotebookFolders.maxDepth,
                  folders[path] == nil, !reads.existing.contains(path) else { continue }
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
    private func applyMove(_ id: UUID, to path: String, changed: Bool, reads: MarkdownScanReads, atLaunch: Bool) -> Bool {
        guard let storage = markdownStorage, noteIndex(id) != nil else { return false }
        if changed {
            storage.index.move(id, to: path)
            applyContentChange(id, at: path, reads: reads, atLaunch: atLaunch)
        } else {
            guard let file = reads.files[path] else { return false }
            storage.adopt(id, at: path, file: file, assignID: false)
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
    private func applyContentChange(_ id: UUID, at path: String, reads: MarkdownScanReads, atLaunch: Bool) {
        guard let storage = markdownStorage, let meta = note(with: id) else { return }
        guard let file = reads.files[path] else {
            return NSLog("NoteIt: couldn't read the changed file of note \(id)")
        }
        if let entry = storage.index.entry(id), entry.path == path, file.stat?.matches(entry) == true { return }
        if !atLaunch { handOverPendingEdits(id) }
        let unsaved = hasUnsavedBody(id)
        let old = cachedBody(id) ?? storage.lastKnownBody(id)?.text
        let adopted = storage.adopt(id, at: path, file: file, assignID: false).0
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
        // A reader that loaded the file after the edit leaves nothing older to keep in history.
        if atLaunch || meta.deletedAt != nil || meta.isLocked || old == nil || old?.isEqual(to: body.text) == true {
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
    private func settledFiles(_ files: [NewFile], reads: MarkdownScanReads) -> [NewFile] {
        let now = markdownClock()
        var wait: TimeInterval?
        let settled = files.filter { file in
            guard let stat = reads.files[file.path]?.stat else { return true }
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

    private func importFiles(_ files: [NewFile], reads: MarkdownScanReads, atLaunch: Bool) {
        guard let storage = markdownStorage, !files.isEmpty else { return }
        var metas: [NoteMeta] = []
        var bodies: [UUID: NSAttributedString] = [:]
        let journaled = Set(syncDeletions().keys)
        var relinked = false
        for file in files {
            if file.id == nil, storage.index.id(forPath: file.path) != nil { continue }
            guard let read = reads.files[file.path] else { continue }
            var id = file.id ?? UUID()
            var assign = file.assign
            if file.id == nil, let named = FolderScanner.frontMatterID(read.data) {
                if let existing = note(with: named), storage.index.entry(named) == nil, !metas.contains(where: { $0.id == named }) {
                    let adopted = storage.adopt(named, at: file.path, file: read, assignID: false).0
                    applyContentChangeAfterRelink(existing.id, body: adopted.body, atLaunch: atLaunch)
                    relinked = true
                    continue
                }
                if note(with: named) == nil, storage.index.entry(named) == nil, !journaled.contains(named), !isTombstoned(named),
                   !metas.contains(where: { $0.id == named }) {
                    id = named
                    assign = false
                }
            }
            let (adopted, idWrite) = storage.adopt(id, at: file.path, file: read, assignID: assign)
            if let idWrite {
                let path = file.path
                _ = enqueueMarkdownIO(storage, { storage -> Error? in
                    do { try storage.writeAssignedID(idWrite, for: id); return nil } catch { return error }
                }, then: { error in
                    if let error { NSLog("NoteIt: couldn't write the id of \(path): \(error)") }
                })
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

    private func applyContentChangeAfterRelink(_ id: UUID, body: StoredBody, atLaunch: Bool) {
        guard let storage = markdownStorage, let index = noteIndex(id) else { return }
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
            // The launch scan applies after the app is set up, so it asks like any other scan.
            onManyNotesDisappeared?(heldMarkdownDeletions.count)
        }
        return true
    }

    /// Held notes whose files are back (or which are gone from the library) leave the batch.
    private func releaseReturnedDeletions(reads: MarkdownScanReads) {
        guard let storage = markdownStorage, !heldMarkdownDeletions.isEmpty else { return }
        let returned = heldMarkdownDeletions.filter { id in
            guard note(with: id) != nil, let entry = storage.index.entry(id) else { return true }
            return reads.existing.contains(entry.path)
        }
        guard !returned.isEmpty else { return }
        heldMarkdownDeletions.subtract(returned)
        for id in returned {
            unblockMarkdownBodyWrites(id, reason: Self.missingFileReason)
            dropCachedBody(id)
        }
        MassDeletionGuard.save(heldMarkdownDeletions, dataDir: rootURL)
    }

    /// A held note whose file NoteIt wrote again (a sync apply) leaves the batch.
    func releaseHeldDeletion(_ id: UUID) {
        guard heldMarkdownDeletions.remove(id) != nil else { return }
        unblockMarkdownBodyWrites(id, reason: Self.missingFileReason)
        MassDeletionGuard.save(heldMarkdownDeletions, dataDir: rootURL)
    }

    /// Asks about a batch still held from an earlier session; the app calls this after launch.
    func askAboutHeldDeletions() {
        guard !heldMarkdownDeletions.isEmpty else { return }
        onManyNotesDisappeared?(heldMarkdownDeletions.count)
    }

    /// **Move to Recently Deleted**: the held notes whose files are still missing are deleted as usual, by the next
    /// scan that is applied (off the main thread, after any queued writes). A folder that is missing or doesn't
    /// answer keeps the batch held. `done` gets whether the scan was applied.
    func confirmHeldDeletions(then done: ((Bool) -> Void)? = nil) {
        guard markdownStorage != nil, !heldMarkdownDeletions.isEmpty else {
            done?(false)
            return
        }
        markdownConfirmingHeldDeletions = true
        rescanMarkdownFolder { done?($0) }
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
        var copies: [DeletedCopy] = []
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
            copies.append(DeletedCopy(meta: deleted, text: text ?? NSAttributedString(string: meta.title), extras: extras))
            if meta.deletedAt == nil { moved.append(id) }
        }
        keepDeletedCopies(copies, in: storage)
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

    private struct DeletedCopy {
        let meta: NoteMeta
        let text: NSAttributedString
        let extras: ContainerExtras
    }

    /// Writes the `.trash/` copies on the IO queue. A copy that can't be written stays as an unsaved body, which
    /// the next write puts in `.trash/` once the folder responds.
    private func keepDeletedCopies(_ copies: [DeletedCopy], in storage: MarkdownBodyStorage) {
        guard !copies.isEmpty else { return }
        nonisolated(unsafe) let pending = copies
        _ = enqueueMarkdownIO(storage, { storage -> [UUID] in
            pending.compactMap { copy in
                do {
                    try storage.writeDeletedCopy(copy.text, extras: copy.extras, for: copy.meta)
                    return nil
                } catch {
                    NSLog("NoteIt: couldn't keep the text of note \(copy.meta.id), whose file was deleted: \(error)")
                    return copy.meta.id
                }
            }
        }, then: { [weak self] failed in
            guard let self, !failed.isEmpty, self.markdownStorage === storage else { return }
            for copy in pending where failed.contains(copy.meta.id) && self.note(with: copy.meta.id) != nil {
                storage.allowRecreatingMissingFile(copy.meta.id)
                self.keepUnsavedBody(copy.meta.id, copy.text)
            }
        })
    }
}
