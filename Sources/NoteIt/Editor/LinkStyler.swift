import AppKit
import NoteItCore

extension NSAttributedString.Key {
    /// Layout-manager temporary attribute marking ranges `LinkStyler` styled, so it can clear only its own styling.
    static let linkStyled = NSAttributedString.Key("NoteItLinkStyled")
}

/// Colors links with layout-manager temporary attributes (spec §2), so nothing is written into the note: web links
/// blue and underlined, note links in the accent color, unresolved grey with a dotted underline, deleted targets
/// struck through, missing targets faint.
@MainActor
final class LinkStyler {
    static let editDelay: TimeInterval = 0.15

    unowned let textView: NSTextView
    var resolve: ((NoteLink) -> LinkResolution)?
    private var pendingRange: NSRange?
    private var work: DispatchWorkItem?

    init(textView: NSTextView) {
        self.textView = textView
    }

    private var storage: NSTextStorage? { textView.textStorage }

    func noteEdit(_ range: NSRange) {
        pendingRange = pendingRange.map { NSUnionRange($0, range) } ?? range
        guard work == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.work = nil
                if let range = self.pendingRange {
                    self.pendingRange = nil
                    self.style(in: range)
                }
            }
        }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.editDelay, execute: item)
    }

    func restyleAll() {
        guard let storage else { return }
        style(in: NSRange(location: 0, length: storage.length))
    }

    /// Styles the paragraphs around `range`.
    func style(in range: NSRange) {
        guard let storage, let lm = textView.layoutManager else { return }
        let length = storage.length
        guard length > 0 else { return }
        let ns = storage.string as NSString
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: length))
        let start = min(clamped.location, length - 1)
        let para = ns.paragraphRange(for: NSRange(location: start, length: max(min(clamped.length, length - start), 0)))

        var cursor = para.location
        while cursor < NSMaxRange(para) {
            var effective = NSRange()
            let marked = lm.temporaryAttribute(.linkStyled, atCharacterIndex: cursor, longestEffectiveRange: &effective, in: para)
            if marked != nil {
                for key in [NSAttributedString.Key.foregroundColor, .underlineStyle, .strikethroughStyle, .linkStyled] {
                    lm.removeTemporaryAttribute(key, forCharacterRange: effective)
                }
            }
            cursor = max(NSMaxRange(effective), cursor + 1)
        }

        storage.enumerateAttribute(.link, in: para) { value, run, _ in
            guard let value else { return }
            let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
            guard let url else { return }
            for (key, attribute) in attributes(for: url) {
                lm.addTemporaryAttribute(key, value: attribute, forCharacterRange: run)
            }
            lm.addTemporaryAttribute(.linkStyled, value: true, forCharacterRange: run)
        }
    }

    func attributes(for url: URL) -> [NSAttributedString.Key: Any] {
        guard let link = NoteLink(url: url) else {
            return [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
        }
        switch resolve?(link) ?? .note(UUID(), heading: nil) {
        case .note:
            return [.foregroundColor: NSColor.controlAccentColor]
        case .unresolved:
            return [.foregroundColor: NSColor.secondaryLabelColor,
                    .underlineStyle: NSUnderlineStyle.single.union(.patternDot).rawValue]
        case .deleted:
            return [.foregroundColor: NSColor.secondaryLabelColor,
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue]
        case .missing:
            return [.foregroundColor: NSColor.tertiaryLabelColor]
        }
    }
}
