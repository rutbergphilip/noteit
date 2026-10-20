import AppKit
import NoteItSync

/// Decides whether pasted text is Markdown source worth converting.
enum MarkdownPasteDetector {
    private static let blockPatterns = [
        "^ {0,3}#{1,6}[ \\t]+\\S",
        "^[ \\t]*(?:[-*+]|\\d{1,9}[.)])[ \\t]+\\S",
        "^ {0,3}>[ \\t]*\\S",
        "^[ \\t]*(?:```|~~~)",
        "^ {0,3}([-*_])(?:[ \\t]*\\1){2,}[ \\t]*$",
        "^[^\\n]*\\|[^\\n]*\\n[ \\t]*\\|?[ \\t]*:?-+:?[ \\t]*(?:\\|[ \\t]*:?-+:?[ \\t]*)+\\|?[ \\t]*$",
    ]
    private static let inlinePatterns = [
        "(?<![\\w*])\\*\\*[^\\s*](?:[^\\n]*?[^\\s*])?\\*\\*(?![\\w*])",
        "(?<![\\w_])__[^\\s_](?:[^\\n]*?[^\\s_])?__(?![\\w_])",
        "`[^`\\n]+`",
        "\\[[^\\]\\n]+\\]\\([^()\\s]+(?:[ \\t]+\"[^\"\\n]*\")?\\)",
        "(?<!~)~~[^\\s~](?:[^\\n]*?[^\\s~])?~~(?!~)",
    ]
    private static let regexes: [NSRegularExpression] = (blockPatterns + inlinePatterns).map {
        try! NSRegularExpression(pattern: $0, options: [.anchorsMatchLines])
    }

    /// Bare URLs, whose underscores and asterisks aren't emphasis.
    private static let bareURL = try! NSRegularExpression(pattern: "(?<![(<\\w])[A-Za-z][A-Za-z0-9+.-]*://\\S+")

    static func looksLikeMarkdown(_ text: String) -> Bool {
        let lines = MarkdownReader.lines(of: text).joined(separator: "\n")
        let normalized = bareURL.stringByReplacingMatches(in: lines, range: NSRange(location: 0, length: (lines as NSString).length), withTemplate: "")
        let range = NSRange(location: 0, length: (normalized as NSString).length)
        return regexes.contains { $0.firstMatch(in: normalized, range: range) != nil }
    }

    /// Whether the pasteboard's rich text, if any, is only the plain text with colours on it (an editor or
    /// terminal copying source) rather than rendered content such as a web page.
    static func richTextIsSource(on pboard: NSPasteboard, plain: String) -> Bool {
        let types = pboard.types ?? []
        let rich: [(NSPasteboard.PasteboardType, NSAttributedString.DocumentType)] = [(.rtfd, .rtfd), (.rtf, .rtf), (.html, .html)]
        var sawRich = false
        for (type, documentType) in rich where types.contains(type) {
            sawRich = true
            guard let data = pboard.data(forType: type) else { continue }
            var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: documentType]
            if documentType == .html { options[.characterEncoding] = String.Encoding.utf8.rawValue }
            if let rendered = try? NSAttributedString(data: data, options: options, documentAttributes: nil) {
                return sameText(rendered.string, plain)
            }
        }
        if types.contains(NSPasteboard.PasteboardType("Apple Web Archive pasteboard type")) { return false }
        return !sawRich
    }

    static func sameText(_ a: String, _ b: String) -> Bool {
        func words(_ s: String) -> [Substring] { s.split(whereSeparator: { $0.isWhitespace }) }
        return words(a) == words(b)
    }
}

extension NoteItTextView {
    /// Marks copies made in NoteIt so pasting them never reinterprets their text as Markdown.
    static let ownCopyType = NSPasteboard.PasteboardType(AppIdentity.bundleID + ".editor-copy")

    /// ⌘V: Markdown source becomes formatted text and anything pasted into a code block stays literal.
    /// Returns false when the normal paste should run instead.
    func pasteMarkdown(from pboard: NSPasteboard) -> Bool {
        guard isEditable, let types = pboard.types, !types.contains(Self.ownCopyType) else { return false }
        let sel = selectedRange()
        if paragraphRanges(for: sel).contains(where: { blockKind(ofParagraph: $0) == .code }) {
            return pastePlainText(from: pboard)
        }
        guard let plain = pboard.string(forType: .string), MarkdownPasteDetector.looksLikeMarkdown(plain),
              MarkdownPasteDetector.richTextIsSource(on: pboard, plain: plain) else { return false }
        let converted = MarkdownReader.attributedString(from: plain, resolveImage: { _ in nil })
        guard converted.length > 0 else { return false }
        if let inline = inlineFragment(plain, converted) {
            return insertPasted(inline, in: sel, actionName: "Paste")
        }
        guard tableBlock(at: sel.location) == nil else { return false }
        return insertBlocks(converted, endsWithNewline: plain.hasSuffix("\n") || plain.hasSuffix("\r"), in: sel)
    }

    /// ⇧⌘V: the clipboard's plain text in the style at the insertion point.
    @discardableResult
    func pastePlainText(from pboard: NSPasteboard) -> Bool {
        guard isEditable, let string = pboard.string(forType: .string) else { return false }
        let text = MarkdownReader.lines(of: string).joined(separator: "\n")
        var attrs = typingAttributes
        attrs[.link] = nil
        attrs[.attachment] = nil
        return insertPasted(NSAttributedString(string: text, attributes: attrs), in: selectedRange(), actionName: "Paste and Match Style")
    }

    /// One line of body text, restyled to continue the paragraph at the insertion point.
    private func inlineFragment(_ plain: String, _ converted: NSAttributedString) -> NSAttributedString? {
        guard !plain.trimmingCharacters(in: .newlines).contains(where: \.isNewline) else { return nil }
        let ns = converted.string as NSString
        var content = NSRange(location: 0, length: ns.length)
        if ns.hasSuffix("\n") { content.length -= 1 }
        guard content.length > 0, ns.rangeOfCharacter(from: .newlines, options: [], range: content).location == NSNotFound,
              EditorStyle.listMarker(in: ns.substring(with: content)) == nil else { return nil }
        let attrs = converted.attributes(at: 0, effectiveRange: nil)
        guard EditorStyle.blockKind(paragraphStyle: attrs[.paragraphStyle] as? NSParagraphStyle, font: attrs[.font] as? NSFont) == .body else { return nil }

        var base = typingAttributes
        for key in [NSAttributedString.Key.link, .attachment, .inlineCodeDisplay, .strikethroughStyle, .backgroundColor] { base[key] = nil }
        if let font = base[.font] as? NSFont, EditorStyle.isMonospaced(font) { base[.font] = nil }
        let baseFont = (base[.font] as? NSFont) ?? EditorStyle.bodyFont
        let fm = NSFontManager.shared
        let result = NSMutableAttributedString()
        converted.enumerateAttributes(in: content) { run, range, _ in
            var a = base
            if let font = run[.font] as? NSFont {
                if EditorStyle.isMonospaced(font) {
                    a[.font] = CodeStyler.codeFont(forText: baseFont)
                } else {
                    var f = baseFont
                    let traits = fm.traits(of: font)
                    if traits.contains(.boldFontMask) { f = fm.convert(f, toHaveTrait: .boldFontMask) }
                    if traits.contains(.italicFontMask) { f = fm.convert(f, toHaveTrait: .italicFontMask) }
                    a[.font] = f
                }
            }
            for key in [NSAttributedString.Key.link, .strikethroughStyle, .backgroundColor, .attachment] where run[key] != nil {
                a[key] = run[key]
            }
            result.append(NSAttributedString(string: ns.substring(with: range), attributes: a))
        }
        return result
    }

    /// Blocks start on a line of their own and leave the text after the insertion point on its own line.
    private func insertBlocks(_ converted: NSAttributedString, endsWithNewline: Bool, in sel: NSRange) -> Bool {
        let startPara = paragraphRange(at: sel.location)
        let endPara = paragraphRange(at: NSMaxRange(sel))
        let contentEnd = NSMaxRange(contentRange(of: endPara))
        let hasTextAfter = NSMaxRange(sel) < contentEnd
        let before = nsString.substring(with: NSRange(location: startPara.location, length: sel.location - startPara.location))

        var range = sel
        let out = NSMutableAttributedString()
        if !before.isEmpty {
            if !hasTextAfter, let m = EditorStyle.listMarker(in: before), m.length == (before as NSString).length {
                range = NSRange(location: startPara.location, length: NSMaxRange(sel) - startPara.location)
            } else {
                var attrs = storage.attributes(at: sel.location - 1, effectiveRange: nil)
                attrs[.link] = nil
                attrs[.attachment] = nil
                out.append(NSAttributedString(string: "\n", attributes: attrs))
            }
        }
        let blocks = NSMutableAttributedString(attributedString: converted)
        let keepNewline = endsWithNewline || hasTextAfter
        if !keepNewline, blocks.string.hasSuffix("\n") {
            blocks.deleteCharacters(in: NSRange(location: blocks.length - 1, length: 1))
        }
        out.append(blocks)
        var caret = out.length
        let endsDocument = contentEnd == storage.length
        if keepNewline, !hasTextAfter, !endsDocument {
            // The paragraph's own line break would otherwise leave an empty line in its old style.
            range.length = contentEnd + 1 - range.location
            out.append(NSAttributedString(string: "\n", attributes: EditorStyle.bodyAttributes))
            caret = out.length - 1
        }
        guard insertPasted(out, in: range, actionName: "Paste", caretOffset: caret) else { return true }
        if keepNewline, !hasTextAfter { typingAttributes = EditorStyle.bodyAttributes }
        let end = selectedRange().location
        renumberList(around: range.location)
        renumberList(around: max(range.location, end - 1))
        return true
    }

    @discardableResult
    private func insertPasted(_ text: NSAttributedString, in range: NSRange, actionName: String, caretOffset: Int? = nil) -> Bool {
        guard shouldChangeText(in: range, replacementString: text.string) else { return false }
        storage.replaceCharacters(in: range, with: text)
        didChangeText()
        setSelectedRange(clamp(NSRange(location: range.location + (caretOffset ?? text.length), length: 0)))
        undoManager?.setActionName(actionName)
        return true
    }
}
