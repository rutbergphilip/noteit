import AppKit

/// Markdown-as-you-type and smart Return/Delete behaviors. Each conversion replaces the trigger
/// keystroke, so a single ⌘Z restores the literal markdown.
extension NoteItTextView {
    private static let boldRegex = try! NSRegularExpression(pattern: "\\*\\*([^*\\s](?:[^*\\n]*[^*\\s])?)\\*$")
    private static let italicRegex = try! NSRegularExpression(pattern: "(?:^|(?<=[^*\\w]))\\*([^*\\s](?:[^*\\n]*[^*\\s])?)$")
    private static let codeRegex = try! NSRegularExpression(pattern: "`([^`\\n]*[^`\\s][^`\\n]*)$")
    private static let strikeRegex = try! NSRegularExpression(pattern: "~~([^~\\s](?:[^~\\n]*[^~\\s])?)~$")
    private static let numberedRegex = try! NSRegularExpression(pattern: "^(\\d{1,3})[.)]$")

    // MARK: Typing triggers

    /// With `dryRun`, only reports whether typing `text` would trigger a conversion.
    func handleMarkdownTrigger(_ text: String, dryRun: Bool = false) -> Bool {
        guard (text as NSString).length == 1 else { return false }
        let sel = selectedRange()
        guard let para = paragraphRanges(for: sel).first else { return false }
        let kind = blockKind(ofParagraph: para)
        guard kind != .code, kind != .divider else { return false }
        if let font = typingAttributes[.font] as? NSFont, EditorStyle.isMonospaced(font), text != "`" { return false }
        let prefixRange = NSRange(location: para.location, length: sel.location - para.location)
        let prefix = nsString.substring(with: prefixRange)

        switch text {
        case " ":
            return handleBlockShortcut(prefix: prefix, para: para, dryRun: dryRun)
        case "*":
            if let m = Self.boldRegex.firstMatch(in: prefix, range: NSRange(location: 0, length: (prefix as NSString).length)) {
                return convertInline(match: m, para: para, closingLength: 2, openingLength: 2, name: "Bold", dryRun: dryRun) { s, r in
                    s.enumerateAttribute(.font, in: r) { v, sub, _ in
                        s.addAttribute(.font, value: NSFontManager.shared.convert((v as? NSFont) ?? EditorStyle.bodyFont, toHaveTrait: .boldFontMask), range: sub)
                    }
                }
            }
            if let m = Self.italicRegex.firstMatch(in: prefix, range: NSRange(location: 0, length: (prefix as NSString).length)) {
                return convertInline(match: m, para: para, closingLength: 0, openingLength: 1, name: "Italic", dryRun: dryRun) { s, r in
                    s.enumerateAttribute(.font, in: r) { v, sub, _ in
                        s.addAttribute(.font, value: NSFontManager.shared.convert((v as? NSFont) ?? EditorStyle.bodyFont, toHaveTrait: .italicFontMask), range: sub)
                    }
                }
            }
        case "`":
            if let m = Self.codeRegex.firstMatch(in: prefix, range: NSRange(location: 0, length: (prefix as NSString).length)) {
                return convertInline(match: m, para: para, closingLength: 0, openingLength: 1, name: "Inline Code", dryRun: dryRun) { s, r in
                    s.addAttributes(EditorStyle.inlineCodeAttributes, range: r)
                }
            }
        case "~":
            if let m = Self.strikeRegex.firstMatch(in: prefix, range: NSRange(location: 0, length: (prefix as NSString).length)) {
                return convertInline(match: m, para: para, closingLength: 1, openingLength: 2, name: "Strikethrough", dryRun: dryRun) { s, r in
                    s.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: r)
                }
            }
        default:
            break
        }
        return false
    }

    /// Replaces `opening + content + closing(already typed part)` with styled content.
    private func convertInline(
        match: NSTextCheckingResult, para: NSRange, closingLength: Int, openingLength: Int, name: String, dryRun: Bool,
        style: (NSMutableAttributedString, NSRange) -> Void
    ) -> Bool {
        if dryRun { return true }
        let whole = NSRange(location: para.location + match.range.location, length: match.range.length)
        let contentRange = NSRange(location: para.location + match.range(at: 1).location, length: match.range(at: 1).length)
        // The italic regex may include a leading non-* character via lookbehind; whole starts at the opening marker.
        let start = contentRange.location - openingLength
        let replaceRange = NSRange(location: start, length: NSMaxRange(whole) - start)
        let plainAttrs = typingAttributes
        let styled = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: contentRange))
        style(styled, NSRange(location: 0, length: styled.length))
        breakUndoCoalescing()
        guard replace(replaceRange, with: styled, select: NSRange(location: start + styled.length, length: 0), actionName: name) else { return false }
        typingAttributes = plainAttrs
        _ = closingLength
        return true
    }

    private func handleBlockShortcut(prefix: String, para: NSRange, dryRun: Bool) -> Bool {
        guard marker(ofParagraph: para) == nil else { return false }
        if dryRun {
            let ns = prefix as NSString
            return ["#", "##", "###", ">", "-", "*", "+", "•", "[]", "[ ]", "[x]", "[X]"].contains(prefix)
                || Self.numberedRegex.firstMatch(in: prefix, range: NSRange(location: 0, length: ns.length)) != nil
        }
        let prefixRange = NSRange(location: para.location, length: (prefix as NSString).length)

        func strip() {
            // Deleting the prefix can leave an empty last paragraph whose typing attributes NSTextView
            // takes from the previous line (e.g. a nested list); keep this paragraph's own style.
            let own = storage.attributes(at: para.location, effectiveRange: nil)
            breakUndoCoalescing()
            replace(prefixRange, with: NSAttributedString(), select: NSRange(location: para.location, length: 0))
            var attrs = own
            attrs[.link] = nil
            attrs[.attachment] = nil
            typingAttributes = attrs
        }

        switch prefix {
        case "#", "##", "###":
            strip()
            setBlock(prefix == "#" ? .title : prefix == "##" ? .heading : .subheading)
            return true
        case ">":
            strip()
            setBlock(.quote)
            return true
        case "-", "*", "+", "•":
            strip()
            toggleList(.bullet)
            return true
        case "[]", "[ ]", "[x]", "[X]":
            strip()
            let checked = prefix.lowercased() == "[x]"
            toggleList(.checklist)
            if checked {
                let p = paragraphRange(at: selectedRange().location)
                toggleCheckbox(atParagraphStart: p.location)
            }
            return true
        default:
            break
        }
        let ns = prefix as NSString
        if let m = Self.numberedRegex.firstMatch(in: prefix, range: NSRange(location: 0, length: ns.length)),
           let n = Int(ns.substring(with: m.range(at: 1))) {
            strip()
            let current = paragraphRanges(for: selectedRange()).first ?? para
            apply([listEdit(current, kind: .numbered, number: n)], actionName: "Numbered List")
            renumberList(around: selectedRange().location)
            let ps = attributes(ofParagraph: paragraphRanges(for: selectedRange()).first ?? current)[.paragraphStyle]
            var attrs = EditorStyle.bodyAttributes
            attrs[.paragraphStyle] = ps
            typingAttributes = attrs
            return true
        }
        return false
    }

    // MARK: Return

    func handleNewline() -> Bool {
        let sel = selectedRange()
        guard let para = paragraphRanges(for: sel).first else { return false }
        let text = content(of: para)
        let textLength = (text as NSString).length
        let kind = blockKind(ofParagraph: para)
        let caretAtEnd = sel.location == para.location + textLength
        let inTable = tableBlock(at: sel.location) != nil
        let existingPS = attributes(ofParagraph: para)[.paragraphStyle] as? NSParagraphStyle

        if kind == .divider {
            let next = NSMaxRange(para)
            if next >= storage.length {
                replace(NSRange(location: storage.length, length: 0), with: NSAttributedString(string: "\n", attributes: EditorStyle.bodyAttributes),
                        select: NSRange(location: storage.length + 1, length: 0))
                typingAttributes = EditorStyle.bodyAttributes
            } else {
                setSelectedRange(NSRange(location: next, length: 0))
            }
            return true
        }

        let m = marker(ofParagraph: para)
        if m == nil, kind != .code, !inTable, caretAtEnd {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                breakUndoCoalescing()
                let code = NSAttributedString(string: "\n", attributes: EditorStyle.attributes(for: .code, existing: existingPS))
                replace(para, with: code, select: NSRange(location: para.location, length: 0), actionName: "Code Block")
                typingAttributes = EditorStyle.attributes(for: .code, existing: existingPS)
                return true
            }
            if ["---", "***", "___", "—-", "—", "–-"].contains(trimmed) {
                breakUndoCoalescing()
                let divider = NSMutableAttributedString(attributedString: EditorStyle.divider())
                let hadNewline = para.length > textLength
                let followed = NSMaxRange(para) < storage.length
                if !followed {
                    divider.append(NSAttributedString(string: hadNewline ? "\n" : "", attributes: EditorStyle.bodyAttributes))
                }
                replace(para, with: divider, select: NSRange(location: para.location + EditorStyle.divider().length, length: 0), actionName: "Divider")
                typingAttributes = EditorStyle.bodyAttributes
                return true
            }
        }

        if let m {
            let level = EditorStyle.listLevel(of: existingPS)
            if textLength <= m.length {
                breakUndoCoalescing()
                if level > 0 {
                    changeIndent(by: -1)
                } else {
                    apply([removeListEdit(para)], actionName: "End List")
                    typingAttributes = EditorStyle.attributes(for: .body, existing: existingPS)
                }
                return true
            }
            guard sel.location >= para.location + m.length else { return false }
            let nextKind: ListMarker.Kind
            switch m.kind {
            case .bullet: nextKind = .bullet
            case .numbered(let n): nextKind = .numbered(n + 1)
            case .checkbox: nextKind = .checkbox(checked: false)
            }
            var contentAttrs = sel.location > para.location ? storage.attributes(at: sel.location - 1, effectiveRange: nil) : typingAttributes
            contentAttrs[.link] = nil
            contentAttrs[.attachment] = nil
            if case .checkbox = m.kind {
                contentAttrs[.strikethroughStyle] = nil
                contentAttrs[.foregroundColor] = nil
            }
            let insertion = NSMutableAttributedString(string: "\n", attributes: contentAttrs)
            insertion.append(NSAttributedString(string: EditorStyle.markerText(nextKind, level: level),
                                                attributes: EditorStyle.markerAttributes(level: level, existing: existingPS)))
            breakUndoCoalescing()
            replace(sel, with: insertion, select: NSRange(location: sel.location + insertion.length, length: 0), actionName: "New Item")
            // Text moved onto the new line keeps checked styling; reset it for the fresh item.
            if case .checkbox = m.kind {
                let newPara = paragraphRange(at: sel.location + insertion.length)
                let contentPart = contentRange(of: newPara)
                let tail = NSRange(location: sel.location + insertion.length, length: NSMaxRange(contentPart) - (sel.location + insertion.length))
                if tail.length > 0 {
                    editAttributes(in: tail) { ts in
                        ts.removeAttribute(.strikethroughStyle, range: tail)
                        ts.removeAttribute(.foregroundColor, range: tail)
                    }
                }
            }
            renumberList(around: selectedRange().location)
            typingAttributes = contentAttrs
            scrollRangeToVisible(selectedRange())
            return true
        }

        if EditorStyle.isHeading(kind), caretAtEnd, !inTable {
            let headingAttrs = attributes(ofParagraph: para)
            let hasNewline = para.length > textLength
            let bodyAttrs = EditorStyle.attributes(for: .body, existing: existingPS)
            let s = NSMutableAttributedString(string: "\n", attributes: headingAttrs)
            if hasNewline { s.append(NSAttributedString(string: "\n", attributes: bodyAttrs)) }
            let range = NSRange(location: sel.location, length: hasNewline ? 1 : 0)
            breakUndoCoalescing()
            replace(range, with: s, select: NSRange(location: sel.location + 1, length: 0))
            typingAttributes = bodyAttrs
            scrollRangeToVisible(selectedRange())
            return true
        }

        if kind == .quote && text.isEmpty {
            breakUndoCoalescing()
            setBlock(.body)
            return true
        }

        if kind == .code && text.isEmpty && para.location > 0 {
            let prev = paragraphRange(at: para.location - 1)
            let nextIsCode = NSMaxRange(para) < storage.length && blockKind(ofParagraph: paragraphRange(at: NSMaxRange(para))) == .code
            if blockKind(ofParagraph: prev) == .code && !nextIsCode {
                breakUndoCoalescing()
                setBlock(.body)
                return true
            }
        }
        return false
    }

    // MARK: Delete

    func handleDeleteBackward() -> Bool {
        let sel = selectedRange()
        if storage.length == 0 {
            if blockKind(ofParagraph: NSRange(location: 0, length: 0)) != .body {
                typingAttributes = EditorStyle.bodyAttributes
                needsDisplay = true
                formattingDidChange?()
                return true
            }
            return false
        }
        guard let para = paragraphRanges(for: sel).first else { return false }
        let offset = sel.location - para.location
        if let m = marker(ofParagraph: para), offset == m.length {
            breakUndoCoalescing()
            apply([removeListEdit(para, keepIndent: true)], actionName: "Remove List")
            renumberList(around: NSMaxRange(para) < storage.length ? NSMaxRange(para) : para.location)
            setSelectedRange(NSRange(location: para.location, length: 0))
            return true
        }
        guard offset == 0, sel.location > 0 else { return false }
        let kind = blockKind(ofParagraph: para)
        let prev = paragraphRange(at: sel.location - 1)
        let prevKind = blockKind(ofParagraph: prev)
        if prevKind == .divider {
            breakUndoCoalescing()
            replace(prev, with: NSAttributedString(), select: NSRange(location: prev.location, length: 0), actionName: "Delete Divider")
            return true
        }
        if (kind == .code || kind == .quote) && prevKind != kind {
            breakUndoCoalescing()
            setBlock(.body)
            return true
        }
        if tableBlock(at: sel.location) == nil, tableBlock(at: prev.location) != nil {
            // Don't merge text into the last table cell; just move the caret into the table.
            if content(of: para).isEmpty, para.length > 0 {
                breakUndoCoalescing()
                replace(para, with: NSAttributedString(), select: NSRange(location: max(0, para.location - 1), length: 0))
            } else {
                setSelectedRange(NSRange(location: sel.location - 1, length: 0))
            }
            return true
        }
        return false
    }
}
