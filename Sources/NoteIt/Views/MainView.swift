import SwiftUI

struct MainView: View {
    @EnvironmentObject private var store: NoteStore
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var notebookDraft: NotebookDraft?
    @State private var smartFolderDraft: SmartFolderDraft?
    @State private var templateRequest: TemplatePickerRequest?
    @State private var showsDailyCalendar = false
    @StateObject private var navigation = NavigationModel()

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(notebookDraft: $notebookDraft)
                .navigationSplitViewColumnWidth(min: Tokens.Size.sidebarMin, ideal: Tokens.Size.sidebarWidth, max: Tokens.Size.sidebarMax)
        } content: {
            Group {
                if store.selection == .tasks {
                    TaskListView()
                } else {
                    NoteListView()
                }
            }
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
        .sheet(item: $smartFolderDraft) { draft in
            SmartFolderEditSheet(draft: draft)
                .environmentObject(store)
        }
        .onReceive(NotificationCenter.default.publisher(for: .noteItEditSmartFolder)) { note in
            guard controlActiveState == .key || NSApp.keyWindow == nil else { return }
            smartFolderDraft = note.object as? SmartFolderDraft ?? SmartFolderDraft()
        }
        .sheet(item: $templateRequest) { request in
            TemplatePickerSheet(request: request)
                .environmentObject(store)
        }
        .sheet(isPresented: $showsDailyCalendar) {
            DailyCalendarView(selected: store.selectedNoteID.flatMap { store.dailyDay(of: $0) }) {
                showsDailyCalendar = false
            }
            .environmentObject(store)
        }
        .onReceive(NotificationCenter.default.publisher(for: .noteItShowDailyCalendar)) { _ in
            guard controlActiveState == .key || NSApp.keyWindow == nil else { return }
            showsDailyCalendar = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .noteItShowTemplatePicker)) { note in
            guard controlActiveState == .key || NSApp.keyWindow == nil,
                  let request = note.object as? TemplatePickerRequest else { return }
            templateRequest = request
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
        .tagEditSupport()
        .capturesOpenWindow()
    }
}
