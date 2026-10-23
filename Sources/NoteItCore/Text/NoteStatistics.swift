import Foundation

/// Word, character and reading-time counts for a note's plain text, shown in Note Info.
public struct NoteStatistics: Equatable, Sendable {
    public var words: Int
    /// Characters including spaces and line breaks, without attachment placeholders.
    public var characters: Int

    /// Reading speed used for the estimate, in words per minute.
    public static let wordsPerMinute = 200

    public init(words: Int, characters: Int) {
        self.words = words
        self.characters = characters
    }

    public init(text: String) {
        // Images and files sit in the text as U+FFFC; they're neither words nor characters.
        let clean = text.replacingOccurrences(of: "\u{FFFC}", with: "")
        let spaced = text.replacingOccurrences(of: "\u{FFFC}", with: " ")
        var count = 0
        spaced.enumerateSubstrings(in: spaced.startIndex..<spaced.endIndex, options: [.byWords, .substringNotRequired]) { _, _, _, _ in
            count += 1
        }
        self.words = count
        self.characters = clean.count
    }

    /// Whole minutes, rounded up; 0 for an empty note.
    public var readingMinutes: Int {
        words == 0 ? 0 : (words + Self.wordsPerMinute - 1) / Self.wordsPerMinute
    }

    /// "Less than a minute", "1 min" or "12 min"; "—" for an empty note.
    public var readingTimeText: String {
        switch readingMinutes {
        case 0: "—"
        case 1: words < Self.wordsPerMinute / 2 ? "Less than a minute" : "1 min"
        case let minutes: "\(minutes) min"
        }
    }
}
