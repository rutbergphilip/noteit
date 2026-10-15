import AppKit
import XCTest
@testable import NoteIt

@MainActor
final class CaptureFormatterTests: XCTestCase {
    private struct Para {
        var text: String
        var kind: BlockKind
        var range: NSRange
    }

    private func paragraphs(_ s: NSAttributedString) -> [Para] {
        let ns = s.string as NSString
        var result: [Para] = []
        var location = 0
        while location < ns.length {
            let range = ns.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(range)
            let text = ns.substring(with: range).trimmingCharacters(in: .newlines)
            let ps = s.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            let font = s.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            result.append(Para(text: text, kind: EditorStyle.blockKind(paragraphStyle: ps, font: font), range: range))
        }
        return result
    }

    private func capture(
        _ text: String = "Some selected text",
        app: String = "Safari",
        window: String? = nil,
        pageURL: String? = nil,
        pageTitle: String? = nil,
        documentURL: URL? = nil
    ) -> CapturedSelection {
        let source = CaptureSource(
            appName: app,
            bundleID: nil,
            windowTitle: window,
            pageURL: pageURL.flatMap { URL(string: $0) },
            pageTitle: pageTitle,
            documentURL: documentURL
        )
        return CapturedSelection(text: text, source: source)
    }

    private func links(in s: NSAttributedString) -> [(URL, String)] {
        var found: [(URL, String)] = []
        let full = NSRange(location: 0, length: s.length)
        s.enumerateAttribute(.link, in: full) { value, range, _ in
            guard let value else { return }
            let url = (value as? URL) ?? URL(string: "\(value)")!
            found.append((url, (s.string as NSString).substring(with: range)))
        }
        return found
    }

    private func lastLine(_ s: NSAttributedString) -> String {
        s.string.components(separatedBy: "\n").last ?? ""
    }

    // MARK: Title

    func testTitlePrefersPageTitle() {
        let c = capture(window: "Window", pageURL: "https://example.com", pageTitle: "  Page Title  ", documentURL: URL(fileURLWithPath: "/a/Doc.txt"))
        XCTAssertEqual(CaptureFormatter.title(for: c), "Page Title")
    }

    func testTitleFallsBackToWindowTitle() {
        let c = capture(app: "TextEdit", window: " Meeting notes ", pageTitle: "   ", documentURL: URL(fileURLWithPath: "/a/Doc.txt"))
        XCTAssertEqual(CaptureFormatter.title(for: c), "Meeting notes")
    }

    func testWindowTitleEqualToAppNameIsSkipped() {
        let c = capture("First line", app: "Mail", window: "mail")
        XCTAssertEqual(CaptureFormatter.title(for: c), "First line")
    }

    func testGenericUntitledWindowIsSkipped() {
        for window in ["Untitled", "untitled 3", "Untitled.txt"] {
            let c = capture(app: "TextEdit", window: window, documentURL: URL(fileURLWithPath: "/Documents/Report Q3.rtf"))
            XCTAssertEqual(CaptureFormatter.title(for: c), "Report Q3", window)
        }
    }

    func testTitleFallsBackToFirstNonBlankLine() {
        let c = capture("\n   \n  Hello \t  world  \nSecond line", app: "Terminal")
        XCTAssertEqual(CaptureFormatter.title(for: c), "Hello world")
    }

    func testTitleFallsBackToAppName() {
        let c = capture(" \n\t\n ", app: " Preview ")
        XCTAssertEqual(CaptureFormatter.title(for: c), "Captured from Preview")
    }

    func testLongTitleTruncatesAtWordBoundary() {
        let line = "The quick brown fox jumps over the lazy dog while the cat watches from a sunny windowsill"
        let title = CaptureFormatter.title(for: capture(line, app: "Notes"))
        XCTAssertLessThanOrEqual(title.count, 60)
        XCTAssertTrue(title.hasSuffix("…"))
        let words = title.dropLast().split(separator: " ").map(String.init)
        XCTAssertEqual(words.joined(separator: " "), line.split(separator: " ").prefix(words.count).joined(separator: " "))
        XCTAssertFalse(title.dropLast().hasSuffix(" "))
    }

    func testTitleOfExactlySixtyCharactersIsKept() {
        let line = String(repeating: "a", count: 60)
        XCTAssertEqual(CaptureFormatter.title(for: capture(line, app: "Notes")), line)
    }

    func testEmojiTitleTruncatesOnCharacterBoundaries() {
        let line = String(repeating: "👨‍👩‍👧", count: 80)
        let title = CaptureFormatter.title(for: capture(line, app: "Messages"))
        XCTAssertEqual(title.count, 60)
        XCTAssertEqual(title, String(repeating: "👨‍👩‍👧", count: 59) + "…")
    }

    func testCJKTitleTruncates() {
        let line = String(repeating: "漢字かな", count: 30)
        let title = CaptureFormatter.title(for: capture(line, app: "Notes"))
        XCTAssertEqual(title.count, 60)
        XCTAssertTrue(line.hasPrefix(String(title.dropLast())))
        XCTAssertTrue(title.hasSuffix("…"))
    }

    // MARK: Body

    func testSelectionBecomesQuoteParagraphs() {
        let body = CaptureFormatter.body(for: capture("Line one\n    indented\nLine three", app: "Notes"))
        let p = paragraphs(body)
        XCTAssertEqual(p.map(\.text), ["Line one", "    indented", "Line three", "", "From Notes"])
        XCTAssertEqual(p.map(\.kind), [.quote, .quote, .quote, .body, .body])
    }

    func testBlankLinesAreCollapsedAndTrimmed() {
        let text = "\n\n  \nA\n\nB\n\n\n\nC\n \n\t\n\n\nD\n\n\n"
        let p = paragraphs(CaptureFormatter.body(for: capture(text, app: "Notes")))
        XCTAssertEqual(Array(p.map(\.text).dropLast(2)), ["A", "", "B", "", "C", "", "D"])
        XCTAssertEqual(Array(p.map(\.kind).dropLast(2)), Array(repeating: .quote, count: 7))
    }

    func testTwoBlankLinesAreKept() {
        let p = paragraphs(CaptureFormatter.body(for: capture("A\n\n\nB", app: "Notes")))
        XCTAssertEqual(Array(p.map(\.text).dropLast(2)), ["A", "", "", "B"])
    }

    func testCarriageReturnsAreLineBreaks() {
        let p = paragraphs(CaptureFormatter.body(for: capture("A\r\nB\rC", app: "Notes")))
        XCTAssertEqual(Array(p.map(\.text).dropLast(2)), ["A", "B", "C"])
    }

    func testPageURLSourceLineLinksPageTitle() {
        let c = capture(app: "Safari", pageURL: "https://www.example.com/article", pageTitle: "An Article")
        let body = CaptureFormatter.body(for: c)
        XCTAssertEqual(lastLine(body), "From An Article in Safari")
        let found = links(in: body)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.0, URL(string: "https://www.example.com/article"))
        XCTAssertEqual(found.first?.1, "An Article")
        let p = paragraphs(body)
        XCTAssertEqual(p.last?.kind, .body)
    }

    func testPageURLWithoutTitleUsesHostWithoutWWW() {
        let c = capture(app: "Google Chrome", pageURL: "https://www.example.org/x?y=1")
        let body = CaptureFormatter.body(for: c)
        XCTAssertEqual(lastLine(body), "From example.org in Google Chrome")
        XCTAssertEqual(links(in: body).first?.1, "example.org")
        XCTAssertEqual(links(in: body).first?.0.absoluteString, "https://www.example.org/x?y=1")
    }

    func testDisallowedSchemesProduceNoLink() {
        for bad in ["javascript:alert(1)", "data:text/html,hi", "ftp://example.com/file", "mailto:a@b.c", "chrome://settings"] {
            let c = capture(app: "Safari", window: "Front", pageURL: bad, pageTitle: "Evil")
            let body = CaptureFormatter.body(for: c)
            XCTAssertTrue(links(in: body).isEmpty, bad)
            XCTAssertEqual(lastLine(body), "From Safari — Front", bad)
        }
    }

    func testDocumentURLSourceLineLinksFileName() {
        let file = URL(fileURLWithPath: "/Documents/Plan 2026.pages")
        let c = capture(app: "Pages", window: "Plan 2026.pages", documentURL: file)
        let body = CaptureFormatter.body(for: c)
        XCTAssertEqual(lastLine(body), "From Plan 2026.pages in Pages")
        let found = links(in: body)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.0, file)
        XCTAssertTrue(found.first?.0.isFileURL ?? false)
        XCTAssertEqual(found.first?.1, "Plan 2026.pages")
    }

    func testNoURLSourceLineIncludesWindowTitleWhenNotTheNoteTitle() {
        let c = capture("Body text", app: "Terminal", window: "zsh — 80×24")
        XCTAssertEqual(CaptureFormatter.title(for: c), "zsh — 80×24")
        XCTAssertEqual(lastLine(CaptureFormatter.body(for: c)), "From Terminal")

        let other = capture("Body text", app: "Terminal", window: "Terminal")
        XCTAssertEqual(lastLine(CaptureFormatter.body(for: other)), "From Terminal")

        let untitled = capture("Body text", app: "TextEdit", window: "Untitled")
        XCTAssertEqual(lastLine(CaptureFormatter.body(for: untitled)), "From TextEdit — Untitled")
        XCTAssertTrue(links(in: CaptureFormatter.body(for: untitled)).isEmpty)
    }

    func testSourceLineLinkRangeIsExact() {
        let c = capture(app: "Arc", pageURL: "https://example.com", pageTitle: "Title")
        let body = CaptureFormatter.body(for: c)
        let ns = body.string as NSString
        let expected = ns.range(of: "Title", options: .backwards)
        var range = NSRange()
        let value = body.attribute(.link, at: expected.location, effectiveRange: &range)
        XCTAssertEqual(value as? URL, URL(string: "https://example.com"))
        XCTAssertEqual(range, expected)
    }

    func testVeryLongSelectionIsTruncated() {
        let line = String(repeating: "x", count: 99) + "\n"
        let text = String(repeating: line, count: 3_000)
        let body = CaptureFormatter.body(for: capture(text, app: "Notes"))
        let p = paragraphs(body)
        let quotes = p.filter { $0.kind == .quote }
        XCTAssertEqual(quotes.last?.text, "…")
        XCTAssertLessThan(body.length, text.utf16.count)
        XCTAssertEqual(quotes.dropLast().reduce(0) { $0 + $1.text.count + 1 }, 200_000)
    }

    // MARK: Title normalization

    private func assertSingleParagraphSourceLine(_ body: NSAttributedString, _ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        let p = paragraphs(body)
        XCTAssertEqual(p.last?.text, expected, file: file, line: line)
        XCTAssertEqual(p.last?.kind, .body, file: file, line: line)
        XCTAssertEqual(p.dropLast().last?.text, "", file: file, line: line)
        XCTAssertFalse(body.string.hasSuffix("\n"), file: file, line: line)
    }

    private func assertSingleParagraphTitle(_ c: CapturedSelection, file: StaticString = #filePath, line: UInt = #line) {
        let title = CaptureFormatter.title(for: c)
        let content = CaptureFormatter.noteContent(for: c)
        let first = paragraphs(content).first?.text
        XCTAssertEqual(first, title, file: file, line: line)
        XCTAssertEqual(paragraphs(content).count, paragraphs(CaptureFormatter.body(for: c)).count + 1, file: file, line: line)
    }

    func testLongPageTitleIsTruncated() {
        let pageTitle = String(repeating: "Breaking news about something ", count: 7)
        let c = capture(app: "Safari", pageURL: "https://example.com", pageTitle: pageTitle)
        let title = CaptureFormatter.title(for: c)
        XCTAssertLessThanOrEqual(title.count, 60)
        XCTAssertTrue(title.hasPrefix("Breaking news about something Breaking"))
        XCTAssertTrue(title.hasSuffix("…"))
        assertSingleParagraphTitle(c)
    }

    func testMultiLinePageTitleIsCollapsed() {
        let c = capture(app: "Safari", pageURL: "https://example.com/a", pageTitle: " headline \nsecond\u{2028}third\u{2029}\tfourth ")
        XCTAssertEqual(CaptureFormatter.title(for: c), "headline second third fourth")
        assertSingleParagraphTitle(c)
        let body = CaptureFormatter.body(for: c)
        assertSingleParagraphSourceLine(body, "From headline second third fourth in Safari")
        XCTAssertEqual(links(in: body).first?.1, "headline second third fourth")
        XCTAssertEqual(links(in: body).first?.0, URL(string: "https://example.com/a"))
    }

    func testLongPageTitleIsKeptWholeInSourceLine() {
        let pageTitle = String(repeating: "word ", count: 30) + "\nend"
        let c = capture(app: "Safari", pageURL: "https://example.com", pageTitle: pageTitle)
        let expected = String(repeating: "word ", count: 30) + "end"
        assertSingleParagraphSourceLine(CaptureFormatter.body(for: c), "From \(expected) in Safari")
    }

    func testMultiLineAndLongWindowTitle() {
        let multi = capture("Body", app: "TextEdit", window: "Draft\r\n  plan\u{2029}v2")
        XCTAssertEqual(CaptureFormatter.title(for: multi), "Draft plan v2")
        assertSingleParagraphTitle(multi)
        assertSingleParagraphSourceLine(CaptureFormatter.body(for: multi), "From TextEdit")

        let window = String(repeating: "Quarterly planning ", count: 8)
        let long = capture("Body", app: "Keynote", window: window)
        let title = CaptureFormatter.title(for: long)
        XCTAssertLessThanOrEqual(title.count, 60)
        XCTAssertTrue(title.hasSuffix("…"))
        assertSingleParagraphTitle(long)
        assertSingleParagraphSourceLine(CaptureFormatter.body(for: long), "From Keynote")
    }

    func testWindowTitleInSourceLineIsCollapsed() {
        let c = capture("Body", app: "Safari", window: "Reader\n  view", pageURL: "javascript:void(0)", pageTitle: "Article")
        assertSingleParagraphSourceLine(CaptureFormatter.body(for: c), "From Safari — Reader view")
    }

    func testMultiLineAndLongDocumentName() {
        let multi = URL(fileURLWithPath: "/Documents/Line one\nLine two.txt")
        let c = capture("Body", app: "TextEdit", window: "Untitled", documentURL: multi)
        XCTAssertEqual(CaptureFormatter.title(for: c), "Line one Line two")
        assertSingleParagraphTitle(c)
        let body = CaptureFormatter.body(for: c)
        assertSingleParagraphSourceLine(body, "From Line one Line two.txt in TextEdit")
        XCTAssertEqual(links(in: body).first?.0, multi)

        let name = String(repeating: "report ", count: 15) + "final"
        let long = capture("Body", app: "Pages", documentURL: URL(fileURLWithPath: "/Documents/\(name).pages"))
        let title = CaptureFormatter.title(for: long)
        XCTAssertLessThanOrEqual(title.count, 60)
        XCTAssertTrue(title.hasSuffix("…"))
        assertSingleParagraphSourceLine(CaptureFormatter.body(for: long), "From \(name).pages in Pages")
    }

    func testAppNameIsCollapsedInSourceLine() {
        let c = capture("Body", app: " Some\nApp ", pageURL: "https://example.com", pageTitle: "Page")
        assertSingleParagraphSourceLine(CaptureFormatter.body(for: c), "From Page in Some App")
    }

    func testTitleOnlyInspectsBoundedPrefix() {
        let late = capture("Short\n" + String(repeating: " \n", count: 3_000) + "Too late", app: "Notes")
        XCTAssertEqual(CaptureFormatter.title(for: late), "Short")

        let huge = capture("Heading\n" + String(repeating: "x", count: 20_000_000), app: "Notes")
        let start = Date()
        XCTAssertEqual(CaptureFormatter.title(for: huge), "Heading")
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.25)
    }

    func testLeadingWhitespaceBeyondScanLimitIsSkipped() {
        let padding = String(repeating: " \n\t\u{2028}", count: 3_000)
        let c = capture(padding + "  Late   heading \nmore", app: "Notes")
        XCTAssertEqual(CaptureFormatter.title(for: c), "Late heading")

        let blank = capture(String(repeating: " \n", count: 5_000), app: "Notes")
        XCTAssertEqual(CaptureFormatter.title(for: blank), "Captured from Notes")
    }

    // MARK: Note content

    func testNoteContentTitleLineMatchesCapturedText() {
        let c = capture("Quoted", app: "Safari", pageURL: "https://example.com", pageTitle: "Example Page")
        let content = CaptureFormatter.noteContent(for: c)
        let reference = NoteStore.capturedText(title: "Example Page", body: "Body")
        XCTAssertTrue(content.string.hasPrefix("Example Page\nQuoted\n"))

        var contentRange = NSRange()
        var referenceRange = NSRange()
        let contentAttrs = content.attributes(at: 0, effectiveRange: &contentRange)
        let referenceAttrs = reference.attributes(at: 0, effectiveRange: &referenceRange)
        XCTAssertEqual(contentRange, referenceRange)
        XCTAssertEqual(NSDictionary(dictionary: contentAttrs), NSDictionary(dictionary: referenceAttrs))

        let newline = ("Example Page" as NSString).length
        XCTAssertEqual(
            NSDictionary(dictionary: content.attributes(at: newline, effectiveRange: nil)),
            NSDictionary(dictionary: reference.attributes(at: newline, effectiveRange: nil))
        )

        let body = CaptureFormatter.body(for: c)
        XCTAssertEqual(content.attributedSubstring(from: NSRange(location: 13, length: body.length)), body)
    }

    func testPlainCapturedTextIsUnchanged() {
        let size = CGFloat(UserDefaults.standard.object(forKey: PrefKey.editorFontSize) as? Double ?? PrefDefault.editorFontSize)
        let text = NoteStore.capturedText(title: "T", body: "B")
        XCTAssertEqual(text.string, "T\nB")
        XCTAssertEqual(text.attribute(.font, at: 2, effectiveRange: nil) as? NSFont, NSFont.systemFont(ofSize: size))
        XCTAssertEqual(text.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor, NSColor.labelColor)
        XCTAssertEqual(NoteStore.capturedText(title: "T", body: "").string, "T")
        XCTAssertEqual(NoteStore.capturedText(title: "", body: "B").string, "B")
    }
}
