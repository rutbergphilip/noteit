import AppKit

/// Every formatting action the toolbar, keyboard and context menu can trigger.
enum FormatCommand: Hashable {
    case bold, italic, underline, strikethrough, inlineCode
    case block(BlockKind)
    case list(ListKind)
    case toggleCheckbox
    case indent, outdent
    case align(NSTextAlignment)
    case textColor(NSColor?)
    case highlight(NSColor?)
    case toggleHighlight
    case customColor
    case fontBigger, fontSmaller
    case link
    case divider
    case table(rows: Int, columns: Int)
    case image
    case clearFormatting
    case addRowAbove, addRowBelow, deleteRow

    var title: String {
        switch self {
        case .bold: "Bold"
        case .italic: "Italic"
        case .underline: "Underline"
        case .strikethrough: "Strikethrough"
        case .inlineCode: "Inline Code"
        case .block(let kind): kind == .code ? "Code Block" : kind.displayName
        case .list(.bullet): "Bulleted List"
        case .list(.numbered): "Numbered List"
        case .list(.checklist): "Checklist"
        case .toggleCheckbox: "Mark as Checked"
        case .indent: "Indent"
        case .outdent: "Outdent"
        case .align(let a):
            switch a {
            case .center: "Align Center"
            case .right: "Align Right"
            case .justified: "Justify"
            default: "Align Left"
            }
        case .textColor: "Text Color"
        case .highlight, .toggleHighlight: "Highlight"
        case .customColor: "Custom Color…"
        case .fontBigger: "Bigger"
        case .fontSmaller: "Smaller"
        case .link: "Link…"
        case .divider: "Divider"
        case .table: "Table"
        case .image: "Image…"
        case .clearFormatting: "Clear Formatting"
        case .addRowAbove: "Add Row Above"
        case .addRowBelow: "Add Row Below"
        case .deleteRow: "Delete Row"
        }
    }

    var symbol: String {
        switch self {
        case .bold: "bold"
        case .italic: "italic"
        case .underline: "underline"
        case .strikethrough: "strikethrough"
        case .inlineCode: "chevron.left.forwardslash.chevron.right"
        case .block(.code): "curlybraces"
        case .block(.quote): "text.quote"
        case .block: "textformat"
        case .list(.bullet): "list.bullet"
        case .list(.numbered): "list.number"
        case .list(.checklist): "checklist"
        case .toggleCheckbox: "checkmark.circle"
        case .indent: "increase.indent"
        case .outdent: "decrease.indent"
        case .align(let a):
            switch a {
            case .center: "text.aligncenter"
            case .right: "text.alignright"
            case .justified: "text.justify"
            default: "text.alignleft"
            }
        case .textColor, .customColor: "paintpalette"
        case .highlight, .toggleHighlight: "highlighter"
        case .fontBigger: "textformat.size.larger"
        case .fontSmaller: "textformat.size.smaller"
        case .link: "link"
        case .divider: "minus"
        case .table: "tablecells"
        case .image: "photo"
        case .clearFormatting: "eraser"
        case .addRowAbove: "arrow.up.to.line"
        case .addRowBelow: "arrow.down.to.line"
        case .deleteRow: "trash"
        }
    }

    var shortcut: KeyShortcut? {
        KeyShortcut.all.first { $0.command == self }
    }

    /// "Bold (⌘B)"
    var helpText: String {
        if let s = shortcut { return "\(title) (\(s.display))" }
        return title
    }
}

struct KeyShortcut {
    let key: String
    let modifiers: NSEvent.ModifierFlags
    let command: FormatCommand
    /// Optional display override for keys that need shift to type (e.g. "+").
    var displayKey: String?

    var display: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + (displayKey ?? key.uppercased())
    }

    static let all: [KeyShortcut] = [
        KeyShortcut(key: "b", modifiers: [.command], command: .bold),
        KeyShortcut(key: "i", modifiers: [.command], command: .italic),
        KeyShortcut(key: "u", modifiers: [.command], command: .underline),
        KeyShortcut(key: "x", modifiers: [.command, .shift], command: .strikethrough),
        KeyShortcut(key: "e", modifiers: [.command, .shift], command: .inlineCode),
        KeyShortcut(key: "1", modifiers: [.command, .option], command: .block(.title)),
        KeyShortcut(key: "2", modifiers: [.command, .option], command: .block(.heading)),
        KeyShortcut(key: "3", modifiers: [.command, .option], command: .block(.subheading)),
        KeyShortcut(key: "0", modifiers: [.command, .option], command: .block(.body)),
        KeyShortcut(key: "4", modifiers: [.command, .option], command: .block(.code)),
        KeyShortcut(key: "5", modifiers: [.command, .option], command: .block(.quote)),
        KeyShortcut(key: "8", modifiers: [.command, .shift], command: .list(.bullet)),
        KeyShortcut(key: "7", modifiers: [.command, .shift], command: .list(.numbered)),
        KeyShortcut(key: "l", modifiers: [.command, .shift], command: .list(.checklist)),
        KeyShortcut(key: "u", modifiers: [.command, .shift], command: .toggleCheckbox),
        KeyShortcut(key: "]", modifiers: [.command], command: .indent),
        KeyShortcut(key: "[", modifiers: [.command], command: .outdent),
        KeyShortcut(key: "[", modifiers: [.command, .shift], command: .align(.left), displayKey: "{"),
        KeyShortcut(key: "\\", modifiers: [.command, .shift], command: .align(.center), displayKey: "|"),
        KeyShortcut(key: "]", modifiers: [.command, .shift], command: .align(.right), displayKey: "}"),
        KeyShortcut(key: "k", modifiers: [.command], command: .link),
        KeyShortcut(key: "h", modifiers: [.command, .shift], command: .toggleHighlight),
        KeyShortcut(key: "=", modifiers: [.command], command: .fontBigger, displayKey: "+"),
        KeyShortcut(key: "-", modifiers: [.command], command: .fontSmaller),
        KeyShortcut(key: "d", modifiers: [.command, .shift, .option], command: .divider),
        KeyShortcut(key: "\\", modifiers: [.command, .option], command: .clearFormatting),
    ]

    static func match(_ event: NSEvent) -> FormatCommand? {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags.contains(.command) else { return nil }
        let base = (event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? "").lowercased()
        if flags == [.command, .shift], base == "=" || event.charactersIgnoringModifiers == "+" {
            return .fontBigger
        }
        return all.first { $0.modifiers == flags && $0.key == base }?.command
    }
}

/// Snapshot of formatting at the selection, used to light up toolbar buttons.
struct FormattingState: Equatable {
    var bold = false
    var italic = false
    var underline = false
    var strikethrough = false
    var inlineCode = false
    var block: BlockKind = .body
    var list: ListKind?
    var alignment: NSTextAlignment = .natural
    var link = false
    var textColor: NSColor?
    var highlight: NSColor?
    var inTable = false
    var fontSize: CGFloat = 14
}
