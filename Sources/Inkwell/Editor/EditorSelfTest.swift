import AppKit

#if DEBUG

/// Scripted editor exercise, enabled only with `INKWELL_EDITOR_SELFTEST=1`. It drives the real
/// text view through `insertText`/`doCommand` (the same entry points as typing) so markdown
/// shortcuts, list continuation and toolbar commands can be checked without synthetic key events.
@MainActor
enum EditorSelfTest {
    private static var started = false

    static func startIfRequested() {
        guard !started, ProcessInfo.processInfo.environment["INKWELL_EDITOR_SELFTEST"] == "1" else { return }
        started = true
        if ProcessInfo.processInfo.environment["INKWELL_EDITOR_SELFTEST_DARK"] == "1" {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        Task { @MainActor in await run() }
    }

    private static func log(_ s: String) {
        FileHandle.standardOutput.write(("SELFTEST " + s + "\n").data(using: .utf8)!)
    }

    private static func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static var textView: InkwellTextView? {
        NSApp.windows.lazy.compactMap { $0.firstResponder as? InkwellTextView }.first
            ?? NSApp.windows.lazy.compactMap { findTextView(in: $0.contentView) }.first
    }

    private static func findTextView(in view: NSView?) -> InkwellTextView? {
        guard let view else { return nil }
        if let tv = view as? InkwellTextView { return tv }
        for sub in view.subviews { if let tv = findTextView(in: sub) { return tv } }
        return nil
    }

    private static func type(_ text: String, into tv: InkwellTextView) async {
        for ch in text {
            event(tv) {
                switch ch {
                case "\n": tv.doCommand(by: #selector(NSResponder.insertNewline(_:)))
                case "\t": tv.doCommand(by: #selector(NSResponder.insertTab(_:)))
                default: tv.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0))
                }
            }
            // Let deferred markdown conversions run between keystrokes, as with real typing.
            await sleep(0.004)
        }
    }

    /// Mimics one AppKit event: one explicit undo group (the test disables `groupsByEvent`).
    private static func event(_ tv: InkwellTextView, _ body: () -> Void) {
        let um = tv.undoManager
        um?.beginUndoGrouping()
        body()
        um?.endUndoGrouping()
    }

    private static func dump(_ tv: InkwellTextView) {
        let ns = tv.string as NSString
        var loc = 0
        while loc < ns.length {
            let para = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            let ps = tv.storage.attribute(.paragraphStyle, at: para.location, effectiveRange: nil) as? NSParagraphStyle
            let text = ns.substring(with: para).trimmingCharacters(in: .newlines)
            let size = (tv.storage.attribute(.font, at: para.location, effectiveRange: nil) as? NSFont)?.pointSize ?? -1
            log("  [\(tv.blockKind(ofParagraph: para))] L\(EditorStyle.listLevel(of: ps)) head=\(ps?.headIndent ?? -1) tab=\(ps?.defaultTabInterval ?? -1) pt=\(size) \(text.debugDescription)")
            loc = NSMaxRange(para)
        }
    }

    private static func run() async {
        let store = NoteStore.shared
        await sleep(1.5)
        // INKWELL_EDITOR_SELFTEST_SHOW=<title prefix>: only open that note (for screenshots).
        if let show = ProcessInfo.processInfo.environment["INKWELL_EDITOR_SELFTEST_SHOW"] {
            store.selectedNoteID = store.notes.first(where: { $0.title.hasPrefix(show) })?.id
            log("showing \(show)")
            return
        }
        if let shortcuts = store.notes.first(where: { $0.title.hasPrefix("Custom keyboard") }) {
            store.selectedNoteID = shortcuts.id
        }
        log("phase1 shortcuts-note")
        await sleep(4)

        _ = store.createNoteInCurrentContext()
        await sleep(1)
        guard let tv = textView else { log("no text view"); return }
        tv.window?.makeFirstResponder(tv)
        tv.undoManager?.groupsByEvent = false
        await type("Hello Inkwell\n", into: tv)
        await type("## Markdown as you type\n", into: tv)
        await type("Some **bold**, *italic*, `code` and ~~strike~~ text.\n", into: tv)
        await type("- first bullet\nsecond bullet\n\tnested bullet\n\n\n", into: tv)
        await type("1. one\ntwo\nthree\n\n", into: tv)
        await type("[] buy milk\nship the editor\n\n", into: tv)
        await type("> A quote that matters.\n\n", into: tv)
        await type("```\nlet answer = 42\nprint(answer)\n\n", into: tv)
        await type("---\n", into: tv)
        await type("Visit https://example.com for more.", into: tv)
        await type("\n", into: tv)

        let s = tv.string as NSString
        let milk = s.range(of: "buy milk")
        if milk.location != NSNotFound {
            tv.setSelectedRange(NSRange(location: milk.location, length: 0))
            event(tv) { tv.perform(.toggleCheckbox) }
        }
        let more = s.range(of: "for more")
        if more.location != NSNotFound {
            tv.setSelectedRange(more)
            event(tv) { tv.perform(.textColor(EditorStyle.textColors[1].color)) }
            event(tv) { tv.perform(.highlight(EditorStyle.highlightColors[0].color)) }
        }
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        event(tv) { tv.perform(.table(rows: 3, columns: 3)) }
        await type("Name\tRole\tTeam\tAda\tEngineer\tCore", into: tv)
        event(tv) { tv.perform(.addRowBelow) }
        await type("Grace\tAdmiral\tNavy", into: tv)

        // Single-step undo of a markdown conversion.
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        event(tv) { tv.perform(.block(.body)) }
        await type("undo check **bold*", into: tv)
        await sleep(0.3)
        await type("*", into: tv)
        await sleep(0.3)
        let before = (tv.string as NSString).substring(from: max(0, (tv.string as NSString).length - 12))
        tv.undoManager?.undo()
        let after = (tv.string as NSString).substring(from: max(0, (tv.string as NSString).length - 12))
        log("undo: \(before.debugDescription) -> \(after.debugDescription)")
        tv.undoManager?.redo()
        await type("\n# ", into: tv)
        await sleep(0.3)
        let headingBefore = tv.blockKind(ofParagraph: tv.paragraphRanges(for: tv.selectedRange()).first!)
        tv.undoManager?.undo()
        let tail = (tv.string as NSString).substring(from: max(0, (tv.string as NSString).length - 4))
        log("undo heading: kind=\(headingBefore) -> tail=\(tail.debugDescription)")
        tv.undoManager?.redo()
        await type("Heading via markdown", into: tv)
        tv.scrollToBeginningOfDocument(nil)
        dump(tv)
        var links: [String] = []
        tv.storage.enumerateAttribute(.link, in: NSRange(location: 0, length: tv.storage.length)) { v, r, _ in
            if v != nil { links.append((tv.storage.string as NSString).substring(with: r)) }
        }
        log("links: \(links)")
        log("phase2 typed")
        await sleep(5)

        let newID = store.selectedNoteID
        if let shortcuts = store.notes.first(where: { $0.title.hasPrefix("Custom keyboard") }) {
            store.selectedNoteID = shortcuts.id
        }
        await sleep(0.5)
        store.selectedNoteID = newID
        await sleep(0.5)
        textView?.scrollToEndOfDocument(nil)
        log("phase3 reloaded+scrolled")
        if ProcessInfo.processInfo.environment["INKWELL_EDITOR_SELFTEST_NARROW"] == "1", let w = textView?.window {
            var f = w.frame
            f.size.width = 900
            w.setFrame(f, display: true)
            log("narrowed window to 900")
        }
        checkHeadingSentinels()
        await checkDebounce(store: store)
        log("done")
    }

    // MARK: Heading sentinels

    private static func kinds(of text: NSAttributedString) -> [BlockKind] {
        let ns = text.string as NSString
        var result: [BlockKind] = []
        var loc = 0
        while loc < ns.length {
            let para = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            let attrs = text.attributes(at: para.location, effectiveRange: nil)
            result.append(EditorStyle.blockKind(paragraphStyle: attrs[.paragraphStyle] as? NSParagraphStyle, font: attrs[.font] as? NSFont))
            loc = NSMaxRange(para)
        }
        return result
    }

    private static func tabs(of text: NSAttributedString) -> [CGFloat] {
        let ns = text.string as NSString
        var result: [CGFloat] = []
        var loc = 0
        while loc < ns.length {
            let para = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            result.append((text.attribute(.paragraphStyle, at: para.location, effectiveRange: nil) as? NSParagraphStyle)?.defaultTabInterval ?? -1)
            loc = NSMaxRange(para)
        }
        return result
    }

    /// Same serialization path as `NoteStore` (RTFD file wrapper), fully serialized and read back.
    private static func rtfdRoundTrip(_ text: NSAttributedString) -> NSAttributedString? {
        guard let wrapper = try? text.fileWrapper(from: NSRange(location: 0, length: text.length),
                                                  documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]),
              let data = wrapper.serializedRepresentation,
              let restored = FileWrapper(serializedRepresentation: data) else { return nil }
        return NSAttributedString(rtfdFileWrapper: restored, documentAttributes: nil)
    }

    private static func checkHeadingSentinels() {
        let defaults = UserDefaults.standard
        let savedSize = defaults.object(forKey: "editorFontSize")
        defer { defaults.set(savedSize, forKey: "editorFontSize") }
        defaults.set(14.0, forKey: "editorFontSize")

        let doc = NSMutableAttributedString()
        doc.append(EditorStyle.paragraph("Title", kind: .title))
        doc.append(EditorStyle.paragraph("Heading", kind: .heading))
        doc.append(EditorStyle.paragraph("Subheading", kind: .subheading))
        doc.append(EditorStyle.paragraph("Body", kind: .body))
        doc.append(EditorStyle.paragraph("Code", kind: .code))
        doc.append(EditorStyle.paragraph("Quote", kind: .quote))
        doc.append(EditorStyle.divider())
        doc.append(EditorStyle.bullet("Bullet"))
        let bold = NSMutableAttributedString(attributedString: EditorStyle.paragraph("Bold body", kind: .body))
        bold.addAttribute(.font, value: NSFont.systemFont(ofSize: 14, weight: .bold), range: NSRange(location: 0, length: bold.length))
        doc.append(bold)
        // Legacy heading: heading font, no sentinel.
        let legacyPS = NSMutableParagraphStyle()
        legacyPS.defaultTabInterval = EditorStyle.defaultTab
        doc.append(NSAttributedString(string: "Legacy heading\n", attributes: [.font: NSFont.systemFont(ofSize: 19, weight: .semibold), .paragraphStyle: legacyPS]))

        let expected = kinds(of: doc)
        log("sentinel original kinds=\(expected.map(\.rawValue)) tabs=\(tabs(of: doc))")
        guard let restored = rtfdRoundTrip(doc) else { log("sentinel RTFD round-trip FAILED to serialize"); return }
        let restoredKinds = kinds(of: restored)
        log("sentinel rtfd kinds=\(restoredKinds.map(\.rawValue)) tabs=\(tabs(of: restored))")
        log("sentinel rtfd round-trip \(restoredKinds == expected ? "PASS" : "FAIL")")

        var allStable = true
        for size in [10.0, 20.0, 30.0] {
            defaults.set(size, forKey: "editorFontSize")
            let k = kinds(of: restored)
            // Only the sentinel-less legacy paragraph (last) may be re-classified.
            let stable = Array(k.dropLast()) == Array(expected.dropLast())
            allStable = allStable && stable
            log("sentinel editorFontSize=\(Int(size)) kinds=\(k.map(\.rawValue)) \(stable ? "PASS" : "FAIL")")
        }
        if let tv = textView {
            defaults.set(14.0, forKey: "editorFontSize")
            let live14 = kinds(of: tv.storage)
            defaults.set(24.0, forKey: "editorFontSize")
            let live24 = kinds(of: tv.storage)
            let stable = live14 == live24
            allStable = allStable && stable
            log("sentinel live note headings@14=\(live14.filter(EditorStyle.isHeading).map(\.rawValue)) @24=\(live24.filter(EditorStyle.isHeading).map(\.rawValue)) \(stable ? "PASS" : "FAIL")")
        }
        log("sentinel classification after editorFontSize change \(allStable ? "PASS" : "FAIL")")
    }

    // MARK: Debounced commits

    private static func checkDebounce(store: NoteStore) async {
        guard let tv = textView, let id = store.selectedNoteID else { log("debounce: no text view"); return }
        tv.window?.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: tv.storage.length, length: 0))
        await sleep(0.5)

        func committed(_ marker: String) -> Bool { store.body(for: id).string.contains(marker) }
        let count0 = RichTextEditor.Coordinator.storeCommitCount
        await type("\ndebounce probe alpha", into: tv)
        let duringTyping = RichTextEditor.Coordinator.storeCommitCount - count0
        let beforeForce = committed("probe alpha")
        NotificationCenter.default.post(name: NSApplication.willResignActiveNotification, object: NSApp)
        let afterForce = committed("probe alpha")
        let forceCount = RichTextEditor.Coordinator.storeCommitCount - count0
        let ok1 = duringTyping == 0 && !beforeForce && afterForce && forceCount == 1
        log("debounce typed 21 keys: updateBody calls while typing=\(duringTyping), in store before forced commit=\(beforeForce), after willResignActive=\(afterForce), total calls=\(forceCount) \(ok1 ? "PASS" : "FAIL")")

        let count1 = RichTextEditor.Coordinator.storeCommitCount
        await type(" beta", into: tv)
        let idleBefore = committed("alpha beta")
        await sleep(RichTextEditor.Coordinator.commitDelay + 0.3)
        let idleAfter = committed("alpha beta")
        let idleCount = RichTextEditor.Coordinator.storeCommitCount - count1
        let ok2 = !idleBefore && idleAfter && idleCount == 1
        log("debounce idle commit: before idle=\(idleBefore), after idle=\(idleAfter), calls=\(idleCount) \(ok2 ? "PASS" : "FAIL")")

        await type(" gamma", into: tv)
        let switchBefore = committed("beta gamma")
        if let other = store.notes.first(where: { $0.id != id }) { store.selectedNoteID = other.id }
        await sleep(0.05)
        let switchAfter = committed("beta gamma")
        let ok3 = !switchBefore && switchAfter
        log("debounce note switch commit: before=\(switchBefore), after switch=\(switchAfter) \(ok3 ? "PASS" : "FAIL")")
        store.selectedNoteID = id
        await sleep(0.5)
    }
}
#endif
