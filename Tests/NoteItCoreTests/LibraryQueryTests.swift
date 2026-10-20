import NoteItCore
import XCTest

final class LibraryQueryTests: XCTestCase {
    private let day: TimeInterval = 24 * 60 * 60
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let work = UUID()

    private func note(
        _ title: String,
        preview: String = "",
        pinned: Bool = false,
        updatedDaysAgo: Double = 1,
        notebook: UUID? = nil,
        tags: [String] = [],
        conflictSource: String? = nil,
        deletedDaysAgo: Double? = nil
    ) -> NoteMeta {
        NoteMeta(
            id: UUID(), notebookID: notebook, title: title, preview: preview, isPinned: pinned,
            createdAt: now.addingTimeInterval(-100 * day), updatedAt: now.addingTimeInterval(-updatedDaysAgo * day),
            tags: tags, conflictSource: conflictSource,
            deletedAt: deletedDaysAgo.map { now.addingTimeInterval(-$0 * day) }
        )
    }

    private func titles(_ all: [NoteMeta], _ selection: SidebarSelection?, search: String = "",
                        indexedText: (UUID) -> String? = { _ in nil }) -> [String] {
        LibraryQuery.notes(all, for: selection, search: search, now: now, indexedText: indexedText).map(\.title)
    }

    func testPinnedFirstThenMostRecentlyUpdated() {
        let all = [note("Old", updatedDaysAgo: 5), note("Pinned old", pinned: true, updatedDaysAgo: 9),
                   note("New", updatedDaysAgo: 1), note("Pinned new", pinned: true, updatedDaysAgo: 2)]
        XCTAssertEqual(titles(all, .allNotes), ["Pinned new", "Pinned old", "New", "Old"])
        XCTAssertEqual(titles(all, nil), ["Pinned new", "Pinned old", "New", "Old"])
        XCTAssertEqual(titles(all, .pinned), ["Pinned new", "Pinned old"])
        XCTAssertEqual(LibraryQuery.count(all, for: .pinned, now: now), 2)
    }

    func testRecentlyDeletedNewestDeletionFirst() {
        let all = [note("Kept"), note("Deleted long ago", pinned: true, deletedDaysAgo: 20),
                   note("Deleted now", deletedDaysAgo: 1), note("Deleted mid", updatedDaysAgo: 0, deletedDaysAgo: 5)]
        XCTAssertEqual(titles(all, .recentlyDeleted), ["Deleted now", "Deleted mid", "Deleted long ago"])
        XCTAssertEqual(LibraryQuery.count(all, for: .recentlyDeleted, now: now), 3)
    }

    func testRecentIncludesExactlySevenDays() {
        let all = [note("Edge", updatedDaysAgo: 7), note("Too old", updatedDaysAgo: 7.0001)]
        XCTAssertEqual(LibraryQuery.recentInterval, 7 * day)
        XCTAssertEqual(titles(all, .recent), ["Edge"])
    }

    func testConflictsRequireConflictSource() {
        let all = [note("Copy", conflictSource: "Laptop"), note("Plain")]
        XCTAssertEqual(titles(all, .conflicts), ["Copy"])
    }

    func testTagAndNotebook() {
        let all = [note("Tagged", tags: ["home", "todo"]), note("Other tag", tags: ["homework"]),
                   note("In work", notebook: work), note("No notebook")]
        XCTAssertEqual(titles(all, .tag("home")), ["Tagged"])
        XCTAssertEqual(titles(all, .notebook(work)), ["In work"])
        XCTAssertEqual(LibraryQuery.count(all, for: .notebook(work), now: now), 1)
    }

    func testSearchRequiresEveryTermWithFolding() {
        let all = [note("Crème brûlée", preview: "Dessert recipe"), note("Creme soup", preview: "Starter"),
                   note("Recipe list")]
        XCTAssertEqual(titles(all, .allNotes, search: "CREME  recipe"), ["Crème brûlée"])
        XCTAssertEqual(titles(all, .allNotes, search: "brulee"), ["Crème brûlée"])
        XCTAssertEqual(titles(all, .allNotes, search: "   ").count, 3)
    }

    func testIndexedTextOverridesTitleAndPreview() {
        let indexed = note("Title words", preview: "preview words")
        let plain = note("Body only in title", updatedDaysAgo: 2)
        let all = [indexed, plain]
        let index: (UUID) -> String? = { $0 == indexed.id ? "folded body text" : nil }
        XCTAssertEqual(titles(all, .allNotes, search: "body", indexedText: index), ["Title words", "Body only in title"])
        XCTAssertEqual(titles(all, .allNotes, search: "title", indexedText: index), ["Body only in title"])
    }

    func testNewSelectionsAreEmpty() {
        let all = [note("A"), note("B", pinned: true, tags: ["x"])]
        for selection: SidebarSelection in [.today, .tasks, .smartFolder(UUID())] {
            XCTAssertEqual(titles(all, selection), [], "\(selection)")
            XCTAssertEqual(LibraryQuery.count(all, for: selection, now: now), 0, "\(selection)")
        }
    }

    func testDeletedNotesOnlyInRecentlyDeleted() {
        let gone = note("Gone", pinned: true, updatedDaysAgo: 0, notebook: work, tags: ["home"],
                        conflictSource: "Laptop", deletedDaysAgo: 1)
        let all = [gone]
        let selections: [SidebarSelection?] = [nil, .allNotes, .pinned, .recent, .conflicts, .notebook(work), .tag("home")]
        for selection in selections {
            XCTAssertEqual(titles(all, selection, search: "gone"), [], "\(String(describing: selection))")
        }
        XCTAssertEqual(titles(all, .recentlyDeleted, search: "gone"), ["Gone"])
    }
}
