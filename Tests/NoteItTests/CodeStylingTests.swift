import AppKit
import XCTest
@testable import NoteIt

@MainActor
final class CodeStylingTests: XCTestCase {
    // MARK: Tokenizer

    private func tokens(_ text: String, _ language: CodeLanguage) -> [(String, TokenKind)] {
        let ns = text as NSString
        return SyntaxHighlighter.tokenize(text, language: language).map { (ns.substring(with: $0.range), $0.kind) }
    }

    private func kind(of snippet: String, in text: String, _ language: CodeLanguage, file: StaticString = #filePath, line: UInt = #line) -> TokenKind? {
        let found = tokens(text, language).first { $0.0 == snippet }
        XCTAssertNotNil(found, "no token \(snippet) in \(tokens(text, language))", file: file, line: line)
        return found?.1
    }

    func testCStyleFamily() {
        let swift = """
        // note
        let s = "hi \\"there\\""
        /* block
        comment */ var n = 42
        """
        XCTAssertEqual(kind(of: "// note", in: swift, .swift), .comment)
        XCTAssertEqual(kind(of: "let", in: swift, .swift), .keyword)
        XCTAssertEqual(kind(of: "\"hi \\\"there\\\"\"", in: swift, .swift), .string)
        XCTAssertEqual(kind(of: "/* block\ncomment */", in: swift, .swift), .comment)
        XCTAssertEqual(kind(of: "42", in: swift, .swift), .number)

        let js = "const x = 'a' + `b ${y}`; // done\nfunction f() { return 0x1F }"
        XCTAssertEqual(kind(of: "const", in: js, .javascript), .keyword)
        XCTAssertEqual(kind(of: "'a'", in: js, .javascript), .string)
        XCTAssertEqual(kind(of: "// done", in: js, .javascript), .comment)
        XCTAssertEqual(kind(of: "0x1F", in: js, .javascript), .number)
        XCTAssertEqual(kind(of: "function", in: js, .javascript), .keyword)

        let go = "func main() { s := \"x\"; n := 3.5 } // end"
        XCTAssertEqual(kind(of: "func", in: go, .go), .keyword)
        XCTAssertEqual(kind(of: "3.5", in: go, .go), .number)
        XCTAssertEqual(kind(of: "// end", in: go, .go), .comment)

        let rust = "fn main() { let v: Vec<u8> = Vec::new(); } // r"
        XCTAssertEqual(kind(of: "fn", in: rust, .rust), .keyword)
        XCTAssertEqual(kind(of: "Vec", in: rust, .rust), .type)
    }

    func testHashCommentFamily() {
        let py = "# comment\ndef f(x):\n    return \"\"\"multi\nline\"\"\" + 'a' * 10"
        XCTAssertEqual(kind(of: "# comment", in: py, .python), .comment)
        XCTAssertEqual(kind(of: "def", in: py, .python), .keyword)
        XCTAssertEqual(kind(of: "\"\"\"multi\nline\"\"\"", in: py, .python), .string)
        XCTAssertEqual(kind(of: "10", in: py, .python), .number)

        let sh = "# setup\nif [ -f \"$f\" ]; then echo 'ok'; fi"
        XCTAssertEqual(kind(of: "# setup", in: sh, .bash), .comment)
        XCTAssertEqual(kind(of: "if", in: sh, .bash), .keyword)
        XCTAssertEqual(kind(of: "'ok'", in: sh, .bash), .string)

        let rb = "# hi\nclass Foo; def bar; 'x'; end; end"
        XCTAssertEqual(kind(of: "class", in: rb, .ruby), .keyword)
        XCTAssertEqual(kind(of: "Foo", in: rb, .ruby), .type)
    }

    func testDataAndMarkupFamilies() {
        let json = "{\"name\": \"NoteIt\", \"count\": 3, \"ok\": true}"
        XCTAssertEqual(kind(of: "\"name\"", in: json, .json), .property)
        XCTAssertEqual(kind(of: "\"NoteIt\"", in: json, .json), .string)
        XCTAssertEqual(kind(of: "3", in: json, .json), .number)
        XCTAssertEqual(kind(of: "true", in: json, .json), .keyword)

        let yaml = "# config\nname: NoteIt\nport: 8080\n"
        XCTAssertEqual(kind(of: "# config", in: yaml, .yaml), .comment)
        XCTAssertEqual(kind(of: "name", in: yaml, .yaml), .property)
        XCTAssertEqual(kind(of: "8080", in: yaml, .yaml), .number)

        let html = "<!-- c --><a href=\"x\">Hi</a>"
        XCTAssertEqual(kind(of: "<!-- c -->", in: html, .html), .comment)
        XCTAssertEqual(kind(of: "\"x\"", in: html, .html), .string)

        let sql = "SELECT * FROM notes WHERE id = 7 -- one\n"
        XCTAssertEqual(kind(of: "SELECT", in: sql, .sql), .keyword)
        XCTAssertEqual(kind(of: "7", in: sql, .sql), .number)
        XCTAssertEqual(kind(of: "-- one", in: sql, .sql), .comment)

        let css = "/* c */ .a { color: #fff; margin: 4px; }"
        XCTAssertEqual(kind(of: "/* c */", in: css, .css), .comment)
    }

    func testTokensStayInBoundsAndOrdered() {
        for language in CodeLanguage.allCases {
            let text = "\"unterminated /* x\n'q 12 <a b=\"c\n# z"
            var last = 0
            for token in SyntaxHighlighter.tokenize(text, language: language) {
                XCTAssertGreaterThanOrEqual(token.range.location, last, "\(language)")
                XCTAssertLessThanOrEqual(NSMaxRange(token.range), (text as NSString).length, "\(language)")
                last = NSMaxRange(token.range)
            }
        }
    }

    func testGuessLanguage() {
        XCTAssertEqual(SyntaxHighlighter.guessLanguage("import SwiftUI\n\nstruct ContentView: View {\n    var body: some View { Text(\"Hi\") }\n}"), .swift)
        XCTAssertEqual(SyntaxHighlighter.guessLanguage("def main():\n    print(\"hi\")\n\nif __name__ == \"__main__\":\n    main()"), .python)
        XCTAssertEqual(SyntaxHighlighter.guessLanguage("{\"a\": 1, \"b\": [true, null]}"), .json)
        XCTAssertEqual(SyntaxHighlighter.guessLanguage("#!/bin/bash\necho hi"), .bash)
        XCTAssertEqual(SyntaxHighlighter.guessLanguage("SELECT name FROM users WHERE id = 1;"), .sql)
        XCTAssertEqual(SyntaxHighlighter.guessLanguage("<div class=\"x\"><p>Hi</p></div>"), .html)
        XCTAssertEqual(SyntaxHighlighter.guessLanguage("const x = require('fs');\nfunction f() { console.log(x); }"), .javascript)
        XCTAssertNil(SyntaxHighlighter.guessLanguage("just some words here"))
    }

    func testGuessLanguageStaysFastOnAwkwardInput() {
        let awkward = [
            String(repeating: "a-b c,d>e ", count: 400) + "x",
            String(repeating: "select a, b, c ", count: 500),
            String(repeating: "x = y.z(w) # q\n", count: 2000),
        ]
        let start = Date()
        for text in awkward { _ = SyntaxHighlighter.guessLanguage(text) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    func testTokenizersStayLinearOnLargeBlocks() {
        func sized(_ unit: String) -> String { String(repeating: unit, count: 256 * 1024 / unit.utf16.count) }
        let cases: [(String, CodeLanguage)] = [
            (sized("- [ ] buy milk and [bread\n"), .markdown),
            (sized("[ "), .markdown),
            (sized("tick ` here\n"), .markdown),
            (sized("<p>Tom & Jerry &amp co</p>\n"), .html),
            (sized("& "), .html),
        ]
        for (text, language) in cases {
            let start = Date()
            _ = SyntaxHighlighter.tokenize(text, language: language)
            XCTAssertLessThan(Date().timeIntervalSince(start), 0.5, "\(language) \(text.prefix(12))")
        }
        for language in CodeLanguage.allCases {
            for unit in ["[ & ` ( ${ \" ' /* <!-- # : ", "x\n"] {
                let start = Date()
                _ = SyntaxHighlighter.tokenize(sized(unit), language: language)
                XCTAssertLessThan(Date().timeIntervalSince(start), 0.5, "\(language)")
            }
        }
    }

    func testBoundedSearchesKeepTokens() {
        XCTAssertEqual(kind(of: "&amp;", in: "a &amp; b", .html), .number)
        XCTAssertNil(tokens("&a\nb;", .html).first { $0.1 == .number })
        XCTAssertEqual(kind(of: "[[ see [x]", in: "[[ see [x](y)", .markdown), .type)
        XCTAssertEqual(kind(of: "(y)", in: "[[ see [x](y)", .markdown), .property)
        XCTAssertNil(tokens("- [ ] a\n[b](c)", .markdown).first { $0.0 == "[ ] a\n[b]" })
        XCTAssertEqual(tokens("- [ ] a\n[b](c)", .markdown).filter { $0.1 == .type }.map(\.0), ["[b]"])
        XCTAssertTrue(tokens("a `b\nc` d", .markdown).filter { $0.1 == .string }.isEmpty)
    }

    // MARK: Language persistence

    func testLanguageAliases() {
        let cases: [String: CodeLanguage] = [
            "sh": .bash, "shell": .bash, "zsh": .bash, "js": .javascript, "ts": .typescript, "py": .python,
            "yml": .yaml, "xml": .html, "c++": .cpp, "cs": .csharp, "md": .markdown, "kt": .kotlin,
            "rb": .ruby, "rs": .rust, "Swift": .swift, "json": .json,
        ]
        for (alias, language) in cases {
            XCTAssertEqual(CodeLanguage(identifier: alias), language, alias)
        }
        XCTAssertNil(CodeLanguage(identifier: ""))
        XCTAssertNil(CodeLanguage(identifier: "brainfuck"))
        for language in CodeLanguage.allCases {
            XCTAssertEqual(CodeLanguage(identifier: language.identifier), language)
        }
    }

    func testLanguageSentinelSurvivesRTFD() throws {
        for language in CodeLanguage.allCases {
            var attrs = EditorStyle.attributes(for: .code)
            let ps = (attrs[.paragraphStyle] as! NSParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
            EditorStyle.setCodeLanguage(language, on: ps)
            attrs[.paragraphStyle] = ps
            let text = NSMutableAttributedString(string: "Intro\n", attributes: EditorStyle.bodyAttributes)
            text.append(NSAttributedString(string: "let a = 1\nlet b = 2\n", attributes: attrs))
            let data = try XCTUnwrap(text.rtfd(from: NSRange(location: 0, length: text.length), documentAttributes: [:]))
            let read = try XCTUnwrap(NSAttributedString(rtfd: data, documentAttributes: nil))
            let at = (read.string as NSString).range(of: "let b").location
            let style = read.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle
            XCTAssertEqual(EditorStyle.codeLanguage(of: style), language)
            XCTAssertEqual(EditorStyle.blockKind(paragraphStyle: style, font: read.attribute(.font, at: at, effectiveRange: nil) as? NSFont), .code)
            let body = read.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
            XCTAssertNil(EditorStyle.codeLanguage(of: body))
        }
    }

    func testAutomaticHasNoSentinel() {
        let ps = EditorStyle.attributes(for: .code)[.paragraphStyle] as? NSParagraphStyle
        XCTAssertNil(EditorStyle.codeLanguage(of: ps))
    }

    func testNewCodeLinesInheritLanguage() {
        let markdown = "```python\nx = 1\n```\n"
        let (_, textView) = NoteItTextView.make()
        textView.storage.setAttributedString(MarkdownReader.attributedString(from: markdown))
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).range(of: "x = 1").upperBound, length: 0))
        textView.insertNewline(nil)
        textView.insertText("y = 2", replacementRange: textView.selectedRange())
        let at = (textView.string as NSString).range(of: "y = 2").location
        let ps = textView.storage.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(EditorStyle.codeLanguage(of: ps), .python)
    }

    func testFenceShortcutSetsLanguage() {
        let (_, textView) = NoteItTextView.make()
        textView.storage.setAttributedString(NSAttributedString(string: "\n", attributes: EditorStyle.bodyAttributes))
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.insertText("```rust", replacementRange: textView.selectedRange())
        textView.insertText(" ", replacementRange: NSRange(location: NSNotFound, length: 0))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let ps = textView.storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(NoteItTextView.blockKind(of: textView.storage, at: 0), .code)
        XCTAssertEqual(EditorStyle.codeLanguage(of: ps), .rust)
        XCTAssertFalse(textView.string.contains("```"))
    }

    // MARK: Export and import

    func testMarkdownFenceRoundTrip() {
        let markdown = "Intro\n\n```ts\nconst a: number = 1\n```\n\n```\nplain\n```\n"
        let text = MarkdownReader.attributedString(from: markdown)
        let blocks = NoteBlocks.parse(text)
        let languages = blocks.compactMap { block -> String? in
            if case .code(_, let language) = block { return language?.identifier ?? "auto" }
            return nil
        }
        XCTAssertEqual(languages, ["typescript", "auto"])
        let out = MarkdownWriter.write(text, title: "T").markdown
        XCTAssertTrue(out.contains("```typescript\nconst a: number = 1\n```"), out)
        XCTAssertTrue(out.contains("```\nplain\n```"), out)
        XCTAssertEqual(NoteBlocks.parse(MarkdownReader.attributedString(from: out)).count, blocks.count)
    }

    func testPlainLanguageWritesNoInfoString() {
        let text = MarkdownReader.attributedString(from: "```text\nhello\n```\n")
        XCTAssertEqual(EditorStyle.codeLanguage(of: text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle), .plain)
        XCTAssertTrue(MarkdownWriter.write(text, title: "T").markdown.contains("```\nhello\n```"))
    }

    func testHTMLLanguageClass() {
        let text = MarkdownReader.attributedString(from: "```py\nprint(1)\n```\n\n```\nx\n```\n")
        let html = HTMLWriter.write(text, title: "T")
        XCTAssertTrue(html.contains("<pre><code class=\"language-python\">print(1)</code></pre>"), html)
        XCTAssertTrue(html.contains("<pre><code>x</code></pre>"), html)
    }

    // MARK: Inline code

    private func inlineCodeRuns(_ text: NSAttributedString) -> [String] {
        NoteBlocks.parse(text).flatMap { block -> [String] in
            if case .paragraph(_, _, let runs) = block { return runs.filter(\.code).map(\.text) }
            return []
        }
    }

    func testInlineCodeHasNoStoredBackground() {
        let (_, textView) = NoteItTextView.make()
        textView.storage.setAttributedString(NSAttributedString(string: "run make now\n", attributes: EditorStyle.bodyAttributes))
        textView.setSelectedRange((textView.string as NSString).range(of: "make"))
        textView.perform(.inlineCode)
        let saved = textView.attributedString()
        let at = (saved.string as NSString).range(of: "make").location
        XCTAssertNil(saved.attribute(.backgroundColor, at: at, effectiveRange: nil))
        XCTAssertEqual(inlineCodeRuns(saved), ["make"])
        XCTAssertEqual(MarkdownWriter.write(saved, title: "T").markdown.trimmingCharacters(in: .whitespacesAndNewlines), "run `make` now")
    }

    func testDisplayStylingIsNotPersisted() {
        let defaults = UserDefaults.standard
        let old = defaults.object(forKey: PrefKey.inlineCodeFont)
        defaults.set(InlineCodeFont.sameAsText.rawValue, forKey: PrefKey.inlineCodeFont)
        defer { defaults.set(old, forKey: PrefKey.inlineCodeFont) }

        let (_, textView) = NoteItTextView.make()
        let text = NSMutableAttributedString(string: "use git here\n", attributes: EditorStyle.bodyAttributes)
        let r = (text.string as NSString).range(of: "git")
        text.addAttributes(EditorStyle.inlineCodeAttributes, range: r)
        text.addAttribute(.backgroundColor, value: EditorStyle.legacyInlineCodeBackground, range: r)
        textView.storage.setAttributedString(text)
        textView.codeStyler.restyleAll()

        let displayed = textView.storage.attributes(at: r.location, effectiveRange: nil)
        XCTAssertTrue(EditorStyle.isInlineCode(displayed))
        XCTAssertNil(displayed[.backgroundColor])

        let saved = textView.attributedString()
        for i in r.location..<NSMaxRange(r) {
            let attrs = saved.attributes(at: i, effectiveRange: nil)
            XCTAssertNil(attrs[.inlineCodeDisplay])
            XCTAssertNil(attrs[.kern])
            XCTAssertTrue(EditorStyle.isMonospaced(attrs[.font] as! NSFont))
        }
        XCTAssertEqual(inlineCodeRuns(saved), ["git"])
    }

    func testCopiedInlineCodeStaysCode() throws {
        let defaults = UserDefaults.standard
        let old = defaults.object(forKey: PrefKey.inlineCodeFont)
        defaults.set(InlineCodeFont.sameAsText.rawValue, forKey: PrefKey.inlineCodeFont)
        defer { defaults.set(old, forKey: PrefKey.inlineCodeFont) }

        let (_, textView) = NoteItTextView.make()
        let text = NSMutableAttributedString(string: "use git here\n", attributes: EditorStyle.bodyAttributes)
        text.addAttributes(EditorStyle.inlineCodeAttributes, range: (text.string as NSString).range(of: "git"))
        textView.storage.setAttributedString(text)
        textView.codeStyler.restyleAll()
        textView.setSelectedRange(NSRange(location: 0, length: 12))

        let pb = NSPasteboard(name: NSPasteboard.Name("NoteItTests.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        XCTAssertTrue(textView.writeSelection(to: pb, type: .rtf))
        let data = try XCTUnwrap(pb.data(forType: .rtf))
        let copied = try XCTUnwrap(NSAttributedString(rtf: data, documentAttributes: nil))
        XCTAssertEqual(inlineCodeRuns(copied), ["git"])
        let at = (copied.string as NSString).range(of: "git").location
        XCTAssertNil(copied.attribute(.kern, at: at - 1, effectiveRange: nil))
    }

    func testInlineCodeKeepsHighlightButDropsLegacyGray() throws {
        for font in [InlineCodeFont.sameAsText, .monospaced] {
            let defaults = UserDefaults.standard
            let old = defaults.object(forKey: PrefKey.inlineCodeFont)
            defaults.set(font.rawValue, forKey: PrefKey.inlineCodeFont)
            defer { defaults.set(old, forKey: PrefKey.inlineCodeFont) }

            let (_, textView) = NoteItTextView.make()
            let text = NSMutableAttributedString(string: "old gray and new mark\n", attributes: EditorStyle.bodyAttributes)
            let ns = text.string as NSString
            let gray = ns.range(of: "gray"), mark = ns.range(of: "mark")
            text.addAttributes(EditorStyle.inlineCodeAttributes, range: gray)
            text.addAttributes(EditorStyle.inlineCodeAttributes, range: mark)
            // Round-trip the legacy gray through RTF, as stored notes do.
            let legacy = NSAttributedString(string: "x", attributes: [.backgroundColor: EditorStyle.legacyInlineCodeBackground])
            let rtf = try XCTUnwrap(legacy.rtf(from: NSRange(location: 0, length: 1), documentAttributes: [:]))
            let loaded = try XCTUnwrap(NSAttributedString(rtf: rtf, documentAttributes: nil))
            let loadedGray = try XCTUnwrap(loaded.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor)
            text.addAttribute(.backgroundColor, value: loadedGray, range: gray)
            let yellow = EditorStyle.highlightColors[0].color
            text.addAttribute(.backgroundColor, value: yellow, range: mark)
            textView.storage.setAttributedString(text)
            textView.codeStyler.restyleAll()

            XCTAssertNil(textView.storage.attribute(.backgroundColor, at: gray.location, effectiveRange: nil))
            XCTAssertEqual(textView.storage.attribute(.backgroundColor, at: mark.location, effectiveRange: nil) as? NSColor, yellow)
            let saved = textView.attributedString()
            XCTAssertNil(saved.attribute(.backgroundColor, at: gray.location, effectiveRange: nil))
            XCTAssertEqual(saved.attribute(.backgroundColor, at: mark.location, effectiveRange: nil) as? NSColor, yellow)
            XCTAssertEqual(inlineCodeRuns(saved), ["gray", "mark"])
        }
        XCTAssertFalse(EditorStyle.isLegacyInlineCodeBackground(NSColor.gray))
        XCTAssertFalse(EditorStyle.isLegacyInlineCodeBackground(nil))
    }

    func testHighlightingInlineCodeSticks() {
        let (_, textView) = NoteItTextView.make()
        textView.storage.setAttributedString(NSAttributedString(string: "run make now\n", attributes: EditorStyle.bodyAttributes))
        let r = (textView.string as NSString).range(of: "make")
        textView.setSelectedRange(r)
        textView.perform(.inlineCode)
        textView.setSelectedRange(r)
        let yellow = EditorStyle.highlightColors[0].color
        textView.perform(.highlight(yellow))
        textView.codeStyler.restyleAll()
        XCTAssertEqual(textView.attributedString().attribute(.backgroundColor, at: r.location, effectiveRange: nil) as? NSColor, yellow)

        textView.setSelectedRange(r)
        textView.perform(.inlineCode)
        XCTAssertEqual(textView.attributedString().attribute(.backgroundColor, at: r.location, effectiveRange: nil) as? NSColor, yellow)
        XCTAssertEqual(inlineCodeRuns(textView.attributedString()), [])
    }

    func testOldBackgroundInlineCodeStillExports() {
        let text = NSMutableAttributedString(string: "call foo() please\n", attributes: EditorStyle.bodyAttributes)
        let r = (text.string as NSString).range(of: "foo()")
        text.addAttributes([.font: EditorStyle.inlineCodeFont, .backgroundColor: NSColor.lightGray], range: r)
        XCTAssertEqual(inlineCodeRuns(text), ["foo()"])
        XCTAssertTrue(HTMLWriter.write(text, title: "T").contains("<code>foo()</code>"))
    }
}
