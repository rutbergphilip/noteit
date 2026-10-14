import SwiftUI

@main
struct NoteItApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = NoteStore.shared
    @AppStorage(PrefKey.showMenuBarIcon) private var showMenuBarIcon = true

    init() {
        LaunchMigration.run()
        NoteStore.prepareDefaultLocation()
    }

    var body: some Scene {
        WindowGroup(id: WindowRouter.mainWindowID) {
            MainView()
                .environmentObject(store)
        }
        .defaultSize(width: 1120, height: 720)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands { NoteItCommands() }
        .commands { RecentlyDeletedCommands() }
        .commands { ExportCommands() }
        .commands { ImportCommands() }

        Settings {
            SettingsView()
                .environmentObject(store)
        }

        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuBarView()
                .environmentObject(store)
        } label: {
            MenuBarGlyph()
        }
        .menuBarExtraStyle(.window)
    }
}

struct NoteItCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            CheckForUpdatesButton()
        }

        CommandGroup(replacing: .newItem) {
            Button("New Note") {
                NotificationCenter.default.post(name: .noteItNewNote, object: nil)
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("New Notebook…") {
                NotificationCenter.default.post(name: .noteItNewNotebook, object: nil)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        // ⌘F searches all notes; in-note find moves to ⌥⌘F.
        CommandGroup(replacing: .textEditing) {
            Button("Search Notes") {
                NotificationCenter.default.post(name: .noteItFocusSearch, object: nil)
            }
            .keyboardShortcut("f", modifiers: .command)

            Divider()

            Button("Find in Note…") { FindCommand.send(.showFindInterface) }
                .keyboardShortcut("f", modifiers: [.command, .option])
            Button("Find Next") { FindCommand.send(.nextMatch) }
                .keyboardShortcut("g", modifiers: .command)
            Button("Find Previous") { FindCommand.send(.previousMatch) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Button("Use Selection for Find") { FindCommand.send(.setSearchString) }
                .keyboardShortcut("e", modifiers: .command)
        }

        CommandGroup(after: .windowArrangement) {
            Button("NoteIt Notes") { WindowRouter.showMainWindow() }
                .keyboardShortcut("0", modifiers: .command)
        }
    }
}

/// "Check for Updates…" for the app menu; nothing when updates are off.
struct CheckForUpdatesButton: View {
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        if updater.isEnabled {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }
    }
}

/// Routes find-bar actions to the first responder (the editor's NSTextView).
enum FindCommand {
    @MainActor
    static func send(_ action: NSTextFinder.Action) {
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        NSApp.sendAction(#selector(NSTextView.performFindPanelAction(_:)), to: nil, from: sender)
    }
}

extension Notification.Name {
    static let noteItNewNote = Notification.Name("noteItNewNote")
    static let noteItFocusSearch = Notification.Name("noteItFocusSearch")
    static let noteItShowMainWindow = Notification.Name("noteItShowMainWindow")
    static let noteItNewNotebook = Notification.Name("noteItNewNotebook")
    /// Posted after a user change to the library has been saved (sync uses it to schedule a pass).
    static let noteItLocalChange = Notification.Name("noteItLocalChange")
}

/// The menu bar icon: the squiggle + pencil template glyph, with a spark while Quick Capture is open.
private struct MenuBarGlyph: View {
    @ObservedObject private var visibility = QuickCaptureVisibility.shared

    var body: some View {
        Group {
            if let glyph = AppResources.menuBarGlyph(capturing: visibility.isCapturing) {
                Image(nsImage: glyph)
            } else {
                Image(systemName: "pencil.line")
            }
        }
        .accessibilityLabel("NoteIt")
    }
}
