import NoteItCore
import SwiftUI

struct NoteListView: View {
    @EnvironmentObject private var store: NoteStore
    @Environment(\.undoManager) private var undoManager
    @ObservedObject private var trash = RecentlyDeletedCoordinator.shared

    private var selection: SidebarSelection { store.selection ?? .allNotes }
    @AppStorage(PrefKey.searchSortOrder) private var sortOrder = PrefDefault.searchSortOrder
    private var order: SearchSortOrder { SearchSortOrder(rawValue: sortOrder) ?? .bestMatch }
    private var isSearching: Bool { !store.searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    /// In a notebook, only notes from its nested notebooks name where they live.
    private func showsNotebook(of note: NoteMeta) -> Bool {
        if case .notebook(let id) = selection { return note.notebookID != id }
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
        case .smartFolder(let id): return store.smartFolder(with: id)?.name ?? "Smart Folder"
        }
    }

    var body: some View {
        let query = SearchQuery.parse(store.searchText)
        let results = store.searchResults(for: selection, search: store.searchText, order: order)
        Group {
            if results.isEmpty {
                emptyState
            } else {
                List(selection: $store.selectedNoteID) {
                    ForEach(results) { result in
                        let note = result.note
                        NoteRow(
                            note: note,
                            notebook: showsNotebook(of: note) ? store.notebook(with: note.notebookID) : nil,
                            search: result
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
        .safeAreaInset(edge: .top, spacing: 0) {
            if isSearching, selection != .recentlyDeleted, query.issues.isEmpty {
                HStack {
                    Spacer()
                    Button("Save as Smart Folder…") { SmartFolderActions.newSmartFolder(query: store.searchText) }
                        .buttonStyle(.borderless)
                        .font(.callout)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle(count: results.count))
        .searchable(text: $store.searchText, placement: .toolbar, prompt: "Search")
        .toolbar {
            if let issue = query.issues.first {
                ToolbarItem(placement: .primaryAction) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .help(issue.message)
                        .accessibilityLabel(issue.message)
                }
            }
            if query.hasTextTerms, selection != .recentlyDeleted {
                ToolbarItem(placement: .primaryAction) {
                    Picker(selection: $sortOrder) {
                        Text("Best Match").tag(SearchSortOrder.bestMatch.rawValue)
                        Text("Date Edited").tag(SearchSortOrder.dateEdited.rawValue)
                    } label: {
                        Label("Sort Results", systemImage: "arrow.up.arrow.down")
                    }
                    .pickerStyle(.menu)
                    .help("Sort Results")
                }
            }
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
                    .disabled(results.isEmpty)
                    .help("Empty Recently Deleted…")
                }
            }
        }
        .onChange(of: store.selection, initial: true) { _, _ in store.reconcileSelection() }
        .onChange(of: store.searchText) { _, _ in store.reconcileSelection() }
        .onChange(of: store.notes) { _, _ in store.reconcileSelection() }
    }

    private func subtitle(count: Int) -> String {
        let notes = count == 1 ? "1 note" : "\(count) notes"
        if case .notebook(let id) = selection, !store.notebookTree.children(of: id).isEmpty {
            return "\(notes), including nested notebooks"
        }
        return notes
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
            ForEach(store.notebookPickerEntries) { entry in
                Button {
                    store.moveNote(note.id, to: entry.id)
                } label: {
                    NotebookPickerLabel(entry)
                }
                .disabled(note.notebookID == entry.id)
            }
            Divider()
            Button("No Notebook") { store.moveNote(note.id, to: nil) }
                .disabled(note.notebookID == nil)
        }
        if note.conflictSource != nil {
            Button("Mark Conflict Resolved") { store.markConflictResolved(note.id) }
        }
        Button("Version History…") { trash.historyNoteID = note.id }
        Button("Copy Note Link") { CopyNoteLink.perform(noteID: note.id, store: store) }
        Divider()
        Button("Delete", role: .destructive) { delete(note) }
    }
}

struct NoteRow: View {
    let note: NoteMeta
    let notebook: Notebook?
    var search: SearchResult?

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
                Text(Self.highlighted(note.displayTitle, search?.titleHighlights ?? []))
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

            previewText
                .font(Tokens.Font.cardPreview)
                .foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Text(note.deletedAt ?? note.updatedAt, format: .relative(presentation: .named))
                    .font(Tokens.Font.cardMeta)
                    .foregroundStyle(Tokens.Color.inkSecondary)
                    .layoutPriority(1)
                if !note.tags.isEmpty {
                    TagChipRow(tags: note.tags)
                }
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

    private var previewText: Text {
        if search?.foundInImage == true {
            return Text(Image(systemName: "photo")) + Text(" Found in an image")
        }
        if let snippet = search?.snippet {
            return Text(Self.highlighted(snippet.text, snippet.highlights))
        }
        return Text(note.preview.isEmpty ? "No additional text" : note.preview)
    }

    /// `ranges` are UTF-16 ranges into `string`.
    static func highlighted(_ string: String, _ ranges: [NSRange]) -> AttributedString {
        var result = AttributedString(string)
        let ns = string as NSString
        for range in ranges where NSMaxRange(range) <= ns.length {
            guard let swiftRange = Range(range, in: string),
                  let lower = AttributedString.Index(swiftRange.lowerBound, within: result),
                  let upper = AttributedString.Index(swiftRange.upperBound, within: result) else { continue }
            result[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
            result[lower..<upper].backgroundColor = Tokens.Color.searchHighlight
        }
        return result
    }
}
