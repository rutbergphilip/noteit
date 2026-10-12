import Foundation
import InkwellSync

/// Bridges the sync engine (off the main actor) to `NoteStore` (main actor).
final class NoteStoreSyncAdapter: SyncLocalStore, @unchecked Sendable {
    private let store: NoteStore
    private let deviceID: String

    init(store: NoteStore, deviceID: String) {
        self.store = store
        self.deviceID = deviceID
    }

    func records() async -> [LocalRecord] {
        await MainActor.run { store.syncRecords() }
    }

    func deletions() async -> [UUID: LocalDeletion] {
        await MainActor.run { store.syncDeletions() }
    }

    func export(_ id: UUID, kind: RecordKind) async throws -> RecordPayload {
        let deviceID = deviceID
        return try await MainActor.run { try store.exportPayload(id: id, kind: kind, deviceID: deviceID) }
    }

    func apply(_ payload: RecordPayload) async throws {
        try await MainActor.run { try store.applyRemote(payload) }
    }

    func applyDeletion(_ id: UUID, kind: RecordKind) async throws {
        await MainActor.run { store.applyRemoteDeletion(id, kind: kind) }
    }

    func importConflictCopy(_ payload: RecordPayload, fromDevice name: String) async throws {
        _ = try await MainActor.run { try store.importConflictCopy(payload, fromDevice: name) }
    }

    func clearDeletion(_ id: UUID) async {
        await MainActor.run { store.clearSyncDeletion(id) }
    }
}
