import AppKit

/// Matching and replacement for the in-note find bar. Ranges are UTF-16 (`NSString`) ranges.
enum FindReplaceEngine {
    struct Options: Equatable {
        var matchCase = false
        var wholeWord = false
        var regex = false
    }

    enum Failure: Error, Equatable {
        case invalidRegex
    }

    /// More matches than this are not collected (keeps highlighting responsive in huge notes).
    static let matchLimit = 10_000

    static func matches(in text: String, query: String, options: Options, limit: Int? = matchLimit) throws -> [NSRange] {
        guard !query.isEmpty, !text.isEmpty else { return [] }
        let regex = try expression(for: query, options: options)
        let ns = text as NSString
        var ranges: [NSRange] = []
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { result, _, stop in
            guard let range = result?.range, range.length > 0 else { return }
            if options.wholeWord, !isWholeWord(range, in: ns) { return }
            ranges.append(range)
            if let limit, ranges.count >= limit { stop.pointee = true }
        }
        return ranges
    }

    /// The text that replaces `match`: `template` with `$1`-style captures expanded in regex mode, and
    /// `template` as typed otherwise.
    static func replacement(for match: NSRange, in text: String, query: String, template: String, options: Options) -> String {
        guard options.regex, let regex = try? expression(for: query, options: options) else { return template }
        let ns = text as NSString
        guard NSMaxRange(match) <= ns.length else { return template }
        let searchRange = NSRange(location: match.location, length: ns.length - match.location)
        guard let result = regex.firstMatch(in: text, options: [.anchored, .withTransparentBounds], range: searchRange),
              result.range == match
        else { return template }
        return regex.replacementString(for: result, in: text, offset: 0, template: template)
    }

    static func expression(for query: String, options: Options) throws -> NSRegularExpression {
        var regexOptions: NSRegularExpression.Options = []
        if !options.matchCase { regexOptions.insert(.caseInsensitive) }
        if options.regex {
            regexOptions.insert(.anchorsMatchLines)
        } else {
            regexOptions.insert(.ignoreMetacharacters)
        }
        do {
            return try NSRegularExpression(pattern: query, options: regexOptions)
        } catch {
            throw Failure.invalidRegex
        }
    }

    /// A match is a whole word when no word character continues it on either side.
    private static func isWholeWord(_ range: NSRange, in text: NSString) -> Bool {
        if range.location > 0 {
            let before = text.rangeOfComposedCharacterSequence(at: range.location - 1)
            let first = text.rangeOfComposedCharacterSequence(at: range.location)
            if isWordCharacter(text.substring(with: before)), isWordCharacter(text.substring(with: first)) { return false }
        }
        let end = NSMaxRange(range)
        if end < text.length {
            let after = text.rangeOfComposedCharacterSequence(at: end)
            let last = text.rangeOfComposedCharacterSequence(at: end - 1)
            if isWordCharacter(text.substring(with: after)), isWordCharacter(text.substring(with: last)) { return false }
        }
        return true
    }

    private static let wordCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))

    private static func isWordCharacter(_ character: String) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        return wordCharacters.contains(scalar)
    }
}

/// Applies replacements to a text view as single undoable edits that keep the replaced text's formatting.
@MainActor
enum FindReplaceApplier {
    /// Replaces `ranges` (any order, non-overlapping) with `replacements`. Each replacement takes the
    /// attributes found at the start of its range. Returns false if the text view refused the change.
    @discardableResult
    static func replace(_ ranges: [NSRange], with replacements: [String], in textView: NSTextView, actionName: String) -> Bool {
        guard textView.isEditable, let storage = textView.textStorage, !ranges.isEmpty, ranges.count == replacements.count else { return false }
        let pairs = zip(ranges, replacements)
            .filter { NSMaxRange($0.0) <= storage.length }
            .sorted { $0.0.location > $1.0.location }
        guard let first = pairs.last?.0, let last = pairs.first?.0 else { return false }
        let undo = textView.undoManager
        textView.breakUndoCoalescing()
        undo?.beginUndoGrouping()
        defer { undo?.endUndoGrouping() }
        if pairs.count <= batchThreshold {
            let sortedRanges = pairs.map { NSValue(range: $0.0) }
            guard textView.shouldChangeText(inRanges: sortedRanges, replacementStrings: pairs.map(\.1)) else { return false }
            storage.beginEditing()
            for (range, string) in pairs {
                storage.replaceCharacters(in: range, with: replacement(string, at: range, in: storage))
            }
            storage.endEditing()
        } else {
            // Many ranges make NSTextView's per-range undo bookkeeping quadratic, so edit their span at once.
            let span = NSUnionRange(first, last)
            let edited = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: span))
            for (range, string) in pairs {
                let local = NSRange(location: range.location - span.location, length: range.length)
                edited.replaceCharacters(in: local, with: replacement(string, at: range, in: storage))
            }
            guard textView.shouldChangeText(in: span, replacementString: edited.string) else { return false }
            storage.beginEditing()
            storage.replaceCharacters(in: span, with: edited)
            storage.endEditing()
        }
        textView.didChangeText()
        undo?.setActionName(actionName)
        return true
    }

    static let batchThreshold = 200

    private static func replacement(_ string: String, at range: NSRange, in storage: NSTextStorage) -> NSAttributedString {
        var attributes = storage.attributes(at: range.location, effectiveRange: nil)
        attributes[.attachment] = nil
        return NSAttributedString(string: string, attributes: attributes)
    }
}
