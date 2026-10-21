import NoteItCore
import XCTest

final class TagTreeTests: XCTestCase {
    func testImpliedParentAndCounts() throws {
        let tree = TagTree.build(noteTags: [["work/acme"], ["work/acme", "work/beta"], ["work"], ["home"]])
        XCTAssertEqual(tree.map(\.path), ["home", "work"])
        let work = try XCTUnwrap(tree.last)
        XCTAssertEqual(work.ownCount, 1)
        XCTAssertEqual(work.totalCount, 3)
        XCTAssertEqual(work.children.map(\.name), ["acme", "beta"])
        XCTAssertEqual(work.children.map(\.totalCount), [2, 1])
    }

    func testDeepImpliedParents() throws {
        let tree = TagTree.build(noteTags: [["a/b/c"]])
        let a = try XCTUnwrap(tree.first)
        XCTAssertEqual(a.ownCount, 0)
        XCTAssertEqual(a.totalCount, 1)
        XCTAssertEqual(a.children.first?.children.first?.path, "a/b/c")
    }

    func testBuildFromCounts() {
        let tree = TagTree.build(counts: ["x/y": 2, "x": 1])
        XCTAssertEqual(tree.first?.totalCount, 3)
        XCTAssertEqual(tree.first?.children.first?.ownCount, 2)
    }

    func testMatchesDescendantsOnly() {
        XCTAssertTrue(TagTree.matches("work", selected: "work"))
        XCTAssertTrue(TagTree.matches("work/acme", selected: "work"))
        XCTAssertFalse(TagTree.matches("workshop", selected: "work"))
        XCTAssertFalse(TagTree.matches("work", selected: "work/acme"))
    }

    func testTagSelectionIncludesDescendants() {
        func note(_ tags: [String]) -> NoteMeta {
            NoteMeta(id: UUID(), title: "n", preview: "", isPinned: false, createdAt: Date(), updatedAt: Date(), tags: tags)
        }
        let acme = note(["work/acme"]), shop = note(["workshop"]), work = note(["work"])
        let ids = LibraryQuery.notes([acme, shop, work], for: .tag("work"), search: "", now: Date(), indexedText: { _ in nil }).map(\.id)
        XCTAssertEqual(Set(ids), [acme.id, work.id])
    }
}
