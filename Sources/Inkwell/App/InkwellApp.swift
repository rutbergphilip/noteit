import SwiftUI

@main
struct InkwellApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = NoteStore.shared
    @AppStorage(PrefKey.showMenuBarIcon) private var showMenuBarIcon = true

    var body: some Scene {
        WindowGroup(id: WindowRouter.mainWindowID) {
            MainView()
                .environmentObject(store)
        }
        .defaultSize(width: 1120, height: 720)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands { InkwellCommands() }

        Settings {
            SettingsView()
                .environmentObject(store)
        }

        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuBarView()
                .environmentObject(store)
        } label: {
            Image(systemName: "pencil.line")
                .accessibilityLabel("Inkwell")
        }
        .menuBarExtraStyle(.window)
    }
}

struct InkwellCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Note") {
                NotificationCenter.default.post(name: .inkwellNewNote, object: nil)
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("New Notebook…") {
                NotificationCenter.default.post(name: .inkwellNewNotebook, object: nil)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        // ⌘F searches all notes; in-note find moves to ⌥⌘F.
        CommandGroup(replacing: .textEditing) {
            Button("Search Notes") {
                NotificationCenter.default.post(name: .inkwellFocusSearch, object: nil)
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
            Button("Inkwell Notes") { WindowRouter.showMainWindow() }
                .keyboardShortcut("0", modifiers: .command)
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
    static let inkwellNewNote = Notification.Name("inkwellNewNote")
    static let inkwellFocusSearch = Notification.Name("inkwellFocusSearch")
    static let inkwellShowMainWindow = Notification.Name("inkwellShowMainWindow")
    static let inkwellNewNotebook = Notification.Name("inkwellNewNotebook")
}
