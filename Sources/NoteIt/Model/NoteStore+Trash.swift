import AppKit
import Foundation

/// Recently Deleted: deleting a note sets `deletedAt` (a normal, synced metadata change). Notes are removed
/// for good, through the tombstone path in `deleteNotes`, 30 days later or when the user asks.
extension NoteStore {
    nonisolated static let recentlyDeletedRetention: TimeInterval = TrashPolicy.retention
    static let purgeCheckInterval: TimeInterval = 24 * 60 * 60

    private static var purgeTimer: Timer?

    var activeNotes: [NoteMeta] { notes.filter { $0.deletedAt == nil } }
    var deletedNotes: [NoteMeta] { notes.filter { $0.deletedAt != nil } }
    var hasRecentlyDeleted: Bool { notes.contains { $0.deletedAt != nil } }

    /// Where a recovered note goes when its notebook no longer exists: the notebook named Inbox, if any.
    /// Without one the note has no notebook and shows under All Notes.
    var inboxNotebookID: UUID? {
        sortedNotebooks.first { $0.name.caseInsensitiveCompare("Inbox") == .orderedSame }?.id
    }

    func purgeDate(of meta: NoteMeta) -> Date? {
        meta.deletedAt.map { TrashPolicy.purgeDate(deletedAt: $0) }
    }

    /// Moves notes to Recently Deleted and returns the ones that moved. Undoing recovers them.
    @discardableResult
    func moveToRecentlyDeleted(_ ids: [UUID], at date: Date = Date(), undoManager: UndoManager? = nil) -> [UUID] {
        var moved: [UUID] = []
        for id in ids {
            guard note(with: id)?.deletedAt == nil, note(with: id) != nil else { continue }
            handOverPendingEdits(id)
            if selectedNoteID == id { selectNeighbor(of: id) }
            guard let index = noteIndex(id) else { continue }
            notes[index].deletedAt = date
            notes[index].revision = UUID()
            moved.append(id)
        }
        guard !moved.isEmpty else { return [] }
        commitUserMetadataChange()
        if let undoManager {
            undoManager.registerUndo(withTarget: self) { store in
                MainActor.assumeIsolated {
                    let recovered = store.recover(moved, undoManager: undoManager)
                    if recovered.count == 1, store.selection != .recentlyDeleted { store.selectedNoteID = recovered[0] }
                }
            }
            undoManager.setActionName(moved.count == 1 ? "Delete Note" : "Delete Notes")
        }
        return moved
    }

    /// Puts notes back in their notebook, or in Inbox when that notebook is gone. Returns the ones recovered.
    @discardableResult
    func recover(_ ids: [UUID], undoManager: UndoManager? = nil) -> [UUID] {
        var recovered: [UUID] = []
        for id in ids {
            guard let index = noteIndex(id), notes[index].deletedAt != nil else { continue }
            notes[index].deletedAt = nil
            if let nb = notes[index].notebookID, notebook(with: nb) == nil {
                notes[index].notebookID = inboxNotebookID
            }
            notes[index].revision = UUID()
            recovered.append(id)
        }
        guard !recovered.isEmpty else { return [] }
        commitUserMetadataChange()
        if let undoManager {
            undoManager.registerUndo(withTarget: self) { store in
                MainActor.assumeIsolated { _ = store.moveToRecentlyDeleted(recovered, undoManager: undoManager) }
            }
            undoManager.setActionName(recovered.count == 1 ? "Recover Note" : "Recover Notes")
        }
        return recovered
    }

    /// Removes notes in Recently Deleted for good. Notes not in Recently Deleted are left alone.
    func deleteNow(_ ids: [UUID]) {
        deleteNotes(ids.filter { note(with: $0)?.deletedAt != nil })
    }

    func emptyRecentlyDeleted() {
        deleteNow(deletedNotes.map(\.id))
    }

    /// Removes notes deleted more than 30 days before `now`, then prunes version history.
    @discardableResult
    func purgeExpiredDeletedNotes(now: Date = Date()) -> Int {
        let expired = notes.filter { meta in
            guard let deletedAt = meta.deletedAt else { return false }
            return TrashPolicy.isExpired(deletedAt: deletedAt, now: now)
        }.map(\.id)
        if !expired.isEmpty { deleteNotes(expired) }
        history.pruneAll(keeping: Set(notes.map(\.id)))
        return expired.count
    }

    /// Purges at launch and once a day after that.
    func startRecentlyDeletedMaintenance() {
        purgeExpiredDeletedNotes()
        guard Self.purgeTimer == nil else { return }
        let timer = Timer(timeInterval: Self.purgeCheckInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.purgeExpiredDeletedNotes() }
        }
        timer.tolerance = 60 * 60
        RunLoop.main.add(timer, forMode: .common)
        Self.purgeTimer = timer
    }

    /// "Deleted 3 days ago. It will be removed in 27 days."
    nonisolated static func deletionSummary(deletedAt: Date, now: Date = Date()) -> String {
        TrashPolicy.deletionSummary(deletedAt: deletedAt, now: now)
    }
}
