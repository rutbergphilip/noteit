import AppKit
import SwiftUI

/// UserDefaults keys shared across modules.
enum PrefKey {
    static let hideDockIcon = "hideDockIcon"
    static let showMenuBarIcon = "showMenuBarIcon"
    static let editorFontSize = "editorFontSize"
    static let defaultNotebookID = "defaultNotebookID"
    /// Mirror of the login item state, so a future bundle-id change can re-register it.
    static let launchAtLogin = "launchAtLogin"
    static let inlineCodeColor = "inlineCodeColor"
    static let inlineCodeFont = "inlineCodeFont"
    static let codeBlockTheme = "codeBlockTheme"
    static let syntaxHighlighting = "syntaxHighlighting"
    static let captureIncludesBrowserLinks = "captureIncludesBrowserLinks"
    /// The "Daily Notes" notebook's UUID string (foundations Task 4.6; linking owns it).
    static let dailyNotesNotebookID = "dailyNotesNotebookID"
    /// A `DailyTitleFormat` raw value for new daily notes; unset means `iso`.
    static let dailyNoteTitleFormat = "dailyNoteTitleFormat"
    /// `ask`, `always` or `never`: what happens to links showing a note's old title after a rename.
    static let linkRenameUpdates = "linkRenameUpdates"
    /// `source` (the linking note's notebook) or `default` (the notebook for new notes).
    static let linkNewNoteNotebook = "linkNewNoteNotebook"
    /// The daily note template's UUID string; empty for none.
    static let dailyNoteTemplateID = "dailyNoteTemplateID"
    static let showTodayInSidebar = "showTodayInSidebar"
    /// The Templates notebook's UUID string; empty means found by name or created on first use.
    static let templatesNotebookID = "templatesNotebookID"
    static let inspectorVisible = "inspectorVisible"
    /// `links` or `outline`.
    static let inspectorTab = "inspectorTab"
    static let unlinkedMentionsExpanded = "unlinkedMentionsExpanded"
    /// Settings › Integrations › Links: `noteit://new` and `append` links run without asking. Off by default.
    static let urlSchemeChangesWithoutAsking = "urlSchemeChangesWithoutAsking"
    /// Settings › Integrations › Local API. Off by default.
    static let localAPIEnabled = "localAPIEnabled"
    /// 0 means automatic (47600–47609).
    static let localAPIPort = "localAPIPort"
    /// `[client id: Date]`, written at most once a minute per client.
    static let localAPIClientLastUsed = "localAPIClientLastUsed"
    /// Settings › Integrations › Spotlight. On by default.
    static let spotlightEnabled = "spotlightEnabled"
    /// Adds the note text to Spotlight items. On by default.
    static let spotlightIncludesText = "spotlightIncludesText"
    /// The index version the Spotlight items were last built with; a different version rebuilds them.
    static let spotlightIndexVersion = "spotlightIndexVersion"
    /// Set before a change is handed to Spotlight and cleared once Spotlight has taken every change; still set at
    /// launch, it rebuilds the items (a change may have been lost to a crash or a failed Core Spotlight call).
    static let spotlightIndexDirty = "spotlightIndexDirty"
    /// Settings › General › Reminders. On by default.
    static let remindersEnabled = "remindersEnabled"
    /// Minutes after midnight for a reminder given only a date.
    static let reminderDefaultTime = "reminderDefaultTime"
    /// When reminders were last checked; reminders due between then and launch are delivered once.
    static let remindersLastCheck = "remindersLastCheck"
    /// Set once the reminder popover has offered Open at Login, so it's only offered the first time.
    static let reminderLoginOffered = "reminderLoginOffered"
    /// A `SearchSortOrder` raw value.
    static let searchSortOrder = "searchSortOrder"
    static let tasksShowCompleted = "tasksShowCompleted"
    /// UUID strings of the notebooks expanded in the sidebar.
    static let expandedNotebookIDs = "expandedNotebookIDs"
}

enum PrefDefault {
    static let editorFontSize: Double = 15
    /// Stored in `defaultNotebookID` to mean "no notebook" (as opposed to unset == automatic).
    static let noNotebook = "none"
    static let linkRenameUpdates = "ask"
    static let linkNewNoteNotebook = "source"
    static let showTodayInSidebar = true
    static let inspectorTab = "links"
    static let remindersEnabled = true
    static let reminderDefaultTime = 540
    static let searchSortOrder = SearchSortOrder.bestMatch.rawValue
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
