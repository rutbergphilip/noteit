import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The note group of the File menu (program §9 order).
struct NoteCommands: Commands {
    /// Program §9's note group, as command IDs. Owners insert their buttons at their place in this order.
    /// "Empty Recently Deleted…" follows the group and isn't part of it. Foundations Task 6.4.
    static let order: [String] = ["togglePin", "lockNote", "removeLock", "lockAllNotes", "versionHistory", "deleteNote"]

    var body: some Commands {
        CommandGroup(after: .newItem) {
            NoteMenuItems()
        }
    }
}

private struct NoteMenuItems: View {
    @ObservedObject private var store = NoteStore.shared

    private var selectedNote: NoteMeta? { store.note(with: store.selectedNoteID) }

    var body: some View {
        Divider()
        Button("Version History…") {
            guard let note = selectedNote else { return }
            NoteMenuActions.showVersionHistory(of: note)
        }
        .menuShortcut(.versionHistory)
        .disabled(selectedNote == nil || selectedNote?.deletedAt != nil)

        Button(selectedNote?.deletedAt != nil ? "Delete Now…" : "Delete Note") { deleteSelectedNote() }
            .menuShortcut(.deleteNote)
            .disabled(selectedNote == nil)

        Button("Empty Recently Deleted…") {
            WindowRouter.showMainWindow()
            RecentlyDeletedCoordinator.shared.confirmingEmpty = true
        }
        .disabled(!store.hasRecentlyDeleted)
    }

    /// ⌘⌫ keeps its text meaning (delete to the start of the line) while typing anywhere.
    private func deleteSelectedNote() {
        if let textView = NSApp.keyWindow?.firstResponder as? NSTextView, !isOtherKeyPress(NSApp.currentEvent) {
            textView.deleteToBeginningOfLine(nil)
            return
        }
        guard let note = selectedNote, isMainWindowKey else { return }
        NoteMenuActions.delete(note, undoManager: NSApp.keyWindow?.undoManager)
    }

    /// A shortcut other than ⌘⌫ chosen in Settings deletes the note even while typing.
    private func isOtherKeyPress(_ event: NSEvent?) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        return !(Int(event.keyCode) == kVK_Delete && flags == .command)
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
