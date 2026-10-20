import AppKit
import NoteItSync

/// Decides whether pasted text is Markdown source worth converting. Anything unclear stays plain text.
enum MarkdownPasteDetector {
    /// Longer pastes skip detection and paste as plain text.
    static let maxLength = 200_000
    /// Converting a line longer than this can stall the main thread, so such pastes stay plain text.
    static let maxLineLength = 5_000

    // Every pattern here runs in linear time: runs are possessive and can't overlap what follows them.
    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }

    /// Each of these is enough on its own. A `#` heading isn't: shell and config files start comments with it.
    private static let strongSignals: [NSRegularExpression] = [
        "^[ \\t]*+[-*+] \\[[ xX]\\](?:[ \\t]|$)",
        "\\[[^\\[\\]\\n]++\\]\\(https?://[^()\\s]++(?:[ \\t]++\"[^\"\\n]*+\")?\\)",
        "^ {0,3}>[ \\t]++\\S",
    ].map(regex)
    private static let boldOpen = regex("(?<![\\w*])\\*\\*[^\\s*]")
    private static let boldClose = regex("[^\\s*]\\*\\*(?![\\w*(])")
    private static let tableDelimiter = regex("^[ \\t]*+\\|?+[ \\t]*+:?-++:?[ \\t]*+(?:\\|[ \\t]*+:?-++:?[ \\t]*+)++\\|?[ \\t]*+$")
    private static let fence = regex("^[ \\t]*+(?:```|~~~)")
    private static let listItem = regex("^[ \\t]*+(?:[-*+]|\\d{1,9}[.)]) \\S")
    private static let commentStar = regex("^[ \\t]++\\*")
    private static let envLine = regex("^[A-Z_][A-Z0-9_]*+=")

    private static let codeStarts = ["def ", "class ", "import ", "from ", "func ", "fn ", "#include", "#!", "//", "/*"]

    static func looksLikeMarkdown(_ text: String) -> Bool {
        guard (text as NSString).length <= maxLength else { return false }
        let all = MarkdownReader.lines(of: text)
        let lines = all.dropFirst(frontMatterLineCount(all))
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
        let normalized = removingBareURLs(joined)
        if strongSignals.contains(where: { matches($0, normalized) }) || hasBold(normalized) || hasTable(normalized) {
            return true
        }
        let inComment = joined.contains("/**") || joined.contains("*/")
        let items = outside.filter { matches(listItem, $0) && !(inComment && matches(commentStar, $0)) }
        return items.count >= 2
    }

    static func hasLine(longerThan limit: Int, in text: String) -> Bool {
        var run = 0
        for unit in text.utf16 {
            if unit == 0x0A || unit == 0x0D || unit == 0x2028 || unit == 0x2029 || unit == 0x85 {
                run = 0
            } else {
                run += 1
                if run > limit { return true }
            }
        }
        return false
    }

    /// The lines of a leading `---` YAML block such as an Obsidian note's front matter, or 0.
    static func frontMatterLineCount(_ lines: [String]) -> Int {
        func isEnd(_ line: String, _ marks: [String]) -> Bool { marks.contains(line.trimmingCharacters(in: .whitespaces)) }
        guard let first = lines.first, isEnd(first, ["---"]),
              let end = lines.dropFirst().firstIndex(where: { isEnd($0, ["---", "..."]) }) else { return 0 }
        var hasKey = false
        for line in lines[1..<end] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if trimmed.hasPrefix("- ") || line.first == " " || line.first == "\t" {
                guard hasKey else { return 0 }
                continue
            }
            guard yamlKey(line) != nil else { return 0 }
            hasKey = true
        }
        return hasKey ? end + 1 : 0
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
        // Less-indented lines before the current one, each with whether it opens a YAML map: a bare `key:` or a `- key:` item.
        var outer: [(indent: Int, opensMap: Bool)] = []
        var codeLike = 0
        for line in nonBlank {
            let indent = line.prefix { $0 == " " || $0 == "\t" }.count
            while let last = outer.last, last.indent >= indent { outer.removeLast() }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let config: Bool
            let opensMap: Bool
            if trimmed.hasPrefix("- ") {
                // `- key: value` starts a map in a YAML list; the item counts as config only under a YAML parent.
                opensMap = yamlKey(String(trimmed.dropFirst(2)))?.lowercase == true
                config = opensMap && outer.last?.opensMap == true
            } else if let key = yamlKey(line) {
                config = indent == 0 ? key.lowercase : outer.last?.opensMap == true
                opensMap = key.opensMap
            } else {
                config = matches(envLine, line)
                opensMap = false
            }
            outer.append((indent, opensMap))
            if config || ["{", "}", ";", "):"].contains(where: trimmed.hasSuffix) || codeStarts.contains(where: trimmed.hasPrefix)
                || (inComment && matches(commentStar, line)) || isPathOrGlob(trimmed) {
                codeLike += 1
            }
        }
        return Double(codeLike) >= 0.3 * Double(nonBlank.count)
    }

    /// A line starting with optional indentation and `key:` followed by a space, a tab or the line's end.
    private static func yamlKey(_ line: String) -> (lowercase: Bool, opensMap: Bool)? {
        var rest = Substring(line).unicodeScalars.drop { $0 == " " || $0 == "\t" }
        guard let first = rest.first, first == "_" || ("a"..."z").contains(first) || ("A"..."Z").contains(first) else { return nil }
        rest = rest.drop { isWord($0) || $0 == "." || $0 == "-" }
        guard rest.first == ":" else { return nil }
        let after = rest.dropFirst()
        guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }
        return (first == "_" || ("a"..."z").contains(first), after.allSatisfy { $0 == " " || $0 == "\t" })
    }

    /// A single path or glob such as `build/`, `*.log` or `.DS_Store`.
    private static func isPathOrGlob(_ line: String) -> Bool {
        let token = line.hasPrefix("!") ? line.dropFirst() : Substring(line)
        var hasWord = false
        for scalar in token.unicodeScalars {
            if isWord(scalar) {
                hasWord = true
            } else if !".*?/[]-".unicodeScalars.contains(scalar) {
                return false
            }
        }
        return hasWord && (line.contains("/") || line.hasPrefix(".") || line.contains("*.") || line.contains(".*"))
    }

    /// `**bold**` within one line.
    private static func hasBold(_ text: String) -> Bool {
        let ns = text as NSString
        var location = 0
        while location < ns.length {
            let newline = ns.range(of: "\n", options: .literal, range: NSRange(location: location, length: ns.length - location)).location
            let lineEnd = newline == NSNotFound ? ns.length : newline
            let line = NSRange(location: location, length: lineEnd - location)
            if let open = boldOpen.firstMatch(in: text, options: .withTransparentBounds, range: line) {
                let from = open.range.location + 2
                if boldClose.firstMatch(in: text, options: .withTransparentBounds, range: NSRange(location: from, length: lineEnd - from)) != nil {
                    return true
                }
            }
            location = lineEnd + 1
        }
        return false
    }

    /// A GFM table: a line with a `|` followed by a delimiter row.
    private static func hasTable(_ text: String) -> Bool {
        let ns = text as NSString
        var found = false
        tableDelimiter.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, stop in
            guard let at = match?.range.location, at > 0, ns.character(at: at - 1) == 0x0A else { return }
            let previous = ns.range(of: "\n", options: [.literal, .backwards], range: NSRange(location: 0, length: at - 1))
            let start = previous.location == NSNotFound ? 0 : NSMaxRange(previous)
            if ns.range(of: "|", options: .literal, range: NSRange(location: start, length: at - 1 - start)).location != NSNotFound {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    /// Drops bare URLs such as `https://example.com/a_b*`, whose underscores and asterisks aren't emphasis.
    /// A URL starts at a letter not preceded by `(`, `<` or a word character.
    private static func removingBareURLs(_ text: String) -> String {
        let ns = text as NSString
        let out = NSMutableString()
        var copied = 0
        var search = 0
        func char(_ i: Int) -> unichar { ns.character(at: i) }
        func isLetter(_ c: unichar) -> Bool { (0x41...0x5A).contains(c) || (0x61...0x7A).contains(c) }
        func isScheme(_ c: unichar) -> Bool { isLetter(c) || (0x30...0x39).contains(c) || c == 0x2B || c == 0x2E || c == 0x2D }
        func isSpace(_ c: unichar) -> Bool { Unicode.Scalar(c).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false }
        func blocksURL(_ c: unichar) -> Bool { c == 0x28 || c == 0x3C || Unicode.Scalar(c).map(isWord) == true }
        while search < ns.length {
            let separator = ns.range(of: "://", options: .literal, range: NSRange(location: search, length: ns.length - search)).location
            guard separator != NSNotFound else { break }
            var runStart = separator
            while runStart > copied, isScheme(char(runStart - 1)) { runStart -= 1 }
            let start = (runStart..<separator).first { isLetter(char($0)) && ($0 == 0 || !blocksURL(char($0 - 1))) }
            var end = separator + 3
            if let start {
                while end < ns.length, !isSpace(char(end)) { end += 1 }
                if end > separator + 3 {
                    out.append(ns.substring(with: NSRange(location: copied, length: start - copied)))
                    copied = end
                    search = end
                    continue
                }
            }
            search = separator + 1
        }
        out.append(ns.substring(from: copied))
        return out as String
    }

    private static func isWord(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "_" || CharacterSet.alphanumerics.contains(scalar)
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

    /// No links, strikethrough, lists, tables or attachments, and a single font family. Bold, italic and
    /// underline count as syntax styling in a monospaced font, and as formatting otherwise.
    static func carriesOnlyColour(_ text: NSAttributedString) -> Bool {
        var families = Set<String>()
        var allMonospaced = true
        var emphasis = false
        var onlyColour = true
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attrs, _, stop in
            let style = attrs[.paragraphStyle] as? NSParagraphStyle
            let strikethrough = (attrs[.strikethroughStyle] as? Int ?? 0) != 0
            var styled = attrs[.link] != nil || attrs[.attachment] != nil || strikethrough
                || style?.textLists.isEmpty == false || style?.textBlocks.isEmpty == false
            emphasis = emphasis || (attrs[.underlineStyle] as? Int ?? 0) != 0
            if let font = attrs[.font] as? NSFont {
                emphasis = emphasis || !font.fontDescriptor.symbolicTraits.isDisjoint(with: [.bold, .italic])
                allMonospaced = allMonospaced && EditorStyle.isMonospaced(font)
                families.insert(font.familyName ?? font.fontName)
            }
            styled = styled || families.count > 1 || (emphasis && !allMonospaced)
            if styled {
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
        let lines = MarkdownReader.lines(of: plain)
        let frontMatter = MarkdownPasteDetector.frontMatterLineCount(lines)
        let markdown = lines.dropFirst(frontMatter).joined(separator: "\n")
        guard !MarkdownPasteDetector.hasLine(longerThan: MarkdownPasteDetector.maxLineLength, in: markdown) else { return false }
        let converted = NSMutableAttributedString(attributedString: MarkdownReader.attributedString(from: markdown, resolveImage: { _ in nil }))
        guard converted.length > 0 else { return false }
        if frontMatter > 0 {
            let verbatim = lines.prefix(frontMatter).joined(separator: "\n") + "\n"
            converted.insert(NSAttributedString(string: verbatim, attributes: EditorStyle.bodyAttributes), at: 0)
        }
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
