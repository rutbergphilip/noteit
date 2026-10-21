import AppKit
import XCTest
@testable import NoteIt

final class TemplateExpanderTests: XCTestCase {
    private let locale = Locale(identifier: "en_US_POSIX")
    private var date: Date {
        var c = DateComponents()
        c.year = 2026; c.month = 10; c.day = 19; c.hour = 14; c.minute = 5
        return Calendar.current.date(from: c)!
    }

    private func context(clipboard: @escaping () -> String? = { nil }) -> TemplateContext {
        TemplateContext(title: "Atlas", date: date, locale: locale, clipboard: clipboard)
    }

    func testAllVariables() {
        let t = NSAttributedString(string: "{{title}} {{date}} {{TIME:HH:mm}} {{clipboard}}{{cursor}}")
        let r = TemplateExpander.expand(t, context: context(clipboard: { "clip\n" }))
        XCTAssertEqual(r.text.string, "Atlas 2026-10-19 14:05 clip")
        XCTAssertEqual(r.caret, (r.text.string as NSString).length)
    }

    func testDatePattern() {
        let r = TemplateExpander.expand(NSAttributedString(string: "{{date:EEEE d MMMM}}"), context: context())
        XCTAssertEqual(r.text.string, "Monday 19 October")
    }

    func testKeepsFormattingOfFirstBrace() {
        let bold = NSFont.boldSystemFont(ofSize: 13)
        let t = NSMutableAttributedString(string: "x ")
        t.append(NSAttributedString(string: "{", attributes: [.font: bold]))
        t.append(NSAttributedString(string: "{date}}"))
        let r = TemplateExpander.expand(t, context: context())
        XCTAssertEqual(r.text.string, "x 2026-10-19")
        XCTAssertEqual(r.text.attribute(.font, at: 2, effectiveRange: nil) as? NSFont, bold)
        XCTAssertEqual(r.text.attribute(.font, at: r.text.length - 1, effectiveRange: nil) as? NSFont, bold)
    }

    func testClipboardReadOnlyWhenUsedAndCapped() {
        var reads = 0
        _ = TemplateExpander.expand(NSAttributedString(string: "{{title}}"), context: context(clipboard: { reads += 1; return "x" }))
        XCTAssertEqual(reads, 0)
        let big = String(repeating: "a", count: 20_000)
        let r = TemplateExpander.expand(NSAttributedString(string: "{{clipboard}}|{{clipboard}}"),
                                        context: context(clipboard: { reads += 1; return big }))
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(r.text.length, TemplateExpander.clipboardLimit * 2 + 1)
    }

    func testFirstCursorWinsOthersRemoved() {
        let r = TemplateExpander.expand(NSAttributedString(string: "{{title}} a{{cursor}}b{{cursor}}c"), context: context())
        XCTAssertEqual(r.text.string, "Atlas abc")
        XCTAssertEqual(r.caret, 7)
    }

    func testUnknownVariableUntouched() {
        let r = TemplateExpander.expand(NSAttributedString(string: "{{weather}} {{date:}}"), context: context())
        XCTAssertEqual(r.text.string, "{{weather}} {{date:}}")
        XCTAssertNil(r.caret)
    }

    func testLinksAndAttachmentsCopied() {
        let url = URL(string: "noteit://note/6F1C2C0E-0000-4000-8000-000000000001")!
        let t = NSMutableAttributedString(string: "{{title}} ")
        t.append(NSAttributedString(string: "link", attributes: [.link: url]))
        t.append(NSAttributedString(attachment: NSTextAttachment()))
        let r = TemplateExpander.expand(t, context: context())
        XCTAssertEqual(r.text.attribute(.link, at: 6, effectiveRange: nil) as? URL, url)
        XCTAssertNotNil(r.text.attribute(.attachment, at: r.text.length - 1, effectiveRange: nil))
    }

    func testDisplayName() {
        XCTAssertEqual(TemplateExpander.displayName(forTitle: "Meeting – {{date}}"), "Meeting")
        XCTAssertEqual(TemplateExpander.displayName(forTitle: "{{date}} {{title}}"), "Untitled Template")
        XCTAssertEqual(TemplateExpander.displayName(forTitle: "Weekly review"), "Weekly review")
    }
}
