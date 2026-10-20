import AppKit
import Combine

/// SwiftUI's standard Edit menu gives Paste and Match Style ⌥⇧⌘V and offers no way to change it, so the
/// item is updated in place, again whenever SwiftUI rebuilds the menu. The editor also handles both keys itself.
/// A user's own ⇧⌘V, as a menu shortcut or a global hotkey, wins: the item then stays on ⌥⇧⌘V.
@MainActor
enum PasteAndMatchStyleShortcut {
    static let shortcut = MenuShortcut("v", [.command, .shift])
    private static let fallbackModifiers: NSEvent.ModifierFlags = [.command, .option, .shift]
    private(set) static var holdsShiftCommandV = true
    private static var observers: [NSObjectProtocol] = []
    private static var subscription: AnyCancellable?
    private static var isScheduled = false

    static func update(overrides: [MenuShortcutCommand: MenuShortcutOverride], globalBindings: [HotkeyAction: KeyCombo]) {
        holdsShiftCommandV = !overrides.values.contains(.shortcut(shortcut)) && !globalBindings.values.contains(where: isShortcut)
    }

    private static func isShortcut(_ combo: KeyCombo) -> Bool {
        guard combo.modifierFlags == shortcut.modifierFlags else { return false }
        let code = Int(combo.keyCode)
        let character = MenuShortcutRules.commandLayerCharacter(keyCode: code) ?? KeyCombo.ansiKeyNames[code]
        return character?.lowercased() == String(shortcut.key.character)
    }

    static func apply(to menu: NSMenu?) {
        guard let menu else { return }
        let modifiers = holdsShiftCommandV ? shortcut.modifierFlags : fallbackModifiers
        let key = String(shortcut.key.character)
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
        if subscription == nil {
            subscription = MenuShortcutStore.shared.$overrides.combineLatest(HotkeyManager.shared.$bindings)
                .sink { overrides, bindings in
                    MainActor.assumeIsolated {
                        update(overrides: overrides, globalBindings: bindings)
                        schedule()
                    }
                }
        }
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
