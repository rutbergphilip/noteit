import AppKit
import NoteItDoc
import NoteItMarkdown
import XCTest
@testable import NoteIt

@MainActor
final class BodyCodecMarkdownTests: XCTestCase {
    private let fm = FileManager.default
    private var dir: URL!

    override func setUpWithError() throws {
        dir = fm.temporaryDirectory.appendingPathComponent("BodyCodecMarkdownTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: dir)
    }

    private func blockCount(_ text: NSAttributedString) throws -> Int {
        guard case .doc(let blocks) = try BodyCodec.noteItDoc(of: text).doc else { return 1 }
        return blocks.count
    }

    func testSeedNotesRoundTripInTheLibraryFlavour() async throws {
        let text = SeedData.welcomeBody()
        let markdown = try BodyCodec.markdown(of: text, profile: .library)
        let fallbacks = markdown.components(separatedBy: "<!-- noteit: ").filter { $0.contains("doc=") }.count
        XCTAssertLessThanOrEqual(fallbacks * 100, try blockCount(text), markdown)
        let (read, unresolved) = try await BodyCodec.attributedString(fromMarkdown: markdown, options: MarkdownImportOptions())
        XCTAssertEqual(unresolved, [])
        XCTAssertTrue(BodyCodec.semanticallyEqual(read, text), markdown)
    }

    func testPortableFlavourHasNoNoteItComments() throws {
        let text = NSMutableAttributedString(attributedString: SeedData.welcomeBody())
        text.append(EditorStyle.paragraph("Centered", kind: .body))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: text.length - 9, length: 8))
        XCTAssertTrue(try BodyCodec.markdown(of: text, profile: .library).contains("<!-- noteit"))
        let portable = try BodyCodec.markdown(of: text, profile: .portable)
        XCTAssertFalse(portable.contains("<!-- noteit"), portable)
        XCTAssertFalse(portable.contains("data-size"), portable)
    }

    func testEditorYellowHighlightIsDoubleEquals() throws {
        let yellow = try XCTUnwrap(EditorStyle.highlightColors.first { $0.name == "Yellow" }).color
        let text = NSMutableAttributedString(attributedString: EditorStyle.paragraph("Mark this", kind: .body))
        text.addAttribute(.backgroundColor, value: yellow, range: NSRange(location: 5, length: 4))
        XCTAssertEqual(try BodyCodec.markdown(of: text, profile: .library), "Mark ==this==\n")
        let other = try XCTUnwrap(EditorStyle.highlightColors.first { $0.name == "Green" }).color
        text.addAttribute(.backgroundColor, value: other, range: NSRange(location: 5, length: 4))
        XCTAssertEqual(try BodyCodec.markdown(of: text, profile: .library), "Mark <mark style=\"background-color: #C2F0B3\">this</mark>\n")
    }

    func testFileExtensionAndDataMatchTheWrittenFile() throws {
        XCTAssertEqual(BodyCodec.markdown.fileExtension, "md")
        let text = SeedData.welcomeBody()
        let extras = ContainerExtras(frontMatter: "aliases:\n  - Welcome")
        let url = dir.appendingPathComponent("note.md")
        try BodyCodec.markdown.write(text, extras: extras, to: url)
        XCTAssertEqual(try BodyCodec.markdown.data(of: text, extras: extras), try Data(contentsOf: url))
    }

    func testImagesAreWrittenBesideTheFile() throws {
        let png = try XCTUnwrap(NSImage(size: NSSize(width: 2, height: 2), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) })
        let attachment = NSTextAttachment(fileWrapper: FileWrapper(regularFileWithContents: png))
        attachment.fileWrapper?.preferredFilename = "dot.png"
        let text = NSMutableAttributedString(attributedString: EditorStyle.paragraph("Image:", kind: .body))
        text.insert(NSAttributedString(attachment: attachment), at: 6)
        let url = dir.appendingPathComponent("note.md")
        try BodyCodec.markdown.write(text, to: url)
        let markdown = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(markdown.contains("](_attachments/"), markdown)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: dir.appendingPathComponent("_attachments").path).count, 1)
        XCTAssertTrue(BodyCodec.semanticallyEqual(try BodyCodec.markdown.read(at: url).text, text))
    }

    func testFrontMatterExtrasSurviveEdit() throws {
        let url = dir.appendingPathComponent("note.md")
        try Data("---\naliases:\n  - Weekly\ncssclasses: [wide]\n---\n# Notes\n\nBody\n".utf8).write(to: url)
        for edit in ["Edited body", ""] {
            let read = try BodyCodec.markdown.read(at: url)
            XCTAssertEqual(read.extras, ContainerExtras(frontMatter: "aliases:\n  - Weekly\ncssclasses: [wide]"))
            try BodyCodec.markdown.write(NSAttributedString(string: edit), extras: read.extras, to: url)
            let written = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(written.hasPrefix("---\naliases:\n  - Weekly\ncssclasses: [wide]\n---\n"), written)
            XCTAssertEqual(try BodyCodec.markdown.read(at: url).text.string.trimmingCharacters(in: .newlines), edit)
        }
    }
}
