import AppKit

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

    /// Widest the text column gets; wider editors center it.
    static let maxReadingWidth: CGFloat = Tokens.Size.readingMax
    /// Images wider than this (less padding) are scaled down when inserted.
    static let maxTextWidth: CGFloat = 760
    static let minHorizontalInset: CGFloat = 28
    static let verticalInset: CGFloat = 22
    /// Untagged paragraphs (legacy content, pasted text): classified by font as a fallback.
    static let defaultTab: CGFloat = 28
    static let bodySentinel = CGFloat(BlockSentinels.body)
    static let codeSentinel = CGFloat(BlockSentinels.code)
    static let quoteSentinel = CGFloat(BlockSentinels.quote)
    static let dividerSentinel = CGFloat(BlockSentinels.divider)
    static let titleSentinel = CGFloat(BlockSentinels.title)
    static let headingSentinel = CGFloat(BlockSentinels.heading)
    static let subheadingSentinel = CGFloat(BlockSentinels.subheading)
    static let indentStep = DocParagraphModel.indentStep
    static let listMarkerWidth = DocParagraphModel.listMarkerWidth
    static let listBaseIndent = DocParagraphModel.listBaseIndent
    static let codeIndent = DocParagraphModel.codeIndent
    static let quoteIndent = DocParagraphModel.quoteIndent
    static let codeBlockOuterSpacing: CGFloat = 15
    /// Right inset (as a negative tail indent) of a code block's first paragraph, so its text never runs
    /// under the language label and copy button.
    static let codeChromeInset: CGFloat = 120
    static let dividerCharacter = DocParagraphModel.dividerCharacter

    static var bodySize: CGFloat {
        let stored = UserDefaults.standard.double(forKey: "editorFontSize")
        return stored >= 9 && stored <= 40 ? CGFloat(stored) : 14
    }

    // MARK: Fonts

    static var bodyFont: NSFont { font(for: .body, bodySize: bodySize) }
    static var titleFont: NSFont { font(for: .title, bodySize: bodySize) }
    static var headingFont: NSFont { font(for: .heading, bodySize: bodySize) }
    static var subheadingFont: NSFont { font(for: .subheading, bodySize: bodySize) }
    static var codeFont: NSFont { font(for: .code, bodySize: bodySize) }
    static var inlineCodeFont: NSFont { inlineCodeFont(bodySize: bodySize) }

    static func font(for kind: BlockKind) -> NSFont {
        font(for: kind, bodySize: bodySize)
    }

    /// The font of a `kind` paragraph when the body text is `size` points; `AppDocStyleProvider` reads it too.
    static func font(for kind: BlockKind, bodySize size: CGFloat) -> NSFont {
        switch kind {
        case .title: .systemFont(ofSize: size + 12, weight: .bold)
        case .heading: .systemFont(ofSize: size + 5, weight: .semibold)
        case .subheading: .systemFont(ofSize: size + 1.5, weight: .semibold)
        case .code: .monospacedSystemFont(ofSize: size - 1, weight: .regular)
        case .body, .quote, .divider: .systemFont(ofSize: size)
        }
    }

    static func inlineCodeFont(bodySize size: CGFloat) -> NSFont {
        .monospacedSystemFont(ofSize: size - 1, weight: .medium)
    }

    // MARK: Colors
    // Text colors are stored as light-appearance values; the text view's adaptive color mapping
    // converts them for dark mode. Drawing-only colors (code background, rules) are dynamic.

    static let checkedTextColor = DocParagraphModel.checkedTextColor

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
    static let tableBorderStatic = DocParagraphModel.tableBorderStatic
    static let tableHeaderStatic = DocParagraphModel.tableHeaderStatic

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
        DocParagraphModel.baseParagraph()
    }

    /// Paragraph style for `kind`, keeping alignment and table cell blocks of `existing`.
    static func paragraphStyle(for kind: BlockKind, existing: NSParagraphStyle? = nil, indentLevel: Int = 0) -> NSMutableParagraphStyle {
        DocParagraphModel.paragraphStyle(for: kind, existing: existing, indentLevel: indentLevel)
    }

    static func listParagraphStyle(level: Int, existing: NSParagraphStyle? = nil) -> NSMutableParagraphStyle {
        DocParagraphModel.listParagraphStyle(level: level, existing: existing)
    }

    static func attributes(for kind: BlockKind, existing: NSParagraphStyle? = nil, indentLevel: Int = 0) -> [NSAttributedString.Key: Any] {
        [.font: font(for: kind), .paragraphStyle: paragraphStyle(for: kind, existing: existing, indentLevel: indentLevel)]
    }

    static var bodyAttributes: [NSAttributedString.Key: Any] { attributes(for: .body) }

    // MARK: Classification

    static func blockKind(paragraphStyle ps: NSParagraphStyle?, font: NSFont?) -> BlockKind {
        DocParagraphModel.blockKind(paragraphStyle: ps, font: font, baseSize: bodySize)
    }

    static func isBold(_ font: NSFont) -> Bool {
        DocParagraphModel.isBold(font)
    }

    static func isItalic(_ font: NSFont) -> Bool {
        DocParagraphModel.isItalic(font)
    }

    static func isMonospaced(_ font: NSFont) -> Bool {
        DocParagraphModel.isMonospaced(font)
    }

    static func isHeading(_ kind: BlockKind) -> Bool {
        kind == .title || kind == .heading || kind == .subheading
    }

    // MARK: Lists

    static let bulletGlyphs = DocParagraphModel.bulletGlyphs
    static let uncheckedBox = ChecklistMarkers.unchecked
    static let checkedBox = ChecklistMarkers.checked

    static func bulletGlyph(level: Int) -> String { DocParagraphModel.bulletGlyph(level: level) }

    static func listLevel(of ps: NSParagraphStyle?) -> Int {
        DocParagraphModel.listLevel(of: ps)
    }

    static func indentLevel(of ps: NSParagraphStyle?, kind: BlockKind) -> Int {
        DocParagraphModel.indentLevel(of: ps, kind: kind)
    }

    /// Parses a list marker at the start of `paragraph` (a paragraph's text).
    static func listMarker(in paragraph: String) -> ListMarker? {
        guard let marker = DocParagraphModel.listMarker(in: paragraph) else { return nil }
        switch marker.kind {
        case .bullet: return ListMarker(kind: .bullet, length: marker.length)
        case .numbered(let n): return ListMarker(kind: .numbered(n), length: marker.length)
        case .checkbox(let checked): return ListMarker(kind: .checkbox(checked: checked), length: marker.length)
        }
    }

    static func markerText(_ kind: ListMarker.Kind, level: Int) -> String {
        switch kind {
        case .bullet: DocParagraphModel.markerText(.bullet, level: level)
        case .numbered(let n): DocParagraphModel.markerText(.numbered(n), level: level)
        case .checkbox(let checked): DocParagraphModel.markerText(.checkbox(checked: checked), level: level)
        }
    }

    static func markerAttributes(level: Int, existing: NSParagraphStyle? = nil) -> [NSAttributedString.Key: Any] {
        [.font: bodyFont, .paragraphStyle: listParagraphStyle(level: level, existing: existing)]
    }

    /// Attributes copied from the text onto text being inserted: only a line break read from a file is soft.
    static func forInsertion(_ attrs: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        var attrs = attrs
        attrs[.noteItSoftBreak] = nil
        return attrs
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
        [.font: inlineCodeFont]
    }

    /// The flat background older versions stored on inline code; it's replaced by the drawn pill.
    static let legacyInlineCodeBackground = DocParagraphModel.legacyInlineCodeBackground

    static func isLegacyInlineCodeBackground(_ color: NSColor?) -> Bool {
        DocParagraphModel.isLegacyInlineCodeBackground(color)
    }

    /// Inline code is stored as a monospaced font outside code blocks. With the *Same as Text* inline
    /// code font, the editor shows it in the text font and marks it with `inlineCodeDisplay` instead.
    static func isInlineCode(_ attrs: [NSAttributedString.Key: Any]) -> Bool {
        if attrs[.inlineCodeDisplay] != nil { return true }
        return (attrs[.font] as? NSFont).map(isMonospaced) ?? false
    }

    // MARK: Code block language
    // A code paragraph's language is an extra left tab stop (see `DocParagraphModel.codeLanguage(of:)`), and,
    // when it came from a document, `noteItCodeLanguageID` holds the identifier as written.

    static let codeLanguageStep = DocParagraphModel.codeLanguageStep

    static func codeLanguage(of ps: NSParagraphStyle?) -> CodeLanguage? {
        DocParagraphModel.codeLanguage(of: ps)
    }

    static func setCodeLanguage(_ language: CodeLanguage?, on ps: NSMutableParagraphStyle) {
        DocParagraphModel.setCodeLanguage(language, on: ps)
    }

    /// Drops a code paragraph's language identifier when the text stops being code.
    static func removeCodeLanguageID(from s: NSMutableAttributedString) {
        s.removeAttribute(.noteItCodeLanguageID, range: NSRange(location: 0, length: s.length))
    }

    static func divider() -> NSAttributedString {
        NSAttributedString(string: dividerCharacter + "\n", attributes: attributes(for: .divider))
    }

    /// An NSTextTable with a bold header row. `widths` are optional column percentages.
    static func table(header: [String], rows: [[String]], widths: [CGFloat]? = nil, monospacedFirstColumn: Bool = false) -> NSAttributedString {
        let table = DocParagraphModel.makeTable(columns: header.count)

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
        DocParagraphModel.tableBlock(table: table, row: row, column: column, width: width, header: header)
    }

    static func tableCellParagraph(block: NSTextBlock) -> NSMutableParagraphStyle {
        DocParagraphModel.tableCellParagraph(block: block)
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

extension NSAttributedString.Key {
    /// Editor-only marker for inline code shown in the text font; never saved (see `NoteItTextView.attributedString()`).
    static let inlineCodeDisplay = NSAttributedString.Key("NoteItInlineCodeDisplay")
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}
