import AppKit

/// NSTextView subclass hosting all editor behaviors: list continuation, checklists, markdown
/// shortcuts, keyboard formatting shortcuts, table navigation, context menu and centered layout.
final class NoteItTextView: NSTextView, NSTextStorageDelegate {
    /// Called after any formatting/selection change so the toolbar can refresh.
    var formattingDidChange: (() -> Void)?

    var placeholder = "Start writing…"

    /// Union of ranges edited since the last normalization pass.
    private var pendingNormalizeRange: NSRange?
    private var isNormalizing = false

    // MARK: Setup

    static func make() -> (NSScrollView, NoteItTextView) {
        let storage = NSTextStorage()
        let layoutManager = NoteItLayoutManager()
        layoutManager.allowsNonContiguousLayout = false
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)

        let textView = NoteItTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        storage.delegate = textView
        textView.configure()

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = textView
        return (scrollView, textView)
    }

    private func configure() {
        isRichText = true
        importsGraphics = true
        allowsImageEditing = false
        allowsUndo = true
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        drawsBackground = false
        usesAdaptiveColorMappingForDarkAppearance = true
        textContainerInset = NSSize(width: EditorStyle.minHorizontalInset, height: EditorStyle.verticalInset)
        font = EditorStyle.bodyFont
        typingAttributes = EditorStyle.bodyAttributes
        isAutomaticLinkDetectionEnabled = true
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticQuoteSubstitutionEnabled = false
        isContinuousSpellCheckingEnabled = true
        smartInsertDeleteEnabled = true
        displaysLinkToolTips = true
        usesFontPanel = true
        linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
    }

    var storage: NSTextStorage { textStorage! }
    var nsString: NSString { storage.string as NSString }

    // MARK: Layout

    override func setFrameSize(_ newSize: NSSize) {
        let inset = max(EditorStyle.minHorizontalInset, floor((newSize.width - EditorStyle.maxTextWidth) / 2))
        if abs(textContainerInset.width - inset) > 0.5 {
            textContainerInset = NSSize(width: inset, height: EditorStyle.verticalInset)
        }
        super.setFrameSize(newSize)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if storage.length == 0, isEditable {
            var attrs = typingAttributes
            attrs[.foregroundColor] = NSColor.placeholderTextColor
            attrs[.backgroundColor] = nil
            let origin = textContainerOrigin
            let ps = attrs[.paragraphStyle] as? NSParagraphStyle
            let x = origin.x + (textContainer?.lineFragmentPadding ?? 0) + (ps?.firstLineHeadIndent ?? 0)
            (placeholder as NSString).draw(at: NSPoint(x: x, y: origin.y + (ps?.paragraphSpacingBefore ?? 0)), withAttributes: attrs)
        }
    }

    override func didChangeText() {
        normalizePendingEdits()
        super.didChangeText()
        if storage.length <= 1 { needsDisplay = true }
    }

    /// Runs after the edit has been processed: attribute fixes that reach beyond the edited range
    /// (e.g. code-block spacing on the previous line) must not happen inside `processEditing`,
    /// or NSTextView extends the edit and moves the caret to its end.
    func normalizePendingEdits() {
        guard let range = pendingNormalizeRange, !isNormalizing else { return }
        pendingNormalizeRange = nil
        isNormalizing = true
        defer { isNormalizing = false }
        storage.beginEditing()
        Self.normalize(storage, around: range)
        storage.endEditing()
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if !stillSelecting { formattingDidChange?() }
    }

    // MARK: Storage normalization

    nonisolated func textStorage(
        _ textStorage: NSTextStorage,
        willProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        MainActor.assumeIsolated {
            guard !isNormalizing else { return }
            let r = NSRange(location: editedRange.location, length: max(editedRange.length, 0))
            pendingNormalizeRange = pendingNormalizeRange.map { NSUnionRange($0, r) } ?? r
            if let p = pendingNormalizeRange, NSMaxRange(p) > textStorage.length {
                pendingNormalizeRange = NSRange(location: min(p.location, textStorage.length), length: textStorage.length - min(p.location, textStorage.length))
            }
        }
    }

    /// Keeps sentinel-based blocks consistent: explicit tab intervals (RTF inherits them otherwise),
    /// code block outer spacing, dividers that received text, oversized images.
    static func normalize(_ ts: NSTextStorage, around editedRange: NSRange) {
        let ns = ts.string as NSString
        guard ns.length > 0 else { return }
        let clamped = NSIntersectionRange(editedRange, NSRange(location: 0, length: ns.length))
        var range = ns.paragraphRange(for: NSRange(location: min(clamped.location, ns.length), length: clamped.length))
        if range.location > 0 {
            range = NSUnionRange(range, ns.paragraphRange(for: NSRange(location: range.location - 1, length: 0)))
        }
        if NSMaxRange(range) < ns.length {
            range = NSUnionRange(range, ns.paragraphRange(for: NSRange(location: NSMaxRange(range), length: 0)))
        }

        ts.enumerateAttribute(.paragraphStyle, in: range) { value, sub, _ in
            let ps = value as? NSParagraphStyle
            if ps == nil || ps!.defaultTabInterval == 0 {
                let m = (ps?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
                m.defaultTabInterval = EditorStyle.defaultTab
                ts.addAttribute(.paragraphStyle, value: m, range: sub)
            }
        }

        var loc = range.location
        while loc < NSMaxRange(range) {
            let para = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            defer { loc = NSMaxRange(para) > loc ? NSMaxRange(para) : loc + 1 }
            let kind = blockKind(of: ts, at: para.location)
            if kind == .code {
                let prevCode = para.location > 0 && blockKind(of: ts, at: ns.paragraphRange(for: NSRange(location: para.location - 1, length: 0)).location) == .code
                let nextCode = NSMaxRange(para) < ns.length && blockKind(of: ts, at: NSMaxRange(para)) == .code
                let before: CGFloat = prevCode ? 0 : EditorStyle.codeBlockOuterSpacing
                let after: CGFloat = nextCode ? 0 : EditorStyle.codeBlockOuterSpacing
                if let ps = ts.attribute(.paragraphStyle, at: para.location, effectiveRange: nil) as? NSParagraphStyle,
                   ps.paragraphSpacingBefore != before || ps.paragraphSpacing != after {
                    ts.enumerateAttribute(.paragraphStyle, in: para) { value, sub, _ in
                        guard let m = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { return }
                        m.paragraphSpacingBefore = before
                        m.paragraphSpacing = after
                        ts.addAttribute(.paragraphStyle, value: m, range: sub)
                    }
                }
            } else if kind == .divider {
                let content = ns.substring(with: para).trimmingCharacters(in: .newlines)
                if content != EditorStyle.dividerCharacter {
                    let existing = ts.attribute(.paragraphStyle, at: para.location, effectiveRange: nil) as? NSParagraphStyle
                    ts.addAttribute(.paragraphStyle, value: EditorStyle.paragraphStyle(for: .body, existing: existing), range: para)
                }
            }
        }

        fitAttachments(in: ts, range: range)
    }

    static func fitAttachments(in ts: NSTextStorage, range: NSRange, maxWidth: CGFloat = EditorStyle.maxTextWidth - 40) {
        ts.enumerateAttribute(.attachment, in: range) { value, _, _ in
            guard let attachment = value as? NSTextAttachment,
                  let cell = attachment.attachmentCell as? NSTextAttachmentCell,
                  let image = cell.image else { return }
            let size = image.size
            if size.width > maxWidth, size.width > 0 {
                image.size = NSSize(width: maxWidth, height: (size.height * maxWidth / size.width).rounded())
            }
        }
    }

    /// Replaces the static table colors written to disk with dynamic ones so tables adapt to dark mode.
    static func refreshTableColors(in ts: NSTextStorage) {
        ts.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: ts.length)) { value, _, _ in
            guard let ps = value as? NSParagraphStyle else { return }
            for case let block as NSTextTableBlock in ps.textBlocks {
                block.setBorderColor(EditorStyle.tableBorder)
                if block.backgroundColor != nil { block.backgroundColor = EditorStyle.tableHeaderBackground }
            }
        }
    }

    static func blockKind(of ts: NSTextStorage, at location: Int) -> BlockKind {
        guard location < ts.length else { return .body }
        let ps = ts.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle
        let font = ts.attribute(.font, at: location, effectiveRange: nil) as? NSFont
        return EditorStyle.blockKind(paragraphStyle: ps, font: font)
    }

    // MARK: Paragraph helpers

    func paragraphRange(at location: Int) -> NSRange {
        nsString.paragraphRange(for: NSRange(location: min(location, nsString.length), length: 0))
    }

    /// Paragraph ranges touched by `range`; the empty trailing paragraph at the end of the text has length 0.
    func paragraphRanges(for range: NSRange) -> [NSRange] {
        let ns = nsString
        let len = ns.length
        if range.location >= len {
            if len == 0 || ns.character(at: len - 1) == 10 { return [NSRange(location: len, length: 0)] }
            return [ns.paragraphRange(for: NSRange(location: len, length: 0))]
        }
        var result: [NSRange] = []
        var loc = range.location
        let end = max(NSMaxRange(range), range.location + 1)
        while loc < end && loc < len {
            let para = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            result.append(para)
            if NSMaxRange(para) <= loc { break }
            loc = NSMaxRange(para)
        }
        return result
    }

    /// Paragraph text without the trailing newline.
    func content(of para: NSRange) -> String {
        var s = nsString.substring(with: para)
        if s.hasSuffix("\n") || s.hasSuffix("\u{2029}") { s.removeLast() }
        return s
    }

    func contentRange(of para: NSRange) -> NSRange {
        var r = para
        if r.length > 0 {
            let c = nsString.character(at: NSMaxRange(r) - 1)
            if c == 10 || c == 0x2029 { r.length -= 1 }
        }
        return r
    }

    func attributes(ofParagraph para: NSRange) -> [NSAttributedString.Key: Any] {
        if para.location < storage.length && para.length > 0 {
            return storage.attributes(at: para.location, effectiveRange: nil)
        }
        return typingAttributes
    }

    func blockKind(ofParagraph para: NSRange) -> BlockKind {
        let attrs = attributes(ofParagraph: para)
        return EditorStyle.blockKind(paragraphStyle: attrs[.paragraphStyle] as? NSParagraphStyle, font: attrs[.font] as? NSFont)
    }

    func marker(ofParagraph para: NSRange) -> ListMarker? {
        EditorStyle.listMarker(in: content(of: para))
    }

    func tableBlock(at location: Int) -> NSTextTableBlock? {
        let para = paragraphRange(at: location)
        let attrs = attributes(ofParagraph: para)
        return (attrs[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.compactMap { $0 as? NSTextTableBlock }.first
    }

    // MARK: Editing primitives (each call is undoable; calls within one event form one undo step)

    @discardableResult
    func replace(_ range: NSRange, with attributed: NSAttributedString, select: NSRange? = nil, actionName: String? = nil) -> Bool {
        guard shouldChangeText(in: range, replacementString: attributed.string) else { return false }
        storage.replaceCharacters(in: range, with: attributed)
        didChangeText()
        if let select { setSelectedRange(clamp(select)) }
        if let actionName { undoManager?.setActionName(actionName) }
        return true
    }

    func editAttributes(in range: NSRange, actionName: String? = nil, _ body: (NSTextStorage) -> Void) {
        guard range.length > 0, shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        body(storage)
        storage.endEditing()
        didChangeText()
        if let actionName { undoManager?.setActionName(actionName) }
    }

    func clamp(_ r: NSRange) -> NSRange {
        let len = storage.length
        let loc = max(0, min(r.location, len))
        return NSRange(location: loc, length: max(0, min(r.length, len - loc)))
    }

    struct ParagraphEdit {
        var range: NSRange
        /// Characters at the start of the old paragraph that are replaced (e.g. a list marker).
        var oldPrefix: Int
        var newPrefix: Int
        var text: NSAttributedString
    }

    /// Rewrites contiguous paragraphs in one replacement, mapping the selection through marker changes.
    func apply(_ edits: [ParagraphEdit], actionName: String? = nil) {
        guard let first = edits.first, let last = edits.last else { return }
        let union = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
        let result = NSMutableAttributedString()
        for e in edits { result.append(e.text) }

        func map(_ p: Int) -> Int {
            var delta = 0
            for e in edits {
                let newStart = e.range.location + delta
                if p < e.range.location { return p + delta }
                if p <= NSMaxRange(e.range) && (p < NSMaxRange(e.range) || e == edits.last!) {
                    let offset = p - e.range.location
                    if offset < e.oldPrefix { return newStart + e.newPrefix }
                    let mapped = newStart + e.newPrefix + (offset - e.oldPrefix)
                    return min(mapped, newStart + e.text.length)
                }
                delta += e.text.length - e.range.length
            }
            return p + delta
        }
        let sel = selectedRange()
        let start = map(sel.location)
        let end = map(NSMaxRange(sel))
        breakUndoCoalescing()
        replace(union, with: result, select: NSRange(location: start, length: max(0, end - start)), actionName: actionName)
    }

    // MARK: Key handling

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, let command = KeyShortcut.match(event) {
            perform(command)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? String) ?? (string as? NSAttributedString)?.string
        if let text, text == " " || text == "\t", !hasMarkedText(), selectedRange().length == 0 {
            autolinkWord(endingAt: selectedRange().location)
        }
        guard let text, !hasMarkedText(), replacementRange.location == NSNotFound,
              selectedRange().length == 0, handleMarkdownTrigger(text, dryRun: true) else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }
        // Type the character first, then convert on the next run-loop turn: the conversion becomes
        // its own undo group, so ⌘Z restores exactly what was typed (e.g. "**bold**").
        super.insertText(string, replacementRange: replacementRange)
        let caret = selectedRange()
        let length = storage.length
        DispatchQueue.main.async { [weak self] in
            guard let self, self.selectedRange() == caret, self.storage.length == length, caret.location > 0,
                  self.nsString.substring(with: NSRange(location: caret.location - 1, length: 1)) == text,
                  self.handleMarkdownTriggerAfterTyping(text, at: caret.location - 1) else { return }
        }
    }

    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Links the URL-like word just before `location` (complements AppKit's asynchronous link detection).
    func autolinkWord(endingAt location: Int) {
        guard location > 0, location <= storage.length else { return }
        let ns = nsString
        var start = location
        while start > 0 {
            let c = ns.character(at: start - 1)
            if let scalar = UnicodeScalar(c), CharacterSet.whitespacesAndNewlines.contains(scalar) { break }
            start -= 1
        }
        let word = NSRange(location: start, length: location - start)
        guard word.length >= 4, storage.attribute(.link, at: start, effectiveRange: nil) == nil else { return }
        let text = ns.substring(with: word)
        guard text.contains("."), let detector = Self.linkDetector else { return }
        for match in detector.matches(in: text, range: NSRange(location: 0, length: word.length)) {
            guard let url = match.url, url.scheme != "mailto" || text.contains("@") else { continue }
            let r = NSRange(location: start + match.range.location, length: match.range.length)
            storage.addAttribute(.link, value: url, range: r)
        }
        typingAttributes[.link] = nil
    }

    private func handleMarkdownTriggerAfterTyping(_ text: String, at location: Int) -> Bool {
        // Runs outside event dispatch, so AppKit's per-event undo group would stay open and swallow
        // the next keystroke; give the conversion its own explicit group instead.
        let um = undoManager
        let ownGroup = um.map { $0.groupingLevel == 0 } ?? false
        let groupsByEvent = um?.groupsByEvent ?? true
        if ownGroup {
            um?.groupsByEvent = false
            um?.beginUndoGrouping()
        }
        defer {
            if ownGroup {
                um?.endUndoGrouping()
                um?.groupsByEvent = groupsByEvent
            }
        }
        let attrs = typingAttributes
        breakUndoCoalescing()
        guard replace(NSRange(location: location, length: 1), with: NSAttributedString(), select: NSRange(location: location, length: 0)) else { return false }
        typingAttributes = attrs
        if handleMarkdownTrigger(text) { return true }
        replace(NSRange(location: location, length: 0), with: NSAttributedString(string: text, attributes: attrs),
                select: NSRange(location: location + 1, length: 0))
        return false
    }

    override func insertNewline(_ sender: Any?) {
        if selectedRange().length == 0, !hasMarkedText() { autolinkWord(endingAt: selectedRange().location) }
        if selectedRange().length == 0, !hasMarkedText(), handleNewline() { return }
        super.insertNewline(sender)
    }

    override func insertTab(_ sender: Any?) {
        let sel = selectedRange()
        if tableBlock(at: sel.location) != nil {
            moveToAdjacentCell(forward: true)
            return
        }
        if paragraphRanges(for: sel).contains(where: { marker(ofParagraph: $0) != nil }) {
            changeIndent(by: 1)
            return
        }
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        let sel = selectedRange()
        if tableBlock(at: sel.location) != nil {
            moveToAdjacentCell(forward: false)
            return
        }
        if paragraphRanges(for: sel).contains(where: { marker(ofParagraph: $0) != nil }) {
            changeIndent(by: -1)
            return
        }
        super.insertBacktab(sender)
    }

    override func deleteBackward(_ sender: Any?) {
        if selectedRange().length == 0, !hasMarkedText(), handleDeleteBackward() { return }
        super.deleteBackward(sender)
    }

    // MARK: Mouse (checkboxes)

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = checkboxCharacter(at: point) {
            toggleCheckbox(atParagraphStart: index)
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if checkboxCharacter(at: point) != nil {
            NSCursor.pointingHand.set()
            return
        }
        super.mouseMoved(with: event)
    }

    private func checkboxCharacter(at point: NSPoint) -> Int? {
        guard let lm = layoutManager as? NoteItLayoutManager, let tc = textContainer, storage.length > 0 else { return nil }
        let origin = textContainerOrigin
        let local = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        let glyph = lm.glyphIndex(for: local, in: tc, fractionOfDistanceThroughGlyph: nil)
        let index = lm.characterIndexForGlyph(at: glyph)
        guard index < storage.length else { return nil }
        let para = paragraphRange(at: index)
        guard case .checkbox = marker(ofParagraph: para)?.kind else { return nil }
        let box = lm.checkboxRect(forCharacterAt: para.location, origin: origin).insetBy(dx: -4, dy: -4)
        return box.contains(point) ? para.location : nil
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        var insertIndex = 0

        if tableBlock(at: selectedRange().location) != nil {
            for cmd in [FormatCommand.addRowAbove, .addRowBelow, .deleteRow] {
                menu.insertItem(menuItem(for: cmd), at: insertIndex)
                insertIndex += 1
            }
            menu.insertItem(.separator(), at: insertIndex)
            insertIndex += 1
        }

        let format = NSMenu(title: "Format")
        let groups: [[FormatCommand]] = [
            [.bold, .italic, .underline, .strikethrough, .inlineCode],
            [.block(.title), .block(.heading), .block(.subheading), .block(.body), .block(.code), .block(.quote)],
            [.list(.bullet), .list(.numbered), .list(.checklist), .toggleCheckbox],
            [.indent, .outdent, .align(.left), .align(.center), .align(.right)],
            [.toggleHighlight, .fontBigger, .fontSmaller],
            [.link, .divider, .table(rows: 3, columns: 3), .image],
            [.clearFormatting],
        ]
        for (i, group) in groups.enumerated() {
            if i > 0 { format.addItem(.separator()) }
            for cmd in group { format.addItem(menuItem(for: cmd)) }
        }
        let formatItem = NSMenuItem(title: "Format", action: nil, keyEquivalent: "")
        formatItem.submenu = format
        menu.insertItem(formatItem, at: insertIndex)
        menu.insertItem(.separator(), at: insertIndex + 1)
        return menu
    }

    private func menuItem(for cmd: FormatCommand) -> NSMenuItem {
        var title = cmd.title
        if case .table = cmd { title = "Insert Table" }
        let item = NSMenuItem(title: title, action: #selector(performMenuCommand(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = MenuCommandBox(cmd)
        item.image = NSImage(systemSymbolName: cmd.symbol, accessibilityDescription: nil)
        if let s = cmd.shortcut {
            item.keyEquivalent = s.displayKey ?? s.key
            item.keyEquivalentModifierMask = s.displayKey != nil ? s.modifiers.subtracting(.shift) : s.modifiers
        }
        let state = currentFormattingState()
        switch cmd {
        case .bold: item.state = state.bold ? .on : .off
        case .italic: item.state = state.italic ? .on : .off
        case .underline: item.state = state.underline ? .on : .off
        case .strikethrough: item.state = state.strikethrough ? .on : .off
        case .inlineCode: item.state = state.inlineCode ? .on : .off
        case .block(let k): item.state = state.block == k && state.list == nil ? .on : .off
        case .list(let k): item.state = state.list == k ? .on : .off
        case .addRowAbove:
            item.isEnabled = (tableBlock(at: selectedRange().location)?.startingRow ?? 0) > 0
        default: break
        }
        return item
    }

    @objc private func performMenuCommand(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? MenuCommandBox else { return }
        perform(box.command)
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(performMenuCommand(_:)) { return menuItem.isEnabled }
        return super.validateMenuItem(menuItem)
    }
}

final class MenuCommandBox: NSObject {
    let command: FormatCommand
    init(_ command: FormatCommand) { self.command = command }
}

extension NoteItTextView.ParagraphEdit: Equatable {
    static func == (a: Self, b: Self) -> Bool { a.range == b.range && a.oldPrefix == b.oldPrefix && a.newPrefix == b.newPrefix }
}

// MARK: - Layout manager

/// Draws code block backgrounds, quote bars, dividers and checklist checkboxes.
final class NoteItLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let ts = textStorage, ts.length > 0, let tc = textContainers.first else { return }
        let ns = ts.string as NSString
        let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        var range = ns.paragraphRange(for: chars)

        // Extend to whole runs so rounded backgrounds are always computed from the full block.
        func kind(at loc: Int) -> BlockKind { MainActor.assumeIsolated { NoteItTextView.blockKind(of: ts, at: loc) } }
        while range.location > 0 {
            let prev = ns.paragraphRange(for: NSRange(location: range.location - 1, length: 0))
            let k = kind(at: prev.location)
            guard k == .code || k == .quote else { break }
            range = NSUnionRange(range, prev)
        }
        while NSMaxRange(range) < ns.length {
            let next = ns.paragraphRange(for: NSRange(location: NSMaxRange(range), length: 0))
            let k = kind(at: next.location)
            guard k == .code || k == .quote else { break }
            range = NSUnionRange(range, next)
        }

        var runs: [(BlockKind, NSRange)] = []
        var loc = range.location
        while loc < NSMaxRange(range) {
            let para = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            let k = kind(at: para.location)
            if k == .code || k == .quote || k == .divider {
                if let last = runs.last, last.0 == k, k != .divider, NSMaxRange(last.1) == para.location,
                   !isTableCell(ts, at: para.location) {
                    runs[runs.count - 1].1 = NSUnionRange(last.1, para)
                } else {
                    runs.append((k, para))
                }
            }
            if NSMaxRange(para) <= loc { break }
            loc = NSMaxRange(para)
        }

        for (k, run) in runs {
            let glyphs = glyphRange(forCharacterRange: run, actualCharacterRange: nil)
            var lineBox = NSRect.null
            var used = NSRect.null
            enumerateLineFragments(forGlyphRange: glyphs) { rect, usedRect, _, _, _ in
                lineBox = lineBox.union(rect)
                used = used.union(usedRect)
            }
            guard !lineBox.isNull else { continue }
            let minX = isTableCell(ts, at: run.location) ? lineBox.minX : max(lineBox.minX, 0)
            let maxX = isTableCell(ts, at: run.location) ? lineBox.maxX : max(lineBox.maxX, tc.size.width)
            switch k {
            case .code:
                let rect = NSRect(x: minX + origin.x, y: used.minY + origin.y - 6, width: maxX - minX, height: used.height + 12)
                let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
                EditorStyle.codeBlockBackground.setFill()
                path.fill()
                EditorStyle.codeBlockBorder.setStroke()
                path.lineWidth = 1
                let inner = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 6.5, yRadius: 6.5)
                inner.lineWidth = 1
                inner.stroke()
            case .quote:
                let ps = ts.attribute(.paragraphStyle, at: run.location, effectiveRange: nil) as? NSParagraphStyle
                let indent = (ps?.firstLineHeadIndent ?? EditorStyle.quoteIndent) - EditorStyle.quoteIndent
                let bar = NSRect(x: minX + indent + origin.x + 2, y: used.minY + origin.y + 1, width: 3, height: used.height - 2)
                EditorStyle.quoteBar.setFill()
                NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
            case .divider:
                let y = (used.midY + origin.y).rounded() + 0.5
                let line = NSRect(x: minX + origin.x, y: y, width: maxX - minX, height: 1)
                EditorStyle.ruleColor.setFill()
                line.fill()
            default:
                break
            }
        }
    }

    private func isTableCell(_ ts: NSTextStorage, at loc: Int) -> Bool {
        guard loc < ts.length else { return false }
        let ps = ts.attribute(.paragraphStyle, at: loc, effectiveRange: nil) as? NSParagraphStyle
        return ps?.textBlocks.contains { $0 is NSTextTableBlock } ?? false
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let ts = textStorage, ts.length > 0 else {
            super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
            return
        }
        let ns = ts.string as NSString
        let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        var boxes: [(glyph: Int, char: Int, checked: Bool)] = []
        var p = ns.paragraphRange(for: NSRange(location: chars.location, length: 0)).location
        while p < NSMaxRange(chars) {
            if p >= chars.location, p + 1 < ns.length, ns.character(at: p + 1) == 9 {
                let c = ns.substring(with: NSRange(location: p, length: 1))
                if c == EditorStyle.uncheckedBox || c == EditorStyle.checkedBox {
                    boxes.append((glyphIndexForCharacter(at: p), p, c == EditorStyle.checkedBox))
                }
            }
            let para = ns.paragraphRange(for: NSRange(location: p, length: 0))
            if NSMaxRange(para) <= p { break }
            p = NSMaxRange(para)
        }
        guard !boxes.isEmpty else {
            super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
            return
        }
        var cursor = glyphsToShow.location
        for box in boxes where box.glyph >= cursor && box.glyph < NSMaxRange(glyphsToShow) {
            if box.glyph > cursor {
                super.drawGlyphs(forGlyphRange: NSRange(location: cursor, length: box.glyph - cursor), at: origin)
            }
            drawCheckbox(characterIndex: box.char, checked: box.checked, origin: origin)
            cursor = box.glyph + 1
        }
        if cursor < NSMaxRange(glyphsToShow) {
            super.drawGlyphs(forGlyphRange: NSRange(location: cursor, length: NSMaxRange(glyphsToShow) - cursor), at: origin)
        }
    }

    func checkboxRect(forCharacterAt index: Int, origin: NSPoint) -> NSRect {
        guard let ts = textStorage, index < ts.length else { return .zero }
        let glyph = glyphIndexForCharacter(at: index)
        let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let loc = location(forGlyphAt: glyph)
        // Size and center from the paragraph text's font, not the (possibly substituted) marker glyph font.
        let textFont = (index + 2 < ts.length ? ts.attribute(.font, at: index + 2, effectiveRange: nil) : nil) as? NSFont
            ?? (ts.attribute(.font, at: index, effectiveRange: nil) as? NSFont) ?? .systemFont(ofSize: 14)
        let side = (textFont.pointSize * 1.08).rounded()
        let baseline = line.minY + loc.y
        let centerY = baseline - textFont.xHeight / 2 - 0.5
        return NSRect(x: line.minX + loc.x + origin.x, y: centerY - side / 2 + origin.y, width: side, height: side)
    }

    private func drawCheckbox(characterIndex: Int, checked: Bool, origin: NSPoint) {
        let rect = checkboxRect(forCharacterAt: characterIndex, origin: origin).insetBy(dx: 0.75, dy: 0.75)
        let circle = NSBezierPath(ovalIn: rect)
        if checked {
            NSColor.controlAccentColor.setFill()
            circle.fill()
            let check = NSBezierPath()
            let w = rect.width, h = rect.height
            check.move(to: NSPoint(x: rect.minX + w * 0.28, y: rect.minY + h * 0.52))
            check.line(to: NSPoint(x: rect.minX + w * 0.44, y: rect.minY + h * 0.68))
            check.line(to: NSPoint(x: rect.minX + w * 0.73, y: rect.minY + h * 0.34))
            check.lineWidth = max(1.5, w * 0.11)
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            NSColor.white.setStroke()
            check.stroke()
        } else {
            NSColor.secondaryLabelColor.setStroke()
            circle.lineWidth = 1.3
            circle.stroke()
        }
    }
}
