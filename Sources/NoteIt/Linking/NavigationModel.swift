import Foundation

/// One main window's Go Back / Go Forward state.
@MainActor
final class NavigationModel: ObservableObject {
    @Published private(set) var history = NavigationHistory()
    /// The model of the main window that was key last; menu commands and selection changes go to it.
    private(set) static weak var active: NavigationModel?

    var isActive: Bool { Self.active === self }

    func becomeActive() {
        Self.active = self
    }

    func visit(_ id: UUID?) {
        guard let id else { return }
        history.visit(id)
    }

    func goBack(in store: NoteStore) {
        guard let id = history.back(isValid: { Self.isLive($0, in: store) }) else { return }
        store.navigate(to: id, heading: nil)
    }

    func goForward(in store: NoteStore) {
        guard let id = history.forward(isValid: { Self.isLive($0, in: store) }) else { return }
        store.navigate(to: id, heading: nil)
    }

    private static func isLive(_ id: UUID, in store: NoteStore) -> Bool {
        guard let meta = store.note(with: id) else { return false }
        return meta.deletedAt == nil
    }
}
