import SwiftUI

/// Editable notebook values; `id == nil` means a new notebook.
struct NotebookDraft: Identifiable {
    let draftID = UUID()
    var notebookID: UUID?
    var name: String = ""
    var symbol: String = "book"
    var colorHex: String = NotebookPalette.colors[0]

    var id: UUID { draftID }

    init() {}

    init(_ notebook: Notebook) {
        notebookID = notebook.id
        name = notebook.name
        symbol = notebook.symbol
        colorHex = notebook.colorHex
    }
}

struct NotebookEditSheet: View {
    @EnvironmentObject private var store: NoteStore
    @Environment(\.dismiss) private var dismiss
    @State var draft: NotebookDraft
    @FocusState private var nameFocused: Bool

    private var isNew: Bool { draft.notebookID == nil }
    private var trimmedName: String { draft.name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var tint: Color { Color(hex: draft.colorHex) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: Tokens.Radius.preview, style: .continuous)
                    .fill(tint.gradient)
                    .frame(width: 52, height: 52)
                    .overlay(
                        Image(systemName: draft.symbol)
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(.white)
                    )
                    .shadow(color: tint.opacity(0.35), radius: 6, y: 3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(isNew ? "New Notebook" : "Edit Notebook")
                        .font(.title3.weight(.semibold))
                    TextField("Name", text: $draft.name)
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFocused)
                        .onSubmit(save)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Color").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    ForEach(NotebookPalette.colors, id: \.self) { hex in
                        let selected = hex == draft.colorHex
                        Button {
                            draft.colorHex = hex
                        } label: {
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 22, height: 22)
                                .overlay(Circle().strokeBorder(.white.opacity(selected ? 0.9 : 0), lineWidth: 2))
                                .padding(3)
                                .overlay(Circle().strokeBorder(Color(hex: hex).opacity(selected ? 1 : 0), lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                        .help(hex)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Icon").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 6), count: 8), spacing: 6) {
                    ForEach(NotebookPalette.symbols, id: \.self) { symbol in
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
                                        .fill(selected ? AnyShapeStyle(tint) : AnyShapeStyle(.quaternary.opacity(0.6)))
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Create" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 380)
        .onAppear { nameFocused = true }
    }

    private func save() {
        guard !trimmedName.isEmpty else { return }
        if let id = draft.notebookID, var notebook = store.notebook(with: id) {
            notebook.name = trimmedName
            notebook.symbol = draft.symbol
            notebook.colorHex = draft.colorHex
            store.updateNotebook(notebook)
        } else {
            let notebook = store.createNotebook(name: trimmedName, symbol: draft.symbol, colorHex: draft.colorHex)
            store.selection = .notebook(notebook.id)
        }
        dismiss()
    }
}
