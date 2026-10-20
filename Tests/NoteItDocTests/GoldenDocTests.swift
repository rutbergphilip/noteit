import NoteItDoc
import NoteItDocTestSupport
import XCTest

final class GoldenDocTests: XCTestCase {
    private struct ValidateCase: Codable {
        enum Expect: Codable, Equatable {
            case valid, readOnly(String)

            init(from decoder: Decoder) throws {
                if let value = try? decoder.singleValueContainer().decode(String.self), value == "valid" {
                    self = .valid
                } else {
                    self = .readOnly(try decoder.singleValueContainer().decode([String: String].self)["readOnly"] ?? "")
                }
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case .valid: try container.encode("valid")
                case .readOnly(let reason): try container.encode(["readOnly": reason])
                }
            }
        }

        var name: String
        var container: BodyContainer
        var expect: Expect
    }

    func testDocValidateVectors() throws {
        let file = try GoldenFixtures.load("doc-validate.json", as: GoldenFile<ValidateCase>.self)
        XCTAssertEqual(file.version, 1)
        XCTAssertGreaterThanOrEqual(file.cases.count, 14)
        for vector in file.cases {
            switch (vector.expect, DocValidation.validate(vector.container)) {
            case (.valid, .valid), (.readOnly, .readOnly): break
            case (let expected, let actual): XCTFail("\(vector.name): expected \(expected), got \(actual)")
            }
        }
    }

    func testRandomDocumentsRoundTripAndValidate() throws {
        for seed in 0..<500 as Range<UInt64> {
            var generator = RandomDocGenerator(seed: seed)
            let container = generator.next()
            let bytes = try container.encoded()
            XCTAssertEqual(try BodyContainer.decode(bytes), container, "seed \(seed)")
            XCTAssertEqual(DocValidation.validate(container), .valid, "seed \(seed)")
        }
    }

    func testTheSameSeedGivesTheSameDocument() throws {
        var a = RandomDocGenerator(seed: 42), b = RandomDocGenerator(seed: 42)
        XCTAssertEqual(try a.next().encoded(), try b.next().encoded())
        XCTAssertEqual(try a.next().encoded(), try b.next().encoded())
    }

    func testRandomDocumentsWithUnknownNodes() throws {
        var unknownSeen = 0
        for seed in 0..<500 as Range<UInt64> {
            var generator = RandomDocGenerator(seed: seed, includeUnknown: true)
            let container = generator.next()
            let bytes = try container.encoded()
            let decoded = try BodyContainer.decode(bytes)
            XCTAssertEqual(decoded, container, "seed \(seed)")
            XCTAssertEqual(try decoded.encoded(), bytes, "seed \(seed)")
            let hasUnknown = containsUnknown(container.doc)
            if hasUnknown { unknownSeen += 1 }
            switch DocValidation.validate(container) {
            case .valid: XCTAssertFalse(hasUnknown, "seed \(seed)")
            case .readOnly(let reason): XCTAssertTrue(hasUnknown, "seed \(seed): \(reason)")
            }
        }
        XCTAssertGreaterThan(unknownSeen, 50)
    }

    func testUnknownNodesAtTopLevelAndInsideABlockquote() throws {
        let body = #"{"attachments":{},"doc":{"content":[{"attrs":{"n":1.50},"type":"callout"},"#
            + #"{"content":[{"type":"paragraph"},{"content":[{"text":"x","type":"text"}],"type":"mathBlock"}],"type":"blockquote"}],"#
            + #""type":"doc"},"format":"noteit-doc","version":1}"#
        let container = try BodyContainer.decode(Data(body.utf8))
        guard case .doc(let blocks) = container.doc, blocks.count == 2,
              case .unknown(let topType, let topJSON) = blocks[0],
              case .blockquote(_, let quoted) = blocks[1], quoted.count == 2,
              case .unknown(let innerType, let innerJSON) = quoted[1] else { return XCTFail("\(container.doc)") }
        XCTAssertEqual(topType, "callout")
        XCTAssertEqual(String(decoding: topJSON, as: UTF8.self), #"{"attrs":{"n":1.50},"type":"callout"}"#)
        XCTAssertEqual(innerType, "mathBlock")
        XCTAssertEqual(String(decoding: innerJSON, as: UTF8.self), #"{"content":[{"text":"x","type":"text"}],"type":"mathBlock"}"#)
        XCTAssertEqual(String(decoding: try container.encoded(), as: UTF8.self), body)
        guard case .readOnly = DocValidation.validate(container) else { return XCTFail("expected read-only") }
    }

    func testWritingIsOffByDefault() {
        guard !GoldenFixtures.isWriting else { return }
        XCTAssertThrowsError(try GoldenFixtures.write(GoldenFile<String>(generator: "swift", cases: []), to: "never-written.json"))
    }

    private func containsUnknown(_ node: DocNode) -> Bool {
        switch node {
        case .unknown: return true
        case .doc(let children), .blockquote(_, let children): return children.contains(where: containsUnknown)
        case .table(_, let rows): return rows.joined().contains { $0.content.contains(where: containsUnknown) }
        default: return false
        }
    }
}
