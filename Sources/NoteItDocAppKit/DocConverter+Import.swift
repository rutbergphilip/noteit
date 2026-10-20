import AppKit
import NoteItDoc

/// noteit-doc → NSAttributedString, with the attributes the editor itself would write. Built in foundations
/// Task 2.3; the rules are web-app spec §3.3.
struct DocImporter {
    let styles: DocStyleProvider
    let attachments: [String: Attachment]
    private let base: CGFloat
    private let out = NSMutableAttributedString()

    init(styles: DocStyleProvider, attachments: [String: Attachment]) {
        self.styles = styles
        self.attachments = attachments
        base = styles.baseFontSize
    }

    mutating func run(_ doc: DocNode) throws -> NSAttributedString {
        guard case .doc(let blocks) = doc else { throw DocConversionError("The document root isn't a doc node") }
        for block in blocks { try append(block) }
        return out
    }

    private func append(_ block: DocNode) throws {
        switch block {
        case .doc:
            throw DocConversionError("A doc node inside the document")
        case .paragraph(let align, let indent, let content):
            let ps = DocParagraphModel.paragraphStyle(for: .body, indentLevel: indent ?? 0)
            ps.alignment = ConverterSupport.alignment(align)
            try appendParagraph(content, kind: .body, style: ps)
        case .heading(let level, let align, let indent, let content):
            let kinds: [BlockKind] = [.title, .heading, .subheading]
            guard (1...3).contains(level) else { throw DocConversionError("Heading level \(level) is out of range") }
            let kind = kinds[level - 1]
            let ps = DocParagraphModel.paragraphStyle(for: kind, indentLevel: indent ?? 0)
            ps.alignment = ConverterSupport.alignment(align)
            try appendParagraph(content, kind: kind, style: ps)
        case .codeBlock(let align, let language, let content):
            let ps = DocParagraphModel.paragraphStyle(for: .code)
            ps.alignment = ConverterSupport.alignment(align)
            var extra: [NSAttributedString.Key: Any] = [:]
            if let language {
                DocParagraphModel.setCodeLanguage(CodeLanguage(identifier: language), on: ps)
                extra[.noteItCodeLanguageID] = language
            }
            try appendParagraph(content, kind: .code, style: ps, extra: extra)
        case .blockquote(let indent, let content):
            for child in content {
                guard case .paragraph(let align, _, let inlines) = child else {
                    throw DocConversionError("A blockquote holds something other than paragraphs")
                }
                let ps = DocParagraphModel.paragraphStyle(for: .quote, indentLevel: indent ?? 0)
                ps.alignment = ConverterSupport.alignment(align)
                try appendParagraph(inlines, kind: .quote, style: ps)
            }
        case .horizontalRule:
            let attrs: [NSAttributedString.Key: Any] = [.font: styles.font(for: .divider, size: base),
                                                        .paragraphStyle: DocParagraphModel.paragraphStyle(for: .divider)]
            out.append(NSAttributedString(string: DocParagraphModel.dividerCharacter + "\n", attributes: attrs))
        case .listItem(let kind, let level, let number, let checked, let align, let content):
            let ps = DocParagraphModel.listParagraphStyle(level: max(0, level))
            ps.alignment = ConverterSupport.alignment(align)
            let marker: DocParagraphModel.Marker.Kind
            switch kind {
            case .bullet: marker = .bullet
            case .ordered: marker = .numbered(number ?? 1)
            case .task: marker = .checkbox(checked: checked ?? false)
            }
            let markerAttrs: [NSAttributedString.Key: Any] = [.font: styles.font(for: .body, size: base), .paragraphStyle: ps]
            out.append(NSAttributedString(string: DocParagraphModel.markerText(marker, level: max(0, level)), attributes: markerAttrs))
            try appendParagraph(content, kind: .body, style: ps, checked: kind == .task && checked == true)
        case .table(let columnWidths, let rows):
            let columns = rows.map(\.count).max() ?? 0
            guard columns > 0 else { return }
            let table = DocParagraphModel.makeTable(columns: columns)
            let widths = columnWidths?.count == columns ? columnWidths : nil
            for (r, row) in rows.enumerated() {
                for (c, cell) in row.enumerated() {
                    let block = DocParagraphModel.tableBlock(table: table, row: r, column: c, width: widths.map { CGFloat($0[c]) },
                                                             header: cell.header)
                    let paragraphs = cell.content.isEmpty ? [DocNode.paragraph(align: nil, indent: nil, content: [])] : cell.content
                    for paragraph in paragraphs {
                        guard case .paragraph(let align, _, let inlines) = paragraph else {
                            throw DocConversionError("A table cell holds something other than paragraphs")
                        }
                        let ps = DocParagraphModel.tableCellParagraph(block: block)
                        ps.alignment = ConverterSupport.alignment(align)
                        try appendParagraph(inlines, kind: .body, style: ps)
                    }
                }
            }
        case .unknown(let type, _):
            throw DocConversionError("Unknown content \(type) can't be edited")
        }
    }

    private func appendParagraph(_ content: [Inline], kind: BlockKind, style: NSParagraphStyle,
                                 extra: [NSAttributedString.Key: Any] = [:], checked: Bool = false) throws {
        let blockFont = styles.font(for: kind, size: base)
        var baseAttrs: [NSAttributedString.Key: Any] = [.font: blockFont, .paragraphStyle: style]
        baseAttrs.merge(extra) { $1 }
        let start = out.length
        for inline in content {
            switch inline {
            case .text(let string, let marks):
                out.append(NSAttributedString(string: string, attributes: attributes(for: marks, kind: kind, base: baseAttrs)))
            case .hardBreak:
                out.append(NSAttributedString(string: "\u{2028}", attributes: baseAttrs))
            case .image(let sha, let name, _, let width):
                out.append(try attachmentString(sha: sha, name: name, width: width, attributes: baseAttrs))
            case .attachment(let sha, let name, _):
                out.append(try attachmentString(sha: sha, name: name, width: nil, attributes: baseAttrs))
            }
        }
        if checked, out.length > start {
            let range = NSRange(location: start, length: out.length - start)
            out.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            out.addAttribute(.foregroundColor, value: DocParagraphModel.checkedTextColor, range: range)
        }
        out.append(NSAttributedString(string: "\n", attributes: baseAttrs))
    }

    private func attributes(for marks: [Mark], kind: BlockKind, base baseAttrs: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        var attrs = baseAttrs
        var font = styles.font(for: kind, size: base)
        let isHeading = kind == .title || kind == .heading || kind == .subheading
        if kind != .code, marks.contains(.code) { font = styles.monospacedFont(size: base) }
        let fm = NSFontManager.shared
        for mark in marks {
            switch mark {
            case .bold where !isHeading: font = fm.convert(font, toHaveTrait: .boldFontMask)
            case .italic: font = Self.italic(font)
            case .underline: attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            case .strike: attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            case .link(let href):
                if let url = URL(string: href), url.absoluteString == href { attrs[.link] = url } else { attrs[.link] = href }
            case .textColor(let hex): attrs[.foregroundColor] = ConverterSupport.color(hex: hex)
            case .highlight(let hex): attrs[.backgroundColor] = ConverterSupport.color(hex: hex)
            case .bold, .code, .fontSize: break
            }
        }
        for case .fontSize(let delta) in marks {
            let size = min(96, max(8, font.pointSize + CGFloat(delta)))
            font = NSFont(descriptor: font.fontDescriptor, size: size) ?? font
        }
        attrs[.font] = font
        return attrs
    }

    /// The editor's italic: the font manager's conversion, or a synthesized slant from the descriptor when the face
    /// has no italic (monospaced system fonts on some systems).
    static func italic(_ font: NSFont) -> NSFont {
        let converted = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        if DocParagraphModel.isItalic(converted) { return converted }
        let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.italic))
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? converted
    }

    private func attachmentString(sha: String, name: String, width: Double?, attributes: [NSAttributedString.Key: Any]) throws -> NSAttributedString {
        guard let stored = attachments[sha] else { throw DocConversionError("Missing attachment \(name)") }
        let wrapper = FileWrapper(regularFileWithContents: stored.data)
        wrapper.preferredFilename = name
        let attachment = NSTextAttachment(fileWrapper: wrapper)
        if let width {
            var height = width
            if let image = NSImage(data: stored.data), image.size.width > 0 {
                height = width * image.size.height / image.size.width
            }
            attachment.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        }
        let string = NSMutableAttributedString(attachment: attachment)
        string.addAttributes(attributes, range: NSRange(location: 0, length: string.length))
        return string
    }
}
