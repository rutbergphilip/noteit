import NoteItDoc
import XCTest

final class BodyContainerTests: XCTestCase {
    private let emptyDoc = #""doc":{"content":[],"type":"doc"}"#

    func testFrontMatterAndUnknownKeysSurviveAReencode() throws {
        let body = #"{"attachments":{},"#  + emptyDoc + #","format":"noteit-doc","frontMatter":"title: A\ntags: [x]","#
            + #""future":{"list":[true,null,"s/t"]},"version":1}"#
        let container = try BodyContainer.decode(Data(body.utf8))
        XCTAssertEqual(container.frontMatter, "title: A\ntags: [x]")
        XCTAssertEqual(container.extra["future"], .object(["list": .array([.bool(true), .null, .string("s/t")])]))
        XCTAssertEqual(String(decoding: try container.encoded(), as: UTF8.self), body)
    }

    func testDefaultsAndMissingAttachments() throws {
        let container = BodyContainer(doc: .doc([]))
        XCTAssertEqual(container.format, "noteit-doc")
        XCTAssertEqual(container.version, 1)
        XCTAssertEqual(BodyContainer.fileExtension, "noteitdoc")
        XCTAssertEqual(String(decoding: try container.encoded(), as: UTF8.self),
                       #"{"attachments":{},"# + emptyDoc + #","format":"noteit-doc","version":1}"#)
        let decoded = try BodyContainer.decode(Data((#"{"# + emptyDoc + #","format":"noteit-doc","version":1}"#).utf8))
        XCTAssertEqual(decoded, container)
    }

    func testAttachmentDataIsBase64() throws {
        let data = Data("hello".utf8)
        let container = BodyContainer(doc: .doc([]), attachments: ["k": Attachment(mime: "text/plain", name: "a.txt", data: data)])
        let text = String(decoding: try container.encoded(), as: UTF8.self)
        XCTAssertTrue(text.contains(#""attachments":{"k":{"data":"aGVsbG8=","mime":"text/plain","name":"a.txt"}}"#), text)
        XCTAssertEqual(try BodyContainer.decode(Data(text.utf8)), container)
    }

    func testSettingExtrasReplacesOnlyFrontMatterAndExtra() throws {
        var container = BodyContainer(doc: .doc([.horizontalRule]),
                                      attachments: ["k": Attachment(mime: "text/plain", name: "a.txt", data: Data([1]))],
                                      frontMatter: "old")
        container.extra = ["a": .number("1")]
        container.extras = ContainerExtras(frontMatter: nil, extra: ["b": .string("x")])
        XCTAssertNil(container.frontMatter)
        XCTAssertEqual(container.extra, ["b": .string("x")])
        XCTAssertEqual(container.doc, .doc([.horizontalRule]))
        XCTAssertEqual(container.attachments.keys.sorted(), ["k"])
        XCTAssertEqual(container.extras, ContainerExtras(frontMatter: nil, extra: ["b": .string("x")]))
        XCTAssertEqual(ContainerExtras.empty, ContainerExtras(frontMatter: nil, extra: [:]))
    }

    func testNumberTokensAreKeptVerbatim() throws {
        let body = #"{"attachments":{},"# + emptyDoc + #","format":"noteit-doc","n":[9007199254740993,1.50,-0,1e+400],"version":1}"#
        let container = try BodyContainer.decode(Data(body.utf8))
        XCTAssertEqual(container.extra["n"], .array([.number("9007199254740993"), .number("1.50"), .number("-0"), .number("1e+400")]))
        XCTAssertEqual(String(decoding: try container.encoded(), as: UTF8.self), body)

        let object = #"{"a":9007199254740993,"b":1.50,"c":-0}"#
        XCTAssertEqual(String(decoding: try JSONValue.decode(Data(object.utf8)).encoded(), as: UTF8.self), object)
    }

    func testNonNumberTokensFail() {
        for token in ["01", "NaN", "-", "1.", ".5", "+1", "Infinity", "0x10", "1e"] {
            let body = #"{"attachments":{},"# + emptyDoc + #","format":"noteit-doc","n":"# + token + #","version":1}"#
            XCTAssertThrowsError(try BodyContainer.decode(Data(body.utf8)), token)
            XCTAssertThrowsError(try JSONValue.decode(Data((#"{"n":"# + token + "}").utf8)), token)
        }
        XCTAssertThrowsError(try JSONValue.number("01").encoded())
    }

    func testMalformedJSONFails() {
        for text in [#"{"a":1,"a":2}"#, #"{"a":1"#, #"{"a":1} x"#, #"{'a':1}"#, "[1,]", ""] {
            XCTAssertThrowsError(try JSONValue.decode(Data(text.utf8)), text)
        }
        XCTAssertThrowsError(try BodyContainer.decode(Data(#"{"format":"noteit-doc","version":1}"#.utf8)))
    }

    func testStringsEscapeLikeJSONEncoderWithoutSlashes() throws {
        let value = JSONValue.string("a/b \"q\" \\ \n\t\u{1} é 😀")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        XCTAssertEqual(try value.encoded(), try encoder.encode("a/b \"q\" \\ \n\t\u{1} é 😀"))
        XCTAssertEqual(try JSONValue.decode(try value.encoded()), value)
    }

    func testNestedCodableUsesDecimal() throws {
        let container = BodyContainer(doc: .doc([]))
        let data = try JSONEncoder().encode(["body": container])
        XCTAssertEqual(try JSONDecoder().decode([String: BodyContainer].self, from: data)["body"], container)
    }
}
