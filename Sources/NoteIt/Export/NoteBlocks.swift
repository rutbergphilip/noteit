import AppKit
import NoteItCore
import UniformTypeIdentifiers

/// A run of text with the character formatting that export formats care about.
struct InlineRun {
    var text: String
    var bold = false
    var italic = false
    var underline = false
    var strikethrough = false
    var code = false
    var link: URL?
    var noteLink: NoteLink?
    var color: NSColor?
    var highlight: NSColor?
    var attachment: NSTextAttachment?

    /// Same formatting (ignoring text), so neighbouring runs can be merged.
    func hasSameStyle(as other: InlineRun) -> Bool {
        attachment == nil && other.attachment == nil
            && bold == other.bold && italic == other.italic && underline == other.underline
            && strikethrough == other.strikethrough && code == other.code && link == other.link && noteLink == other.noteLink
            && color == other.color && highlight == other.highlight
    }
}

/// A paragraph-level block of a note, classified with the editor's own rules (`EditorStyle`).
enum NoteBlock {
    /// Title, heading, subheading, body or quote. Line breaks inside the paragraph are U+2028.
    case paragraph(kind: BlockKind, alignment: NSTextAlignment, runs: [InlineRun])
    case listItem(marker: ListMarker.Kind, level: Int, alignment: NSTextAlignment, runs: [InlineRun])
    /// Consecutive code paragraphs, joined with "\n".
    /// `language` nil means Automatic (no info string on export).
    case code(String, language: CodeLanguage?)
    case divider
    /// Rows of cells; the first row is the header row. A cell with several paragraphs has U+2028 between them.
    case table(rows: [[[InlineRun]]])
}

@MainActor
enum NoteBlocks {
    nonisolated static let lineBreak = "\u{2028}"

    static func parse(_ text: NSAttributedString) -> [NoteBlock] {
        let ns = text.string as NSString
        var blocks: [NoteBlock] = []
        var codeLines: [String] = []
        var codeLanguage: CodeLanguage?
        var loc = 0

        func flushCode() {
            guard !codeLines.isEmpty else { return }
            blocks.append(.code(codeLines.joined(separator: "\n"), language: codeLanguage))
            codeLines = []
        }

        while loc < ns.length {
            let para = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            let attrs = text.attributes(at: para.location, effectiveRange: nil)
            let ps = attrs[.paragraphStyle] as? NSParagraphStyle
            loc = max(NSMaxRange(para), loc + 1)

            if let block = tableBlock(of: ps) {
                flushCode()
                let end = tableEnd(in: text, from: para, table: block.table)
                let range = NSRange(location: para.location, length: end - para.location)
                blocks.append(.table(rows: tableRows(in: text, range: range, table: block.table)))
                loc = end
                continue
            }

            let kind = EditorStyle.blockKind(paragraphStyle: ps, font: attrs[.font] as? NSFont)
            let content = contentRange(of: para, in: ns)
            let string = ns.substring(with: content)
            if kind == .code {
                let language = EditorStyle.codeLanguage(of: ps)
                if !codeLines.isEmpty, language != codeLanguage { flushCode() }
                if codeLines.isEmpty { codeLanguage = language }
                codeLines.append(string.replacingOccurrences(of: lineBreak, with: "\n"))
                continue
            }
            flushCode()
            let alignment = ps?.alignment ?? .natural
            if kind == .divider {
                blocks.append(.divider)
            } else if let marker = EditorStyle.listMarker(in: string) {
                let body = NSRange(location: content.location + marker.length, length: content.length - marker.length)
                var checked = false
                if case .checkbox(true) = marker.kind { checked = true }
                let runs = runs(in: text, range: body, kind: .body, checked: checked)
                guard hasContent(runs) else { continue }
                blocks.append(.listItem(marker: marker.kind, level: EditorStyle.listLevel(of: ps), alignment: alignment, runs: runs))
            } else {
                let runs = runs(in: text, range: content, kind: kind, checked: false)
                guard hasContent(runs) else { continue }
                blocks.append(.paragraph(kind: kind, alignment: alignment, runs: runs))
            }
        }
        flushCode()
        return blocks
    }

    static func hasContent(_ runs: [InlineRun]) -> Bool {
        runs.contains { $0.attachment != nil || !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Plain text of runs, with attachments left out.
    static func plainText(_ runs: [InlineRun]) -> String {
        runs.filter { $0.attachment == nil }.map(\.text).joined()
    }

    // MARK: Paragraphs

    private static func contentRange(of para: NSRange, in ns: NSString) -> NSRange {
        var r = para
        if r.length > 0 {
            let c = ns.character(at: NSMaxRange(r) - 1)
            if c == 10 || c == 13 || c == 0x2029 { r.length -= 1 }
        }
        return r
    }

    private static func runs(in text: NSAttributedString, range: NSRange, kind: BlockKind, checked: Bool, headerCell: Bool = false) -> [InlineRun] {
        guard range.length > 0 else { return [] }
        let piece = NSMutableAttributedString(attributedString: text.attributedSubstring(from: range))
        if checked { NoteItTextView.removeCheckedStyle(piece) }
        let ns = piece.string as NSString
        var result: [InlineRun] = []
        piece.enumerateAttributes(in: NSRange(location: 0, length: piece.length)) { attrs, r, _ in
            var run = InlineRun(text: ns.substring(with: r))
            if let attachment = attrs[.attachment] as? NSTextAttachment {
                run.attachment = attachment
                run.text = ""
                result.append(run)
                return
            }
            if let font = attrs[.font] as? NSFont {
                run.code = kind != .code && EditorStyle.isMonospaced(font)
                run.bold = !EditorStyle.isHeading(kind) && !headerCell && EditorStyle.isBold(font)
                run.italic = EditorStyle.isItalic(font)
            }
            run.underline = ((attrs[.underlineStyle] as? Int) ?? 0) != 0
            run.strikethrough = ((attrs[.strikethroughStyle] as? Int) ?? 0) != 0
            if let url = attrs[.link] as? URL {
                run.link = url
            } else if let s = attrs[.link] as? String {
                run.link = URL(string: s)
            }
            if let url = run.link, let noteLink = NoteLink(url: url) {
                run.noteLink = noteLink
                run.link = nil
            }
            run.color = attrs[.foregroundColor] as? NSColor
            if let bg = attrs[.backgroundColor] as? NSColor, !(run.code && EditorStyle.isLegacyInlineCodeBackground(bg)) {
                run.highlight = bg
            }
            if let last = result.last, last.hasSameStyle(as: run) {
                result[result.count - 1].text += run.text
            } else {
                result.append(run)
            }
        }
        return result
    }

    // MARK: Tables

    private static func tableBlock(of ps: NSParagraphStyle?) -> NSTextTableBlock? {
        ps?.textBlocks.compactMap { $0 as? NSTextTableBlock }.first
    }

    private static func tableEnd(in text: NSAttributedString, from para: NSRange, table: NSTextTable) -> Int {
        let ns = text.string as NSString
        var end = NSMaxRange(para)
        while end < ns.length {
            let next = ns.paragraphRange(for: NSRange(location: end, length: 0))
            let ps = text.attribute(.paragraphStyle, at: next.location, effectiveRange: nil) as? NSParagraphStyle
            guard tableBlock(of: ps)?.table === table else { break }
            end = NSMaxRange(next)
        }
        return end
    }

    private static func tableRows(in text: NSAttributedString, range: NSRange, table: NSTextTable) -> [[[InlineRun]]] {
        let ns = text.string as NSString
        var cells: [Int: [Int: [InlineRun]]] = [:]
        var rowCount = 0
        var columnCount = table.numberOfColumns
        var loc = range.location
        while loc < NSMaxRange(range) {
            let para = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            loc = max(NSMaxRange(para), loc + 1)
            let ps = text.attribute(.paragraphStyle, at: para.location, effectiveRange: nil) as? NSParagraphStyle
            guard let block = tableBlock(of: ps) else { continue }
            let row = block.startingRow, column = block.startingColumn
            rowCount = max(rowCount, row + 1)
            columnCount = max(columnCount, column + 1)
            let runs = runs(in: text, range: contentRange(of: para, in: ns), kind: .body, checked: false, headerCell: row == 0)
            if let existing = cells[row]?[column] {
                cells[row, default: [:]][column] = existing + [InlineRun(text: lineBreak)] + runs
            } else {
                cells[row, default: [:]][column] = runs
            }
        }
        return (0..<rowCount).map { r in (0..<columnCount).map { c in cells[r]?[c] ?? [] } }
    }
}

/// Image or file data referenced by an exported note.
struct ExportAsset: Equatable {
    var filename: String
    var data: Data
}

extension NSTextAttachment {
    /// The attachment's file name and contents, or a PNG of its image.
    var exportContents: (filename: String?, data: Data, isImage: Bool)? {
        if let wrapper = fileWrapper, wrapper.isRegularFile, let data = wrapper.regularFileContents {
            let name = wrapper.preferredFilename ?? wrapper.filename
            let ext = ((name ?? "") as NSString).pathExtension
            let isImage = ExportFileType.isImage(extension: ext) || (ext.isEmpty && NSImage(data: data) != nil)
            return (name, data, isImage)
        }
        let image = self.image ?? (attachmentCell as? NSTextAttachmentCell)?.image
        guard let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return ("image.png", png, true)
    }
}

enum ExportFileType {
    static func isImage(extension ext: String) -> Bool {
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image)
    }

    static func mimeType(extension ext: String) -> String {
        UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }
}

/// Links that are kept in exported files. Others, such as `javascript:`, are written as plain text.
enum ExportLinks {
    static let safeSchemes: Set<String> = ["http", "https", "mailto", "tel", "ftp"]

    /// True for links with a safe scheme, and for relative and fragment links.
    static func isSafe(_ url: URL) -> Bool {
        // Renderers decode references and percent escapes and drop hidden characters, so `java&Tab;script&colon;` is still script.
        var s = url.absoluteString
        for _ in 0..<4 {
            var next = CharacterReferences.decode(s, requireSemicolon: false)
            next = next.removingPercentEncoding ?? next
            next = String(String.UnicodeScalarView(next.unicodeScalars.filter { $0.value > 0x20 && $0.value != 0x7F }))
            if next == s { break }
            s = next
        }
        guard let colon = s.firstIndex(of: ":") else { return true }
        let scheme = s[..<colon]
        if scheme.contains(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { return true }
        return safeSchemes.contains(scheme.lowercased())
    }
}

/// Decodes HTML character references such as `&colon;`, `&#58;` and `&#x3A;`.
enum CharacterReferences {
    static let named: [String: String] = [
        "colon": ":", "tab": "\t", "newline": "\n", "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "sol": "/", "quest": "?", "num": "#", "period": ".", "lpar": "(", "rpar": ")", "nbsp": "\u{00A0}",
    ]

    static func decode(_ s: String, requireSemicolon: Bool) -> String {
        guard s.contains("&") else { return s }
        let chars = Array(s)
        var out = ""
        var i = 0
        while i < chars.count {
            if chars[i] == "&", let (text, end) = reference(chars, at: i + 1, requireSemicolon: requireSemicolon) {
                out += text
                i = end
            } else {
                out.append(chars[i])
                i += 1
            }
        }
        return out
    }

    static func reference(_ chars: [Character], at start: Int, requireSemicolon: Bool) -> (String, Int)? {
        var j = start
        var value: String?
        if j < chars.count, chars[j] == "#" {
            j += 1
            var radix = 10
            if j < chars.count, chars[j] == "x" || chars[j] == "X" { radix = 16; j += 1 }
            let digitsStart = j
            while j < chars.count, chars[j].isASCII, chars[j].isHexDigit, radix == 16 || chars[j].isNumber { j += 1 }
            guard j > digitsStart, j - digitsStart <= 8, let code = UInt32(String(chars[digitsStart..<j]), radix: radix) else { return nil }
            value = String(Unicode.Scalar(code).map(Character.init) ?? "\u{FFFD}")
        } else {
            let nameStart = j
            while j < chars.count, chars[j].isASCII, chars[j].isLetter || chars[j].isNumber { j += 1 }
            guard j > nameStart, let text = named[String(chars[nameStart..<j]).lowercased()] else { return nil }
            value = text
        }
        if j < chars.count, chars[j] == ";" { j += 1 } else if requireSemicolon { return nil }
        return value.map { ($0, j) }
    }
}
