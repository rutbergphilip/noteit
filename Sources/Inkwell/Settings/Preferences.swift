import AppKit
import SwiftUI

/// UserDefaults keys shared across modules.
enum PrefKey {
    static let hideDockIcon = "hideDockIcon"
    static let showMenuBarIcon = "showMenuBarIcon"
    static let editorFontSize = "editorFontSize"
    static let defaultNotebookID = "defaultNotebookID"
}

enum PrefDefault {
    static let editorFontSize: Double = 15
    /// Stored in `defaultNotebookID` to mean "no notebook" (as opposed to unset == automatic).
    static let noNotebook = "none"
}

/// Opens the Settings scene and brings it to the front, also in menu-bar-only (`.accessory`) mode.
///
/// SwiftUI views should pass their own `@Environment(\.openSettings)` action. Non-view callers
/// (hotkeys, launch arguments) fall back to the app menu's Settings… item.
@MainActor
enum SettingsOpener {
    static let windowIdentifier = "com_apple_SwiftUI_Settings_window"

    static var settingsWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == windowIdentifier }
    }

    static func open(using openSettings: OpenSettingsAction? = nil) {
        NSApp.unhide(nil)
        NSApp.activate()
        if let openSettings {
            openSettings()
        } else if let item = settingsMenuItem, let menu = item.menu {
            menu.performActionForItem(at: menu.index(of: item))
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        // In menu-bar-only mode the window can open behind other apps; pull it forward once it exists.
        Task { @MainActor in
            for _ in 0..<10 {
                if let window = settingsWindow, window.isVisible {
                    NSApp.activate()
                    window.makeKeyAndOrderFront(nil)
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private static var settingsMenuItem: NSMenuItem? {
        NSApp.mainMenu?.items.first?.submenu?.items.first {
            $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command
        }
    }
}
