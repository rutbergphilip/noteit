import AppKit
import SwiftUI

/// NSSearchField that forwards ↑/↓/↩/Esc so a results list can be driven from the keyboard.
struct PanelSearchField: NSViewRepresentable {
    enum Direction { case up, down }

    @Binding var text: String
    var placeholder = "Search notes"
    /// Changing this value makes the field first responder.
    var focusToken: Int
    var onMove: (Direction) -> Void
    var onSubmit: () -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.font = .systemFont(ofSize: 13)
        field.controlSize = .large
        field.focusRingType = .default
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        (field.cell as? NSSearchFieldCell)?.cancelButtonCell?.isEnabled = true
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async {
                MainActor.assumeIsolated { _ = field.window?.makeFirstResponder(field) }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: PanelSearchField
        var lastFocusToken: Int?

        init(parent: PanelSearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onMove(.up)
            case #selector(NSResponder.moveDown(_:)):
                parent.onMove(.down)
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
            default:
                return false
            }
            return true
        }
    }
}
