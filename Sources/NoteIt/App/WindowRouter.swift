import AppKit
import SwiftUI

/// Brings the main window forward from anywhere (menu bar, global hotkeys, commands).
@MainActor
enum WindowRouter {
    static let mainWindowID = "main"

    /// Captured from a SwiftUI environment so windows can be reopened after being closed.
    static var openWindow: OpenWindowAction?

    static var mainWindow: NSWindow? {
        NSApp.windows.first { window in
            guard let id = window.identifier?.rawValue else { return false }
            return id == mainWindowID || id.hasPrefix("\(mainWindowID)-")
        }
    }

    static func showMainWindow() {
        if NSApp.isHidden { NSApp.unhide(nil) }
        NSApp.activate()
        if let window = mainWindow {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else if let openWindow {
            openWindow(id: mainWindowID)
        }
    }

    /// Hides NoteIt (returning focus to the previous app) if the main window is frontmost, otherwise shows it.
    static func toggleMainWindow() {
        if let window = mainWindow, window.isKeyWindow, window.isVisible, NSApp.isActive {
            NSApp.hide(nil)
        } else {
            showMainWindow()
        }
    }

    /// Focuses the toolbar search field of the main window.
    static func focusSearch() {
        showMainWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            MainActor.assumeIsolated {
                guard let window = mainWindow,
                      let root = window.contentView?.superview,
                      let field = findSearchField(in: root) else { return }
                window.makeFirstResponder(field)
            }
        }
    }

    /// Makes the note editor (the main window's editable NSTextView) first responder.
    static func focusEditor() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            MainActor.assumeIsolated {
                guard let window = mainWindow, let root = window.contentView else { return }
                let candidates = textViews(in: root).filter { $0.isEditable && !$0.isFieldEditor }
                guard let editor = candidates.max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height })
                else { return }
                window.makeFirstResponder(editor)
            }
        }
    }

    private static func textViews(in view: NSView) -> [NSTextView] {
        var result: [NSTextView] = []
        if let textView = view as? NSTextView { result.append(textView) }
        for sub in view.subviews { result += textViews(in: sub) }
        return result
    }

    private static func findSearchField(in view: NSView) -> NSSearchField? {
        if let field = view as? NSSearchField { return field }
        for sub in view.subviews {
            if let found = findSearchField(in: sub) { return found }
        }
        return nil
    }
}

/// Stores the SwiftUI `openWindow` action for use by `WindowRouter`.
struct CaptureOpenWindow: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            WindowRouter.openWindow = openWindow
        }
    }
}

extension View {
    func capturesOpenWindow() -> some View { modifier(CaptureOpenWindow()) }
}
