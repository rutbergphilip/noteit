import AppKit
import CryptoKit
import NoteItCore
import NoteItDoc
import NoteItDocAppKit
import XCTest

/// One fixture per `FormatCommand` row of the web-app spec §3.3 code-block table: the text the editor leaves after
/// the command, the noteit-doc it exports to, and an import that gives the same text back.
final class ConverterCodeBlockTests: XCTestCase {
    private let styles = TestStyles()
    private var codeFont: NSFont { styles.font(for: .code, size: 14) }
    private var bodyFont: NSFont { styles.font(for: .body, size: 14) }

    func testBoldItalic() throws {
        let fm = NSFontManager.shared
        let text = code([("a", [.font: fm.convert(codeFont, toHaveTrait: .boldFontMask)]),
                         ("b", [.font: fm.convert(codeFont, toHaveTrait: .italicFontMask)])])
        try check(text, [.codeBlock(align: nil, language: nil, content: [.text("a", marks: [.bold]), .text("b", marks: [.italic])])])
    }

    func testUnderlineStrikethrough() throws {
        let line = NSUnderlineStyle.single.rawValue
        let text = code([("a", [.underlineStyle: line]), ("b", [.strikethroughStyle: line])])
        try check(text, [.codeBlock(align: nil, language: nil, content: [.text("a", marks: [.underline]), .text("b", marks: [.strike])])])
    }

    func testInlineCodeIsNoOp() throws {
        let text = code([("let x = 1", [:])])
        try check(text, [.codeBlock(align: nil, language: nil, content: [.text("let x = 1", marks: [])])])
    }

    func testTextColorSetAndRemoved() throws {
        let text = code([("a", [.foregroundColor: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)]), ("b", [:])])
        try check(text, [.codeBlock(align: nil, language: nil, content: [.text("a", marks: [.textColor("#FF0000")]), .text("b", marks: [])])])
        XCTAssertNotEqual(SemanticText(text), SemanticText(code([("ab", [:])])), "the comparer sees colors")
    }

    func testHighlight() throws {
        let text = code([("a", [.backgroundColor: NSColor(srgbRed: 1, green: 1, blue: 0, alpha: 1)])])
        try check(text, [.codeBlock(align: nil, language: nil, content: [.text("a", marks: [.highlight("#FFFF00")])])])
    }

    func testFontBiggerSmaller() throws {
        let bigger = NSFont(descriptor: codeFont.fontDescriptor, size: codeFont.pointSize + 1)!
        let smaller = NSFont(descriptor: codeFont.fontDescriptor, size: codeFont.pointSize - 1)!
        let text = code([("a", [.font: bigger]), ("b", [.font: smaller])])
        try check(text, [.codeBlock(align: nil, language: nil, content: [.text("a", marks: [.fontSize(delta: 1)]),
                                                                         .text("b", marks: [.fontSize(delta: -1)])])])
    }

    func testAlignment() throws {
        let pairs: [(NSTextAlignment, Align)] = [(.left, .left), (.center, .center), (.right, .right), (.justified, .justify)]
        for (alignment, align) in pairs {
            try check(code([("x", [:])], alignment: alignment), [.codeBlock(align: align, language: nil, content: [.text("x", marks: [])])])
        }
    }

    func testIndentOutdentListAndCheckboxAreNoOps() throws {
        // The editor gives code paragraphs an identity edit for these, so the text is plain code.
        let text = code([("x", [:])], language: .swift)
        try check(text, [.codeBlock(align: nil, language: "swift", content: [.text("x", marks: [])])])
    }

    func testBlockCodeAgainGivesBody() throws {
        let italic = NSFontManager.shared.convert(bodyFont, toHaveTrait: .italicFontMask)
        let line = NSUnderlineStyle.single.rawValue
        let text = paragraph(.body, [("a", [.font: italic]), ("b", [.underlineStyle: line])], alignment: .center)
        try check(text, [.paragraph(align: .center, indent: nil, content: [.text("a", marks: [.italic]), .text("b", marks: [.underline])])])
    }

    func testBlockHeadingConvertsOutOfCode() throws {
        let heading = styles.font(for: .heading, size: 14)
        let italic = NSFontManager.shared.convert(heading, toHaveTrait: .italicFontMask)
        let text = paragraph(.heading, [("a", [.font: italic]), ("b", [.strikethroughStyle: NSUnderlineStyle.single.rawValue])],
                             alignment: .right)
        try check(text, [.heading(level: 2, align: .right, indent: nil, content: [.text("a", marks: [.italic]), .text("b", marks: [.strike])])])
    }

    func testBlockQuoteConvertsOutOfCode() throws {
        let text = paragraph(.quote, [("a", [.foregroundColor: NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)])])
        try check(text, [.blockquote(indent: nil, content: [.paragraph(align: nil, indent: nil, content: [.text("a", marks: [.textColor("#0000FF")])])])])
    }

    func testLink() throws {
        let text = code([("site", [.link: URL(string: "https://example.com/")!])])
        try check(text, [.codeBlock(align: nil, language: nil, content: [.text("site", marks: [.link(href: "https://example.com/")])])])
    }

    func testImage() throws {
        let data = try Self.pngData()
        let wrapper = FileWrapper(regularFileWithContents: data)
        wrapper.preferredFilename = "dot.png"
        let image = NSMutableAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper))
        let text = code([("a", [:])])
        image.addAttributes(text.attributes(at: 0, effectiveRange: nil), range: NSRange(location: 0, length: image.length))
        text.insert(image, at: 1)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let doc = try check(text, [.codeBlock(align: nil, language: nil, content: [.text("a", marks: []),
                                                                                    .image(sha: sha, name: "dot.png", mime: "image/png", width: nil)])])
        XCTAssertEqual(doc.attachments[sha]?.data, data)
    }

    func testDividerAndTableAreSiblings() throws {
        let text = code([("x", [:])])
        text.append(NSAttributedString(string: DocParagraphModel.dividerCharacter + "\n",
                                       attributes: [.font: bodyFont, .paragraphStyle: DocParagraphModel.paragraphStyle(for: .divider)]))
        let table = DocParagraphModel.makeTable(columns: 1)
        let block = DocParagraphModel.tableBlock(table: table, row: 0, column: 0, width: nil, header: false)
        text.append(NSAttributedString(string: "c\n", attributes: [.font: bodyFont, .paragraphStyle: DocParagraphModel.tableCellParagraph(block: block)]))
        try check(text, [.codeBlock(align: nil, language: nil, content: [.text("x", marks: [])]),
                         .horizontalRule,
                         .table(columnWidths: nil, rows: [[TableCell(header: false, content: [.paragraph(align: nil, indent: nil, content: [.text("c", marks: [])])])]])])
    }

    func testClearFormattingLeavesCode() throws {
        // A partial clear: the cleared run has the body font and keeps its link; the rest keeps the code font.
        let text = paragraph(.body, [("go", [.link: URL(string: "https://example.com/")!]),
                                     ("kept", [.font: codeFont, .underlineStyle: NSUnderlineStyle.single.rawValue])])
        try check(text, [.paragraph(align: nil, indent: nil, content: [.text("go", marks: [.link(href: "https://example.com/")]),
                                                                      .text("kept", marks: [.underline, .code])])])
    }

    func testTableRowCommandsLeaveCodeUnchanged() throws {
        let text = code([("x", [:])], language: CodeLanguage(identifier: "python"))
        try check(text, [.codeBlock(align: nil, language: "python", content: [.text("x", marks: [])])])
    }

    func testLanguageSurvivesEdit() throws {
        for language in ["swift", "zig-nightly"] {
            let doc = BodyContainer(doc: .doc([.codeBlock(align: nil, language: language, content: [.text("ab", marks: [])])]))
            let text = NSMutableAttributedString(attributedString: try DocConverter.importDocument(doc, styles: styles))
            text.insert(NSAttributedString(string: "x", attributes: text.attributes(at: 0, effectiveRange: nil)), at: 1)
            let back = try DocConverter.export(text, styles: styles)
            XCTAssertEqual(back.doc, .doc([.codeBlock(align: nil, language: language, content: [.text("axb", marks: [])])]), language)
        }
    }

    // MARK: - Fixtures

    private func code(_ runs: [(String, [NSAttributedString.Key: Any])], alignment: NSTextAlignment = .natural,
                      language: CodeLanguage? = nil) -> NSMutableAttributedString {
        let ps = DocParagraphModel.paragraphStyle(for: .code)
        ps.alignment = alignment
        var extra: [NSAttributedString.Key: Any] = [:]
        if let language {
            DocParagraphModel.setCodeLanguage(language, on: ps)
            extra[.noteItCodeLanguageID] = language.identifier
        }
        return build(runs, font: codeFont, style: ps, extra: extra)
    }

    private func paragraph(_ kind: BlockKind, _ runs: [(String, [NSAttributedString.Key: Any])],
                           alignment: NSTextAlignment = .natural) -> NSMutableAttributedString {
        let ps = DocParagraphModel.paragraphStyle(for: kind)
        ps.alignment = alignment
        return build(runs, font: styles.font(for: kind, size: 14), style: ps, extra: [:])
    }

    private func build(_ runs: [(String, [NSAttributedString.Key: Any])], font: NSFont, style: NSParagraphStyle,
                       extra: [NSAttributedString.Key: Any]) -> NSMutableAttributedString {
        var base: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: style]
        base.merge(extra) { $1 }
        let out = NSMutableAttributedString()
        for (string, attrs) in runs {
            out.append(NSAttributedString(string: string, attributes: base.merging(attrs) { $1 }))
        }
        out.append(NSAttributedString(string: "\n", attributes: base))
        return out
    }

    @discardableResult
    private func check(_ text: NSAttributedString, _ blocks: [DocNode], file: StaticString = #filePath, line: UInt = #line) throws -> BodyContainer {
        let doc = try DocConverter.export(text, styles: styles)
        XCTAssertEqual(doc.doc, .doc(blocks), file: file, line: line)
        let back = try DocConverter.importDocument(doc, styles: styles)
        XCTAssertEqual(SemanticText(back), SemanticText(text), file: file, line: line)
        return doc
    }

    private static func pngData() throws -> Data {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()
        let rep = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }
}

/// Test-only comparer: paragraphs, then each character's meaningful attributes, ignoring how AppKit happens to
/// split runs or which font object it picked.
struct SemanticText: Equatable, CustomStringConvertible {
    struct Paragraph: Equatable {
        var text: String
        var kind: BlockKind
        var alignment: NSTextAlignment
        var indent: Int
        var listLevel: Int
        var language: String?
        var inTable: Bool
        var characters: [String]
    }

    var paragraphs: [Paragraph] = []

    init(_ text: NSAttributedString) {
        let string = text.string as NSString
        var location = 0
        while location < string.length {
            let range = string.paragraphRange(for: NSRange(location: location, length: 0))
            let ps = text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            let font = text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            let kind = DocParagraphModel.blockKind(paragraphStyle: ps, font: font, baseSize: 14)
            var characters: [String] = []
            for i in range.location..<NSMaxRange(range) {
                characters.append(Self.signature(text.attributes(at: i, effectiveRange: nil)))
            }
            paragraphs.append(Paragraph(text: string.substring(with: range), kind: kind, alignment: ps?.alignment ?? .natural,
                                        indent: DocParagraphModel.indentLevel(of: ps, kind: kind),
                                        listLevel: DocParagraphModel.listLevel(of: ps),
                                        language: DocParagraphModel.codeLanguage(of: ps)?.identifier,
                                        inTable: !(ps?.textBlocks.isEmpty ?? true), characters: characters))
            location = NSMaxRange(range)
        }
    }

    var description: String {
        paragraphs.map { "\($0)" }.joined(separator: "\n")
    }

    private static func signature(_ attrs: [NSAttributedString.Key: Any]) -> String {
        var parts: [String] = []
        if let font = attrs[.font] as? NSFont {
            parts.append("font \(Int(font.pointSize * 2))")
            if DocParagraphModel.isMonospaced(font) { parts.append("mono") }
            if DocParagraphModel.isBold(font) { parts.append("bold") }
            if DocParagraphModel.isItalic(font) { parts.append("italic") }
        }
        if let u = attrs[.underlineStyle] as? Int, u != 0 { parts.append("underline") }
        if let s = attrs[.strikethroughStyle] as? Int, s != 0 { parts.append("strike") }
        if let c = (attrs[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB) { parts.append("fg \(hex(c))") }
        if let c = (attrs[.backgroundColor] as? NSColor)?.usingColorSpace(.sRGB) { parts.append("bg \(hex(c))") }
        if let link = attrs[.link] { parts.append("link \((link as? URL)?.absoluteString ?? "\(link)")") }
        if let id = attrs[.noteItCodeLanguageID] as? String { parts.append("lang \(id)") }
        if let attachment = attrs[.attachment] as? NSTextAttachment {
            let data = attachment.fileWrapper?.regularFileContents ?? attachment.contents ?? Data()
            parts.append("attachment \(attachment.fileWrapper?.preferredFilename ?? "") \(SHA256.hash(data: data).description)")
        }
        return parts.joined(separator: ",")
    }

    private static func hex(_ c: NSColor) -> String {
        String(format: "%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()),
               Int((c.blueComponent * 255).rounded()))
    }
}
