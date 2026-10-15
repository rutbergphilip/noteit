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
            .keyboardShortcut(MenuShortcuts.newNote)

            Button("New Notebook…") {
                NotificationCenter.default.post(name: .noteItNewNotebook, object: nil)
            }
            .keyboardShortcut(MenuShortcuts.newNotebook)

            Divider()

            Button("Open Quickly…") { PaletteController.shared.toggle(mode: .everything) }
                .keyboardShortcut(MenuShortcuts.openQuickly)

            Button("Command Palette…") { PaletteController.shared.toggle(mode: .commands) }
                .keyboardShortcut(MenuShortcuts.commandPalette)
        }

        // ⌘F searches all notes; in-note find moves to ⌥⌘F.
        CommandGroup(replacing: .textEditing) {
            Button("Search Notes") {
                NotificationCenter.default.post(name: .noteItFocusSearch, object: nil)
            }
            .keyboardShortcut(MenuShortcuts.searchNotes)

            Divider()

            Menu("Find") {
                Button("Find…") { FindReplaceModel.active()?.open(replace: false) }
                    .keyboardShortcut(MenuShortcuts.find)
                Button("Find and Replace…") { FindReplaceModel.active()?.open(replace: true) }
                    .keyboardShortcut(MenuShortcuts.findAndReplace)
                Button("Find Next") { FindReplaceModel.active()?.findNext() }
                    .keyboardShortcut("g", modifiers: .command)
                Button("Find Previous") { FindReplaceModel.active()?.findPrevious() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Button("Use Selection for Find") { FindReplaceModel.active()?.useSelectionForFind() }
                    .keyboardShortcut("e", modifiers: .command)
            }
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
