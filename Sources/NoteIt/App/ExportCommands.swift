import SwiftUI

/// File › Export…, Share and Print, and Edit › Copy as Markdown.
struct ExportCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .importExport) {
            ExportMenuItems()
        }

        CommandGroup(replacing: .printItem) {
            PrintMenuItem()
        }

        CommandGroup(after: .pasteboard) {
            CopyAsMarkdownMenuItem()
        }
    }
}

private struct ExportMenuItems: View {
    @ObservedObject private var store = NoteStore.shared

    var body: some View {
        let note = store.note(with: store.selectedNoteID)
        Divider()

        Button("Export Note As…") { ExportActions.exportCurrentNote() }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(note == nil)
        Button("Export Notebook…") { ExportActions.exportCurrentNotebook() }
            .disabled(ExportActions.currentNotebook == nil)
        Button("Export All Notes…") { ExportActions.exportAllNotes() }
            .disabled(store.notes.isEmpty)

        Divider()

        Menu("Share") {
            if let note {
                ForEach(ExportActions.sharingServices, id: \.self) { service in
                    Button {
                        ExportActions.share(note, with: service)
                    } label: {
                        Label { Text(service.menuItemTitle) } icon: { Image(nsImage: service.image) }
                    }
                }
            }
        }
        .disabled(note == nil)
    }
}

private struct PrintMenuItem: View {
    @ObservedObject private var store = NoteStore.shared

    var body: some View {
        Button("Print…") { ExportActions.printCurrentNote() }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(store.note(with: store.selectedNoteID) == nil)
    }
}

private struct CopyAsMarkdownMenuItem: View {
    @ObservedObject private var store = NoteStore.shared

    var body: some View {
        Button("Copy as Markdown") { ExportActions.copyAsMarkdown() }
            .keyboardShortcut("c", modifiers: [.command, .option, .shift])
            .disabled(store.note(with: store.selectedNoteID) == nil)
    }
}
