import NoteItCore
import SwiftUI

/// A notebook as listed in pickers and menus: in tree order, indented by depth.
struct NotebookPickerEntry: Identifiable {
    let notebook: Notebook
    let depth: Int
    var id: UUID { notebook.id }

    /// The name behind one em space per level below the top; menus keep leading em spaces.
    var indentedName: String {
        String(repeating: "\u{2003}", count: max(depth - 1, 0)) + notebook.name
    }
}

extension NoteStore {
    var notebookPickerEntries: [NotebookPickerEntry] {
        notebookTree.flattened(expanded: nil).compactMap { item in
            notebook(with: item.id).map { NotebookPickerEntry(notebook: $0, depth: item.depth) }
        }
    }
}

struct NotebookPickerLabel: View {
    let entry: NotebookPickerEntry

    init(_ entry: NotebookPickerEntry) {
        self.entry = entry
    }

    var body: some View {
        Label(entry.indentedName, systemImage: entry.notebook.symbol)
    }
}
