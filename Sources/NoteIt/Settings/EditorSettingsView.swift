import SwiftUI

struct EditorSettingsView: View {
    @EnvironmentObject private var store: NoteStore
    @AppStorage(PrefKey.editorFontSize) private var fontSize = PrefDefault.editorFontSize
    @AppStorage(PrefKey.defaultNotebookID) private var defaultNotebookRaw = ""

    var body: some View {
        Form {
            Section {
                LabeledContent("Default font size") {
                    HStack(spacing: 10) {
                        Image(systemName: "textformat.size.smaller")
                            .foregroundStyle(.secondary)
                        Slider(value: $fontSize, in: 11...24, step: 1)
                            .frame(width: 180)
                        Image(systemName: "textformat.size.larger")
                            .foregroundStyle(.secondary)
                        Text("\(Int(fontSize)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)
                    }
                }
                Text("The quick brown fox jumps over the lazy dog.")
                    .font(.system(size: fontSize))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                    .animation(.easeOut(duration: 0.12), value: fontSize)
            } header: {
                Text("Text")
            }

            Section {
                Picker("Default notebook for new notes", selection: notebookBinding) {
                    Label("No Notebook", systemImage: "tray.full").tag(PrefDefault.noNotebook)
                    Divider()
                    ForEach(store.sortedNotebooks) { notebook in
                        Label(notebook.name, systemImage: notebook.symbol).tag(notebook.id.uuidString)
                    }
                }
                SettingsFootnote(text: "Used by Quick Capture and notes created from the menu bar.")
            } header: {
                Text("New Notes")
            }
        }
        .formStyle(.grouped)
        .frame(height: 300)
    }

    private var notebookBinding: Binding<String> {
        Binding(
            get: {
                _ = defaultNotebookRaw
                return store.defaultNotebookIDForNewNotes?.uuidString ?? PrefDefault.noNotebook
            },
            set: { defaultNotebookRaw = $0 }
        )
    }
}
