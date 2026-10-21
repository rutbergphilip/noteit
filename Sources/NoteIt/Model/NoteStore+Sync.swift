import AppKit
import NoteItSync

enum NoteStoreSyncError: Error, Equatable {
    case notFound(UUID)
    case unreadableBody(UUID)
    case missingBody(UUID)
    case invalidPayload(String)
}

/// Record-level API used by `NoteStoreSyncAdapter`. Remote applies never assign new revisions.
extension NoteStore {
    func syncRecords() -> [LocalRecord] {
        assignMissingRevisions()
        let books = notebooks.compactMap { nb in
            nb.revision.map { LocalRecord(id: nb.id, kind: .notebook, revision: $0, modifiedAt: nb.modifiedAt ?? .distantPast) }
        }
        let metas = notes.compactMap { meta in
            meta.revision.map { LocalRecord(id: meta.id, kind: .note, revision: $0, modifiedAt: meta.updatedAt) }
        }
        let folders = smartFolders.compactMap { folder in
            folder.revision.map { LocalRecord(id: folder.id, kind: .smartFolder, revision: $0, modifiedAt: folder.modifiedAt ?? .distantPast) }
        }
        return books + folders + metas
    }

    /// Journaled deletions of records that are really gone (stale entries are dropped).
    func syncDeletions() -> [UUID: LocalDeletion] {
        for id in syncDeletionJournal.keys where note(with: id) != nil || notebook(with: id) != nil {
            clearSyncDeletion(id)
        }
        return syncDeletionJournal.merging(smartFolderSyncDeletions) { journal, _ in journal }
    }

    /// O(1): the engine checks this right before every apply.
    func syncRevision(of id: UUID, kind: RecordKind) -> UUID? {
        switch kind {
        case .note: note(with: id)?.revision
        case .notebook: notebook(with: id)?.revision
        case .smartFolder: smartFolder(with: id)?.revision
        }
    }

    func exportPayload(id: UUID, kind: RecordKind, deviceID: String) throws -> RecordPayload {
        let (payload, source) = try exportPlan(id: id, kind: kind, deviceID: deviceID)
        return try Self.completeExport(payload, source)
    }

    /// Everything but the note body, which `completeExport` serializes (off the main actor in the adapter). The meta
    /// keeps fields from the last applied remote meta that this build doesn't know (`RawMetaOverlay`).
    func exportPlan(id: UUID, kind: RecordKind, deviceID: String) throws -> (RecordPayload, ExportBody?) {
        assignMissingRevisions()
        switch kind {
        case .notebook:
            guard let nb = notebook(with: id), let revision = nb.revision else { throw NoteStoreSyncError.notFound(id) }
            let meta = try RawMetaOverlay(lastDecrypted: lastRemoteMeta(for: id, kind: .notebooks))
                .merged(with: try Self.encoder.encode(nb), ownedKeys: Notebook.ownedCodingKeys)
            return (RecordPayload(id: id, kind: .notebook, revision: revision, modifiedAt: nb.modifiedAt ?? .distantPast,
                                  deviceID: deviceID, meta: meta), nil)
        case .smartFolder:
            guard let folder = smartFolder(with: id), let revision = folder.revision else { throw NoteStoreSyncError.notFound(id) }
            let meta = try RawMetaOverlay(lastDecrypted: lastRemoteMeta(for: id, kind: .smartFolders))
                .merged(with: try Self.encoder.encode(folder), ownedKeys: SmartFolder.ownedCodingKeys)
            return (RecordPayload(id: id, kind: .smartFolder, revision: revision, modifiedAt: folder.modifiedAt ?? .distantPast,
                                  deviceID: deviceID, meta: meta), nil)
        case .note:
            guard let meta = note(with: id), let revision = meta.revision else { throw NoteStoreSyncError.notFound(id) }
            // An unreadable body loads as empty; never push that over a good remote copy.
            if hasUnreadableBody(id) { throw NoteStoreSyncError.unreadableBody(id) }
            let merged = try RawMetaOverlay(lastDecrypted: lastRemoteMeta(for: id, kind: .notes))
                .merged(with: try Self.encoder.encode(meta), ownedKeys: NoteMeta.ownedCodingKeys)
            return (RecordPayload(id: id, kind: .note, revision: revision, modifiedAt: meta.updatedAt,
                                  deviceID: deviceID, meta: merged), try exportBodySource(id))
        }
    }

    nonisolated static func completeExport(_ payload: RecordPayload, _ source: ExportBody?) throws -> RecordPayload {
        guard let source else { return payload }
        let text: NSAttributedString
        switch source {
        case .text(let cached):
            text = cached
        case .file(let url):
            if FileManager.default.fileExists(atPath: url.path) {
                do { text = try readBody(at: url) } catch { throw NoteStoreSyncError.unreadableBody(payload.id) }
            } else {
                text = NSAttributedString()
            }
        }
        var complete = payload
        complete.body = try serializeBody(text)
        return complete
    }

    /// Inserts or replaces the record, keeping `payload.revision`. A note whose notebook hasn't arrived yet
    /// keeps its notebookID and shows under All Notes meanwhile.
    func applyRemote(_ payload: RecordPayload) throws {
        switch payload.kind {
        case .notebook:
            var nb = try Self.decodeMeta(Notebook.self, payload)
            nb.revision = payload.revision
            nb.modifiedAt = payload.modifiedAt
            // The raw copy goes first; if it can't be written the record isn't applied, and the next pass retries.
            try setLastRemoteMeta(RawMeta(sourceRevision: payload.revision, meta: payload.meta), for: nb.id, kind: .notebooks)
            applyRemoteNotebook(nb, hasParentKey: Notebook.recordHasParentKey(payload.meta))
        case .smartFolder:
            var folder = try Self.decodeMeta(SmartFolder.self, payload)
            folder.revision = payload.revision
            folder.modifiedAt = payload.modifiedAt
            try setLastRemoteMeta(RawMeta(sourceRevision: payload.revision, meta: payload.meta), for: folder.id, kind: .smartFolders)
            applyRemoteSmartFolder(folder)
        case .note:
            try applyPreparedRemoteNote(Self.prepareRemoteNote(payload, storage: bodyStorage))
        }
    }

    func applyRemoteDeletion(_ id: UUID, kind: RecordKind) {
        switch kind {
        case .notebook:
            removeNotebookForRemote(id)
        case .smartFolder:
            removeSmartFolderForRemote(id)
        case .note:
            clearSyncDeletion(id)
            removeNote(id, remote: true)
        }
    }

    /// Imports a remote note as a new note (new id and revision) whose title carries a conflict suffix.
    /// Notebook and smart folder conflicts are resolved last-writer-wins by the engine and never reach here.
    @discardableResult
    func importConflictCopy(_ payload: RecordPayload, fromDevice name: String) throws -> NoteMeta {
        guard payload.kind == .note else { throw NoteStoreSyncError.invalidPayload("conflict copy of a \(payload.kind.rawValue)") }
        let remote = try Self.decodeMeta(NoteMeta.self, payload)
        guard let data = payload.body else { throw NoteStoreSyncError.missingBody(payload.id) }
        let suffix = " (conflict — \(name), \(Self.conflictDateFormatter.string(from: payload.modifiedAt)))"
        let body = Self.appendingToTitleLine(try Self.deserializeBody(data), suffix)
        let created = createNote(in: remote.notebookID, initial: body, postsLocalChange: false)
        updateSyncCreatedNote(created.id) { meta in
            meta.isPinned = remote.isPinned
            meta.createdAt = remote.createdAt
            meta.updatedAt = remote.updatedAt
            meta.conflictSource = name
            meta.conflictOriginalID = payload.id
        }
        return note(with: created.id) ?? created
    }

    // MARK: Body transport

    /// Flattened RTFD (same document type as `notes/<id>.rtfd` on disk), so paragraph sentinels and attachments survive.
    nonisolated static func serializeBody(_ text: NSAttributedString) throws -> Data {
        guard let data = text.rtfd(from: NSRange(location: 0, length: text.length), documentAttributes: [
            .documentType: NSAttributedString.DocumentType.rtfd,
        ]) else { throw NoteStoreSyncError.invalidPayload("body could not be serialized") }
        return data
    }

    nonisolated static func deserializeBody(_ data: Data) throws -> NSAttributedString {
        guard let text = NSAttributedString(rtfd: data, documentAttributes: nil) else {
            throw NoteStoreSyncError.invalidPayload("body is not RTFD")
        }
        return text
    }

    nonisolated static func decodeMeta<T: Decodable & Identifiable>(_ type: T.Type, _ payload: RecordPayload) throws -> T where T.ID == UUID {
        let value: T
        do {
            value = try decoder.decode(T.self, from: payload.meta)
        } catch {
            throw NoteStoreSyncError.invalidPayload("\(payload.kind.rawValue) meta: \(error.localizedDescription)")
        }
        guard value.id == payload.id else { throw NoteStoreSyncError.invalidPayload("meta id mismatch") }
        return value
    }

    private static let conflictDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    /// Appends `suffix` to the first non-blank paragraph (the derived title), or starts the body with it.
    static func appendingToTitleLine(_ text: NSAttributedString, _ suffix: String) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        let ns = text.string as NSString
        var location = 0
        while location < ns.length {
            let para = ns.paragraphRange(for: NSRange(location: location, length: 0))
            var contentEnd = NSMaxRange(para)
            while contentEnd > para.location,
                  let scalar = UnicodeScalar(ns.character(at: contentEnd - 1)),
                  CharacterSet.newlines.contains(scalar) {
                contentEnd -= 1
            }
            let line = ns.substring(with: NSRange(location: para.location, length: contentEnd - para.location))
            if !line.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespaces).isEmpty {
                let attrs = text.attributes(at: max(para.location, contentEnd - 1), effectiveRange: nil)
                result.insert(NSAttributedString(string: suffix, attributes: attrs), at: contentEnd)
                return result
            }
            location = NSMaxRange(para)
        }
        let attrs = text.length > 0 ? text.attributes(at: 0, effectiveRange: nil) : [:]
        result.insert(NSAttributedString(string: "Untitled" + suffix + "\n", attributes: attrs), at: 0)
        return result
    }
}
