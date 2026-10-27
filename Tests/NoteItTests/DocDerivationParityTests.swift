@testable import NoteIt
import NoteItDoc
import NoteItDocAppKit
import NoteItDocTestSupport
import XCTest

/// What `NoteStore` derives from a note's attributed string equals what `DocDerivation` (and so the web) derives
/// from the same note as a noteit-doc: every `derive.json` document and a random corpus.
@MainActor
final class DocDerivationParityTests: XCTestCase {
    private struct DeriveCase: Codable {
        var name: String
        var doc: DocNode
    }

    private func assertParity(_ container: BodyContainer, _ name: String) throws {
        let text = try DocConverter.importDocument(container, styles: AppDocStyleProvider.shared)
        let exported = try DocConverter.export(text, styles: AppDocStyleProvider.shared).doc
        XCTAssertEqual(NoteStore.previewLines(of: text), DocDerivation.lines(of: exported), "\(name): lines")
        let (title, preview) = DocDerivation.titleAndPreview(lines: NoteStore.previewLines(of: text))
        XCTAssertTrue(DocDerivation.titleAndPreview(of: exported) == (title, preview), "\(name): title and preview")
        XCTAssertEqual(NoteStore.parseTags(text), DocDerivation.tags(of: exported), "\(name): tags")
        // Importing ends the last paragraph with a newline too; the document has no trace of it.
        // (In a code block that newline is masked to a space.)
        func trimmed(_ string: String) -> String { text.string.hasSuffix("\n") ? String(string.dropLast()) : string }
        XCTAssertEqual(trimmed(text.string), DocDerivation.plainText(of: exported), "\(name): plain text")
        XCTAssertEqual(trimmed(NoteStore.maskedForTokens(text)), DocDerivation.maskedText(of: exported), "\(name): masked text")
        // The vector documents are already in the converter's normal form, so they derive the same before the round trip.
        XCTAssertTrue(DocDerivation.titleAndPreview(of: container.doc) == (title, preview), "\(name): original title and preview")
        XCTAssertEqual(DocDerivation.tags(of: container.doc), NoteStore.parseTags(text), "\(name): original tags")
    }

    func testTheDeriveVectorsDeriveAsTheMacDoes() throws {
        let file = try GoldenFixtures.load("derive.json", as: GoldenFile<DeriveCase>.self)
        XCTAssertGreaterThanOrEqual(file.cases.count, 40)
        for vector in file.cases {
            var container = BodyContainer(doc: vector.doc)
            // Image and attachment nodes need their bytes in the container to become attachments.
            container.attachments = Self.attachments(in: vector.doc)
            try assertParity(container, vector.name)
        }
    }

    func testARandomCorpusDerivesAsTheMacDoes() throws {
        for seed in UInt64(1)...200 {
            var generator = RandomDocGenerator(seed: seed)
            try assertParity(generator.next(), "seed \(seed)")
        }
    }

    private static func attachments(in doc: DocNode) -> [String: Attachment] {
        var found: [String: Attachment] = [:]
        func visit(_ node: DocNode) {
            switch node {
            case .doc(let content), .blockquote(_, let content): content.forEach(visit)
            case .paragraph(_, _, let content), .heading(_, _, _, let content), .codeBlock(_, _, let content),
                 .listItem(_, _, _, _, _, let content):
                for inline in content {
                    switch inline {
                    case .image(let sha, let name, let mime, _), .attachment(let sha, let name, let mime):
                        // derive.json's two objects hold these bytes.
                        found[sha] = Attachment(mime: mime, name: name, data: Data((mime == "image/png" ? "photo bytes" : "pdf bytes").utf8))
                    default: break
                    }
                }
            case .table(_, let rows): rows.flatMap { $0 }.flatMap(\.content).forEach(visit)
            default: break
            }
        }
        visit(doc)
        return found
    }
}
