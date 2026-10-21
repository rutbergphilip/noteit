import AppKit
import NoteItCore

extension NSAttributedString.Key {
    /// Temporary attribute: the fill colour of a token chip `NoteItLayoutManager` draws behind `#tag`, `@due` and
    /// `@remind` tokens.
    static let tokenChip = NSAttributedString.Key("NoteItTokenChip")
    /// Temporary attribute: the tag path under a `#tag` token, for ⌘-click.
    static let tokenTag = NSAttributedString.Key("NoteItTokenTag")
    /// Temporary attribute: the range of a `@due` or `@remind` token, for the date popover.
    static let tokenDate = NSAttributedString.Key("NoteItTokenDate")
}

/// Styles tokens as chips with temporary attributes, so nothing is written into the note. Code and links are
/// skipped, as when tags are read.
@MainActor
final class TokenStyler {
    static let editDelay: TimeInterval = 0.15
    static let tagFill = NSColor.controlAccentColor.withAlphaComponent(0.14)
    static let dueFill = NSColor.systemOrange.withAlphaComponent(0.16)
    static let overdueFill = NSColor.systemRed.withAlphaComponent(0.18)
    static let remindFill = NSColor.systemPurple.withAlphaComponent(0.15)
    static let doneFill = NSColor.quaternaryLabelColor
    private static let keys: [NSAttributedString.Key] = [.tokenChip, .tokenTag, .tokenDate, .foregroundColor]

    unowned let textView: NSTextView
    var today: () -> LocalDateTime = { LocalDateTime(Date(), calendar: .current, includeTime: false) }
    private var pendingRange: NSRange?
    private var work: DispatchWorkItem?

    init(textView: NSTextView) {
        self.textView = textView
    }

    func noteEdit(_ range: NSRange) {
        pendingRange = pendingRange.map { NSUnionRange($0, range) } ?? range
        guard work == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.work = nil
                if let range = self.pendingRange {
                    self.pendingRange = nil
                    self.restyle(range: range)
                }
            }
        }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.editDelay, execute: item)
    }

    func restyleAll() {
        guard let length = textView.textStorage?.length else { return }
        restyle(range: NSRange(location: 0, length: length))
    }

    /// Restyles the paragraphs around `range`.
    func restyle(range: NSRange) {
        guard let storage = textView.textStorage, let lm = textView.layoutManager, storage.length > 0 else { return }
        let length = storage.length
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: length))
        let start = min(clamped.location, length - 1)
        let para = (storage.string as NSString).paragraphRange(
            for: NSRange(location: start, length: max(min(clamped.length, length - start), 0)))

        var cursor = para.location
        while cursor < NSMaxRange(para) {
            var effective = NSRange()
            let chip = lm.temporaryAttribute(.tokenChip, atCharacterIndex: cursor, longestEffectiveRange: &effective, in: para)
            if chip != nil {
                for key in Self.keys { lm.removeTemporaryAttribute(key, forCharacterRange: effective) }
            }
            cursor = max(NSMaxRange(effective), cursor + 1)
        }

        let masked = NoteStore.maskedForTokens(storage.attributedSubstring(from: para))
        let today = today()
        for token in TokenGrammar.tokens(inMasked: masked) {
            let range = NSRange(location: para.location + token.range.location, length: token.range.length)
            let fill: NSColor
            switch token.kind {
            case .tag(let path):
                fill = Self.tagFill
                lm.addTemporaryAttribute(.tokenTag, value: path, forCharacterRange: range)
                lm.addTemporaryAttribute(.foregroundColor, value: NSColor.controlAccentColor, forCharacterRange: range)
            case .due(let date):
                fill = date.dateOnly < today ? Self.overdueFill : Self.dueFill
                lm.addTemporaryAttribute(.tokenDate, value: NSValue(range: range), forCharacterRange: range)
            case .remind(_, let done):
                fill = done ? Self.doneFill : Self.remindFill
                lm.addTemporaryAttribute(.tokenDate, value: NSValue(range: range), forCharacterRange: range)
            }
            lm.addTemporaryAttribute(.tokenChip, value: fill, forCharacterRange: range)
        }
        lm.invalidateDisplay(forCharacterRange: para)
    }
}
