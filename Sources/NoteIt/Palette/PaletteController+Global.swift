import AppKit

/// What the Open Quickly and Command Palette global hotkeys do, given the palette's state.
enum PaletteToggle: Equatable {
    case show(PaletteMode)
    case switchTo(PaletteMode)
    case close

    static func decide(isVisible: Bool, currentMode: PaletteMode, requested: PaletteMode) -> PaletteToggle {
        guard isVisible else { return .show(requested) }
        return currentMode == requested ? .close : .switchTo(requested)
    }
}

/// What a menu shortcut does in the palette. Over another app, NoteIt's main window must not come
/// forward, so the palette just closes.
enum PaletteHandOff: Equatable {
    case toMainWindow
    case closeOnly

    static func decide(appIsActive: Bool) -> PaletteHandOff {
        appIsActive ? .toMainWindow : .closeOnly
    }
}

/// Whether closing the global palette should hide NoteIt again. Showing a panel un-hides the app,
/// so a palette opened while NoteIt was hidden hides it again unless a row was chosen, NoteIt
/// became the active app, or another NoteIt window (such as Quick Capture) took over.
struct PaletteHiddenApp {
    struct Environment {
        var appIsActive: @MainActor () -> Bool
        var otherWindowIsKey: @MainActor () -> Bool
        var quickCaptureIsVisible: @MainActor () -> Bool
        var hide: @MainActor () -> Void

        static var live: Environment {
            Environment(
                appIsActive: { NSApp.isActive },
                otherWindowIsKey: { NSApp.keyWindow.map { !($0 is PalettePanel) } ?? false },
                quickCaptureIsVisible: { QuickCaptureController.shared.isVisible || QuickCaptureVisibility.shared.isCapturing },
                hide: { NSApp.hide(nil) }
            )
        }
    }

    /// NoteIt was hidden (⌘H) when the global hotkey showed the palette.
    var wasHidden = false
    /// Set while the palette closes because a row was chosen.
    var closingForChosenItem = false

    static func shouldRehide(wasHidden: Bool, choseItem: Bool, appIsActive: Bool,
                             otherWindowIsKey: Bool = false, quickCaptureIsVisible: Bool = false) -> Bool {
        wasHidden && !choseItem && !appIsActive && !otherWindowIsKey && !quickCaptureIsVisible
    }

    /// Called once the palette is off screen. Hiding an inactive app leaves the frontmost app and its focus alone.
    @MainActor mutating func paletteClosed(_ environment: Environment) {
        let wasHidden = self.wasHidden
        self.wasHidden = false
        guard wasHidden, !closingForChosenItem else { return }
        if Self.shouldRehide(wasHidden: wasHidden, choseItem: closingForChosenItem,
                             appIsActive: environment.appIsActive(),
                             otherWindowIsKey: environment.otherWindowIsKey(),
                             quickCaptureIsVisible: environment.quickCaptureIsVisible()) {
            environment.hide()
        }
    }
}

extension PaletteLayout {
    /// The panel frame for a list of `height`, centred on `anchor` with its top `topOffset` down from the top.
    static func frame(in anchor: NSRect, height: CGFloat) -> NSRect {
        let top = anchor.maxY - anchor.height * topOffset
        return NSRect(x: anchor.midX - width / 2, y: top - height, width: width, height: height)
    }

    /// The visible frame of the screen containing `point`, else of the first screen.
    static func visibleFrame(containing point: NSPoint, screens: [(frame: NSRect, visibleFrame: NSRect)]) -> NSRect? {
        (screens.first { NSMouseInRect(point, $0.frame, false) } ?? screens.first)?.visibleFrame
    }
}

extension PaletteController {
    /// Global hotkey entry point. With NoteIt active it behaves like the menu items; otherwise the palette
    /// opens over the current app, on the screen with the pointer, without activating NoteIt.
    func hotkeyToggle(mode: PaletteMode) {
        switch PaletteToggle.decide(isVisible: isVisible, currentMode: model.mode, requested: mode) {
        case .show(let mode):
            if NSApp.isActive {
                show(mode: mode)
            } else {
                showOverCurrentApp(mode: mode)
            }
        case .switchTo(let mode):
            model.reset(query: Self.initialQuery(for: mode))
        case .close:
            dismiss()
        }
    }

    func showOverCurrentApp(mode: PaletteMode) {
        // Still set if the previous palette is fading out and hasn't hidden NoteIt yet.
        let wasHidden = NSApp.isHidden || hiddenApp.wasHidden
        let panel = globalPanel ?? makePanel(nonactivating: true)
        globalPanel = panel
        let screens = NSScreen.screens.map { (frame: $0.frame, visibleFrame: $0.visibleFrame) }
        let anchor = PaletteLayout.visibleFrame(containing: NSEvent.mouseLocation, screens: screens)
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        present(panel, mode: mode, anchor: anchor, overOtherApp: true)
        hiddenApp.wasHidden = wasHidden
    }

    /// Closes the palette for a chosen row; NoteIt then comes forward, so it stays un-hidden.
    func dismissForChosenItem() {
        hiddenApp.closingForChosenItem = true
        defer { hiddenApp.closingForChosenItem = false }
        dismiss(animated: false)
    }

    func rehideAppIfNeeded(_ environment: PaletteHiddenApp.Environment = .live) {
        hiddenApp.paletteClosed(environment)
    }

    /// Runs `work` once NoteIt is active with its main window key, or after about two seconds regardless.
    static func whenMainWindowIsKey(attempt: Int = 0, _ work: @escaping @MainActor () -> Void) {
        let ready = NSApp.isActive && WindowRouter.mainWindow?.isKeyWindow == true
        guard ready || attempt >= 40 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                MainActor.assumeIsolated { whenMainWindowIsKey(attempt: attempt + 1, work) }
            }
            return
        }
        work()
    }
}
