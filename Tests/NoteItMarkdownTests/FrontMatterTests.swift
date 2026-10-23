import XCTest
@testable import NoteItMarkdown

final class FrontMatterTests: XCTestCase {
    private let specExample = """
    ---
    id: 6F1C2E9A-6B0D-4E43-9B5C-1E0F5D7B9A11
    created: 2026-10-19T09:12:44Z
    updated: 2026-10-19T10:03:02Z
    pinned: true
    ---

    """

    private func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    func testSpecExampleRoundTripsByteForByte() throws {
        let (front, bodyStart) = try FrontMatter.read(specExample + "# Plan\n")
        XCTAssertEqual(front.id, UUID(uuidString: "6F1C2E9A-6B0D-4E43-9B5C-1E0F5D7B9A11"))
        XCTAssertEqual(front.created, date("2026-10-19T09:12:44Z"))
        XCTAssertEqual(front.updated, date("2026-10-19T10:03:02Z"))
        XCTAssertTrue(front.pinned)
        XCTAssertEqual(front.written(), specExample)
        XCTAssertEqual(String((specExample + "# Plan\n")[bodyStart...]), "# Plan\n")
    }

    func testPinnedFalseIsNeverWritten() {
        let front = FrontMatter(id: UUID(), created: Date(timeIntervalSince1970: 0), pinned: false)
        XCTAssertFalse(front.written().contains("pinned"))
    }

    func testOptionalKeysOnlyWhenSet() throws {
        let plain = FrontMatter(id: UUID(), created: Date(timeIntervalSince1970: 0), updated: Date(timeIntervalSince1970: 60))
        for key in ["deleted", "conflict-of", "conflict-source", "locked"] {
            XCTAssertFalse(plain.written().contains(key), key)
        }
        let original = UUID()
        let conflict = FrontMatter(id: UUID(), deleted: date("2026-10-20T08:00:00Z"), conflictOf: original,
                                   conflictSource: "Outside NoteIt")
        let text = conflict.written()
        XCTAssertTrue(text.contains("deleted: 2026-10-20T08:00:00Z\n"))
        XCTAssertTrue(text.contains("conflict-of: \(original.uuidString)\n"))
        XCTAssertTrue(text.contains("conflict-source: \"Outside NoteIt\"\n"))
        let (read, _) = try FrontMatter.read(text)
        XCTAssertEqual(read, conflict)
    }

    func testUnknownKeysAreKeptVerbatimAndInOrder() throws {
        let text = """
        ---
        cssclasses: wide
        id: 6F1C2E9A-6B0D-4E43-9B5C-1E0F5D7B9A11
        aliases:
          - Plan for Q4
          - "Q4: plan"
        publish: false   # keep spacing
        ---
        Body

        """
        let (front, _) = try FrontMatter.read(text)
        XCTAssertEqual(front.extra, "cssclasses: wide\naliases:\n  - Plan for Q4\n  - \"Q4: plan\"\npublish: false   # keep spacing")
        let (again, _) = try FrontMatter.read(front.written())
        XCTAssertEqual(again, front)
    }

    func testTagsAreReadFromFlowAndBlockLists() throws {
        let (flow, _) = try FrontMatter.read("---\ntags: [a, b]\n---\n")
        XCTAssertEqual(flow.tags, ["a", "b"])
        let (block, _) = try FrontMatter.read("---\ntags:\n  - work\n  - \"#home\"\n---\n")
        XCTAssertEqual(block.tags, ["work", "home"])
        XCTAssertEqual(block.extra, "tags:\n  - work\n  - \"#home\"", "a foreign file keeps its tags verbatim")
        XCTAssertFalse(FrontMatter(id: UUID(), tags: ["work"]).written().contains("tags"), "the tags property is never written")
    }

    func testNoFrontMatterIsEmpty() throws {
        let text = "# Title\n\nBody\n"
        let (front, bodyStart) = try FrontMatter.read(text)
        XCTAssertEqual(front, .empty)
        XCTAssertEqual(bodyStart, text.startIndex)
        XCTAssertEqual(FrontMatter.empty.written(), "")
        XCTAssertEqual(try FrontMatter.read("").0, .empty)
    }

    func testDashesNotOnLineOneAreBody() throws {
        let text = "Intro\n---\nid: 6F1C2E9A-6B0D-4E43-9B5C-1E0F5D7B9A11\n---\n"
        let (front, bodyStart) = try FrontMatter.read(text)
        XCTAssertEqual(front, .empty)
        XCTAssertEqual(bodyStart, text.startIndex)
    }

    func testUnterminatedBlockThrows() {
        XCTAssertThrowsError(try FrontMatter.read("---\nid: 6F1C2E9A-6B0D-4E43-9B5C-1E0F5D7B9A11\n")) { error in
            XCTAssertEqual(error as? MarkdownError, .invalidFrontMatter(line: 1))
        }
        XCTAssertThrowsError(try FrontMatter.read("---\nid: 6F1C2E9A-6B0D-4E43-9B5C-1E0F5D7B9A11\nBody text\n")) { error in
            XCTAssertEqual(error as? MarkdownError, .invalidFrontMatter(line: 3))
        }
        XCTAssertThrowsError(try FrontMatter.read("---\nid: not-a-uuid\n---\n")) { error in
            XCTAssertEqual(error as? MarkdownError, .invalidFrontMatter(line: 2))
        }
    }

    func testCRLFIsRead() throws {
        let text = "---\r\nid: 6F1C2E9A-6B0D-4E43-9B5C-1E0F5D7B9A11\r\naliases: x\r\npinned: true\r\n---\r\nBody\r\n"
        let (front, bodyStart) = try FrontMatter.read(text)
        XCTAssertEqual(front.id, UUID(uuidString: "6F1C2E9A-6B0D-4E43-9B5C-1E0F5D7B9A11"))
        XCTAssertTrue(front.pinned)
        XCTAssertEqual(front.extra, "aliases: x")
        XCTAssertEqual(String(text[bodyStart...]), "Body\r\n")
    }

    func testDatesWithoutZoneAreUTC() throws {
        let (front, _) = try FrontMatter.read("---\ncreated: 2026-10-19T09:12:44\nupdated: 2026-10-19\n---\n")
        XCTAssertEqual(front.created, date("2026-10-19T09:12:44Z"))
        XCTAssertEqual(front.updated, date("2026-10-19T00:00:00Z"))
    }

    func testLockedIsWrittenOnlyWhenSetAndIsInformational() throws {
        XCTAssertFalse(FrontMatter(id: UUID()).written().contains("locked"))
        let placeholder = FrontMatter(id: UUID(), locked: true)
        XCTAssertTrue(placeholder.written().contains("\nlocked: true\n"))
        let (read, _) = try FrontMatter.read("---\nlocked: true\n---\n")
        XCTAssertTrue(read.locked)
        XCTAssertEqual(read.extra, "", "never kept as an unknown key")
        XCTAssertNil(read.id)
    }

    // MARK: Untrusted extras (synced noteit-doc containers)

    func testWrittenNeverLetsExtraOverrideOwnedKeys() throws {
        let id = UUID()
        var fm = FrontMatter(id: id, pinned: false)
        fm.extra = "source: web\nid: 00000000-0000-0000-0000-000000000000\npinned: true\nconflict-of: x\n  continued\n---\nlocked: yes\naliases:\n  - a"
        let text = fm.written()
        XCTAssertEqual(text, "---\nid: \(id.uuidString)\nsource: web\naliases:\n  - a\n---\n")
        let (read, _) = try FrontMatter.read(text + "body")
        XCTAssertEqual(read.id, id)
        XCTAssertFalse(read.pinned)
        XCTAssertFalse(read.locked)
    }

    func testSanitizedExtraDropsOwnedKeysAndDelimiters() throws {
        let remote = "id: 00000000-0000-0000-0000-000000000000\ncreated: 2020-01-01\nsource: web\n---\ndeleted: 2020-01-02\n...\ntags: [a, b]"
        XCTAssertEqual(try FrontMatter.sanitizedExtra(remote), "source: web\ntags: [a, b]")
        XCTAssertEqual(try FrontMatter.sanitizedExtra("---\n..."), "")
    }

    /// Security review: no line break other than "\n" may hide a key or a delimiter from the filter.
    static let otherLineBreaks: [(String, String)] = [
        ("CR", "\r"), ("CRLF", "\r\n"), ("NEL", "\u{85}"), ("LS", "\u{2028}"), ("PS", "\u{2029}"), ("VT", "\u{0B}"), ("FF", "\u{0C}"),
    ]

    func testSanitizedExtraRejectsOtherLineBreaks() {
        for (name, separator) in Self.otherLineBreaks {
            XCTAssertThrowsError(try FrontMatter.sanitizedExtra("source: web\(separator)id: 00000000-0000-0000-0000-000000000000"), name)
            XCTAssertThrowsError(try FrontMatter.sanitizedExtra("source: web\(separator)---\(separator)pinned: true"), name)
        }
        XCTAssertEqual(try FrontMatter.sanitizedExtra("source: web\nkind: note"), "source: web\nkind: note")
    }

    func testWrittenSplitsOnEveryLineBreak() throws {
        let id = UUID()
        for (name, separator) in Self.otherLineBreaks {
            var fm = FrontMatter(id: id)
            fm.extra = "source: web\(separator)pinned: true\(separator) --- \(separator)created: 2020-01-01"
            let text = fm.written()
            XCTAssertEqual(text, "---\nid: \(id.uuidString)\nsource: web\n---\n", name)
            XCTAssertFalse(text.contains("pinned"), name)
        }
    }

    func testSanitizedExtraRejectsInvalidFrontMatter() {
        XCTAssertThrowsError(try FrontMatter.sanitizedExtra("this is not front matter"))
        XCTAssertThrowsError(try FrontMatter.sanitizedExtra("created: not-a-date"))
    }
}
