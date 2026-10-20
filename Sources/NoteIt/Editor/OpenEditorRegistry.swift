import AppKit
import Foundation

/// Every open editor per note, and the read-only observers that mirror a note's body (program §6). Shape owned by
/// the organise plan; built in foundations Task 4.5. `editBody` edits the editor `textView(for:)` returns.
@MainActor
final class OpenEditorRegistry {
    static let shared = OpenEditorRegistry()

    typealias Observer = @MainActor (NSAttributedString) -> Void

    private struct Entry {
        weak var view: NoteItTextView?
        var noteID: UUID
        var registered: Int
        var active: Int?
    }

    private struct ObserverEntry {
        var noteID: UUID
        var handler: Observer
    }

    private var entries: [Entry] = []
    private var observers: [UUID: ObserverEntry] = [:]
    /// Per watched editor (by object identity): the didProcessEditing observation passing its text to observers.
    private var storageWatches: [ObjectIdentifier: (view: () -> NoteItTextView?, token: NSObjectProtocol)] = [:]
    private var counter = 0

    init() {}

    /// Keeps every registered view, weakly, per note: several windows can show the same note. Registering a view
    /// again moves it to `noteID` and makes it the most recently registered.
    func register(_ view: NoteItTextView, for noteID: UUID) {
        counter += 1
        entries.removeAll { $0.view == nil || $0.view === view }
        entries.append(Entry(view: view, noteID: noteID, registered: counter))
        updateWatches()
    }

    func unregister(_ view: NoteItTextView) {
        entries.removeAll { $0.view == nil || $0.view === view }
        updateWatches()
    }

    /// Called when a registered view becomes first responder, so `textView(for:)` returns the view used last.
    func markActive(_ view: NoteItTextView) {
        guard let index = entries.firstIndex(where: { $0.view === view }) else { return }
        counter += 1
        entries[index].active = counter
    }

    /// The most recently active (else most recently registered) editor for the note. Editors only.
    func textView(for noteID: UUID) -> NoteItTextView? {
        let live = liveEntries(for: noteID)
        let active = live.filter { $0.active != nil }.max { $0.active! < $1.active! }
        return (active ?? live.max { $0.registered < $1.registered })?.view
    }

    /// Every live editor for the note, most recent first (by activity, then registration).
    func textViews(for noteID: UUID) -> [NoteItTextView] {
        liveEntries(for: noteID)
            .sorted { recency($0) > recency($1) }
            .compactMap(\.view)
    }

    /// Every live editor for the note in registration order.
    func textViewsInRegistrationOrder(for noteID: UUID) -> [NoteItTextView] {
        liveEntries(for: noteID).sorted { $0.registered < $1.registered }.compactMap(\.view)
    }

    /// Read-only surfaces mirror a note's body; `textView(for:)` never returns one and `editBody` never edits one.
    @discardableResult
    func registerObserver(_ observer: @escaping Observer, for noteID: UUID) -> UUID {
        let token = UUID()
        observers[token] = ObserverEntry(noteID: noteID, handler: observer)
        updateWatches()
        return token
    }

    func removeObserver(_ token: UUID) {
        guard observers.removeValue(forKey: token) != nil else { return }
        updateWatches()
    }

    func hasObservers(for noteID: UUID) -> Bool {
        observers.values.contains { $0.noteID == noteID }
    }

    /// Passes a copy of `body` to every observer of the note.
    func notifyObservers(of noteID: UUID, body: NSAttributedString) {
        let handlers = observers.values.filter { $0.noteID == noteID }.map(\.handler)
        guard !handlers.isEmpty else { return }
        let copy = NSAttributedString(attributedString: body)
        for handler in handlers { handler(copy) }
    }

    private func liveEntries(for noteID: UUID) -> [Entry] {
        entries.filter { $0.noteID == noteID && $0.view != nil }
    }

    private func recency(_ entry: Entry) -> Int {
        max(entry.active ?? 0, entry.registered)
    }

    /// Watches the text storage of each editor whose note has observers, and nothing else.
    private func updateWatches() {
        entries.removeAll { $0.view == nil }
        let observed = Set(observers.values.map(\.noteID))
        var wanted: [ObjectIdentifier: NoteItTextView] = [:]
        for entry in entries where observed.contains(entry.noteID) {
            if let view = entry.view { wanted[ObjectIdentifier(view)] = view }
        }
        for (key, watch) in storageWatches where wanted[key] == nil || watch.view() == nil {
            NotificationCenter.default.removeObserver(watch.token)
            storageWatches[key] = nil
        }
        for (key, view) in wanted where storageWatches[key] == nil {
            let token = NotificationCenter.default.addObserver(
                forName: NSTextStorage.didProcessEditingNotification, object: view.textStorage, queue: nil
            ) { [weak self, weak view] _ in
                MainActor.assumeIsolated {
                    guard let self, let view,
                          let noteID = self.entries.first(where: { $0.view === view })?.noteID else { return }
                    self.notifyObservers(of: noteID, body: CodeStyler.persisted(view.storage))
                }
            }
            storageWatches[key] = ({ [weak view] in view }, token)
        }
    }
}
