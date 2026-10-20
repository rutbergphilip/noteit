import Foundation
import NoteItDoc

/// Inline Markdown → `[Inline]`: CommonMark delimiter runs and code spans, links and autolinks, GFM strikethrough and
/// bare URLs, `==`, the NoteIt HTML tags (`<u>`, `<mark>`, `<span>`, `<strong>`, `<em>`, `<del>`, `<br>`) and wiki
/// links. Anything else stays literal text.
struct InlineParser {
    var resolveNoteLink: (String) -> UUID?
    /// Every image and attachment reference seen, in document order.
    var refs: [AttachmentRef] = []

    init(resolveNoteLink: @escaping (String) -> UUID?) {
        self.resolveNoteLink = resolveNoteLink
    }

    mutating func parse(_ source: String) -> [Inline] {
        var scanner = InlineScanner(chars: Array(source), resolveNoteLink: resolveNoteLink)
        scanner.scan()
        refs += scanner.refs
        return scanner.flattened()
    }
}

// MARK: - Mark order

enum MarkOrder {
    static func rank(_ mark: Mark) -> Int {
        switch mark {
        case .bold: 0
        case .italic: 1
        case .underline: 2
        case .strike: 3
        case .code: 4
        case .link: 5
        case .textColor: 6
        case .highlight: 7
        case .fontSize: 8
        }
    }

    static func canonical(_ marks: [Mark]) -> [Mark] {
        marks.sorted { rank($0) < rank($1) }
    }
}

// MARK: - Scanner

private struct InlineScanner {
    struct Delimiter {
        var char: Character
        var count: Int
        var originalCount: Int
        var canOpen: Bool
        var canClose: Bool
    }

    struct Tag {
        var name: String
        var closing: Bool
        var marks: [Mark]
        var hardBreak = false
    }

    struct Node {
        var text = ""
        var marks: [Mark] = []
        var atom: Inline?
        var delimiter: Delimiter?
        var tag: Tag?
        var isBracket = false
    }

    struct Bracket {
        var node: Int
        var sourceStart: Int
        var image: Bool
        var delimiterBottom: Int?
        var spanBottom: Int
    }

    /// An entry of CommonMark's delimiter stack, kept as a doubly linked list over `delimiters`.
    struct DelimiterEntry {
        var node: Int
        var prev: Int?
        var next: Int?
    }

    /// A mark over `nodes[start..<end]`, applied once scanning is done.
    struct Span {
        var start: Int
        var end: Int
        var mark: Mark
    }

    /// Nested images copy their alt source, so deeper `![` is read as `!` and a plain bracket.
    static let maxOpenImages = 4

    let chars: [Character]
    let resolveNoteLink: (String) -> UUID?
    var refs: [AttachmentRef] = []
    var nodes: [Node] = []
    var delimiters: [DelimiterEntry] = []
    var delimiterTop: Int?
    var spans: [Span] = []
    var brackets: [Bracket] = []
    /// Non-image brackets below this index can't make a link any more: links don't nest.
    var linkFloor = 0
    var openImages = 0
    var backtickRuns: [Int: [Int]]?
    var bareURLBlockedUntil = 0
    var buffer = ""
    var i = 0

    init(chars: [Character], resolveNoteLink: @escaping (String) -> UUID?) {
        self.chars = chars
        self.resolveNoteLink = resolveNoteLink
    }

    // MARK: Scanning

    mutating func scan() {
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "\\":
                if i + 1 >= chars.count || chars[i + 1] == "\n" {
                    appendAtom(.hardBreak)
                    i += 2
                } else if chars[i + 1].isASCIIPunctuation {
                    buffer.append(chars[i + 1])
                    i += 2
                } else {
                    buffer.append(c)
                    i += 1
                }
            case "\n":
                appendAtom(.hardBreak)
                i += 1
            case "`":
                scanCodeSpan()
            case "&":
                scanEntity()
            case "<":
                scanAngle()
            case "!" where peek(1) == "[" && peek(2) == "[" && scanWikiLink(embed: true):
                break
            case "!" where peek(1) == "[":
                pushBracket(image: true)
            case "[" where peek(1) == "[" && scanWikiLink(embed: false):
                break
            case "[":
                pushBracket(image: false)
            case "]":
                closeBracket()
            case "*", "_", "~", "=":
                scanDelimiterRun()
            case "h" where scanBareURL(), "w" where scanBareURL():
                break
            default:
                buffer.append(c)
                i += 1
            }
        }
        flush()
        processEmphasis(bottom: nil)
        applySpans()
        processTags()
    }

    private func peek(_ offset: Int) -> Character? {
        i + offset < chars.count ? chars[i + offset] : nil
    }

    private mutating func flush() {
        guard !buffer.isEmpty else { return }
        nodes.append(Node(text: buffer))
        buffer = ""
    }

    private mutating func appendAtom(_ inline: Inline) {
        flush()
        nodes.append(Node(atom: inline))
    }

    private mutating func appendText(_ text: String, marks: [Mark]) {
        flush()
        nodes.append(Node(text: text, marks: marks))
    }

    private mutating func scanCodeSpan() {
        var run = 0
        while i + run < chars.count, chars[i + run] == "`" { run += 1 }
        if backtickRuns == nil { backtickRuns = Self.backtickRuns(in: chars) }
        let starts = backtickRuns?[run] ?? []
        var low = 0
        var high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] < i + run { low = mid + 1 } else { high = mid }
        }
        guard low < starts.count else {
            buffer += String(repeating: "`", count: run)
            i += run
            return
        }
        let j = starts[low]
        var content = String(chars[(i + run)..<j]).replacingOccurrences(of: "\n", with: " ")
        if content.count >= 2, content.first == " ", content.last == " ", content.contains(where: { $0 != " " }) {
            content = String(content.dropFirst().dropLast())
        }
        appendText(content, marks: [.code])
        i = j + run
    }

    /// Start offsets of every maximal backtick run, by run length, so finding a closer doesn't rescan the line.
    private static func backtickRuns(in chars: [Character]) -> [Int: [Int]] {
        var runs: [Int: [Int]] = [:]
        var j = 0
        while j < chars.count {
            guard chars[j] == "`" else {
                j += 1
                continue
            }
            var length = 0
            while j + length < chars.count, chars[j + length] == "`" { length += 1 }
            runs[length, default: []].append(j)
            j += length
        }
        return runs
    }

    private mutating func scanEntity() {
        if let (decoded, length) = Entities.decode(chars, at: i) {
            buffer += decoded
            i += length
        } else {
            buffer.append("&")
            i += 1
        }
    }

    // MARK: Angle brackets: autolinks and HTML tags

    private mutating func scanAngle() {
        guard let close = chars[(i + 1)...].firstIndex(where: { $0 == ">" || $0 == "<" || $0 == "\n" }), chars[close] == ">" else {
            buffer.append("<")
            i += 1
            return
        }
        let inner = String(chars[(i + 1)..<close])
        if let href = Self.autolinkHref(inner) {
            appendText(inner, marks: [.link(href: href)])
            i = close + 1
        } else if let tag = Self.tag(inner) {
            flush()
            if tag.hardBreak {
                nodes.append(Node(atom: .hardBreak))
            } else {
                nodes.append(Node(text: "<" + inner + ">", tag: tag))
            }
            i = close + 1
        } else {
            buffer.append("<")
            i += 1
        }
    }

    private static func autolinkHref(_ inner: String) -> String? {
        guard !inner.isEmpty, !inner.contains(where: { $0 == " " || $0 == "\t" }) else { return nil }
        if let colon = inner.firstIndex(of: ":") {
            let scheme = inner[..<colon]
            guard (2...32).contains(scheme.count), scheme.first!.isASCII, scheme.first!.isLetter,
                  scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+.-".contains($0)) }) else { return nil }
            return LinkPolicy.allows(inner) ? inner : nil
        }
        let parts = inner.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."), !parts[1].hasPrefix("."), !parts[1].hasSuffix("."),
              inner.allSatisfy({ $0.isASCII && !$0.isWhitespace }) else { return nil }
        return "mailto:" + inner
    }

    private static func tag(_ inner: String) -> Tag? {
        var body = Substring(inner)
        let closing = body.hasPrefix("/")
        if closing { body = body.dropFirst() }
        let nameEnd = body.firstIndex(where: { !($0.isASCII && $0.isLetter) }) ?? body.endIndex
        let name = body[..<nameEnd].lowercased()
        var rest = body[nameEnd...]
        if name == "br" {
            rest = rest.drop(while: { $0 == " " })
            guard !closing, rest.isEmpty || rest == "/" else { return nil }
            return Tag(name: name, closing: false, marks: [], hardBreak: true)
        }
        if closing {
            guard rest.allSatisfy({ $0 == " " }), knownTags.contains(name) else { return nil }
            return Tag(name: name, closing: true, marks: [])
        }
        guard let attributes = HTMLAttributes.parse(rest) else { return nil }
        switch name {
        case "u", "ins":
            return attributes.isEmpty ? Tag(name: name, closing: false, marks: [.underline]) : nil
        case "strong", "b":
            return attributes.isEmpty ? Tag(name: name, closing: false, marks: [.bold]) : nil
        case "em", "i":
            return attributes.isEmpty ? Tag(name: name, closing: false, marks: [.italic]) : nil
        case "del", "s", "strike":
            return attributes.isEmpty ? Tag(name: name, closing: false, marks: [.strike]) : nil
        case "mark":
            if attributes.isEmpty { return Tag(name: name, closing: false, marks: [.highlight(MarkdownStyle.yellowHighlight)]) }
            guard attributes.count == 1, let style = attributes["style"],
                  let color = CSSStyle.color(in: style, property: ["background-color", "background"]) else { return nil }
            return Tag(name: name, closing: false, marks: [.highlight(color)])
        case "span":
            var marks: [Mark] = []
            for (key, value) in attributes {
                switch key {
                case "style":
                    guard let color = CSSStyle.color(in: value, property: ["color"]) else { return nil }
                    marks.append(.textColor(color))
                case "data-size":
                    guard let delta = Int(value.hasPrefix("+") ? String(value.dropFirst()) : value), delta != 0 else { return nil }
                    marks.append(.fontSize(delta: delta))
                default:
                    return nil
                }
            }
            return marks.isEmpty ? nil : Tag(name: name, closing: false, marks: marks)
        default:
            return nil
        }
    }

    private static let knownTags: Set<String> = ["u", "ins", "strong", "b", "em", "i", "del", "s", "strike", "mark", "span"]

    // MARK: Bare URLs (GFM extended autolinks)

    private mutating func scanBareURL() -> Bool {
        guard i >= bareURLBlockedUntil else { return false }
        if i > 0 {
            let previous = chars[i - 1]
            guard previous.isWhitespace || "*_~(".contains(previous) else { return false }
        }
        let rest = String(chars[i..<min(chars.count, i + 8)])
        let prefix = ["https://", "http://", "www."].first { rest.hasPrefix($0) }
        guard let prefix else { return false }
        var end = i
        while end < chars.count, !chars[end].isWhitespace, chars[end] != "<" { end += 1 }
        let runEnd = end
        var opening = 0
        var closing = 0
        for c in chars[i..<end] {
            if c == "(" { opening += 1 } else if c == ")" { closing += 1 }
        }
        while end > i {
            let last = chars[end - 1]
            if "?!.,:*_~'\"".contains(last) {
                end -= 1
            } else if last == ")", closing > opening {
                closing -= 1
                end -= 1
            } else {
                break
            }
        }
        let text = String(chars[i..<end])
        guard text.count > prefix.count, text.dropFirst(prefix.count).contains(where: { $0.isLetter || $0.isNumber }) else { return false }
        let href = prefix == "www." ? "http://" + text : text
        guard LinkPolicy.allows(href) else {
            // Later starts in the same run are suffixes of this one; trying each would be quadratic.
            bareURLBlockedUntil = runEnd
            return false
        }
        appendText(text, marks: [.link(href: href)])
        i = end
        return true
    }

    // MARK: Wiki links

    private mutating func scanWikiLink(embed: Bool) -> Bool {
        let open = i + (embed ? 3 : 2)
        var j = open
        var close: Int?
        while j + 1 < chars.count, chars[j] != "\n" {
            if chars[j] == "[" { return false }
            if chars[j] == "]" {
                guard chars[j + 1] == "]" else { return false }
                close = j
                break
            }
            j += 1
        }
        guard let close, close > open, let link = WikiLink.parse(String(chars[open..<close])) else { return false }
        if embed, let ext = MIMEType.fileExtension(of: link.target), MIMEType.isImage(ext) {
            let width = link.shownText.flatMap { Double($0) }
            let name = (link.target as NSString).lastPathComponent
            let ref = AttachmentRef(path: link.target, displayName: name, width: width.map { Int($0.rounded()) })
            refs.append(ref)
            appendAtom(.image(sha: ref.path, name: name, mime: MIMEType.forName(name), width: width))
        } else {
            appendText(link.shownText ?? link.target, marks: [.link(href: link.href(resolve: resolveNoteLink))])
        }
        i = close + 2
        return true
    }

    // MARK: Links and images

    private mutating func pushBracket(image: Bool) {
        if image, openImages >= Self.maxOpenImages {
            buffer.append("!")
            i += 1
            return
        }
        flush()
        nodes.append(Node(text: image ? "![" : "[", isBracket: true))
        brackets.append(Bracket(node: nodes.count - 1, sourceStart: i, image: image, delimiterBottom: delimiterTop,
                                spanBottom: spans.count))
        if image { openImages += 1 }
        i += image ? 2 : 1
    }

    private mutating func popBracket() {
        if brackets.removeLast().image { openImages -= 1 }
        linkFloor = min(linkFloor, brackets.count)
    }

    private mutating func closeBracket() {
        guard let bracket = brackets.last else {
            buffer.append("]")
            i += 1
            return
        }
        let active = bracket.image || brackets.count - 1 >= linkFloor
        guard active, let (destination, end) = LinkDestination.parse(chars, at: i + 1) else {
            popBracket()
            buffer.append("]")
            i += 1
            return
        }
        flush()
        processEmphasis(bottom: bracket.delimiterBottom)
        popBracket()
        let inner = (bracket.node + 1)..<nodes.count
        if bracket.image {
            let rawAlt = String(chars[(bracket.sourceStart + 2)..<i])
            let (name, width) = Self.imageName(rawAlt)
            let path = destination.removingPercentEncoding ?? destination
            let ref = AttachmentRef(path: path, displayName: name, width: width.map { Int($0.rounded()) })
            refs.append(ref)
            let mimeSource = MIMEType.fileExtension(of: name) != nil ? name : path
            spans.removeSubrange(bracket.spanBottom...)
            nodes.removeSubrange(inner)
            nodes[bracket.node] = Node(atom: .image(sha: path, name: name, mime: MIMEType.forName(mimeSource), width: width))
        } else {
            switch LinkTarget(destination: destination, resolveNoteLink: resolveNoteLink) {
            case .href(let href):
                spans.append(Span(start: inner.lowerBound, end: inner.upperBound, mark: .link(href: href)))
                nodes[bracket.node] = Node()
            case .attachment(let path):
                let name = Self.plainText(nodes[inner])
                refs.append(AttachmentRef(path: path, displayName: name, width: nil))
                spans.removeSubrange(bracket.spanBottom...)
                nodes.removeSubrange(inner)
                nodes[bracket.node] = Node(atom: .attachment(sha: path, name: name, mime: MIMEType.forName(name.isEmpty ? path : name)))
            case .none:
                nodes[bracket.node] = Node()
            }
            // Whatever it points at, this is a link, and a link can't contain one (nested names were quadratic).
            linkFloor = brackets.count
        }
        i = end
    }

    /// `name|480` → ("name", 480). A `|` escaped as `\|` is part of the name.
    private static func imageName(_ raw: String) -> (String, Double?) {
        if let bar = raw.lastIndex(of: "|"), bar > raw.startIndex, raw[raw.index(before: bar)] != "\\" {
            let digits = raw[raw.index(after: bar)...]
            if !digits.isEmpty, digits.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }), let width = Double(digits) {
                return (Unescape.text(String(raw[..<bar])), width)
            }
        }
        return (Unescape.text(raw), nil)
    }

    private static func plainText(_ nodes: ArraySlice<Node>) -> String {
        nodes.map { node -> String in
            if case .image(_, let name, _, _)? = node.atom { return name }
            if case .attachment(_, let name, _)? = node.atom { return name }
            if node.atom == .hardBreak { return " " }
            if let delimiter = node.delimiter { return String(repeating: delimiter.char, count: delimiter.count) }
            return node.text
        }.joined()
    }

    // MARK: Emphasis

    private mutating func scanDelimiterRun() {
        let c = chars[i]
        var count = 0
        while i + count < chars.count, chars[i + count] == c { count += 1 }
        let valid = switch c {
        case "~": count <= 2
        case "=": count == 2
        default: true
        }
        guard valid else {
            buffer += String(repeating: c, count: count)
            i += count
            return
        }
        let before: Character = i > 0 ? chars[i - 1] : " "
        let after: Character = i + count < chars.count ? chars[i + count] : " "
        let leftFlanking = !after.isWhitespace && (!after.isMarkdownPunctuation || before.isWhitespace || before.isMarkdownPunctuation)
        let rightFlanking = !before.isWhitespace && (!before.isMarkdownPunctuation || after.isWhitespace || after.isMarkdownPunctuation)
        var canOpen = leftFlanking
        var canClose = rightFlanking
        if c == "_" {
            canOpen = leftFlanking && (!rightFlanking || before.isMarkdownPunctuation)
            canClose = rightFlanking && (!leftFlanking || after.isMarkdownPunctuation)
        }
        flush()
        nodes.append(Node(text: String(repeating: c, count: count),
                          delimiter: Delimiter(char: c, count: count, originalCount: count, canOpen: canOpen, canClose: canClose)))
        delimiters.append(DelimiterEntry(node: nodes.count - 1, prev: delimiterTop, next: nil))
        if let top = delimiterTop { delimiters[top].next = delimiters.count - 1 }
        delimiterTop = delimiters.count - 1
        i += count
    }

    /// CommonMark's "process emphasis" over the delimiters above `bottom` (all of them when nil); afterwards those
    /// delimiters are gone. `openersBottom` keeps a failed search from being repeated, so this is linear.
    private mutating func processEmphasis(bottom: Int?) {
        var first: Int?
        var cursor = delimiterTop
        while let entry = cursor, entry != bottom {
            first = entry
            cursor = delimiters[entry].prev
        }
        var openersBottom = [Int?](repeating: bottom, count: 16)
        var closerEntry = first
        while let closer = closerEntry {
            let closerNode = delimiters[closer].node
            let closing = nodes[closerNode].delimiter!
            guard closing.canClose else {
                closerEntry = delimiters[closer].next
                continue
            }
            let key = Self.openersBottomKey(closing)
            var found: Int?
            var candidate = delimiters[closer].prev
            while let entry = candidate, entry != bottom, entry != openersBottom[key] {
                if let opener = nodes[delimiters[entry].node].delimiter, opener.char == closing.char, opener.canOpen,
                   Self.canPair(opener, closing) {
                    found = entry
                    break
                }
                candidate = delimiters[entry].prev
            }
            guard let openerEntry = found else {
                openersBottom[key] = delimiters[closer].prev
                closerEntry = delimiters[closer].next
                if !closing.canOpen { removeDelimiter(closer, &openersBottom) }
                continue
            }
            let openerNode = delimiters[openerEntry].node
            let opener = nodes[openerNode].delimiter!
            let used: Int
            let mark: Mark
            switch closing.char {
            case "~":
                used = closing.count
                mark = .strike
            case "=":
                used = 2
                mark = .highlight(MarkdownStyle.yellowHighlight)
            default:
                used = opener.count >= 2 && closing.count >= 2 ? 2 : 1
                mark = used == 2 ? .bold : .italic
            }
            spans.append(Span(start: openerNode + 1, end: closerNode, mark: mark))
            var between = delimiters[openerEntry].next
            while let entry = between, entry != closer {
                between = delimiters[entry].next
                removeDelimiter(entry, &openersBottom)
            }
            nodes[openerNode].delimiter!.count -= used
            nodes[closerNode].delimiter!.count -= used
            if nodes[openerNode].delimiter!.count == 0 {
                removeDelimiter(openerEntry, &openersBottom)
            }
            if nodes[closerNode].delimiter!.count == 0 {
                closerEntry = delimiters[closer].next
                removeDelimiter(closer, &openersBottom)
            }
        }
        if let bottom { delimiters[bottom].next = nil }
        delimiterTop = bottom
    }

    private mutating func removeDelimiter(_ entry: Int, _ openersBottom: inout [Int?]) {
        let prev = delimiters[entry].prev
        let next = delimiters[entry].next
        if let prev { delimiters[prev].next = next }
        if let next { delimiters[next].prev = prev } else { delimiterTop = prev }
        for key in openersBottom.indices where openersBottom[key] == entry { openersBottom[key] = prev }
    }

    /// Closers that share a key fail on the same openers: same character, and for `*`/`_` the same can-open and
    /// length mod 3 (the rule of 3), for `~` the same length.
    private static func openersBottomKey(_ closer: Delimiter) -> Int {
        switch closer.char {
        case "*": (closer.canOpen ? 3 : 0) + closer.originalCount % 3
        case "_": 6 + (closer.canOpen ? 3 : 0) + closer.originalCount % 3
        case "~": 12 + min(closer.count, 2)
        default: 15
        }
    }

    private static func canPair(_ opener: Delimiter, _ closer: Delimiter) -> Bool {
        switch closer.char {
        case "~", "=":
            return opener.count == closer.count
        default:
            if opener.canClose || closer.canOpen,
               (opener.originalCount + closer.originalCount) % 3 == 0,
               !(opener.originalCount % 3 == 0 && closer.originalCount % 3 == 0) {
                return false
            }
            return true
        }
    }

    private mutating func addMark(_ mark: Mark, to index: Int) {
        guard nodes[index].atom == nil else { return }
        let rank = MarkOrder.rank(mark)
        if nodes[index].marks.contains(where: { MarkOrder.rank($0) == rank }) { return }
        nodes[index].marks.append(mark)
    }

    /// Marks that don't depend on order: emphasis marks of one rank are all equal and links never overlap.
    private mutating func applySpans() {
        var depths: [[Int]?] = Array(repeating: nil, count: 9)
        var marks: [Mark?] = Array(repeating: nil, count: 9)
        for span in spans where span.start < span.end {
            if case .link = span.mark {
                for index in span.start..<span.end { addMark(span.mark, to: index) }
                continue
            }
            let rank = MarkOrder.rank(span.mark)
            if depths[rank] == nil { depths[rank] = Array(repeating: 0, count: nodes.count + 1) }
            marks[rank] = span.mark
            depths[rank]![span.start] += 1
            depths[rank]![span.end] -= 1
        }
        for rank in depths.indices {
            guard let changes = depths[rank], let mark = marks[rank] else { continue }
            var depth = 0
            for index in nodes.indices {
                depth += changes[index]
                if depth > 0 { addMark(mark, to: index) }
            }
        }
        spans = []
    }

    // MARK: Tags

    private mutating func processTags() {
        var open: [Int] = []
        var openByName: [String: [(position: Int, node: Int)]] = [:]
        var matched: [(start: Int, end: Int, marks: [Mark])] = []
        for index in nodes.indices {
            guard let tag = nodes[index].tag else { continue }
            if !tag.closing {
                openByName[tag.name, default: []].append((open.count, index))
                open.append(index)
                continue
            }
            var position: Int?
            while let last = openByName[tag.name]?.last {
                openByName[tag.name]!.removeLast()
                if last.position < open.count, open[last.position] == last.node {
                    position = last.position
                    break
                }
            }
            guard let position else { continue }
            let opener = open[position]
            if opener + 1 < index { matched.append((opener + 1, index, nodes[opener].tag!.marks)) }
            nodes[opener] = Node()
            nodes[index] = Node()
            open.removeSubrange(position...)
        }
        applyNested(matched)
    }

    /// Matched tags nest properly, and the innermost tag wins a rank, as if each were applied as it closed.
    private mutating func applyNested(_ ranges: [(start: Int, end: Int, marks: [Mark])]) {
        guard !ranges.isEmpty else { return }
        let order = ranges.indices.sorted { ranges[$0].start != ranges[$1].start ? ranges[$0].start < ranges[$1].start : ranges[$0].end > ranges[$1].end }
        var active: [Int] = []
        var byRank: [[Mark]] = Array(repeating: [], count: 9)
        var next = 0
        for index in nodes.indices {
            while let top = active.last, ranges[top].end <= index {
                for mark in ranges[top].marks { byRank[MarkOrder.rank(mark)].removeLast() }
                active.removeLast()
            }
            while next < order.count, ranges[order[next]].start == index {
                for mark in ranges[order[next]].marks { byRank[MarkOrder.rank(mark)].append(mark) }
                active.append(order[next])
                next += 1
            }
            guard !active.isEmpty else { continue }
            for marks in byRank {
                if let mark = marks.last { addMark(mark, to: index) }
            }
        }
    }

    // MARK: Output

    func flattened() -> [Inline] {
        var result: [Inline] = []
        var run = ""
        var runMarks: [Mark] = []
        for node in nodes {
            if let atom = node.atom {
                if !run.isEmpty { result.append(.text(run, marks: runMarks)) }
                run = ""
                result.append(atom)
                continue
            }
            let text = node.delimiter.map { String(repeating: $0.char, count: $0.count) } ?? node.text
            guard !text.isEmpty else { continue }
            let marks = MarkOrder.canonical(node.marks)
            if marks != runMarks {
                if !run.isEmpty { result.append(.text(run, marks: runMarks)) }
                run = ""
                runMarks = marks
            }
            run += text
        }
        if !run.isEmpty { result.append(.text(run, marks: runMarks)) }
        return result
    }
}

// MARK: - Link destinations

enum LinkTarget {
    case href(String)
    case attachment(String)
    case none

    init(destination: String, resolveNoteLink: (String) -> UUID?) {
        if let colon = destination.firstIndex(of: ":"),
           destination[..<colon].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+.-".contains($0)) }),
           destination[..<colon].count >= 2 {
            if destination.lowercased().hasPrefix("file:") {
                self = .attachment(URL(string: destination)?.path ?? destination)
            } else {
                self = LinkPolicy.allows(destination) ? .href(destination) : .none
            }
            return
        }
        if destination.isEmpty || destination.hasPrefix("#") {
            self = .none
            return
        }
        let decoded = destination.removingPercentEncoding ?? destination
        let (path, fragment) = decoded.splitOnce("#")
        let lowered = path.lowercased()
        if lowered.hasSuffix(".md") || lowered.hasSuffix(".markdown") {
            var target = String(path.dropLast(lowered.hasSuffix(".md") ? 3 : 9))
            while target.hasPrefix("./") { target.removeFirst(2) }
            self = .href(WikiLink(target: target, heading: fragment, shownText: nil).href(resolve: resolveNoteLink))
            return
        }
        self = .attachment(decoded)
    }
}

enum LinkDestination {
    /// cmark's limit; also keeps `[a](` repeated from rescanning the rest of the paragraph at every `]`.
    static let maxParenDepth = 32

    /// Parses `(destination "title")` starting at `start`, which must be `(`. Returns the unescaped destination and
    /// the index after `)`.
    static func parse(_ chars: [Character], at start: Int) -> (String, Int)? {
        guard start < chars.count, chars[start] == "(" else { return nil }
        var j = start + 1
        func skipSpace() { while j < chars.count, chars[j] == " " || chars[j] == "\t" || chars[j] == "\n" { j += 1 } }
        skipSpace()
        var raw = ""
        if j < chars.count, chars[j] == "<" {
            j += 1
            while j < chars.count, chars[j] != ">" {
                if chars[j] == "\n" || chars[j] == "<" { return nil }
                if chars[j] == "\\", j + 1 < chars.count, chars[j + 1].isASCIIPunctuation {
                    raw.append(chars[j])
                    j += 1
                }
                raw.append(chars[j])
                j += 1
            }
            guard j < chars.count else { return nil }
            j += 1
        } else {
            var depth = 0
            while j < chars.count {
                let c = chars[j]
                if c == "\\", j + 1 < chars.count, chars[j + 1].isASCIIPunctuation {
                    raw.append(c)
                    raw.append(chars[j + 1])
                    j += 2
                    continue
                }
                if c.isWhitespace { break }
                if c == "(" {
                    depth += 1
                    if depth > maxParenDepth { return nil }
                }
                if c == ")" {
                    if depth == 0 { break }
                    depth -= 1
                }
                raw.append(c)
                j += 1
            }
        }
        skipSpace()
        if j < chars.count, let closing: Character = ["\"": "\"", "'": "'", "(": ")"][chars[j]] {
            j += 1
            while j < chars.count, chars[j] != closing {
                if closing == ")", chars[j] == "(" { return nil }
                if chars[j] == "\\" { j += 1 }
                j += 1
            }
            guard j < chars.count else { return nil }
            j += 1
            skipSpace()
        }
        guard j < chars.count, chars[j] == ")" else { return nil }
        return (Unescape.text(raw), j + 1)
    }
}

// MARK: - Helpers

enum Unescape {
    /// Backslash escapes and entities.
    static func text(_ raw: String) -> String {
        let chars = Array(raw)
        var result = ""
        var i = 0
        while i < chars.count {
            if chars[i] == "\\", i + 1 < chars.count, chars[i + 1].isASCIIPunctuation {
                result.append(chars[i + 1])
                i += 2
            } else if chars[i] == "&", let (decoded, length) = Entities.decode(chars, at: i) {
                result += decoded
                i += length
            } else {
                result.append(chars[i])
                i += 1
            }
        }
        return result
    }
}

enum Entities {
    static let named: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
                                          "#32": " ", "#9": "\t"]

    static func decode(_ chars: [Character], at start: Int) -> (String, Int)? {
        guard chars[start] == "&" else { return nil }
        var j = start + 1
        while j < chars.count, j - start <= 32, chars[j] != ";" {
            guard chars[j].isASCII, chars[j].isLetter || chars[j].isNumber || chars[j] == "#" else { return nil }
            j += 1
        }
        guard j < chars.count, chars[j] == ";", j > start + 1 else { return nil }
        let name = String(chars[(start + 1)..<j])
        if let value = named[name] { return (value, j - start + 1) }
        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let scalar: UInt32? = digits.first == "x" || digits.first == "X" ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
            guard let scalar, let value = Unicode.Scalar(scalar), scalar != 0 else { return nil }
            return (String(Character(value)), j - start + 1)
        }
        return nil
    }
}

enum HTMLAttributes {
    /// ` key="value" data-x='y'` → pairs in order; nil when malformed.
    static func parse(_ text: Substring) -> [(String, String)]? {
        var pairs: [(String, String)] = []
        var rest = text
        while true {
            rest = rest.drop(while: { $0 == " " })
            if rest.isEmpty { return pairs }
            let keyEnd = rest.firstIndex(where: { !($0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-")) }) ?? rest.endIndex
            let key = rest[..<keyEnd].lowercased()
            guard !key.isEmpty else { return nil }
            rest = rest[keyEnd...]
            guard rest.first == "=" else { return nil }
            rest = rest.dropFirst()
            guard let quote = rest.first, quote == "\"" || quote == "'" else { return nil }
            rest = rest.dropFirst()
            guard let close = rest.firstIndex(of: quote) else { return nil }
            pairs.append((key, String(rest[..<close])))
            rest = rest[rest.index(after: close)...]
        }
    }
}

extension Array where Element == (String, String) {
    subscript(key: String) -> String? {
        first { $0.0 == key }?.1
    }
}

enum CSSStyle {
    /// `color: #2899E0` → "#2899E0"; the only declaration allowed is one of `property`.
    static func color(in style: String, property names: [String]) -> String? {
        let declarations = style.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard declarations.count == 1 else { return nil }
        let parts = declarations[0].splitOnce(":")
        guard let value = parts.1, names.contains(parts.0.trimmingCharacters(in: .whitespaces).lowercased()) else { return nil }
        return normalizedColor(value.trimmingCharacters(in: .whitespaces))
    }

    static func normalizedColor(_ value: String) -> String? {
        guard value.hasPrefix("#") else { return nil }
        var hex = String(value.dropFirst()).uppercased()
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return "#" + hex
    }
}

extension String {
    func splitOnce(_ separator: Character) -> (String, String?) {
        guard let found = firstIndex(of: separator) else { return (self, nil) }
        return (String(self[..<found]), String(self[index(after: found)...]))
    }
}

extension Character {
    var isASCIIPunctuation: Bool {
        guard let ascii = asciiValue else { return false }
        return (33...47).contains(ascii) || (58...64).contains(ascii) || (91...96).contains(ascii) || (123...126).contains(ascii)
    }

    /// CommonMark 0.31: Unicode P and S categories.
    var isMarkdownPunctuation: Bool {
        isASCIIPunctuation || isPunctuation || isSymbol
    }
}

// MARK: - MIME types

enum MIMEType {
    private static let byExtension: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "heic": "image/heic",
        "heif": "image/heif", "webp": "image/webp", "tif": "image/tiff", "tiff": "image/tiff", "bmp": "image/bmp",
        "svg": "image/svg+xml", "pdf": "application/pdf", "zip": "application/zip", "txt": "text/plain",
        "md": "text/markdown", "csv": "text/csv", "json": "application/json", "html": "text/html", "htm": "text/html",
        "rtf": "text/rtf", "mp3": "audio/mpeg", "m4a": "audio/mp4", "wav": "audio/wav", "mp4": "video/mp4",
        "mov": "video/quicktime", "doc": "application/msword",
        "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "xls": "application/vnd.ms-excel", "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "ppt": "application/vnd.ms-powerpoint",
        "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    ]

    static func fileExtension(of name: String) -> String? {
        let ext = (name as NSString).pathExtension.lowercased()
        return ext.isEmpty ? nil : ext
    }

    static func forName(_ name: String) -> String {
        fileExtension(of: name).flatMap { byExtension[$0] } ?? "application/octet-stream"
    }

    static func isImage(_ ext: String) -> Bool {
        byExtension[ext.lowercased()]?.hasPrefix("image/") == true
    }
}

public enum MarkdownStyle {
    /// The editor's default (Yellow) highlight, written as `==…==`. Must match `EditorStyle.highlightColors[0]`.
    public static let yellowHighlight = "#FFED8C"
}
