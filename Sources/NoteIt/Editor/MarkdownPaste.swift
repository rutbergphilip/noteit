import AppKit
import NoteItSync

/// Decides whether pasted text is Markdown source worth converting. Anything unclear stays plain text.
enum MarkdownPasteDetector {
    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }

    /// Each of these is enough on its own.
    private static let strongSignals: [NSRegularExpression] = [
        "^ {0,3}#{1,6}[ \\t]+\\S",
        "^[ \\t]*[-*+] \\[[ xX]\\](?:[ \\t]|$)",
        "\\[[^\\]\\n]+\\]\\(https?://[^()\\s]+(?:[ \\t]+\"[^\"\\n]*\")?\\)",
        "(?<![\\w*])\\*\\*[^\\s*](?:[^\\n]*?[^\\s*])?\\*\\*(?![\\w*(])",
        "^ {0,3}>[ \\t]+\\S",
        "^[^\\n]*\\|[^\\n]*\\n[ \\t]*\\|?[ \\t]*:?-+:?[ \\t]*(?:\\|[ \\t]*:?-+:?[ \\t]*)+\\|?[ \\t]*$",
    ].map(regex)
    private static let fence = regex("^[ \\t]*(?:```|~~~)")
    private static let listItem = regex("^[ \\t]*(?:[-*+]|\\d{1,9}[.)]) \\S")
    private static let commentStar = regex("^[ \\t]+\\*")

    /// Bare URLs, whose underscores and asterisks aren't emphasis.
    private static let bareURL = regex("(?<![(<\\w])[A-Za-z][A-Za-z0-9+.-]*://\\S+")

    private static let codeStarts = ["def ", "class ", "import ", "from ", "func ", "fn ", "#include", "#!", "//", "/*"]

    static func looksLikeMarkdown(_ text: String) -> Bool {
        let lines = MarkdownReader.lines(of: text)
        var hasFencedBlock = false
        var outside: [String] = []
        var fenced: [String]?
        for line in lines {
            if matches(fence, line) {
                if fenced == nil {
                    fenced = [line]
                } else {
                    fenced = nil
                    hasFencedBlock = true
                }
            } else if fenced != nil {
                fenced?.append(line)
            } else {
                outside.append(line)
            }
        }
        outside += fenced ?? []
        if looksLikeCode(outside) { return false }
        if hasFencedBlock { return true }

        let joined = outside.joined(separator: "\n")
        let normalized = bareURL.stringByReplacingMatches(in: joined, range: NSRange(location: 0, length: (joined as NSString).length), withTemplate: "")
        if strongSignals.contains(where: { matches($0, normalized) }) { return true }
        let inComment = joined.contains("/**") || joined.contains("*/")
        let items = outside.filter { matches(listItem, $0) && !(inComment && matches(commentStar, $0)) }
        return items.count >= 2
    }

    /// Diffs, and text where many lines read like a programming language.
    private static func looksLikeCode(_ lines: [String]) -> Bool {
        if lines.contains(where: { $0.hasPrefix("diff --git") || $0.hasPrefix("@@ ") || $0.hasPrefix("+++ ") || $0.hasPrefix("--- a/") }) {
            return true
        }
        let changed = lines.filter { $0.hasPrefix("+") || $0.hasPrefix("-") }
        let indented = changed.filter { $0.dropFirst().hasPrefix("  ") || $0.dropFirst().hasPrefix("\t") }
        if !changed.isEmpty, indented.count * 2 > changed.count { return true }

        let inComment = lines.contains { $0.contains("/*") || $0.contains("*/") }
        let nonBlank = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !nonBlank.isEmpty else { return false }
        let codeLike = nonBlank.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return ["{", "}", ";", "):"].contains(where: trimmed.hasSuffix)
                || codeStarts.contains(where: trimmed.hasPrefix)
                || (inComment && matches(commentStar, line))
        }
        return Double(codeLike.count) >= 0.3 * Double(nonBlank.count)
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    /// Whether the pasteboard's rich text, if any, is only the plain text with colours on it (an editor or
    /// terminal copying source) rather than rendered content such as a web page or a rich-text document.
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
                return sameText(rendered.string, plain) && carriesOnlyColour(rendered)
            }
        }
        if types.contains(NSPasteboard.PasteboardType("Apple Web Archive pasteboard type")) { return false }
        return !sawRich
    }

    /// No links, lines, bold or italic, lists, tables or attachments, and a single font family.
    static func carriesOnlyColour(_ text: NSAttributedString) -> Bool {
        var families = Set<String>()
        var onlyColour = true
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attrs, _, stop in
            let underline = (attrs[.underlineStyle] as? Int ?? 0) != 0
            let strikethrough = (attrs[.strikethroughStyle] as? Int ?? 0) != 0
            let style = attrs[.paragraphStyle] as? NSParagraphStyle
            var styled = attrs[.link] != nil || attrs[.attachment] != nil || underline || strikethrough
                || style?.textLists.isEmpty == false || style?.textBlocks.isEmpty == false
            if let font = attrs[.font] as? NSFont {
                styled = styled || !font.fontDescriptor.symbolicTraits.isDisjoint(with: [.bold, .italic])
                families.insert(font.familyName ?? font.fontName)
            }
            if styled || families.count > 1 {
                onlyColour = false
                stop.pointee = true
            }
        }
        return onlyColour
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
        guard tableBlock(at: sel.location) == nil, tableBlock(at: NSMaxRange(sel)) == nil,
              !paragraphRanges(for: sel).contains(where: { tableBlock(at: $0.location) != nil }) else { return false }
        return insertBlocks(converted, endsWithNewline: plain.last?.isNewline == true, in: sel)
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
        // A table needs the line after it, or there is no way to type below it.
        let endsWithTable = blocks.length > 1
            && ((blocks.attribute(.paragraphStyle, at: blocks.length - 2, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks.isEmpty == false)
        let keepNewline = endsWithNewline || hasTextAfter || endsWithTable
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
