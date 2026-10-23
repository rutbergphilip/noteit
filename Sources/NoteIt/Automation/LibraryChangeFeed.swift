import Combine
import Foundation
import NoteItAPI
import NoteItCore

struct LibraryChange: Equatable {
    var kind: ChangeKind
    var id: UUID
    var op: ChangeOp
    var at: Date
}

enum LibraryDiff {
    /// Notebooks first, then notes, each sorted by id.
    static func changes(oldNotes: [UUID: NoteMeta], newNotes: [UUID: NoteMeta], oldNotebooks: [UUID: Notebook],
                        newNotebooks: [UUID: Notebook], at: Date) -> [LibraryChange] {
        var result: [LibraryChange] = []
        for id in Set(oldNotebooks.keys).union(newNotebooks.keys).sorted(by: { $0.uuidString < $1.uuidString }) {
            switch (oldNotebooks[id], newNotebooks[id]) {
            case (nil, .some): result.append(LibraryChange(kind: .notebook, id: id, op: .created, at: at))
            case (.some, nil): result.append(LibraryChange(kind: .notebook, id: id, op: .deleted, at: at))
            case let (old?, new?) where old != new: result.append(LibraryChange(kind: .notebook, id: id, op: .updated, at: at))
            default: break
            }
        }
        for id in Set(oldNotes.keys).union(newNotes.keys).sorted(by: { $0.uuidString < $1.uuidString }) {
            let op: ChangeOp?
            switch (oldNotes[id], newNotes[id]) {
            case (nil, .some): op = .created
            case (.some, nil): op = .purged
            case let (old?, new?):
                if old.deletedAt == nil, new.deletedAt != nil { op = .deleted }
                else if old.deletedAt != nil, new.deletedAt == nil { op = .restored }
                else if old != new { op = .updated }
                else { op = nil }
            default: op = nil
            }
            if let op { result.append(LibraryChange(kind: .note, id: id, op: op, at: at)) }
        }
        return result
    }
}

/// Turns store changes into `LibraryChange` batches for the Local API event feed.
@MainActor
final class LibraryChangeFeed {
    private let store: NoteStore
    private var notes: [UUID: NoteMeta]
    private var notebooks: [UUID: Notebook]
    private var handlers: [UUID: @MainActor ([LibraryChange]) -> Void] = [:]
    private var storeSubscription: AnyCancellable?

    init(store: NoteStore, debounce: Duration = .milliseconds(250)) {
        self.store = store
        notes = Self.byID(store.notes)
        notebooks = Dictionary(store.notebooks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let interval = Double(debounce.components.seconds) + Double(debounce.components.attoseconds) / 1e18
        storeSubscription = Publishers.Merge(store.$notes.map { _ in () }, store.$notebooks.map { _ in () })
            .debounce(for: .seconds(interval), scheduler: RunLoop.main)
            .sink { [weak self] in
                MainActor.assumeIsolated { self?.emit() }
            }
    }

    func subscribe(_ handler: @escaping @MainActor ([LibraryChange]) -> Void) -> AnyCancellable {
        let token = UUID()
        handlers[token] = handler
        return AnyCancellable { [weak self] in
            if Thread.isMainThread {
                MainActor.assumeIsolated { _ = self?.handlers.removeValue(forKey: token) }
            } else {
                DispatchQueue.main.async { _ = self?.handlers.removeValue(forKey: token) }
            }
        }
    }

    private func emit() {
        let newNotes = Self.byID(store.notes)
        let newNotebooks = Dictionary(store.notebooks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let changes = LibraryDiff.changes(oldNotes: notes, newNotes: newNotes, oldNotebooks: notebooks,
                                          newNotebooks: newNotebooks, at: Date())
        notes = newNotes
        notebooks = newNotebooks
        guard !changes.isEmpty else { return }
        for handler in handlers.values { handler(changes) }
    }

    private static func byID(_ notes: [NoteMeta]) -> [UUID: NoteMeta] {
        Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
}
