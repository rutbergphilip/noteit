import AppKit
import NoteItCore

/// Plain-text mentions of a note's title (spec §7).
enum MentionFinder {
    static let minimumTitleLength = 3
    private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    /// Whole-word matches of `title` outside links, code and the first paragraph, in text order.
    nonisolated static func ranges(of title: String, in text: NSAttributedString) -> [NSRange] {
        let needle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        let ns = text.string as NSString
        let firstParagraphEnd = ns.paragraphRange(for: NSRange(location: 0, length: 0)).upperBound
        var result: [NSRange] = []
        var search = NSRange(location: firstParagraphEnd, length: ns.length - firstParagraphEnd)
        while search.length > 0 {
            let found = ns.range(of: needle, options: options, range: search)
            guard found.location != NSNotFound, found.length > 0 else { break }
            search = NSRange(location: found.upperBound, length: ns.length - found.upperBound)
            if isWholeWord(found, in: ns), isPlainText(found, in: text, ns) { result.append(found) }
        }
        return result
    }

    /// Fast pre-check on folded text: `foldedTitle` appears with no letter or digit on either side.
    nonisolated static func mayMention(_ foldedTitle: String, inFolded text: String) -> Bool {
        guard !foldedTitle.isEmpty else { return false }
        var start = text.startIndex
        while let range = text.range(of: foldedTitle, range: start..<text.endIndex) {
            let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
            let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
            if !isWordCharacter(before), !isWordCharacter(after) { return true }
            start = text.index(after: range.lowerBound)
        }
        return false
    }

    private nonisolated static func isWordCharacter(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character.isLetter || character.isNumber
    }

    private nonisolated static func isWholeWord(_ range: NSRange, in ns: NSString) -> Bool {
        func wordChar(at index: Int) -> Bool {
            guard index >= 0, index < ns.length else { return false }
            let composed = ns.rangeOfComposedCharacterSequence(at: index)
            return isWordCharacter(ns.substring(with: composed).first)
        }
        return !wordChar(at: range.location - 1) && !wordChar(at: range.upperBound)
    }

    private nonisolated static func isPlainText(_ range: NSRange, in text: NSAttributedString, _ ns: NSString) -> Bool {
        var plain = true
        text.enumerateAttributes(in: range) { attrs, _, stop in
            if attrs[.link] != nil || EditorStyle.isInlineCode(attrs) { plain = false; stop.pointee = true }
        }
        guard plain else { return false }
        let ps = text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
        let font = text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        return EditorStyle.blockKind(paragraphStyle: ps, font: font) != .code
    }
}
