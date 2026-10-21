import AppKit
import NoteItCore
import SwiftUI

/// What the template picker does with the chosen template.
struct TemplatePickerRequest: Identifiable {
    enum Mode {
        case newNote
        case insert(WeakTextView)
    }

    final class WeakTextView {
        weak var textView: NoteItTextView?
        init(_ textView: NoteItTextView) { self.textView = textView }
    }

    let id = UUID()
    let mode: Mode
}

extension Notification.Name {
    /// `object` is a `TemplatePickerRequest`.
    static let noteItShowTemplatePicker = Notification.Name("noteItShowTemplatePicker")
}

/// File › New Note from Template… and Insert Template…: a search field over the templates.
struct TemplatePickerSheet: View {
    @EnvironmentObject private var store: NoteStore
    @Environment(\.dismiss) private var dismiss
    let request: TemplatePickerRequest
    @State private var query = ""
    @State private var selectedID: UUID?
    @FocusState private var searchFocused: Bool

    private struct Row: Identifiable {
        let meta: NoteMeta
        let name: String
        var id: UUID { meta.id }
    }

    private var rows: [Row] {
        let all = store.templates.filter { !$0.isLocked }.map { Row(meta: $0, name: NoteStore.templateName($0)) }
        let fuzzy = FuzzyQuery(query)
        let matching = all.compactMap { row in FuzzyMatcher.match(fuzzy, in: row.name).map { (row, $0.score) } }
            .enumerated()
            .sorted { $0.element.1 != $1.element.1 ? $0.element.1 > $1.element.1 : $0.offset < $1.offset }
            .map(\.element.0)
        return matching.isEmpty && !isInsert ? all : matching
    }

    private var typedTitle: String? {
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isInsert, !typed.isEmpty,
              !store.templates.contains(where: { FuzzyMatcher.match(typed, in: NoteStore.templateName($0)) != nil }) else { return nil }
        return typed
    }

    private var isInsert: Bool {
        if case .insert = request.mode { return true }
        return false
    }

    var body: some View {
        let rows = rows
        VStack(alignment: .leading, spacing: 12) {
            Text(isInsert ? "Insert Template" : "New Note from Template")
                .font(.title3.weight(.semibold))
            TextField(isInsert ? "Search templates" : "Search templates or type a title", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit { choose(currentID(in: rows)) }
                .onKeyPress(.downArrow) { move(1, in: rows); return .handled }
                .onKeyPress(.upArrow) { move(-1, in: rows); return .handled }
            if store.templates.isEmpty {
                Text("No templates yet. Use New Template in the command palette to make one.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else if rows.isEmpty {
                Text("No templates match.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                if let typedTitle {
                    Text("The new note's title: \(typedTitle)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                List(rows, selection: $selectedID) { row in
                    Label(row.name, systemImage: "doc.on.doc")
                        .tag(row.id)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { choose(row.id) }
                }
                .frame(minHeight: 180)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isInsert ? "Insert" : "Create") { choose(currentID(in: rows)) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(currentID(in: rows) == nil)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear { searchFocused = true }
    }

    private func currentID(in rows: [Row]) -> UUID? {
        if let selectedID, rows.contains(where: { $0.id == selectedID }) { return selectedID }
        return rows.first?.id
    }

    private func move(_ delta: Int, in rows: [Row]) {
        guard !rows.isEmpty else { return }
        let current = currentID(in: rows).flatMap { id in rows.firstIndex { $0.id == id } } ?? 0
        selectedID = rows[min(max(current + delta, 0), rows.count - 1)].id
    }

    private func choose(_ id: UUID?) {
        guard let id, let template = store.note(with: id) else { return }
        dismiss()
        switch request.mode {
        case .newNote:
            let title = Self.title(typed: query, templateName: NoteStore.templateName(template))
            store.createNoteFromTemplateInCurrentContext(id, title: title)
            WindowRouter.focusEditor()
        case .insert(let box):
            guard let textView = box.textView else { return }
            DispatchQueue.main.async { textView.insertTemplate(id) }
        }
    }

    /// The typed text is the new note's `{{title}}` unless it matches the template's name.
    static func title(typed: String, templateName: String) -> String {
        let typed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, FuzzyMatcher.match(typed, in: templateName) == nil else { return "" }
        return typed
    }
}
