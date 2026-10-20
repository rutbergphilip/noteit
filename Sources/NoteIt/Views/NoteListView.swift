import SwiftUI

struct NoteListView: View {
    @EnvironmentObject private var store: NoteStore
    @Environment(\.undoManager) private var undoManager
    @ObservedObject private var trash = RecentlyDeletedCoordinator.shared

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
        case .recentlyDeleted: return "Recently Deleted"
        case .notebook(let id): return store.notebook(with: id)?.name ?? "Notebook"
        case .tag(let tag): return "#\(tag)"
        case .today: return "Today"
        case .tasks: return "Tasks"
        case .smartFolder: return "Smart Folder"
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
                // Rows the table never re-measures (seen after sync updates) fall back to this height.
                .environment(\.defaultMinListRowHeight, NoteRow.height)
                .onDeleteCommand {
                    if let note = store.note(with: store.selectedNoteID) { delete(note) }
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
            if selection == .recentlyDeleted {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        trash.confirmingEmpty = true
                    } label: {
                        Label("Empty Recently Deleted", systemImage: "trash.slash")
                    }
                    .disabled(notes.isEmpty)
                    .help("Empty Recently Deleted…")
                }
            }
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
                message: "No notes match “\(store.searchText)”."
            )
        } else {
            switch selection {
            case .recentlyDeleted:
                EmptyStateView(
                    symbol: "trash",
                    title: "No Recently Deleted Notes",
                    message: "Deleted notes stay here for 30 days before they’re removed."
                )
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
                    title: "No Notes Yet",
                    message: "Notes you create will appear here.",
                    actionTitle: "New Note"
                ) { store.createNoteInCurrentContext() }
            }
        }
    }

    /// Notes go to Recently Deleted right away (with Undo); from there, removing them for good is confirmed.
    private func delete(_ note: NoteMeta) {
        if note.deletedAt != nil {
            trash.pendingDeleteNow = [note.id]
        } else {
            trash.delete([note.id], store: store, undoManager: undoManager)
        }
    }

    @ViewBuilder
    private func contextMenu(for note: NoteMeta) -> some View {
        if note.deletedAt != nil {
            Button("Recover") { store.recover([note.id], undoManager: undoManager) }
            Divider()
            Button("Delete Now…", role: .destructive) { trash.pendingDeleteNow = [note.id] }
        } else {
            activeContextMenu(for: note)
        }
    }

    @ViewBuilder
    private func activeContextMenu(for note: NoteMeta) -> some View {
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
        Button("Version History…") { trash.historyNoteID = note.id }
        Divider()
        Button("Delete", role: .destructive) { delete(note) }
    }
}

struct NoteRow: View {
    let note: NoteMeta
    let notebook: Notebook?

    private static let verticalPadding: CGFloat = 8
    private static let spacing: CGFloat = 4

    /// Every row is this tall (the preview always reserves two lines), so the list can use it as its
    /// minimum row height and a row is never laid out shorter than its content.
    static let height: CGFloat = {
        let layout = NSLayoutManager()
        func line(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> CGFloat {
            ceil(layout.defaultLineHeight(for: .systemFont(ofSize: size, weight: weight)))
        }
        return verticalPadding * 2 + spacing * 2 + line(13, .semibold) + line(12) * 2 + line(11)
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
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
                .lineLimit(2, reservesSpace: true)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Text(note.deletedAt ?? note.updatedAt, format: .relative(presentation: .named))
                    .font(Tokens.Font.cardMeta)
                    .foregroundStyle(Tokens.Color.inkSecondary)
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
        .padding(.vertical, Self.verticalPadding)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }
}
