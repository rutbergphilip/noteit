import Foundation

enum TokenKind: CaseIterable {
    case keyword, string, comment, number, type, property, punctuation
}

struct SyntaxToken: Equatable {
    var range: NSRange
    var kind: TokenKind
}

/// A small, dependency-free tokenizer for code block highlighting. Pure: (language, text) → tokens.
enum SyntaxHighlighter {
    struct Grammar {
        var lineComments: [String] = []
        var blockComments: [(String, String)] = []
        var quotes: Set<UInt16> = [34, 39]
        /// Quotes that may span lines (JS template literals, Go raw strings).
        var multilineQuotes: Set<UInt16> = []
        var tripleQuotes = false
        var keywords: Set<String> = []
        var literals: Set<String> = ["true", "false", "null"]
        var caseInsensitive = false
        var capitalizedTypes = true
        var identifierExtras: Set<UInt16> = [95]
        /// Characters that start a variable or attribute marker (`$x`, `@x`, `#if`).
        var sigils: [UInt16: TokenKind] = [:]
        var hashComments: Bool { lineComments.contains("#") }
    }

    static func tokenize(_ text: String, language: CodeLanguage) -> [SyntaxToken] {
        let u = Array(text.utf16)
        switch language {
        case .plain: return []
        case .html: return tokenizeMarkup(u)
        case .markdown: return tokenizeMarkdown(u)
        case .yaml: return tokenizeYAML(u)
        default: return tokenizeCode(u, grammar: grammar(for: language))
        }
    }

    // MARK: Grammars

    private static func words(_ s: String) -> Set<String> { Set(s.split(separator: " ").map(String.init)) }

    private static let cKeywords = "auto break case char const continue default do double else enum extern float for goto if inline int long register restrict return short signed sizeof static struct switch typedef union unsigned void volatile while bool NULL"
    private static let cppKeywords = cKeywords + " alignas alignof catch class constexpr const_cast decltype delete dynamic_cast explicit export friend mutable namespace new noexcept nullptr operator override private protected public reinterpret_cast static_assert static_cast template this throw try typeid typename using virtual final"

    static func grammar(for language: CodeLanguage) -> Grammar {
        var g = Grammar()
        switch language {
        case .bash:
            g.lineComments = ["#"]
            g.keywords = words("if then else elif fi for while until do done case esac in function return export local readonly declare unset shift exit source alias echo printf cd set eval exec trap select time sudo")
            g.capitalizedTypes = false
            g.identifierExtras = [95, 45]
            g.sigils = [36: .property]
            g.multilineQuotes = [34, 39]
        case .c:
            g.lineComments = ["//"]
            g.blockComments = [("/*", "*/")]
            g.keywords = words(cKeywords)
            g.sigils = [35: .keyword]
        case .cpp:
            g.lineComments = ["//"]
            g.blockComments = [("/*", "*/")]
            g.keywords = words(cppKeywords)
            g.sigils = [35: .keyword]
        case .csharp:
            g.lineComments = ["//"]
            g.blockComments = [("/*", "*/")]
            g.keywords = words("abstract as async await base bool break byte case catch char checked class const continue decimal default delegate do double else enum event explicit extern finally fixed float for foreach get goto if implicit in init int interface internal is lock long namespace new object operator out override params private protected public readonly record ref return sbyte sealed set short sizeof static string struct switch this throw try typeof uint ulong unsafe ushort using var virtual void volatile where while yield")
            g.sigils = [35: .keyword]
        case .css:
            g.blockComments = [("/*", "*/")]
            g.keywords = words("important inherit initial unset none auto solid block flex grid inline absolute relative fixed sticky")
            g.literals = []
            g.capitalizedTypes = false
            g.identifierExtras = [95, 45]
            g.sigils = [64: .keyword, 46: .type, 35: .number]
        case .go:
            g.lineComments = ["//"]
            g.blockComments = [("/*", "*/")]
            g.keywords = words("break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var bool byte error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 any")
            g.literals = words("true false nil iota")
            g.quotes = [34, 39, 96]
            g.multilineQuotes = [96]
        case .java:
            g.lineComments = ["//"]
            g.blockComments = [("/*", "*/")]
            g.keywords = words("abstract assert boolean break byte case catch char class const continue default do double else enum extends final finally float for goto if implements import instanceof int interface long native new package private protected public record return short static strictfp super switch synchronized this throw throws transient try var void volatile while yield")
            g.sigils = [64: .type]
        case .javascript, .typescript, .json:
            g.lineComments = ["//"]
            g.blockComments = [("/*", "*/")]
            g.quotes = [34, 39, 96]
            g.multilineQuotes = [96]
            g.keywords = words("async await break case catch class const continue debugger default delete do else export extends finally for from function get if import in instanceof let new of return set static super switch this throw try typeof var void while with yield")
            g.literals = words("true false null undefined NaN Infinity")
            g.identifierExtras = [95, 36]
            if language == .typescript {
                g.keywords.formUnion(words("abstract any as boolean declare enum implements interface keyof namespace never number private protected public readonly string symbol type unknown"))
                g.sigils = [64: .type]
            }
            if language == .json {
                g.keywords = []
                g.quotes = [34]
                g.multilineQuotes = []
                g.capitalizedTypes = false
            }
        case .kotlin:
            g.lineComments = ["//"]
            g.blockComments = [("/*", "*/")]
            g.tripleQuotes = true
            g.keywords = words("abstract annotation as break by catch class companion const constructor continue crossinline data do else enum expect external final finally for fun get if import in infix init inline inner interface internal is lateinit noinline object open operator out override package private protected public reified return sealed set super suspend this throw try typealias val var vararg when where while")
            g.sigils = [64: .type]
        case .php:
            g.lineComments = ["//", "#"]
            g.blockComments = [("/*", "*/")]
            g.keywords = words("abstract and array as break callable case catch class clone const continue declare default do echo else elseif empty enddeclare endfor endforeach endif endswitch endwhile extends final finally fn for foreach function global if implements include include_once instanceof insteadof interface isset list match namespace new or print private protected public readonly require require_once return static switch throw trait try unset use var while yield php")
            g.literals = words("true false null TRUE FALSE NULL")
            g.sigils = [36: .property]
        case .python:
            g.lineComments = ["#"]
            g.tripleQuotes = true
            g.keywords = words("and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield self cls print")
            g.literals = words("True False None")
            g.sigils = [64: .type]
        case .ruby:
            g.lineComments = ["#"]
            g.blockComments = [("=begin", "=end")]
            g.keywords = words("alias and begin break case class def defined? do else elsif end ensure for if in module next not or redo require require_relative rescue retry return self super then undef unless until when while yield puts attr_accessor attr_reader private protected public lambda proc")
            g.literals = words("true false nil")
            g.sigils = [64: .property, 58: .property]
            g.multilineQuotes = [34, 39]
        case .rust:
            g.lineComments = ["//"]
            g.blockComments = [("/*", "*/")]
            g.quotes = [34]
            g.multilineQuotes = [34]
            g.keywords = words("as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait type unsafe use where while i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str")
            g.literals = words("true false None Some Ok Err")
            g.sigils = [35: .type]
        case .sql:
            g.lineComments = ["--"]
            g.blockComments = [("/*", "*/")]
            g.caseInsensitive = true
            g.capitalizedTypes = false
            g.multilineQuotes = [39]
            g.keywords = words("add all alter and as asc begin between by case cascade check column commit constraint create cross database default delete desc distinct drop else end exists foreign from full group having if in index inner insert into is join key left like limit not null offset on or order outer primary references replace returning right rollback select set table then transaction union unique update using values view when where with count sum avg min max int integer bigint text varchar char boolean date timestamp real float serial")
            g.literals = words("true false")
        case .swift:
            g.lineComments = ["//"]
            g.blockComments = [("/*", "*/")]
            g.tripleQuotes = true
            g.quotes = [34]
            g.keywords = words("actor any as associatedtype async await break case catch class continue default defer deinit do else enum extension fallthrough fileprivate final for func get guard if import in indirect init inout internal is lazy let mutating nonisolated open operator override private protocol public repeat rethrows return self Self set some static struct subscript super switch throw throws try typealias var weak where while willSet didSet unowned convenience required consume borrowing consuming")
            g.literals = words("true false nil")
            g.sigils = [64: .keyword, 35: .keyword]
        case .plain, .html, .markdown, .yaml:
            break
        }
        return g
    }

    // MARK: Code

    private static func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
    private static func isLetter(_ c: UInt16) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c > 127 }
    private static func isUpper(_ c: UInt16) -> Bool { c >= 65 && c <= 90 }
    private static let punctuation: Set<UInt16> = Set("{}[]()<>=+-*/%&|^!~?:;,.\\".utf16)

    private static func hasPrefix(_ u: [UInt16], _ i: Int, _ s: String) -> Bool {
        var j = i
        for c in s.utf16 {
            guard j < u.count, u[j] == c else { return false }
            j += 1
        }
        return true
    }

    /// First match of `s` starting before `limit` (default: the end of the text).
    private static func find(_ u: [UInt16], _ s: String, from i: Int, before limit: Int? = nil) -> Int? {
        let first = s.utf16.first!
        let stop = min(limit ?? u.count, u.count)
        var j = i
        while j < stop {
            if u[j] == first, hasPrefix(u, j, s) { return j }
            j += 1
        }
        return nil
    }

    private static func lineEnd(_ u: [UInt16], from i: Int) -> Int {
        var j = i
        while j < u.count, u[j] != 10 { j += 1 }
        return j
    }

    private static func string(_ u: [UInt16], from i: Int, quote: UInt16, multiline: Bool) -> Int {
        var j = i + 1
        while j < u.count {
            let c = u[j]
            if c == 92 { j += 2; continue }
            if c == quote { return j + 1 }
            if c == 10 && !multiline { return j }
            j += 1
        }
        return u.count
    }

    private static func number(_ u: [UInt16], from i: Int) -> Int {
        var j = i
        if u[j] == 48, j + 1 < u.count, u[j + 1] == 120 || u[j + 1] == 88 || u[j + 1] == 98 || u[j + 1] == 111 { j += 2 }
        while j < u.count {
            let c = u[j]
            if isDigit(c) || isLetter(c) || c == 95 { j += 1; continue }
            if c == 46, j + 1 < u.count, isDigit(u[j + 1]) { j += 1; continue }
            if (c == 43 || c == 45), j > i, u[j - 1] == 101 || u[j - 1] == 69, !hasHexPrefix(u, i) { j += 1; continue }
            break
        }
        return j
    }

    private static func hasHexPrefix(_ u: [UInt16], _ i: Int) -> Bool {
        i + 1 < u.count && u[i] == 48 && (u[i + 1] == 120 || u[i + 1] == 88)
    }

    private static func identifierEnd(_ u: [UInt16], from i: Int, extras: Set<UInt16>) -> Int {
        var j = i
        while j < u.count, isLetter(u[j]) || isDigit(u[j]) || extras.contains(u[j]) { j += 1 }
        return j
    }

    static func tokenizeCode(_ u: [UInt16], grammar g: Grammar) -> [SyntaxToken] {
        var tokens: [SyntaxToken] = []
        func add(_ start: Int, _ end: Int, _ kind: TokenKind) {
            guard end > start else { return }
            if kind == .punctuation, let last = tokens.last, last.kind == .punctuation, NSMaxRange(last.range) == start {
                tokens[tokens.count - 1].range.length += end - start
            } else {
                tokens.append(SyntaxToken(range: NSRange(location: start, length: end - start), kind: kind))
            }
        }
        let keywords = g.caseInsensitive ? Set(g.keywords.map { $0.lowercased() }) : g.keywords
        var i = 0
        var lineStart = true
        while i < u.count {
            let c = u[i]
            if c == 10 { lineStart = true; i += 1; continue }
            if c == 32 || c == 9 || c == 13 { i += 1; continue }
            let atLineStart = lineStart
            lineStart = false

            if let (open, close) = g.blockComments.first(where: { hasPrefix(u, i, $0.0) }),
               open != "=begin" || atLineStart {
                let end = find(u, close, from: i + open.utf16.count).map { $0 + close.utf16.count } ?? u.count
                add(i, end, .comment)
                i = end
                continue
            }
            if g.lineComments.contains(where: { hasPrefix(u, i, $0) }) {
                // `#` mid-word (e.g. shell `$#`, `a#b`) isn't a comment.
                if c != 35 || i == 0 || u[i - 1] == 32 || u[i - 1] == 9 || u[i - 1] == 10 || !g.hashComments {
                    let end = lineEnd(u, from: i)
                    add(i, end, .comment)
                    i = end
                    continue
                }
            }
            if g.tripleQuotes, c == 34 || c == 39, hasPrefix(u, i, String(repeating: String(UnicodeScalar(UInt8(c))), count: 3)) {
                let delimiter = String(repeating: String(UnicodeScalar(UInt8(c))), count: 3)
                let end = find(u, delimiter, from: i + 3).map { $0 + 3 } ?? u.count
                add(i, end, .string)
                i = end
                continue
            }
            if g.quotes.contains(c) {
                let end = string(u, from: i, quote: c, multiline: g.multilineQuotes.contains(c))
                add(i, end, .string)
                i = end
                continue
            }
            if isDigit(c) || (c == 46 && i + 1 < u.count && isDigit(u[i + 1]) && (i == 0 || !isLetter(u[i - 1]))) {
                let end = number(u, from: i)
                add(i, end, .number)
                i = end
                continue
            }
            if let kind = g.sigils[c], i + 1 < u.count, isLetter(u[i + 1]) || u[i + 1] == 95 || (c == 36 && (u[i + 1] == 123 || isDigit(u[i + 1]))) {
                var end = identifierEnd(u, from: i + 1, extras: g.identifierExtras)
                if c == 36, u[i + 1] == 123 { end = min(u.count, (find(u, "}", from: i) ?? u.count - 1) + 1) }
                add(i, end, kind)
                i = end
                continue
            }
            if isLetter(c) || g.identifierExtras.contains(c) && c != 45 {
                var end = identifierEnd(u, from: i, extras: g.identifierExtras)
                if end < u.count, u[end] == 63 || u[end] == 33, g.keywords.contains(String(utf16CodeUnits: Array(u[i...end]), count: end - i + 1)) { end += 1 }
                let word = String(utf16CodeUnits: Array(u[i..<end]), count: end - i)
                let key = g.caseInsensitive ? word.lowercased() : word
                if keywords.contains(key) || g.literals.contains(word) {
                    add(i, end, .keyword)
                } else if g.capitalizedTypes, isUpper(c), end - i > 1 {
                    add(i, end, .type)
                } else if g.literals.isEmpty, end + 1 < u.count, u[end] == 58, u[end + 1] == 32 || u[end + 1] == 9 {
                    // CSS `property: value`.
                    add(i, end, .property)
                }
                i = end
                continue
            }
            if punctuation.contains(c) {
                add(i, i + 1, .punctuation)
                i += 1
                continue
            }
            i += 1
        }
        if g.keywords.isEmpty && g.quotes == [34] { markJSONKeys(u, &tokens) }
        return tokens
    }

    /// Strings directly followed by `:` are object keys.
    private static func markJSONKeys(_ u: [UInt16], _ tokens: inout [SyntaxToken]) {
        for t in tokens.indices where tokens[t].kind == .string {
            var k = NSMaxRange(tokens[t].range)
            while k < u.count, u[k] == 32 || u[k] == 9 { k += 1 }
            if k < u.count, u[k] == 58 { tokens[t].kind = .property }
        }
    }

    // MARK: Markup

    static func tokenizeMarkup(_ u: [UInt16]) -> [SyntaxToken] {
        var tokens: [SyntaxToken] = []
        func add(_ s: Int, _ e: Int, _ k: TokenKind) {
            if e > s { tokens.append(SyntaxToken(range: NSRange(location: s, length: e - s), kind: k)) }
        }
        var i = 0
        while i < u.count {
            if hasPrefix(u, i, "<!--") {
                let end = find(u, "-->", from: i + 4).map { $0 + 3 } ?? u.count
                add(i, end, .comment)
                i = end
                continue
            }
            if u[i] == 60, i + 1 < u.count, isLetter(u[i + 1]) || u[i + 1] == 47 || u[i + 1] == 33 || u[i + 1] == 63 {
                var j = i + 1
                if u[j] == 47 || u[j] == 33 || u[j] == 63 { j += 1 }
                add(i, j, .punctuation)
                let nameEnd = identifierEnd(u, from: j, extras: [95, 45, 58, 46])
                add(j, nameEnd, .keyword)
                j = nameEnd
                while j < u.count, u[j] != 62 {
                    let c = u[j]
                    if c == 34 || c == 39 {
                        let end = string(u, from: j, quote: c, multiline: true)
                        add(j, end, .string)
                        j = end
                    } else if isLetter(c) {
                        let end = identifierEnd(u, from: j, extras: [95, 45, 58, 46])
                        add(j, end, .property)
                        j = end
                    } else {
                        if c == 61 || c == 47 || c == 63 { add(j, j + 1, .punctuation) }
                        j += 1
                    }
                }
                if j < u.count { add(j, j + 1, .punctuation); j += 1 }
                i = j
                continue
            }
            if u[i] == 38, let semi = find(u, ";", from: i, before: i + 10), !u[i..<semi].contains(10) {
                add(i, semi + 1, .number)
                i = semi + 1
                continue
            }
            i += 1
        }
        return tokens
    }

    // MARK: Markdown

    static func tokenizeMarkdown(_ u: [UInt16]) -> [SyntaxToken] {
        var tokens: [SyntaxToken] = []
        func add(_ s: Int, _ e: Int, _ k: TokenKind) {
            if e > s { tokens.append(SyntaxToken(range: NSRange(location: s, length: e - s), kind: k)) }
        }
        var i = 0
        var inFence = false
        // The `](` and `)` found for a `[`; later `[`s before that `](` share it, so a line full of `[` stays linear.
        var link: (from: Int, close: Int?, paren: Int?)?
        func linkEnd(at k: Int, line: Int, lineEnd end: Int) -> (Int, Int)? {
            if let l = link, l.from >= line, l.from <= k, l.close.map({ $0 >= k }) ?? true {
                return l.close.flatMap { c in l.paren.map { (c, $0) } }
            }
            let close = find(u, "](", from: k, before: end)
            let paren = close.flatMap { find(u, ")", from: $0, before: end) }
            link = (k, close, paren)
            return close.flatMap { c in paren.map { (c, $0) } }
        }
        while i < u.count {
            let end = lineEnd(u, from: i)
            var j = i
            while j < end, u[j] == 32 { j += 1 }
            if hasPrefix(u, j, "```") || hasPrefix(u, j, "~~~") {
                add(i, end, .string)
                inFence.toggle()
            } else if inFence {
                add(i, end, .string)
            } else if j < end, u[j] == 35 {
                add(i, end, .keyword)
            } else if j < end, u[j] == 62 {
                add(i, end, .comment)
            } else {
                if j + 1 < end, u[j] == 45 || u[j] == 42 || u[j] == 43, u[j + 1] == 32 {
                    add(j, j + 1, .punctuation)
                }
                var k = j
                while k < end {
                    let c = u[k]
                    if c == 96, let close = find(u, "`", from: k + 1, before: end) {
                        add(k, close + 1, .string)
                        k = close + 1
                    } else if c == 91, let (close, paren) = linkEnd(at: k, line: i, lineEnd: end) {
                        add(k, close + 1, .type)
                        add(close + 1, paren + 1, .property)
                        k = paren + 1
                    } else if c == 42 || c == 95, k + 1 < end, u[k + 1] == c {
                        add(k, k + 2, .punctuation)
                        k += 2
                    } else {
                        k += 1
                    }
                }
            }
            i = end + 1
        }
        return tokens
    }

    // MARK: YAML

    static func tokenizeYAML(_ u: [UInt16]) -> [SyntaxToken] {
        var tokens: [SyntaxToken] = []
        func add(_ s: Int, _ e: Int, _ k: TokenKind) {
            if e > s { tokens.append(SyntaxToken(range: NSRange(location: s, length: e - s), kind: k)) }
        }
        let literals: Set<String> = ["true", "false", "null", "yes", "no", "on", "off", "~"]
        var i = 0
        while i < u.count {
            let end = lineEnd(u, from: i)
            var j = i
            while j < end, u[j] == 32 { j += 1 }
            if j < end, u[j] == 35 { add(j, end, .comment); i = end + 1; continue }
            if hasPrefix(u, j, "---") || hasPrefix(u, j, "...") { add(j, j + 3, .punctuation); i = end + 1; continue }
            if j + 1 < end, u[j] == 45, u[j + 1] == 32 {
                add(j, j + 1, .punctuation)
                j += 2
                while j < end, u[j] == 32 { j += 1 }
            }
            var valueStart = j
            var k = j
            while k < end, u[k] != 58, u[k] != 35, u[k] != 34, u[k] != 39 { k += 1 }
            if k < end, u[k] == 58, k + 1 == end || u[k + 1] == 32 {
                add(j, k, .property)
                add(k, k + 1, .punctuation)
                valueStart = k + 1
            }
            var v = valueStart
            while v < end, u[v] == 32 { v += 1 }
            var valueEnd = end
            var c = v
            while c < end {
                if u[c] == 34 || u[c] == 39 { c = string(u, from: c, quote: u[c], multiline: false); continue }
                if u[c] == 35, c > v, u[c - 1] == 32 { valueEnd = c; add(c, end, .comment); break }
                c += 1
            }
            var trimmed = valueEnd
            while trimmed > v, u[trimmed - 1] == 32 { trimmed -= 1 }
            if trimmed > v {
                let value = String(utf16CodeUnits: Array(u[v..<trimmed]), count: trimmed - v)
                if u[v] == 34 || u[v] == 39 {
                    add(v, trimmed, .string)
                } else if literals.contains(value.lowercased()) {
                    add(v, trimmed, .keyword)
                } else if Double(value) != nil {
                    add(v, trimmed, .number)
                } else if u[v] == 38 || u[v] == 42 || u[v] == 124 || u[v] == 62 {
                    add(v, trimmed, .type)
                }
            }
            i = end + 1
        }
        return tokens
    }

    // MARK: Guessing

    private static func count(_ pattern: String, in text: String, options: NSRegularExpression.Options = [.anchorsMatchLines]) -> Int {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return 0 }
        return count(re, in: text)
    }

    private static func count(_ re: NSRegularExpression, in text: String) -> Int {
        re.numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    private static let signalPatterns: [(CodeLanguage, [(String, Int)])] = [
        (.swift, [("\\bfunc \\w+\\(", 2), ("\\b(let|var) \\w+(: [A-Z]\\w*)? = ", 1), ("\\bguard \\b", 3), ("^import (SwiftUI|Foundation|UIKit|AppKit|Combine)", 4), ("@(State|Published|MainActor|objc|Observable)\\b", 3), ("\\) -> \\w", 2), ("\\bif let \\b", 3), ("\\bstruct \\w+: \\w+", 2), ("\\bprint\\(\"", 1)]),
        (.python, [("^\\s*def \\w+\\(.*\\):\\s*$", 4), ("^\\s*(from \\w[\\w.]* )?import \\w", 1), ("\\bself\\.", 2), ("\\belif\\b", 3), ("^\\s*class \\w+(\\(.*\\))?:\\s*$", 3), ("\\b(True|False|None)\\b", 1), ("^if __name__", 4), ("\\bprint\\(f?[\"']", 1)]),
        (.javascript, [("\\bfunction\\b", 2), ("\\b(const|let) \\w+ = ", 1), ("=> ", 2), ("console\\.log", 4), ("\\brequire\\(", 3), ("\\bdocument\\.", 3), ("module\\.exports", 4), ("===", 2), ("^import .* from ['\"]", 2), ("\\bexport (default|const|function)\\b", 2)]),
        (.typescript, [(": (string|number|boolean|void|any)\\b", 3), ("^\\s*(export )?interface \\w+", 3), ("^\\s*(export )?type \\w+ = ", 3), ("\\b(private|public|readonly) \\w+:", 2), ("\\bas const\\b", 3)]),
        (.go, [("^package \\w+", 5), ("\\bfunc (\\(\\w+ \\*?\\w+\\) )?\\w+\\(", 2), (" := ", 3), ("\\bfmt\\.", 4), ("\\berr != nil\\b", 4), ("^import \\(", 3)]),
        (.rust, [("\\bfn \\w+", 3), ("\\blet mut\\b", 4), ("\\bimpl\\b", 3), ("\\bpub (fn|struct|enum|mod)\\b", 3), ("\\w!\\(", 2), ("::", 1), ("&mut\\b", 3), ("\\buse \\w+::", 3)]),
        (.java, [("\\bpublic (static )?(class|void|final)\\b", 3), ("System\\.out\\.", 5), ("@Override", 4), ("\\bString\\[\\] args", 5), ("\\bprivate (final )?\\w+ \\w+;", 2), ("^import java\\.", 5)]),
        (.kotlin, [("\\bfun \\w+\\(", 4), ("\\bval \\w+", 2), ("\\bdata class\\b", 4), ("\\bprintln\\(", 1), ("\\bwhen \\(", 2)]),
        (.csharp, [("^using System", 5), ("\\bnamespace \\w+", 2), ("Console\\.Write", 5), ("\\{ get; (private )?set; \\}", 5), ("\\bpublic (async )?(void|Task|string|int)\\b", 2), ("\\bvar \\w+ = new\\b", 2)]),
        (.c, [("^#include <\\w+\\.h>", 4), ("\\bprintf\\(", 2), ("\\bint main\\(", 3), ("\\bmalloc\\(", 3), ("->", 1), ("^#define ", 2)]),
        (.cpp, [("^#include <\\w+>", 4), ("\\bstd::", 4), ("\\bcout <<", 4), ("\\btemplate ?<", 4), ("\\bnamespace \\w+", 1), ("::", 1), ("\\bnullptr\\b", 3)]),
        (.ruby, [("^\\s*def \\w+[!?]?(\\(.*\\))?\\s*$", 3), ("^\\s*end\\s*$", 2), ("\\bputs\\b", 3), ("\\.each do \\|", 4), ("^require ['\"]", 3), ("\\battr_(accessor|reader)\\b", 4), ("\\bdo \\|\\w+\\|", 3)]),
        (.php, [("<\\?php", 8), ("\\$this->", 5), ("\\becho \\$", 3), ("\\$\\w+ = ", 2), ("\\bfunction \\w+\\(\\$", 3)]),
        (.sql, [("\\bselect\\b[\\s\\S]*\\bfrom\\b", 4), ("\\binsert into\\b", 5), ("\\bcreate table\\b", 5), ("\\bwhere\\b", 1), ("\\b(inner|left) join\\b", 3), ("\\bupdate \\w+ set\\b", 4), ("\\bgroup by\\b|\\border by\\b", 2)]),
        (.css, [("^\\s*+[.#]?[\\w-]++(?:[ ,>+~.#:]++[\\w-]++)*+\\s*\\{\\s*$", 2), ("^\\s*[a-z-]+:\\s*[^;{]+;\\s*$", 2), ("@media\\b", 4), ("\\b\\d+(px|rem|em|vh|vw)\\b", 2), ("#[0-9a-fA-F]{3,6};", 2)]),
        (.yaml, [("^\\s*[\\w-]+:( .+)?$", 1), ("^\\s*- [\\w\"']", 1), ("^---\\s*$", 2)]),
        (.markdown, [("^#{1,6} \\S", 3), ("\\[[^\\]]+\\]\\([^)]+\\)", 3), ("^\\s*[-*] \\[[ x]\\] ", 4), ("\\*\\*\\w[^*]*\\*\\*", 2), ("^> ", 2)]),
        (.bash, [("^#!/(usr/)?bin/(env )?(ba|z)?sh", 8), ("^\\s*\\$ \\w", 4), ("^\\s*(sudo|brew|apt(-get)?|npm|yarn|pip3?|git|cd|ls|mkdir|curl|chmod|export|echo|swift|xcodebuild|docker|make|cat|rm|cp|mv) ", 2), ("\\bfi\\s*$", 3), ("\\bdone\\s*$", 2), ("\\$\\{?\\w+\\}?", 1), (" \\| (grep|sed|awk|xargs|head|tail|sort)\\b", 3), (" --?\\w", 1)]),
    ]

    /// `signalPatterns`, compiled once.
    static let signals: [(CodeLanguage, [(NSRegularExpression, Int)])] = signalPatterns.map { language, patterns in
        let options: NSRegularExpression.Options = language == .sql ? [.anchorsMatchLines, .caseInsensitive] : [.anchorsMatchLines]
        return (language, patterns.map { pattern, weight in
            guard let re = try? NSRegularExpression(pattern: pattern, options: options) else {
                preconditionFailure("bad language signal \(pattern)")
            }
            return (re, weight)
        })
    }

    /// Only the start of a long block is looked at, so guessing stays cheap.
    static let guessLimit = 4000

    /// Best guess for a code block's language, or nil if nothing stands out.
    static func guessLanguage(_ text: String) -> CodeLanguage? {
        var sample = text
        if (text as NSString).length > guessLimit {
            sample = (text as NSString).substring(to: guessLimit)
            if let lastLine = sample.lastIndex(of: "\n") { sample = String(sample[..<lastLine]) }
        }
        let trimmed = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("<?php") { return .php }
        if trimmed.hasPrefix("#!") {
            if trimmed.hasPrefix("#!/usr/bin/env python") || trimmed.hasPrefix("#!/usr/bin/python") { return .python }
            if trimmed.contains("ruby") { return .ruby }
            if trimmed.contains("node") { return .javascript }
            return .bash
        }
        if let first = trimmed.first, first == "{" || first == "[",
           let data = trimmed.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil {
            return .json
        }
        if trimmed.hasPrefix("<"), count("</\\w+>|/>|<!DOCTYPE|<\\?xml", in: trimmed) > 0 { return .html }

        var best: (CodeLanguage, Int)?
        var scores: [CodeLanguage: Int] = [:]
        for (language, patterns) in signals {
            var score = 0
            for (re, weight) in patterns {
                score += min(count(re, in: trimmed), 3) * weight
            }
            scores[language] = score
        }
        // TypeScript is JavaScript plus types.
        if let ts = scores[.typescript], ts > 0 { scores[.typescript] = ts + (scores[.javascript] ?? 0) }
        if let cpp = scores[.cpp], cpp > 0 { scores[.cpp] = cpp + (scores[.c] ?? 0) / 2 }
        for (language, _) in signals {
            let score = scores[language] ?? 0
            if score >= 2, score > (best?.1 ?? 0) { best = (language, score) }
        }
        return best?.0
    }
}
