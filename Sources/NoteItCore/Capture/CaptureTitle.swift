import Foundation

/// A note title taken from the first line of captured text. Moved out of `CaptureFormatter` in
/// foundations Task 1.3.
public enum CaptureTitle {
    public static let maxLength = 60
    public static let scanLimit = 4_096

    /// The first non-empty line within `scanLimit` characters of the first non-whitespace one.
    public static func firstLine(of text: String) -> String? {
        let start = text.firstIndex(where: { !$0.isWhitespace }) ?? text.endIndex
        let head = String(text[start...].prefix(scanLimit))
        for raw in normalizedLines(head) {
            if let line = singleLine(String(raw)) {
                return line
            }
        }
        return nil
    }

    /// Collapses every run of whitespace, including line and paragraph breaks, to one space.
    public static func singleLine(_ text: String?) -> String? {
        guard let text else { return nil }
        let words = text.split(whereSeparator: { $0.isWhitespace })
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    public static func truncated(_ title: String) -> String {
        guard title.count > maxLength else { return title }
        let limit = maxLength - 1
        let head = title.prefix(limit)
        let next = title[head.endIndex]
        var cut = head
        if !next.isWhitespace, let space = head.lastIndex(where: { $0.isWhitespace }), head.distance(from: head.startIndex, to: space) >= limit / 2 {
            cut = head[..<space]
        }
        let kept = String(cut).trimmingCharacters(in: .whitespaces)
        return kept + "…"
    }

    private static func normalizedLines(_ text: String) -> [Substring] {
        var normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        normalized = normalized.replacingOccurrences(of: "\r", with: "\n")
        normalized = normalized.replacingOccurrences(of: "\u{2029}", with: "\n")
        normalized = normalized.replacingOccurrences(of: "\u{2028}", with: "\n")
        return normalized.split(separator: "\n", omittingEmptySubsequences: false)
    }
}
