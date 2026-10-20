import Foundation
import NoteItCore

/// The Mac's copy of the last decrypted remote JSON per record, with one lifecycle for every record kind that
/// keeps raw meta (foundations Task 3.5 lists what a later kind adds). Files:
/// `<rootURL>/sync-meta-raw/<kind.rawValue>/<UUID>.json`, one folder per kind, so records of different kinds with
/// the same UUID never share a file.
///
/// rawValue is the folder name. Later kinds add a case: organise `smartFolders = "smart-folders"`,
/// surfaces-polish `boards`. The switches in appliedRemoteRevision and isDurablyListed have no default, so a new
/// case doesn't compile until it supplies both arms.
enum RawMetaKind: String, CaseIterable, Sendable, Codable {
    case notes, notebooks
}

/// A raw meta file's content. `sourceRevision` is the `RecordPayload.revision` of the remote meta in `meta` (the
/// revision the engine records as `SyncState.Base.revision` when it applies that payload); `meta` is the
/// decrypted bytes.
struct RawMeta: Codable, Equatable, Sendable {
    var sourceRevision: UUID
    var meta: Data
}

extension NoteStore {
    var rawMetaURL: URL { rootURL.appendingPathComponent("sync-meta-raw", isDirectory: true) }
    private var rawMetaDeletionQueueURL: URL { rawMetaURL.appendingPathComponent("pending-deletions.json") }

    func rawMetaFileURL(_ id: UUID, kind: RawMetaKind) -> URL {
        rawMetaURL.appendingPathComponent(kind.rawValue, isDirectory: true)
            .appendingPathComponent("\(id.uuidString).json")
    }

    /// The revision of the last remote payload applied to the record, from that kind's own applied-revision map.
    /// nil for a local-only record.
    func appliedRemoteRevision(for id: UUID, kind: RawMetaKind) -> UUID? {
        switch kind {
        case .notes: appliedRemoteRevisions.notes[id.uuidString]
        case .notebooks: appliedRemoteRevisions.notebooks[id.uuidString]
        }
    }

    /// The raw meta only when its `sourceRevision` equals `appliedRemoteRevision(for:kind:)`; otherwise nil, as if
    /// there were no file. The file stays until the next successful apply of that record replaces it.
    func lastRemoteMeta(for id: UUID, kind: RawMetaKind) -> Data? {
        guard let applied = appliedRemoteRevision(for: id, kind: kind),
              let data = try? Data(contentsOf: rawMetaFileURL(id, kind: kind)) else { return nil }
        guard let raw = try? Self.decoder.decode(RawMeta.self, from: data) else {
            NSLog("NoteIt: unreadable sync meta copy for \(kind.rawValue) \(id); exporting without it")
            return nil
        }
        return raw.sourceRevision == applied ? raw.meta : nil
    }

    /// nil removes. Apply writes it before the record is applied; a throw skips that record's apply this pass.
    /// A removed record's file is not removed here (see queueRawMetaDeletion).
    func setLastRemoteMeta(_ raw: RawMeta?, for id: UUID, kind: RawMetaKind) throws {
        guard let raw else {
            try removeRawMetaFile(id, kind: kind)
            return
        }
        let url = rawMetaFileURL(id, kind: kind)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(raw).write(to: url, options: .atomic)
        // The record is back, so a deletion queued when it was removed must not take the new file.
        if rawMetaDeletionQueue[kind]?.remove(id) != nil {
            if rawMetaDeletionQueue[kind]?.isEmpty == true { rawMetaDeletionQueue[kind] = nil }
            saveRawMetaDeletionQueue()
        }
    }

    /// Deferred deletion for a removed record of any kind except notes. Queues (kind, id), persisted with the
    /// tombstones; the pending-trash pass (trashPendingBodies, after a successful save) deletes the file once
    /// `isDurablyListed` is false, and keeps it queued when the delete throws. A purged note's file instead rides
    /// on pendingTrash and is deleted with the body's .trash move, after library.json no longer lists the note.
    func queueRawMetaDeletion(_ id: UUID, kind: RawMetaKind) {
        guard rawMetaDeletionQueue[kind, default: []].insert(id).inserted else { return }
        saveRawMetaDeletionQueue()
    }

    /// Whether the kind's last successfully saved file still lists the record (notes and notebooks: library.json).
    /// Unknown (no saved library yet) counts as listed.
    func isDurablyListed(_ id: UUID, kind: RawMetaKind) -> Bool {
        switch kind {
        case .notes: libraryNoteIDsOnDisk?.contains(id) ?? true
        case .notebooks: libraryNotebookIDsOnDisk?.contains(id) ?? true
        }
    }

    func removeRawMetaFile(_ id: UUID, kind: RawMetaKind) throws {
        let url = rawMetaFileURL(id, kind: kind)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Part of the pending-trash pass, which runs only after a successful library save.
    func drainRawMetaDeletionQueue() {
        guard !rawMetaDeletionQueue.isEmpty else { return }
        let before = rawMetaDeletionQueue
        for (kind, ids) in before {
            for id in ids {
                if isDurablyListed(id, kind: kind) {
                    // Saved as listed again after the removal: the record is back and its file belongs to it.
                    if !hasRecord(id, kind: kind) { continue }
                } else {
                    do {
                        try removeRawMetaFile(id, kind: kind)
                    } catch {
                        NSLog("NoteIt: failed to delete the sync meta copy of removed \(kind.rawValue) \(id): \(error)")
                        continue
                    }
                }
                rawMetaDeletionQueue[kind]?.remove(id)
                if rawMetaDeletionQueue[kind]?.isEmpty == true { rawMetaDeletionQueue[kind] = nil }
            }
        }
        if rawMetaDeletionQueue != before { saveRawMetaDeletionQueue() }
    }

    private func hasRecord(_ id: UUID, kind: RawMetaKind) -> Bool {
        switch kind {
        case .notes: note(with: id) != nil
        case .notebooks: notebook(with: id) != nil
        }
    }

    private struct QueuedDeletion: Codable {
        var kind: RawMetaKind
        var id: UUID
    }

    func loadRawMetaDeletionQueue() {
        guard let data = try? Data(contentsOf: rawMetaDeletionQueueURL) else { return }
        guard let entries = try? Self.decoder.decode([QueuedDeletion].self, from: data) else {
            NSLog("NoteIt: \(rawMetaDeletionQueueURL.lastPathComponent) is unreadable; ignoring it")
            return
        }
        for entry in entries { rawMetaDeletionQueue[entry.kind, default: []].insert(entry.id) }
    }

    func saveRawMetaDeletionQueue() {
        let fm = FileManager.default
        do {
            if rawMetaDeletionQueue.isEmpty {
                if fm.fileExists(atPath: rawMetaDeletionQueueURL.path) { try fm.removeItem(at: rawMetaDeletionQueueURL) }
                return
            }
            let entries = rawMetaDeletionQueue
                .flatMap { kind, ids in ids.map { QueuedDeletion(kind: kind, id: $0) } }
                .sorted { ($0.kind.rawValue, $0.id.uuidString) < ($1.kind.rawValue, $1.id.uuidString) }
            try fm.createDirectory(at: rawMetaURL, withIntermediateDirectories: true)
            try Self.encoder.encode(entries).write(to: rawMetaDeletionQueueURL, options: .atomic)
        } catch {
            NSLog("NoteIt: failed to save the sync meta deletion queue: \(error)")
        }
    }
}
