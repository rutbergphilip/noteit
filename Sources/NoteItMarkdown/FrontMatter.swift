import Foundation

/// The YAML front matter of a note file (markdown-storage spec §3.3). NoteIt reads and writes a small fixed subset
/// with its own parser; every other key is kept verbatim in `extra`.
public struct FrontMatter: Sendable, Equatable {
    public var id: UUID?
    public var created: Date?
    public var updated: Date?
    public var pinned: Bool
    public var deleted: Date?
    public var conflictOf: UUID?
    public var conflictSource: String?
    /// Written on placeholders only; informational when read (the sealed file decides whether a note is locked).
    public var locked: Bool
    /// Read only: `written()` ignores it. The `tags:` lines themselves stay in `extra`, so a foreign file keeps them.
    public var tags: [String]
    /// Unknown keys, verbatim and in their original order: lines joined with "\n", no final newline.
    public var extra: String

    public static let empty = FrontMatter()

    public init(id: UUID? = nil, created: Date? = nil, updated: Date? = nil, pinned: Bool = false, deleted: Date? = nil,
                conflictOf: UUID? = nil, conflictSource: String? = nil, locked: Bool = false, tags: [String] = [],
                extra: String = "") {
        self.id = id
        self.created = created
        self.updated = updated
        self.pinned = pinned
        self.deleted = deleted
        self.conflictOf = conflictOf
        self.conflictSource = conflictSource
        self.locked = locked
        self.tags = tags
        self.extra = extra
    }

    // MARK: Reading

    /// `bodyStart` is the index after the closing `---` line, or `text.startIndex` when the text has no front matter.
    public static func read(_ text: String) throws -> (FrontMatter, bodyStart: String.Index) {
        let lines = Lines(text)
        guard let first = lines.next(after: text.startIndex), first.content == "---" else {
            return (.empty, text.startIndex)
        }
        var entries: [[Lines.Line]] = []
        var cursor = first.end
        var lineNumber = 1
        var closed: String.Index?
        while let line = lines.next(after: cursor) {
            lineNumber += 1
            cursor = line.end
            if line.content == "---" || line.content == "..." {
                closed = line.end
                break
            }
            let isContinuation = line.content.first.map { $0 == " " || $0 == "\t" || $0 == "-" } ?? true
            if isContinuation || line.content.hasPrefix("#") {
                if entries.isEmpty { entries.append([]) }
                entries[entries.count - 1].append(line.numbered(lineNumber))
            } else {
                guard key(of: line.content) != nil else { throw MarkdownError.invalidFrontMatter(line: lineNumber) }
                entries.append([line.numbered(lineNumber)])
            }
        }
        guard let bodyStart = closed else { throw MarkdownError.invalidFrontMatter(line: 1) }

        var result = FrontMatter()
        var extraLines: [String] = []
        for entry in entries {
            guard let head = entry.first, let key = key(of: head.content) else {
                extraLines += entry.map(\.content)
                continue
            }
            let value = unquoted(String(head.content.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces))
            let fail = MarkdownError.invalidFrontMatter(line: head.number)
            switch key {
            case "id":
                guard let id = UUID(uuidString: value) else { throw fail }
                result.id = id
            case "created":
                guard let date = parseDate(value) else { throw fail }
                result.created = date
            case "updated":
                guard let date = parseDate(value) else { throw fail }
                result.updated = date
            case "deleted":
                guard let date = parseDate(value) else { throw fail }
                result.deleted = date
            case "pinned":
                guard let flag = parseBool(value) else { throw fail }
                result.pinned = flag
            case "locked":
                guard let flag = parseBool(value) else { throw fail }
                result.locked = flag
            case "conflict-of":
                guard let id = UUID(uuidString: value) else { throw fail }
                result.conflictOf = id
            case "conflict-source":
                result.conflictSource = value
            case "tags":
                result.tags = parseTags(value, continuation: entry.dropFirst().map(\.content))
                extraLines += entry.map(\.content)
            default:
                extraLines += entry.map(\.content)
            }
        }
        result.extra = extraLines.joined(separator: "\n")
        return (result, bodyStart)
    }

    /// The key of a `key: value` line, nil for anything else.
    private static func key(of line: String) -> String? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let after = line.index(after: colon)
        guard after == line.endIndex || line[after] == " " || line[after] == "\t" else { return nil }
        let key = String(line[..<colon])
        guard !key.isEmpty, !key.contains(" "), !key.contains("\t") else { return nil }
        return key
    }

    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" else { return value }
        let inner = String(value.dropFirst().dropLast())
        guard first == "\"" else { return inner.replacingOccurrences(of: "''", with: "'") }
        return inner.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func parseBool(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "true", "yes", "on": true
        case "false", "no", "off": false
        default: nil
        }
    }

    private static func parseTags(_ value: String, continuation: [String]) -> [String] {
        var raw: [String] = []
        if value.hasPrefix("[") && value.hasSuffix("]") {
            raw = value.dropFirst().dropLast().split(separator: ",").map(String.init)
        } else if !value.isEmpty {
            raw = value.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        }
        for line in continuation {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") { raw.append(String(trimmed.dropFirst(2))) }
        }
        return raw.map { unquoted($0.trimmingCharacters(in: .whitespaces)) }
            .map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 }
            .filter { !$0.isEmpty }
    }

    /// ISO 8601 with `Z`, an offset or no zone (read as UTC); fractional seconds and date-only values are accepted.
    static func parseDate(_ value: String) -> Date? {
        var text = value.replacingOccurrences(of: " ", with: "T")
        if text.count == 10 { text += "T00:00:00Z" }
        let hasZone = text.hasSuffix("Z") || text.range(of: #"[+-]\d\d:?\d\d$"#, options: .regularExpression) != nil
        if !hasZone { text += "Z" }
        for options: ISO8601DateFormatter.Options in [.withInternetDateTime, [.withInternetDateTime, .withFractionalSeconds]] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    static func formatDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = .withInternetDateTime
        return formatter.string(from: date)
    }

    // MARK: Writing

    /// "" when there is nothing to write; otherwise ends with "---\n".
    public func written() -> String {
        var lines: [String] = []
        if let id { lines.append("id: \(id.uuidString)") }
        if let created { lines.append("created: \(Self.formatDate(created))") }
        if let updated { lines.append("updated: \(Self.formatDate(updated))") }
        if pinned { lines.append("pinned: true") }
        if let deleted { lines.append("deleted: \(Self.formatDate(deleted))") }
        if let conflictOf { lines.append("conflict-of: \(conflictOf.uuidString)") }
        if let conflictSource { lines.append("conflict-source: \(Self.quoted(conflictSource))") }
        if locked { lines.append("locked: true") }
        if !extra.isEmpty { lines.append(extra) }
        guard !lines.isEmpty else { return "" }
        return "---\n" + lines.joined(separator: "\n") + "\n---\n"
    }

    private static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// Lines of a string without copying it; `content` has no line ending (LF or CRLF).
struct Lines {
    struct Line {
        var content: String
        var start: String.Index
        /// After the line ending.
        var end: String.Index
        var number = 0

        func numbered(_ number: Int) -> Line {
            var copy = self
            copy.number = number
            return copy
        }
    }

    let text: String

    init(_ text: String) {
        self.text = text
    }

    func next(after index: String.Index) -> Line? {
        let utf8 = text.utf8
        guard index < utf8.endIndex else { return nil }
        var end = index
        while end < utf8.endIndex, utf8[end] != UInt8(ascii: "\n") { end = utf8.index(after: end) }
        let after = end < utf8.endIndex ? utf8.index(after: end) : end
        var contentEnd = end
        if contentEnd > index, utf8[utf8.index(before: contentEnd)] == UInt8(ascii: "\r") {
            contentEnd = utf8.index(before: contentEnd)
        }
        return Line(content: String(decoding: utf8[index..<contentEnd], as: UTF8.self), start: index, end: after)
    }
}
