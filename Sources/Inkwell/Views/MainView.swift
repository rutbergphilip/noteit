import SwiftUI

struct MainView: View {
    @EnvironmentObject private var store: NoteStore
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var notebookDraft: NotebookDraft?

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(notebookDraft: $notebookDraft)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 320)
        } content: {
            NoteListView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 440)
        } detail: {
            EditorContainerView()
        }
        .frame(minWidth: 820, minHeight: 480)
        .sheet(item: $notebookDraft) { draft in
            NotebookEditSheet(draft: draft)
                .environmentObject(store)
        }
        .onReceive(NotificationCenter.default.publisher(for: .inkwellNewNotebook)) { _ in
            guard controlActiveState == .key || NSApp.keyWindow == nil else { return }
            notebookDraft = NotebookDraft()
        }
        .capturesOpenWindow()
    }
}
