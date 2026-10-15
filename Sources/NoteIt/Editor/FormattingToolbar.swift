import AppKit
import SwiftUI

/// Compact formatting bar shown under the editor header. Groups collapse into an overflow menu
/// as the editor gets narrower.
struct FormattingToolbar: View {
    @ObservedObject var controller: EditorController

    private enum Group: Int, CaseIterable {
        case style, text, color, lists, layout, insert, size
    }

    /// Lowest priority first: these move into the overflow menu first.
    private static let collapseOrder: [Group] = [.size, .layout, .insert, .color, .lists]

    /// Ideal width of the bar with the first n groups of `collapseOrder` hidden, indexed by n.
    @State private var barWidths: [Int: CGFloat] = [:]
    @State private var availableWidth: CGFloat = 0
    /// Drives the measuring copies, so selection changes don't re-render them.
    @StateObject private var sizingController = EditorController()

    /// Picks the fullest bar that fits from widths measured once, rather than with `ViewThatFits`, which
    /// re-measures every variant on each width change and made sidebar animations stutter.
    private var hiddenCount: Int {
        let count = Self.collapseOrder.count
        guard barWidths.count == count + 1 else { return 0 }
        return (0...count).first { barWidths[$0]! <= availableWidth + 0.5 } ?? count
    }

    var body: some View {
        bar(hidden: Array(Self.collapseOrder.prefix(hiddenCount)), controller: controller)
            .frame(minWidth: 0, maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
            .background(measuredBars)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
    }

    /// Every variant at its ideal size, hidden. The fixed zero-size frame keeps them out of the editor's
    /// layout, so resizing the editor doesn't measure them again.
    private var measuredBars: some View {
        ZStack {
            ForEach(0...Self.collapseOrder.count, id: \.self) { n in
                bar(hidden: Array(Self.collapseOrder.prefix(n)), controller: sizingController)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { barWidths[n] = $0 }
            }
        }
        .frame(width: 0, height: 0)
        .hidden()
        .accessibilityHidden(true)
    }

    private func bar(hidden: [Group], controller: EditorController) -> some View {
        HStack(spacing: 2) {
            ForEach(Group.allCases.filter { !hidden.contains($0) }, id: \.self) { group in
                if group != .style { ToolbarSeparator() }
                groupView(group, controller: controller)
            }
            if !hidden.isEmpty {
                ToolbarSeparator()
                OverflowMenu(controller: controller, hidden: Set(hidden.map(\.rawValue)))
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private func groupView(_ group: Group, controller: EditorController) -> some View {
        let s = controller.state
        switch group {
        case .style:
            ParagraphStyleMenu(controller: controller)
        case .text:
            button(.bold, active: s.bold, in: controller)
            button(.italic, active: s.italic, in: controller)
            button(.underline, active: s.underline, in: controller)
            button(.strikethrough, active: s.strikethrough, in: controller)
            button(.inlineCode, active: s.inlineCode, in: controller)
        case .color:
            TextColorButton(controller: controller)
            HighlightButton(controller: controller)
        case .lists:
            button(.list(.bullet), active: s.list == .bullet, in: controller)
            button(.list(.numbered), active: s.list == .numbered, in: controller)
            button(.list(.checklist), active: s.list == .checklist, in: controller)
        case .layout:
            button(.outdent, in: controller)
            button(.indent, in: controller)
            AlignmentMenu(controller: controller)
        case .insert:
            button(.link, active: s.link, in: controller)
            TableButton(controller: controller)
            button(.image, in: controller)
            button(.divider, in: controller)
        case .size:
            button(.fontSmaller, in: controller)
            button(.fontBigger, in: controller)
            button(.clearFormatting, in: controller)
        }
    }

    private func button(_ command: FormatCommand, active: Bool = false, in controller: EditorController) -> some View {
        ToolbarIconButton(symbol: command.symbol, help: command.helpText, active: active) {
            controller.perform(command)
        }
    }
}

// MARK: - Building blocks

struct ToolbarSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.1))
            .frame(width: 1, height: 16)
            .padding(.horizontal, 4)
    }
}

/// Square icon button with hover and active states.
struct ToolbarIconButton: View {
    let symbol: String
    let help: String
    var active = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .frame(width: 26, height: 24)
                .foregroundStyle(active ? Color.accentColor : Color.primary.opacity(0.78))
                .background(ToolbarHoverBackground(active: active, hovering: hovering))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

struct ToolbarHoverBackground: View {
    var active: Bool
    var hovering: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: Tokens.Radius.toolbar, style: .continuous)
            .fill(active || hovering ? Color.primary.opacity(0.08) : Color.clear)
    }
}

/// Generic hover-styled label used for buttons that open popovers.
struct ToolbarPopoverButton<Label: View, Content: View>: View {
    let help: String
    var active = false
    @ViewBuilder let label: () -> Label
    @ViewBuilder let content: (_ dismiss: @escaping () -> Void) -> Content
    @State private var hovering = false
    @State private var presented = false

    var body: some View {
        Button { presented.toggle() } label: {
            label()
                .frame(height: 24)
                .padding(.horizontal, 3)
                .background(ToolbarHoverBackground(active: active || presented, hovering: hovering))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
        .help(help)
        .popover(isPresented: $presented, arrowEdge: .bottom) {
            content { presented = false }
        }
    }
}

// MARK: - Paragraph style

struct ParagraphStyleMenu: View {
    @ObservedObject var controller: EditorController
    @State private var hovering = false

    private var current: BlockKind {
        let b = controller.state.block
        return BlockKind.menuCases.contains(b) ? b : .body
    }

    var body: some View {
        Menu {
            ForEach(BlockKind.menuCases) { kind in
                let cmd = FormatCommand.block(kind)
                Button {
                    controller.perform(cmd)
                } label: {
                    if current == kind && controller.state.list == nil {
                        Label(kind.displayName, systemImage: "checkmark")
                    } else {
                        Text(kind.displayName)
                    }
                }
                .modifier(ShortcutModifier(command: cmd))
            }
        } label: {
            HStack(spacing: 4) {
                Text(controller.state.list != nil ? "List" : current.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .frame(minWidth: 72, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(ToolbarHoverBackground(active: false, hovering: hovering))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .focusable(false)
        .onHover { hovering = $0 }
        .help("Paragraph Style (⌥⌘1 Title, ⌥⌘2 Heading, ⌥⌘3 Subheading, ⌥⌘0 Body, ⌥⌘4 Monospaced, ⌥⌘5 Quote)")
    }
}

/// Shows the shortcut next to menu items (display only; the text view handles the keys).
struct ShortcutModifier: ViewModifier {
    let command: FormatCommand

    func body(content: Content) -> some View {
        if let s = command.shortcut, s.displayKey == nil, let ch = s.key.first {
            content.keyboardShortcut(KeyEquivalent(ch), modifiers: eventModifiers(s.modifiers))
        } else {
            content
        }
    }

    private func eventModifiers(_ flags: NSEvent.ModifierFlags) -> EventModifiers {
        var m: EventModifiers = []
        if flags.contains(.command) { m.insert(.command) }
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.control) { m.insert(.control) }
        return m
    }
}

// MARK: - Alignment

struct AlignmentMenu: View {
    @ObservedObject var controller: EditorController
    @State private var hovering = false

    private static let options: [NSTextAlignment] = [.left, .center, .right, .justified]

    var body: some View {
        let current = controller.state.alignment == .natural ? NSTextAlignment.left : controller.state.alignment
        Menu {
            ForEach(Self.options, id: \.rawValue) { a in
                let cmd = FormatCommand.align(a)
                Button {
                    controller.perform(cmd)
                } label: {
                    Label(cmd.title + (cmd.shortcut.map { "  \($0.display)" } ?? ""), systemImage: cmd.symbol)
                }
            }
        } label: {
            Image(systemName: FormatCommand.align(current).symbol)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.78))
                .frame(width: 26, height: 24)
                .background(ToolbarHoverBackground(active: false, hovering: hovering))
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .focusable(false)
        .onHover { hovering = $0 }
        .help("Alignment (⇧⌘{ ⇧⌘| ⇧⌘})")
    }
}

// MARK: - Colors

struct TextColorButton: View {
    @ObservedObject var controller: EditorController

    var body: some View {
        let current = controller.state.textColor
        ToolbarPopoverButton(help: "Text Color", active: false) {
            VStack(spacing: 1) {
                Text("A")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.8))
                RoundedRectangle(cornerRadius: 1)
                    .fill(current.map { Color(nsColor: $0) } ?? Color.primary.opacity(0.75))
                    .frame(width: 14, height: 3)
            }
            .frame(width: 20)
        } content: { dismiss in
            SwatchGrid(
                title: "Text Color",
                swatches: EditorStyle.textColors,
                selected: current,
                noneTitle: "Default",
                onSelect: { color in
                    controller.perform(.textColor(color))
                    dismiss()
                },
                onCustom: {
                    dismiss()
                    controller.perform(.customColor)
                }
            )
        }
    }
}

struct HighlightButton: View {
    @ObservedObject var controller: EditorController

    var body: some View {
        let current = controller.state.highlight
        ToolbarPopoverButton(help: "Highlight (⇧⌘H)", active: current != nil) {
            Image(systemName: "highlighter")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(current.map { Color(nsColor: $0) } ?? Color.primary.opacity(0.78))
                .frame(width: 20)
        } content: { dismiss in
            SwatchGrid(
                title: "Highlight",
                swatches: EditorStyle.highlightColors,
                selected: current,
                noneTitle: "None",
                onSelect: { color in
                    controller.perform(.highlight(color))
                    dismiss()
                },
                onCustom: nil
            )
        }
    }
}

struct SwatchGrid: View {
    let title: String
    let swatches: [EditorStyle.Swatch]
    let selected: NSColor?
    let noneTitle: String
    let onSelect: (NSColor?) -> Void
    let onCustom: (() -> Void)?

    private let columns = Array(repeating: GridItem(.fixed(24), spacing: 8), count: 5)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: columns, spacing: 8) {
                SwatchCircle(color: nil, isSelected: selected == nil, help: noneTitle) { onSelect(nil) }
                ForEach(swatches) { swatch in
                    SwatchCircle(color: swatch.color, isSelected: matches(swatch.color), help: swatch.name) {
                        onSelect(swatch.color)
                    }
                }
            }
            if let onCustom {
                Divider()
                Button(action: onCustom) {
                    Label("Custom Color…", systemImage: "eyedropper")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        }
        .padding(12)
    }

    private func matches(_ color: NSColor) -> Bool {
        guard let selected, let a = selected.usingColorSpace(.sRGB), let b = color.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.01 && abs(a.greenComponent - b.greenComponent) < 0.01
            && abs(a.blueComponent - b.blueComponent) < 0.01
    }
}

struct SwatchCircle: View {
    let color: NSColor?
    let isSelected: Bool
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if let color {
                    Circle().fill(Color(nsColor: color))
                } else {
                    Circle().strokeBorder(Color.primary.opacity(0.35), lineWidth: 1)
                    Rectangle()
                        .fill(Color.red.opacity(0.8))
                        .frame(width: 1.5, height: 22)
                        .rotationEffect(.degrees(45))
                        .clipShape(Circle())
                }
                Circle()
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            }
            .frame(width: 22, height: 22)
            .padding(2)
            .overlay(
                Circle().strokeBorder(isSelected ? Color.accentColor : (hovering ? Color.primary.opacity(0.25) : .clear), lineWidth: 2)
            )
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - Table picker

struct TableButton: View {
    @ObservedObject var controller: EditorController

    var body: some View {
        ToolbarPopoverButton(help: "Insert Table") {
            Image(systemName: "tablecells")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.78))
                .frame(width: 20)
        } content: { dismiss in
            TableSizePicker { rows, cols in
                dismiss()
                controller.perform(.table(rows: rows, columns: cols))
            }
        }
    }
}

struct TableSizePicker: View {
    let onPick: (Int, Int) -> Void
    @State private var hover: (Int, Int) = (2, 2)
    private let maxSize = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Insert Table")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(spacing: 3) {
                ForEach(1...maxSize, id: \.self) { r in
                    HStack(spacing: 3) {
                        ForEach(1...maxSize, id: \.self) { c in
                            let on = r <= hover.0 && c <= hover.1
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(on ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.06))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .strokeBorder(on ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: 1)
                                )
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                                .onHover { if $0 { hover = (r, c) } }
                                .onTapGesture { onPick(r, c) }
                        }
                    }
                }
            }
            Text("\(hover.0) × \(hover.1)  ·  first row is the header")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(12)
    }
}

// MARK: - Overflow

struct OverflowMenu: View {
    @ObservedObject var controller: EditorController
    let hidden: Set<Int>
    @State private var hovering = false

    var body: some View {
        Menu {
            // Mirrors FormattingToolbar.Group raw values: 2 color, 3 lists, 4 layout, 5 insert, 6 size.
            if hidden.contains(3) {
                Section("Lists") {
                    item(.list(.bullet)); item(.list(.numbered)); item(.list(.checklist))
                }
            }
            if hidden.contains(2) {
                Section("Color") {
                    Menu("Text Color") {
                        Button("Default") { controller.perform(.textColor(nil)) }
                        ForEach(EditorStyle.textColors) { s in
                            Button(s.name) { controller.perform(.textColor(s.color)) }
                        }
                        Divider()
                        Button("Custom Color…") { controller.perform(.customColor) }
                    }
                    Menu("Highlight") {
                        Button("None") { controller.perform(.highlight(nil)) }
                        ForEach(EditorStyle.highlightColors) { s in
                            Button(s.name) { controller.perform(.highlight(s.color)) }
                        }
                    }
                }
            }
            if hidden.contains(5) {
                Section("Insert") {
                    item(.link)
                    Menu("Table") {
                        ForEach(2...6, id: \.self) { n in
                            Button("\(n) × \(n)") { controller.perform(.table(rows: n, columns: n)) }
                        }
                        Button("3 rows × 2 columns") { controller.perform(.table(rows: 3, columns: 2)) }
                    }
                    item(.image); item(.divider)
                }
            }
            if hidden.contains(4) {
                Section("Layout") {
                    item(.indent); item(.outdent)
                    item(.align(.left)); item(.align(.center)); item(.align(.right)); item(.align(.justified))
                }
            }
            if hidden.contains(6) {
                Section("Size") {
                    item(.fontBigger); item(.fontSmaller); item(.clearFormatting)
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.78))
                .frame(width: 26, height: 24)
                .background(ToolbarHoverBackground(active: false, hovering: hovering))
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .focusable(false)
        .onHover { hovering = $0 }
        .help("More Formatting")
    }

    private func item(_ cmd: FormatCommand) -> some View {
        Button {
            controller.perform(cmd)
        } label: {
            Label(cmd.title, systemImage: cmd.symbol)
        }
        .modifier(ShortcutModifier(command: cmd))
    }
}
