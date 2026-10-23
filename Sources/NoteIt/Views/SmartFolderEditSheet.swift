import NoteItCore
import SwiftUI

/// What the smart folder sheet edits; `folderID` nil creates a new folder.
struct SmartFolderDraft: Identifiable {
    let id = UUID()
    var folderID: UUID?
    var name = ""
    var query = ""
    var symbol = SmartFolder.defaultSymbol

    init(query: String = "") {
        self.query = query
    }

    init(_ folder: SmartFolder) {
        folderID = folder.id
        name = folder.name
        query = folder.query
        symbol = folder.symbol
    }

    static let starters: [(name: String, query: String, symbol: String)] = [
        ("Open tasks", "is:todo", "checklist"),
        ("Due this week", "due:<7d", "calendar"),
        ("Edited today", "edited:today", "clock"),
        ("Untagged", "is:untagged", "tag.slash"),
    ]

    static let symbols = [
        SmartFolder.defaultSymbol, "checklist", "calendar", "clock", "tag", "tag.slash", "star", "flag",
        "bell", "paperclip", "briefcase", "house", "bookmark", "lightbulb", "magnifyingglass", "tray",
    ]
}

extension Notification.Name {
    /// Object: a `SmartFolderDraft`, or nil for an empty one.
    static let noteItEditSmartFolder = Notification.Name("noteItEditSmartFolder")
}

@MainActor
enum SmartFolderActions {
    static func newSmartFolder(query: String = "") {
        WindowRouter.showMainWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NotificationCenter.default.post(name: .noteItEditSmartFolder, object: SmartFolderDraft(query: query))
        }
    }

    static func edit(_ folder: SmartFolder) {
        NotificationCenter.default.post(name: .noteItEditSmartFolder, object: SmartFolderDraft(folder))
    }

    static func create(fromTag tag: String, store: NoteStore) {
        let name = String("#\(tag)".prefix(SmartFolder.maxNameLength))
        let value = tag.contains(where: \.isWhitespace) ? "\"\(tag)\"" : tag
        if let folder = try? store.createSmartFolder(name: name, query: "tag:\(value)", symbol: "number") {
            store.searchText = ""
            store.selection = .smartFolder(folder.id)
        }
    }

    static func duplicate(_ folder: SmartFolder, store: NoteStore) {
        let name = String("\(folder.name) Copy".prefix(SmartFolder.maxNameLength))
        if let copy = try? store.createSmartFolder(name: name, query: folder.query, symbol: folder.symbol) {
            store.selection = .smartFolder(copy.id)
        }
    }
}

struct SmartFolderEditSheet: View {
    @EnvironmentObject private var store: NoteStore
    @Environment(\.dismiss) private var dismiss
    @State var draft: SmartFolderDraft
    @State private var error: String?
    @FocusState private var focus: Field?

    private enum Field { case name, query }

    private var isNew: Bool { draft.folderID == nil }
    private var trimmedQuery: String { draft.query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var issues: [QueryIssue] { SearchQuery.parse(draft.query).issues }

    private var canSave: Bool {
        issues.isEmpty && !trimmedQuery.isEmpty && trimmedQuery.count <= SmartFolder.maxQueryLength
            && !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draft.name.trimmingCharacters(in: .whitespacesAndNewlines).count <= SmartFolder.maxNameLength
    }

    private var matchCount: Int? {
        guard !trimmedQuery.isEmpty, issues.isEmpty else { return nil }
        return store.searchResults(for: .allNotes, search: trimmedQuery, order: .bestMatch, decorated: false).count
    }

    private var suggestions: [QueryCompletionSource.Suggestion] {
        guard focus == .query else { return [] }
        let notebooks = store.sortedNotebooks.map { store.notebookTree.path(of: $0.id).joined(separator: "/") }
        return QueryCompletionSource.suggestions(for: draft.query, tags: Array(store.tagTree.flattenedPaths).sorted(),
                                                 notebooks: notebooks)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: Tokens.Radius.preview, style: .continuous)
                    .fill(Tokens.Color.accent.gradient)
                    .frame(width: 52, height: 52)
                    .overlay(
                        Image(systemName: draft.symbol)
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(.white)
                    )
                VStack(alignment: .leading, spacing: 4) {
                    Text(isNew ? "New Smart Folder" : "Edit Smart Folder")
                        .font(.title3.weight(.semibold))
                    TextField("Name", text: $draft.name)
                        .textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .name)
                        .onSubmit(save)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Search").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                TextField("tag:work is:todo", text: $draft.query)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .focused($focus, equals: .query)
                    .onSubmit(save)
                    .accessibilityLabel("Search")
                if !suggestions.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(suggestions) { suggestion in
                                Button(suggestion.title) { draft.query = suggestion.text }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                        }
                    }
                }
                if let issue = issues.first {
                    Text(issue.message).font(.callout).foregroundStyle(.red)
                } else if let matchCount {
                    Text(matchCount == 1 ? "1 note matches" : "\(matchCount) notes match")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if trimmedQuery.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(SmartFolderDraft.starters, id: \.query) { starter in
                            Button(starter.name) {
                                draft.query = starter.query
                                if draft.name.trimmingCharacters(in: .whitespaces).isEmpty {
                                    draft.name = starter.name
                                    draft.symbol = starter.symbol
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Icon").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 6), count: 8), spacing: 6) {
                    ForEach(SmartFolderDraft.symbols, id: \.self) { symbol in
                        let selected = symbol == draft.symbol
                        Button {
                            draft.symbol = symbol
                        } label: {
                            Image(systemName: symbol)
                                .font(.system(size: 15))
                                .frame(width: 34, height: 34)
                                .foregroundStyle(selected ? .white : .primary)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(selected ? AnyShapeStyle(Tokens.Color.accent) : AnyShapeStyle(.quaternary.opacity(0.6)))
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(symbol)
                    }
                }
            }

            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Create" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(22)
        .frame(width: 420)
        .onAppear { focus = draft.name.isEmpty ? .name : .query }
    }

    private func save() {
        guard canSave else { return }
        do {
            if let id = draft.folderID {
                try store.updateSmartFolder(id, name: draft.name, query: draft.query, symbol: draft.symbol)
            } else {
                let folder = try store.createSmartFolder(name: draft.name, query: draft.query, symbol: draft.symbol)
                store.searchText = ""
                store.selection = .smartFolder(folder.id)
            }
            dismiss()
        } catch let failure as SmartFolderError {
            error = Self.message(for: failure)
        } catch {
            self.error = error.localizedDescription
        }
    }

    static func message(for error: SmartFolderError) -> String {
        switch error {
        case .emptyName: "Give the smart folder a name."
        case .nameTooLong: "Use a name of \(SmartFolder.maxNameLength) characters or fewer."
        case .emptyQuery: "Type a search."
        case .queryTooLong: "Use a search of \(SmartFolder.maxQueryLength) characters or fewer."
        case .tooMany: "You can have up to \(SmartFolder.maxCount) smart folders."
        case .notFound: "This smart folder was deleted."
        }
    }
}
