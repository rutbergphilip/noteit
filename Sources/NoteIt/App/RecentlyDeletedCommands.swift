import AppKit
import SwiftUI

/// File menu items for Recently Deleted and Version History.
struct RecentlyDeletedCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .newItem) {
            RecentlyDeletedMenuItems()
        }
    }
}

private struct RecentlyDeletedMenuItems: View {
    @ObservedObject private var store = NoteStore.shared

    private var selectedNote: NoteMeta? { store.note(with: store.selectedNoteID) }

    var body: some View {
        Divider()
        Button("Version History…") {
            guard let note = selectedNote else { return }
            NoteMenuActions.showVersionHistory(of: note)
        }
        .keyboardShortcut(MenuShortcuts.versionHistory)
        .disabled(selectedNote == nil || selectedNote?.deletedAt != nil)

        Button(selectedNote?.deletedAt != nil ? "Delete Now…" : "Delete Note") { deleteSelectedNote() }
            .keyboardShortcut(MenuShortcuts.deleteNote)
            .disabled(selectedNote == nil)

        Button("Empty Recently Deleted…") {
            WindowRouter.showMainWindow()
            RecentlyDeletedCoordinator.shared.confirmingEmpty = true
        }
        .disabled(!store.hasRecentlyDeleted)
    }

    /// ⌘⌫ keeps its text meaning (delete to the start of the line) while typing anywhere.
    private func deleteSelectedNote() {
        if let textView = NSApp.keyWindow?.firstResponder as? NSTextView {
            textView.deleteToBeginningOfLine(nil)
            return
        }
        guard let note = selectedNote, isMainWindowKey else { return }
        NoteMenuActions.delete(note, undoManager: NSApp.keyWindow?.undoManager)
    }

    private var isMainWindowKey: Bool {
        guard let window = WindowRouter.mainWindow else { return false }
        return window.isKeyWindow
    }
}

/// Note actions shared by the File menu and the command palette.
@MainActor
enum NoteMenuActions {
    static func showVersionHistory(of note: NoteMeta) {
        guard note.deletedAt == nil else { return }
        WindowRouter.showMainWindow()
        RecentlyDeletedCoordinator.shared.historyNoteID = note.id
    }

    /// Moves the note to Recently Deleted, or asks to delete it for good when it's already there.
    static func delete(_ note: NoteMeta, store: NoteStore? = nil, undoManager: UndoManager?) {
        if note.deletedAt != nil {
            RecentlyDeletedCoordinator.shared.pendingDeleteNow = [note.id]
        } else {
            RecentlyDeletedCoordinator.shared.delete([note.id], store: store, undoManager: undoManager)
        }
    }
}
