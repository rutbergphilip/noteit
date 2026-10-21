import Foundation
import NoteItSync

/// Bridges the sync engine (off the main actor) to `NoteStore` (main actor).
///
/// RTFD parsing/serialization and body file writes happen off the main actor; main-actor hops only swap
/// prepared files into place and update metadata. Before a remote change replaces or deletes a note, staged
/// and open-editor edits are committed. If that (or any edit since the engine last read the record) changed
/// the local revision, the apply is refused; the next pass then sees both sides changed and keeps the
/// remote version as a conflict copy.
final class NoteStoreSyncAdapter: SyncLocalStore, @unchecked Sendable {
    enum AdapterError: Error, CustomStringConvertible {
        case localEditInProgress(UUID)
        case inactive
        case librarySaveFailed

        var description: String {
            switch self {
            case .localEditInProgress: "local edit in progress; retrying next pass"
            case .inactive: "sync was disconnected"
            case .librarySaveFailed: "couldn't save the library; retrying next pass"
            }
        }
    }

    private let store: NoteStore
    private let deviceID: String
    private let bodyStorage: NoteBodyStorage
    /// Main-actor state: revisions as of the engine's latest `records()` read, and the on/off switch.
    private var seenRevisions: [UUID: UUID] = [:]
    private var isActive = true

    init(store: NoteStore, deviceID: String) {
        self.store = store
        self.deviceID = deviceID
        self.bodyStorage = store.bodyStorage
    }

    @MainActor func deactivate() {
        isActive = false
    }

    func records() async -> [LocalRecord] {
        // Revisions for pre-sync records hash their body files; do that off the main actor.
        let inputs = await MainActor.run { store.missingRevisionInputs() }
        if !inputs.isEmpty {
            let revisions = NoteStore.contentRevisions(for: inputs)
            await MainActor.run { store.assignRevisions(revisions, inputs: inputs) }
        }
        return await MainActor.run {
            let records = store.syncRecords()
            seenRevisions = Dictionary(records.map { ($0.id, $0.revision) }, uniquingKeysWith: { first, _ in first })
            return records
        }
    }

    func revision(of id: UUID, kind: RecordKind) async -> UUID? {
        await onMain { store.syncRevision(of: id, kind: kind) }
    }

    func deletions() async -> [UUID: LocalDeletion] {
        await MainActor.run { store.syncDeletions() }
    }

    func export(_ id: UUID, kind: RecordKind) async throws -> RecordPayload {
        let deviceID = deviceID
        let (payload, source) = try await onMain {
            try requireActive()
            return try store.exportPlan(id: id, kind: kind, deviceID: deviceID)
        }
        return try NoteStore.completeExport(payload, source)
    }

    func apply(_ payload: RecordPayload) async throws {
        guard payload.kind == .note else {
            try await onMain {
                try requireActive()
                try store.applyRemote(payload)
                seenRevisions[payload.id] = payload.revision
                try requireSaved(payload.kind)
            }
            return
        }
        let prepared = try NoteStore.prepareRemoteNote(payload, storage: bodyStorage)
        do {
            try await onMain {
                try requireActive()
                try settleLocalEdits(payload.id, kind: .note)
                try store.applyPreparedRemoteNote(prepared)
                seenRevisions[payload.id] = payload.revision
                try requireSaved()
            }
        } catch {
            prepared.discard()
            throw error
        }
    }

    func applyDeletion(_ id: UUID, kind: RecordKind) async throws {
        try await onMain {
            try requireActive()
            try settleLocalEdits(id, kind: kind)
            store.applyRemoteDeletion(id, kind: kind)
            seenRevisions[id] = nil
            try requireSaved(kind)
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

    func passDidFinish() async {
        await MainActor.run { store.saveSearchIndexIfDirty() }
    }

    @MainActor private func requireActive() throws {
        guard isActive, !store.isClosedForLibrarySwitch else { throw AdapterError.inactive }
    }

    /// The engine records a base right after an apply returns, so the change must be on disk by then.
    @MainActor private func requireSaved(_ kind: RecordKind = .note) throws {
        let unsaved = kind == .smartFolder ? store.hasUnsavedSmartFolders : store.hasUnsavedLibrary
        if unsaved { throw AdapterError.librarySaveFailed }
    }

    @MainActor private func settleLocalEdits(_ id: UUID, kind: RecordKind) throws {
        guard kind == .note else { return }
        store.commitStagedEditorBody(id)
        NotificationCenter.default.post(name: .noteItSyncWillApplyRemote, object: id)
        let current = store.note(with: id)?.revision
        if current != seenRevisions[id] { throw AdapterError.localEditInProgress(id) }
    }

    private func onMain<T: Sendable>(_ work: @MainActor () throws -> T) async rethrows -> T {
        try await MainActor.run {
            #if DEBUG
            let start = DispatchTime.now().uptimeNanoseconds
            defer { SyncMainThreadMetrics.record(DispatchTime.now().uptimeNanoseconds - start) }
            #endif
            return try work()
        }
    }
}

#if DEBUG
/// Main-actor time spent per adapter hop (apply, deletion, export plan, revision lookups).
@MainActor
enum SyncMainThreadMetrics {
    private(set) static var count = 0
    private(set) static var totalNanos: UInt64 = 0
    private(set) static var maxNanos: UInt64 = 0
    private(set) static var samples: [UInt64] = []

    static func record(_ nanos: UInt64) {
        samples.append(nanos)
        count += 1
        totalNanos += nanos
        maxNanos = max(maxNanos, nanos)
    }

    static func reset() {
        count = 0
        totalNanos = 0
        maxNanos = 0
        samples = []
    }

    static func percentile(_ p: Double) -> UInt64 {
        let sorted = samples.sorted()
        return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
    }

    static var slowestIndex: Int { samples.firstIndex(of: maxNanos) ?? -1 }
}
#endif

extension Notification.Name {
    /// Posted synchronously on the main thread before sync replaces or deletes a note. Object: the note's UUID.
    static let noteItSyncWillApplyRemote = Notification.Name("noteItSyncWillApplyRemote")
}
