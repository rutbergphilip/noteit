import SwiftUI

/// Window-level state for Recently Deleted and Version History: the undo toast, confirmations and the sheet.
@MainActor
final class RecentlyDeletedCoordinator: ObservableObject {
    static let shared = RecentlyDeletedCoordinator()

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let noteIDs: [UUID]
        var message: String { "Moved to Recently Deleted" }
    }

    @Published private(set) var toast: Toast?
    @Published var confirmingEmpty = false
    /// Notes waiting for a "Delete Now" confirmation.
    @Published var pendingDeleteNow: [UUID] = []
    /// The note whose Version History sheet is open.
    @Published var historyNoteID: UUID?

    private weak var toastUndoManager: UndoManager?
    private var dismissWorkItem: DispatchWorkItem?
    static let toastDuration: TimeInterval = 6

    /// Moves notes to Recently Deleted and offers Undo, both in a toast and through `undoManager` (⌘Z).
    func delete(_ ids: [UUID], store: NoteStore? = nil, undoManager: UndoManager?) {
        let store = store ?? .shared
        let moved = store.moveToRecentlyDeleted(ids, undoManager: undoManager)
        guard !moved.isEmpty else { return }
        toastUndoManager = undoManager
        withAnimation(.snappy(duration: 0.2)) { toast = Toast(noteIDs: moved) }
        dismissWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.dismissToast() }
        }
        dismissWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.toastDuration, execute: item)
    }

    func undoFromToast(store: NoteStore? = nil) {
        let store = store ?? .shared
        guard let toast else { return }
        toastUndoManager?.removeAllActions(withTarget: store)
        let recovered = store.recover(toast.noteIDs)
        if recovered.count == 1, store.selection != .recentlyDeleted { store.selectedNoteID = recovered[0] }
        dismissToast()
    }

    func dismissToast() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        withAnimation(.snappy(duration: 0.2)) { toast = nil }
    }
}

extension View {
    /// The undo toast, the Recently Deleted confirmations and the Version History sheet for the main window.
    func recentlyDeletedSupport() -> some View {
        modifier(RecentlyDeletedSupport())
    }
}

private struct RecentlyDeletedSupport: ViewModifier {
    @EnvironmentObject private var store: NoteStore
    @ObservedObject private var coordinator = RecentlyDeletedCoordinator.shared

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let toast = coordinator.toast {
                    UndoToast(message: toast.message) { coordinator.undoFromToast(store: store) }
                        .padding(.bottom, 18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .id(toast.id)
                }
            }
            .confirmationDialog(
                "Delete all notes in Recently Deleted?",
                isPresented: $coordinator.confirmingEmpty
            ) {
                Button("Delete \(countLabel(store.deletedNotes.count))", role: .destructive) {
                    store.emptyRecentlyDeleted()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("They will be removed immediately. You can’t undo this action.")
            }
            .confirmationDialog(
                deleteNowTitle,
                isPresented: Binding(
                    get: { !coordinator.pendingDeleteNow.isEmpty },
                    set: { if !$0 { coordinator.pendingDeleteNow = [] } }
                )
            ) {
                Button("Delete Now", role: .destructive) {
                    store.deleteNow(coordinator.pendingDeleteNow)
                    coordinator.pendingDeleteNow = []
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This note will be removed immediately. You can’t undo this action.")
            }
            .sheet(item: Binding(
                get: { coordinator.historyNoteID.map(HistoryTarget.init) },
                set: { coordinator.historyNoteID = $0?.id }
            )) { target in
                VersionHistorySheet(noteID: target.id)
                    .environmentObject(store)
            }
    }

    private var deleteNowTitle: String {
        let ids = coordinator.pendingDeleteNow
        if ids.count == 1, let note = store.note(with: ids[0]) { return "Delete “\(note.displayTitle)” now?" }
        return "Delete \(countLabel(ids.count)) now?"
    }

    private func countLabel(_ count: Int) -> String {
        count == 1 ? "1 Note" : "\(count) Notes"
    }

    private struct HistoryTarget: Identifiable {
        let id: UUID
    }
}

struct UndoToast: View {
    let message: String
    var symbol = "trash"
    var secondary: (title: String, action: () -> Void)?
    let undo: () -> Void

    var body: some View {
        HStack(spacing: Tokens.Space.s12) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Tokens.Color.ink)
            if let secondary {
                Button(secondary.title, action: secondary.action)
                    .controlSize(.small)
            }
            Button("Undo", action: undo)
                .controlSize(.small)
                .help("Undo (⌘Z)")
        }
        .padding(.leading, Tokens.Space.s14)
        .padding(.trailing, Tokens.Space.s6)
        .padding(.vertical, Tokens.Space.s6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Tokens.Color.hairline, lineWidth: Tokens.Size.hairline))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        .accessibilityElement(children: .contain)
    }
}
