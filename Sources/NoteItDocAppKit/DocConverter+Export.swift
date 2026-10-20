import AppKit
import NoteItDoc
import UniformTypeIdentifiers

/// NSAttributedString → noteit-doc. Built in foundations Task 2.3; the rules are web-app spec §3.3 and §3.5.
struct DocExporter {
    let text: NSAttributedString
    let styles: DocStyleProvider
    let imagePolicy: ImagePolicy
    private let ns: NSString
    private let base: CGFloat
    private var attachments: [String: Attachment] = [:]

    init(text: NSAttributedString, styles: DocStyleProvider, imagePolicy: ImagePolicy) {
        self.text = text
        self.styles = styles
        self.imagePolicy = imagePolicy
        ns = text.string as NSString
        base = styles.baseFontSize
    }

    private struct PendingQuote {
        var indent: Int?
        var paragraphs: [DocNode]
    }

    private struct PendingTable {
        var table: NSTextTable
        var cells: [(block: NSTextTableBlock, paragraph: DocNode)]
    }

    mutating func run() throws -> BodyContainer {
        var blocks: [DocNode] = []
        var quote: PendingQuote?
        var table: PendingTable?
        func flushQuote() {
            if let pending = quote { blocks.append(.blockquote(indent: pending.indent, content: pending.paragraphs)) }
            quote = nil
        }
        func flushTable() {
            if let pending = table { blocks.append(Self.tableNode(pending)) }
            table = nil
        }

        var location = 0
        while location < ns.length {
            let para = ns.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(para)
            let content = contentRange(of: para)
            let attrs = text.attributes(at: para.location, effectiveRange: nil)
            let ps = attrs[.paragraphStyle] as? NSParagraphStyle
            let align = ps.flatMap { ConverterSupport.align($0.alignment) }

            if let cell = ps?.textBlocks.lazy.compactMap({ $0 as? NSTextTableBlock }).first {
                flushQuote()
                if let pending = table, pending.table !== cell.table { flushTable() }
                let paragraph = DocNode.paragraph(align: align, indent: nil, content: try inlines(in: content, kind: .body, checked: false))
                if table == nil { table = PendingTable(table: cell.table, cells: []) }
                table?.cells.append((cell, paragraph))
                continue
            }
            flushTable()

            let kind = DocParagraphModel.blockKind(paragraphStyle: ps, font: attrs[.font] as? NSFont, baseSize: base)
            let indentLevel = DocParagraphModel.indentLevel(of: ps, kind: kind)
            let indent = indentLevel > 0 ? indentLevel : nil
            if kind == .quote {
                let paragraph = DocNode.paragraph(align: align, indent: nil, content: try inlines(in: content, kind: .quote, checked: false))
                if let pending = quote, pending.indent == indent {
                    quote?.paragraphs.append(paragraph)
                } else {
                    flushQuote()
                    quote = PendingQuote(indent: indent, paragraphs: [paragraph])
                }
                continue
            }
            flushQuote()

            switch kind {
            case .divider:
                blocks.append(.horizontalRule)
            case .code:
                let language = (attrs[.noteItCodeLanguageID] as? String) ?? DocParagraphModel.codeLanguage(of: ps)?.identifier
                blocks.append(.codeBlock(align: align, language: language, content: try inlines(in: content, kind: .code, checked: false)))
            case .title, .heading, .subheading:
                let level = kind == .title ? 1 : kind == .heading ? 2 : 3
                blocks.append(.heading(level: level, align: align, indent: indent, content: try inlines(in: content, kind: kind, checked: false)))
            case .body, .quote:
                if let marker = DocParagraphModel.listMarker(in: ns.substring(with: content)) {
                    let rest = NSRange(location: content.location + marker.length, length: content.length - marker.length)
                    let level = DocParagraphModel.listLevel(of: ps)
                    switch marker.kind {
                    case .bullet:
                        blocks.append(.listItem(kind: .bullet, level: level, number: nil, checked: nil, align: align,
                                                content: try inlines(in: rest, kind: .body, checked: false)))
                    case .numbered(let number):
                        blocks.append(.listItem(kind: .ordered, level: level, number: number, checked: nil, align: align,
                                                content: try inlines(in: rest, kind: .body, checked: false)))
                    case .checkbox(let checked):
                        blocks.append(.listItem(kind: .task, level: level, number: nil, checked: checked, align: align,
                                                content: try inlines(in: rest, kind: .body, checked: checked)))
                    }
                } else {
                    blocks.append(.paragraph(align: align, indent: indent, content: try inlines(in: content, kind: .body, checked: false)))
                }
            }
        }
        flushQuote()
        flushTable()
        return BodyContainer(doc: .doc(blocks), attachments: attachments)
    }

    private func contentRange(of para: NSRange) -> NSRange {
        var range = para
        while range.length > 0 {
            let c = ns.character(at: NSMaxRange(range) - 1)
            guard c == 10 || c == 13 || c == 0x2029 else { break }
            range.length -= 1
        }
        return range
    }

    private static func tableNode(_ pending: PendingTable) -> DocNode {
        var rows: [Int: [Int: TableCell]] = [:]
        var widths: [Int: Double] = [:]
        for (block, paragraph) in pending.cells {
            let row = block.startingRow, column = block.startingColumn
            if rows[row]?[column] == nil {
                rows[row, default: [:]][column] = TableCell(header: block.backgroundColor != nil, content: [])
            }
            rows[row]?[column]?.content.append(paragraph)
            if widths[column] == nil, block.valueType(for: .width) == .percentageValueType, block.value(for: .width) > 0 {
                widths[column] = Double(block.value(for: .width))
            }
        }
        let columns = rows.values.map { ($0.keys.max() ?? -1) + 1 }.max() ?? 0
        let columnWidths: [Double]? = columns > 0 && (0..<columns).allSatisfy({ widths[$0] != nil }) ? (0..<columns).map { widths[$0]! } : nil
        let cells = rows.keys.sorted().map { row in rows[row]!.keys.sorted().map { rows[row]![$0]! } }
        return .table(columnWidths: columnWidths, rows: cells)
    }

    // MARK: Inline content

    private mutating func inlines(in range: NSRange, kind: BlockKind, checked: Bool) throws -> [Inline] {
        var content: [Inline] = []
        func appendText(_ string: String, marks: [Mark]) {
            guard !string.isEmpty else { return }
            if case .text(let previous, let previousMarks)? = content.last, previousMarks == marks {
                content[content.count - 1] = .text(previous + string, marks: marks)
            } else {
                content.append(.text(string, marks: marks))
            }
        }
        var runs: [(NSRange, [NSAttributedString.Key: Any])] = []
        text.enumerateAttributes(in: range) { attrs, run, _ in runs.append((run, attrs)) }
        for (run, attrs) in runs {
            if let attachment = attrs[.attachment] as? NSTextAttachment {
                for _ in 0..<run.length {
                    if let inline = try attachmentInline(attachment) { content.append(inline) }
                }
                continue
            }
            let marks = marks(attrs, kind: kind, checked: checked)
            let pieces = ns.substring(with: run).components(separatedBy: "\u{2028}")
            var location = run.location
            for (index, piece) in pieces.enumerated() {
                if index > 0 {
                    content.append(isSoftBreak(at: location) ? .softBreak : .hardBreak)
                    location += 1
                }
                appendText(piece, marks: marks)
                location += (piece as NSString).length
            }
        }
        return content
    }

    /// Only a U+2028 whose `noteItSoftBreak` run is that one character: text typed next to it may have inherited it.
    private func isSoftBreak(at location: Int) -> Bool {
        var run = NSRange()
        guard text.attribute(.noteItSoftBreak, at: location, longestEffectiveRange: &run,
                             in: NSRange(location: 0, length: text.length)) != nil else { return false }
        return run == NSRange(location: location, length: 1)
    }

    private func marks(_ attrs: [NSAttributedString.Key: Any], kind: BlockKind, checked: Bool) -> [Mark] {
        let blockFont = styles.font(for: kind, size: base)
        let font = (attrs[.font] as? NSFont) ?? blockFont
        let isHeading = kind == .title || kind == .heading || kind == .subheading
        let code = kind != .code && DocParagraphModel.isMonospaced(font) && !DocParagraphModel.isMonospaced(blockFont)
        var marks: [Mark] = []
        if !isHeading, DocParagraphModel.isBold(font) { marks.append(.bold) }
        if DocParagraphModel.isItalic(font) { marks.append(.italic) }
        if ((attrs[.underlineStyle] as? Int) ?? 0) != 0 { marks.append(.underline) }
        if !checked, ((attrs[.strikethroughStyle] as? Int) ?? 0) != 0 { marks.append(.strike) }
        if code { marks.append(.code) }
        if let url = attrs[.link] as? URL {
            marks.append(.link(href: url.absoluteString))
        } else if let href = attrs[.link] as? String {
            marks.append(.link(href: href))
        }
        if let color = attrs[.foregroundColor] as? NSColor, !(checked && DocParagraphModel.isCheckedGray(color)),
           let hex = ConverterSupport.hex(color) {
            marks.append(.textColor(hex))
        }
        if let color = attrs[.backgroundColor] as? NSColor, !DocParagraphModel.isLegacyInlineCodeBackground(color),
           let hex = ConverterSupport.hex(color) {
            marks.append(.highlight(hex))
        }
        let expected = code ? styles.monospacedFont(size: base).pointSize : blockFont.pointSize
        let delta = Int((font.pointSize - expected).rounded())
        if delta != 0 { marks.append(.fontSize(delta: delta)) }
        return marks
    }

    // MARK: Attachments

    private mutating func attachmentInline(_ attachment: NSTextAttachment) throws -> Inline? {
        var data: Data?
        var name: String?
        if let wrapper = attachment.fileWrapper, wrapper.isRegularFile {
            data = wrapper.regularFileContents
            name = wrapper.preferredFilename ?? wrapper.filename
        } else if let contents = attachment.contents {
            data = contents
        }
        if data == nil, let image = attachment.image, let tiff = image.tiffRepresentation {
            data = tiff
            name = name ?? "image.tiff"
        }
        guard var bytes = data else { return nil }
        var fileName = (name?.isEmpty == false ? name : nil) ?? "attachment"
        var mime = ConverterSupport.mime(forFileName: fileName) ?? sniffedMime(bytes)
        if (fileName as NSString).pathExtension.isEmpty, let ext = UTType(mimeType: mime)?.preferredFilenameExtension {
            fileName += "." + ext
        }
        if ConverterSupport.isImage(mime: mime) {
            let normalized = ImageNormalizer.normalized(bytes, mime: mime, policy: imagePolicy)
            if normalized.mime != mime, let ext = UTType(mimeType: normalized.mime)?.preferredFilenameExtension {
                fileName = ((fileName as NSString).deletingPathExtension as NSString).appendingPathExtension(ext) ?? fileName
            }
            bytes = normalized.data
            mime = normalized.mime
        }
        let sha = ConverterSupport.sha256(bytes)
        if attachments[sha] == nil { attachments[sha] = Attachment(mime: mime, name: fileName, data: bytes) }
        guard ConverterSupport.inlineImageTypes.contains(mime) else {
            return .attachment(sha: sha, name: fileName, mime: mime)
        }
        let width = attachment.bounds.width > 0 ? Double(attachment.bounds.width) : nil
        return .image(sha: sha, name: fileName, mime: mime, width: width)
    }

    private func sniffedMime(_ data: Data) -> String {
        if let source = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(source),
           let mime = UTType(type as String)?.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }
}
