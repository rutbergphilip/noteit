import AppKit
import CryptoKit
import NoteItDoc
import NoteItDocAppKit
import XCTest
@testable import NoteIt

@MainActor
final class BodyCodecTests: XCTestCase {
    private let fm = FileManager.default
    private var dir: URL!

    override func setUpWithError() throws {
        dir = fm.temporaryDirectory.appendingPathComponent("BodyCodecTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: dir)
    }

    /// The golden file holds `NoteExporter.plainText` and `HTMLWriter.write` output captured before BodyCodec existed.
    func testPlainTextAndHTMLMatchPreChangeOutput() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/golden/body-codec-text.json")
        let golden = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let cases = try XCTUnwrap(golden["cases"] as? [[String: String]])
        XCTAssertGreaterThan(cases.count, 20)
        for item in cases {
            let markdown = try XCTUnwrap(item["markdown"])
            let text = MarkdownReader.attributedString(from: markdown, resolveImage: { _ in nil })
            XCTAssertEqual(BodyCodec.plainText(of: text), item["plainText"], markdown)
            XCTAssertEqual(NoteExporter.plainText(text), item["plainText"], markdown)
            XCTAssertEqual(BodyCodec.html(of: text, title: "Fixture"), item["html"], markdown)
            XCTAssertEqual(BodyCodec.html(of: text, title: "Fixture"), HTMLWriter.write(text, title: "Fixture"), markdown)
        }
    }

    func testEveryCodecRoundTripsAFullNote() throws {
        let text = try fullNote()
        for codec in BodyCodec.allCases {
            let url = dir.appendingPathComponent("note.\(codec.fileExtension)")
            try codec.write(text, meta: NoteMeta(id: UUID(), title: "", preview: "", isPinned: false, createdAt: Date(),
                                                 updatedAt: Date(), tags: []), to: url)
            let read = try codec.read(at: url)
            XCTAssertTrue(BodyCodec.semanticallyEqual(read.text, text), "\(codec)")
            XCTAssertEqual(read.extras, .empty, "\(codec)")
            XCTAssertEqual(imageData(read.text), imagePNG, "\(codec)")
        }
    }

    func testNoteItDocIsOneSelfContainedFile() throws {
        let text = try fullNote()
        let first = dir.appendingPathComponent("first", isDirectory: true)
        let second = dir.appendingPathComponent("second", isDirectory: true)
        try fm.createDirectory(at: first, withIntermediateDirectories: true)
        try fm.createDirectory(at: second, withIntermediateDirectories: true)
        let url = first.appendingPathComponent("note.noteitdoc")
        try BodyCodec.noteItDoc.write(text, to: url)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: first.path), ["note.noteitdoc"])

        let moved = second.appendingPathComponent("note.noteitdoc")
        try fm.moveItem(at: url, to: moved)
        let read = try BodyCodec.noteItDoc.read(at: moved)
        XCTAssertEqual(imageData(read.text), imagePNG)
        XCTAssertTrue(BodyCodec.semanticallyEqual(read.text, text))
    }

    func testExtrasSurviveEdit() throws {
        let extras = ContainerExtras(frontMatter: "title: Trip\ntags: [a, b]", extra: ["futureKey": .number("9007199254740993")])
        let url = dir.appendingPathComponent("note.noteitdoc")
        try BodyCodec.noteItDoc.write(try fullNote(), extras: extras, to: url)

        for edit in ["Edited body", ""] {
            let read = try BodyCodec.noteItDoc.read(at: url)
            XCTAssertEqual(read.extras, extras)
            let edited = NSAttributedString(string: edit)
            try BodyCodec.noteItDoc.write(edited, extras: read.extras, to: url)
            let written = try Data(contentsOf: url)
            let json = String(decoding: written, as: UTF8.self)
            XCTAssertTrue(json.contains("9007199254740993"), json)
            XCTAssertFalse(json.contains("9007199254740992"), json)
            XCTAssertEqual(try BodyContainer.decode(written).frontMatter, extras.frontMatter)
            XCTAssertEqual(try BodyCodec.noteItDoc.read(at: url).extras, extras)
            XCTAssertEqual(try BodyCodec.noteItDoc.data(of: edited, extras: read.extras), written)
            XCTAssertEqual(try BodyCodec.noteItDoc.read(at: url).text.string.trimmingCharacters(in: .newlines), edit)
        }

        let container = try BodyCodec.noteItDoc(of: try fullNote(), extras: extras)
        XCTAssertEqual(container.extras, extras)
        XCTAssertEqual(try BodyCodec.attributedString(from: container).extras, extras)
    }

    func testRTFDIgnoresExtras() throws {
        let text = try fullNote()
        let extras = ContainerExtras(frontMatter: "title: x", extra: ["futureKey": .number("1")])
        XCTAssertEqual(try BodyCodec.rtfd.data(of: text, extras: extras), try BodyCodec.rtfd.data(of: text, extras: .empty))

        let url = dir.appendingPathComponent("note.rtfd")
        try BodyCodec.rtfd.write(text, extras: extras, to: url)
        XCTAssertEqual(try BodyCodec.rtfd.read(at: url).extras, .empty)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: dir.path), ["note.rtfd"])
    }

    func testRTFDWritesTheLibraryPackage() throws {
        let text = try fullNote()
        let viaCodec = dir.appendingPathComponent("codec.rtfd")
        let viaStorage = dir.appendingPathComponent("storage.rtfd")
        try BodyCodec.rtfd.write(text, to: viaCodec)
        try RTFDBodyStorage.installBody(RTFDBodyStorage.writeTempBody(text, in: dir), at: viaStorage)
        XCTAssertEqual(try RTFDBodyStorage.packageDigest(at: viaCodec), try RTFDBodyStorage.packageDigest(at: viaStorage))
    }

    func testSemanticallyEqualSeesOneCharacter() throws {
        let text = try fullNote()
        XCTAssertTrue(BodyCodec.semanticallyEqual(text, NSAttributedString(attributedString: text)))
        let changed = NSMutableAttributedString(attributedString: text)
        let range = (changed.string as NSString).range(of: "Body text")
        changed.replaceCharacters(in: NSRange(location: range.location, length: 1), with: "b")
        XCTAssertFalse(BodyCodec.semanticallyEqual(text, changed))
    }

    // MARK: Helpers

    private lazy var imagePNG: Data = {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 3, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.setColor(.red, atX: 1, y: 1)
        return rep.representation(using: .png, properties: [:])!
    }()

    /// Every BlockKind, code in two languages, a list, a table and an image. Alignment is explicit because RTF stores
    /// natural alignment as left, which the noteit-doc export then writes out.
    private func fullNote() throws -> NSAttributedString {
        let sha = SHA256.hash(data: imagePNG).map { String(format: "%02x", $0) }.joined()
        func text(_ s: String) -> [Inline] { [.text(s, marks: [])] }
        func cell(_ s: String, header: Bool = false) -> TableCell {
            TableCell(header: header, content: [.paragraph(align: .left, indent: nil, content: text(s))])
        }
        let blocks: [DocNode] = [
            .heading(level: 1, align: .left, indent: nil, content: text("Title")),
            .heading(level: 2, align: .left, indent: nil, content: text("Heading")),
            .heading(level: 3, align: .left, indent: nil, content: text("Subheading")),
            .paragraph(align: .left, indent: nil, content: text("Body text")),
            .codeBlock(align: .left, language: "swift", content: text("let x = 1")),
            .codeBlock(align: .left, language: "python", content: text("x = 1")),
            .blockquote(indent: nil, content: [.paragraph(align: .left, indent: nil, content: text("Quote"))]),
            .horizontalRule,
            .listItem(kind: .bullet, level: 0, number: nil, checked: nil, align: .left, content: text("Item")),
            .listItem(kind: .task, level: 0, number: nil, checked: true, align: .left, content: text("Done")),
            .table(columnWidths: nil, rows: [[cell("A", header: true), cell("B", header: true)], [cell("1"), cell("2")]]),
            .paragraph(align: .left, indent: nil, content: [.image(sha: sha, name: "dot.png", mime: "image/png", width: nil)]),
        ]
        let container = BodyContainer(doc: .doc(blocks), attachments: [sha: Attachment(mime: "image/png", name: "dot.png", data: imagePNG)])
        let result = try DocConverter.importDocument(container, styles: AppDocStyleProvider.shared)
        let kinds = Set(paragraphKinds(result))
        XCTAssertEqual(kinds, Set(BlockKind.allCases), "fixture must cover every BlockKind")
        XCTAssertNotNil(imageData(result))
        return result
    }

    private func paragraphKinds(_ text: NSAttributedString) -> [BlockKind] {
        let ns = text.string as NSString
        var kinds: [BlockKind] = []
        var location = 0
        while location < ns.length {
            let range = ns.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(range)
            let style = text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            let font = text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            kinds.append(EditorStyle.blockKind(paragraphStyle: style, font: font))
        }
        return kinds
    }

    private func imageData(_ text: NSAttributedString) -> Data? {
        var found: Data?
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let wrapper = (value as? NSTextAttachment)?.fileWrapper, let data = wrapper.regularFileContents { found = data }
        }
        return found
    }
}
