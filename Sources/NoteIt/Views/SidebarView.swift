import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var store: NoteStore
    @Binding var notebookDraft: NotebookDraft?

    @State private var renamingID: UUID?
    @State private var renameText = ""
    @State private var notebookPendingDelete: Notebook?
    @FocusState private var renameFocused: Bool

    var body: some View {
        List(selection: $store.selection) {
            Section("Library") {
                libraryRow("All Notes", symbol: "note.text", tint: Tokens.Color.accent, selection: .allNotes)
                libraryRow("Pinned", symbol: "pin.fill", tint: Tokens.Color.pinned, selection: .pinned)
                libraryRow("Recent", symbol: "clock", tint: Tokens.Color.recent, selection: .recent)
                if store.count(for: .conflicts) > 0 || store.selection == .conflicts {
                    libraryRow("Conflicts", symbol: "exclamationmark.triangle.fill", tint: .orange, selection: .conflicts)
                }
            }

            Section("Notebooks") {
                ForEach(store.sortedNotebooks) { notebook in
                    notebookRow(notebook)
                }
                .onMove { store.moveNotebooks(from: $0, to: $1) }
            }

            if !store.allTags.isEmpty {
                Section("Tags") {
                    ForEach(store.allTags, id: \.self) { tag in
                        Label {
                            Text(tag)
                        } icon: {
                            Image(systemName: "number").foregroundStyle(.secondary)
                        }
                        .badge(store.count(for: .tag(tag)))
                        .tag(SidebarSelection.tag(tag))
                    }
                }
            }

            if store.hasRecentlyDeleted || store.selection == .recentlyDeleted {
                Section {
                    libraryRow("Recently Deleted", symbol: "trash", tint: .secondary, selection: .recentlyDeleted)
                        .contextMenu {
                            Button("Empty Recently Deleted…") { RecentlyDeletedCoordinator.shared.confirmingEmpty = true }
                                .disabled(!store.hasRecentlyDeleted)
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button {
                    notebookDraft = NotebookDraft()
                } label: {
                    Label("New Notebook", systemImage: "plus.circle")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("New Notebook (⇧⌘N)")
                Spacer(minLength: 8)
                SyncStatusPill()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .confirmationDialog(
            "Delete “\(notebookPendingDelete?.name ?? "")”?",
            isPresented: Binding(
                get: { notebookPendingDelete != nil },
                set: { if !$0 { notebookPendingDelete = nil } }
            ),
            presenting: notebookPendingDelete
        ) { notebook in
            Button("Delete Notebook", role: .destructive) { store.deleteNotebook(notebook.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its notes will be moved to Recently Deleted.")
        }
    }

    private func libraryRow(_ title: String, symbol: String, tint: Color, selection: SidebarSelection) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .badge(store.count(for: selection))
        .tag(selection)
        .dropDestination(for: String.self) { items, _ in
            guard selection == .pinned else { return false }
            for id in noteIDs(from: items) where store.note(with: id)?.isPinned == false {
                store.togglePin(id)
            }
            return true
        }
    }

    @ViewBuilder
    private func notebookRow(_ notebook: Notebook) -> some View {
        Label {
            if renamingID == notebook.id {
                TextField("Name", text: $renameText)
                    .textFieldStyle(.plain)
                    .focused($renameFocused)
                    .onSubmit { commitRename(notebook) }
                    .onExitCommand { renamingID = nil }
                    .onChange(of: renameFocused) { _, focused in
                        if !focused { commitRename(notebook) }
                    }
            } else {
                Text(notebook.name)
            }
        } icon: {
            Image(systemName: notebook.symbol)
                .foregroundStyle(notebook.color)
        }
        .badge(store.count(for: .notebook(notebook.id)))
        .tag(SidebarSelection.notebook(notebook.id))
        .dropDestination(for: String.self) { items, _ in
            let ids = noteIDs(from: items)
            for id in ids { store.moveNote(id, to: notebook.id) }
            return !ids.isEmpty
        }
        .contextMenu {
            Button("Rename") { beginRename(notebook) }
            Button("Edit Notebook…") { notebookDraft = NotebookDraft(notebook) }
            Divider()
            Button("Delete Notebook…", role: .destructive) { notebookPendingDelete = notebook }
        }
    }

    private func noteIDs(from items: [String]) -> [UUID] {
        items.compactMap { UUID(uuidString: $0) }
    }

    private func beginRename(_ notebook: Notebook) {
        renameText = notebook.name
        renamingID = notebook.id
        DispatchQueue.main.async { renameFocused = true }
    }

    private func commitRename(_ notebook: Notebook) {
        guard renamingID == notebook.id else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, var current = store.notebook(with: notebook.id) {
            current.name = name
            store.updateNotebook(current)
        }
        renamingID = nil
    }
}
