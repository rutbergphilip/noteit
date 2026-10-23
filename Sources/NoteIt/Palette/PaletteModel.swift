import AppKit
import Combine
import NoteItCore

/// What the palette needs from the app around it; tests substitute a recording host.
struct PaletteHost {
    var dismiss: @MainActor () -> Void
    var showMainWindow: @MainActor () -> Void
    var focusEditor: @MainActor () -> Void
    /// Runs work on a later main run-loop turn.
    var later: @MainActor (@escaping @MainActor () -> Void) -> Void
    /// Runs a command after the palette closed; `later` when nil.
    var runCommand: (@MainActor (@escaping @MainActor () -> Void) -> Void)? = nil

    @MainActor static var live: PaletteHost {
        PaletteHost(
            dismiss: { PaletteController.shared.dismissForChosenItem() },
            showMainWindow: { WindowRouter.showMainWindow() },
            focusEditor: {
                if PaletteController.shared.presentedOverOtherApp {
                    PaletteController.whenMainWindowIsKey { WindowRouter.focusEditor() }
                } else {
                    WindowRouter.focusEditor()
                }
            },
            later: { work in
                DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
            },
            runCommand: { work in
                guard PaletteController.shared.presentedOverOtherApp else {
                    DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
                    return
                }
                WindowRouter.showMainWindow()
                PaletteController.whenMainWindowIsKey(work)
            }
        )
    }
}

@MainActor
final class PaletteModel: ObservableObject {
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            selectedIndex = 0
            recompute()
        }
    }
    @Published private(set) var items: [PaletteItem] = []
    @Published private(set) var selectedIndex = 0
    /// Bumped on every presentation so the search field takes focus.
    @Published private(set) var focusToken = 0

    let store: NoteStore
    var host: PaletteHost
    private(set) var commands: [PaletteCommand] = []
    private var lastMouseLocation: NSPoint?
    private var storeObserver: AnyCancellable?
    private var refreshScheduled = false

    init(store: NoteStore? = nil, host: PaletteHost? = nil) {
        self.store = store ?? .shared
        self.host = host ?? .live
    }

    var mode: PaletteMode { PaletteRanker.parse(query).mode }

    var selectedItem: PaletteItem? {
        items.indices.contains(selectedIndex) ? items[selectedIndex] : nil
    }

    /// Rebuilds the commands from the current app state and starts over with `query`.
    func reset(query newQuery: String) {
        commands = PaletteCommandRegistry.availableCommands(for: store)
        lastMouseLocation = NSEvent.mouseLocation
        if query == newQuery {
            selectedIndex = 0
            recompute()
        } else {
            query = newQuery
        }
        focusToken += 1
        observeStore()
    }

    /// Stops following store changes; the palette calls this when it closes.
    func stopObserving() {
        storeObserver = nil
        refreshScheduled = false
    }

    /// Rebuilds commands and results from the current store, keeping the selected row if it's still there.
    func refresh() {
        let selectedID = selectedItem?.id
        commands = PaletteCommandRegistry.availableCommands(for: store)
        recompute()
        if let selectedID, let index = items.firstIndex(where: { $0.id == selectedID }) {
            select(index)
        }
    }

    func notebookColorHex(_ id: UUID) -> String? {
        store.notebook(with: id)?.colorHex
    }

    private func observeStore() {
        guard storeObserver == nil else { return }
        storeObserver = store.objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
    }

    /// `objectWillChange` fires before the change lands, and often several times in a row.
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        host.later { [weak self] in
            guard let self, self.refreshScheduled else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    func recompute() {
        let parsed = PaletteRanker.parse(query)
        let text = parsed.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var bodyMatches: [UUID: Double] = [:]
        if parsed.mode == .everything, !text.isEmpty {
            for result in store.searchResults(for: .allNotes, search: text, order: .bestMatch, decorated: false) {
                bodyMatches[result.id] = result.score ?? 0
            }
        }
        items = PaletteRanker.items(query: query, notes: store.activeNotes, notebooks: store.sortedNotebooks,
                                    commands: commands.map(\.info), bodyMatches: bodyMatches,
                                    smartFolders: store.sortedSmartFolders, tags: Self.tagPaths(store.tagTree))
        select(selectedIndex)
    }

    private static func tagPaths(_ nodes: [TagNode]) -> [(path: String, count: Int)] {
        nodes.flatMap { [($0.path, $0.totalCount)] + tagPaths($0.children) }
    }

    func select(_ index: Int) {
        let clamped = items.isEmpty ? 0 : min(max(index, 0), items.count - 1)
        if selectedIndex != clamped { selectedIndex = clamped }
    }

    func moveSelection(_ delta: Int) {
        select(selectedIndex + delta)
    }

    /// Selects a row under the pointer, but only once the pointer has actually moved (rows scrolling
    /// under a resting pointer don't take the selection).
    func hover(_ index: Int, at location: NSPoint) {
        guard location != lastMouseLocation else { return }
        lastMouseLocation = location
        select(index)
    }

    func activateSelected() {
        guard let item = selectedItem else {
            NSSound.beep()
            return
        }
        activate(item)
    }

    func activate(_ item: PaletteItem) {
        switch item.kind {
        case .note(let id):
            guard let note = store.note(with: id), note.deletedAt == nil else { return refresh() }
            host.dismiss()
            open(noteID: id)
        case .notebook(let id):
            guard store.notebook(with: id) != nil else { return refresh() }
            host.dismiss()
            store.selection = .notebook(id)
            host.showMainWindow()
        case .smartFolder(let id):
            guard store.smartFolder(with: id) != nil else { return refresh() }
            host.dismiss()
            store.searchText = ""
            store.selection = .smartFolder(id)
            host.showMainWindow()
        case .tag(let path):
            host.dismiss()
            store.searchText = ""
            store.selection = .tag(path)
            host.showMainWindow()
        case .command(let id):
            guard let command = commands.first(where: { $0.info.id == id }) else { return refresh() }
            host.dismiss()
            (host.runCommand ?? host.later) { command.perform() }
        case .createNote(let title):
            host.dismiss()
            createNote(titled: title)
        }
    }

    /// Selects the note, switching the sidebar (and clearing the search) only when the note isn't
    /// already in the visible list.
    func open(noteID id: UUID) {
        guard let note = store.note(with: id) else { return }
        if !store.notes(for: store.selection, search: store.searchText).contains(where: { $0.id == id }) {
            let inSelection = store.notes(for: store.selection, search: "").contains { $0.id == id }
            store.searchText = ""
            if !inSelection {
                store.selection = store.notebook(with: note.notebookID).map { .notebook($0.id) } ?? .allNotes
            }
        }
        store.selectedNoteID = id
        host.showMainWindow()
        host.focusEditor()
    }

    @discardableResult
    func createNote(titled title: String) -> NoteMeta? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let text = NSMutableAttributedString(attributedString: NoteStore.capturedText(title: title, body: ""))
        text.append(NSAttributedString(string: "\n", attributes: EditorStyle.bodyAttributes))
        guard let meta = store.createNoteInCurrentContext(initial: text) else { return nil }
        RichTextEditor.pendingCaret[meta.id] = text.length
        host.showMainWindow()
        host.focusEditor()
        return meta
    }
}
