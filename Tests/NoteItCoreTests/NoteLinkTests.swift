import Foundation
import NoteItCore
import XCTest

final class NoteLinkTests: XCTestCase {
    private let id = UUID(uuidString: "6F1C3A2E-9B4D-4E7A-8C21-0D5E7F9A1B3C")!

    func testNoteByID() throws {
        let link = try XCTUnwrap(NoteLink(url: URL(string: "noteit://note/\(id.uuidString)")!))
        XCTAssertEqual(link, .note(id: id, heading: nil))
        XCTAssertEqual(link.url.absoluteString, "noteit://note/\(id.uuidString)")
        XCTAssertNil(link.heading)
    }

    func testLowercaseUUIDAndSchemeAreAcceptedAndWrittenUppercase() throws {
        let link = try XCTUnwrap(NoteLink(url: URL(string: "NoteIt://NOTE/\(id.uuidString.lowercased())")!))
        XCTAssertEqual(link, .note(id: id, heading: nil))
        XCTAssertEqual(link.url.absoluteString, "noteit://note/\(id.uuidString)")
    }

    func testHeading() throws {
        let link = try XCTUnwrap(NoteLink(url: URL(string: "noteit://note/\(id.uuidString)?heading=Budget%202027")!))
        XCTAssertEqual(link, .note(id: id, heading: "Budget 2027"))
        XCTAssertEqual(link.heading, "Budget 2027")
        XCTAssertEqual(link.url.absoluteString, "noteit://note/\(id.uuidString)?heading=Budget%202027")
        XCTAssertEqual(link.withHeading(nil), .note(id: id, heading: nil))
        XCTAssertEqual(NoteLink.note(id: id, heading: nil).withHeading("A"), .note(id: id, heading: "A"))
    }

    func testTitleWithHeading() throws {
        let link = try XCTUnwrap(NoteLink(url: URL(string: "noteit://note?title=Weekly%20plan&heading=Mon")!))
        XCTAssertEqual(link, .unresolved(title: "Weekly plan", heading: "Mon"))
        XCTAssertEqual(link.url.absoluteString, "noteit://note?title=Weekly%20plan&heading=Mon")
        XCTAssertEqual(link.withHeading(nil), .unresolved(title: "Weekly plan", heading: nil))
    }

    func testPercentEncodingRoundTrips() {
        let samples = ["A & B = C", "1 + 1", "Ünïcødé 📝", "100%", "#tag?/x", "semi;colon"]
        for title in samples {
            let link = NoteLink.unresolved(title: title, heading: title)
            XCTAssertEqual(NoteLink(url: link.url), link, title)
        }
        XCTAssertEqual(NoteLink(url: NoteLink.note(id: id, heading: "a&b").url), .note(id: id, heading: "a&b"))
    }

    func testTextOverTheLimitIsRejected() {
        let ok = String(repeating: "a", count: NoteLink.maxTextLength)
        let long = ok + "a"
        XCTAssertNotNil(NoteLink(url: NoteLink.unresolved(title: ok, heading: ok).url))
        XCTAssertNil(NoteLink(url: NoteLink.unresolved(title: long, heading: nil).url))
        XCTAssertNil(NoteLink(url: NoteLink.note(id: id, heading: long).url))
    }

    func testOtherFormsAreRejected() {
        for raw in [
            "noteit://note/not-a-uuid",
            "noteit://note/\(id.uuidString)/extra",
            "noteit://note",
            "noteit://note?title=",
            "noteit://note/\(id.uuidString)?title=x",
            "noteit://note/\(id.uuidString)?foo=1",
            "noteit://note/\(id.uuidString)#frag",
            "noteit://open?id=\(id.uuidString)",
            "noteit://evil",
            "https://note/\(id.uuidString)",
        ] {
            XCTAssertNil(NoteLink(url: URL(string: raw)!), raw)
        }
    }

    func testLinkQuerySplitsTitleHeadingAndAlias() {
        XCTAssertEqual(LinkQuery("Plan#Mon|this week"), query("Plan", "Mon", "this week"))
        XCTAssertEqual(LinkQuery("Plan"), query("Plan", nil, nil))
        XCTAssertEqual(LinkQuery("Plan|alias#not heading"), query("Plan", nil, "alias#not heading"))
        XCTAssertEqual(LinkQuery("Plan#a#b"), query("Plan", "a#b", nil))
        XCTAssertEqual(LinkQuery(" Plan # |"), query("Plan", nil, nil))
        XCTAssertEqual(LinkQuery("#Mon"), query("", "Mon", nil))
    }

    private func query(_ title: String, _ heading: String?, _ alias: String?) -> LinkQuery {
        var value = LinkQuery("")
        value.title = title
        value.heading = heading
        value.alias = alias
        return value
    }
}
