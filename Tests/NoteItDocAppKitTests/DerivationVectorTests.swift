import AppKit
import NoteItDoc
import NoteItDocAppKit
import NoteItDocTestSupport
import XCTest

/// `fixtures/golden/doc-convert.json`: noteit-docs as the converter writes them from the native corpus, their body
/// bytes and what they derive to. Written here under `NOTEIT_WRITE_VECTORS=1`; `@noteit/doc` decodes each body,
/// validates it, round-trips it through the ProseMirror schema and derives the same text (`derive.test.ts`).
final class DerivationVectorTests: XCTestCase {
    struct Derived: Codable, Equatable {
        var title: String
        var preview: String
        var tags: [String]
        var plainText: String
    }

    struct ConvertCase: Codable, Equatable {
        var name: String
        var doc: DocNode
        /// The container's UTF-8 JSON bytes, base64.
        var bodyBytes: String
        var derived: Derived
    }

    private static func derived(_ doc: DocNode) -> Derived {
        let (title, preview) = DocDerivation.titleAndPreview(of: doc)
        return Derived(title: title, preview: preview, tags: DocDerivation.tags(of: doc), plainText: DocDerivation.plainText(of: doc))
    }

    /// The native corpus: random documents and two fixed ones, each through the attributed string and back.
    private func corpus() throws -> [(String, BodyContainer)] {
        var sources: [(String, BodyContainer)] = []
        for seed in UInt64(1)...8 {
            var generator = RandomDocGenerator(seed: seed)
            sources.append(("random-\(seed)", generator.next()))
        }
        let code = DocNode.doc([
            .heading(level: 1, align: nil, indent: nil, content: [.text("Script #ops", marks: [])]),
            .codeBlock(align: nil, language: "swift", content: [.text("let tag = \"#notatag\"", marks: [])]),
            .codeBlock(align: nil, language: "swift", content: [.text("print(tag)", marks: [])]),
            .paragraph(align: nil, indent: nil, content: [.text("Runs on ", marks: []), .text("macOS", marks: [.bold])]),
        ])
        sources.append(("code-block-language", BodyContainer(doc: code)))
        let front = DocNode.doc([.paragraph(align: nil, indent: nil, content: [.text("Kept #front", marks: [])])])
        sources.append(("front-matter", BodyContainer(doc: front, frontMatter: "aliases: [kept]\nsource: obsidian")))

        return try sources.map { name, container in
            let text = try DocConverter.importDocument(container, styles: TestStyles())
            var exported = try DocConverter.export(text, styles: TestStyles())
            exported.frontMatter = container.frontMatter
            return (name, exported)
        }
    }

    func testDocConvertVectors() throws {
        let cases = try corpus().map { name, container in
            ConvertCase(name: name, doc: container.doc, bodyBytes: try container.encoded().base64EncodedString(),
                        derived: Self.derived(container.doc))
        }
        XCTAssertTrue(cases.contains { $0.name == "code-block-language" })
        if ProcessInfo.processInfo.environment["NOTEIT_WRITE_VECTORS"] == "1" {
            try GoldenFixtures.write(GoldenFile(generator: "swift", cases: cases), to: "doc-convert.json")
        }
        let stored = try GoldenFixtures.load("doc-convert.json", as: GoldenFile<ConvertCase>.self)
        XCTAssertEqual(stored.cases.map(\.name), cases.map(\.name))
        for (stored, fresh) in zip(stored.cases, cases) {
            XCTAssertEqual(stored, fresh, stored.name)
            let body = try BodyContainer.decode(try XCTUnwrap(Data(base64Encoded: stored.bodyBytes)))
            XCTAssertEqual(body.doc, stored.doc, stored.name)
        }
        let front = try XCTUnwrap(stored.cases.first { $0.name == "front-matter" })
        XCTAssertEqual(try BodyContainer.decode(Data(base64Encoded: front.bodyBytes)!).frontMatter, "aliases: [kept]\nsource: obsidian")
        guard case .doc(let blocks) = try XCTUnwrap(stored.cases.first { $0.name == "code-block-language" }).doc,
              case .codeBlock(_, let language, _) = blocks[1] else { return XCTFail("the code block is kept") }
        XCTAssertEqual(language, "swift")
    }
}
