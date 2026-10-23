import AppKit
import XCTest
import NoteItDocTestSupport
@testable import NoteIt

@MainActor
final class FindReplaceTests: XCTestCase {
    private typealias Engine = FindReplaceEngine
    private typealias Options = FindReplaceEngine.Options

    private func matches(_ text: String, _ query: String, _ options: Options = Options()) throws -> [NSRange] {
        try Engine.matches(in: text, query: query, options: options)
    }

    private func strings(_ text: String, _ ranges: [NSRange]) -> [String] {
        ranges.map { (text as NSString).substring(with: $0) }
    }

    // MARK: Matching

    func testEmptyQueryOrTextHasNoMatches() throws {
        XCTAssertEqual(try matches("hello", ""), [])
        XCTAssertEqual(try matches("", "a"), [])
        XCTAssertEqual(try matches("", "", Options(regex: true)), [])
    }

    func testCaseInsensitiveByDefaultAndMatchCase() throws {
        let text = "Apple apple APPLE"
        XCTAssertEqual(try matches(text, "apple").count, 3)
        XCTAssertEqual(try matches(text, "apple", Options(matchCase: true)), [NSRange(location: 6, length: 5)])
    }

    func testLiteralQueryIgnoresRegexSyntax() throws {
        let text = "a.b axb (x) $1 \\d"
        XCTAssertEqual(try matches(text, "a.b"), [NSRange(location: 0, length: 3)])
        XCTAssertEqual(try matches(text, "(x)"), [NSRange(location: 8, length: 3)])
        XCTAssertEqual(try matches(text, "$1").count, 1)
        XCTAssertEqual(try matches(text, "\\d").count, 1)
    }

    func testWholeWord() throws {
        let text = "cat concat cat_s cats cat. (cat) Cat"
        let found = try matches(text, "cat", Options(wholeWord: true))
        XCTAssertEqual(strings(text, found), ["cat", "cat", "cat", "Cat"])
        XCTAssertEqual(found.first, NSRange(location: 0, length: 3))
    }

    func testWholeWordWithPunctuationAtEdges() throws {
        let text = "a-b x-b -b"
        XCTAssertEqual(try matches(text, "-b", Options(wholeWord: true)).count, 3)
    }

    func testWholeWordTreatsUnicodeLettersAsWordCharacters() throws {
        let text = "över överallt över"
        XCTAssertEqual(try matches(text, "över", Options(wholeWord: true)), [NSRange(location: 0, length: 4), NSRange(location: 14, length: 4)])
    }

    func testRegex() throws {
        let text = "id 12, id 345, id x"
        XCTAssertEqual(strings(text, try matches(text, "\\d+", Options(regex: true))), ["12", "345"])
        XCTAssertEqual(try matches(text, "^id", Options(regex: true)).count, 1)
        XCTAssertEqual(try matches("one\ntwo\nthree", "^t\\w+", Options(regex: true)).count, 2)
    }

    func testRegexRespectsMatchCase() throws {
        XCTAssertEqual(try matches("Ab ab", "a.", Options(regex: true)).count, 2)
        XCTAssertEqual(try matches("Ab ab", "a.", Options(matchCase: true, regex: true)).count, 1)
    }

    func testZeroLengthRegexMatchesAreSkipped() throws {
        XCTAssertEqual(try matches("abc", "x*", Options(regex: true)), [])
        XCTAssertEqual(try matches("abc", "^", Options(regex: true)), [])
    }

    func testInvalidRegexThrows() {
        XCTAssertThrowsError(try matches("abc", "(", Options(regex: true))) { error in
            XCTAssertEqual(error as? Engine.Failure, .invalidRegex)
        }
        XCTAssertEqual(try matches("a(b", "("), [NSRange(location: 1, length: 1)])
    }

    func testOverlappingCandidatesDoNotOverlapAndAdjacentMatchesAreAllFound() throws {
        XCTAssertEqual(try matches("aaaa", "aa"), [NSRange(location: 0, length: 2), NSRange(location: 2, length: 2)])
        XCTAssertEqual(try matches("aaa", "aa"), [NSRange(location: 0, length: 2)])
        XCTAssertEqual(try matches("abab", "ab").count, 2)
    }

    func testRangesAreUTF16() throws {
        let text = "😀 cat 👨‍👩‍👧 cat é"
        let found = try matches(text, "cat")
        XCTAssertEqual(found, [NSRange(location: 3, length: 3), NSRange(location: 16, length: 3)])
        XCTAssertEqual(strings(text, found), ["cat", "cat"])
        let emoji = try matches(text, "👨‍👩‍👧")
        XCTAssertEqual(emoji, [NSRange(location: 7, length: 8)])
        XCTAssertEqual(try matches(text, "é"), [NSRange(location: 20, length: 1)])
    }

    func testWholeWordNextToEmoji() throws {
        XCTAssertEqual(try matches("😀cat😀", "cat", Options(wholeWord: true)), [NSRange(location: 2, length: 3)])
    }

    // MARK: Replacement strings

    func testLiteralReplacementKeepsDollarAndBackslash() {
        let text = "price"
        let replaced = Engine.replacement(for: NSRange(location: 0, length: 5), in: text, query: "price", template: "$1 \\n cost", options: Options())
        XCTAssertEqual(replaced, "$1 \\n cost")
    }

    func testRegexReplacementExpandsCaptures() {
        let text = "John Smith, Jane Doe"
        let options = Options(regex: true)
        let query = "(\\w+) (\\w+)"
        let found = try! Engine.matches(in: text, query: query, options: options)
        XCTAssertEqual(found.count, 2)
        let replaced = found.map { Engine.replacement(for: $0, in: text, query: query, template: "$2, $1", options: options) }
        XCTAssertEqual(replaced, ["Smith, John", "Doe, Jane"])
    }

    func testRegexReplacementWithLookbehindUsesFullText() {
        let text = "x1 y2"
        let options = Options(regex: true)
        let query = "(?<=y)(\\d)"
        let found = try! Engine.matches(in: text, query: query, options: options)
        XCTAssertEqual(found, [NSRange(location: 4, length: 1)])
        XCTAssertEqual(Engine.replacement(for: found[0], in: text, query: query, template: "[$1]", options: options), "[2]")
    }

    func testRegexReplacementEscapedDollar() {
        let text = "5"
        let options = Options(regex: true)
        XCTAssertEqual(Engine.replacement(for: NSRange(location: 0, length: 1), in: text, query: "(\\d)", template: "\\$$1", options: options), "$5")
    }

    // MARK: Applying to a text view

    private func makeTextView(_ text: NSAttributedString) -> (NSTextView, UndoManager) {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        textView.isRichText = true
        textView.allowsUndo = true
        let undo = UndoManager()
        undo.groupsByEvent = false
        let delegate = UndoDelegate(undo: undo)
        textView.delegate = delegate
        objc_setAssociatedObject(textView, &UndoDelegate.key, delegate, .OBJC_ASSOCIATION_RETAIN)
        textView.textStorage?.setAttributedString(text)
        return (textView, undo)
    }

    private func sample() -> NSAttributedString {
        let result = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: 14)
        let bold = NSFont.boldSystemFont(ofSize: 14)
        result.append(NSAttributedString(string: "cat ", attributes: [.font: body]))
        result.append(NSAttributedString(string: "cat", attributes: [.font: bold, .foregroundColor: NSColor.systemRed]))
        result.append(NSAttributedString(string: " and ", attributes: [.font: body]))
        result.append(NSAttributedString(string: "cat", attributes: [.font: body, .underlineStyle: NSUnderlineStyle.single.rawValue]))
        return result
    }

    func testReplaceAllKeepsFormattingAndIsOneUndoStep() throws {
        let original = sample()
        let (textView, undo) = makeTextView(original)
        let text = textView.string
        let ranges = try Engine.matches(in: text, query: "cat", options: Options())
        XCTAssertEqual(ranges.count, 3)
        let replacements = ranges.map { Engine.replacement(for: $0, in: text, query: "cat", template: "tiger", options: Options()) }

        XCTAssertTrue(FindReplaceApplier.replace(ranges, with: replacements, in: textView, actionName: "Replace All"))

        let storage = try XCTUnwrap(textView.textStorage)
        XCTAssertEqual(storage.string, "tiger tiger and tiger")
        XCTAssertEqual((storage.attribute(.font, at: 6, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold), true)
        var boldRange = NSRange()
        _ = storage.attribute(.foregroundColor, at: 6, effectiveRange: &boldRange)
        XCTAssertEqual(boldRange, NSRange(location: 6, length: 5))
        XCTAssertEqual(storage.attribute(.foregroundColor, at: 6, effectiveRange: nil) as? NSColor, NSColor.systemRed)
        XCTAssertNil(storage.attribute(.underlineStyle, at: 0, effectiveRange: nil))
        var underlineRange = NSRange()
        let underline = storage.attribute(.underlineStyle, at: 16, effectiveRange: &underlineRange) as? Int
        XCTAssertEqual(underline, NSUnderlineStyle.single.rawValue)
        XCTAssertEqual(underlineRange, NSRange(location: 16, length: 5))

        XCTAssertTrue(undo.canUndo)
        XCTAssertEqual(undo.undoActionName, "Replace All")
        undo.undo()
        XCTAssertTrue(storage.isEqual(to: original), "one undo restores the text and its formatting")
        XCTAssertFalse(undo.canUndo)
        undo.redo()
        XCTAssertEqual(storage.string, "tiger tiger and tiger")
    }

    func testBatchedReplaceAllKeepsFormattingAndIsOneUndoStep() throws {
        let original = NSMutableAttributedString()
        for _ in 0...FindReplaceApplier.batchThreshold { original.append(sample()); original.append(NSAttributedString(string: "\n")) }
        let (textView, undo) = makeTextView(original)
        let text = textView.string
        let ranges = try Engine.matches(in: text, query: "cat", options: Options())
        XCTAssertGreaterThan(ranges.count, FindReplaceApplier.batchThreshold)

        XCTAssertTrue(FindReplaceApplier.replace(ranges, with: ranges.map { _ in "tiger" }, in: textView, actionName: "Replace All"))

        let storage = try XCTUnwrap(textView.textStorage)
        XCTAssertFalse(storage.string.contains("cat"))
        XCTAssertTrue(storage.string.hasPrefix("tiger tiger and tiger\ntiger tiger and tiger\n"))
        let secondBold = 22 + 6
        XCTAssertEqual(storage.attribute(.foregroundColor, at: secondBold, effectiveRange: nil) as? NSColor, NSColor.systemRed)
        XCTAssertEqual(storage.attribute(.underlineStyle, at: 22 + 16, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)
        XCTAssertEqual(undo.undoActionName, "Replace All")
        undo.undo()
        XCTAssertTrue(storage.isEqual(to: original), "one undo restores the text and its formatting")
        XCTAssertFalse(undo.canUndo)
    }

    func testReplaceSingleMatchIsUndoable() throws {
        let original = sample()
        let (textView, undo) = makeTextView(original)
        XCTAssertTrue(FindReplaceApplier.replace([NSRange(location: 4, length: 3)], with: ["dog"], in: textView, actionName: "Replace"))
        XCTAssertEqual(textView.string, "cat dog and cat")
        XCTAssertEqual(textView.textStorage?.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? NSColor, NSColor.systemRed)
        undo.undo()
        XCTAssertTrue(textView.textStorage!.isEqual(to: original))
    }

    func testReplaceRefusedForReadOnlyTextView() {
        let (textView, _) = makeTextView(sample())
        textView.isEditable = false
        XCTAssertFalse(FindReplaceApplier.replace([NSRange(location: 0, length: 3)], with: ["dog"], in: textView, actionName: "Replace"))
        XCTAssertEqual(textView.string, "cat cat and cat")
    }

    func testRegexReplaceAllWithCapturesInTextView() throws {
        let (textView, undo) = makeTextView(NSAttributedString(string: "a1 b22 c333", attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        let options = Options(regex: true)
        let query = "([a-z])(\\d+)"
        let text = textView.string
        let ranges = try Engine.matches(in: text, query: query, options: options)
        let replacements = ranges.map { Engine.replacement(for: $0, in: text, query: query, template: "$2$1", options: options) }
        FindReplaceApplier.replace(ranges, with: replacements, in: textView, actionName: "Replace All")
        XCTAssertEqual(textView.string, "1a 22b 333c")
    }
}

private final class UndoDelegate: NSObject, NSTextViewDelegate {
    nonisolated(unsafe) static var key = 0
    let undo: UndoManager
    init(undo: UndoManager) { self.undo = undo }
    func undoManager(for view: NSTextView) -> UndoManager? { undo }
}

/// The find bar's model driving a real editor text view.
@MainActor
final class FindReplaceModelTests: XCTestCase {
    private var window: NSWindow!
    private var textView: NoteItTextView!
    private var editor: EditorController!
    private var model: FindReplaceModel!

    override func setUp() {
        let (scrollView, textView) = NoteItTextView.make()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        self.textView = textView
        editor = EditorController()
        editor.textView = textView
        model = FindReplaceModel()
        model.editor = editor
        let body = NSMutableAttributedString(string: "One cat, ", attributes: EditorStyle.bodyAttributes)
        var bold = EditorStyle.bodyAttributes
        bold[.font] = NSFontManager.shared.convert(EditorStyle.bodyFont, toHaveTrait: .boldFontMask)
        body.append(NSAttributedString(string: "two cats", attributes: bold))
        body.append(NSAttributedString(string: " and a Cat.", attributes: EditorStyle.bodyAttributes))
        textView.textStorage?.setAttributedString(body)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
    }

    override func tearDown() {
        model.close(refocusText: false)
        window.close()
    }

    private func highlightCount() -> Int {
        guard let layoutManager = textView.layoutManager else { return 0 }
        var count = 0
        var index = 0
        while index < textView.storage.length {
            var range = NSRange()
            if layoutManager.temporaryAttribute(.backgroundColor, atCharacterIndex: index, effectiveRange: &range) != nil { count += 1 }
            index = max(NSMaxRange(range), index + 1)
        }
        return count
    }

    func testOpenUsesSelectionCountsAndHighlights() {
        textView.setSelectedRange(NSRange(location: 4, length: 3))
        model.open(replace: false)
        XCTAssertTrue(model.isVisible)
        XCTAssertEqual(model.query, "cat")
        XCTAssertEqual(model.matchCount, 3)
        XCTAssertEqual(model.statusText, "1 of 3")
        XCTAssertEqual(highlightCount(), 3)
        XCTAssertEqual(textView.string, "One cat, two cats and a Cat.", "highlighting never edits the text")
    }

    func testSelectionIsEscapedInRegexMode() {
        let cat = (textView.string as NSString).range(of: "Cat.")
        model.options = .init(regex: true)
        textView.setSelectedRange(cat)
        model.open(replace: false)
        XCTAssertEqual(model.query, "Cat\\.")
        XCTAssertEqual(model.matchCount, 1)

        model.query = "zzz"
        textView.setSelectedRange(cat)
        model.useSelectionForFind()
        XCTAssertEqual(model.query, "Cat\\.")
        XCTAssertEqual(model.matchCount, 1)

        model.options = .init()
        textView.setSelectedRange(cat)
        model.useSelectionForFind()
        XCTAssertEqual(model.query, "Cat.")
    }

    func testNextAndPreviousWrapAround() {
        model.open(replace: false)
        model.query = "cat"
        XCTAssertEqual(model.currentIndex, 0)
        model.findNext(); model.findNext()
        XCTAssertEqual(model.statusText, "3 of 3")
        model.findNext()
        XCTAssertEqual(model.statusText, "1 of 3")
        model.findPrevious()
        XCTAssertEqual(model.statusText, "3 of 3")
    }

    func testOptionsAndInvalidRegex() {
        model.open(replace: false)
        model.query = "cat"
        model.options.matchCase = true
        XCTAssertEqual(model.matchCount, 2)
        model.options.wholeWord = true
        XCTAssertEqual(model.matchCount, 1)
        model.options = .init(regex: true)
        model.query = "ca("
        XCTAssertTrue(model.isInvalidRegex)
        XCTAssertEqual(model.statusText, "Invalid regex")
        XCTAssertTrue(model.statusIsError)
        model.query = "zzz"
        XCTAssertEqual(model.statusText, "No results")
    }

    func testReplaceMovesToNextAndReplaceAllIsOneUndo() throws {
        let undo = try XCTUnwrap(textView.undoManager)
        undo.groupsByEvent = false
        model.open(replace: true)
        XCTAssertTrue(model.showsReplace)
        model.query = "cat"
        model.replacement = "dog"
        model.replaceCurrent()
        XCTAssertEqual(textView.string, "One dog, two cats and a Cat.")
        XCTAssertEqual(model.statusText, "1 of 2")
        model.replaceAll()
        XCTAssertEqual(textView.string, "One dog, two dogs and a dog.")
        XCTAssertEqual(model.statusText, "No results")
        let font = try XCTUnwrap(textView.storage.attribute(.font, at: 13, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold))
        undo.undo()
        XCTAssertEqual(textView.string, "One dog, two cats and a Cat.")
        undo.undo()
        XCTAssertEqual(textView.string, "One cat, two cats and a Cat.")
    }

    func testReadOnlyHidesReplaceAndDoesNotEdit() {
        model.allowsReplace = false
        textView.isEditable = false
        model.open(replace: true)
        XCTAssertFalse(model.showsReplace)
        model.query = "cat"
        model.replacement = "dog"
        model.replaceAll()
        XCTAssertEqual(textView.string, "One cat, two cats and a Cat.")
        XCTAssertEqual(model.matchCount, 3)
    }

    func testCloseSelectsCurrentMatchAndClearsHighlights() {
        model.open(replace: false)
        model.query = "cat"
        model.findNext()
        model.close()
        XCTAssertFalse(model.isVisible)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 13, length: 3))
        XCTAssertEqual(highlightCount(), 0)
    }

    func testEditingTextRecomputesMatches() {
        model.open(replace: false)
        model.query = "cat"
        textView.setSelectedRange(NSRange(location: textView.storage.length, length: 0))
        textView.insertText(" cat", replacementRange: textView.selectedRange())
        let deadline = Date().addingTimeInterval(TestTiming.scaled(2))
        while model.matchCount != 4, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(model.matchCount, 4)
    }

    func testReplaceAllCoversMatchesBeyondTheLimit() {
        let count = FindReplaceEngine.matchLimit + 500
        textView.textStorage?.setAttributedString(NSAttributedString(string: String(repeating: "x ", count: count), attributes: EditorStyle.bodyAttributes))
        model.open(replace: true)
        model.query = "x"
        model.replacement = "y"
        XCTAssertEqual(model.matchCount, FindReplaceEngine.matchLimit)
        model.replaceAll()
        XCTAssertFalse(textView.string.contains("x"))
        XCTAssertEqual(model.statusText, "No results")
    }

    func testFocusRequestIsHandledOnce() {
        model.open(replace: false)
        let token = model.focusRequest.token
        XCTAssertTrue(model.consumeFocus(token))
        XCTAssertFalse(model.consumeFocus(token))
        model.requestFocus(.find)
        XCTAssertTrue(model.consumeFocus(model.focusRequest.token))
    }
}
