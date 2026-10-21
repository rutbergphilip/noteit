import AppKit
import XCTest
@testable import NoteIt
import NoteItCore

@MainActor
final class LinkIndexTests: XCTestCase {
    private func link(_ link: NoteLink, _ text: String = "x", at location: Int = 0) -> OutgoingLink {
        OutgoingLink(url: link.url, text: text, location: location, context: text)
    }

    func testSetAndRemoveUpdateReverseMaps() {
        let index = LinkIndex()
        let a = UUID(), b = UUID(), c = UUID()
        index.set([link(.note(id: b, heading: nil))], for: a)
        XCTAssertEqual(index.sources(linkingTo: b, title: "B"), [a])
        index.set([link(.note(id: c, heading: nil))], for: a)
        XCTAssertEqual(index.sources(linkingTo: b, title: "B"), [])
        XCTAssertEqual(index.sources(linkingTo: c, title: "C"), [a])
        index.remove(a)
        XCTAssertEqual(index.sources(linkingTo: c, title: "C"), [])
        XCTAssertFalse(index.hasEntry(for: a))
    }

    func testUnresolvedBacklinksByFoldedTitle() {
        let index = LinkIndex()
        let a = UUID(), target = UUID()
        index.set([link(.unresolved(title: "Café Plans", heading: nil))], for: a)
        XCTAssertEqual(index.sources(linkingTo: target, title: "cafe plans"), [a])
        XCTAssertEqual(index.sources(linkingTo: target, title: "Other"), [])
    }

    func testSnapshotLoadSkipsStaleEntries() {
        let index = LinkIndex()
        let a = UUID(), b = UUID(), target = UUID()
        let now = Date()
        index.set([link(.note(id: target, heading: nil))], for: a)
        index.set([link(.note(id: target, heading: nil))], for: b)
        let file = index.snapshot(updatedAt: [a: now, b: now])
        XCTAssertEqual(file.entries.count, 2)

        let fresh = LinkIndex()
        let missing = fresh.load(file, validFor: [a: now.addingTimeInterval(0.5), b: now.addingTimeInterval(5)])
        XCTAssertEqual(missing, [b])
        XCTAssertTrue(fresh.hasEntry(for: a))
        XCTAssertEqual(fresh.sources(linkingTo: target, title: ""), [a])
    }

    func testCorruptFileIsIgnored() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("link-index-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{not json".utf8).write(to: url)
        XCTAssertNil(LinkIndex.readFile(at: url))
        try Data(#"{"version":2,"entries":{}}"#.utf8).write(to: url)
        XCTAssertNil(LinkIndex.readFile(at: url))
    }
}
