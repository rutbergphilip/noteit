import NoteItCore
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var store: NoteStore
    @Binding var notebookDraft: NotebookDraft?

    @State private var renamingID: UUID?
    @State private var renameText = ""
    @State private var notebookPendingDelete: Notebook?
    @State private var smartFolderPendingDelete: SmartFolder?
    @FocusState private var renameFocused: Bool
    @AppStorage(PrefKey.showTodayInSidebar) private var showToday = PrefDefault.showTodayInSidebar
    @State private var todayNumber = Self.currentDayNumber()
    @State private var showsTodayCalendar = false

    // The footer sits below the list, not in its safe area inset: a sidebar List on macOS draws rows under an inset.
    var body: some View {
        VStack(spacing: 0) {
            sidebarList
            Divider()
            footer
        }
    }

    private var footer: some View {
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

    private var sidebarList: some View {
        List(selection: $store.selection) {
            let tags = store.tagTree
            let smartFolders = store.sortedSmartFolders
            let sections = SidebarSection.visible(hasSmartFolders: !smartFolders.isEmpty, hasTags: !tags.isEmpty,
                                                  showsRecentlyDeleted: store.hasRecentlyDeleted || store.selection == .recentlyDeleted)
            ForEach(sections, id: \.self) { section in
                switch section {
                case .library:
                    Section("Library") {
                        libraryRow("All Notes", symbol: "note.text", tint: Tokens.Color.accent, selection: .allNotes)
                        if showToday && DailyNotes.isAvailable {
                            todayRow
                        }
                        Label {
                            Text("Tasks")
                        } icon: {
                            SidebarIcon(symbol: "checklist", tint: Tokens.Color.tasks)
                        }
                        .badge(store.openDueTodayOrOverdueCount)
                        .tag(SidebarSelection.tasks)
                        libraryRow("Pinned", symbol: "pin.fill", tint: Tokens.Color.pinned, selection: .pinned)
                        libraryRow("Recent", symbol: "clock", tint: Tokens.Color.recent, selection: .recent)
                        if store.count(for: .conflicts) > 0 || store.selection == .conflicts {
                            libraryRow("Conflicts", symbol: "exclamationmark.triangle.fill", tint: .orange, selection: .conflicts)
                        }
                    }
                case .smartFolders:
                    Section("Smart Folders") {
                        ForEach(smartFolders) { smartFolderRow($0) }
                            .onMove { store.moveSmartFolders(fromOffsets: $0, toOffset: $1) }
                    }
                case .notebooks:
                    Section {
                        NotebookOutlineRows(parent: nil) { notebookRow($0) }
                    } header: {
                        Text("Notebooks")
                            .dropDestination(for: String.self) { items, _ in
                                SidebarDragPayload.drop(items, on: nil, store: store)
                            }
                    }
                case .tags:
                    Section("Tags") {
                        ForEach(tags) { node in
                            TagTreeRow(node: node)
                        }
                    }
                case .recentlyDeleted:
                    Section {
                        libraryRow("Recently Deleted", symbol: "trash", tint: .secondary, selection: .recentlyDeleted)
                            .contextMenu {
                                Button("Empty Recently Deleted…") { RecentlyDeletedCoordinator.shared.confirmingEmpty = true }
                                    .disabled(!store.hasRecentlyDeleted)
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: RunLoop.main)) { _ in
            todayNumber = Self.currentDayNumber()
        }
        .confirmationDialog(
            "Delete the smart folder “\(smartFolderPendingDelete?.name ?? "")”?",
            isPresented: Binding(
                get: { smartFolderPendingDelete != nil },
                set: { if !$0 { smartFolderPendingDelete = nil } }
            ),
            presenting: smartFolderPendingDelete
        ) { folder in
            Button("Delete Smart Folder", role: .destructive) { store.deleteSmartFolder(folder.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The notes in it aren’t touched.")
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
        } message: { notebook in
            Text(deleteMessage(notebook))
        }
    }

    private func smartFolderRow(_ folder: SmartFolder) -> some View {
        Label {
            Text(folder.name)
        } icon: {
            SidebarIcon(symbol: folder.symbol, tint: Tokens.Color.accent)
        }
        .badge(store.count(for: .smartFolder(folder.id)))
        .tag(SidebarSelection.smartFolder(folder.id))
        .help(folder.query)
        .contextMenu {
            Button("Edit Smart Folder…") { SmartFolderActions.edit(folder) }
            Button("Duplicate") { SmartFolderActions.duplicate(folder, store: store) }
            Divider()
            Button("Delete Smart Folder…", role: .destructive) { smartFolderPendingDelete = folder }
        }
    }

    /// An action, not a list: it opens today's note in the daily notes notebook.
    private var todayRow: some View {
        Label {
            Text("Today")
        } icon: {
            SidebarIcon(symbol: "calendar", tint: Tokens.Color.today)
        }
        .badge(Text(todayNumber))
        .contentShape(Rectangle())
        .onTapGesture { store.openDailyNote(for: Date()) }
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { store.openDailyNote(for: Date()) }
        .help("Open Today's Note")
        .contextMenu {
            Button("Open Today's Note") { store.openDailyNote(for: Date()) }
            Button("Open Note for Date…") { showsTodayCalendar = true }
        }
        .popover(isPresented: $showsTodayCalendar, arrowEdge: .trailing) {
            DailyCalendarView { showsTodayCalendar = false }
                .environmentObject(store)
        }
    }

    private static func currentDayNumber() -> String {
        String(DayKey(Date(), calendar: DayKey.dailyCalendar()).day)
    }

    private func libraryRow(_ title: String, symbol: String, tint: Color, selection: SidebarSelection) -> some View {
        Label {
            Text(title)
        } icon: {
            SidebarIcon(symbol: symbol, tint: tint)
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
            SidebarIcon(symbol: notebook.symbol, tint: notebook.color)
        }
        .badge(store.count(for: .notebook(notebook.id)))
        .tag(SidebarSelection.notebook(notebook.id))
        .contextMenu {
            Button("Rename") { beginRename(notebook) }
            Button("Edit Notebook…") { notebookDraft = NotebookDraft(notebook) }
            Button("New Notebook Inside…") { notebookDraft = NotebookDraft(parentID: notebook.id) }
                .disabled(store.notebookTree.depth(of: notebook.id) >= NotebookTree.maxDepth)
            NotebookMoveMenu(notebook: notebook)
            Divider()
            Button("Delete Notebook…", role: .destructive) { notebookPendingDelete = notebook }
        }
    }

    private func deleteMessage(_ notebook: Notebook) -> String {
        let inner = store.notebookTree.descendants(of: notebook.id).count
        let notes = store.count(for: .notebook(notebook.id))
        let noteText = notes == 1 ? "1 note" : "\(notes) notes"
        switch inner {
        case 0: return "Its \(noteText) will be moved to Recently Deleted."
        case 1: return "Its notebook inside and \(noteText) go too. The notes will be moved to Recently Deleted."
        default: return "Its \(inner) notebooks inside and \(noteText) go too. The notes will be moved to Recently Deleted."
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

/// Sidebar sections in program §9 order: library rows, smart folders, notebooks, tags, then Recently Deleted on its own.
enum SidebarSection: Hashable, CaseIterable {
    case library, smartFolders, notebooks, tags, recentlyDeleted

    static func visible(hasSmartFolders: Bool, hasTags: Bool, showsRecentlyDeleted: Bool) -> [SidebarSection] {
        allCases.filter { section in
            switch section {
            case .library, .notebooks: true
            case .smartFolders: hasSmartFolders
            case .tags: hasTags
            case .recentlyDeleted: showsRecentlyDeleted
            }
        }
    }
}

/// A sidebar row icon in its own colour, white on an emphasised (focused, accent) selection like Finder and Notes.
struct SidebarIcon: View {
    @Environment(\.backgroundProminence) private var prominence
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(prominence == .increased ? Tokens.Color.onAccent : tint)
    }
}

/// A tag and, under a disclosure triangle, the tags nested in it.
struct TagTreeRow: View {
    @EnvironmentObject private var store: NoteStore
    let node: TagNode

    var body: some View {
        if node.children.isEmpty {
            label
        } else {
            DisclosureGroup {
                ForEach(node.children) { TagTreeRow(node: $0) }
            } label: {
                label
            }
        }
    }

    private var label: some View {
        Label {
            Text(node.name)
        } icon: {
            SidebarIcon(symbol: "number", tint: .secondary)
        }
        .badge(node.totalCount)
        .tag(SidebarSelection.tag(node.path))
        .help("#\(node.path)")
        .contextMenu {
            Button("Rename Tag…") { TagEditCoordinator.shared.renaming = .init(tag: node.path) }
            Button("New Smart Folder from Tag") { SmartFolderActions.create(fromTag: node.path, store: store) }
            Button("Delete Tag…", role: .destructive) { TagEditCoordinator.shared.pendingDelete = node.path }
        }
    }
}
