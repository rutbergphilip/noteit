import AppKit
import SwiftUI

/// The editor's find and replace bar, pinned to the top-right corner of the text.
struct FindReplaceBar: View {
    @ObservedObject var model: FindReplaceModel
    @State private var findFocused = false
    @State private var replaceFocused = false

    private static let width: CGFloat = 440
    private static let rowHeight: CGFloat = 26

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            if model.allowsReplace {
                Button { model.toggleReplace() } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(model.showsReplace ? 90 : 0))
                        .frame(width: 16, height: model.showsReplace ? Self.rowHeight * 2 + 6 : Self.rowHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(FindBarIconButtonStyle())
                .help(model.showsReplace ? "Hide Replace" : "Show Replace")
                .accessibilityLabel(model.showsReplace ? "Hide Replace" : "Show Replace")
            }

            VStack(alignment: .leading, spacing: 6) {
                findRow
                if model.showsReplace && model.allowsReplace {
                    replaceRow
                }
            }
        }
        .padding(.leading, model.allowsReplace ? 4 : 8)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .frame(maxWidth: Self.width)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .strokeBorder(Tokens.Color.hairline, lineWidth: Tokens.Size.hairline)
        )
        .shadow(color: .black.opacity(0.14), radius: 10, y: 3)
        .animation(.easeOut(duration: 0.12), value: model.showsReplace)
    }

    private var findRow: some View {
        HStack(spacing: 4) {
            HStack(spacing: 2) {
                FindBarTextField(
                    text: $model.query,
                    placeholder: "Find",
                    isFocused: $findFocused,
                    focusToken: model.focusRequest.field == .find ? model.focusRequest.token : nil,
                    consumeFocus: model.consumeFocus,
                    noteUndoManager: { model.textView?.undoManager },
                    onSubmit: { shift in shift ? model.findPrevious() : model.findNext() },
                    onTab: { _ in
                        guard model.showsReplace else { return false }
                        model.requestFocus(.replace)
                        return true
                    },
                    onCancel: { model.close() }
                )
                OptionToggle(label: "Aa", help: "Match Case", isOn: $model.options.matchCase)
                OptionToggle(label: "ab", help: "Match Whole Word", isOn: $model.options.wholeWord, underlined: true)
                OptionToggle(label: ".*", help: "Use Regular Expression", isOn: $model.options.regex)
            }
            .padding(.leading, 7)
            .padding(.trailing, 3)
            .frame(height: Self.rowHeight)
            .modifier(FindFieldBackground(isFocused: findFocused, isError: model.isInvalidRegex))

            Text(model.statusText ?? "")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(model.statusIsError ? Tokens.Color.destructive : Tokens.Color.inkSecondary)
                .lineLimit(1)
                .frame(minWidth: 78, alignment: .leading)
                .fixedSize()
                .padding(.leading, 4)
                .accessibilityLabel(model.statusText ?? "No search")

            Group {
                Button { model.findPrevious() } label: { Image(systemName: "chevron.up") }
                    .help("Previous Match (⇧↩)")
                    .accessibilityLabel("Previous Match")
                Button { model.findNext() } label: { Image(systemName: "chevron.down") }
                    .help("Next Match (↩)")
                    .accessibilityLabel("Next Match")
            }
            .buttonStyle(FindBarIconButtonStyle())
            .disabled(model.matchCount == 0)

            Button { model.close() } label: { Image(systemName: "xmark") }
                .buttonStyle(FindBarIconButtonStyle())
                .help("Close (Esc)")
                .accessibilityLabel("Close Find")
        }
    }

    private var replaceRow: some View {
        HStack(spacing: 6) {
            FindBarTextField(
                text: $model.replacement,
                placeholder: "Replace",
                isFocused: $replaceFocused,
                focusToken: model.focusRequest.field == .replace ? model.focusRequest.token : nil,
                consumeFocus: model.consumeFocus,
                noteUndoManager: { model.textView?.undoManager },
                onSubmit: { _ in model.replaceCurrent() },
                onTab: { _ in
                    model.requestFocus(.find)
                    return true
                },
                onCancel: { model.close() }
            )
            .padding(.horizontal, 7)
            .frame(height: Self.rowHeight)
            .modifier(FindFieldBackground(isFocused: replaceFocused, isError: false))

            Button("Replace") { model.replaceCurrent() }
                .keyboardShortcut("1", modifiers: [.command, .shift])
                .help("Replace (⇧⌘1)")
                .disabled(model.currentIndex == nil)
            Button("Replace All") { model.replaceAll() }
                .keyboardShortcut(.return, modifiers: [.command, .option])
                .help("Replace All (⌥⌘↩)")
                .disabled(model.matchCount == 0)
        }
        .controlSize(.small)
    }
}

private struct FindFieldBackground: ViewModifier {
    let isFocused: Bool
    let isError: Bool

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.toolbar, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.85))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.Radius.toolbar, style: .continuous)
                    .strokeBorder(
                        isError ? Tokens.Color.destructive : (isFocused ? Tokens.Color.accent : Tokens.Color.hairline),
                        lineWidth: isFocused || isError ? 1.5 : 1
                    )
            )
    }
}

/// An Aa / ab / .* toggle inside the find field.
private struct OptionToggle: View {
    let label: String
    let help: String
    @Binding var isOn: Bool
    var underlined = false

    var body: some View {
        Button { isOn.toggle() } label: {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: underlined ? .default : .monospaced))
                .underline(underlined)
                .foregroundStyle(isOn ? Tokens.Color.accent : Tokens.Color.inkSecondary)
                .frame(width: 22, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isOn ? Tokens.Color.accent.opacity(0.18) : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(isOn ? Tokens.Color.accent.opacity(0.6) : .clear, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

private struct FindBarIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(isEnabled ? Tokens.Color.ink : Tokens.Color.inkTertiary)
            .frame(minWidth: 22, minHeight: 22)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Tokens.Color.fillQuiet.opacity(configuration.isPressed ? 1 : (isHovering && isEnabled ? 0.6 : 0)))
            )
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
    }
}

/// Borderless text field that reports ↩ / ⇧↩, Tab and Esc, and takes focus on request.
struct FindBarTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    @Binding var isFocused: Bool
    /// A new non-nil token makes the field first responder with its text selected, once per token.
    var focusToken: Int?
    var consumeFocus: (Int) -> Bool
    /// ⌘Z / ⇧⌘Z in the field act on the note, so a replace can be undone without leaving the bar.
    var noteUndoManager: () -> UndoManager?
    var onSubmit: (_ shift: Bool) -> Void
    /// Returns true when the Tab (or ⇧Tab, `backward`) was handled.
    var onTab: (_ backward: Bool) -> Bool
    var onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = FocusReportingTextField()
        field.placeholderString = placeholder
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12)
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.cell?.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel(placeholder)
        field.onFocus = { [weak coordinator = context.coordinator] in coordinator?.setFocused(true) }
        field.noteUndoManager = { [weak coordinator = context.coordinator] in coordinator?.parent.noteUndoManager() }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if let focusToken, consumeFocus(focusToken) {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let window = field.window else { return }
                    if window.firstResponder !== field.currentEditor() { window.makeFirstResponder(field) }
                    field.currentEditor()?.selectAll(nil)
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FindBarTextField

        init(parent: FindBarTextField) { self.parent = parent }

        func setFocused(_ focused: Bool) {
            if parent.isFocused != focused { parent.isFocused = focused }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            fieldEditor(notification)?.allowsUndo = false
            setFocused(true)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            fieldEditor(notification)?.allowsUndo = true
            setFocused(false)
        }

        private func fieldEditor(_ notification: Notification) -> NSTextView? {
            notification.userInfo?["NSFieldEditor"] as? NSTextView
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                parent.onSubmit(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false)
            case #selector(NSResponder.insertTab(_:)):
                return parent.onTab(false)
            case #selector(NSResponder.insertBacktab(_:)):
                return parent.onTab(true)
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
            default:
                return false
            }
            return true
        }
    }
}

/// Reports when it becomes first responder (before any editing begins) and routes undo to the note.
private final class FocusReportingTextField: NSTextField, NSMenuItemValidation {
    var onFocus: (() -> Void)?
    var noteUndoManager: (() -> UndoManager?)?

    @objc func undo(_ sender: Any?) { noteUndoManager?()?.undo() }
    @objc func redo(_ sender: Any?) { noteUndoManager?()?.redo() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let undo = noteUndoManager?() else {
            return item.action != #selector(undo(_:)) && item.action != #selector(redo(_:))
        }
        switch item.action {
        case #selector(undo(_:)):
            item.title = undo.undoMenuItemTitle
            return undo.canUndo
        case #selector(redo(_:)):
            item.title = undo.redoMenuItemTitle
            return undo.canRedo
        default:
            return true
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }
}
