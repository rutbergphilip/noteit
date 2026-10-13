import SwiftUI

struct NoteListView: View {
    @EnvironmentObject private var store: NoteStore
    @State private var notePendingDelete: NoteMeta?

    private var selection: SidebarSelection { store.selection ?? .allNotes }
    private var visibleNotes: [NoteMeta] { store.notes(for: selection, search: store.searchText) }
    private var isSearching: Bool { !store.searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    private var showsNotebookDot: Bool {
        if case .notebook = selection { return false }
        return true
    }

    private var title: String {
        switch selection {
        case .allNotes: return "All Notes"
        case .pinned: return "Pinned"
        case .recent: return "Recent"
        case .conflicts: return "Conflicts"
        case .notebook(let id): return store.notebook(with: id)?.name ?? "Notebook"
        case .tag(let tag): return "#\(tag)"
        }
    }

    var body: some View {
        let notes = visibleNotes
        Group {
            if notes.isEmpty {
                emptyState
            } else {
                List(selection: $store.selectedNoteID) {
                    ForEach(notes) { note in
                        NoteRow(
                            note: note,
                            notebook: showsNotebookDot ? store.notebook(with: note.notebookID) : nil
                        )
                        .tag(note.id)
                        .listRowSeparator(.hidden)
                        .draggable(note.id.uuidString)
                        .contextMenu { contextMenu(for: note) }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .onDeleteCommand {
                    if let note = store.note(with: store.selectedNoteID) { notePendingDelete = note }
                }
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(notes.count == 1 ? "1 note" : "\(notes.count) notes")
        .searchable(text: $store.searchText, placement: .toolbar, prompt: "Search")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.createNoteInCurrentContext()
                } label: {
                    Label("New Note", systemImage: "square.and.pencil")
                }
                .help("New Note (⌘N)")
            }
        }
        .confirmationDialog(
            "Delete “\(notePendingDelete?.displayTitle ?? "")”?",
            isPresented: Binding(
                get: { notePendingDelete != nil },
                set: { if !$0 { notePendingDelete = nil } }
            ),
            presenting: notePendingDelete
        ) { note in
            Button("Delete Note", role: .destructive) { store.deleteNote(note.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The note will be removed from NoteIt.")
        }
        .onChange(of: store.selection) { _, _ in store.reconcileSelection() }
        .onChange(of: store.searchText) { _, _ in store.reconcileSelection() }
        .onChange(of: store.notes) { _, _ in store.reconcileSelection() }
    }

    @ViewBuilder
    private var emptyState: some View {
        if isSearching {
            EmptyStateView(
                symbol: "magnifyingglass",
                title: "No Results",
                message: "No notes match “\(store.searchText)”.",
                tint: .secondary
            )
        } else {
            switch selection {
            case .pinned:
                EmptyStateView(
                    symbol: "pin",
                    title: "No Pinned Notes",
                    message: "Pin a note to keep it at the top of your lists.",
                    tint: Tokens.Color.pinned
                )
            case .notebook(let id):
                let notebook = store.notebook(with: id)
                EmptyStateView(
                    symbol: notebook?.symbol ?? "book",
                    title: "No Notes Yet",
                    message: "Capture your first thought in \(notebook?.name ?? "this notebook").",
                    tint: notebook?.color ?? Tokens.Color.accent,
                    actionTitle: "New Note"
                ) { store.createNoteInCurrentContext() }
            default:
                EmptyStateView(
                    symbol: "note.text",
                    title: "No Notes",
                    message: "Notes you create will appear here.",
                    actionTitle: "New Note"
                ) { store.createNoteInCurrentContext() }
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for note: NoteMeta) -> some View {
        Button(note.isPinned ? "Unpin" : "Pin") { store.togglePin(note.id) }
        Menu("Move to") {
            ForEach(store.sortedNotebooks) { notebook in
                Button {
                    store.moveNote(note.id, to: notebook.id)
                } label: {
                    Label(notebook.name, systemImage: notebook.symbol)
                }
                .disabled(note.notebookID == notebook.id)
            }
            Divider()
            Button("No Notebook") { store.moveNote(note.id, to: nil) }
                .disabled(note.notebookID == nil)
        }
        if note.conflictSource != nil {
            Button("Mark Conflict Resolved") { store.markConflictResolved(note.id) }
        }
        Divider()
        Button("Delete…", role: .destructive) { notePendingDelete = note }
    }
}

struct NoteRow: View {
    let note: NoteMeta
    let notebook: Notebook?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(note.displayTitle)
                    .font(Tokens.Font.cardTitle)
                    .lineLimit(1)
                    .foregroundStyle(note.title.isEmpty ? .secondary : .primary)
                Spacer(minLength: 4)
                if let source = note.conflictSource {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .help("Conflict copy from \(source)")
                        .accessibilityLabel("Conflict copy from \(source)")
                }
                if note.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Tokens.Color.pinned)
                        .help("Pinned")
                }
            }

            Text(note.preview.isEmpty ? "No additional text" : note.preview)
                .font(Tokens.Font.cardPreview)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Text(note.updatedAt, format: .relative(presentation: .named))
                    .font(Tokens.Font.cardMeta)
                    .foregroundStyle(.tertiary)
                if let notebook {
                    Spacer(minLength: 4)
                    HStack(spacing: 4) {
                        Circle().fill(notebook.color).frame(width: 7, height: 7)
                        Text(notebook.name)
                            .font(Tokens.Font.cardMeta)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }
}
