import Foundation
import NoteItDoc

/// Block structure: CommonMark + GFM (ATX and setext headings, paragraphs, fenced and indented code, lists, task
/// items, quotes, thematic breaks, pipe tables) plus NoteIt's attribute comment lines, with the source range of
/// every block. Blank lines beyond the one that separates two blocks are empty paragraphs (none between list items).
struct BlockParser {
    struct SourceLine {
        var text: String
        var range: Range<String.Index>
    }

    /// One or more doc blocks that come from the same lines (a fence gives one code block per line).
    struct Unit {
        var nodes: [DocNode]
        var range: Range<String.Index>
        var isListItem = false
    }

    var inline: InlineParser

    init(resolveNoteLink: @escaping (String) -> UUID?) {
        inline = InlineParser(resolveNoteLink: resolveNoteLink)
    }

    static func lines(of text: String, from start: String.Index) -> [SourceLine] {
        let all = Lines(text)
        var result: [SourceLine] = []
        var cursor = start
        while let line = all.next(after: cursor) {
            let contentEnd = text.utf8.index(line.start, offsetBy: line.content.utf8.count)
            result.append(SourceLine(text: line.content, range: line.start..<contentEnd))
            cursor = line.end
        }
        return result
    }

    /// Quotes nested deeper than this read their remaining `>` as text, so nesting can't exhaust the stack.
    static let maxQuoteDepth = 32

    /// Blocks with their ranges. Empty paragraphs from blank lines get the range of their blank line.
    mutating func parseBlocks(_ lines: [SourceLine], quoteDepth: Int = 0) -> [(DocNode, Range<String.Index>)] {
        var units: [Unit] = []
        var blanks: [[Range<String.Index>]] = [[]]
        var i = 0
        var pending: BlockAttributes?
        var pendingStart: String.Index?

        func add(_ unit: Unit) {
            units.append(unit)
            blanks.append([])
        }

        while i < lines.count {
            let line = lines[i]
            if line.isBlank {
                if let attrs = pending, let start = pendingStart, let empty = attrs.emptyParagraph {
                    add(Unit(nodes: [empty], range: start..<lines[i - 1].range.upperBound))
                }
                pending = nil
                blanks[blanks.count - 1].append(line.range)
                i += 1
                continue
            }
            if let attrs = BlockAttributes.parse(comment: line.text) {
                if let payload = attrs.payload, case .unknown = payload {
                    add(Unit(nodes: [payload], range: line.range))
                    pending = nil
                    i += 1
                    continue
                }
                pending = attrs
                pendingStart = line.range.lowerBound
                i += 1
                continue
            }
            let start = pending != nil ? pendingStart! : line.range.lowerBound
            let attrs = pending ?? BlockAttributes()
            pending = nil
            let previousIsList = units.last?.isListItem == true && blanks[blanks.count - 1].isEmpty
            var produced: [Unit] = []
            var listBlanks: [[Range<String.Index>]] = []
            if let fence = Fence(line.text) {
                var j = i + 1
                var code: [String] = []
                while j < lines.count, !fence.closes(lines[j].text) {
                    code.append(fence.strip(lines[j].text))
                    j += 1
                }
                let end = j < lines.count ? lines[j].range.upperBound : lines[j - 1].range.upperBound
                let content = code.isEmpty ? [""] : code
                produced = [Unit(nodes: content.map { .codeBlock(align: attrs.align, language: fence.language,
                                                                  content: $0.isEmpty ? [] : [.text($0, marks: [])]) },
                                 range: start..<end)]
                i = min(j + 1, lines.count)
            } else if let (level, text) = Self.atxHeading(line.text) {
                produced = [Unit(nodes: [.heading(level: min(level, 3), align: attrs.align, indent: attrs.indent,
                                                  content: inline.parse(text))],
                                 range: start..<line.range.upperBound)]
                i += 1
            } else if Self.isThematicBreak(line.text) {
                produced = [Unit(nodes: [.horizontalRule], range: start..<line.range.upperBound)]
                i += 1
            } else if quoteDepth < Self.maxQuoteDepth, Self.quoteContent(line.text) != nil {
                var inner: [SourceLine] = []
                var j = i
                while j < lines.count, !lines[j].isBlank {
                    if let content = Self.quoteContent(lines[j].text) {
                        inner.append(SourceLine(text: content, range: lines[j].range))
                    } else if !inner.isEmpty, !inner[inner.count - 1].isBlank, !Self.startsBlock(lines[j].text) {
                        inner.append(lines[j])
                    } else {
                        break
                    }
                    j += 1
                }
                let paragraphs = Self.quoteParagraphs(parseBlocks(inner, quoteDepth: quoteDepth + 1).map(\.0))
                produced = [Unit(nodes: [.blockquote(indent: attrs.indent, content: paragraphs)], range: start..<lines[j - 1].range.upperBound)]
                i = j
            } else if let item = ListItemLine(line.text),
                      item.indent < 4 || previousIsList || attrs.level != nil || attrs.align != nil && item.indent % 4 == 0 {
                let (items, gaps, next) = parseList(lines, from: i, firstAttrs: attrs, firstStart: start)
                produced = items
                listBlanks = gaps
                i = next
            } else if let table = parseTable(lines, from: i, attrs: attrs, start: start) {
                produced = [table.0]
                i = table.1
            } else if Self.indentation(of: line.text) >= 4 {
                var j = i
                var code: [String] = []
                var lastCode = i
                while j < lines.count, lines[j].isBlank || Self.indentation(of: lines[j].text) >= 4 {
                    code.append(Self.removingIndentation(lines[j].text, columns: 4))
                    if !lines[j].isBlank { lastCode = j }
                    j += 1
                }
                code = Array(code.prefix(lastCode - i + 1))
                produced = [Unit(nodes: code.map { .codeBlock(align: attrs.align, language: nil,
                                                               content: $0.isEmpty ? [] : [.text($0, marks: [])]) },
                                 range: start..<lines[lastCode].range.upperBound)]
                i = lastCode + 1
            } else {
                var text = [line.text]
                var j = i + 1
                var setext: Int?
                while j < lines.count, !lines[j].isBlank {
                    if let level = Self.setextLevel(lines[j].text) {
                        setext = level
                        break
                    }
                    if Self.startsBlock(lines[j].text, interruptingParagraph: true) { break }
                    text.append(lines[j].text)
                    j += 1
                }
                let content = inline.parse(lines: text)
                if let setext {
                    produced = [Unit(nodes: [.heading(level: setext, align: attrs.align, indent: attrs.indent,
                                                      content: content.hardeningSoftBreaks())],
                                     range: start..<lines[j].range.upperBound)]
                    i = j + 1
                } else {
                    produced = [Unit(nodes: [.paragraph(align: attrs.align, indent: attrs.indent, content: content)],
                                     range: start..<lines[j - 1].range.upperBound)]
                    i = j
                }
            }
            for (index, var unit) in produced.enumerated() {
                if index == 0, let payload = attrs.payload { unit = applying(payload, to: unit) }
                if index > 0 { blanks[blanks.count - 1] = listBlanks[index] }
                add(unit)
            }
        }
        if let attrs = pending, let start = pendingStart, let empty = attrs.emptyParagraph {
            add(Unit(nodes: [empty], range: start..<lines[lines.count - 1].range.upperBound))
        }

        var result: [(DocNode, Range<String.Index>)] = []
        for (index, unit) in units.enumerated() {
            let gap = blanks[index]
            let separator = index == 0 ? 0 : (units[index - 1].isListItem && unit.isListItem ? 0 : 1)
            for range in gap.dropFirst(min(separator, gap.count)) { result.append((Self.emptyParagraph, range)) }
            for node in unit.nodes { result.append((node, unit.range)) }
        }
        for range in blanks[units.count] { result.append((Self.emptyParagraph, range)) }
        return result
    }

    static let emptyParagraph = DocNode.paragraph(align: nil, indent: nil, content: [])

    private mutating func applying(_ payload: DocNode, to unit: Unit) -> Unit {
        guard RichBlock.fingerprint(of: [payload]) == RichBlock.fingerprint(of: unit.nodes) else { return unit }
        inline.refs += RichBlock.attachmentRefs(in: payload)
        var replaced = unit
        replaced.nodes = [payload]
        if case .listItem = payload {} else { replaced.isListItem = false }
        return replaced
    }

    // MARK: Lists

    private mutating func parseList(_ lines: [SourceLine], from first: Int, firstAttrs: BlockAttributes,
                                    firstStart: String.Index) -> ([Unit], [[Range<String.Index>]], Int) {
        struct Item {
            var line: ListItemLine
            var attrs: BlockAttributes
            var start: String.Index
            var end: String.Index
            var text: [String]
            var blanksBefore: [Range<String.Index>]
        }
        var items: [Item] = []
        let firstLine = ListItemLine(lines[first].text)!
        items.append(Item(line: firstLine, attrs: firstAttrs, start: firstStart, end: lines[first].range.upperBound,
                          text: [firstLine.content + Self.hardBreakSpaces(lines[first].text)], blanksBefore: []))
        var j = first + 1
        while j < lines.count {
            var k = j
            var gap: [Range<String.Index>] = []
            while k < lines.count, lines[k].isBlank {
                gap.append(lines[k].range)
                k += 1
            }
            guard k < lines.count else { break }
            var attrs = BlockAttributes()
            var start = lines[k].range.lowerBound
            var itemIndex = k
            if let comment = BlockAttributes.parse(comment: lines[k].text), k + 1 < lines.count, ListItemLine(lines[k + 1].text) != nil {
                attrs = comment
                itemIndex = k + 1
            }
            if let next = ListItemLine(lines[itemIndex].text), !Self.isThematicBreak(lines[itemIndex].text) {
                start = itemIndex == k ? start : lines[k].range.lowerBound
                items.append(Item(line: next, attrs: attrs, start: start, end: lines[itemIndex].range.upperBound,
                                  text: [next.content + Self.hardBreakSpaces(lines[itemIndex].text)], blanksBefore: gap))
                j = itemIndex + 1
                continue
            }
            guard gap.isEmpty, !Self.startsBlock(lines[k].text, interruptingParagraph: true) else { break }
            items[items.count - 1].text.append(lines[k].text)
            items[items.count - 1].end = lines[k].range.upperBound
            j = k + 1
        }

        let indents = items.map(\.line.indent)
        var levels: [Int]
        if indents.allSatisfy({ $0 % 4 == 0 }) {
            levels = indents.map { $0 / 4 }
        } else {
            var stack: [Int] = []
            levels = indents.map { indent in
                while let top = stack.last, top > indent { stack.removeLast() }
                if stack.last != indent { stack.append(indent) }
                return stack.count - 1
            }
        }
        if let hint = firstAttrs.level, hint != levels[0] {
            let offset = hint - levels[0]
            levels = levels.map { $0 + offset }
        }
        var units: [Unit] = []
        var gaps: [[Range<String.Index>]] = []
        for (index, item) in items.enumerated() {
            let level = min(8, max(0, levels[index]))
            let content = inline.parse(lines: item.text)
            let node: DocNode
            switch item.line.kind {
            case .task(let checked):
                node = .listItem(kind: .task, level: level, number: nil, checked: checked, align: item.attrs.align, content: content)
            case .ordered(let number):
                node = .listItem(kind: .ordered, level: level, number: number, checked: nil, align: item.attrs.align, content: content)
            case .bullet:
                node = .listItem(kind: .bullet, level: level, number: nil, checked: nil, align: item.attrs.align, content: content)
            }
            var unit = Unit(nodes: [node], range: item.start..<item.end, isListItem: true)
            if index > 0, let payload = item.attrs.payload { unit = applying(payload, to: unit) }
            units.append(unit)
            gaps.append(item.blanksBefore)
        }
        return (units, gaps, j)
    }

    // MARK: Tables

    private mutating func parseTable(_ lines: [SourceLine], from first: Int, attrs: BlockAttributes,
                                     start: String.Index) -> (Unit, Int)? {
        guard first + 1 < lines.count, lines[first].text.contains("|"),
              let alignments = Self.delimiterRow(lines[first + 1].text) else { return nil }
        let header = Self.cells(lines[first].text)
        guard header.count == alignments.count else { return nil }
        var rows = [header]
        var j = first + 2
        while j < lines.count, !lines[j].isBlank, lines[j].text.contains("|"), !Self.startsBlock(lines[j].text) {
            rows.append(Self.cells(lines[j].text))
            j += 1
        }
        let headerIsEmpty = header.allSatisfy { $0.isEmpty }
        if headerIsEmpty { rows.removeFirst() }
        let docRows = rows.enumerated().map { index, row in
            (0..<alignments.count).map { column -> TableCell in
                let text = column < row.count ? row[column] : ""
                return TableCell(header: index == 0 && !headerIsEmpty,
                                 content: [.paragraph(align: alignments[column], indent: nil, content: inline.parse(text))])
            }
        }
        return (Unit(nodes: [.table(columnWidths: attrs.widths, rows: docRows)], range: start..<lines[j - 1].range.upperBound), j)
    }

    /// `| a | b\|c |` → ["a", "b|c"]: cells trimmed, `\|` unescaped.
    static func cells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|"), !text.hasSuffix("\\|") { text.removeLast() }
        var cells: [String] = []
        var current = ""
        var iterator = text.makeIterator()
        while let c = iterator.next() {
            if c == "\\" {
                guard let next = iterator.next() else {
                    current.append(c)
                    break
                }
                if next != "|" { current.append(c) }
                current.append(next)
            } else if c == "|" {
                cells.append(current)
                current = ""
            } else {
                current.append(c)
            }
        }
        cells.append(current)
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func delimiterRow(_ line: String) -> [Align?]? {
        guard line.contains("-") else { return nil }
        let cells = cells(line)
        var result: [Align?] = []
        for cell in cells {
            guard !cell.isEmpty, cell.allSatisfy({ $0 == "-" || $0 == ":" }), cell.contains("-"),
                  !cell.dropFirst().dropLast().contains(":") else { return nil }
            switch (cell.first == ":", cell.count > 1 && cell.last == ":") {
            case (true, true): result.append(.center)
            case (true, false): result.append(.left)
            case (false, true): result.append(.right)
            case (false, false): result.append(nil)
            }
        }
        guard line.contains("|") || result.count > 1 else { return nil }
        return result
    }

    // MARK: Quotes

    static func quoteContent(_ line: String) -> String? {
        let indent = indentation(of: line)
        guard indent < 4 else { return nil }
        let rest = line.drop(while: { $0 == " " || $0 == "\t" })
        guard rest.first == ">" else { return nil }
        var content = rest.dropFirst()
        if content.first == " " || content.first == "\t" { content = content.dropFirst() }
        return String(content)
    }

    /// A quote holds paragraphs only; other blocks inside a foreign quote keep their text.
    static func quoteParagraphs(_ nodes: [DocNode]) -> [DocNode] {
        nodes.flatMap { node -> [DocNode] in
            switch node {
            case .paragraph(let align, _, let content):
                return [.paragraph(align: align, indent: nil, content: content)]
            case .heading(_, let align, _, let content), .listItem(_, _, _, _, let align, let content):
                return [.paragraph(align: align, indent: nil, content: content)]
            case .codeBlock(let align, _, let content):
                return [.paragraph(align: align, indent: nil, content: content.map { inline in
                    if case .text(let text, let marks) = inline { return .text(text, marks: MarkOrder.canonical(marks + [.code])) }
                    return inline
                })]
            case .blockquote(_, let content):
                return quoteParagraphs(content)
            case .table(_, let rows):
                return rows.map { row in
                    .paragraph(align: nil, indent: nil, content: Array(row.flatMap { cell in
                        cell.content.flatMap { paragraph -> [Inline] in
                            if case .paragraph(_, _, let content) = paragraph { return content + [.text(" ", marks: [])] }
                            return []
                        }
                    }.dropLast()))
                }
            case .horizontalRule, .doc, .unknown:
                return []
            }
        }
    }

    // MARK: Line classification

    static func indentation(of line: String) -> Int {
        var columns = 0
        for c in line {
            if c == " " { columns += 1 } else if c == "\t" { columns += 4 - columns % 4 } else { break }
        }
        return columns
    }

    static func removingIndentation(_ line: String, columns: Int) -> String {
        var removed = 0
        var index = line.startIndex
        while index < line.endIndex, removed < columns {
            if line[index] == " " { removed += 1 } else if line[index] == "\t" { removed += 4 - removed % 4 } else { break }
            index = line.index(after: index)
        }
        return String(line[index...])
    }

    /// Two spaces when `line` ends in a hard break's spaces, for `InlineParser.parse(lines:)`.
    static func hardBreakSpaces(_ line: String) -> String {
        line.reversed().prefix(while: { $0 == " " }).count >= 2 ? "  " : ""
    }

    static func trimmed(_ line: String) -> String {
        line.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
    }

    static func atxHeading(_ line: String) -> (Int, String)? {
        guard indentation(of: line) < 4 else { return nil }
        let rest = line.drop(while: { $0 == " " })
        let hashes = rest.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let after = rest.dropFirst(hashes)
        guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }
        var text = trimmed(String(after))
        let closing = text.reversed().prefix(while: { $0 == "#" }).count
        if closing > 0 {
            let before = text.dropLast(closing)
            if before.isEmpty || before.last == " " || before.last == "\t" { text = trimmed(String(before)) }
        }
        return (hashes, text)
    }

    static func isThematicBreak(_ line: String) -> Bool {
        guard indentation(of: line) < 4 else { return false }
        let marks = line.filter { $0 != " " && $0 != "\t" }
        guard marks.count >= 3, let first = marks.first, "*-_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    static func setextLevel(_ line: String) -> Int? {
        guard indentation(of: line) < 4 else { return nil }
        let text = trimmed(line)
        guard let first = text.first, first == "=" || first == "-", text.allSatisfy({ $0 == first }) else { return nil }
        return first == "=" ? 1 : 2
    }

    /// Whether `line` starts a block other than a paragraph. A paragraph can't be interrupted by an indented code
    /// line, an empty list item or an ordered item that doesn't start at 1.
    static func startsBlock(_ line: String, interruptingParagraph: Bool = false) -> Bool {
        if Fence(line) != nil || atxHeading(line) != nil || isThematicBreak(line) || quoteContent(line) != nil
            || BlockAttributes.parse(comment: line) != nil {
            return true
        }
        guard let item = ListItemLine(line), item.indent < 4 else { return false }
        guard interruptingParagraph else { return true }
        if item.content.isEmpty { return false }
        if case .ordered(let number) = item.kind { return number == 1 }
        return true
    }
}

extension BlockParser.SourceLine {
    var isBlank: Bool {
        text.allSatisfy { $0 == " " || $0 == "\t" }
    }
}

// MARK: - Fences

struct Fence {
    var char: Character
    var length: Int
    var indent: Int
    var language: String?

    init?(_ line: String) {
        indent = BlockParser.indentation(of: line)
        guard indent < 4 else { return nil }
        let rest = line.drop(while: { $0 == " " })
        guard let first = rest.first, first == "`" || first == "~" else { return nil }
        let run = rest.prefix(while: { $0 == first }).count
        guard run >= 3 else { return nil }
        let info = BlockParser.trimmed(String(rest.dropFirst(run)))
        if first == "`", info.contains("`") { return nil }
        char = first
        length = run
        language = info.split(separator: " ").first.map { Unescape.text(String($0)) }
    }

    func closes(_ line: String) -> Bool {
        guard BlockParser.indentation(of: line) < 4 else { return false }
        let text = BlockParser.trimmed(line)
        return text.count >= length && text.allSatisfy { $0 == char }
    }

    func strip(_ line: String) -> String {
        BlockParser.removingIndentation(line, columns: indent)
    }
}

// MARK: - List item lines

struct ListItemLine {
    enum Kind: Equatable {
        case bullet
        case ordered(Int)
        case task(Bool)
    }

    var indent: Int
    var kind: Kind
    var content: String

    init?(_ line: String) {
        indent = BlockParser.indentation(of: line)
        let rest = line.drop(while: { $0 == " " || $0 == "\t" })
        guard let first = rest.first else { return nil }
        var after: Substring
        if "-+*".contains(first) {
            kind = .bullet
            after = rest.dropFirst()
        } else {
            let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
            guard (1...9).contains(digits.count), let number = Int(digits) else { return nil }
            let delimiter = rest.dropFirst(digits.count).first
            guard delimiter == "." || delimiter == ")" else { return nil }
            kind = .ordered(number)
            after = rest.dropFirst(digits.count + 1)
        }
        guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }
        var text = BlockParser.trimmed(String(after))
        let lowered = text.prefix(3).lowercased()
        if lowered == "[ ]" || lowered == "[x]", text.count == 3 || text.dropFirst(3).first == " " || text.dropFirst(3).first == "\t" {
            kind = .task(lowered == "[x]")
            text = BlockParser.trimmed(String(text.dropFirst(3)))
        }
        content = text
    }
}

// MARK: - Attribute comments

/// `<!-- noteit: align=center indent=2 level=3 widths=120,80 doc=… -->`. Unknown keys are ignored.
struct BlockAttributes: Equatable {
    var align: Align?
    var indent: Int?
    var level: Int?
    var widths: [Double]?
    var payload: DocNode?

    static let prefix = "<!-- noteit:"

    static func parse(comment line: String) -> BlockAttributes? {
        let text = BlockParser.trimmed(line)
        guard BlockParser.indentation(of: line) < 4, text.hasPrefix(prefix), text.hasSuffix("-->") else { return nil }
        var attrs = BlockAttributes()
        let body = text.dropFirst(prefix.count).dropLast(3)
        for pair in body.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            let (key, value) = String(pair).splitOnce("=")
            guard let value else { continue }
            switch key {
            case "align": attrs.align = Align(rawValue: value)
            case "indent": attrs.indent = Int(value).flatMap { (1...8).contains($0) ? $0 : nil }
            case "level": attrs.level = Int(value).flatMap { (1...8).contains($0) ? $0 : nil }
            case "widths":
                let numbers = value.split(separator: ",").compactMap { Double($0) }
                attrs.widths = numbers.isEmpty || numbers.contains(where: { !$0.isFinite }) ? nil : numbers
            case "doc": attrs.payload = RichBlock.decode(value)
            default: continue
            }
        }
        return attrs
    }

    /// A comment followed by a blank line or the end is an empty paragraph with its alignment and indent.
    var emptyParagraph: DocNode? {
        guard align != nil || indent != nil else { return nil }
        return .paragraph(align: align, indent: indent, content: [])
    }
}

// MARK: - Rich-block fallback payload

enum RichBlock {
    static func encode(_ node: DocNode) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(node) else { return nil }
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ text: String) -> DocNode? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64), let node = try? JSONDecoder().decode(DocNode.self, from: data) else { return nil }
        if case .doc = node { return nil }
        return node
    }

    /// The visible text of blocks with whitespace collapsed: what must match for a payload to be used.
    static func fingerprint(of nodes: [DocNode]) -> String {
        var words: [String] = []
        func add(_ inlines: [Inline]) {
            for inline in inlines {
                switch inline {
                case .text(let text, _): words.append(text)
                case .image(_, let name, _, _), .attachment(_, let name, _): words.append(" " + name + " ")
                case .hardBreak, .softBreak: words.append(" ")
                }
            }
            words.append(" ")
        }
        func visit(_ node: DocNode) {
            switch node {
            case .paragraph(_, _, let content), .heading(_, _, _, let content), .codeBlock(_, _, let content),
                 .listItem(_, _, _, _, _, let content):
                add(content)
            case .blockquote(_, let content), .doc(let content):
                content.forEach(visit)
            case .table(_, let rows):
                for cell in rows.joined() { cell.content.forEach(visit) }
            case .horizontalRule, .unknown:
                break
            }
        }
        nodes.forEach(visit)
        return words.joined().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Images and attachments in a payload; their `sha` holds the path.
    static func attachmentRefs(in node: DocNode) -> [AttachmentRef] {
        var refs: [AttachmentRef] = []
        func add(_ inlines: [Inline]) {
            for inline in inlines {
                switch inline {
                case .image(let path, let name, _, let width):
                    refs.append(AttachmentRef(path: path, displayName: name, width: width.map { Int($0.rounded()) }))
                case .attachment(let path, let name, _):
                    refs.append(AttachmentRef(path: path, displayName: name, width: nil))
                case .text, .hardBreak, .softBreak:
                    break
                }
            }
        }
        func visit(_ node: DocNode) {
            switch node {
            case .paragraph(_, _, let content), .heading(_, _, _, let content), .codeBlock(_, _, let content),
                 .listItem(_, _, _, _, _, let content):
                add(content)
            case .blockquote(_, let content), .doc(let content):
                content.forEach(visit)
            case .table(_, let rows):
                for cell in rows.joined() { cell.content.forEach(visit) }
            case .horizontalRule, .unknown:
                break
            }
        }
        visit(node)
        return refs
    }
}
