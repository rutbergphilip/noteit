import AppKit
import UniformTypeIdentifiers

/// Formatting commands. All edits go through `replace`/`editAttributes`/`apply` so they are undoable,
/// and edits made while handling one event collapse into a single undo step.
extension NoteItTextView {
    func perform(_ command: FormatCommand) {
        breakUndoCoalescing()
        switch command {
        case .bold: toggleFontTrait(.boldFontMask, name: "Bold")
        case .italic: toggleFontTrait(.italicFontMask, name: "Italic")
        case .underline: toggleLineAttribute(.underlineStyle, name: "Underline")
        case .strikethrough: toggleLineAttribute(.strikethroughStyle, name: "Strikethrough")
        case .inlineCode: toggleInlineCode()
        case .block(.divider): insertDivider()
        case .block(let kind): setBlock(kind)
        case .list(let kind): toggleList(kind)
        case .toggleCheckbox: toggleSelectedCheckboxes()
        case .indent: changeIndent(by: 1)
        case .outdent: changeIndent(by: -1)
        case .align(let alignment): setAlignment(alignment)
        case .textColor(let color): setCharacterAttribute(.foregroundColor, color, name: "Text Color")
        case .highlight(let color): setCharacterAttribute(.backgroundColor, color, name: "Highlight")
        case .toggleHighlight:
            let current = currentFormattingState().highlight
            setCharacterAttribute(.backgroundColor, current == nil ? EditorStyle.highlightColors[0].color : nil, name: "Highlight")
        case .customColor: showColorPanel()
        case .fontBigger: adjustFontSize(by: 1)
        case .fontSmaller: adjustFontSize(by: -1)
        case .link: showLinkSheet()
        case .divider: insertDivider()
        case .table(let rows, let columns): insertTable(rows: rows, columns: columns)
        case .image: chooseImages()
        case .clearFormatting: clearFormatting()
        case .addRowAbove: addTableRow(below: false)
        case .addRowBelow: addTableRow(below: true)
        case .deleteRow: deleteTableRow()
        }
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        formattingDidChange?()
    }

    // MARK: State

    func currentFormattingState() -> FormattingState {
        var state = FormattingState()
        guard textStorage != nil else { return state }
        let sel = selectedRange()
        let attrs: [NSAttributedString.Key: Any]
        if sel.length == 0 || sel.location >= storage.length {
            attrs = typingAttributes
        } else {
            attrs = storage.attributes(at: sel.location, effectiveRange: nil)
        }
        let font = (attrs[.font] as? NSFont) ?? EditorStyle.bodyFont
        if sel.length > 0 {
            state.bold = allFonts(in: sel) { EditorStyle.isBold($0) }
            state.italic = allFonts(in: sel) { EditorStyle.isItalic($0) }
            state.inlineCode = allInlineCode(in: sel)
        } else {
            state.bold = EditorStyle.isBold(font)
            state.italic = EditorStyle.isItalic(font)
            state.inlineCode = EditorStyle.isInlineCode(attrs)
        }
        state.fontSize = font.pointSize
        state.underline = ((attrs[.underlineStyle] as? Int) ?? 0) != 0
        state.strikethrough = ((attrs[.strikethroughStyle] as? Int) ?? 0) != 0
        let para = paragraphRanges(for: sel).first ?? NSRange(location: 0, length: 0)
        state.block = blockKind(ofParagraph: para)
        // Heading fonts are bold by design; only explicit bold should light up the toolbar.
        if [.title, .heading, .subheading].contains(state.block) { state.bold = false }
        if state.block == .code { state.inlineCode = false }
        state.list = marker(ofParagraph: para)?.listKind
        let ps = attributes(ofParagraph: para)[.paragraphStyle] as? NSParagraphStyle
        state.alignment = ps?.alignment ?? .natural
        state.inTable = ps?.textBlocks.contains { $0 is NSTextTableBlock } ?? false
        var link = attrs[.link]
        if link == nil, sel.length == 0, sel.location > 0, sel.location < storage.length {
            link = storage.attribute(.link, at: sel.location, effectiveRange: nil)
        }
        state.link = link != nil
        state.textColor = attrs[.foregroundColor] as? NSColor
        if !state.inlineCode {
            state.highlight = attrs[.backgroundColor] as? NSColor
        }
        return state
    }

    private func allFonts(in range: NSRange, _ test: (NSFont) -> Bool) -> Bool {
        var all = true
        storage.enumerateAttribute(.font, in: range) { value, _, stop in
            if !test((value as? NSFont) ?? EditorStyle.bodyFont) { all = false; stop.pointee = true }
        }
        return all
    }

    private func allInlineCode(in range: NSRange) -> Bool {
        var all = true
        storage.enumerateAttributes(in: range) { attrs, _, stop in
            if !EditorStyle.isInlineCode(attrs) { all = false; stop.pointee = true }
        }
        return all
    }

    // MARK: Character formatting

    private func toggleFontTrait(_ trait: NSFontTraitMask, name: String) {
        let fm = NSFontManager.shared
        let sel = selectedRange()
        let has: (NSFont) -> Bool = { trait == .boldFontMask ? EditorStyle.isBold($0) : EditorStyle.isItalic($0) }
        if sel.length == 0 {
            let font = (typingAttributes[.font] as? NSFont) ?? EditorStyle.bodyFont
            typingAttributes[.font] = has(font) ? fm.convert(font, toNotHaveTrait: trait) : fm.convert(font, toHaveTrait: trait)
            return
        }
        let remove = allFonts(in: sel, has)
        editAttributes(in: sel, actionName: name) { ts in
            ts.enumerateAttribute(.font, in: sel) { value, r, _ in
                let font = (value as? NSFont) ?? EditorStyle.bodyFont
                ts.addAttribute(.font, value: remove ? fm.convert(font, toNotHaveTrait: trait) : fm.convert(font, toHaveTrait: trait), range: r)
            }
        }
    }

    private func toggleLineAttribute(_ key: NSAttributedString.Key, name: String) {
        let sel = selectedRange()
        if sel.length == 0 {
            let on = ((typingAttributes[key] as? Int) ?? 0) != 0
            typingAttributes[key] = on ? nil : NSUnderlineStyle.single.rawValue
            return
        }
        var allOn = true
        storage.enumerateAttribute(key, in: sel) { value, _, stop in
            if ((value as? Int) ?? 0) == 0 { allOn = false; stop.pointee = true }
        }
        editAttributes(in: sel, actionName: name) { ts in
            if allOn { ts.removeAttribute(key, range: sel) } else { ts.addAttribute(key, value: NSUnderlineStyle.single.rawValue, range: sel) }
        }
    }

    private func toggleInlineCode() {
        let sel = selectedRange()
        let para = paragraphRanges(for: sel).first ?? sel
        guard blockKind(ofParagraph: para) != .code else { return }
        if sel.length == 0 {
            if EditorStyle.isInlineCode(typingAttributes) {
                typingAttributes[.font] = EditorStyle.bodyFont
                if EditorStyle.isLegacyInlineCodeBackground(typingAttributes[.backgroundColor] as? NSColor) { typingAttributes[.backgroundColor] = nil }
                typingAttributes[.inlineCodeDisplay] = nil
                typingAttributes[.kern] = nil
            } else {
                typingAttributes.merge(EditorStyle.inlineCodeAttributes) { $1 }
            }
            return
        }
        let remove = allInlineCode(in: sel)
        editAttributes(in: sel, actionName: "Inline Code") { ts in
            if remove {
                ts.addAttribute(.font, value: EditorStyle.bodyFont, range: sel)
                ts.enumerateAttribute(.backgroundColor, in: sel) { value, r, _ in
                    if EditorStyle.isLegacyInlineCodeBackground(value as? NSColor) { ts.removeAttribute(.backgroundColor, range: r) }
                }
                ts.removeAttribute(.inlineCodeDisplay, range: sel)
            } else {
                ts.addAttributes(EditorStyle.inlineCodeAttributes, range: sel)
            }
        }
    }

    private func setCharacterAttribute(_ key: NSAttributedString.Key, _ value: NSColor?, name: String) {
        let sel = selectedRange()
        if sel.length == 0 {
            typingAttributes[key] = value
            return
        }
        editAttributes(in: sel, actionName: name) { ts in
            if let value { ts.addAttribute(key, value: value, range: sel) } else { ts.removeAttribute(key, range: sel) }
        }
    }

    private func adjustFontSize(by delta: CGFloat) {
        let sel = selectedRange()
        let resize: (NSFont) -> NSFont = { font in
            NSFont(descriptor: font.fontDescriptor, size: min(96, max(8, font.pointSize + delta))) ?? font
        }
        if sel.length == 0 {
            typingAttributes[.font] = resize((typingAttributes[.font] as? NSFont) ?? EditorStyle.bodyFont)
            return
        }
        editAttributes(in: sel, actionName: delta > 0 ? "Bigger" : "Smaller") { ts in
            ts.enumerateAttribute(.font, in: sel) { value, r, _ in
                ts.addAttribute(.font, value: resize((value as? NSFont) ?? EditorStyle.bodyFont), range: r)
            }
        }
    }

    private func showColorPanel() {
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        if let color = currentFormattingState().textColor { panel.color = color }
        window?.makeFirstResponder(self)
        NSApp.orderFrontColorPanel(nil)
    }

    // MARK: Paragraph helpers

    /// Builds an edit replacing the paragraph's list marker (if any) with `newMarker`.
    func makeEdit(
        _ para: NSRange,
        newMarker: String?,
        markerAttributes: [NSAttributedString.Key: Any] = [:],
        paragraphStyle: NSParagraphStyle?,
        transform: ((NSMutableAttributedString) -> Void)? = nil
    ) -> ParagraphEdit {
        let oldPrefix = marker(ofParagraph: para)?.length ?? 0
        let body = NSMutableAttributedString(attributedString: storage.attributedSubstring(
            from: NSRange(location: para.location + oldPrefix, length: para.length - oldPrefix)))
        transform?(body)
        let result = NSMutableAttributedString()
        if let newMarker { result.append(NSAttributedString(string: newMarker, attributes: markerAttributes)) }
        result.append(body)
        if let paragraphStyle, result.length > 0 {
            result.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: result.length))
        }
        return ParagraphEdit(range: para, oldPrefix: oldPrefix, newPrefix: (newMarker as NSString?)?.length ?? 0, text: result)
    }

    func identityEdit(_ para: NSRange) -> ParagraphEdit {
        ParagraphEdit(range: para, oldPrefix: 0, newPrefix: 0, text: storage.attributedSubstring(from: para))
    }

    static func convertFonts(_ s: NSMutableAttributedString, to kind: BlockKind, from oldKind: BlockKind) {
        let full = NSRange(location: 0, length: s.length)
        guard full.length > 0 else { return }
        let fm = NSFontManager.shared
        if kind != .code { EditorStyle.removeCodeLanguageID(from: s) }
        switch kind {
        case .code:
            s.addAttribute(.font, value: EditorStyle.codeFont, range: full)
            s.removeAttribute(.backgroundColor, range: full)
            s.removeAttribute(.inlineCodeDisplay, range: full)
        case .title, .heading, .subheading:
            let target = EditorStyle.font(for: kind)
            s.enumerateAttribute(.font, in: full) { value, r, _ in
                let italic = (value as? NSFont).map(EditorStyle.isItalic) ?? false
                s.addAttribute(.font, value: italic ? fm.convert(target, toHaveTrait: .italicFontMask) : target, range: r)
            }
        case .body, .quote, .divider:
            guard EditorStyle.isHeading(oldKind) || oldKind == .code else { return }
            s.enumerateAttribute(.font, in: full) { value, r, _ in
                let italic = (value as? NSFont).map(EditorStyle.isItalic) ?? false
                let target = EditorStyle.bodyFont
                s.addAttribute(.font, value: italic ? fm.convert(target, toHaveTrait: .italicFontMask) : target, range: r)
            }
        }
    }

    static func removeCheckedStyle(_ s: NSMutableAttributedString) {
        let full = NSRange(location: 0, length: s.length)
        s.removeAttribute(.strikethroughStyle, range: full)
        s.enumerateAttribute(.foregroundColor, in: full) { value, r, _ in
            if let c = value as? NSColor, c == EditorStyle.checkedTextColor || isCheckedGray(c) {
                s.removeAttribute(.foregroundColor, range: r)
            }
        }
    }

    private static func isCheckedGray(_ c: NSColor) -> Bool {
        guard let rgb = c.usingColorSpace(.sRGB) else { return false }
        let t = EditorStyle.checkedTextColor
        return abs(rgb.redComponent - t.redComponent) < 0.02 && abs(rgb.greenComponent - t.greenComponent) < 0.02
            && abs(rgb.blueComponent - t.blueComponent) < 0.02
    }

    private func setTypingAttributesForEmptyParagraph(kind: BlockKind, existing: NSParagraphStyle?) {
        let para = paragraphRanges(for: selectedRange()).first ?? NSRange(location: 0, length: 0)
        if content(of: para).isEmpty {
            typingAttributes = EditorStyle.attributes(for: kind, existing: existing)
        }
    }

    // MARK: Blocks

    func setBlock(_ requested: BlockKind) {
        let paras = paragraphRanges(for: selectedRange()).filter { blockKind(ofParagraph: $0) != .divider }
        guard !paras.isEmpty else { return }
        let allAlready = paras.allSatisfy { blockKind(ofParagraph: $0) == requested && marker(ofParagraph: $0) == nil }
        let kind: BlockKind = (allAlready && requested != .body) ? .body : requested
        let existingCaretPS = attributes(ofParagraph: paras[0])[.paragraphStyle] as? NSParagraphStyle

        if paras.count == 1, paras[0].length == 0 {
            // Empty last line: a code block needs a real paragraph to draw its background.
            if kind == .code {
                let text = NSAttributedString(string: "\n", attributes: EditorStyle.attributes(for: .code, existing: existingCaretPS))
                replace(paras[0], with: text, select: NSRange(location: paras[0].location, length: 0), actionName: kind.displayName)
            }
            typingAttributes = EditorStyle.attributes(for: kind, existing: existingCaretPS)
            needsDisplay = true
            return
        }

        let edits = paras.map { para -> ParagraphEdit in
            let oldKind = blockKind(ofParagraph: para)
            let ps = attributes(ofParagraph: para)[.paragraphStyle] as? NSParagraphStyle
            let wasList = marker(ofParagraph: para) != nil
            let level = wasList ? 0 : EditorStyle.indentLevel(of: ps, kind: oldKind)
            let newPS = EditorStyle.paragraphStyle(for: kind, existing: ps, indentLevel: level)
            return makeEdit(para, newMarker: nil, paragraphStyle: newPS) { s in
                Self.convertFonts(s, to: kind, from: oldKind)
                if wasList { Self.removeCheckedStyle(s) }
            }
        }
        apply(edits, actionName: kind.displayName)
        setTypingAttributesForEmptyParagraph(kind: kind, existing: existingCaretPS)
    }

    // MARK: Lists

    func toggleList(_ kind: ListKind) {
        let paras = paragraphRanges(for: selectedRange()).filter {
            let k = blockKind(ofParagraph: $0)
            return k != .divider && k != .code
        }
        guard !paras.isEmpty else { return }
        let remove = paras.allSatisfy { marker(ofParagraph: $0)?.listKind == kind }
        let edits = paras.map { para -> ParagraphEdit in
            if remove { return removeListEdit(para) }
            return listEdit(para, kind: kind)
        }
        apply(edits, actionName: remove ? "Remove List" : FormatCommand.list(kind).title)
        renumberList(around: selectedRange().location)
        updateTypingAttributesForListParagraph()
    }

    func listEdit(_ para: NSRange, kind: ListKind, number: Int = 1, checked: Bool = false) -> ParagraphEdit {
        let oldKind = blockKind(ofParagraph: para)
        let ps = attributes(ofParagraph: para)[.paragraphStyle] as? NSParagraphStyle
        let old = marker(ofParagraph: para)
        let level = old != nil ? EditorStyle.listLevel(of: ps) : EditorStyle.indentLevel(of: ps, kind: oldKind)
        let markerKind: ListMarker.Kind
        switch kind {
        case .bullet: markerKind = .bullet
        case .numbered: markerKind = .numbered(number)
        case .checklist: markerKind = .checkbox(checked: checked)
        }
        let newPS = EditorStyle.listParagraphStyle(level: level, existing: ps)
        return makeEdit(para, newMarker: EditorStyle.markerText(markerKind, level: level),
                        markerAttributes: EditorStyle.markerAttributes(level: level, existing: ps),
                        paragraphStyle: newPS) { s in
            Self.convertFonts(s, to: .body, from: oldKind == .quote ? .body : oldKind)
            Self.removeCheckedStyle(s)
            if checked { Self.applyCheckedStyle(s) }
        }
    }

    func removeListEdit(_ para: NSRange, keepIndent: Bool = false) -> ParagraphEdit {
        let ps = attributes(ofParagraph: para)[.paragraphStyle] as? NSParagraphStyle
        let level = keepIndent ? EditorStyle.listLevel(of: ps) : 0
        let newPS = EditorStyle.paragraphStyle(for: .body, existing: ps, indentLevel: level)
        return makeEdit(para, newMarker: nil, paragraphStyle: newPS) { s in Self.removeCheckedStyle(s) }
    }

    static func applyCheckedStyle(_ s: NSMutableAttributedString) {
        var full = NSRange(location: 0, length: s.length)
        if s.string.hasSuffix("\n") { full.length -= 1 }
        guard full.length > 0 else { return }
        s.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: full)
        s.addAttribute(.foregroundColor, value: EditorStyle.checkedTextColor, range: full)
    }

    private func updateTypingAttributesForListParagraph() {
        let sel = selectedRange()
        guard sel.length == 0, let para = paragraphRanges(for: sel).first, let m = marker(ofParagraph: para),
              content(of: para).count <= m.length + 1 else { return }
        let ps = attributes(ofParagraph: para)[.paragraphStyle] as? NSParagraphStyle
        var attrs = EditorStyle.bodyAttributes
        attrs[.paragraphStyle] = ps
        typingAttributes = attrs
    }

    /// Renumbers the contiguous list run containing `location`.
    func renumberList(around location: Int) {
        guard storage.length > 0 else { return }
        var start = paragraphRange(at: min(location, storage.length - 1))
        if location >= storage.length, nsString.character(at: storage.length - 1) == 10 { return }
        guard marker(ofParagraph: start) != nil else { return }
        while start.location > 0 {
            let prev = paragraphRange(at: start.location - 1)
            guard marker(ofParagraph: prev) != nil else { break }
            start = prev
        }
        var edits: [ParagraphEdit] = []
        var changed = false
        var counters: [Int: Int] = [:]
        var cur = start
        var first = true
        while let m = marker(ofParagraph: cur) {
            let ps = attributes(ofParagraph: cur)[.paragraphStyle] as? NSParagraphStyle
            let level = EditorStyle.listLevel(of: ps)
            counters = counters.filter { $0.key <= level }
            if case .numbered(let n) = m.kind {
                let expected = counters[level].map { $0 + 1 } ?? (first ? n : 1)
                counters[level] = expected
                if expected != n {
                    changed = true
                    let markerAttrs = storage.attributes(at: cur.location, effectiveRange: nil)
                    edits.append(makeEdit(cur, newMarker: EditorStyle.markerText(.numbered(expected), level: level),
                                          markerAttributes: markerAttrs, paragraphStyle: nil))
                } else {
                    edits.append(identityEdit(cur))
                }
            } else {
                counters[level] = nil
                edits.append(identityEdit(cur))
            }
            first = false
            if NSMaxRange(cur) >= storage.length || NSMaxRange(cur) <= cur.location { break }
            cur = paragraphRange(at: NSMaxRange(cur))
        }
        if changed { apply(edits) }
    }

    func changeIndent(by delta: Int) {
        let paras = paragraphRanges(for: selectedRange())
        var edits: [ParagraphEdit] = []
        var any = false
        for para in paras {
            let kind = blockKind(ofParagraph: para)
            let ps = attributes(ofParagraph: para)[.paragraphStyle] as? NSParagraphStyle
            let inTable = ps?.textBlocks.contains { $0 is NSTextTableBlock } ?? false
            if let m = marker(ofParagraph: para) {
                let level = EditorStyle.listLevel(of: ps)
                let newLevel = min(8, max(0, level + delta))
                guard newLevel != level else { edits.append(identityEdit(para)); continue }
                any = true
                let markerKind: ListMarker.Kind = m.kind == .bullet ? .bullet : m.kind
                edits.append(makeEdit(para, newMarker: EditorStyle.markerText(markerKind, level: newLevel),
                                      markerAttributes: EditorStyle.markerAttributes(level: newLevel, existing: ps),
                                      paragraphStyle: EditorStyle.listParagraphStyle(level: newLevel, existing: ps)))
            } else if kind != .code && kind != .divider && !inTable && para.length > 0 {
                let level = EditorStyle.indentLevel(of: ps, kind: kind)
                let newLevel = min(8, max(0, level + delta))
                guard newLevel != level else { edits.append(identityEdit(para)); continue }
                any = true
                edits.append(makeEdit(para, newMarker: nil, paragraphStyle: EditorStyle.paragraphStyle(for: kind, existing: ps, indentLevel: newLevel)))
            } else {
                edits.append(identityEdit(para))
            }
        }
        guard any else { return }
        apply(edits, actionName: delta > 0 ? "Indent" : "Outdent")
        renumberList(around: selectedRange().location)
        updateTypingAttributesForListParagraph()
    }

    // MARK: Checkboxes

    func toggleCheckbox(atParagraphStart location: Int) {
        let para = paragraphRange(at: location)
        guard case .checkbox(let checked) = marker(ofParagraph: para)?.kind else { return }
        breakUndoCoalescing()
        apply([listEdit(para, kind: .checklist, checked: !checked)], actionName: checked ? "Uncheck" : "Check")
        formattingDidChange?()
    }

    private func toggleSelectedCheckboxes() {
        let paras = paragraphRanges(for: selectedRange())
        let boxes = paras.compactMap { para -> (NSRange, Bool)? in
            if case .checkbox(let checked) = marker(ofParagraph: para)?.kind { return (para, checked) }
            return nil
        }
        guard !boxes.isEmpty else {
            toggleList(.checklist)
            return
        }
        let check = boxes.contains { !$0.1 }
        let edits = paras.map { para -> ParagraphEdit in
            if case .checkbox = marker(ofParagraph: para)?.kind { return listEdit(para, kind: .checklist, checked: check) }
            return identityEdit(para)
        }
        apply(edits, actionName: check ? "Check" : "Uncheck")
    }

    // MARK: Alignment

    private func setAlignment(_ alignment: NSTextAlignment) {
        let paras = paragraphRanges(for: selectedRange())
        guard let first = paras.first, let last = paras.last else { return }
        let union = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        if let ps = (typingAttributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle {
            ps.alignment = alignment
            typingAttributes[.paragraphStyle] = ps
        }
        editAttributes(in: union, actionName: "Alignment") { ts in
            ts.enumerateAttribute(.paragraphStyle, in: union) { value, r, _ in
                let ps = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? EditorStyle.baseParagraph()
                ps.alignment = alignment
                ts.addAttribute(.paragraphStyle, value: ps, range: r)
            }
        }
    }

    // MARK: Inserting blocks

    /// Where a block (divider/table) goes: before an empty paragraph, or after the current one.
    private func blockInsertionPoint() -> (location: Int, prefix: NSAttributedString, beforeEmptyParagraph: Bool) {
        let sel = selectedRange()
        let para = paragraphRanges(for: NSRange(location: NSMaxRange(sel), length: 0)).first ?? NSRange(location: storage.length, length: 0)
        if content(of: para).isEmpty {
            return (para.location, NSAttributedString(), para.length > 0)
        }
        let end = NSMaxRange(para)
        let endsWithNewline = end > 0 && nsString.character(at: end - 1) == 10
        let prefix = endsWithNewline ? NSAttributedString() : NSAttributedString(string: "\n", attributes: attributes(ofParagraph: para))
        let followedByParagraph = end < storage.length
        return (end, prefix, followedByParagraph && blockKind(ofParagraph: paragraphRange(at: end)) == .body
                && content(of: paragraphRange(at: end)).isEmpty)
    }

    func insertDivider() {
        let point = blockInsertionPoint()
        let text = NSMutableAttributedString(attributedString: point.prefix)
        text.append(EditorStyle.divider())
        replace(NSRange(location: point.location, length: 0), with: text,
                select: NSRange(location: point.location + text.length, length: 0), actionName: "Insert Divider")
        if selectedRange().location >= storage.length { typingAttributes = EditorStyle.bodyAttributes }
    }

    func insertTable(rows: Int, columns: Int) {
        let point = blockInsertionPoint()
        let text = NSMutableAttributedString(attributedString: point.prefix)
        let header = Array(repeating: "", count: columns)
        let body = Array(repeating: Array(repeating: "", count: columns), count: max(0, rows - 1))
        text.append(EditorStyle.table(header: header, rows: body))
        if !point.beforeEmptyParagraph {
            text.append(NSAttributedString(string: "\n", attributes: EditorStyle.bodyAttributes))
        }
        let firstCell = point.location + point.prefix.length
        replace(NSRange(location: point.location, length: 0), with: text,
                select: NSRange(location: firstCell, length: 0), actionName: "Insert Table")
        Self.refreshTableColors(in: storage)
        typingAttributes = storage.attributes(at: firstCell, effectiveRange: nil)
    }

    // MARK: Tables

    private func tableBlock(ofParagraph para: NSRange) -> NSTextTableBlock? {
        guard para.location < storage.length else { return nil }
        let ps = storage.attribute(.paragraphStyle, at: para.location, effectiveRange: nil) as? NSParagraphStyle
        return ps?.textBlocks.compactMap { $0 as? NSTextTableBlock }.first
    }

    /// All paragraphs of the table at `location`, in order.
    private func tableParagraphs(at location: Int) -> (table: NSTextTable, cells: [(NSRange, NSTextTableBlock)])? {
        guard let block = tableBlock(at: location) else { return nil }
        let table = block.table
        var start = paragraphRange(at: location)
        while start.location > 0 {
            let prev = paragraphRange(at: start.location - 1)
            guard tableBlock(ofParagraph: prev)?.table === table else { break }
            start = prev
        }
        var cells: [(NSRange, NSTextTableBlock)] = []
        var cur = start
        while let b = tableBlock(ofParagraph: cur), b.table === table {
            cells.append((cur, b))
            if NSMaxRange(cur) >= storage.length { break }
            cur = paragraphRange(at: NSMaxRange(cur))
        }
        return (table, cells)
    }

    private func reblocked(_ range: NSRange, map: (NSTextTableBlock) -> NSTextTableBlock) -> NSAttributedString {
        let s = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
        s.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: s.length)) { value, r, _ in
            guard let ps = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { return }
            ps.textBlocks = ps.textBlocks.map { ($0 as? NSTextTableBlock).map(map) ?? $0 }
            s.addAttribute(.paragraphStyle, value: ps, range: r)
        }
        return s
    }

    private func addTableRow(below: Bool) {
        let sel = selectedRange()
        guard let current = tableBlock(at: sel.location), let info = tableParagraphs(at: sel.location) else { return }
        let curRow = current.startingRow
        if !below && curRow == 0 { return }
        let targetRow = below ? curRow + current.rowSpan : curRow
        var templates: [Int: NSTextTableBlock] = [:]
        for (_, b) in info.cells where b.startingRow == curRow { templates[b.startingColumn] = b }

        var shifted: [ObjectIdentifier: NSTextTableBlock] = [:]
        let result = NSMutableAttributedString()
        var newRowStart = -1
        func appendNewRow() {
            newRowStart = result.length
            for c in 0..<info.table.numberOfColumns {
                guard let t = templates[c] ?? info.cells.first?.1 else { continue }
                let block = EditorStyle.copyBlock(t, row: targetRow, header: false)
                let ps = EditorStyle.tableCellParagraph(block: block)
                if let existing = storage.attribute(.paragraphStyle, at: info.cells[0].0.location, effectiveRange: nil) as? NSParagraphStyle {
                    ps.alignment = existing.alignment
                }
                result.append(NSAttributedString(string: "\n", attributes: [.font: EditorStyle.bodyFont, .paragraphStyle: ps]))
            }
        }
        for (range, block) in info.cells {
            if newRowStart < 0 && block.startingRow >= targetRow { appendNewRow() }
            result.append(reblocked(range) { b in
                guard b.startingRow >= targetRow else { return b }
                if let s = shifted[ObjectIdentifier(b)] { return s }
                let s = EditorStyle.copyBlock(b, row: b.startingRow + 1)
                shifted[ObjectIdentifier(b)] = s
                return s
            })
        }
        if newRowStart < 0 { appendNewRow() }
        let tableRange = NSRange(location: info.cells[0].0.location, length: NSMaxRange(info.cells.last!.0) - info.cells[0].0.location)
        replace(tableRange, with: result, select: NSRange(location: tableRange.location + newRowStart, length: 0),
                actionName: "Add Row")
        typingAttributes = storage.attributes(at: tableRange.location + newRowStart, effectiveRange: nil)
    }

    private func deleteTableRow() {
        let sel = selectedRange()
        guard let current = tableBlock(at: sel.location), let info = tableParagraphs(at: sel.location) else { return }
        let curRow = current.startingRow
        let tableRange = NSRange(location: info.cells[0].0.location, length: NSMaxRange(info.cells.last!.0) - info.cells[0].0.location)
        let rows = Set(info.cells.map { $0.1.startingRow })
        if rows.count <= 1 {
            replace(tableRange, with: NSAttributedString(), select: NSRange(location: tableRange.location, length: 0), actionName: "Delete Table")
            return
        }
        var shifted: [ObjectIdentifier: NSTextTableBlock] = [:]
        let result = NSMutableAttributedString()
        var caret = -1
        for (range, block) in info.cells {
            if block.startingRow == curRow { continue }
            if block.startingRow > curRow && caret < 0 { caret = result.length }
            result.append(reblocked(range) { b in
                guard b.startingRow > curRow else { return b }
                if let s = shifted[ObjectIdentifier(b)] { return s }
                let s = EditorStyle.copyBlock(b, row: b.startingRow - 1, header: curRow == 0 && b.startingRow == 1 ? true : nil)
                shifted[ObjectIdentifier(b)] = s
                return s
            })
        }
        if caret < 0 { caret = max(0, result.length - 1) }
        replace(tableRange, with: result, select: NSRange(location: tableRange.location + caret, length: 0), actionName: "Delete Row")
    }

    func moveToAdjacentCell(forward: Bool) {
        let sel = selectedRange()
        guard let current = tableBlock(at: sel.location), let info = tableParagraphs(at: sel.location) else { return }
        // Group paragraphs into cells (a cell may hold several paragraphs).
        var cells: [(block: NSTextTableBlock, range: NSRange)] = []
        for (range, block) in info.cells {
            if let last = cells.last, last.block === block {
                cells[cells.count - 1].range = NSUnionRange(last.range, range)
            } else {
                cells.append((block, range))
            }
        }
        guard let index = cells.firstIndex(where: { $0.block === current }) else { return }
        let target = forward ? index + 1 : index - 1
        if target >= cells.count {
            setSelectedRange(NSRange(location: cells[index].range.location, length: 0))
            breakUndoCoalescing()
            addTableRow(below: true)
            return
        }
        guard target >= 0 else { return }
        let range = cells[target].range
        setSelectedRange(NSRange(location: range.location, length: max(0, range.length - 1)))
        scrollRangeToVisible(selectedRange())
    }

    // MARK: Links

    private func showLinkSheet() {
        guard let window else { return }
        var range = selectedRange()
        var existing: URL?
        let probe = range.length == 0 ? max(0, min(range.location, storage.length - 1)) : range.location
        if storage.length > 0, probe < storage.length {
            var effective = NSRange()
            let value = storage.attribute(.link, at: probe, longestEffectiveRange: &effective, in: NSRange(location: 0, length: storage.length))
            if let value {
                existing = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
                if range.length == 0 { range = effective }
            }
        }

        let alert = NSAlert()
        alert.messageText = existing == nil ? "Add Link" : "Edit Link"
        alert.informativeText = range.length == 0 ? "Enter the text to show and a web address." : "Enter a web address for the selected text."
        alert.addButton(withTitle: existing == nil ? "Add Link" : "Save")
        alert.addButton(withTitle: "Cancel")
        if existing != nil { alert.addButton(withTitle: "Remove Link") }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        let textField = NSTextField(string: "")
        textField.placeholderString = "Text"
        let urlField = NSTextField(string: existing?.absoluteString ?? "")
        urlField.placeholderString = "https://example.com"
        if range.length == 0 {
            stack.addArrangedSubview(textField)
            textField.widthAnchor.constraint(equalToConstant: 280).isActive = true
        }
        stack.addArrangedSubview(urlField)
        urlField.widthAnchor.constraint(equalToConstant: 280).isActive = true
        stack.frame = NSRect(x: 0, y: 0, width: 280, height: range.length == 0 ? 54 : 24)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = urlField

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
            switch response {
            case .alertFirstButtonReturn:
                guard let url = Self.normalizedURL(urlField.stringValue) else { return }
                self.breakUndoCoalescing()
                if range.length == 0 {
                    let title = textField.stringValue.isEmpty ? urlField.stringValue : textField.stringValue
                    var attrs = self.typingAttributes
                    attrs[.link] = url
                    let s = NSAttributedString(string: title, attributes: attrs)
                    self.replace(range, with: s, select: NSRange(location: range.location + s.length, length: 0), actionName: "Add Link")
                    self.typingAttributes[.link] = nil
                } else {
                    self.editAttributes(in: range, actionName: "Add Link") { $0.addAttribute(.link, value: url, range: range) }
                }
            case .alertThirdButtonReturn:
                self.breakUndoCoalescing()
                self.editAttributes(in: range, actionName: "Remove Link") { $0.removeAttribute(.link, range: range) }
            default:
                break
            }
            self.formattingDidChange?()
        }
    }

    static func normalizedURL(_ raw: String) -> URL? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.contains("://") || s.hasPrefix("mailto:") || s.hasPrefix("tel:") { return URL(string: s) }
        if s.contains("@") && !s.contains("/") { return URL(string: "mailto:" + s) }
        return URL(string: "https://" + s)
    }

    // MARK: Images

    private func chooseImages() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.prompt = "Insert"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK else { return }
            self.insertImages(panel.urls)
        }
    }

    func insertImages(_ urls: [URL]) {
        let s = NSMutableAttributedString()
        var attrs = typingAttributes
        attrs[.link] = nil
        for (i, url) in urls.enumerated() {
            guard let wrapper = try? FileWrapper(url: url, options: .immediate) else { continue }
            wrapper.preferredFilename = url.lastPathComponent
            let attachment = NSTextAttachment(fileWrapper: wrapper)
            if i > 0 { s.append(NSAttributedString(string: "\n", attributes: attrs)) }
            let piece = NSMutableAttributedString(attachment: attachment)
            piece.addAttributes(attrs, range: NSRange(location: 0, length: piece.length))
            s.append(piece)
        }
        guard s.length > 0 else { return }
        window?.makeFirstResponder(self)
        breakUndoCoalescing()
        let sel = selectedRange()
        replace(sel, with: s, select: NSRange(location: sel.location + s.length, length: 0), actionName: "Insert Image")
        Self.fitAttachments(in: storage, range: NSRange(location: sel.location, length: s.length))
        layoutManager?.invalidateLayout(forCharacterRange: NSRange(location: sel.location, length: s.length), actualCharacterRange: nil)
    }

    // MARK: Clear formatting

    private func clearFormatting() {
        let sel = selectedRange()
        let paras = paragraphRanges(for: sel)
        guard let first = paras.first, let last = paras.last else { return }
        let target = sel.length > 0 ? sel : NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        if target.length > 0 {
            editAttributes(in: target, actionName: "Clear Formatting") { ts in
                for key in [NSAttributedString.Key.foregroundColor, .backgroundColor, .underlineStyle, .strikethroughStyle,
                            .shadow, .kern, .baselineOffset, .superscript, .obliqueness, .expansion, .strokeWidth] {
                    ts.removeAttribute(key, range: target)
                }
                ts.addAttribute(.font, value: EditorStyle.bodyFont, range: target)
            }
        }
        let edits = paras.map { para -> ParagraphEdit in
            guard para.length > 0, blockKind(ofParagraph: para) != .divider else { return identityEdit(para) }
            let ps = attributes(ofParagraph: para)[.paragraphStyle] as? NSParagraphStyle
            let base = EditorStyle.paragraphStyle(for: .body, existing: ps)
            base.alignment = .natural
            return makeEdit(para, newMarker: nil, paragraphStyle: base) { s in EditorStyle.removeCodeLanguageID(from: s) }
        }
        apply(edits, actionName: "Clear Formatting")
        typingAttributes = EditorStyle.bodyAttributes
    }
}
