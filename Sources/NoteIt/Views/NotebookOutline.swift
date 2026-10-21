import NoteItCore
import SwiftUI

/// Which notebooks are expanded in the sidebar, kept per Mac.
@MainActor
final class NotebookExpansion: ObservableObject {
    static let shared = NotebookExpansion()

    @Published private(set) var expanded: Set<UUID>
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        expanded = Set((defaults.stringArray(forKey: PrefKey.expandedNotebookIDs) ?? []).compactMap(UUID.init(uuidString:)))
    }

    func isExpanded(_ id: UUID) -> Bool { expanded.contains(id) }

    func set(_ id: UUID, expanded value: Bool) {
        guard expanded.contains(id) != value else { return }
        if value { expanded.insert(id) } else { expanded.remove(id) }
        defaults.set(expanded.map(\.uuidString).sorted(), forKey: PrefKey.expandedNotebookIDs)
    }
}

/// Sidebar drag payloads: notebooks travel as `notebook:<UUID>`, notes as their bare UUID string.
enum SidebarDragPayload {
    static let notebookPrefix = "notebook:"

    static func notebook(_ id: UUID) -> String { notebookPrefix + id.uuidString }

    static func notebookID(_ item: String) -> UUID? {
        guard item.hasPrefix(notebookPrefix) else { return nil }
        return UUID(uuidString: String(item.dropFirst(notebookPrefix.count)))
    }

    static func noteIDs(_ items: [String]) -> [UUID] {
        items.compactMap { UUID(uuidString: $0) }
    }

    /// Moves dropped notebooks under `parent` (top level when nil) and dropped notes into `parent`.
    @MainActor
    static func drop(_ items: [String], on parent: UUID?, store: NoteStore) -> Bool {
        var handled = false
        for id in items.compactMap(notebookID) where id != parent {
            handled = store.moveNotebook(id, under: parent) || handled
        }
        if let parent {
            let notes = noteIDs(items)
            for id in notes { store.moveNote(id, to: parent) }
            handled = handled || !notes.isEmpty
        }
        return handled
    }
}

/// One sibling group of the notebook outline, reorderable by dragging.
struct NotebookOutlineRows<Row: View>: View {
    @EnvironmentObject private var store: NoteStore
    let parent: UUID?
    let row: (Notebook) -> Row

    var body: some View {
        ForEach(store.notebookTree.siblings(under: parent), id: \.self) { id in
            if let notebook = store.notebook(with: id) {
                NotebookOutlineNode(notebook: notebook, row: row)
            }
        }
        .onMove { store.moveNotebooks(from: $0, to: $1, parent: parent) }
    }
}

/// A notebook row and, under a disclosure triangle, its sub-notebooks.
struct NotebookOutlineNode<Row: View>: View {
    @EnvironmentObject private var store: NoteStore
    @ObservedObject private var expansion = NotebookExpansion.shared
    let notebook: Notebook
    let row: (Notebook) -> Row
    @State private var springLoad: DispatchWorkItem?

    static var springLoadDelay: TimeInterval { 0.7 }

    var body: some View {
        if store.notebookTree.children(of: notebook.id).isEmpty {
            droppableRow
        } else {
            DisclosureGroup(isExpanded: Binding(get: { expansion.isExpanded(notebook.id) },
                                                set: { expansion.set(notebook.id, expanded: $0) })) {
                NotebookOutlineRows(parent: notebook.id, row: row)
            } label: {
                droppableRow
            }
        }
    }

    private var droppableRow: some View {
        row(notebook)
            .itemProvider { NSItemProvider(object: SidebarDragPayload.notebook(notebook.id) as NSString) }
            .dropDestination(for: String.self) { items, _ in
                SidebarDragPayload.drop(items, on: notebook.id, store: store)
            } isTargeted: { targeted in
                springLoad?.cancel()
                springLoad = nil
                guard targeted, !expansion.isExpanded(notebook.id), !store.notebookTree.children(of: notebook.id).isEmpty else { return }
                let id = notebook.id
                let work = DispatchWorkItem { NotebookExpansion.shared.set(id, expanded: true) }
                springLoad = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.springLoadDelay, execute: work)
            }
    }
}

/// The notebook's **Move To** submenu: top level and every notebook it may go under.
struct NotebookMoveMenu: View {
    @EnvironmentObject private var store: NoteStore
    let notebook: Notebook

    var body: some View {
        let tree = store.notebookTree
        Menu("Move To") {
            Button("Top Level") { store.moveNotebook(notebook.id, under: nil) }
                .disabled(tree.effectiveParent(of: notebook.id) == nil)
            Divider()
            ForEach(store.notebookPickerEntries) { entry in
                Button { store.moveNotebook(notebook.id, under: entry.id) } label: { NotebookPickerLabel(entry) }
                    .disabled(tree.effectiveParent(of: notebook.id) == entry.id || !tree.canMove(notebook.id, under: entry.id))
            }
        }
    }
}
