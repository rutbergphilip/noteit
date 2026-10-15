import AppKit

extension NSAttributedString.Key {
    /// Layout-manager temporary attribute on Automatic code blocks: the guessed `CodeLanguage` raw value.
    static let guessedCodeLanguage = NSAttributedString.Key("NoteItGuessedCodeLanguage")
}

/// Display-time styling for inline code and code blocks: pill padding, the inline code font and tint,
/// syntax colors and the guessed language. Colors are temporary attributes (never saved); the kern
/// and inline font swap live in the text storage but are removed by `NoteItTextView.attributedString()`.
@MainActor
final class CodeStyler {
    /// Kern after the character before inline code and after its last character, so the pill has room.
    static let pillKern: CGFloat = 4.5

    unowned let textView: NoteItTextView
    private(set) var settings = CodeStyleSettings.current
    private(set) var isApplying = false
    private var pendingRange: NSRange?
    private var flushScheduled = false
    private var highlightRange: NSRange?
    private var highlightWork: DispatchWorkItem?
    private var defaultsObserver: NSObjectProtocol?

    init(textView: NoteItTextView) {
        self.textView = textView
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsMayHaveChanged() }
        }
    }

    deinit {
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
    }

    private var storage: NSTextStorage { textView.storage }
    private var layoutManager: NoteItLayoutManager? { textView.layoutManager as? NoteItLayoutManager }

    private func settingsMayHaveChanged() {
        let current = CodeStyleSettings.current
        guard current != settings else { return }
        settings = current
        layoutManager?.codeSettings = current
        restyleAll()
    }

    /// Re-applies everything, e.g. after a settings change.
    func restyleAll() {
        noteEdit(NSRange(location: 0, length: storage.length))
        flush(typing: false)
        textView.needsDisplay = true
    }

    // MARK: Edits

    /// Called from `textStorage(_:willProcessEditing:…)` with the edited range (post-edit coordinates).
    func noteEdit(_ range: NSRange) {
        guard !isApplying else { return }
        pendingRange = pendingRange.map { NSUnionRange($0, range) } ?? range
        guard !flushScheduled else { return }
        flushScheduled = true
        // Programmatic changes (loading a note, remote updates, undo) get styled on the next turn;
        // typing flushes right away from `didChangeText`.
        DispatchQueue.main.async { [weak self] in
            self?.flush(typing: false)
        }
    }

    func flush(typing: Bool) {
        flushScheduled = false
        guard let pending = pendingRange else { return }
        pendingRange = nil
        let length = storage.length
        guard length > 0 else { return }
        let start = min(pending.location, length)
        let clamped = NSRange(location: start, length: min(NSMaxRange(pending), length) - start)
        let ns = storage.string as NSString
        let paragraphs = ns.paragraphRange(for: clamped)

        isApplying = true
        storage.beginEditing()
        applyInlineDisplay(in: paragraphs)
        storage.endEditing()
        isApplying = false

        applyInlineColors(in: paragraphs)
        let blocks = codeBlocks(intersecting: paragraphs)
        if typing {
            for block in blocks { highlightRange = highlightRange.map { NSUnionRange($0, block) } ?? block }
            scheduleHighlight()
        } else {
            for block in blocks { highlight(block) }
        }
    }

    private func scheduleHighlight() {
        highlightWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let range = self.highlightRange else { return }
            self.highlightRange = nil
            let length = self.storage.length
            guard length > 0 else { return }
            let start = min(range.location, length)
            let clamped = NSRange(location: start, length: min(NSMaxRange(range), length) - start)
            for block in self.codeBlocks(intersecting: clamped) { self.highlight(block) }
        }
        highlightWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    // MARK: Inline code

    private func kind(at location: Int) -> BlockKind {
        NoteItTextView.blockKind(of: storage, at: location)
    }

    /// Strips the legacy flat background (highlights stay), swaps the font for *Same as Text*, and adds pill padding.
    private func applyInlineDisplay(in range: NSRange) {
        let ns = storage.string as NSString
        let sameAsText = settings.inlineFont == .sameAsText
        var loc = range.location
        while loc < NSMaxRange(range) {
            let para = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            defer { loc = max(NSMaxRange(para), loc + 1) }
            guard para.length > 0 else { continue }
            var kerned = IndexSet()
            storage.enumerateAttribute(.kern, in: para) { value, r, _ in
                if let k = value as? CGFloat, abs(k - Self.pillKern) < 0.001 { kerned.insert(integersIn: r.location..<NSMaxRange(r)) }
            }
            if kind(at: para.location) == .code {
                for r in kerned.rangeView { storage.removeAttribute(.kern, range: NSRange(r)) }
                storage.removeAttribute(.inlineCodeDisplay, range: para)
                continue
            }
            var runs: [NSRange] = []
            storage.enumerateAttributes(in: para) { attrs, r, _ in
                guard EditorStyle.isInlineCode(attrs) else {
                    if attrs[.inlineCodeDisplay] != nil { storage.removeAttribute(.inlineCodeDisplay, range: r) }
                    return
                }
                if EditorStyle.isLegacyInlineCodeBackground(attrs[.backgroundColor] as? NSColor) { storage.removeAttribute(.backgroundColor, range: r) }
                if let font = attrs[.font] as? NSFont {
                    if sameAsText, attrs[.inlineCodeDisplay] == nil {
                        storage.addAttributes([.font: Self.textFont(forCode: font), .inlineCodeDisplay: true], range: r)
                    } else if !sameAsText, attrs[.inlineCodeDisplay] != nil {
                        storage.addAttribute(.font, value: Self.codeFont(forText: font), range: r)
                        storage.removeAttribute(.inlineCodeDisplay, range: r)
                    }
                }
                if let last = runs.last, NSMaxRange(last) == r.location {
                    runs[runs.count - 1].length += r.length
                } else {
                    runs.append(r)
                }
            }
            // Only touch kerns that change, so typing doesn't re-layout more than it must.
            var wanted = IndexSet()
            for run in runs {
                let lastChar = NSMaxRange(run) - 1
                if !isLineEnd(ns.character(at: lastChar)) { wanted.insert(lastChar) }
                let before = run.location - 1
                if before >= para.location, !isLineEnd(ns.character(at: before)) { wanted.insert(before) }
            }
            for r in kerned.subtracting(wanted).rangeView { storage.removeAttribute(.kern, range: NSRange(r)) }
            for r in wanted.subtracting(kerned).rangeView { storage.addAttribute(.kern, value: Self.pillKern, range: NSRange(r)) }
        }
    }

    private func isLineEnd(_ c: unichar) -> Bool { c == 10 || c == 13 || c == 0x2028 || c == 0x2029 }

    static func textFont(forCode font: NSFont) -> NSFont {
        let bold = EditorStyle.isBold(font)
        var result = NSFont.systemFont(ofSize: font.pointSize + 1, weight: bold ? .bold : .regular)
        if EditorStyle.isItalic(font) { result = NSFontManager.shared.convert(result, toHaveTrait: .italicFontMask) }
        return result
    }

    static func codeFont(forText font: NSFont) -> NSFont {
        let bold = EditorStyle.isBold(font)
        var result = NSFont.monospacedSystemFont(ofSize: max(font.pointSize - 1, 6), weight: bold ? .bold : .medium)
        if EditorStyle.isItalic(font) { result = NSFontManager.shared.convert(result, toHaveTrait: .italicFontMask) }
        return result
    }

    /// The text as it is saved: inline code back in its monospaced font, without pill padding.
    static func persisted(_ text: NSAttributedString) -> NSAttributedString {
        let full = NSRange(location: 0, length: text.length)
        var needsWork = false
        text.enumerateAttribute(.inlineCodeDisplay, in: full) { v, _, stop in if v != nil { needsWork = true; stop.pointee = true } }
        if !needsWork {
            text.enumerateAttribute(.kern, in: full) { v, _, stop in
                if let k = v as? CGFloat, abs(k - pillKern) < 0.001 { needsWork = true; stop.pointee = true }
            }
        }
        guard needsWork else { return text }
        let copy = NSMutableAttributedString(attributedString: text)
        copy.enumerateAttribute(.kern, in: full) { v, r, _ in
            if let k = v as? CGFloat, abs(k - pillKern) < 0.001 { copy.removeAttribute(.kern, range: r) }
        }
        copy.enumerateAttribute(.inlineCodeDisplay, in: full) { v, r, _ in
            guard v != nil else { return }
            copy.enumerateAttribute(.font, in: r) { f, fr, _ in
                if let f = f as? NSFont, !EditorStyle.isMonospaced(f) { copy.addAttribute(.font, value: codeFont(forText: f), range: fr) }
            }
            copy.removeAttribute(.inlineCodeDisplay, range: r)
        }
        return copy
    }

    private func applyInlineColors(in range: NSRange) {
        guard let lm = layoutManager else { return }
        let ns = storage.string as NSString
        let color = settings.inlineColor.textColor
        var loc = range.location
        while loc < NSMaxRange(range) {
            let para = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            defer { loc = max(NSMaxRange(para), loc + 1) }
            guard para.length > 0, kind(at: para.location) != .code else { continue }
            lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: para)
            storage.enumerateAttributes(in: para) { attrs, r, _ in
                if EditorStyle.isInlineCode(attrs), attrs[.link] == nil {
                    lm.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: r)
                }
            }
        }
    }

    // MARK: Code blocks

    /// Whole code blocks overlapping `range`.
    func codeBlocks(intersecting range: NSRange) -> [NSRange] {
        let ns = storage.string as NSString
        var result: [NSRange] = []
        var loc = range.location
        while loc < min(NSMaxRange(range) + 1, ns.length) {
            let para = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            if kind(at: para.location) == .code, let block = textView.codeBlockRange(at: para.location) {
                result.append(block)
                loc = max(NSMaxRange(block), loc + 1)
            } else {
                loc = max(NSMaxRange(para), loc + 1)
            }
            if loc >= NSMaxRange(range) { break }
        }
        return result
    }

    func highlight(_ block: NSRange) {
        guard let lm = layoutManager, NSMaxRange(block) <= storage.length, block.length > 0 else { return }
        let text = (storage.string as NSString).substring(with: block)
        let ps = storage.attribute(.paragraphStyle, at: block.location, effectiveRange: nil) as? NSParagraphStyle
        let explicit = EditorStyle.codeLanguage(of: ps)
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: block)
        lm.removeTemporaryAttribute(.guessedCodeLanguage, forCharacterRange: block)
        var language = explicit
        if explicit == nil, let guess = SyntaxHighlighter.guessLanguage(text) {
            language = guess
            lm.addTemporaryAttribute(.guessedCodeLanguage, value: guess.rawValue, forCharacterRange: block)
        }
        guard settings.highlighting else { return }
        let theme = settings.theme
        lm.addTemporaryAttribute(.foregroundColor, value: theme.color(for: nil), forCharacterRange: block)
        guard let language else { return }
        for token in SyntaxHighlighter.tokenize(text, language: language) {
            let r = NSRange(location: block.location + token.range.location, length: token.range.length)
            lm.addTemporaryAttribute(.foregroundColor, value: theme.color(for: token.kind), forCharacterRange: r)
        }
    }

    // MARK: Card actions

    func setLanguage(_ language: CodeLanguage?, forBlockAt location: Int) {
        guard let block = textView.codeBlockRange(at: location) else { return }
        textView.editAttributes(in: block, actionName: "Code Language") { ts in
            ts.enumerateAttribute(.paragraphStyle, in: block) { value, r, _ in
                let m = ((value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
                EditorStyle.setCodeLanguage(language, on: m)
                ts.addAttribute(.paragraphStyle, value: m, range: r)
            }
        }
        highlight(block)
        textView.needsDisplay = true
    }

    func copyBlock(at location: Int) {
        guard let block = textView.codeBlockRange(at: location) else { return }
        var text = (storage.string as NSString).substring(with: block)
        if text.hasSuffix("\n") { text.removeLast() }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text.replacingOccurrences(of: "\u{2028}", with: "\n"), forType: .string)
        layoutManager?.copiedCodeBlock = block.location
        textView.invalidateCodeCard(at: block.location)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            guard let self, self.layoutManager?.copiedCodeBlock == block.location else { return }
            self.layoutManager?.copiedCodeBlock = nil
            self.textView.invalidateCodeCard(at: block.location)
        }
    }

    func showLanguageMenu(forBlockAt location: Int, at point: NSPoint) {
        guard let block = textView.codeBlockRange(at: location) else { return }
        let ps = storage.attribute(.paragraphStyle, at: block.location, effectiveRange: nil) as? NSParagraphStyle
        let current = EditorStyle.codeLanguage(of: ps)
        let guess = layoutManager?.temporaryAttribute(.guessedCodeLanguage, atCharacterIndex: block.location, effectiveRange: nil) as? Int
        let menu = NSMenu()
        let auto = NSMenuItem(title: guess.flatMap(CodeLanguage.init(rawValue:)).map { "Automatic (\($0.displayName))" } ?? "Automatic",
                              action: #selector(LanguageMenuTarget.choose(_:)), keyEquivalent: "")
        auto.state = current == nil ? .on : .off
        let target = LanguageMenuTarget { [weak self] raw in
            self?.setLanguage(raw.flatMap(CodeLanguage.init(rawValue:)), forBlockAt: block.location)
        }
        auto.target = target
        menu.addItem(auto)
        menu.addItem(.separator())
        for language in CodeLanguage.allCases {
            let item = NSMenuItem(title: language.displayName, action: #selector(LanguageMenuTarget.choose(_:)), keyEquivalent: "")
            item.tag = language.rawValue
            item.target = target
            item.state = current == language ? .on : .off
            menu.addItem(item)
            if language == .plain { menu.addItem(.separator()) }
        }
        withExtendedLifetime(target) {
            menu.popUp(positioning: nil, at: point, in: textView)
        }
    }
}

private final class LanguageMenuTarget: NSObject {
    let action: (Int?) -> Void
    init(_ action: @escaping (Int?) -> Void) { self.action = action }
    @objc func choose(_ sender: NSMenuItem) { action(sender.tag == 0 ? nil : sender.tag) }
}
