import AppKit
import NoteItCore

/// The editor's note and store, for link suggestions and the `]]` shortcut.
@MainActor protocol NoteLinkHost: AnyObject {
    var store: NoteStore { get }
    var noteID: UUID { get }
}

extension NoteItTextView {
    private static let wikiLinkRegex = try! NSRegularExpression(pattern: "\\[\\[([^\\[\\]\\n]{1,240})\\]$")

    /// Links can't go in code blocks or inline code.
    var canInsertNoteLink: Bool {
        guard isEditable, linkHost != nil, let para = paragraphRanges(for: selectedRange()).first else { return false }
        let kind = blockKind(ofParagraph: para)
        return kind != .code && kind != .divider && !EditorStyle.isInlineCode(typingAttributes)
    }

    /// After `[` is typed: a second `[` opens the suggestion list.
    func beginLinkCompletionIfNeeded(afterTyping text: String) {
        guard text == "[", !hasMarkedText(), !inlineCompletion.isActive, canInsertNoteLink else { return }
        let caret = selectedRange()
        guard caret.length == 0, caret.location >= 2, nsString.substring(with: NSRange(location: caret.location - 2, length: 2)) == "[[",
              let host = linkHost else { return }
        if caret.location >= 3, nsString.character(at: caret.location - 3) == 0x5B { return }
        inlineCompletion.begin(at: caret.location, source: LinkCompletionSource(store: host.store, noteID: host.noteID))
    }

    /// Format › Link to Note…: opens the list at the caret, with the selection as query and shown text.
    @objc func linkToNote(_ sender: Any?) {
        guard canInsertNoteLink, let host = linkHost else { return }
        let selection = selectedRange()
        let selected = nsString.substring(with: selection)
        guard !selected.contains(where: \.isNewline) else { return }
        let source = LinkCompletionSource(store: host.store, noteID: host.noteID)
        if selection.length > 0 { source.presetText = selected }
        var attrs = typingAttributes
        attrs[.link] = nil
        let opening = NSAttributedString(string: "[[", attributes: attrs)
        breakUndoCoalescing()
        guard replace(NSRange(location: selection.location, length: 0), with: opening,
                      select: NSRange(location: NSMaxRange(selection) + 2, length: 0), actionName: "Link to Note") else { return }
        source.insertedOpening = selection.location
        inlineCompletion.begin(at: selection.location + 2, source: source)
    }

    /// Replaces `range` with one link run showing `text`; the typing attributes after it have no link. One undo step.
    @discardableResult
    func insertNoteLink(_ link: NoteLink, text: String, replacing range: NSRange) -> Bool {
        var range = clamp(range)
        if NSMaxRange(range) + 2 <= storage.length, nsString.substring(with: NSRange(location: NSMaxRange(range), length: 2)) == "]]" {
            range.length += 2
        }
        var attrs = range.location < storage.length ? storage.attributes(at: range.location, effectiveRange: nil) : typingAttributes
        if range.length == 0 { attrs = typingAttributes }
        attrs[.link] = nil
        attrs[.attachment] = nil
        var linked = attrs
        linked[.link] = link.url
        let shown = text.isEmpty ? "Untitled" : text
        let run = NSAttributedString(string: shown, attributes: linked)
        breakUndoCoalescing()
        guard replace(range, with: run, select: NSRange(location: range.location + run.length, length: 0), actionName: "Insert Link") else {
            return false
        }
        typingAttributes = attrs
        return true
    }

    /// The `]]` shortcut: `[[Title#Heading|text]` + `]` becomes a link to the note with that exact title, or an
    /// unresolved link.
    func handleWikiLinkTrigger(prefix: String, para: NSRange, dryRun: Bool) -> Bool {
        guard let host = linkHost,
              let match = Self.wikiLinkRegex.firstMatch(in: prefix, range: NSRange(location: 0, length: (prefix as NSString).length))
        else { return false }
        let inner = (prefix as NSString).substring(with: match.range(at: 1))
        let query = LinkQuery(inner)
        let currentTitle = host.store.note(with: host.noteID)?.title ?? ""
        let title = String((query.title.isEmpty ? currentTitle : query.title).prefix(NoteLink.maxTextLength))
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if dryRun { return true }
        let heading = query.heading.map { String($0.prefix(NoteLink.maxTextLength)) }
        let link: NoteLink
        if query.title.isEmpty {
            link = .note(id: host.noteID, heading: heading)
        } else if let id = host.store.noteID(forTitle: title, preferring: host.store.note(with: host.noteID)?.notebookID),
                  id != host.noteID || heading != nil {
            link = .note(id: id, heading: heading)
        } else {
            link = .unresolved(title: title, heading: heading)
        }
        let shown = query.alias ?? {
            guard let heading else { return query.title }
            return query.title.isEmpty ? heading : "\(query.title) › \(heading)"
        }()
        inlineCompletion.end()
        let range = NSRange(location: para.location + match.range.location, length: match.range.length)
        return insertNoteLink(link, text: shown, replacing: range)
    }
}

extension NoteItTextView {
    /// Format › Insert Template…: picks a template, then `insertTemplate(_:)`.
    @objc func showInsertTemplatePicker(_ sender: Any?) {
        guard isEditable, linkHost != nil else { return }
        NotificationCenter.default.post(name: .noteItShowTemplatePicker,
                                        object: TemplatePickerRequest(mode: .insert(.init(self))))
    }

    /// Inserts the expanded template at the caret as one undo step; `{{title}}` is this note's title.
    func insertTemplate(_ templateID: UUID) {
        guard isEditable, let host = linkHost,
              let expansion = host.store.expandedTemplate(templateID, title: host.store.note(with: host.noteID)?.title ?? "", date: Date())
        else { return }
        let selection = selectedRange()
        let firstPara = paragraphRanges(for: NSRange(location: 0, length: 0)).first
        let onEmptyFirstLine = selection.location == 0 && (firstPara.map { nsString.substring(with: $0).trimmingCharacters(in: .newlines).isEmpty } ?? true)
        let (text, caret) = Self.templateInsertion(expansion, keepsTitle: onEmptyFirstLine)
        guard text.length > 0 else { return }
        breakUndoCoalescing()
        let end = selection.location + (caret ?? text.length)
        replace(selection, with: text, select: NSRange(location: end, length: 0), actionName: "Insert Template")
        breakUndoCoalescing()
    }

    /// The expansion without its title paragraph unless `keepsTitle` (or it is the only paragraph), and the caret in it.
    static func templateInsertion(_ expansion: TemplateExpansion, keepsTitle: Bool) -> (NSAttributedString, Int?) {
        let ns = expansion.text.string as NSString
        let newline = ns.range(of: "\n")
        guard !keepsTitle, newline.location != NSNotFound, newline.location > 0 else { return (expansion.text, expansion.caret) }
        let dropped = NSMaxRange(newline)
        let rest = expansion.text.attributedSubstring(from: NSRange(location: dropped, length: ns.length - dropped))
        let caret = expansion.caret.flatMap { $0 >= dropped ? $0 - dropped : nil }
        return (rest, caret)
    }

    /// The line rect of the character at `location`, in view coordinates.
    func lineRect(at location: Int) -> NSRect? {
        guard let layoutManager, let textContainer, location <= storage.length else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: location, length: 0), actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphs.location, length: 1), in: textContainer)
        rect.origin.y += textContainerOrigin.y
        return rect
    }

    /// Scrolls so the line at `location` sits a third of the way down the visible area.
    func scrollToTopThird(_ location: Int) {
        guard let rect = lineRect(at: location), let scrollView = enclosingScrollView else { return }
        let clip = scrollView.contentView
        let y = max(0, min(rect.minY - clip.bounds.height / 3, frame.height - clip.bounds.height))
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        scrollView.reflectScrolledClipView(clip)
    }
}
