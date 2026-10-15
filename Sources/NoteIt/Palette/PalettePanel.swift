import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

enum PaletteLayout {
    static let width: CGFloat = 600
    static let fieldHeight: CGFloat = 52
    static let rowHeight: CGFloat = 44
    static let maxVisibleRows = 10
    static let listPadding: CGFloat = 6
    static let emptyHeight: CGFloat = 52
    static let cornerRadius: CGFloat = 12
    /// The panel's top edge sits this fraction of the window height below the window's top.
    static let topOffset: CGFloat = 0.18

    static func height(rowCount: Int) -> CGFloat {
        let rows = CGFloat(min(rowCount, maxVisibleRows))
        let list = rowCount == 0 ? emptyHeight : rows * rowHeight + listPadding * 2
        return fieldHeight + 1 + list
    }
}

/// What a key-down in the palette does before AppKit sees it.
enum PaletteKeyRoute: Equatable {
    /// Not a ⌘ shortcut, or one the search field edits text with: dispatch normally.
    case pass
    case toggleEverything
    case toggleCommands
    /// ⌘W / ⌘.: close the palette and swallow the key.
    case close
    /// Any other menu shortcut: close the palette and let the menu run it against the main window.
    case handOff

    private static let editingKeys: Set<String> = ["a", "c", "v", "x", "z"]
    private static let editingKeyCodes: Set<Int> = [
        kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_Delete, kVK_ForwardDelete,
    ]

    /// `characters` is the event's `characters`, which with ⌘ held comes from the layout's ⌘ layer (Latin on
    /// Russian, Greek or "Dvorak – QWERTY ⌘"), the same key the menus match. `charactersIgnoringModifiers`
    /// is the base layer and is only used when ⌥ or ⌃ turn `characters` into something else.
    static func route(keyCode: Int, characters: String?, charactersIgnoringModifiers: String?,
                      modifierFlags: NSEvent.ModifierFlags) -> PaletteKeyRoute {
        route(keyCode: keyCode, characters: characters, charactersIgnoringModifiers: charactersIgnoringModifiers,
              modifierFlags: modifierFlags, openQuickly: MenuShortcuts.openQuickly, commandPalette: MenuShortcuts.commandPalette,
              otherMenuShortcuts: otherMenuShortcuts)
    }

    private static var otherMenuShortcuts: [MenuShortcut] {
        MenuShortcutCommand.allCases.compactMap { command -> MenuShortcut? in
            command == .openQuickly || command == .commandPalette ? nil : MenuShortcuts.current(command)
        }
    }

    /// `openQuickly` and `commandPalette` are the current menu shortcuts; nil when cleared in Settings.
    /// `otherMenuShortcuts` lets shortcuts without ⌘ (⌃ or a function key) hand off like ⌘ ones.
    static func route(keyCode: Int, characters: String?, charactersIgnoringModifiers: String?,
                      modifierFlags: NSEvent.ModifierFlags,
                      openQuickly: MenuShortcut?, commandPalette: MenuShortcut?,
                      otherMenuShortcuts: [MenuShortcut] = []) -> PaletteKeyRoute {
        let flags = modifierFlags.intersection([.command, .shift, .option, .control])
        // ⌃⌘Space (Emoji & Symbols) and other ⌘-Space input shortcuts belong to the field.
        if keyCode == kVK_Space { return .pass }
        let characters = commandLayerKey(characters, charactersIgnoringModifiers, flags: flags)
        if types(openQuickly, keyCode: keyCode, characters: characters, flags: flags) { return .toggleEverything }
        if types(commandPalette, keyCode: keyCode, characters: characters, flags: flags) { return .toggleCommands }
        guard flags.contains(.command) else {
            let isMenuShortcut = otherMenuShortcuts.contains { types($0, keyCode: keyCode, characters: characters, flags: flags) }
            return isMenuShortcut ? .handOff : .pass
        }
        let key = characters?.lowercased() ?? ""
        if flags == [.command], key == "w" || key == "." { return .close }
        if editingKeyCodes.contains(keyCode), !flags.contains(.control) { return .pass }
        if flags == [.command], editingKeys.contains(key) { return .pass }
        if flags == [.command, .shift], key == "z" { return .pass }
        return .handOff
    }

    /// ⇧ turns "1" into "!", so a shifted shortcut is also compared with the key's unshifted ⌘-layer character.
    private static func types(_ shortcut: MenuShortcut?, keyCode: Int, characters: String?, flags: NSEvent.ModifierFlags) -> Bool {
        guard let shortcut else { return false }
        if shortcut.matches(characters: characters, modifierFlags: flags) { return true }
        guard flags.contains(.shift), shortcut.modifiers.contains(.shift) else { return false }
        return shortcut.matches(characters: MenuShortcutRules.commandLayerCharacter(keyCode: keyCode), modifierFlags: flags)
    }

    private static func commandLayerKey(_ characters: String?, _ ignoringModifiers: String?,
                                        flags: NSEvent.ModifierFlags) -> String? {
        let usable = characters.flatMap { $0.isEmpty ? nil : $0 }
        guard let usable, flags.isDisjoint(with: [.option, .control]),
              !usable.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return ignoringModifiers
        }
        return usable
    }
}

/// Open Quickly (⌘O) and the command palette (⇧⌘P): a panel over the main window.
@MainActor
final class PaletteController: NSObject, NSWindowDelegate {
    static let shared = PaletteController()

    let model = PaletteModel()
    /// The panel on screen, or the one shown last.
    private(set) var panel: PalettePanel?
    private var inAppPanel: PalettePanel?
    /// Non-activating twin used by the global hotkeys while another app is active.
    var globalPanel: PalettePanel?
    /// Whether the current presentation started while another app was active.
    private(set) var presentedOverOtherApp = false
    private var keyMonitor: Any?
    private var itemsObserver: AnyCancellable?
    private var topEdge: CGFloat = 0
    private var shownAt = Date.distantPast
    private var presentationGeneration = 0

    var isVisible: Bool { panel?.isVisible ?? false }

    /// ⌘O closes an open palette; ⇧⌘P switches it to commands, or closes it when it already shows them.
    func toggle(mode: PaletteMode) {
        guard isVisible else {
            show(mode: mode)
            return
        }
        if mode == .commands, model.mode != .commands {
            model.reset(query: Self.initialQuery(for: mode))
        } else {
            dismiss()
        }
    }

    func show(mode: PaletteMode) {
        WindowRouter.showMainWindow()
        present(mode: mode, attempt: 0)
    }

    /// Waits briefly for a main window that is being reopened, so the panel can sit over it.
    private func present(mode: PaletteMode, attempt: Int) {
        if WindowRouter.mainWindow?.isVisible != true, attempt < 20 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                MainActor.assumeIsolated { self.present(mode: mode, attempt: attempt + 1) }
            }
            return
        }
        let panel = inAppPanel ?? makePanel(nonactivating: false)
        inAppPanel = panel
        let anchor = WindowRouter.mainWindow.flatMap { $0.isVisible ? $0.frame : nil }
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        present(panel, mode: mode, anchor: anchor, overOtherApp: false)
    }

    /// Shows `panel` with a fresh query, its top edge `PaletteLayout.topOffset` down `anchor`.
    func present(_ panel: PalettePanel, mode: PaletteMode, anchor: NSRect, overOtherApp: Bool) {
        let hider = TransientSurfaceHider.shared
        if !overOtherApp { hider.surfaceOpenedNoteIt() }
        if let current = self.panel, current !== panel, current.isVisible { dismiss(animated: false) }
        self.panel = panel
        presentedOverOtherApp = overOtherApp
        model.reset(query: Self.initialQuery(for: mode))

        let frame = PaletteLayout.frame(in: anchor, height: PaletteLayout.height(rowCount: model.items.count))
        topEdge = frame.maxY
        panel.setFrame(frame, display: false)

        presentationGeneration += 1
        shownAt = Date()
        panel.alphaValue = 0
        if overOtherApp {
            hider.surfaceWillAppear(.palette, appIsHidden: NSApp.isHidden)
            if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        }
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            panel.animator().alphaValue = 1
        }
        installKeyMonitor()
    }

    func dismiss(animated: Bool = true) {
        guard let panel, panel.isVisible else {
            TransientSurfaceHider.shared.surfaceDidClose(.palette)
            return
        }
        removeKeyMonitor()
        model.stopObserving()
        presentationGeneration += 1
        let generation = presentationGeneration
        guard animated else {
            panel.orderOut(nil)
            panel.alphaValue = 1
            TransientSurfaceHider.shared.surfaceDidClose(.palette)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                guard generation == self.presentationGeneration else { return }
                panel.orderOut(nil)
                panel.alphaValue = 1
                TransientSurfaceHider.shared.surfaceDidClose(.palette)
            }
        })
    }

    static func initialQuery(for mode: PaletteMode) -> String {
        mode == .commands ? ">" : ""
    }

    /// A non-activating panel takes key without activating NoteIt and shows on every Space,
    /// like Quick Capture.
    func makePanel(nonactivating: Bool) -> PalettePanel {
        let size = NSSize(width: PaletteLayout.width, height: PaletteLayout.height(rowCount: 0))
        let panel = PalettePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: nonactivating ? [.borderless, .nonactivatingPanel, .fullSizeContentView] : [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = nonactivating ? [.canJoinAllSpaces, .fullScreenAuxiliary, .transient] : [.fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.title = "Open Quickly"
        panel.delegate = self

        let root = PaletteView(model: model, onCancel: { [weak self] in self?.dismiss() })
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        guard itemsObserver == nil else { return panel }
        itemsObserver = model.$items
            .map(\.count)
            .removeDuplicates()
            .sink { [weak self] count in
                MainActor.assumeIsolated { self?.resize(rowCount: count) }
            }
        return panel
    }

    /// Keeps the top edge in place while the list grows or shrinks.
    private func resize(rowCount: Int) {
        guard let panel, panel.isVisible else { return }
        let height = PaletteLayout.height(rowCount: rowCount)
        guard abs(panel.frame.height - height) > 0.5 else { return }
        let frame = NSRect(x: panel.frame.minX, y: topEdge - height, width: PaletteLayout.width, height: height)
        panel.setFrame(frame, display: true)
        DispatchQueue.main.async { panel.invalidateShadow() }
    }

    /// Runs before the main menu sees the key, so a menu shortcut never acts on the palette itself:
    /// sheets from Print or Export would attach to the panel and vanish with it.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let route = PaletteKeyRoute.route(keyCode: Int(event.keyCode), characters: event.characters,
                                              charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                                              modifierFlags: event.modifierFlags)
            let windowNumber = event.windowNumber
            let swallow = MainActor.assumeIsolated { () -> Bool in
                let controller = PaletteController.shared
                guard let panel = controller.panel, panel.isVisible, panel.windowNumber == windowNumber else { return false }
                switch route {
                case .pass:
                    return false
                case .toggleEverything:
                    controller.toggle(mode: .everything)
                    return true
                case .toggleCommands:
                    controller.toggle(mode: .commands)
                    return true
                case .close:
                    controller.dismiss()
                    return true
                case .handOff:
                    if PaletteHandOff.decide(appIsActive: NSApp.isActive) == .closeOnly {
                        controller.dismiss()
                        return true
                    }
                    controller.handOffToMainWindow()
                    return false
                }
            }
            return swallow ? nil : event
        }
    }

    /// Closes the palette at once and makes the main window key, ready for a menu key equivalent.
    func handOffToMainWindow() {
        dismiss(animated: false)
        WindowRouter.mainWindow?.makeKeyAndOrderFront(nil)
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    nonisolated func windowDidResignKey(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self, let panel = self.panel, panel.isVisible, !panel.isKeyWindow else { return }
            // A main window that was just reopened can take key right after the panel appeared.
            if Date().timeIntervalSince(self.shownAt) < 0.3, WindowRouter.mainWindow?.isKeyWindow == true {
                panel.makeKey()
            } else {
                self.dismiss()
            }
        }
    }
}
