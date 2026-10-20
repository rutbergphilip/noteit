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
        var active = true
        var delimiterBottom: Int
    }

    let chars: [Character]
    let resolveNoteLink: (String) -> UUID?
    var refs: [AttachmentRef] = []
    var nodes: [Node] = []
    var delimiters: [Int] = []
    var brackets: [Bracket] = []
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
        processEmphasis(bottom: 0)
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
        var j = i + run
        while j < chars.count {
            if chars[j] == "`" {
                var closing = 0
                while j + closing < chars.count, chars[j + closing] == "`" { closing += 1 }
                if closing == run {
                    var content = String(chars[(i + run)..<j]).replacingOccurrences(of: "\n", with: " ")
                    if content.count >= 2, content.first == " ", content.last == " ", content.contains(where: { $0 != " " }) {
                        content = String(content.dropFirst().dropLast())
                    }
                    appendText(content, marks: [.code])
                    i = j + closing
                    return
                }
                j += closing
            } else {
                j += 1
            }
        }
        buffer += String(repeating: "`", count: run)
        i += run
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
        if i > 0 {
            let previous = chars[i - 1]
            guard previous.isWhitespace || "*_~(".contains(previous) else { return false }
        }
        let rest = String(chars[i..<min(chars.count, i + 8)])
        let prefix = ["https://", "http://", "www."].first { rest.hasPrefix($0) }
        guard let prefix else { return false }
        var end = i
        while end < chars.count, !chars[end].isWhitespace, chars[end] != "<" { end += 1 }
        while end > i {
            let last = chars[end - 1]
            if "?!.,:*_~'\"".contains(last) {
                end -= 1
            } else if last == ")" {
                let span = chars[i..<end]
                if span.filter({ $0 == ")" }).count > span.filter({ $0 == "(" }).count { end -= 1 } else { break }
            } else {
                break
            }
        }
        let text = String(chars[i..<end])
        guard text.count > prefix.count, text.dropFirst(prefix.count).contains(where: { $0.isLetter || $0.isNumber }) else { return false }
        let href = prefix == "www." ? "http://" + text : text
        guard LinkPolicy.allows(href) else { return false }
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
        flush()
        nodes.append(Node(text: image ? "![" : "[", isBracket: true))
        brackets.append(Bracket(node: nodes.count - 1, sourceStart: i, image: image, delimiterBottom: delimiters.count))
        i += image ? 2 : 1
    }

    private mutating func closeBracket() {
        guard let bracket = brackets.last else {
            buffer.append("]")
            i += 1
            return
        }
        guard bracket.active, let (destination, end) = LinkDestination.parse(chars, at: i + 1) else {
            brackets.removeLast()
            buffer.append("]")
            i += 1
            return
        }
        flush()
        processEmphasis(bottom: bracket.delimiterBottom)
        brackets.removeLast()
        let inner = (bracket.node + 1)..<nodes.count
        if bracket.image {
            let rawAlt = String(chars[(bracket.sourceStart + 2)..<i])
            let (name, width) = Self.imageName(rawAlt)
            let path = destination.removingPercentEncoding ?? destination
            let ref = AttachmentRef(path: path, displayName: name, width: width.map { Int($0.rounded()) })
            refs.append(ref)
            let mimeSource = MIMEType.fileExtension(of: name) != nil ? name : path
            nodes.removeSubrange(inner)
            nodes[bracket.node] = Node(atom: .image(sha: path, name: name, mime: MIMEType.forName(mimeSource), width: width))
        } else {
            switch LinkTarget(destination: destination, resolveNoteLink: resolveNoteLink) {
            case .href(let href):
                for index in inner { addMark(.link(href: href), to: index) }
                nodes[bracket.node] = Node()
                for index in brackets.indices where !brackets[index].image { brackets[index].active = false }
            case .attachment(let path):
                let name = Self.plainText(nodes[inner])
                refs.append(AttachmentRef(path: path, displayName: name, width: nil))
                nodes.removeSubrange(inner)
                nodes[bracket.node] = Node(atom: .attachment(sha: path, name: name, mime: MIMEType.forName(name.isEmpty ? path : name)))
            case .none:
                nodes[bracket.node] = Node()
            }
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
        delimiters.append(nodes.count - 1)
        i += count
    }

    /// CommonMark's "process emphasis" over `delimiters[bottom...]`; afterwards those delimiters are gone.
    private mutating func processEmphasis(bottom: Int) {
        var closerPosition = bottom
        while closerPosition < delimiters.count {
            let closerNode = delimiters[closerPosition]
            guard let closer = nodes[closerNode].delimiter, closer.canClose else {
                closerPosition += 1
                continue
            }
            var openerPosition: Int?
            var position = closerPosition - 1
            while position >= bottom {
                if let opener = nodes[delimiters[position]].delimiter, opener.char == closer.char, opener.canOpen,
                   Self.canPair(opener, closer) {
                    openerPosition = position
                    break
                }
                position -= 1
            }
            guard let openerPosition else {
                if !closer.canOpen {
                    delimiters.remove(at: closerPosition)
                } else {
                    closerPosition += 1
                }
                continue
            }
            let openerNode = delimiters[openerPosition]
            let opener = nodes[openerNode].delimiter!
            let used: Int
            let mark: Mark
            switch closer.char {
            case "~":
                used = closer.count
                mark = .strike
            case "=":
                used = 2
                mark = .highlight(MarkdownStyle.yellowHighlight)
            default:
                used = opener.count >= 2 && closer.count >= 2 ? 2 : 1
                mark = used == 2 ? .bold : .italic
            }
            for index in (openerNode + 1)..<closerNode { addMark(mark, to: index) }
            delimiters.removeSubrange((openerPosition + 1)..<closerPosition)
            closerPosition = openerPosition + 1
            nodes[openerNode].delimiter!.count -= used
            nodes[closerNode].delimiter!.count -= used
            if nodes[openerNode].delimiter!.count == 0 {
                delimiters.remove(at: openerPosition)
                closerPosition -= 1
            }
            if nodes[closerNode].delimiter!.count == 0 {
                delimiters.remove(at: closerPosition)
            }
        }
        delimiters.removeSubrange(min(bottom, delimiters.count)...)
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

    // MARK: Tags

    private mutating func processTags() {
        var open: [Int] = []
        for index in nodes.indices {
            guard let tag = nodes[index].tag else { continue }
            if !tag.closing {
                open.append(index)
                continue
            }
            guard let position = open.lastIndex(where: { nodes[$0].tag!.name == tag.name }) else { continue }
            let opener = open[position]
            for inner in (opener + 1)..<index {
                for mark in nodes[opener].tag!.marks { addMark(mark, to: inner) }
            }
            nodes[opener] = Node()
            nodes[index] = Node()
            open.removeSubrange(position...)
        }
    }

    // MARK: Output

    func flattened() -> [Inline] {
        var result: [Inline] = []
        for node in nodes {
            if let atom = node.atom {
                result.append(atom)
                continue
            }
            let text = node.delimiter.map { String(repeating: $0.char, count: $0.count) } ?? node.text
            guard !text.isEmpty else { continue }
            let marks = MarkOrder.canonical(node.marks)
            if case .text(let previous, let previousMarks)? = result.last, previousMarks == marks {
                result[result.count - 1] = .text(previous + text, marks: marks)
            } else {
                result.append(.text(text, marks: marks))
            }
        }
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
                if c == "(" { depth += 1 }
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
