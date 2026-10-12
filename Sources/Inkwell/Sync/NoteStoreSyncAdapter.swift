import Foundation
import InkwellSync

/// Bridges the sync engine (off the main actor) to `NoteStore` (main actor).
///
/// Before a remote change replaces or deletes a note, open editors commit their pending edits. If that
/// (or any edit since the engine last read the record) changed the local revision, the apply is refused;
/// the next pass then sees both sides changed and keeps the remote version as a conflict copy.
final class NoteStoreSyncAdapter: SyncLocalStore, @unchecked Sendable {
    enum AdapterError: Error, CustomStringConvertible {
        case localEditInProgress(UUID)
        case inactive

        var description: String {
            switch self {
            case .localEditInProgress: "local edit in progress; retrying next pass"
            case .inactive: "sync was disconnected"
            }
        }
    }

    private let store: NoteStore
    private let deviceID: String
    /// Main-actor state: revisions as of the engine's latest `records()` read, and the on/off switch.
    private var seenRevisions: [UUID: UUID] = [:]
    private var isActive = true

    init(store: NoteStore, deviceID: String) {
        self.store = store
        self.deviceID = deviceID
    }

    @MainActor func deactivate() {
        isActive = false
    }

    func records() async -> [LocalRecord] {
        await MainActor.run {
            let records = store.syncRecords()
            seenRevisions = Dictionary(records.map { ($0.id, $0.revision) }, uniquingKeysWith: { first, _ in first })
            return records
        }
    }

    func deletions() async -> [UUID: LocalDeletion] {
        await MainActor.run { store.syncDeletions() }
    }

    func export(_ id: UUID, kind: RecordKind) async throws -> RecordPayload {
        let deviceID = deviceID
        return try await MainActor.run {
            try requireActive()
            return try store.exportPayload(id: id, kind: kind, deviceID: deviceID)
        }
    }

    func apply(_ payload: RecordPayload) async throws {
        try await MainActor.run {
            try requireActive()
            try settleLocalEdits(payload.id, kind: payload.kind)
            try store.applyRemote(payload)
            seenRevisions[payload.id] = payload.revision
        }
    }

    func applyDeletion(_ id: UUID, kind: RecordKind) async throws {
        try await MainActor.run {
            try requireActive()
            try settleLocalEdits(id, kind: kind)
            store.applyRemoteDeletion(id, kind: kind)
            seenRevisions[id] = nil
        }
    }

    func importConflictCopy(_ payload: RecordPayload, fromDevice name: String) async throws {
        _ = try await MainActor.run {
            try requireActive()
            return try store.importConflictCopy(payload, fromDevice: name)
        }
    }

    func clearDeletion(_ id: UUID) async {
        await MainActor.run { store.clearSyncDeletion(id) }
    }

    @MainActor private func requireActive() throws {
        guard isActive else { throw AdapterError.inactive }
    }

    @MainActor private func settleLocalEdits(_ id: UUID, kind: RecordKind) throws {
        guard kind == .note else { return }
        NotificationCenter.default.post(name: .inkwellSyncWillApplyRemote, object: id)
        let current = store.note(with: id)?.revision
        if current != seenRevisions[id] { throw AdapterError.localEditInProgress(id) }
    }
}

extension Notification.Name {
    /// Posted synchronously on the main thread before sync replaces or deletes a note. Object: the note's UUID.
    static let inkwellSyncWillApplyRemote = Notification.Name("inkwellSyncWillApplyRemote")
}
