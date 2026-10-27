import NoteItDoc
import NoteItDocTestSupport
import XCTest

/// `fixtures/golden/derive.json`: title, preview, tags and plain text of noteit-docs. Written here under
/// `NOTEIT_WRITE_VECTORS=1`, read by `@noteit/doc` (`derive.test.ts`), and checked against the Mac's own derivation
/// from the attributed string in `DocDerivationParityTests` (NoteItTests).
final class DocDerivationTests: XCTestCase {
    struct DeriveCase: Codable, Equatable {
        var name: String
        var doc: DocNode
        var title: String
        var preview: String
        var tags: [String]
        var plainText: String
        var maskedText: String
    }

    // MARK: Builders

    private static func t(_ text: String, _ marks: [Mark] = []) -> Inline { .text(text, marks: marks) }
    private static func p(_ content: Inline...) -> DocNode { .paragraph(align: nil, indent: nil, content: content) }
    private static func h(_ level: Int, _ content: Inline...) -> DocNode { .heading(level: level, align: nil, indent: nil, content: content) }
    private static func code(_ text: String, language: String? = nil) -> DocNode {
        .codeBlock(align: nil, language: language, content: [t(text)])
    }
    private static func li(_ kind: ListKind, level: Int = 0, number: Int? = nil, checked: Bool? = nil, _ content: Inline...) -> DocNode {
        .listItem(kind: kind, level: level, number: number, checked: checked, align: nil, content: content)
    }
    private static func cell(_ text: String, header: Bool = false) -> TableCell { TableCell(header: header, content: [p(t(text))]) }
    private static func doc(_ blocks: DocNode...) -> DocNode { .doc(blocks) }
    private static let png = Inline.image(sha: "2a6927613ddc903379f3e02145f22074ccf048c7753cfa1ed8ee26c746682997", name: "photo.png", mime: "image/png", width: nil)
    private static let file = Inline.attachment(sha: "d1cb546b102fab8362de413fdacc187b05be10df72b72db3b3e50b4953f6a555", name: "notes.pdf", mime: "application/pdf")

    /// The documents; the expected values are what `DocDerivation` gives, checked against the Mac's attributed
    /// string derivation in `DocDerivationParityTests`.
    static let docs: [(String, DocNode)] = [
        ("empty", .doc([])),
        ("blank-paragraphs", doc(p(), p(t("   ")), p(t("\t")))),
        ("title-only", doc(p(t("Trip plan")))),
        ("title-and-preview", doc(h(1, t("Trip plan")), p(t("Pack boots.")), p(), p(t("Book the hut.")))),
        ("leading-blank-lines", doc(p(), p(t("  ")), p(t("  First  ")), p(t("second")))),
        ("tabs-and-controls", doc(p(t("a\tb\u{0007}c")), p(t("\u{001B}d")))),
        ("title-120-ascii", doc(p(t(String(repeating: "x", count: 130))))),
        ("title-120-emoji-modifiers", doc(p(t(String(repeating: "👍🏽", count: 125))))),
        ("title-120-zwj-family", doc(p(t(String(repeating: "x", count: 119) + "👨‍👩‍👧‍👦" + "tail")))),
        ("preview-140-zwj", doc(p(t("T")), p(t(String(repeating: "y", count: 139) + "👩‍💻👩‍💻")))),
        ("preview-joins-lines", doc(p(t("T")), p(t("one")), p(t("  two ")), p(), p(t("three")))),
        ("rtl-text", doc(p(t("שלום עולם")), p(t("مرحبا #سلام")))),
        ("combining-accents", doc(p(t("Cafe\u{301} #cafe\u{301}")))),
        ("bullet-levels", doc(p(t("List")), li(.bullet, t("one")), li(.bullet, level: 1, t("two")), li(.bullet, level: 2, t("three")),
                              li(.bullet, level: 3, t("four")))),
        ("ordered-list", doc(li(.ordered, number: 1, t("first")), li(.ordered, number: 2, t("second")), li(.ordered, number: 10, t("tenth")))),
        ("task-list", doc(li(.task, checked: false, t("buy milk")), li(.task, checked: true, t("call mom #home")))),
        ("empty-list-item-title", doc(li(.bullet), p(t("after")))),
        ("tags-basic", doc(p(t("#gear and #gear/boots, #Café")))),
        ("tags-after-punctuation", doc(p(t("(#paren) “#quote” ,#comma ;#semi \"#dq\" '#sq'")))),
        ("tags-not-in-words", doc(p(t("a#b site.com/#x ?q=#y mail#tag")))),
        ("tags-dedup-case", doc(p(t("#Work #work #WORK #work/Plan")))),
        ("tags-nesting-limit", doc(p(t("#a/b/c/d/e/f/g")))),
        ("tags-in-inline-code", doc(p(t("see "), t("#notatag", [.code]), t(" and #real")))),
        ("tags-in-link", doc(p(t("#linked", [.link(href: "https://example.com")]), t(" #free")))),
        ("tags-in-code-block", doc(p(t("Code")), code("let x = 1 // #nottag", language: "swift"), p(t("#after")))),
        ("code-block-language", doc(code("print(\"hi\")", language: "python"), code("second line"))),
        ("code-block-title", doc(code("  #!/bin/sh  "), p(t("body")))),
        ("hard-break", doc(p(t("line one"), .hardBreak, t("line two")), p(t("next")))),
        ("soft-break", doc(p(t("a"), .softBreak, t("b")))),
        ("break-at-edges", doc(p(.hardBreak, t("middle"), .hardBreak))),
        ("image-only-title", doc(p(png), p(t("Caption")))),
        ("image-in-text", doc(p(t("Look "), png, t(" here")), p(file, t(" attached")))),
        ("horizontal-rule", doc(p(t("Above")), .horizontalRule, p(t("Below")))),
        ("blockquote", doc(.blockquote(indent: nil, content: [p(t("Quoted #idea")), p(t("more"))]), p(t("after")))),
        ("table-with-header", doc(p(t("Prices")), .table(columnWidths: nil, rows: [
            [cell("Item", header: true), cell("Cost", header: true)],
            [cell("Boots"), cell("120")],
            [cell("Tent"), cell("")],
        ]))),
        ("table-without-header", doc(.table(columnWidths: nil, rows: [[cell("a"), cell("b")], [cell(""), cell("")], [cell("c"), cell("#tagged")]]),
                                     p(t("after")))),
        ("table-only-header", doc(p(t("T")), .table(columnWidths: nil, rows: [[cell("H1", header: true), cell("H2", header: true)]]))),
        ("table-title", doc(.table(columnWidths: [100, 200], rows: [[cell("x"), cell("y")]]), p(t("tail")))),
        ("headings", doc(h(1, t("Title")), h(2, t("Heading")), h(3, t("Sub")))),
        ("mixed-marks", doc(p(t("Bold", [.bold]), t(" "), t("italic", [.italic]), t(" "), t("#hl", [.highlight("yellow")])))),
        ("whitespace-only-preview", doc(p(t("T")), p(t(" \t ")), p(t("\u{00A0}")))),
        ("numbers-tag", doc(p(t("#2024 #_under #a-b #é1")))),
        ("table-bold-first-row", doc(.table(columnWidths: nil, rows: [
            [TableCell(header: false, content: [p(t("Name", [.bold]))]), cell("plain")],
            [cell("Ann"), cell("12")],
        ]))),
        ("table-bold-later-row", doc(.table(columnWidths: nil, rows: [
            [cell("Ann"), cell("12")],
            [TableCell(header: false, content: [p(t("Total", [.bold]))]), cell("12")],
        ]))),
        ("table-one-header-cell", doc(.table(columnWidths: nil, rows: [[cell("H", header: true), cell("not")], [cell("a"), cell("b")]]))),
        ("table-header-in-second-row", doc(.table(columnWidths: nil, rows: [[cell("a"), cell("b")], [cell("H", header: true), cell("c")]]))),
        ("table-bold-blank-first-row", doc(.table(columnWidths: nil, rows: [
            [TableCell(header: false, content: [p(t(" ", [.bold]))]), cell("")],
            [cell("a"), cell("b")],
        ]))),
        ("code-block-then-tag", doc(code("x = 1"), p(t("#after")), p(t("text "), t("code", [.code])), p(t("#next")))),
        ("empty-code-block", doc(p(t("T")), .codeBlock(align: nil, language: nil, content: []), p(t("#tail")))),
        ("link-at-end", doc(p(t("see "), t("site", [.link(href: "https://example.com")])), p(t("#x")))),
    ]

    static func expected(_ name: String, _ doc: DocNode) -> DeriveCase {
        let (title, preview) = DocDerivation.titleAndPreview(of: doc)
        return DeriveCase(name: name, doc: doc, title: title, preview: preview, tags: DocDerivation.tags(of: doc),
                          plainText: DocDerivation.plainText(of: doc), maskedText: DocDerivation.maskedText(of: doc))
    }

    func testDeriveVectors() throws {
        let cases = Self.docs.map { Self.expected($0.0, $0.1) }
        XCTAssertGreaterThanOrEqual(cases.count, 40)
        if ProcessInfo.processInfo.environment["NOTEIT_WRITE_VECTORS"] == "1" {
            try GoldenFixtures.write(GoldenFile(generator: "swift", cases: cases), to: "derive.json")
        }
        let stored = try GoldenFixtures.load("derive.json", as: GoldenFile<DeriveCase>.self)
        XCTAssertEqual(stored.cases.map(\.name), cases.map(\.name))
        for (stored, fresh) in zip(stored.cases, cases) { XCTAssertEqual(stored, fresh, stored.name) }
    }

    // MARK: Rules

    func testCleanDropsObjectsAndControlsAndTrims() {
        XCTAssertEqual(DocDerivation.clean("\u{FFFC} a\tb\u{0007} \n"), "a b")
    }

    func testTitleAndPreviewFromLines() {
        let (title, preview) = DocDerivation.titleAndPreview(lines: ["", " Title ", "", "one", " two"])
        XCTAssertEqual(title, "Title")
        XCTAssertEqual(preview, "one two")
        XCTAssertTrue(DocDerivation.titleAndPreview(lines: ["", "  "]) == ("", ""))
    }

    func testTitleCountsGraphemes() {
        let title = DocDerivation.titleAndPreview(of: Self.doc(Self.p(Self.t(String(repeating: "👍🏽", count: 125))))).title
        XCTAssertEqual(title.count, 120)
        XCTAssertEqual(title, String(repeating: "👍🏽", count: 120))
    }

    func testTablesCollapseWithoutTheirHeaderRow() {
        let lines = DocDerivation.lines(of: Self.docs.first { $0.0 == "table-with-header" }!.1)
        XCTAssertEqual(lines, ["Prices", "Boots · 120  Tent"])
    }

    func testTagsSkipCodeAndLinks() {
        XCTAssertEqual(DocDerivation.tags(of: Self.docs.first { $0.0 == "tags-in-inline-code" }!.1), ["real"])
        XCTAssertEqual(DocDerivation.tags(of: Self.docs.first { $0.0 == "tags-in-link" }!.1), ["free"])
        XCTAssertEqual(DocDerivation.tags(of: Self.docs.first { $0.0 == "tags-in-code-block" }!.1), ["after"])
    }
}
