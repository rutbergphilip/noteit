import AppKit

/// The front matter fields NoteIt uses; everything else is dropped.
struct MarkdownFrontMatter: Equatable {
    var title: String?
    var tags: [String] = []
    var created: Date?
    var updated: Date?
}

struct MarkdownNote {
    var title: String
    var body: NSAttributedString
    var frontMatter: MarkdownFrontMatter
}

/// Markdown → NoteIt rich text, built with the editor's own block styles so imported notes behave
/// exactly like typed ones. The inverse of the export mapping:
///
/// - `#` title, `##` heading, `###`–`######` subheading; `**`/`__`, `*`/`_`, `~~`, `` ` ``, `[text](url)`
/// - `- `, `* `, `+ ` bullets, `1. ` numbered, `- [ ] ` / `- [x] ` checklist, nested by indentation
/// - `> ` quote, fenced code, `---` divider, GFM tables, `![](path)` and `![[image.png]]`
/// - Obsidian `[[Note]]` and `[[Note|alias]]` become plain text.
///
/// Lines without a blank line between them are one paragraph, with a line break between the lines, as
/// Obsidian shows them. Blank lines only separate blocks, however many there are.
enum MarkdownReader {
    /// Returns the file for an image reference (a relative path or an Obsidian file name), or nil.
    typealias ImageResolver = (String) -> URL?

    /// A full note: the title comes from front matter, a leading `#` heading or `fallbackTitle`, and
    /// front matter tags are added as a last line of hashtags.
    @MainActor
    static func note(from markdown: String, fallbackTitle: String, resolveImage: @escaping ImageResolver = { _ in nil }) -> MarkdownNote {
        let (frontMatter, content) = splitFrontMatter(markdown)
        let body = NSMutableAttributedString(attributedString: attributedString(from: content, resolveImage: resolveImage))
        let first = firstParagraph(of: body)

        let title: String
        if let fmTitle = frontMatter.title, !fmTitle.isEmpty {
            title = fmTitle
            if !(first?.kind == .title && first?.text.caseInsensitiveCompare(fmTitle) == .orderedSame) {
                body.insert(EditorStyle.paragraph(fmTitle, kind: .title), at: 0)
            }
        } else if let first, first.kind == .title {
            title = first.text
        } else {
            title = fallbackTitle
            if !fallbackTitle.isEmpty { body.insert(EditorStyle.paragraph(fallbackTitle, kind: .title), at: 0) }
        }

        let existing = Set(NoteStore.parseTags(body))
        let missing = frontMatter.tags.filter { !existing.contains($0.lowercased()) }
        if !missing.isEmpty {
            if body.length > 0, !body.string.hasSuffix("\n") {
                body.append(NSAttributedString(string: "\n", attributes: EditorStyle.bodyAttributes))
            }
            body.append(EditorStyle.paragraph(missing.map { "#" + $0 }.joined(separator: " "), kind: .body))
        }
        return MarkdownNote(title: title, body: body, frontMatter: frontMatter)
    }

    /// Markdown without front matter handling → NoteIt body.
    @MainActor
    static func attributedString(from markdown: String, resolveImage: @escaping ImageResolver = { _ in nil }) -> NSAttributedString {
        var builder = BlockBuilder(resolveImage: resolveImage)
        builder.parse(lines(of: markdown))
        let ts = NSTextStorage(attributedString: builder.output)
        if ts.length > 0 { NoteItTextView.normalize(ts, around: NSRange(location: 0, length: ts.length)) }
        return NSAttributedString(attributedString: ts)
    }

    // MARK: Front matter

    static func splitFrontMatter(_ markdown: String) -> (MarkdownFrontMatter, String) {
        let all = lines(of: markdown)
        guard let first = all.first, first.trimmingCharacters(in: .whitespaces) == "---" else {
            return (MarkdownFrontMatter(), markdown)
        }
        guard let end = all.dropFirst().firstIndex(where: {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t == "---" || t == "..."
        }) else { return (MarkdownFrontMatter(), markdown) }
        var fm = MarkdownFrontMatter()
        for (key, values) in parseYAML(Array(all[1..<end])) {
            switch key {
            case "title":
                fm.title = values.first.map(unquote)
            case "tags", "tag":
                fm.tags += values.flatMap(splitTags)
            case "created", "date", "created_at", "creation_date", "date created":
                fm.created = values.first.flatMap { date(from: unquote($0)) }
            case "updated", "modified", "updated_at", "last_modified", "date modified":
                fm.updated = values.first.flatMap { date(from: unquote($0)) }
            default:
                break
            }
        }
        var seen = Set<String>()
        fm.tags = fm.tags.filter { seen.insert($0.lowercased()).inserted }
        return (fm, all[(end + 1)...].joined(separator: "\n"))
    }

    /// Top-level `key: value` pairs; a key followed by `- item` lines gets each item.
    private static func parseYAML(_ lines: [String]) -> [(String, [String])] {
        var result: [(String, [String])] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if trimmed.hasPrefix("- "), !result.isEmpty {
                result[result.count - 1].1.append(String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                continue
            }
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            result.append((key, value.isEmpty ? [] : [value]))
        }
        return result
    }

    private static func unquote(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.count >= 2, let f = t.first, let l = t.last, (f == "\"" && l == "\"") || (f == "'" && l == "'") {
            t = String(t.dropFirst().dropLast())
        }
        return t
    }

    private static func splitTags(_ value: String) -> [String] {
        var v = value.trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("["), v.hasSuffix("]") { v = String(v.dropFirst().dropLast()) }
        return v.split(whereSeparator: { $0 == "," || $0 == " " })
            .map { unquote(String($0)) }
            .map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 }
            .filter { !$0.isEmpty }
    }

    /// ISO 8601 dates and date-times, with or without seconds or a time zone (local time if none).
    static func date(from string: String) -> Date? {
        let s = string.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
            iso.formatOptions = options
            if let d = iso.date(from: s) { return d }
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd", "yyyy/MM/dd"] {
            formatter.dateFormat = format
            if let d = formatter.date(from: s) { return d }
        }
        return nil
    }

    // MARK: Helpers

    static func lines(of text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    private static func firstParagraph(of text: NSAttributedString) -> (kind: BlockKind, text: String)? {
        let ns = text.string as NSString
        var location = 0
        while location < ns.length {
            let para = ns.paragraphRange(for: NSRange(location: location, length: 0))
            let line = ns.substring(with: para).trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty {
                let ps = text.attribute(.paragraphStyle, at: para.location, effectiveRange: nil) as? NSParagraphStyle
                let font = text.attribute(.font, at: para.location, effectiveRange: nil) as? NSFont
                return (EditorStyle.blockKind(paragraphStyle: ps, font: font), line)
            }
            location = NSMaxRange(para)
        }
        return nil
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "tif", "tiff", "bmp", "webp", "svg"]

    static func isImagePath(_ path: String) -> Bool {
        imageExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// An image attachment like the editor's Insert Image makes.
    static func attachment(for url: URL) -> NSTextAttachment? {
        guard let wrapper = try? FileWrapper(url: url, options: .immediate) else { return nil }
        wrapper.preferredFilename = url.lastPathComponent
        return NSTextAttachment(fileWrapper: wrapper)
    }
}

// MARK: - Blocks

@MainActor
private struct BlockBuilder {
    let resolveImage: MarkdownReader.ImageResolver
    let output = NSMutableAttributedString()

    private var listIndents: [Int] = []
    private var listCounters: [Int: Int] = [:]
    private var lastWasTable = false

    init(resolveImage: @escaping MarkdownReader.ImageResolver) {
        self.resolveImage = resolveImage
    }

    private static let heading = try! NSRegularExpression(pattern: "^ {0,3}(#{1,6})(?:[ \\t]+(.*?))?(?:[ \\t]+#+)?[ \\t]*$")
    private static let divider = try! NSRegularExpression(pattern: "^ {0,3}([-*_])(?:[ \\t]*\\1){2,}[ \\t]*$")
    private static let fence = try! NSRegularExpression(pattern: "^([ \\t]*)(`{3,}|~{3,})(.*)$")
    private static let listItem = try! NSRegularExpression(pattern: "^([ \\t]*)([-*+]|\\d{1,9}[.)])(?:[ \\t]+(.*))?$")
    private static let task = try! NSRegularExpression(pattern: "^\\[([ xX])\\](?:[ \\t]+(.*))?$")
    private static let tableSeparator = try! NSRegularExpression(pattern: "^[ \\t]*\\|?[ \\t]*:?-+:?[ \\t]*(\\|[ \\t]*:?-+:?[ \\t]*)*\\|?[ \\t]*$")
    private static let setextUnderline = try! NSRegularExpression(pattern: "^ {0,3}(=+|-+)[ \\t]*$")

    mutating func parse(_ lines: [String]) {
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                i += 1
                continue
            }

            if let m = Self.match(Self.fence, line) {
                let indent = Self.width(Self.group(m, 1, line))
                let marker = Self.group(m, 2, line)
                var code: [String] = []
                i += 1
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix(marker), t.allSatisfy({ $0 == marker.first }) { i += 1; break }
                    code.append(Self.dropIndent(lines[i], upTo: indent))
                    i += 1
                }
                beginBlock(list: false)
                for codeLine in code.isEmpty ? [""] : code {
                    output.append(NSAttributedString(string: codeLine + "\n", attributes: EditorStyle.attributes(for: .code)))
                }
                continue
            }

            if Self.match(Self.divider, line) != nil {
                beginBlock(list: false)
                output.append(EditorStyle.divider())
                i += 1
                continue
            }

            if let m = Self.match(Self.heading, line) {
                let level = Self.group(m, 1, line).count
                let text = Self.group(m, 2, line)
                beginBlock(list: false)
                if !text.isEmpty {
                    let kind: BlockKind = level == 1 ? .title : level == 2 ? .heading : .subheading
                    appendParagraph(text, kind: kind)
                }
                i += 1
                continue
            }

            if let text = Self.quoteContent(line) {
                i += 1
                // A `>` line with nothing after it separates quote paragraphs.
                guard !text.isEmpty else { continue }
                var texts = [text]
                while i < lines.count {
                    if let next = Self.quoteContent(lines[i]) {
                        guard !next.isEmpty else { break }
                        texts.append(next)
                    } else if Self.startsBlock(lines, at: i) {
                        break
                    } else {
                        texts.append(lines[i].trimmingCharacters(in: .whitespaces))
                    }
                    i += 1
                }
                beginBlock(list: false)
                appendParagraph(Self.joinLines(texts), kind: .quote)
                continue
            }

            if Self.startsTable(lines, at: i) {
                let header = Self.cells(of: line)
                let alignments = Self.cells(of: lines[i + 1]).map(Self.alignment)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(Self.cells(of: lines[i]))
                    i += 1
                }
                beginBlock(list: false)
                appendTable(header: header, rows: rows, alignments: alignments)
                lastWasTable = true
                continue
            }

            if let m = Self.match(Self.listItem, line) {
                let indent = Self.width(Self.group(m, 1, line))
                let marker = Self.group(m, 2, line)
                var text = Self.group(m, 3, line)
                beginBlock(list: true)
                let level = listLevel(forIndent: indent)
                listCounters = listCounters.filter { $0.key <= level }
                let kind: ListMarker.Kind
                var checked = false
                if let first = marker.first, "-*+".contains(first) {
                    if let t = Self.match(Self.task, text) {
                        checked = Self.group(t, 1, text) != " "
                        kind = .checkbox(checked: checked)
                        text = Self.group(t, 2, text)
                    } else {
                        kind = .bullet
                    }
                    listCounters[level] = nil
                } else {
                    let n = listCounters[level].map { $0 + 1 } ?? Int(marker.dropLast()) ?? 1
                    listCounters[level] = n
                    kind = .numbered(n)
                }
                i += 1
                let texts = [text] + continuationLines(lines, from: &i)
                appendListItem(Self.joinLines(texts), kind: kind, level: level, checked: checked)
                continue
            }

            let indent = Self.width(Self.leadingWhitespace(line))
            if !listIndents.isEmpty, indent > 0 {
                let level = listLevel(forIndent: indent, push: false) + 1
                beginBlock(list: true)
                i += 1
                appendParagraph(Self.joinLines([trimmed] + continuationLines(lines, from: &i)), kind: .body, indentLevel: level)
            } else {
                beginBlock(list: false)
                i += 1
                var texts = [trimmed]
                var kind = BlockKind.body
                while i < lines.count {
                    if let m = Self.match(Self.setextUnderline, lines[i]) {
                        kind = Self.group(m, 1, lines[i]).hasPrefix("=") ? .title : .heading
                        i += 1
                        break
                    }
                    guard !Self.startsBlock(lines, at: i, interruptingParagraph: true) else { break }
                    texts.append(lines[i].trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                appendParagraph(Self.joinLines(texts, keepBreaks: kind == .body), kind: kind)
            }
        }
        // Like Insert Table: a table at the end gets a line after it.
        if lastWasTable {
            output.append(NSAttributedString(string: "\n", attributes: EditorStyle.bodyAttributes))
        }
    }

    /// Ends a list unless `list`.
    private mutating func beginBlock(list: Bool) {
        lastWasTable = false
        if !list {
            listIndents = []
            listCounters = [:]
        }
    }

    /// The lines after `i` that continue the current paragraph, trimmed; `i` moves past them.
    private func continuationLines(_ lines: [String], from i: inout Int) -> [String] {
        var texts: [String] = []
        while i < lines.count, !Self.startsBlock(lines, at: i) {
            texts.append(lines[i].trimmingCharacters(in: .whitespaces))
            i += 1
        }
        return texts
    }

    private mutating func listLevel(forIndent indent: Int, push: Bool = true) -> Int {
        while let last = listIndents.last, last > indent { listIndents.removeLast() }
        if push, listIndents.last.map({ indent > $0 }) ?? true { listIndents.append(indent) }
        return max(0, listIndents.count - 1)
    }

    // MARK: Paragraphs

    private func appendParagraph(_ text: String, kind: BlockKind, indentLevel: Int = 0) {
        let font = EditorStyle.font(for: kind)
        let content = InlineParser(baseFont: font, resolveImage: resolveImage).parse(Self.stripHardBreak(text))
        content.append(NSAttributedString(string: "\n", attributes: [.font: font]))
        content.addAttribute(.paragraphStyle, value: EditorStyle.paragraphStyle(for: kind, indentLevel: indentLevel),
                             range: NSRange(location: 0, length: content.length))
        output.append(content)
    }

    private func appendListItem(_ text: String, kind: ListMarker.Kind, level: Int, checked: Bool) {
        let item = NSMutableAttributedString(string: EditorStyle.markerText(kind, level: level), attributes: EditorStyle.markerAttributes(level: level))
        let content = InlineParser(baseFont: EditorStyle.bodyFont, resolveImage: resolveImage).parse(Self.stripHardBreak(text))
        content.append(NSAttributedString(string: "\n", attributes: [.font: EditorStyle.bodyFont]))
        if checked { NoteItTextView.applyCheckedStyle(content) }
        item.append(content)
        item.addAttribute(.paragraphStyle, value: EditorStyle.listParagraphStyle(level: level), range: NSRange(location: 0, length: item.length))
        output.append(item)
    }

    /// Built with `EditorStyle.table`, then each cell's text is swapped for its formatted version.
    private func appendTable(header: [String], rows: [[String]], alignments: [NSTextAlignment]) {
        let columns = header.count
        let fitted = rows.map { row in (0..<columns).map { $0 < row.count ? row[$0] : "" } }
        let plain = InlineParser(baseFont: EditorStyle.bodyFont, resolveImage: { _ in nil })
        let table = NSMutableAttributedString(attributedString: EditorStyle.table(
            header: header.map { plain.parse($0).string },
            rows: fitted.map { $0.map { plain.parse($0).string } }
        ))
        var location = 0
        for row in [header] + fitted {
            for (c, raw) in row.enumerated() {
                let para = (table.string as NSString).paragraphRange(for: NSRange(location: location, length: 0))
                let attrs = table.attributes(at: para.location, effectiveRange: nil)
                let font = (attrs[.font] as? NSFont) ?? EditorStyle.bodyFont
                guard let ps = (attrs[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { continue }
                ps.alignment = alignments[c]
                let content = InlineParser(baseFont: font, resolveImage: resolveImage).parse(raw)
                content.append(NSAttributedString(string: "\n", attributes: [.font: font]))
                content.addAttribute(.paragraphStyle, value: ps, range: NSRange(location: 0, length: content.length))
                table.replaceCharacters(in: para, with: content)
                location = para.location + content.length
            }
        }
        output.append(table)
    }

    // MARK: Line helpers

    private static func match(_ regex: NSRegularExpression, _ line: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length))
    }

    private static func group(_ m: NSTextCheckingResult, _ index: Int, _ line: String) -> String {
        let r = m.range(at: index)
        return r.location == NSNotFound ? "" : (line as NSString).substring(with: r)
    }

    private static func leadingWhitespace(_ line: String) -> String {
        String(line.prefix { $0 == " " || $0 == "\t" })
    }

    /// Indentation width, with tabs counting as four spaces.
    private static func width(_ whitespace: String) -> Int {
        whitespace.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
    }

    private static func dropIndent(_ line: String, upTo indent: Int) -> String {
        var removed = 0
        var index = line.startIndex
        while index < line.endIndex, removed < indent, line[index] == " " || line[index] == "\t" {
            removed += line[index] == "\t" ? 4 : 1
            index = line.index(after: index)
        }
        return String(line[index...])
    }

    /// Whether line `i` is blank or starts a block, which ends the paragraph above it. A paragraph can
    /// only be interrupted by a numbered item that starts at 1 and a list item with text, as in CommonMark.
    private static func startsBlock(_ lines: [String], at i: Int, interruptingParagraph: Bool = false) -> Bool {
        let line = lines[i]
        if line.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        if match(fence, line) != nil || match(divider, line) != nil || match(heading, line) != nil { return true }
        if quoteContent(line) != nil || startsTable(lines, at: i) { return true }
        guard let m = match(listItem, line) else { return false }
        guard interruptingParagraph else { return true }
        let marker = group(m, 2, line)
        return !group(m, 3, line).trimmingCharacters(in: .whitespaces).isEmpty
            && (marker.first.map { "-*+".contains($0) } ?? false || marker.dropLast() == "1")
    }

    private static func startsTable(_ lines: [String], at i: Int) -> Bool {
        guard i + 1 < lines.count, lines[i].contains("|"), lines[i + 1].contains("|"),
              match(tableSeparator, lines[i + 1]) != nil else { return false }
        return cells(of: lines[i]).count == cells(of: lines[i + 1]).count
    }

    /// The text of a `>` line without its markers, or nil if it isn't one.
    private static func quoteContent(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(">"), width(leadingWhitespace(line)) < 4 else { return nil }
        var content = Substring(trimmed)
        while content.first == ">" {
            content = content.dropFirst()
            if content.first == " " { content = content.dropFirst() }
        }
        return content.trimmingCharacters(in: .whitespaces)
    }

    /// The lines of one paragraph, with a line break between them (or a space in a heading).
    private static func joinLines(_ lines: [String], keepBreaks: Bool = true) -> String {
        lines.map(stripHardBreak).joined(separator: keepBreaks ? NoteBlocks.lineBreak : " ")
    }

    private static func stripHardBreak(_ text: String) -> String {
        var t = text
        while t.hasSuffix(" ") { t.removeLast() }
        if t.hasSuffix("\\"), !t.hasSuffix("\\\\") { t.removeLast() }
        return t
    }

    /// Cells of a pipe-table row, split on `|` outside code spans; `\|` is a literal pipe.
    private static func cells(of line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|"), !t.hasSuffix("\\|") { t.removeLast() }
        var result: [String] = []
        var current = ""
        var inCode = false
        var escaped = false
        for ch in t {
            if escaped {
                current.append(ch == "|" ? "|" : "\\\(ch)")
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "`" {
                inCode.toggle()
                current.append(ch)
            } else if ch == "|", !inCode {
                result.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
        }
        if escaped { current.append("\\") }
        result.append(current.trimmingCharacters(in: .whitespaces))
        return result
    }

    private static func alignment(_ separator: String) -> NSTextAlignment {
        let left = separator.hasPrefix(":")
        let right = separator.hasSuffix(":")
        if left && right { return .center }
        if right { return .right }
        return .natural
    }
}

// MARK: - Inline

@MainActor
private struct InlineParser {
    struct Style {
        var bold = false
        var italic = false
        var strike = false
        var highlight = false
        var link: URL?
    }

    let baseFont: NSFont
    let resolveImage: MarkdownReader.ImageResolver

    func parse(_ text: String) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        append(Array(text), style: Style(), to: out)
        return out
    }

    private func attributes(_ style: Style) -> [NSAttributedString.Key: Any] {
        let fm = NSFontManager.shared
        var font = baseFont
        if style.bold { font = fm.convert(font, toHaveTrait: .boldFontMask) }
        if style.italic { font = fm.convert(font, toHaveTrait: .italicFontMask) }
        var attrs: [NSAttributedString.Key: Any] = [.font: font]
        if style.strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if style.highlight { attrs[.backgroundColor] = EditorStyle.highlightColors[0].color }
        if let link = style.link { attrs[.link] = link }
        return attrs
    }

    private static func webURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), let scheme = url.scheme, scheme.count > 1 else { return nil }
        return url
    }

    /// Text parsed before emphasis is matched, drawn with the style it ends up with.
    private enum Item {
        case piece((Style) -> NSAttributedString)
        case delimiter(Delimiter)
    }

    /// A run of `*`, `_`, `~~` or `==` that may open or close emphasis.
    private struct Delimiter {
        let char: Character
        let length: Int
        var count: Int
        var canOpen: Bool
        var canClose: Bool
    }

    private func append(_ chars: [Character], style: Style, to out: NSMutableAttributedString) {
        var items: [Item] = []
        var buffer = ""
        func flush() {
            guard !buffer.isEmpty else { return }
            let text = buffer
            items.append(.piece { NSAttributedString(string: text, attributes: attributes($0)) })
            buffer = ""
        }
        func appendLink(_ text: String, _ url: URL) {
            flush()
            items.append(.piece { style in
                var linkStyle = style
                linkStyle.link = url
                return NSAttributedString(string: text, attributes: attributes(linkStyle))
            })
        }
        func appendAttachment(_ attachment: NSTextAttachment) {
            flush()
            items.append(.piece { style in
                let piece = NSMutableAttributedString(attachment: attachment)
                var attrs = attributes(style)
                attrs[.link] = nil
                piece.addAttributes(attrs, range: NSRange(location: 0, length: piece.length))
                return piece
            })
        }

        var i = 0
        while i < chars.count {
            let c = chars[i]

            if c == "\\", i + 1 < chars.count, chars[i + 1].isASCII, chars[i + 1].isPunctuation || chars[i + 1].isSymbol {
                buffer.append(chars[i + 1])
                i += 2
                continue
            }

            if c == "`" {
                let run = Self.runLength(chars, i)
                if let close = Self.findCodeClose(chars, from: i + run, run: run) {
                    flush()
                    var code = String(chars[(i + run)..<close])
                    if code.count >= 2, code.hasPrefix(" "), code.hasSuffix(" "), code.contains(where: { $0 != " " }) {
                        code = String(code.dropFirst().dropLast())
                    }
                    items.append(.piece { style in
                        var attrs = attributes(style)
                        attrs.merge(EditorStyle.inlineCodeAttributes) { $1 }
                        return NSAttributedString(string: code, attributes: attrs)
                    })
                    i = close + run
                } else {
                    buffer.append(String(repeating: "`", count: run))
                    i += run
                }
                continue
            }

            if c == "!", Self.hasPrefix(chars, i + 1, "[["), let close = Self.find(chars, "]]", from: i + 3) {
                let inner = String(chars[(i + 3)..<close])
                let target = inner.split(separator: "|", maxSplits: 1).first.map(String.init) ?? inner
                if MarkdownReader.isImagePath(target), let url = resolveImage(target), let attachment = MarkdownReader.attachment(for: url) {
                    appendAttachment(attachment)
                } else {
                    buffer += Self.wikiText(inner)
                }
                i = close + 2
                continue
            }

            if c == "[", Self.hasPrefix(chars, i, "[["), let close = Self.find(chars, "]]", from: i + 2) {
                buffer += Self.wikiText(String(chars[(i + 2)..<close]))
                i = close + 2
                continue
            }

            if c == "!", i + 1 < chars.count, chars[i + 1] == "[", let link = Self.parseLink(chars, at: i + 1) {
                let alt = String(chars[link.text])
                if let url = Self.webURL(link.destination) {
                    appendLink(alt.isEmpty ? link.destination : alt, url)
                } else if let url = resolveImage(link.destination), let attachment = MarkdownReader.attachment(for: url) {
                    appendAttachment(attachment)
                } else {
                    buffer += alt
                }
                i = link.end
                continue
            }

            if c == "[", let link = Self.parseLink(chars, at: i) {
                flush()
                let text = Array(chars[link.text])
                let url = Self.webURL(link.destination)
                items.append(.piece { style in
                    var inner = style
                    if let url { inner.link = url }
                    let piece = NSMutableAttributedString()
                    append(text, style: inner, to: piece)
                    return piece
                })
                i = link.end
                continue
            }

            if c == "<", let close = chars[(i + 1)...].firstIndex(of: ">") {
                let candidate = String(chars[(i + 1)..<close])
                if ["br", "br/", "br /"].contains(candidate.lowercased()) {
                    buffer += NoteBlocks.lineBreak
                    i = close + 1
                    continue
                }
                if !candidate.contains(" "), candidate.contains(":"), let url = Self.webURL(candidate) {
                    appendLink(candidate, url)
                    i = close + 1
                    continue
                }
            }

            if style.link == nil, c == "h", i == 0 || chars[i - 1].isWhitespace || chars[i - 1] == "(",
               Self.hasPrefix(chars, i, "https://") || Self.hasPrefix(chars, i, "http://") {
                var end = i
                while end < chars.count, !chars[end].isWhitespace, chars[end] != "<" { end += 1 }
                while end > i, ".,;:!?)\"'*_~".contains(chars[end - 1]) { end -= 1 }
                let raw = String(chars[i..<end])
                if let url = URL(string: raw) {
                    appendLink(raw, url)
                    i = end
                    continue
                }
            }

            if c == "*" || c == "_" || c == "~" || c == "=" {
                let run = Self.runLength(chars, i)
                if let delimiter = Self.delimiter(chars, at: i, run: run) {
                    flush()
                    items.append(.delimiter(delimiter))
                } else {
                    buffer.append(String(repeating: String(c), count: run))
                }
                i += run
                continue
            }

            buffer.append(c)
            i += 1
        }
        flush()

        let emphasis = Self.matchEmphasis(&items)
        for (k, item) in items.enumerated() {
            var itemStyle = style
            itemStyle.bold = itemStyle.bold || emphasis[k].bold
            itemStyle.italic = itemStyle.italic || emphasis[k].italic
            itemStyle.strike = itemStyle.strike || emphasis[k].strike
            itemStyle.highlight = itemStyle.highlight || emphasis[k].highlight
            switch item {
            case .piece(let make):
                out.append(make(itemStyle))
            case .delimiter(let d) where d.count > 0:
                out.append(NSAttributedString(string: String(repeating: d.char, count: d.count), attributes: attributes(itemStyle)))
            case .delimiter:
                break
            }
        }
    }

    // MARK: Emphasis

    /// `*`/`_` (italic), `**`/`__` (bold), `~~` (strikethrough) and `==` (highlight), with CommonMark's
    /// flanking rules, so `snake_case` and `2 * 3` stay literal.
    private static func delimiter(_ chars: [Character], at i: Int, run: Int) -> Delimiter? {
        let c = chars[i]
        if c == "~" || c == "=", run != 2 { return nil }
        let before: Character = i > 0 ? chars[i - 1] : " "
        let after: Character = i + run < chars.count ? chars[i + run] : " "
        func isPunctuation(_ ch: Character) -> Bool { ch.isPunctuation || ch.isSymbol }
        let left = !after.isWhitespace && (!isPunctuation(after) || before.isWhitespace || isPunctuation(before))
        let right = !before.isWhitespace && (!isPunctuation(before) || after.isWhitespace || isPunctuation(after))
        var canOpen = left, canClose = right
        if c == "_" {
            canOpen = left && (!right || isPunctuation(before))
            canClose = right && (!left || isPunctuation(after))
        }
        guard canOpen || canClose else { return nil }
        return Delimiter(char: c, length: run, count: run, canOpen: canOpen, canClose: canClose)
    }

    /// CommonMark's emphasis matching: each closer pairs with the nearest opener of the same kind, so
    /// `**bold *both***` and `***both** italic*` nest correctly. Returns the styles added to each item.
    private static func matchEmphasis(_ items: inout [Item]) -> [Style] {
        var added = Array(repeating: Style(), count: items.count)
        var k = 0
        while k < items.count {
            guard case .delimiter(var closer) = items[k], closer.canClose, closer.count > 0 else {
                k += 1
                continue
            }
            var o = k - 1
            while o >= 0 {
                if case .delimiter(let opener) = items[o], opener.char == closer.char, opener.canOpen, opener.count > 0 {
                    let oddMatch = (opener.canClose || closer.canOpen) && (opener.length + closer.length) % 3 == 0
                        && !(opener.length % 3 == 0 && closer.length % 3 == 0)
                    if !oddMatch { break }
                }
                o -= 1
            }
            guard o >= 0, case .delimiter(var opener) = items[o] else {
                k += 1
                continue
            }
            let use = opener.count >= 2 && closer.count >= 2 ? 2 : 1
            for m in (o + 1)..<k {
                switch (closer.char, use) {
                case ("~", _): added[m].strike = true
                case ("=", _): added[m].highlight = true
                case (_, 1): added[m].italic = true
                default: added[m].bold = true
                }
                if case .delimiter(var inner) = items[m] {
                    inner.canOpen = false
                    inner.canClose = false
                    items[m] = .delimiter(inner)
                }
            }
            opener.count -= use
            closer.count -= use
            items[o] = .delimiter(opener)
            items[k] = .delimiter(closer)
            if closer.count == 0 { k += 1 }
        }
        return added
    }

    // MARK: Scanning

    private static func runLength(_ chars: [Character], _ i: Int) -> Int {
        var j = i
        while j < chars.count, chars[j] == chars[i] { j += 1 }
        return j - i
    }

    private static func findCodeClose(_ chars: [Character], from start: Int, run: Int) -> Int? {
        var j = start
        while j < chars.count {
            if chars[j] == "`" {
                let r = runLength(chars, j)
                if r == run { return j }
                j += r
            } else {
                j += 1
            }
        }
        return nil
    }

    private static func hasPrefix(_ chars: [Character], _ i: Int, _ prefix: String) -> Bool {
        let p = Array(prefix)
        guard i >= 0, i + p.count <= chars.count else { return false }
        return Array(chars[i..<(i + p.count)]) == p
    }

    private static func find(_ chars: [Character], _ needle: String, from start: Int) -> Int? {
        var j = start
        while j < chars.count {
            if hasPrefix(chars, j, needle) { return j }
            j += 1
        }
        return nil
    }

    /// `[[Note]]` → "Note", `[[Note|alias]]` → "alias", `[[Note#Part]]` → "Note › Part".
    private static func wikiText(_ inner: String) -> String {
        let parts = inner.split(separator: "|", maxSplits: 1).map(String.init)
        if parts.count == 2, !parts[1].isEmpty { return parts[1] }
        let target = parts.first ?? inner
        return target.split(separator: "#").joined(separator: " › ")
    }

    /// `[text](destination "title")`; `<…>` destinations and unescaped spaces are accepted.
    private static func parseLink(_ chars: [Character], at start: Int) -> (text: Range<Int>, destination: String, end: Int)? {
        guard start < chars.count, chars[start] == "[" else { return nil }
        var depth = 0
        var j = start
        var textEnd: Int?
        while j < chars.count {
            let ch = chars[j]
            if ch == "\\" { j += 2; continue }
            if ch == "`" {
                let r = runLength(chars, j)
                j = findCodeClose(chars, from: j + r, run: r).map { $0 + r } ?? j + r
                continue
            }
            if ch == "[" { depth += 1 }
            if ch == "]" {
                depth -= 1
                if depth == 0 { textEnd = j; break }
            }
            j += 1
        }
        guard let textEnd, textEnd + 1 < chars.count, chars[textEnd + 1] == "(" else { return nil }
        var k = textEnd + 2
        while k < chars.count, chars[k] == " " { k += 1 }
        var destination: String
        if k < chars.count, chars[k] == "<" {
            guard let close = chars[(k + 1)...].firstIndex(of: ">") else { return nil }
            destination = String(chars[(k + 1)..<close])
            k = close + 1
            while k < chars.count, chars[k] != ")" { k += 1 }
            guard k < chars.count else { return nil }
        } else {
            var parens = 0
            let destStart = k
            while k < chars.count {
                if chars[k] == "\\" { k += 2; continue }
                if chars[k] == "(" { parens += 1 }
                if chars[k] == ")" {
                    if parens == 0 { break }
                    parens -= 1
                }
                k += 1
            }
            guard k < chars.count else { return nil }
            destination = String(chars[destStart..<k]).trimmingCharacters(in: .whitespaces)
            if destination.hasSuffix("\""), let quote = destination.range(of: " \"") {
                destination = String(destination[..<quote.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
        }
        return (start + 1..<textEnd, destination, k + 1)
    }
}
