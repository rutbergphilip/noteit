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
        for text in ["- one\n- two", "* a\n* b", "+ a\n+ b", "1. first\n2. second",
                     "> quoted", "- [ ] task", "- [x] done", "```\ncode\n```", "```swift\nlet x = 1;\n```",
                     "| a | b |\n|---|---|\n| 1 | 2 |", "some **bold** text", "(**bold**)",
                     "see [the docs](https://example.com)", "# Groceries\n- milk\n- eggs\n", "# Title\n> quoted"] {
            XCTAssertTrue(MarkdownPasteDetector.looksLikeMarkdown(text), text)
        }
    }

    func testIgnoresOrdinaryText() {
        for text in ["https://example.com/some_path/__init__?q=*", "important*", "*", "2*3*4",
                     "Plain prose, with punctuation - and a dash.", "#hashtag and #another", "a**2 + b**2",
                     "Price: 5 * 3", "x | y", "Dear team,\n\nThanks for the update.\nBest", "- item", "* item",
                     "some *emphasis* here", "snake_case and _this_", "-  wide\n-  dash", "# Title", "## Notes\nSome text"] {
            XCTAssertFalse(MarkdownPasteDetector.looksLikeMarkdown(text), text)
        }
    }

    func testCodeAndDiffsStayPlain() {
        let python = """
        class Greeter:
            def __init__(self, name):
                self.name = name

            def greet(self):
                return f"Hello {self.name}"
        """
        let diff = """
        diff --git a/main.swift b/main.swift
        --- a/main.swift
        +++ b/main.swift
        @@ -1,3 +1,3 @@
         func f() {
        -    let x = 1
        +    let x = 2
         }
        """
        let hunk = "-    let x = 1\n+    let x = 2\n+    let y = **x**"
        let docComment = """
        /**
         * Adds two numbers.
         * @param a first
         * @param b second
         */
        function add(a, b) {
          return a + b;
        }
        """
        let commentOnly = "/**\n * @param x the value\n * @returns the result\n */"
        for text in [python, diff, hunk, docComment, commentOnly, "if __name__ == \"__main__\":", "call **opts**(x)",
                     "# Notes\nimport os\nfrom x import y\nx = 1"] {
            XCTAssertFalse(MarkdownPasteDetector.looksLikeMarkdown(text), text)
        }
        let view = editor(body(""))
        XCTAssertFalse(view.pasteMarkdown(from: pasteboard(plain: python)))
        XCTAssertFalse(view.pasteMarkdown(from: pasteboard(plain: "- item")))
    }

    func testShellAndConfigCommentsStayPlain() {
        let gitignore = "# Build output\nbuild/\n*.log\n\n# macOS\n.DS_Store\n"
        let shell = "# install deps\nbrew install node\nnpm ci\n"
        let compose = "# Services\nservices:\n  web:\n    image: nginx\n    ports:\n      - \"80:80\"\n      - \"443:443\"\n"
        let env = "# Settings\n- staging\n- production\nAPI_URL=https://example.com\nDEBUG=1\nLOG_LEVEL=info\n"
        for text in [gitignore, shell, compose, env] {
            XCTAssertFalse(MarkdownPasteDetector.looksLikeMarkdown(text), text)
        }
        XCTAssertFalse(editor(body("")).pasteMarkdown(from: pasteboard(plain: compose)))
    }

    func testYAMLListsOfMapsStayPlain() {
        let actions = "steps:\n  - uses: actions/checkout@v4\n  - name: Build\n    run: make\n"
        let ansible = "- name: Install\n  apt: name=nginx\n- name: Start\n  service: name=nginx state=started\n"
        let containers = "containers:\n  - name: x\n    image: y\n"
        let env = "env:\n  - name: A\n    value: b\n"
        for text in [actions, ansible, containers, env] {
            XCTAssertFalse(MarkdownPasteDetector.looksLikeMarkdown(text), text)
        }
        let meeting = "Attendees: Ann, Bo\n- Agenda item one\n- Agenda item two\n"
        let shopping = "- Milk: 2 litres\n- Bread: one loaf\n- Eggs\n"
        let lowercase = "- milk: 2 litres\n- bread: one loaf\n- eggs\n"
        let changelog = "- fix: login bug\n  - repro: open app\n  - cause: token expiry\n- feat: dark mode\n  - note: needs design\n"
        let todo = "- todo: groceries\n  - milk: 2 litres\n  - bread: one loaf\n"
        for text in [meeting, shopping, lowercase, changelog, todo] {
            XCTAssertTrue(MarkdownPasteDetector.looksLikeMarkdown(text), text)
        }
    }

    func testEverydayMarkdownStillConverts() throws {
        let readme = "## Install\n\nRun this in the project folder:\n\n```sh\nnpm ci\n```\n"
        let answer = "**Short answer:** yes, it works.\n\n1. Open the settings.\n2. Turn it on.\n\n### Why\nIt saves time.\n"
        let checklist = "- [ ] milk\n- [x] eggs\n"
        for text in [readme, answer, checklist] {
            XCTAssertTrue(MarkdownPasteDetector.looksLikeMarkdown(text), text)
        }
        let view = editor(body(""))
        XCTAssertTrue(view.pasteMarkdown(from: pasteboard(plain: answer)))
        XCTAssertEqual(kind(view, of: "Why"), .subheading)
        XCTAssertTrue(EditorStyle.isBold(try XCTUnwrap(font(view, at: "Short answer"))))
    }

    func testIndentedLabelsUnderListItemsAreNotConfig() throws {
        let answer = "1. **Option A**\n   Pros: fast\n   Cons: costly\n2. **Option B**\n   Pros: cheap\n   Cons: slow\nPick A if speed matters.\n"
        XCTAssertTrue(MarkdownPasteDetector.looksLikeMarkdown(answer))
        let view = editor(body(""))
        XCTAssertTrue(view.pasteMarkdown(from: pasteboard(plain: answer)))
        XCTAssertTrue(EditorStyle.isBold(try XCTUnwrap(font(view, at: "Option B"))))
        XCTAssertFalse(view.string.contains("**"))
    }

    func testFrontMatterStaysVerbatimAboveConvertedBody() throws {
        let frontMatter = "---\ntitle: Trip\ntags: travel\ncreated: 2026-10-01\n---"
        let note = frontMatter + "\n## Packing\n- passport\n- charger\n\nBook the **train** early.\n"
        XCTAssertTrue(MarkdownPasteDetector.looksLikeMarkdown(note))
        XCTAssertFalse(MarkdownPasteDetector.looksLikeMarkdown(frontMatter + "\nJust a sentence.\n"))
        let view = editor(body(""))
        XCTAssertTrue(view.pasteMarkdown(from: pasteboard(plain: note)))
        XCTAssertTrue(view.string.hasPrefix(frontMatter + "\n"), view.string)
        for line in ["title: Trip", "tags: travel", "created: 2026-10-01"] {
            XCTAssertEqual(kind(view, of: line), .body, line)
        }
        let ns = view.string as NSString
        XCTAssertEqual(view.blockKind(ofParagraph: view.paragraphRange(at: 0)), .body)
        XCTAssertEqual(view.blockKind(ofParagraph: view.paragraphRange(at: ns.range(of: "---\n## ").location)), .body)
        XCTAssertEqual(kind(view, of: "Packing"), .heading)
        XCTAssertNotNil(view.marker(ofParagraph: view.paragraphRange(at: ns.range(of: "charger").location)))
        XCTAssertTrue(EditorStyle.isBold(try XCTUnwrap(font(view, at: "train"))))
        XCTAssertFalse(view.string.contains("**"))
    }

    func testFrontMatterKeysMayHaveSpacesAccentsAndQuotes() {
        func count(_ text: String) -> Int { MarkdownPasteDetector.frontMatterLineCount(MarkdownReader.lines(of: text)) }
        for line in ["Date created: 2024-01-01", "ämne: möte", "Time: 10:30", "\"x y\": z", "'x': z", "done:"] {
            XCTAssertEqual(count("---\n\(line)\n---\nBody\n"), 3, line)
        }
        for line in ["_x: y", "[link]: y", "> quote: y", "See https://example.com: y"] {
            XCTAssertEqual(count("---\n\(line)\n---\nBody\n"), 0, line)
        }

        let frontMatter = "---\nDate created: 2024-01-01\nämne: möte\nTime: 10:30\n---"
        let view = editor(body(""))
        XCTAssertTrue(view.pasteMarkdown(from: pasteboard(plain: frontMatter + "\n## Notes\n- a\n- b\n")))
        XCTAssertTrue(view.string.hasPrefix(frontMatter + "\n"), view.string)
        XCTAssertEqual(kind(view, of: "ämne: möte"), .body)
        XCTAssertEqual(kind(view, of: "Notes"), .heading)
    }

    func testFrontMatterNeedsYAMLKeyLines() {
        func count(_ text: String) -> Int { MarkdownPasteDetector.frontMatterLineCount(MarkdownReader.lines(of: text)) }
        for line in ["See https://example.com for details", "**Note:** x", "  indented: first", "- item"] {
            XCTAssertEqual(count("---\n\(line)\n---\nBody\n"), 0, line)
        }
        XCTAssertEqual(count("---\ntitle: x\ntags: [a, b]\n# comment\n\naliases:\n  - y\n- z\n---\nBody\n"), 9)

        let note = "---\nSee https://example.com for details\n---\n## Next\n- a\n- b\n"
        XCTAssertTrue(MarkdownPasteDetector.looksLikeMarkdown(note))
        let view = editor(body(""))
        XCTAssertTrue(view.pasteMarkdown(from: pasteboard(plain: note)))
        XCTAssertEqual(kind(view, of: "Next"), .heading)
        XCTAssertNotNil(view.marker(ofParagraph: view.paragraphRange(at: (view.string as NSString).range(of: "b", options: .backwards).location)))
    }

    func testPathologicalInputsAreFast() {
        let n = 100_000
        let inputs = [
            String(repeating: "a", count: n) + " ",
            String(repeating: "ab-", count: n / 3) + "(x",
            String(repeating: "*_[(`|#", count: n / 7),
            String(repeating: "**a ", count: n / 4),
            String(repeating: "[", count: n) + "](x",
            String(repeating: "|", count: n) + "\n|-|-x",
            String(repeating: " ", count: n) + "-",
            String(repeating: "a:", count: n / 2) + "//",
            String(repeating: "**x\n", count: n / 4),
            String(repeating: "  k: v\n", count: n / 7),
        ]
        for input in inputs {
            let start = Date()
            _ = MarkdownPasteDetector.looksLikeMarkdown(input)
            XCTAssertLessThan(Date().timeIntervalSince(start), 0.5, String(input.prefix(12)))
        }
        XCTAssertFalse(MarkdownPasteDetector.looksLikeMarkdown(String(repeating: "- item\n", count: 30_000)))
    }

    func testVeryLongLinePastesWithoutConversion() {
        let longLine = String(repeating: "*_[(`|#", count: 100_000 / 7)
        let text = "- one\n- two\n" + longLine
        let view = editor(body(""))
        let start = Date()
        XCTAssertFalse(view.pasteMarkdown(from: pasteboard(plain: text)))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        XCTAssertEqual(view.string, "")

        let paragraph = String(repeating: "word ", count: 800)
        let markdown = "## Notes\n- one\n- two\n\n" + paragraph + "\n"
        let converted = editor(body(""))
        XCTAssertTrue(converted.pasteMarkdown(from: pasteboard(plain: markdown)))
        XCTAssertEqual(kind(converted, of: "Notes"), .heading)
        XCTAssertTrue(converted.string.contains(paragraph.trimmingCharacters(in: .whitespaces)))
    }

    func testNoteWithHeadingAndListConverts() {
        let view = editor(body(""))
        XCTAssertTrue(view.pasteMarkdown(from: pasteboard(plain: "## Groceries\n- milk\n- eggs\n")))
        XCTAssertEqual(kind(view, of: "Groceries"), .heading)
        XCTAssertNotNil(view.marker(ofParagraph: view.paragraphRange(at: (view.string as NSString).range(of: "eggs").location)))
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
        XCTAssertTrue(view.pasteMarkdown(from: pasteboard(plain: "# Big\n- item\n- more")))
        let bullet = EditorStyle.markerText(.bullet, level: 0)
        XCTAssertEqual(view.string, "Before\nBig\n\(bullet)item\n\(bullet)more\n after\nNext\n")
        XCTAssertEqual(kind(view, of: "Before"), .body)
        XCTAssertEqual(kind(view, of: "Big"), .title)
        XCTAssertEqual(kind(view, of: "after"), .body)
    }

    func testTitleLineKeepsItsStyle() {
        let text = NSMutableAttributedString(attributedString: EditorStyle.paragraph("My note", kind: .title))
        text.append(body("Body"))
        let view = editor(text, caret: 7)
        XCTAssertTrue(view.pasteMarkdown(from: pasteboard(plain: "## Section\n- a\n- b\n")))
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

    private func rtfPasteboard(_ text: NSAttributedString) throws -> NSPasteboard {
        let pb = pasteboard()
        pb.setString(text.string, forType: .string)
        pb.setData(try XCTUnwrap(text.rtf(from: NSRange(location: 0, length: text.length))), forType: .rtf)
        return pb
    }

    func testRichTextWithMeaningIsNotConverted() throws {
        let source = "1. Read the [docs](https://example.com)\n2. Ship **it**\n"
        let plainFont = NSFont(name: "Helvetica", size: 12)!
        let linked = NSMutableAttributedString(string: source, attributes: [.font: plainFont])
        linked.addAttribute(.link, value: URL(string: "https://example.com")!, range: (source as NSString).range(of: "docs"))
        XCTAssertFalse(editor(body("")).pasteMarkdown(from: try rtfPasteboard(linked)))

        let bold = NSMutableAttributedString(string: source, attributes: [.font: plainFont])
        bold.addAttribute(.font, value: NSFont(name: "Helvetica-Bold", size: 12)!, range: (source as NSString).range(of: "it"))
        XCTAssertFalse(editor(body("")).pasteMarkdown(from: try rtfPasteboard(bold)), "bold in a proportional font is formatting")

        let mono = NSFont(name: "Menlo-Regular", size: 12)!
        let syntaxBold = NSMutableAttributedString(string: source, attributes: [.font: mono])
        syntaxBold.addAttribute(.font, value: NSFont(name: "Menlo-Bold", size: 12)!, range: (source as NSString).range(of: "it"))
        syntaxBold.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: (source as NSString).range(of: "docs"))
        XCTAssertTrue(editor(body("")).pasteMarkdown(from: try rtfPasteboard(syntaxBold)), "bold in a code font is syntax colouring")

        let monoStruck = NSMutableAttributedString(string: source, attributes: [.font: mono])
        monoStruck.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: 4))
        XCTAssertFalse(editor(body("")).pasteMarkdown(from: try rtfPasteboard(monoStruck)))

        let monoLinked = NSMutableAttributedString(string: source, attributes: [.font: mono])
        monoLinked.addAttribute(.link, value: URL(string: "https://example.com")!, range: (source as NSString).range(of: "docs"))
        XCTAssertFalse(editor(body("")).pasteMarkdown(from: try rtfPasteboard(monoLinked)))

        let monoMixed = NSMutableAttributedString(string: source, attributes: [.font: mono])
        monoMixed.addAttribute(.font, value: NSFont(name: "Courier-Bold", size: 12)!, range: (source as NSString).range(of: "it"))
        XCTAssertFalse(editor(body("")).pasteMarkdown(from: try rtfPasteboard(monoMixed)))

        let underlined = NSMutableAttributedString(string: source, attributes: [.font: plainFont])
        underlined.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: 4))
        XCTAssertFalse(editor(body("")).pasteMarkdown(from: try rtfPasteboard(underlined)))

        let mixed = NSMutableAttributedString(string: source, attributes: [.font: plainFont])
        mixed.addAttribute(.font, value: NSFont(name: "Times-Roman", size: 12)!, range: NSRange(location: 0, length: 4))
        XCTAssertFalse(editor(body("")).pasteMarkdown(from: try rtfPasteboard(mixed)))
    }

    func testSourceCopiedFromVSCodeIsConverted() {
        let source = "# Heading\n- item one\n- item **two**\n"
        let html = """
        <meta charset='utf-8'><div style="color: #d4d4d4;background-color: #1e1e1e;font-family: Menlo, Monaco, 'Courier New', monospace;\
        font-weight: normal;font-size: 12px;line-height: 18px;white-space: pre;">\
        <div><span style="color: #569cd6;font-weight: bold;"># Heading</span></div>\
        <div><span style="color: #d4d4d4;">- item one</span></div>\
        <div><span style="color: #d4d4d4;">- item </span><span style="color: #569cd6;font-weight: bold;">**two**</span></div>\
        </div>
        """
        let pb = pasteboard()
        pb.setString(source, forType: .string)
        pb.setData(Data(html.utf8), forType: .html)
        let view = editor(body(""))
        XCTAssertTrue(view.pasteMarkdown(from: pb))
        XCTAssertEqual(kind(view, of: "Heading"), .title)
        XCTAssertFalse(view.string.contains("**"))
    }

    func testWindowsLineEndingsAndTablesKeepTheLineAfter() {
        let view = editor(body("Intro"))
        XCTAssertTrue(view.pasteMarkdown(from: pasteboard(plain: "# Title\r\n> quote\r\n")))
        XCTAssertTrue(view.string.hasSuffix("quote\n"))

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
        XCTAssertFalse(view.pasteMarkdown(from: pasteboard(plain: "- x\n- y\n")))
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
        XCTAssertEqual(MenuShortcutRules.evaluate(PasteAndMatchStyleShortcut.shortcut, for: .find, store: shortcutStore(),
                                                  keyCombo: nil, globalBindings: [:]),
                       .reject("⇧⌘V is already used for “Paste and Match Style”."))
    }

    private func shortcutStore() -> MenuShortcutStore {
        let suite = "noteit-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return MenuShortcutStore(defaults: defaults)
    }

    private func keyEvent(_ modifiers: NSEvent.ModifierFlags, window: NSWindow?) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                         windowNumber: window?.windowNumber ?? 0, context: nil, characters: "v",
                         charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9)!
    }

    func testUsersOwnShiftCommandVWins() {
        let shiftCommandV = PasteAndMatchStyleShortcut.shortcut
        PasteAndMatchStyleShortcut.update(overrides: [.find: .shortcut(shiftCommandV)], globalBindings: [:])
        defer { PasteAndMatchStyleShortcut.update(overrides: [:], globalBindings: [:]) }

        let menu = NSMenu(title: "Edit")
        let item = menu.addItem(withTitle: "Paste and Match Style", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "v")
        item.keyEquivalentModifierMask = [.command, .shift]
        PasteAndMatchStyleShortcut.apply(to: menu)
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .option, .shift])

        let view = editor(body("Start "))
        view.window?.makeFirstResponder(view)
        XCTAssertFalse(view.performKeyEquivalent(with: keyEvent([.command, .shift], window: view.window)))
        XCTAssertTrue(NoteItTextView.isPasteAndMatchStyle(keyEvent([.command, .shift, .option], window: view.window)))

        let store = shortcutStore()
        store.set(shiftCommandV, for: .find)
        XCTAssertEqual(MenuShortcutRules.evaluate(shiftCommandV, for: .find, store: store, keyCombo: nil, globalBindings: [:]),
                       .accept(warning: nil))

        let combo = KeyCombo(keyCode: 9, modifiers: KeyCombo.carbonModifiers(from: [.command, .shift]))
        PasteAndMatchStyleShortcut.update(overrides: [:], globalBindings: [.newNote: combo])
        XCTAssertFalse(PasteAndMatchStyleShortcut.holdsShiftCommandV)
        PasteAndMatchStyleShortcut.update(overrides: [:], globalBindings: [:])
        XCTAssertTrue(PasteAndMatchStyleShortcut.holdsShiftCommandV)
    }
}
