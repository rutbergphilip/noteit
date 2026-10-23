import AppKit
import NoteItCore

/// A note link found in a note body.
struct OutgoingLink: Codable, Equatable, Sendable {
    /// Stored as written; `link` parses it on read.
    var url: URL
    var text: String
    /// UTF-16 offset in the body.
    var location: Int
    /// At most 80 characters, on one line.
    var context: String
    var link: NoteLink? { NoteLink(url: url) }
}

enum LinkExtractor {
    static let maxLinksPerNote = 2_000
    static let contextLength = 80

    /// Note links only, in text order. Adjacent runs with the same URL count as one link.
    nonisolated static func links(in text: NSAttributedString) -> [OutgoingLink] {
        let ns = text.string as NSString
        var result: [OutgoingLink] = []
        var current: (url: URL, range: NSRange)?

        func finish() {
            guard let found = current else { return }
            current = nil
            guard result.count < maxLinksPerNote else { return }
            result.append(OutgoingLink(url: found.url, text: ns.substring(with: found.range),
                                       location: found.range.location,
                                       context: context(around: found.range, in: ns)))
        }

        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, range, stop in
            guard let url = linkURL(value), NoteLink(url: url) != nil else {
                finish()
                return
            }
            if let open = current, open.url == url, NSMaxRange(open.range) == range.location {
                current = (url, NSUnionRange(open.range, range))
            } else {
                finish()
                current = (url, range)
            }
            if result.count >= maxLinksPerNote { stop.pointee = true }
        }
        finish()
        return result
    }

    nonisolated static func linkURL(_ value: Any?) -> URL? {
        if let url = value as? URL { return url }
        if let string = value as? String { return URL(string: string) }
        return nil
    }

    private static let lineBreaks: Set<Character> = ["\n", "\r", "\r\n", "\u{2028}", "\u{2029}"]

    /// The link's paragraph on one line, cut to `contextLength` characters centred on the link, with `…` at cut ends.
    nonisolated static func context(around range: NSRange, in ns: NSString) -> String {
        let paragraph = ns.paragraphRange(for: range)
        func clean(_ s: String) -> [Character] {
            s.compactMap { $0 == "\u{FFFC}" ? nil : (lineBreaks.contains($0) ? " " : $0) }
        }
        let before = clean(ns.substring(with: NSRange(location: paragraph.location, length: range.location - paragraph.location)))
        let link = clean(ns.substring(with: range))
        let after = clean(ns.substring(with: NSRange(location: NSMaxRange(range), length: NSMaxRange(paragraph) - NSMaxRange(range))))
        let chars = before + link + after
        let full = String(chars).trimmingCharacters(in: .whitespaces)
        guard full.count > contextLength else { return full }

        let budget = contextLength - 2
        var start = max(0, before.count + link.count / 2 - budget / 2)
        start = min(start, max(0, chars.count - budget))
        let end = min(chars.count, start + budget)
        var snippet = String(chars[start..<end]).trimmingCharacters(in: .whitespaces)
        if start > 0 { snippet = "…" + snippet }
        if end < chars.count { snippet += "…" }
        return snippet
    }
}
