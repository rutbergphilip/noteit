import AppKit
import NoteItCore
import NoteItDoc

/// The editor's paragraph model: the metrics, paragraph styles, list markers, code-language tab stops and table
/// blocks the converter reads and writes. Owned by the foundations plan (Task 2.3); `EditorStyle` forwards to it,
/// so the editor and the converter can't drift.
public enum DocParagraphModel {
    // MARK: Metrics

    public static let indentStep: CGFloat = 24
    public static let listMarkerWidth: CGFloat = 22
    public static let listBaseIndent: CGFloat = 4
    public static let codeIndent: CGFloat = 14
    public static let quoteIndent: CGFloat = 18
    /// The text of a divider paragraph.
    public static let dividerCharacter = "\u{00A0}"
    /// The gray a checked checklist item is drawn in, derived from `checked`, never exported as a mark.
    public static let checkedTextColor = NSColor(srgbRed: 0.56, green: 0.56, blue: 0.58, alpha: 1)
    /// Static table colors written by builders; the editor swaps in dynamic ones when it loads the text.
    public static let tableBorderStatic = NSColor(srgbRed: 0.80, green: 0.80, blue: 0.82, alpha: 1)
    public static let tableHeaderStatic = NSColor(srgbRed: 0.955, green: 0.955, blue: 0.97, alpha: 1)
    /// The flat background older versions stored on inline code; it's replaced by the drawn pill.
    public static let legacyInlineCodeBackground = NSColor(srgbRed: 0.92, green: 0.92, blue: 0.94, alpha: 1)

    private static let bodySentinel = CGFloat(BlockSentinels.body)

    // MARK: Paragraph styles

    public static func baseParagraph() -> NSMutableParagraphStyle {
        let ps = NSMutableParagraphStyle()
        ps.lineHeightMultiple = 1.15
        ps.paragraphSpacing = 6
        ps.defaultTabInterval = bodySentinel
        return ps
    }

    /// Paragraph style for `kind`, keeping alignment and table cell blocks of `existing`.
    public static func paragraphStyle(for kind: BlockKind, existing: NSParagraphStyle? = nil, indentLevel: Int = 0) -> NSMutableParagraphStyle {
        let ps = baseParagraph()
        switch kind {
        case .title:
            ps.defaultTabInterval = CGFloat(BlockSentinels.title)
            ps.paragraphSpacing = 10
        case .heading:
            ps.defaultTabInterval = CGFloat(BlockSentinels.heading)
            ps.paragraphSpacingBefore = 10
            ps.paragraphSpacing = 6
        case .subheading:
            ps.defaultTabInterval = CGFloat(BlockSentinels.subheading)
            ps.paragraphSpacingBefore = 6
            ps.paragraphSpacing = 4
        case .body:
            break
        case .code:
            ps.defaultTabInterval = CGFloat(BlockSentinels.code)
            ps.lineHeightMultiple = 1.1
            ps.paragraphSpacing = 0
            ps.firstLineHeadIndent = codeIndent
            ps.headIndent = codeIndent
        case .quote:
            ps.defaultTabInterval = CGFloat(BlockSentinels.quote)
            ps.firstLineHeadIndent = quoteIndent
            ps.headIndent = quoteIndent
        case .divider:
            ps.defaultTabInterval = CGFloat(BlockSentinels.divider)
            ps.paragraphSpacingBefore = 4
            ps.paragraphSpacing = 8
        }
        if kind != .code && kind != .divider && indentLevel > 0 {
            ps.firstLineHeadIndent += CGFloat(indentLevel) * indentStep
            ps.headIndent += CGFloat(indentLevel) * indentStep
        }
        if let existing {
            if kind != .divider { ps.alignment = existing.alignment }
            if kind == .code, blockKind(paragraphStyle: existing, font: nil, baseSize: 0) == .code {
                setCodeLanguage(codeLanguage(of: existing), on: ps)
            }
            let tableBlocks = existing.textBlocks.filter { $0 is NSTextTableBlock }
            if !tableBlocks.isEmpty { ps.textBlocks = tableBlocks }
        }
        return ps
    }

    public static func listParagraphStyle(level: Int, existing: NSParagraphStyle? = nil) -> NSMutableParagraphStyle {
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

    // MARK: Classification

    /// The block kind from the paragraph's sentinel tab interval. Paragraphs without one (legacy content, pasted
    /// text) are classified by font against the body size `baseSize`.
    public static func blockKind(paragraphStyle ps: NSParagraphStyle?, font: NSFont?, baseSize: CGFloat) -> BlockKind {
        if let ps {
            switch Double(ps.defaultTabInterval) {
            case BlockSentinels.code: return .code
            case BlockSentinels.quote: return .quote
            case BlockSentinels.divider: return .divider
            case BlockSentinels.title: return .title
            case BlockSentinels.heading: return .heading
            case BlockSentinels.subheading: return .subheading
            case BlockSentinels.body: return .body
            default: break
            }
        }
        guard let font else { return .body }
        let bold = isBold(font)
        let size = font.pointSize
        if bold && size >= baseSize + 9 { return .title }
        if bold && size >= baseSize + 3.5 { return .heading }
        if bold && size >= baseSize + 1 && !isMonospaced(font) { return .subheading }
        return .body
    }

    public static func isBold(_ font: NSFont) -> Bool {
        font.fontDescriptor.symbolicTraits.contains(.bold)
    }

    public static func isItalic(_ font: NSFont) -> Bool {
        font.fontDescriptor.symbolicTraits.contains(.italic)
    }

    public static func isMonospaced(_ font: NSFont) -> Bool {
        font.fontDescriptor.symbolicTraits.contains(.monoSpace) || font.isFixedPitch
    }

    public static func isLegacyInlineCodeBackground(_ color: NSColor?) -> Bool {
        guard let color, let c = color.usingColorSpace(.sRGB), let l = legacyInlineCodeBackground.usingColorSpace(.sRGB) else { return false }
        let tolerance: CGFloat = 0.01
        return abs(c.redComponent - l.redComponent) < tolerance && abs(c.greenComponent - l.greenComponent) < tolerance
            && abs(c.blueComponent - l.blueComponent) < tolerance && abs(c.alphaComponent - l.alphaComponent) < tolerance
    }

    public static func isCheckedGray(_ color: NSColor) -> Bool {
        if color == checkedTextColor { return true }
        guard let rgb = color.usingColorSpace(.sRGB) else { return false }
        let t = checkedTextColor
        return abs(rgb.redComponent - t.redComponent) < 0.02 && abs(rgb.greenComponent - t.greenComponent) < 0.02
            && abs(rgb.blueComponent - t.blueComponent) < 0.02
    }

    // MARK: Lists

    public static let bulletGlyphs: [String] = ["•", "◦", "▪"]

    public static func bulletGlyph(level: Int) -> String { bulletGlyphs[level % bulletGlyphs.count] }

    public static func listLevel(of ps: NSParagraphStyle?) -> Int {
        guard let ps else { return 0 }
        return max(0, Int(((ps.firstLineHeadIndent - listBaseIndent) / indentStep).rounded()))
    }

    public static func indentLevel(of ps: NSParagraphStyle?, kind: BlockKind) -> Int {
        guard let ps else { return 0 }
        let base: CGFloat = kind == .quote ? quoteIndent : (kind == .code ? codeIndent : 0)
        return max(0, Int(((ps.firstLineHeadIndent - base) / indentStep).rounded()))
    }

    /// A list marker at the start of a paragraph: "•\t", "3.\t" or "☐\t".
    public struct Marker: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case bullet, numbered(Int), checkbox(checked: Bool) }
        public var kind: Kind
        /// Length of the marker text including the trailing tab, in UTF-16 units.
        public var length: Int

        public init(kind: Kind, length: Int) {
            self.kind = kind
            self.length = length
        }
    }

    /// Parses a list marker at the start of `paragraph` (a paragraph's text).
    public static func listMarker(in paragraph: String) -> Marker? {
        let ns = paragraph as NSString
        guard ns.length >= 2 else { return nil }
        let first = ns.substring(to: 1)
        if bulletGlyphs.contains(first), ns.character(at: 1) == 9 {
            return Marker(kind: .bullet, length: 2)
        }
        if first == ChecklistMarkers.unchecked || first == ChecklistMarkers.checked, ns.character(at: 1) == 9 {
            return Marker(kind: .checkbox(checked: first == ChecklistMarkers.checked), length: 2)
        }
        var i = 0
        while i < min(ns.length, 4), let scalar = UnicodeScalar(ns.character(at: i)), CharacterSet.decimalDigits.contains(scalar) {
            i += 1
        }
        if i > 0, i + 1 < ns.length, ns.character(at: i) == 46 /* . */, ns.character(at: i + 1) == 9,
           let n = Int(ns.substring(to: i)) {
            return Marker(kind: .numbered(n), length: i + 2)
        }
        return nil
    }

    public static func markerText(_ kind: Marker.Kind, level: Int) -> String {
        switch kind {
        case .bullet: bulletGlyph(level: level) + "\t"
        case .numbered(let n): "\(n).\t"
        case .checkbox(let checked): (checked ? ChecklistMarkers.checked : ChecklistMarkers.unchecked) + "\t"
        }
    }

    // MARK: Code block language
    // A code paragraph's language is an extra left tab stop at `rawValue × 0.5` pt (0.5–10.5 pt).
    // Tab stops are written to RTF in twips, so the value survives exactly, and a stop left of the
    // code indent is never reached by typing a tab. No such stop means Automatic.

    public static let codeLanguageStep: CGFloat = 0.5

    public static func codeLanguage(of ps: NSParagraphStyle?) -> CodeLanguage? {
        guard let ps else { return nil }
        for tab in ps.tabStops where tab.location > 0 && tab.location < codeIndent {
            let raw = Int((tab.location / codeLanguageStep).rounded())
            if abs(CGFloat(raw) * codeLanguageStep - tab.location) < 0.01, let language = CodeLanguage(rawValue: raw) {
                return language
            }
        }
        return nil
    }

    public static func setCodeLanguage(_ language: CodeLanguage?, on ps: NSMutableParagraphStyle) {
        var tabs = ps.tabStops.filter { !($0.location > 0 && $0.location < codeIndent) }
        if let language {
            tabs.append(NSTextTab(textAlignment: .left, location: CGFloat(language.rawValue) * codeLanguageStep))
        }
        ps.tabStops = tabs
    }

    // MARK: Tables

    /// A 100%-wide table with collapsed borders, as the editor inserts.
    public static func makeTable(columns: Int) -> NSTextTable {
        let table = NSTextTable()
        table.numberOfColumns = columns
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        table.setValue(99.5, type: .percentageValueType, for: .width)
        return table
    }

    public static func tableBlock(table: NSTextTable, row: Int, column: Int, width: CGFloat?, header: Bool) -> NSTextTableBlock {
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

    public static func tableCellParagraph(block: NSTextBlock) -> NSMutableParagraphStyle {
        let ps = NSMutableParagraphStyle()
        ps.textBlocks = [block]
        ps.lineHeightMultiple = 1.1
        ps.defaultTabInterval = bodySentinel
        return ps
    }
}

extension NSAttributedString.Key {
    /// A code paragraph's `codeBlock.language` identifier as written, known to `CodeLanguage` or not (foundations
    /// Task 2.3). Value: String. The only paragraph attribute NoteItDocAppKit adds.
    public static let noteItCodeLanguageID = NSAttributedString.Key("NoteItCodeLanguageID")
}
