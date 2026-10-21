import SwiftUI

struct MainView: View {
    @EnvironmentObject private var store: NoteStore
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var notebookDraft: NotebookDraft?
    @StateObject private var navigation = NavigationModel()

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(notebookDraft: $notebookDraft)
                .navigationSplitViewColumnWidth(min: Tokens.Size.sidebarMin, ideal: Tokens.Size.sidebarWidth, max: Tokens.Size.sidebarMax)
        } content: {
            NoteListView()
                .navigationSplitViewColumnWidth(min: Tokens.Size.noteListMin, ideal: Tokens.Size.noteListWidth, max: Tokens.Size.noteListMax)
        } detail: {
            EditorContainerView()
                .environmentObject(navigation)
        }
        .frame(minWidth: 820, minHeight: 480)
        .sheet(item: $notebookDraft) { draft in
            NotebookEditSheet(draft: draft)
                .environmentObject(store)
        }
        .onReceive(NotificationCenter.default.publisher(for: .noteItNewNotebook)) { _ in
            guard controlActiveState == .key || NSApp.keyWindow == nil else { return }
            notebookDraft = NotebookDraft()
        }
        .onAppear { if NavigationModel.active == nil || controlActiveState == .key { navigation.becomeActive() } }
        .onChange(of: controlActiveState) { _, state in
            if state == .key { navigation.becomeActive() }
        }
        .onChange(of: store.selectedNoteID, initial: true) { _, id in
            guard navigation.isActive else { return }
            navigation.visit(id)
        }
        .onReceive(NotificationCenter.default.publisher(for: .noteItGoBack)) { _ in
            guard navigation.isActive else { return }
            navigation.goBack(in: store)
        }
        .onReceive(NotificationCenter.default.publisher(for: .noteItGoForward)) { _ in
            guard navigation.isActive else { return }
            navigation.goForward(in: store)
        }
        .recentlyDeletedSupport()
        .capturesOpenWindow()
    }
}
