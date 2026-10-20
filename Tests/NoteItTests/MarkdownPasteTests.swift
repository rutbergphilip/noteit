import AppKit
import XCTest
@testable import NoteIt

@MainActor
final class MarkdownPasteTests: XCTestCase {
    private var pasteboards: [NSPasteboard] = []
    private var windows: [NSWindow] = []

    override func tearDown() {
        pasteboards.forEach { $0.releaseGlobally() }
        pasteboards = []
        windows.forEach { $0.close() }
        windows = []
        super.tearDown()
    }

    private func pasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("noteit-tests-\(UUID().uuidString)"))
        pb.clearContents()
        pasteboards.append(pb)
        return pb
    }

    private func pasteboard(plain: String) -> NSPasteboard {
        let pb = pasteboard()
        pb.setString(plain, forType: .string)
        return pb
    }

    private func editor(_ text: NSAttributedString, caret: Int? = nil) -> NoteItTextView {
        let (scrollView, view) = NoteItTextView.make()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        windows.append(window)
        view.storage.setAttributedString(text)
        view.normalizePendingEdits()
        view.setSelectedRange(NSRange(location: caret ?? text.length, length: 0))
        return view
    }

    private func body(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: EditorStyle.bodyAttributes)
    }

    private func kind(_ view: NoteItTextView, of needle: String) -> BlockKind {
        let at = (view.string as NSString).range(of: needle).location
        XCTAssertNotEqual(at, NSNotFound, "missing \(needle)")
        return view.blockKind(ofParagraph: view.paragraphRange(at: at))
    }

    private func font(_ view: NoteItTextView, at needle: String) -> NSFont? {
        let at = (view.string as NSString).range(of: needle).location
        return view.storage.attribute(.font, at: at, effectiveRange: nil) as? NSFont
    }

    // MARK: Detector

    func testDetectsMarkdownSource() {
        for text in ["# Title", "## Notes\nSome text", "- one\n- two", "* item", "+ item", "1. first\n2. second",
                     "> quoted", "- [ ] task", "- [x] done", "```\ncode\n```", "Above\n\n---\n\nBelow",
                     "| a | b |\n|---|---|\n| 1 | 2 |", "some **bold** text", "__strong__ words", "run `make` now",
                     "see [the docs](https://example.com)", "~~gone~~"] {
            XCTAssertTrue(MarkdownPasteDetector.looksLikeMarkdown(text), text)
        }
    }

    func testIgnoresOrdinaryText() {
        for text in ["https://example.com/some_path/__init__?q=*", "important*", "*", "2*3*4",
                     "Plain prose, with punctuation - and a dash.", "#hashtag and #another", "a**2 + b**2",
                     "Price: 5 * 3", "x | y", "Dear team,\n\nThanks for the update.\nBest"] {
            XCTAssertFalse(MarkdownPasteDetector.looksLikeMarkdown(text), text)
        }
    }

    // MARK: ⌘V

    func testPastesBlocksInEditorStyles() {
        let view = editor(body("Intro\n"))
        let markdown = "## Plan\n\n- one\n- two\n\n- [ ] task\n- [x] done\n\n1. first\n2. second\n\n> quote\n\nsome **bold** and [a link](https://example.com)"
        XCTAssertTrue(view.pasteMarkdown(from: pasteboard(plain: markdown)))

        XCTAssertEqual(kind(view, of: "Intro"), .body)
        XCTAssertEqual(kind(view, of: "Plan"), .heading)
        XCTAssertEqual(kind(view, of: "quote"), .quote)
        let ns = view.string as NSString
        for item in ["one", "two", "task", "done", "first", "second"] {
            let para = view.paragraphRange(at: ns.range(of: item).location)
            XCTAssertNotNil(view.marker(ofParagraph: para), item)
        }
        XCTAssertEqual(view.marker(ofParagraph: view.paragraphRange(at: ns.range(of: "task").location))?.kind, .checkbox(checked: false))
        XCTAssertEqual(view.marker(ofParagraph: view.paragraphRange(at: ns.range(of: "done").location))?.kind, .checkbox(checked: true))
        XCTAssertEqual(view.marker(ofParagraph: view.paragraphRange(at: ns.range(of: "second").location))?.kind, .numbered(2))
        XCTAssertFalse(view.string.contains("**"))
        XCTAssertFalse(view.string.contains("##"))
        XCTAssertTrue(EditorStyle.isBold(try XCTUnwrap(font(view, at: "bold"))))
        XCTAssertEqual(view.storage.attribute(.link, at: ns.range(of: "a link").location, effectiveRange: nil) as? URL,
                       URL(string: "https://example.com"))
        XCTAssertFalse(view.string.hasSuffix("\n"), "no trailing newline unless the source had one")
        XCTAssertEqual(view.selectedRange(), NSRange(location: view.storage.length, length: 0))
    }

    func testPasteMidParagraphKeepsTextAfterOnItsOwnLine() {
        let view = editor(body("Before after\nNext\n"), caret: 6)
        XCTAssertTrue(view.pasteMarkdown(from: pasteboard(plain: "# Big\n- item")))
        XCTAssertEqual(view.string, "Before\nBig\n\(EditorStyle.markerText(.bullet, level: 0))item\n after\nNext\n")
        XCTAssertEqual(kind(view, of: "Before"), .body)
        XCTAssertEqual(kind(view, of: "Big"), .title)
        XCTAssertEqual(kind(view, of: "after"), .body)
    }

    func testTitleLineKeepsItsStyle() {
        let text = NSMutableAttributedString(attributedString: EditorStyle.paragraph("My note", kind: .title))
        text.append(body("Body"))
        let view = editor(text, caret: 7)
        XCTAssertTrue(view.pasteMarkdown(from: pasteboard(plain: "## Section\n- a\n")))
        XCTAssertTrue(view.string.hasPrefix("My note\nSection\n"))
        XCTAssertEqual(kind(view, of: "My note"), .title)
        XCTAssertEqual(kind(view, of: "Section"), .heading)
        XCTAssertEqual(kind(view, of: "Body"), .body)
    }

    func testInlineFragmentMergesIntoParagraph() {
        let view = editor(body("Start  end\nNext\n"), caret: 6)
        XCTAssertTrue(view.pasteMarkdown(from: pasteboard(plain: "some **bold** and `code`")))
        XCTAssertEqual(view.string, "Start some bold and code end\nNext\n")
        XCTAssertEqual(kind(view, of: "Start"), .body)
        XCTAssertTrue(EditorStyle.isBold(try XCTUnwrap(font(view, at: "bold"))))
        XCTAssertFalse(EditorStyle.isBold(try XCTUnwrap(font(view, at: "some"))))
        let codeAttrs = view.storage.attributes(at: (view.string as NSString).range(of: "code").location, effectiveRange: nil)
        XCTAssertTrue(EditorStyle.isInlineCode(codeAttrs))
        XCTAssertEqual(view.selectedRange().location, ("Start some bold and code" as NSString).length)
    }

    func testRenderedHTMLIsNotConverted() {
        let pb = pasteboard()
        pb.setString("- one\n- two", forType: .string)
        pb.setData(Data("<ul><li><b>One</b> item</li><li>Two</li></ul>".utf8), forType: .html)
        let view = editor(body("Intro\n"))
        XCTAssertFalse(view.pasteMarkdown(from: pb))
        XCTAssertEqual(view.string, "Intro\n")
    }

    func testSyntaxColouredSourceIsConverted() throws {
        let source = "# Title\n- item **bold**\n"
        let colored = NSMutableAttributedString(string: source, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)])
        colored.addAttribute(.foregroundColor, value: NSColor.systemPink, range: NSRange(location: 0, length: 7))
        let pb = pasteboard()
        pb.setString(source, forType: .string)
        pb.setData(try XCTUnwrap(colored.rtf(from: NSRange(location: 0, length: colored.length))), forType: .rtf)
        let view = editor(body(""))
        XCTAssertTrue(view.pasteMarkdown(from: pb))
        XCTAssertEqual(kind(view, of: "Title"), .title)
        XCTAssertNotNil(view.marker(ofParagraph: view.paragraphRange(at: (view.string as NSString).range(of: "item").location)))
        XCTAssertTrue(view.string.hasSuffix("\n"))
    }

    func testWindowsLineEndingsAndTablesKeepTheLineAfter() {
        let view = editor(body("Intro"))
        XCTAssertTrue(view.pasteMarkdown(from: pasteboard(plain: "# Title\r\n")))
        XCTAssertTrue(view.string.hasSuffix("Title\n"))

        let table = editor(body(""))
        XCTAssertTrue(table.pasteMarkdown(from: pasteboard(plain: "| a | b |\n|---|---|\n| 1 | 2 |")))
        XCTAssertNil(table.tableBlock(at: table.storage.length))
        XCTAssertNotNil(table.tableBlock(at: (table.string as NSString).range(of: "2").location))
    }

    func testSelectionEndingInATableUsesTheNormalPaste() {
        let text = NSMutableAttributedString(attributedString: body("Intro\n"))
        text.append(MarkdownReader.attributedString(from: "| a | b |\n|---|---|\n| 1 | 2 |\n"))
        let view = editor(text)
        view.setSelectedRange(NSRange(location: 2, length: (view.string as NSString).range(of: "a").location + 1 - 2))
        XCTAssertFalse(view.pasteMarkdown(from: pasteboard(plain: "- x\n")))
    }

    func testOwnCopyRoundTrips() throws {
        let original = NSMutableAttributedString(attributedString: body("Use **stars** and "))
        original.append(NSAttributedString(string: "bold", attributes: [.font: NSFontManager.shared.convert(EditorStyle.bodyFont, toHaveTrait: .boldFontMask)]))
        original.append(body("\n- literal dash\n"))
        let source = editor(original)
        source.selectAll(nil)
        let pb = pasteboard()
        XCTAssertTrue(source.writeSelection(to: pb, types: source.writablePasteboardTypes))
        XCTAssertTrue(pb.types?.contains(NoteItTextView.ownCopyType) ?? false)

        let target = editor(body(""))
        XCTAssertFalse(target.pasteMarkdown(from: pb))
        XCTAssertTrue(target.readSelection(from: pb))
        XCTAssertEqual(target.string, source.string)
        XCTAssertTrue(EditorStyle.isBold(try XCTUnwrap(font(target, at: "bold"))))
    }

    func testPasteInsideCodeBlockStaysLiteral() {
        let text = NSMutableAttributedString(attributedString: body("Intro\n"))
        text.append(NSAttributedString(string: "let x = 1\n", attributes: EditorStyle.attributes(for: .code)))
        let caret = ("Intro\nlet x = 1" as NSString).length
        let view = editor(text, caret: caret)
        XCTAssertTrue(view.pasteMarkdown(from: pasteboard(plain: " // **not bold**\n# not a title")))
        XCTAssertTrue(view.string.contains("let x = 1 // **not bold**\n# not a title"))
        XCTAssertEqual(kind(view, of: "not bold"), .code)
        XCTAssertEqual(kind(view, of: "not a title"), .code)
    }

    func testImagesKeepTheirTextWithoutLoading() {
        let view = editor(body(""))
        XCTAssertTrue(view.pasteMarkdown(from: pasteboard(plain: "![Diagram](images/diagram.png)\n![Logo](https://example.com/logo.png)\n\n- x")))
        XCTAssertTrue(view.string.contains("Diagram"))
        let logo = (view.string as NSString).range(of: "Logo").location
        XCTAssertNotEqual(logo, NSNotFound)
        XCTAssertNotNil(view.storage.attribute(.link, at: logo, effectiveRange: nil))
        XCTAssertNil(view.storage.attribute(.attachment, at: 0, effectiveRange: nil))
    }

    func testOneUndoRemovesThePaste() {
        let view = editor(body("Intro\n"))
        let undo = view.undoManager
        EditorHarness.settle(undo)
        XCTAssertTrue(view.pasteMarkdown(from: pasteboard(plain: "1. a\n2. b\n\n## Heading")))
        EditorHarness.settle(undo)
        XCTAssertNotEqual(view.string, "Intro\n")
        undo?.undo()
        XCTAssertEqual(view.string, "Intro\n")
    }

    // MARK: ⇧⌘V

    func testPasteAsPlainTextUsesSurroundingStyle() {
        let view = editor(body("Start \n"), caret: 6)
        XCTAssertTrue(view.pastePlainText(from: pasteboard(plain: "# Heading **bold**")))
        XCTAssertEqual(view.string, "Start # Heading **bold**\n")
        let ns = view.string as NSString
        view.storage.enumerateAttribute(.font, in: NSRange(location: 0, length: ns.length - 1)) { value, _, _ in
            let font = value as? NSFont
            XCTAssertEqual(font?.pointSize, EditorStyle.bodyFont.pointSize)
            XCTAssertFalse(font.map(EditorStyle.isBold) ?? true)
        }
        XCTAssertEqual(kind(view, of: "Heading"), .body)
        XCTAssertEqual(view.selectedRange().location, ("Start # Heading **bold**" as NSString).length)
    }

    func testPasteAndMatchStyleMenuItemUsesShiftCommandV() {
        let menu = NSMenu(title: "Edit")
        let item = menu.addItem(withTitle: "Paste and Match Style", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "v")
        item.keyEquivalentModifierMask = [.command, .option, .shift]
        PasteAndMatchStyleShortcut.apply(to: menu)
        XCTAssertEqual(item.keyEquivalent, "v")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .shift])
        XCTAssertEqual(MenuShortcutRules.reservedName(for: MenuShortcut("v", [.command, .shift])), "Paste and Match Style")
    }
}
