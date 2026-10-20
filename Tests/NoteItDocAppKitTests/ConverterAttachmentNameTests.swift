import AppKit
import CryptoKit
import NoteItDoc
import NoteItDocAppKit
import XCTest

final class ConverterAttachmentNameTests: XCTestCase {
    func testAnEmptyNameImportsWithADefaultFileName() throws {
        XCTAssertEqual(try importedFileName(.image(sha: "", name: "", mime: "image/png", width: nil), mime: "image/png"), "image.png")
        XCTAssertEqual(try importedFileName(.attachment(sha: "", name: " ", mime: "application/pdf"), mime: "application/pdf"),
                       "attachment.pdf")
        XCTAssertEqual(try importedFileName(.attachment(sha: "", name: "", mime: "application/x-unknown-kind"),
                                            mime: "application/x-unknown-kind"), "attachment")
        XCTAssertEqual(try importedFileName(.attachment(sha: "", name: "Scan.pdf", mime: "application/pdf"), mime: "application/pdf"),
                       "Scan.pdf")
    }

    private func importedFileName(_ inline: Inline, mime: String) throws -> String? {
        let data = Data("bytes".utf8)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let item: Inline
        switch inline {
        case .image(_, let name, let mime, let width): item = .image(sha: sha, name: name, mime: mime, width: width)
        case .attachment(_, let name, let mime): item = .attachment(sha: sha, name: name, mime: mime)
        default: item = inline
        }
        let body = BodyContainer(doc: .doc([.paragraph(align: nil, indent: nil, content: [item])]),
                                 attachments: [sha: Attachment(mime: mime, name: "", data: data)])
        let text = try DocConverter.importDocument(body, styles: TestStyles())
        var found: String?
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let attachment = value as? NSTextAttachment { found = attachment.fileWrapper?.preferredFilename }
        }
        return found
    }
}
