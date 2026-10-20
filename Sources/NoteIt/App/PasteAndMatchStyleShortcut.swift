import AppKit

/// SwiftUI's standard Edit menu gives Paste and Match Style ⌥⇧⌘V and offers no way to change it, so the
/// item is updated in place, again whenever SwiftUI rebuilds the menu. The editor also handles both keys itself.
@MainActor
enum PasteAndMatchStyleShortcut {
    static let key = "v"
    static let modifiers: NSEvent.ModifierFlags = [.command, .shift]
    private static var observers: [NSObjectProtocol] = []
    private static var isScheduled = false

    static func apply(to menu: NSMenu?) {
        guard let menu else { return }
        for item in menu.items {
            if item.action == #selector(NSTextView.pasteAsPlainText(_:)) || item.title == "Paste and Match Style",
               item.keyEquivalent != key || item.keyEquivalentModifierMask != modifiers {
                item.keyEquivalent = key
                item.keyEquivalentModifierMask = modifiers
            }
            apply(to: item.submenu)
        }
    }

    static func install() {
        apply(to: NSApp.mainMenu)
        guard observers.isEmpty else { return }
        for name in [NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
                Task { @MainActor in schedule() }
            })
        }
    }

    private static func schedule() {
        guard !isScheduled else { return }
        isScheduled = true
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                isScheduled = false
                apply(to: NSApp.mainMenu)
            }
        }
    }
}
