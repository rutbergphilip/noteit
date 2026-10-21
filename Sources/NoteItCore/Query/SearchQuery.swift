import Foundation

public indirect enum QueryNode: Sendable, Equatable {
    case word(String), phrase(String)
    case title(String), tag(String), notebook(String)
    case `is`(IsFilter), has(HasFilter)
    case date(DateField, DateFilter)
    case not(QueryNode), and([QueryNode]), or([QueryNode])
    case all
}

public enum IsFilter: String, Sendable, CaseIterable { case pinned, todo, done, untagged, conflict }
public enum HasFilter: String, Sendable, CaseIterable { case due, reminder, attachment }
public enum DateField: String, Sendable { case edited, created, due }

public enum DateFilter: Sendable, Equatable {
    case within(TimeInterval), olderThan(TimeInterval)
    case on(LocalDateTime), after(LocalDateTime), before(LocalDateTime)
    case today, yesterday, thisWeek, lastWeek, thisMonth, overdue
}

public struct QueryIssue: Sendable, Equatable {
    public var range: Range<String.Index>
    public var message: String

    public init(range: Range<String.Index>, message: String) {
        self.range = range
        self.message = message
    }
}

/// The search language (spec 4.3): words, "phrases", `key:value` filters, `-`, `OR` and parentheses.
public struct SearchQuery: Sendable, Equatable {
    public var root: QueryNode
    public var issues: [QueryIssue]
    /// Folded words, phrases and `title:` values that aren't negated.
    public var highlightTerms: [String]
    /// True when a word or phrase isn't negated; such queries can be sorted by best match.
    public var hasTextTerms: Bool
    public var isEmpty: Bool { root == .all }

    public init(root: QueryNode, issues: [QueryIssue] = [], highlightTerms: [String] = [], hasTextTerms: Bool = false) {
        self.root = root
        self.issues = issues
        self.highlightTerms = highlightTerms
        self.hasTextTerms = hasTextTerms
    }

    public static func parse(_ text: String) -> SearchQuery {
        var parser = QueryParser(lexemes: QueryLexer.lex(text), text: text)
        let root = parser.parseQuery()
        var terms: [String] = []
        var hasText = false
        collectTerms(root, positive: true, into: &terms, hasText: &hasText)
        return SearchQuery(root: root, issues: parser.issues, highlightTerms: terms, hasTextTerms: hasText)
    }

    private static func collectTerms(_ node: QueryNode, positive: Bool, into terms: inout [String], hasText: inout Bool) {
        switch node {
        case .word(let value), .phrase(let value):
            guard positive, !value.isEmpty else { return }
            hasText = true
            if !terms.contains(value) { terms.append(value) }
        case .title(let value):
            if positive, !value.isEmpty, !terms.contains(value) { terms.append(value) }
        case .not(let inner):
            collectTerms(inner, positive: !positive, into: &terms, hasText: &hasText)
        case .and(let nodes), .or(let nodes):
            for inner in nodes { collectTerms(inner, positive: positive, into: &terms, hasText: &hasText) }
        default:
            break
        }
    }
}

/// One lexeme of a query, with the ranges `QueryRewriter` edits.
struct QueryLexeme: Equatable {
    enum Kind: Equatable { case open, close, or, minus, term }
    var kind: Kind
    var range: Range<String.Index>
    /// Lowercased key of a `key:value` term whose key is known.
    var key: String?
    var value: String = ""
    var valueRange: Range<String.Index>?
    var quoted = false
}

enum QueryLexer {
    static let keys: Set<String> = ["tag", "notebook", "in", "title", "is", "has", "edited", "created", "due"]

    static func lex(_ text: String) -> [QueryLexeme] {
        var result: [QueryLexeme] = []
        var depth = 0
        var i = text.startIndex
        func isSpace(_ c: Character) -> Bool { c.isWhitespace }
        while i < text.endIndex {
            let c = text[i]
            if isSpace(c) {
                i = text.index(after: i)
                continue
            }
            let next = text.index(after: i)
            if c == "(" {
                depth += 1
                result.append(QueryLexeme(kind: .open, range: i..<next))
                i = next
                continue
            }
            if c == ")" {
                depth = max(0, depth - 1)
                result.append(QueryLexeme(kind: .close, range: i..<next))
                i = next
                continue
            }
            if c == "-", next < text.endIndex, !isSpace(text[next]), text[next] != ")" {
                result.append(QueryLexeme(kind: .minus, range: i..<next))
                i = next
                continue
            }
            if c == "\"" {
                let (end, valueRange) = quoted(text, from: i)
                result.append(QueryLexeme(kind: .term, range: i..<end, key: nil,
                                          value: String(text[valueRange]), valueRange: valueRange, quoted: true))
                i = end
                continue
            }
            // A bare run; `key:"…"` continues into the quote. `)` ends it only inside parentheses.
            var j = i
            var lexeme: QueryLexeme?
            while j < text.endIndex {
                let d = text[j]
                if isSpace(d) || (d == ")" && depth > 0) { break }
                if d == ":", text.index(after: j) < text.endIndex, text[text.index(after: j)] == "\"" {
                    let after = text.index(after: j)
                    let key = String(text[i..<j]).lowercased()
                    let (end, valueRange) = quoted(text, from: after)
                    lexeme = QueryLexeme(kind: .term, range: i..<end, key: keys.contains(key) ? key : nil,
                                         value: keys.contains(key) ? String(text[valueRange]) : String(text[i..<end]),
                                         valueRange: valueRange, quoted: true)
                    j = end
                    break
                }
                j = text.index(after: j)
            }
            if let lexeme {
                result.append(lexeme)
                i = j
                continue
            }
            let raw = String(text[i..<j])
            if raw == "OR" {
                result.append(QueryLexeme(kind: .or, range: i..<j))
            } else if let colon = raw.firstIndex(of: ":"), keys.contains(raw[..<colon].lowercased()),
                      raw.index(after: colon) < raw.endIndex {
                let offset = raw.distance(from: raw.startIndex, to: colon)
                let valueStart = text.index(i, offsetBy: offset + 1)
                result.append(QueryLexeme(kind: .term, range: i..<j, key: raw[..<colon].lowercased(),
                                          value: String(text[valueStart..<j]), valueRange: valueStart..<j))
            } else {
                result.append(QueryLexeme(kind: .term, range: i..<j, value: raw, valueRange: i..<j))
            }
            i = j
        }
        return result
    }

    /// From an opening quote to just past its closing one, or the end of the text when it isn't closed.
    private static func quoted(_ text: String, from open: String.Index) -> (end: String.Index, value: Range<String.Index>) {
        let start = text.index(after: open)
        if let close = text[start...].firstIndex(of: "\"") {
            return (text.index(after: close), start..<close)
        }
        return (text.endIndex, start..<text.endIndex)
    }
}

struct QueryParser {
    let lexemes: [QueryLexeme]
    let text: String
    var position = 0
    var issues: [QueryIssue] = []

    init(lexemes: [QueryLexeme], text: String) {
        self.lexemes = lexemes
        self.text = text
    }

    private var current: QueryLexeme? { position < lexemes.count ? lexemes[position] : nil }

    mutating func parseQuery() -> QueryNode {
        combine(parseSequence(opening: nil))
    }

    private func combine(_ nodes: [QueryNode]) -> QueryNode {
        switch nodes.count {
        case 0: return .all
        case 1: return nodes[0]
        default: return .and(nodes)
        }
    }

    private mutating func parseSequence(opening: QueryLexeme?) -> [QueryNode] {
        var nodes: [QueryNode] = []
        while let lexeme = current {
            if lexeme.kind == .close {
                position += 1
                if opening != nil { return nodes }
                issues.append(QueryIssue(range: lexeme.range, message: "This “)” has no matching “(”."))
                continue
            }
            if let node = parseOr() { nodes.append(node) }
        }
        if let opening {
            issues.append(QueryIssue(range: opening.range, message: "This “(” is never closed."))
        }
        return nodes
    }

    private mutating func parseOr() -> QueryNode? {
        guard let first = parseUnary() else { return nil }
        var options = [first]
        while current?.kind == .or {
            position += 1
            guard let next = current, next.kind != .close, next.kind != .or else { break }
            if let node = parseUnary() { options.append(node) }
        }
        return options.count == 1 ? first : .or(options)
    }

    private mutating func parseUnary() -> QueryNode? {
        guard let lexeme = current else { return nil }
        if lexeme.kind == .minus {
            position += 1
            guard let next = current, next.kind != .close else { return nil }
            return parseAtom().map { .not($0) }
        }
        return parseAtom()
    }

    private mutating func parseAtom() -> QueryNode? {
        guard let lexeme = current else { return nil }
        position += 1
        switch lexeme.kind {
        case .open:
            let inner = parseSequence(opening: lexeme)
            return inner.isEmpty ? nil : combine(inner)
        case .or:
            return .word("or")
        case .minus, .close:
            return nil
        case .term:
            return term(lexeme)
        }
    }

    private mutating func term(_ lexeme: QueryLexeme) -> QueryNode {
        let raw = String(text[lexeme.range])
        guard let key = lexeme.key else {
            let folded = TextFold.fold(lexeme.value)
            return lexeme.quoted ? .phrase(folded) : .word(folded)
        }
        let value = lexeme.value.trimmingCharacters(in: .whitespaces)
        func fallback(_ message: String) -> QueryNode {
            issues.append(QueryIssue(range: lexeme.range, message: message))
            return .word(TextFold.fold(raw))
        }
        guard !value.isEmpty else { return .word(TextFold.fold(raw)) }
        switch key {
        case "tag":
            var name = value.hasPrefix("#") ? String(value.dropFirst()) : value
            while name.hasSuffix("/") { name.removeLast() }
            guard TokenGrammar.isValidTagName(name) else { return fallback("“\(raw)” isn't a tag name. Try tag:work.") }
            return .tag(TokenGrammar.normalizedTag(name))
        case "notebook", "in":
            return .notebook(value)
        case "title":
            return .title(TextFold.fold(value))
        case "is":
            guard let filter = IsFilter(rawValue: value.lowercased()) else {
                return fallback("“\(raw)” isn't a filter. Try is:todo, is:done, is:pinned, is:untagged or is:conflict.")
            }
            return .is(filter)
        case "has":
            guard let filter = HasFilter(rawValue: value.lowercased()) else {
                return fallback("“\(raw)” isn't a filter. Try has:due, has:reminder or has:attachment.")
            }
            return .has(filter)
        default:
            let field = DateField(rawValue: key)!
            guard let filter = Self.dateFilter(value, field: field) else {
                return fallback("“\(raw)” isn't a date. Try \(key):<7d.")
            }
            return .date(field, filter)
        }
    }

    static let units: [Character: TimeInterval] = ["h": 3600, "d": 86400, "w": 7 * 86400, "m": 30 * 86400, "y": 365 * 86400]

    static func dateFilter(_ value: String, field: DateField) -> DateFilter? {
        let v = value.lowercased()
        switch v {
        case "today": return .today
        case "yesterday": return .yesterday
        case "this-week": return .thisWeek
        case "last-week": return .lastWeek
        case "this-month": return .thisMonth
        case "overdue": return field == .due ? .overdue : nil
        default: break
        }
        guard let first = v.first else { return nil }
        if first == "<" || first == ">" {
            let rest = v.dropFirst()
            if let unit = rest.last, let seconds = units[unit], rest.count > 1,
               rest.dropLast().allSatisfy(\.isASCII), let count = Int(rest.dropLast()), count >= 0 {
                let interval = TimeInterval(count) * seconds
                return first == "<" ? .within(interval) : .olderThan(interval)
            }
            guard let day = LocalDateTime(token: String(rest))?.dateOnly else { return nil }
            return first == "<" ? .before(day) : .after(day)
        }
        return LocalDateTime(token: v).map { .on($0.dateOnly) }
    }
}
