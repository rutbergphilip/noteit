import AppKit
import NoteItCore

extension NoteItTextView {
    /// The token under `point` and the temporary attribute's value, if the point is on the token's glyphs.
    func token(at point: NSPoint, key: NSAttributedString.Key) -> (value: Any, range: NSRange)? {
        guard let lm = layoutManager, let tc = textContainer, storage.length > 0 else { return nil }
        let origin = textContainerOrigin
        let local = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        let glyph = lm.glyphIndex(for: local, in: tc, fractionOfDistanceThroughGlyph: nil)
        guard lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tc).contains(local) else { return nil }
        let index = lm.characterIndexForGlyph(at: glyph)
        guard index < storage.length else { return nil }
        var range = NSRange()
        guard let value = lm.temporaryAttribute(key, atCharacterIndex: index, effectiveRange: &range) else { return nil }
        return (value, range)
    }

    /// ⌘-click on a tag shows its notes; a click on a date token opens its date editor. True when handled.
    func handleTokenClick(at point: NSPoint, event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, let (value, _) = token(at: point, key: .tokenTag), let tag = value as? String,
           let host = linkHost {
            host.store.searchText = ""
            host.store.selection = .tag(tag)
            return true
        }
        if flags.isEmpty, let onDateToken, let (value, _) = token(at: point, key: .tokenDate),
           let range = (value as? NSValue)?.rangeValue {
            onDateToken(range)
            return true
        }
        return false
    }

    /// After `#` at a tag boundary outside code and links: opens tag suggestions.
    func beginTagCompletionIfNeeded(afterTyping text: String) {
        guard text == "#", !hasMarkedText(), !inlineCompletion.isActive, canInsertNoteLink, typingAttributes[.link] == nil,
              let host = linkHost else { return }
        let caret = selectedRange()
        guard caret.length == 0, caret.location >= 1 else { return }
        if caret.location >= 2 {
            let before = nsString.substring(with: NSRange(location: caret.location - 2, length: 1))
            guard let scalar = before.unicodeScalars.first, TagCompletionSource.isBoundary(scalar) else { return }
        }
        inlineCompletion.begin(at: caret.location, source: TagCompletionSource(store: host.store))
    }
}
