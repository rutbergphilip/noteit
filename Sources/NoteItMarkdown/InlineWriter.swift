import Foundation
import NoteItDoc

/// Wiki-link targets written so far, so a written file can be read back the way the library will read it.
final class NoteTargets {
    private var map: [String: UUID?] = [:]

    /// False when `target` already stands for a different note.
    func register(_ target: String, _ id: UUID?) -> Bool {
        if let existing = map[target] { return existing == id }
        map[target] = id
        return true
    }

    func resolve(_ target: String) -> UUID? {
        map[target] ?? nil
    }
}

/// How hard the writer tries to stay readable. A block that doesn't read back moves down the list.
struct InlineStyle: Equatable {
    /// `<strong>`, `<em>`, `<del>`, `<mark>` instead of `**`, `*`, `~~`, `==`.
    var html = false
    /// Escape every ASCII punctuation character; no wiki links, no autolinks.
    var escapeAll = false

    static let canonical = InlineStyle()
    static let htmlForms = InlineStyle(html: true)
    static let strict = InlineStyle(html: true, escapeAll: true)
    static let all = [canonical, htmlForms, strict]
}

/// `[Inline]` → Markdown. Marks nest in a fixed order, outermost first: link, `span`, `mark`/`==`, `<u>`, `~~`,
/// `**`, `*`, code; a mark that runs longer opens first.
struct InlineWriter {
    enum Context { case block, heading, tableCell }

    let context: Context
    let style: InlineStyle
    let profile: MarkdownProfile
    let noteLinkName: (UUID) -> String?
    let attachmentPath: (String) -> String
    let targets: NoteTargets

    private struct Group {
        var marks: [Mark]
        var closer: String
    }

    func write(_ content: [Inline]) -> String {
        let items = Self.normalized(content, profile: profile)
        var out = ""
        var stack: [Group] = []

        func marks(at index: Int) -> [Mark] {
            guard index >= 0, index < items.count, case .text(_, let marks) = items[index] else { return [] }
            return marks
        }
        func extent(_ mark: Mark, from index: Int) -> Int {
            var end = index
            while end < items.count, marks(at: end).contains(mark) { end += 1 }
            return end - index
        }
        func closeAll() {
            while let group = stack.popLast() { out += group.closer }
        }
        func sync(to wanted: [Mark], at index: Int) {
            var keep = 0
            while keep < stack.count, stack[keep].marks.allSatisfy(wanted.contains) { keep += 1 }
            while stack.count > keep { out += stack.removeLast().closer }
            let open = stack.flatMap(\.marks)
            let toOpen = wanted.filter { !open.contains($0) }
                .map { ($0, extent($0, from: index)) }
                .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : Self.nesting($0.0) < Self.nesting($1.0) }
            var k = 0
            while k < toOpen.count {
                var group = [toOpen[k].0]
                if k + 1 < toOpen.count, Self.nesting(toOpen[k].0) == 1, Self.nesting(toOpen[k + 1].0) == 1, toOpen[k].1 == toOpen[k + 1].1 {
                    group.append(toOpen[k + 1].0)
                    k += 1
                }
                let (opener, closer) = delimiters(for: group)
                out += opener
                stack.append(Group(marks: group, closer: closer))
                k += 1
            }
        }

        for (index, item) in items.enumerated() {
            switch item {
            case .text(let text, let itemMarks):
                var wanted = itemMarks.filter { $0 != .code }
                var special: String?
                if let link = itemMarks.first(where: Self.isLink), !marks(at: index - 1).contains(link), !marks(at: index + 1).contains(link),
                   !itemMarks.contains(.code), case .link(let href) = link {
                    special = wikiLink(text: text, href: href) ?? autolink(text: text, href: href, index: index, items: items, out: out, otherMarks: wanted.count > 1)
                    if special != nil { wanted.removeAll { $0 == link } }
                }
                sync(to: wanted, at: index)
                if let special {
                    out += special
                } else if itemMarks.contains(.code) {
                    out += codeSpan(text)
                } else {
                    out += escape(text, inLinkText: stack.contains { $0.marks.contains(where: Self.isLink) },
                                  first: index == 0, last: index == items.count - 1)
                }
            case .hardBreak:
                closeAll()
                out += context == .block ? "\\\n" : "<br>"
            case .image(let sha, let name, _, let width):
                closeAll()
                out += "![" + escapeName(name) + (width.map { "|" + Self.number($0) } ?? "") + "](" + Self.destination(path: attachmentPath(sha)) + ")"
            case .attachment(let sha, let name, _):
                closeAll()
                out += "[" + escapeName(name, linkText: true) + "](" + Self.destination(path: attachmentPath(sha)) + ")"
            }
        }
        closeAll()
        if out.hasSuffix("\n") { out.removeLast() }
        return out
    }

    /// Plain text of inlines for fallback blocks: no marks, images and attachments by name, breaks as spaces.
    static func plainText(_ content: [Inline], separator: String = " ") -> String {
        content.map { inline -> String in
            switch inline {
            case .text(let text, _): text
            case .image(_, let name, _, _), .attachment(_, let name, _): " " + name + " "
            case .hardBreak: separator
            }
        }.joined()
    }

    // MARK: Marks

    private static func normalized(_ content: [Inline], profile: MarkdownProfile) -> [Inline] {
        var result: [Inline] = []
        for inline in content {
            guard case .text(let text, var marks) = inline else {
                result.append(inline)
                continue
            }
            if profile == .portable { marks.removeAll { if case .fontSize = $0 { true } else { false } } }
            result.append(.text(text, marks: marks))
        }
        return result.mergingTextRuns()
    }

    static func isLink(_ mark: Mark) -> Bool {
        if case .link = mark { true } else { false }
    }

    /// Outermost first.
    private static func nesting(_ mark: Mark) -> Int {
        switch mark {
        case .link: 0
        case .textColor, .fontSize: 1
        case .highlight: 2
        case .underline: 3
        case .strike: 4
        case .bold: 5
        case .italic: 6
        case .code: 7
        }
    }

    private func delimiters(for group: [Mark]) -> (String, String) {
        switch group[0] {
        case .link(let href):
            return ("[", "](" + Self.destination(href: href) + ")")
        case .textColor, .fontSize:
            var attributes: [String] = []
            for case .textColor(let color) in group { attributes.append("style=\"color: \(color)\"") }
            for case .fontSize(let delta) in group { attributes.append("data-size=\"\(delta > 0 ? "+" : "")\(delta)\"") }
            return ("<span " + attributes.joined(separator: " ") + ">", "</span>")
        case .highlight(let color):
            if color == MarkdownStyle.yellowHighlight { return style.html ? ("<mark>", "</mark>") : ("==", "==") }
            return ("<mark style=\"background-color: \(color)\">", "</mark>")
        case .underline: return ("<u>", "</u>")
        case .strike: return style.html ? ("<del>", "</del>") : ("~~", "~~")
        case .bold: return style.html ? ("<strong>", "</strong>") : ("**", "**")
        case .italic: return style.html ? ("<em>", "</em>") : ("*", "*")
        case .code: return ("", "")
        }
    }

    // MARK: Links

    /// `[[target#heading|shown text]]` for a note link, when it reads back as the same link.
    private func wikiLink(text: String, href: String) -> String? {
        guard !style.escapeAll, let parts = WikiLink.noteHref(href) else { return nil }
        let target: String
        let id: UUID?
        let heading: String?
        switch parts {
        case .resolved(let uuid, let h):
            target = noteLinkName(uuid) ?? text
            id = uuid
            heading = h
        case .unresolved(let title, let h):
            target = title
            id = nil
            heading = h
        }
        let forbidden = CharacterSet(charactersIn: "[]|#\\\n\r")
        guard !target.isEmpty, target.rangeOfCharacter(from: forbidden) == nil,
              target == target.trimmingCharacters(in: .whitespaces),
              heading.map({ $0.rangeOfCharacter(from: CharacterSet(charactersIn: "[]|\\\n\r")) == nil && $0 == $0.trimmingCharacters(in: .whitespaces) }) ?? true,
              text.rangeOfCharacter(from: CharacterSet(charactersIn: "[]|\\\n\r")) == nil,
              targets.register(target, id) else { return nil }
        let link = WikiLink(target: target, heading: heading, shownText: text == target ? nil : text)
        guard WikiLink.parse(String(link.written().dropFirst(2).dropLast(2))) == link else { return nil }
        return link.written(inTableCell: context == .tableCell)
    }

    /// A bare URL when it stands alone between spaces, else `<url>`; nil when neither reads back as the same link.
    private func autolink(text: String, href: String, index: Int, items: [Inline], out: String, otherMarks: Bool) -> String? {
        guard !style.escapeAll, text == href, !href.contains(where: { $0.isWhitespace || $0 == "<" || $0 == ">" }),
              context != .tableCell || !href.contains("|"), LinkPolicy.allows(href) else { return nil }
        let bareStart = out.last.map { $0.isWhitespace } ?? true
        var bareEnd = true
        if index + 1 < items.count {
            switch items[index + 1] {
            case .text(let next, let marks): bareEnd = marks.isEmpty && next.first?.isWhitespace == true
            case .hardBreak: bareEnd = context != .block
            default: bareEnd = false
            }
        }
        let lower = href.lowercased()
        if !otherMarks, bareStart, bareEnd, lower.hasPrefix("http://") || lower.hasPrefix("https://"),
           href.hasPrefix("http"), let last = href.last, !"?!.,:*_~'\")".contains(last),
           href.drop(while: { $0 != "/" }).contains(where: { $0.isLetter || $0.isNumber }) {
            return href
        }
        guard let colon = href.firstIndex(of: ":"), (2...32).contains(href.distance(from: href.startIndex, to: colon)),
              href[..<colon].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+.-".contains($0)) }),
              href.first!.isLetter else { return nil }
        return "<" + href + ">"
    }

    static func destination(href: String) -> String {
        if href.contains(where: { $0 == " " || $0 == "\t" }) {
            var result = "<"
            for c in href {
                if "\\<>&".contains(c) { result.append("\\") }
                result.append(c)
            }
            return result + ">"
        }
        var result = ""
        for c in href {
            if "\\()<>&".contains(c) { result.append("\\") }
            result.append(c)
        }
        return result
    }

    /// Relative paths are percent-encoded where Markdown or a URL parser would stop or change them.
    static func destination(path: String) -> String {
        var result = ""
        for scalar in path.unicodeScalars {
            let keep = scalar.isASCII
                ? (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || "-._~/!$'*+,;=@".unicodeScalars.contains(scalar))
                : !scalar.properties.isWhitespace && scalar.properties.generalCategory != .control
            if keep {
                result.unicodeScalars.append(scalar)
            } else {
                for byte in String(scalar).utf8 { result += String(format: "%%%02X", byte) }
            }
        }
        return result
    }

    static func number(_ value: Double) -> String {
        value.rounded() == value && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }

    // MARK: Text

    private func codeSpan(_ text: String) -> String {
        var longest = 0
        var run = 0
        for c in text {
            run = c == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: longest + 1)
        let pad = text.first == "`" || text.last == "`" || (text.first == " " && text.last == " " && text.contains { $0 != " " })
        var body = text
        if context == .tableCell { body = body.replacingOccurrences(of: "|", with: "\\|") }
        return fence + (pad ? " " : "") + body + (pad ? " " : "") + fence
    }

    /// `first`/`last`: the text starts or ends the content, so nothing written next to it can pair with it.
    func escape(_ text: String, inLinkText: Bool, first: Bool = false, last: Bool = false) -> String {
        let chars = Array(text)
        let urlMarks = Self.urlLookalikes(chars)
        var out = ""
        for (i, c) in chars.enumerated() {
            if c == "\n" {
                out += "&#10;"
                continue
            }
            if c == "\r" {
                out += "&#13;"
                continue
            }
            let previous: Character? = i > 0 ? chars[i - 1] : nil
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            var escaped: Bool
            if style.escapeAll {
                escaped = c.isASCIIPunctuation
            } else {
                switch c {
                case "\\", "*", "`", "~", "|":
                    escaped = true
                case "_":
                    escaped = !(previous.map { $0.isLetter || $0.isNumber } == true && next.map { $0.isLetter || $0.isNumber } == true)
                case "[":
                    escaped = inLinkText || !(previous == "[" && !(i >= 2 && chars[i - 2] == "["))
                case "]":
                    escaped = inLinkText || next == "("
                case "<":
                    escaped = next.map { $0.isLetter || "/!?".contains($0) } ?? false
                case "&":
                    escaped = next.map { $0.isLetter || $0.isNumber || $0 == "#" } ?? false
                case "=":
                    escaped = (previous == nil && !first) || (next == nil && !last) || previous == "=" || next == "="
                case "!":
                    escaped = next == "[" || (next == nil && !last)
                case "#":
                    escaped = context == .heading && chars[(i + 1)...].allSatisfy { $0 == "#" }
                default:
                    escaped = urlMarks.contains(i)
                }
            }
            if escaped { out.append("\\") }
            out.append(c)
        }
        return out
    }

    /// Names of images and attachments: escaped so the scanner can't end the brackets early.
    private func escapeName(_ name: String, linkText: Bool = false) -> String {
        let chars = Array(name)
        let urlMarks = Self.urlLookalikes(chars)
        let special = linkText ? "\\[]`&<|*_~=!" : "\\[]`&<|"
        var out = ""
        for (i, c) in chars.enumerated() {
            if c == "\n" {
                out += "&#10;"
                continue
            }
            if c == "\r" {
                out += "&#13;"
                continue
            }
            if special.contains(c) || urlMarks.contains(i) || (style.escapeAll && c.isASCIIPunctuation) { out.append("\\") }
            out.append(c)
        }
        return out
    }

    /// The `:` of `http://` and `https://` and the `.` of `www.`, so text never turns into a bare link.
    private static func urlLookalikes(_ chars: [Character]) -> Set<Int> {
        var result = Set<Int>()
        for i in chars.indices where chars[i] == "h" || chars[i] == "w" {
            let rest = String(chars[i..<min(chars.count, i + 8)])
            if rest.hasPrefix("https://") {
                result.insert(i + 5)
            } else if rest.hasPrefix("http://") {
                result.insert(i + 4)
            } else if rest.hasPrefix("www.") {
                result.insert(i + 3)
            }
        }
        return result
    }

    // MARK: Lines

    /// Leading and trailing spaces and tabs as entities (lines are trimmed when read), and the characters that
    /// would start a block at the beginning of a line escaped.
    static func protectLine(_ line: String, lineStart: Bool) -> String {
        var chars = Array(line)
        var prefix = ""
        while let first = chars.first, first == " " || first == "\t" {
            prefix += first == " " ? "&#32;" : "&#9;"
            chars.removeFirst()
        }
        var suffix = ""
        while let last = chars.last, last == " " || last == "\t" {
            suffix = (last == " " ? "&#32;" : "&#9;") + suffix
            chars.removeLast()
        }
        if lineStart, prefix.isEmpty, let first = chars.first {
            if "#-+>".contains(first) {
                chars.insert("\\", at: 0)
            } else if first.isASCII, first.isNumber {
                let digits = chars.prefix { $0.isASCII && $0.isNumber }.count
                if digits < chars.count, chars[digits] == "." || chars[digits] == ")" { chars.insert("\\", at: digits) }
            }
        }
        return prefix + String(chars) + suffix
    }
}

extension Array where Element == Inline {
    /// Adjacent text runs with equal marks joined and empty ones dropped. Linear: `previous + text` per run is not.
    func mergingTextRuns() -> [Inline] {
        var result: [Inline] = []
        var run: (text: String, marks: [Mark])?
        for inline in self {
            guard case .text(let text, let marks) = inline else {
                if let run { result.append(.text(run.text, marks: run.marks)) }
                run = nil
                result.append(inline)
                continue
            }
            guard !text.isEmpty else { continue }
            if run?.marks == marks {
                run!.text += text
            } else {
                if let run { result.append(.text(run.text, marks: run.marks)) }
                run = (text, marks)
            }
        }
        if let run { result.append(.text(run.text, marks: run.marks)) }
        return result
    }
}
