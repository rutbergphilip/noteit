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

    func testHardWrappedParagraphEditAddsNoBackslashes() throws {
        let url = dir.appendingPathComponent("note.md")
        try Data("One two\nthree four\n".utf8).write(to: url)
        let (_, view) = NoteItTextView.make()
        view.storage.setAttributedString(try BodyCodec.markdown.read(at: url).text)
        view.normalizePendingEdits()
        XCTAssertEqual(view.string, "One two\u{2028}three four\n")
        view.insertText("2", replacementRange: NSRange(location: 4, length: 3))
        view.setSelectedRange(NSRange(location: 6, length: 0))
        view.insertText("x", replacementRange: view.selectedRange())
        view.insertLineBreak(nil)
        try BodyCodec.markdown.write(view.attributedString(), to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "One 2\nx\\\nthree four\n")
    }

    func testTypingOverASoftBreakWritesAHardBreak() throws {
        let url = dir.appendingPathComponent("note.md")
        try Data("One two\nthree four\n".utf8).write(to: url)
        let (_, view) = NoteItTextView.make()
        view.storage.setAttributedString(try BodyCodec.markdown.read(at: url).text)
        view.normalizePendingEdits()
        view.setSelectedRange(NSRange(location: 7, length: 3))
        XCTAssertNil(view.typingAttributes[.noteItSoftBreak])
        view.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.insertLineBreak(nil)
        XCTAssertEqual(view.string, "One twox\u{2028}ree four\n")
        XCTAssertNil(view.storage.attribute(.noteItSoftBreak, at: 7, effectiveRange: nil))
        XCTAssertNil(view.storage.attribute(.noteItSoftBreak, at: 8, effectiveRange: nil))
        try BodyCodec.markdown.write(view.attributedString(), to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "One twox\\\nree four\n")
    }

    func testFrontMatterSurvivesEdit() throws {
        let url = dir.appendingPathComponent("note.md")
        let known = "id: 6F1C2E9A-6B0D-4E43-9B5C-1E0F5D7B9A11\ncreated: 2026-10-19T09:12:44Z\npinned: true"
        let unknown = "aliases:\n  - Weekly\ncssclasses: [wide]"
        try Data("---\n\(known)\n\(unknown)\n---\n# Notes\n\nBody\n".utf8).write(to: url)
        for edit in ["Edited body", ""] {
            let read = try BodyCodec.markdown.read(at: url)
            XCTAssertEqual(read.extras.frontMatter, unknown)
            XCTAssertNil(try BodyCodec.noteItDoc(of: read.text, extras: read.extras).extra[BodyCodec.markdownFrontMatterKey])
            try BodyCodec.markdown.write(NSAttributedString(string: edit), extras: read.extras, to: url)
            let written = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(written.hasPrefix("---\n\(known)\n\(unknown)\n---\n"), written)
            XCTAssertEqual(try BodyCodec.markdown.read(at: url).text.string.trimmingCharacters(in: .newlines), edit)
        }
    }

    private func png(_ color: NSColor) throws -> Data {
        try XCTUnwrap(NSImage(size: NSSize(width: 2, height: 2), flipped: false) { rect in
            color.setFill()
            rect.fill()
            return true
        }.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) })
    }

    func testImagesOutsideTheNoteFolderAreNotRead() throws {
        let notes = dir.appendingPathComponent("notes", isDirectory: true)
        let attachments = notes.appendingPathComponent("_attachments", isDirectory: true)
        try fm.createDirectory(at: attachments, withIntermediateDirectories: true)
        try png(.red).write(to: dir.appendingPathComponent("secret.png"))
        try png(.blue).write(to: dir.appendingPathComponent("linked.png"))
        try fm.createSymbolicLink(at: attachments.appendingPathComponent("link.png"), withDestinationURL: dir.appendingPathComponent("linked.png"))
        try png(.green).write(to: attachments.appendingPathComponent("ok.png"))
        let url = notes.appendingPathComponent("note.md")
        try Data("![a](../secret.png) ![b](_attachments/link.png) ![c](_attachments/../../secret.png) ![d](_attachments/ok.png)\n".utf8)
            .write(to: url)
        let container = try BodyCodec.noteItDoc(of: try BodyCodec.markdown.read(at: url).text)
        XCTAssertEqual(container.attachments.values.map(\.data), [try png(.green)])
    }
}
