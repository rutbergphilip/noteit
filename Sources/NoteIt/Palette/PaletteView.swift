import AppKit
import SwiftUI

struct PaletteView: View {
    @ObservedObject var model: PaletteModel
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(.secondary)
                PaletteSearchField(
                    text: $model.query,
                    placeholder: model.mode == .commands ? "Run a command" : "Search notes, notebooks and commands",
                    focusToken: model.focusToken,
                    onMove: { model.moveSelection($0) },
                    onSubmit: { model.activateSelected() },
                    onCancel: onCancel
                )
            }
            .padding(.horizontal, 16)
            .frame(height: PaletteLayout.fieldHeight)

            Divider()

            if model.items.isEmpty {
                Text("No results")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: PaletteLayout.emptyHeight)
            } else {
                results
            }
        }
        .frame(width: PaletteLayout.width, height: PaletteLayout.height(rowCount: model.items.count), alignment: .top)
        .background(VisualEffectBackground(material: .popover))
        .clipShape(RoundedRectangle(cornerRadius: PaletteLayout.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PaletteLayout.cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: Tokens.Size.hairline)
        )
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        PaletteRow(item: item, isSelected: index == model.selectedIndex, tint: tint(for: item))
                            .id(item.id)
                            .onContinuousHover { phase in
                                if case .active = phase { model.hover(index, at: NSEvent.mouseLocation) }
                            }
                            .onTapGesture { model.activate(item) }
                    }
                }
                .padding(PaletteLayout.listPadding)
            }
            .scrollIndicators(.automatic)
            .onChange(of: model.selectedIndex) { _, index in
                guard model.items.indices.contains(index) else { return }
                proxy.scrollTo(model.items[index].id)
            }
            .onChange(of: model.items) { _, items in
                let index = model.selectedIndex
                guard items.indices.contains(index) else { return }
                proxy.scrollTo(items[index].id, anchor: index == 0 ? .top : nil)
            }
        }
    }

    private func tint(for item: PaletteItem) -> Color? {
        guard case .notebook(let id) = item.kind, let hex = model.notebookColorHex(id) else { return nil }
        return Color(hex: hex)
    }
}

private struct PaletteRow: View {
    let item: PaletteItem
    let isSelected: Bool
    var tint: Color?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol)
                .font(.system(size: 14))
                .foregroundStyle(tint ?? (isSelected ? Color.accentColor : Color.secondary))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(PaletteHighlight.title(item.title, matched: item.matchedIndices))
                    .font(.system(size: 13))
                    .lineLimit(1)
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let shortcut = item.shortcut {
                Text(shortcut)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: PaletteLayout.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

enum PaletteHighlight {
    /// The title with the characters at `matched` (Character offsets) bold and in the accent colour.
    static func title(_ title: String, matched: [Int]) -> AttributedString {
        let marked = Set(matched)
        var result = AttributedString()
        var run = ""
        var runIsMatch = false
        func flush() {
            guard !run.isEmpty else { return }
            var piece = AttributedString(run)
            if runIsMatch {
                piece.inlinePresentationIntent = .stronglyEmphasized
                piece.foregroundColor = .accentColor
            }
            result.append(piece)
            run = ""
        }
        for (offset, character) in title.enumerated() {
            let isMatch = marked.contains(offset)
            if isMatch != runIsMatch {
                flush()
                runIsMatch = isMatch
            }
            run.append(character)
        }
        flush()
        return result
    }
}

/// Borderless text field that leaves ↑/↓ (and ⌃P/⌃N), ↩ and Esc to the palette.
private struct PaletteSearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    /// Changing this value focuses the field with the caret at the end.
    var focusToken: Int
    var onMove: (Int) -> Void
    var onSubmit: () -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 20)
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Search")
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if field.placeholderString != placeholder { field.placeholderString = placeholder }
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let window = field.window else { return }
                    if field.currentEditor() == nil { window.makeFirstResponder(field) }
                    let end = (field.stringValue as NSString).length
                    field.currentEditor()?.selectedRange = NSRange(location: end, length: 0)
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PaletteSearchField
        var lastFocusToken: Int?

        init(parent: PaletteSearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)):
                parent.onMove(1)
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
