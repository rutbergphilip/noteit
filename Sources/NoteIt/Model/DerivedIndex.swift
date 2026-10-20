import AppKit
import Foundation

/// An index built from notes and kept beside them in the data folder (program §7). Shape owned by the organise plan;
/// built in foundations Task 4.4. Hooks are sent through NoteStore's one dispatcher, in registration order.
@MainActor
protocol DerivedIndex: AnyObject {
    var indexID: String { get }
    /// The body changed or the note was created; also on Remove Lock. Never for a locked note.
    func noteChanged(_ note: NoteMeta, body: NSAttributedString)
    /// Deleted for good; also when a note is locked.
    func noteRemoved(_ noteID: UUID)
    /// Metadata only (pin, move, tags without a body change, Recently Deleted and restore from it). No body, and
    /// never sent together with noteChanged for the same change.
    func metadataChanged(_ note: NoteMeta)
    /// Build from scratch. `body` reads from disk and returns nil for locked notes.
    func rebuild(notes: [NoteMeta], body: @escaping (UUID) -> NSAttributedString?) async
    /// Synchronous: write out pending index work.
    func flush()
}

/// What NoteStore's dispatcher sends to every registered index.
enum DerivedIndexEvent {
    case changed(NoteMeta, NSAttributedString)
    case removed(UUID)
    case metadata(NoteMeta)
    case flush
}

/// The derived-index registry (program §7; organise owns the shape, foundations Task 4.4).
extension NoteStore {
    /// Registered once per store open; there is no unregister. A feature that can be turned off keeps its index
    /// registered and dormant. Traps on a duplicate `indexID`.
    func registerDerivedIndex(_ index: DerivedIndex) {
        guard canRegisterDerivedIndex(index.indexID) else {
            preconditionFailure("A derived index with ID \(index.indexID) is already registered")
        }
        derivedIndexes.append(index)
    }

    func canRegisterDerivedIndex(_ indexID: String) -> Bool {
        !derivedIndexes.contains { $0.indexID == indexID }
    }

    /// Re-sends one note to every index: noteChanged when unlocked, noteRemoved when locked. sync-security calls it
    /// after Lock Note and Remove Lock.
    func refreshDerivedIndexes(for id: UUID) {
        guard !derivedIndexes.isEmpty, let meta = note(with: id) else { return }
        if meta.isLocked {
            dispatchDerivedIndexes(.removed(id))
        } else {
            dispatchDerivedIndexes(.changed(meta, body(for: id)))
        }
    }

    /// The one dispatcher for every hook. A locked note never reaches noteChanged; it gets noteRemoved instead.
    func dispatchDerivedIndexes(_ event: DerivedIndexEvent) {
        guard !derivedIndexes.isEmpty else { return }
        let resolved: DerivedIndexEvent
        if case .changed(let meta, _) = event, meta.isLocked {
            resolved = .removed(meta.id)
        } else {
            resolved = event
        }
        for index in derivedIndexes {
            switch resolved {
            case .changed(let meta, let body): index.noteChanged(meta, body: body)
            case .removed(let id): index.noteRemoved(id)
            case .metadata(let meta): index.metadataChanged(meta)
            case .flush: index.flush()
            }
        }
    }

    /// Sends rebuild to every index, with a body reader that reads through `bodyStorage` (callable off the main
    /// actor) and returns nil for locked notes.
    func rebuildDerivedIndexes() {
        guard !derivedIndexes.isEmpty else { return }
        let all = notes
        let locked = Set(all.filter(\.isLocked).map(\.id))
        let storage = bodyStorage
        let body: (UUID) -> NSAttributedString? = { id in
            locked.contains(id) ? nil : try? storage.read(id).text
        }
        let indexes = derivedIndexes
        Task { @MainActor in
            for index in indexes { await index.rebuild(notes: all, body: body) }
        }
    }
}
