import AppKit

/// Paragraph-level block kinds the editor understands.
///
/// RTFD drops custom attributes and plain `NSTextBlock`s, so special blocks are tagged with a
/// sentinel `defaultTabInterval` (which RTF persists per paragraph) and drawn by `InkwellLayoutManager`.
/// Headings and body paragraphs written by the editor carry sentinels too, so their identity doesn't
/// depend on font size relative to the (user-adjustable) body size.
enum BlockKind: String, CaseIterable, Identifiable {
    case title, heading, subheading, body, code, quote, divider

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .title: "Title"
        case .heading: "Heading"
        case .subheading: "Subheading"
        case .body: "Body"
        case .code: "Monospaced"
        case .quote: "Quote"
        case .divider: "Divider"
        }
    }

    static let menuCases: [BlockKind] = [.title, .heading, .subheading, .body, .code, .quote]
}

enum ListKind: Equatable {
    case bullet, numbered, checklist
}

/// A list marker at the start of a paragraph, e.g. "•\t", "3.\t", "☐\t".
struct ListMarker: Equatable {
    enum Kind: Equatable { case bullet, numbered(Int), checkbox(checked: Bool) }
    var kind: Kind
    /// Length of the marker text including the trailing tab.
    var length: Int

    var listKind: ListKind {
        switch kind {
        case .bullet: .bullet
        case .numbered: .numbered
        case .checkbox: .checklist
        }
    }
}

enum EditorStyle {
    // MARK: Metrics

    static let maxTextWidth: CGFloat = 760
    static let minHorizontalInset: CGFloat = 28
    static let verticalInset: CGFloat = 22
    /// Untagged paragraphs (legacy content, pasted text): classified by font as a fallback.
    static let defaultTab: CGFloat = 28
    static let bodySentinel: CGFloat = 29
    static let codeSentinel: CGFloat = 31
    static let quoteSentinel: CGFloat = 33
    static let dividerSentinel: CGFloat = 35
    static let titleSentinel: CGFloat = 37
    static let headingSentinel: CGFloat = 39
    static let subheadingSentinel: CGFloat = 41
    static let indentStep: CGFloat = 24
    static let listMarkerWidth: CGFloat = 22
    static let listBaseIndent: CGFloat = 4
    static let codeIndent: CGFloat = 14
    static let quoteIndent: CGFloat = 18
    static let codeBlockOuterSpacing: CGFloat = 12
    static let dividerCharacter = "\u{00A0}"

    static var bodySize: CGFloat {
        let stored = UserDefaults.standard.double(forKey: "editorFontSize")
        return stored >= 9 && stored <= 40 ? CGFloat(stored) : 14
    }

    // MARK: Fonts

    static var bodyFont: NSFont { .systemFont(ofSize: bodySize) }
    static var titleFont: NSFont { .systemFont(ofSize: bodySize + 12, weight: .bold) }
    static var headingFont: NSFont { .systemFont(ofSize: bodySize + 5, weight: .semibold) }
    static var subheadingFont: NSFont { .systemFont(ofSize: bodySize + 1.5, weight: .semibold) }
    static var codeFont: NSFont { .monospacedSystemFont(ofSize: bodySize - 1, weight: .regular) }
    static var inlineCodeFont: NSFont { .monospacedSystemFont(ofSize: bodySize - 1, weight: .medium) }

    static func font(for kind: BlockKind) -> NSFont {
        switch kind {
        case .title: titleFont
        case .heading: headingFont
        case .subheading: subheadingFont
        case .code: codeFont
        case .body, .quote, .divider: bodyFont
        }
    }

    // MARK: Colors
    // Text colors are stored as light-appearance values; the text view's adaptive color mapping
    // converts them for dark mode. Drawing-only colors (code background, rules) are dynamic.

    static let inlineCodeBackground = NSColor(srgbRed: 0.92, green: 0.92, blue: 0.94, alpha: 1)
    static let checkedTextColor = NSColor(srgbRed: 0.56, green: 0.56, blue: 0.58, alpha: 1)

    static let codeBlockBackground = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(white: 1, alpha: 0.07) : NSColor(white: 0, alpha: 0.045)
    }
    static let codeBlockBorder = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.06)
    }
    static let quoteBar = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(white: 1, alpha: 0.28) : NSColor(white: 0, alpha: 0.2)
    }
    static let ruleColor = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(white: 1, alpha: 0.18) : NSColor(white: 0, alpha: 0.14)
    }
    static let tableBorder = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(white: 1, alpha: 0.16) : NSColor(srgbRed: 0.80, green: 0.80, blue: 0.82, alpha: 1)
    }
    static let tableHeaderBackground = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(white: 1, alpha: 0.06) : NSColor(srgbRed: 0.955, green: 0.955, blue: 0.97, alpha: 1)
    }
    /// Static stand-ins written by builders; replaced with the dynamic colors when loaded into the editor.
    static let tableBorderStatic = NSColor(srgbRed: 0.80, green: 0.80, blue: 0.82, alpha: 1)
    static let tableHeaderStatic = NSColor(srgbRed: 0.955, green: 0.955, blue: 0.97, alpha: 1)

    struct Swatch: Identifiable {
        let name: String
        let color: NSColor
        var id: String { name }
    }

    static let textColors: [Swatch] = [
        Swatch(name: "Red", color: NSColor(srgbRed: 0.86, green: 0.20, blue: 0.18, alpha: 1)),
        Swatch(name: "Orange", color: NSColor(srgbRed: 0.90, green: 0.45, blue: 0.05, alpha: 1)),
        Swatch(name: "Yellow", color: NSColor(srgbRed: 0.76, green: 0.58, blue: 0.0, alpha: 1)),
        Swatch(name: "Green", color: NSColor(srgbRed: 0.16, green: 0.60, blue: 0.27, alpha: 1)),
        Swatch(name: "Teal", color: NSColor(srgbRed: 0.05, green: 0.55, blue: 0.62, alpha: 1)),
        Swatch(name: "Blue", color: NSColor(srgbRed: 0.10, green: 0.42, blue: 0.90, alpha: 1)),
        Swatch(name: "Purple", color: NSColor(srgbRed: 0.55, green: 0.27, blue: 0.85, alpha: 1)),
        Swatch(name: "Pink", color: NSColor(srgbRed: 0.88, green: 0.22, blue: 0.52, alpha: 1)),
        Swatch(name: "Gray", color: NSColor(srgbRed: 0.50, green: 0.50, blue: 0.53, alpha: 1)),
    ]

    static let highlightColors: [Swatch] = [
        Swatch(name: "Yellow", color: NSColor(srgbRed: 1.0, green: 0.93, blue: 0.55, alpha: 1)),
        Swatch(name: "Green", color: NSColor(srgbRed: 0.76, green: 0.94, blue: 0.70, alpha: 1)),
        Swatch(name: "Blue", color: NSColor(srgbRed: 0.75, green: 0.87, blue: 1.0, alpha: 1)),
        Swatch(name: "Pink", color: NSColor(srgbRed: 1.0, green: 0.80, blue: 0.88, alpha: 1)),
        Swatch(name: "Purple", color: NSColor(srgbRed: 0.88, green: 0.81, blue: 1.0, alpha: 1)),
        Swatch(name: "Orange", color: NSColor(srgbRed: 1.0, green: 0.85, blue: 0.68, alpha: 1)),
    ]

    // MARK: Paragraph styles

    static func baseParagraph() -> NSMutableParagraphStyle {
        let ps = NSMutableParagraphStyle()
        ps.lineHeightMultiple = 1.15
        ps.paragraphSpacing = 6
        ps.defaultTabInterval = bodySentinel
        return ps
    }

    /// Paragraph style for `kind`, keeping alignment and table cell blocks of `existing`.
    static func paragraphStyle(for kind: BlockKind, existing: NSParagraphStyle? = nil, indentLevel: Int = 0) -> NSMutableParagraphStyle {
        let ps = baseParagraph()
        switch kind {
        case .title:
            ps.defaultTabInterval = titleSentinel
            ps.paragraphSpacing = 10
        case .heading:
            ps.defaultTabInterval = headingSentinel
            ps.paragraphSpacingBefore = 10
            ps.paragraphSpacing = 6
        case .subheading:
            ps.defaultTabInterval = subheadingSentinel
            ps.paragraphSpacingBefore = 6
            ps.paragraphSpacing = 4
        case .body:
            break
        case .code:
            ps.defaultTabInterval = codeSentinel
            ps.lineHeightMultiple = 1.1
            ps.paragraphSpacing = 0
            ps.firstLineHeadIndent = codeIndent
            ps.headIndent = codeIndent
        case .quote:
            ps.defaultTabInterval = quoteSentinel
            ps.firstLineHeadIndent = quoteIndent
            ps.headIndent = quoteIndent
        case .divider:
            ps.defaultTabInterval = dividerSentinel
            ps.paragraphSpacingBefore = 4
            ps.paragraphSpacing = 8
        }
        if kind != .code && kind != .divider && indentLevel > 0 {
            ps.firstLineHeadIndent += CGFloat(indentLevel) * indentStep
            ps.headIndent += CGFloat(indentLevel) * indentStep
        }
        if let existing {
            if kind != .divider { ps.alignment = existing.alignment }
            let tableBlocks = existing.textBlocks.filter { $0 is NSTextTableBlock }
            if !tableBlocks.isEmpty { ps.textBlocks = tableBlocks }
        }
        return ps
    }

    static func listParagraphStyle(level: Int, existing: NSParagraphStyle? = nil) -> NSMutableParagraphStyle {
        let ps = baseParagraph()
        ps.paragraphSpacing = 3
        let first = listBaseIndent + CGFloat(level) * indentStep
        ps.firstLineHeadIndent = first
        ps.headIndent = first + listMarkerWidth
        ps.tabStops = [NSTextTab(textAlignment: .left, location: first + listMarkerWidth)]
        if let existing {
            ps.alignment = existing.alignment
            let tableBlocks = existing.textBlocks.filter { $0 is NSTextTableBlock }
            if !tableBlocks.isEmpty { ps.textBlocks = tableBlocks }
        }
        return ps
    }

    static func attributes(for kind: BlockKind, existing: NSParagraphStyle? = nil, indentLevel: Int = 0) -> [NSAttributedString.Key: Any] {
        [.font: font(for: kind), .paragraphStyle: paragraphStyle(for: kind, existing: existing, indentLevel: indentLevel)]
    }

    static var bodyAttributes: [NSAttributedString.Key: Any] { attributes(for: .body) }

    // MARK: Classification

    static func blockKind(paragraphStyle ps: NSParagraphStyle?, font: NSFont?) -> BlockKind {
        if let ps {
            switch ps.defaultTabInterval {
            case codeSentinel: return .code
            case quoteSentinel: return .quote
            case dividerSentinel: return .divider
            case titleSentinel: return .title
            case headingSentinel: return .heading
            case subheadingSentinel: return .subheading
            case bodySentinel: return .body
            default: break
            }
        }
        // Legacy fallback for paragraphs without a sentinel.
        guard let font else { return .body }
        let bold = isBold(font)
        let size = font.pointSize
        let base = bodySize
        if bold && size >= base + 9 { return .title }
        if bold && size >= base + 3.5 { return .heading }
        if bold && size >= base + 1 && !isMonospaced(font) { return .subheading }
        return .body
    }

    static func isBold(_ font: NSFont) -> Bool {
        font.fontDescriptor.symbolicTraits.contains(.bold)
    }

    static func isItalic(_ font: NSFont) -> Bool {
        font.fontDescriptor.symbolicTraits.contains(.italic)
    }

    static func isMonospaced(_ font: NSFont) -> Bool {
        font.fontDescriptor.symbolicTraits.contains(.monoSpace) || font.isFixedPitch
    }

    static func isHeading(_ kind: BlockKind) -> Bool {
        kind == .title || kind == .heading || kind == .subheading
    }

    // MARK: Lists

    static let bulletGlyphs: [String] = ["•", "◦", "▪"]
    static let uncheckedBox = "☐"
    static let checkedBox = "☑"

    static func bulletGlyph(level: Int) -> String { bulletGlyphs[level % bulletGlyphs.count] }

    static func listLevel(of ps: NSParagraphStyle?) -> Int {
        guard let ps else { return 0 }
        return max(0, Int(((ps.firstLineHeadIndent - listBaseIndent) / indentStep).rounded()))
    }

    static func indentLevel(of ps: NSParagraphStyle?, kind: BlockKind) -> Int {
        guard let ps else { return 0 }
        let base: CGFloat = kind == .quote ? quoteIndent : (kind == .code ? codeIndent : 0)
        return max(0, Int(((ps.firstLineHeadIndent - base) / indentStep).rounded()))
    }

    /// Parses a list marker at the start of `paragraph` (a paragraph's text).
    static func listMarker(in paragraph: String) -> ListMarker? {
        let ns = paragraph as NSString
        guard ns.length >= 2 else { return nil }
        let first = ns.substring(to: 1)
        if bulletGlyphs.contains(first), ns.character(at: 1) == 9 {
            return ListMarker(kind: .bullet, length: 2)
        }
        if first == uncheckedBox || first == checkedBox, ns.character(at: 1) == 9 {
            return ListMarker(kind: .checkbox(checked: first == checkedBox), length: 2)
        }
        var i = 0
        while i < min(ns.length, 4), let scalar = UnicodeScalar(ns.character(at: i)), CharacterSet.decimalDigits.contains(scalar) {
            i += 1
        }
        if i > 0, i + 1 < ns.length, ns.character(at: i) == 46 /* . */, ns.character(at: i + 1) == 9,
           let n = Int(ns.substring(to: i)) {
            return ListMarker(kind: .numbered(n), length: i + 2)
        }
        return nil
    }

    static func markerText(_ kind: ListMarker.Kind, level: Int) -> String {
        switch kind {
        case .bullet: bulletGlyph(level: level) + "\t"
        case .numbered(let n): "\(n).\t"
        case .checkbox(let checked): (checked ? checkedBox : uncheckedBox) + "\t"
        }
    }

    static func markerAttributes(level: Int, existing: NSParagraphStyle? = nil) -> [NSAttributedString.Key: Any] {
        [.font: bodyFont, .paragraphStyle: listParagraphStyle(level: level, existing: existing)]
    }

    // MARK: Builders (shared with SeedData)

    static func paragraph(_ text: String, kind: BlockKind) -> NSAttributedString {
        NSAttributedString(string: text + "\n", attributes: attributes(for: kind))
    }

    static func bullet(_ text: String, code: String? = nil) -> NSAttributedString {
        let ps = listParagraphStyle(level: 0)
        let base: [NSAttributedString.Key: Any] = [.font: bodyFont, .paragraphStyle: ps]
        let result = NSMutableAttributedString(string: markerText(.bullet, level: 0), attributes: base)
        if let code {
            var codeAttrs = inlineCodeAttributes
            codeAttrs[.paragraphStyle] = ps
            result.append(NSAttributedString(string: code, attributes: codeAttrs))
            result.append(NSAttributedString(string: "  ", attributes: base))
        }
        result.append(NSAttributedString(string: text + "\n", attributes: base))
        return result
    }

    static var inlineCodeAttributes: [NSAttributedString.Key: Any] {
        [.font: inlineCodeFont, .backgroundColor: inlineCodeBackground]
    }

    static func divider() -> NSAttributedString {
        NSAttributedString(string: dividerCharacter + "\n", attributes: attributes(for: .divider))
    }

    /// An NSTextTable with a bold header row. `widths` are optional column percentages.
    static func table(header: [String], rows: [[String]], widths: [CGFloat]? = nil, monospacedFirstColumn: Bool = false) -> NSAttributedString {
        let table = NSTextTable()
        table.numberOfColumns = header.count
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        table.setValue(99.5, type: .percentageValueType, for: .width)

        let result = NSMutableAttributedString()
        for (c, title) in header.enumerated() {
            result.append(tableCell(title, table: table, row: 0, column: c, columns: header.count, width: widths?[c], header: true, monospaced: false))
        }
        for (r, row) in rows.enumerated() {
            for (c, value) in row.enumerated() {
                result.append(tableCell(value, table: table, row: r + 1, column: c, columns: header.count, width: widths?[c], header: false, monospaced: monospacedFirstColumn && c == 0))
            }
        }
        return result
    }

    static func tableBlock(table: NSTextTable, row: Int, column: Int, columns: Int, width: CGFloat?, header: Bool) -> NSTextTableBlock {
        let block = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
        block.setWidth(1, type: .absoluteValueType, for: .border)
        block.setBorderColor(tableBorderStatic)
        block.setWidth(8, type: .absoluteValueType, for: .padding)
        // Uniform tables get no cell widths: the 100%-wide table shares space evenly, whereas
        // percentage cell widths exclude padding/borders and would overflow the container.
        if let width { block.setValue(width, type: .percentageValueType, for: .width) }
        if header { block.backgroundColor = tableHeaderStatic }
        return block
    }

    static func tableCellParagraph(block: NSTextBlock) -> NSMutableParagraphStyle {
        let ps = NSMutableParagraphStyle()
        ps.textBlocks = [block]
        ps.lineHeightMultiple = 1.1
        ps.defaultTabInterval = bodySentinel
        return ps
    }

    static func tableCell(_ text: String, table: NSTextTable, row: Int, column: Int, columns: Int, width: CGFloat?, header: Bool, monospaced: Bool) -> NSAttributedString {
        let block = tableBlock(table: table, row: row, column: column, columns: columns, width: width, header: header)
        let font: NSFont
        if header {
            font = .systemFont(ofSize: bodySize - 1, weight: .semibold)
        } else if monospaced {
            font = .monospacedSystemFont(ofSize: bodySize, weight: .medium)
        } else {
            font = bodyFont
        }
        return NSAttributedString(string: text + "\n", attributes: [.font: font, .paragraphStyle: tableCellParagraph(block: block)])
    }

    /// Copies a table cell block, moving it to `row`.
    static func copyBlock(_ old: NSTextTableBlock, row: Int, header: Bool? = nil) -> NSTextTableBlock {
        let block = NSTextTableBlock(table: old.table, startingRow: row, rowSpan: 1, startingColumn: old.startingColumn, columnSpan: old.columnSpan)
        block.setWidth(old.width(for: .border, edge: .minX), type: .absoluteValueType, for: .border)
        block.setBorderColor(old.borderColor(for: .minX) ?? tableBorder)
        block.setWidth(old.width(for: .padding, edge: .minX), type: .absoluteValueType, for: .padding)
        if old.value(for: .width) > 0 {
            block.setValue(old.value(for: .width), type: old.valueType(for: .width), for: .width)
        }
        let isHeader = header ?? (old.backgroundColor != nil)
        block.backgroundColor = isHeader ? tableHeaderBackground : nil
        return block
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}
