import Foundation
import XCTest
@testable import NoteItCore

final class NotebookTreeTests: XCTestCase {
    private func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }

    private func node(_ n: Int, _ parent: Int?, _ name: String, sort: Int = 0) -> NotebookNodeInput {
        NotebookNodeInput(id: id(n), parentID: parent.map(id), sortIndex: sort, name: name)
    }

    private var sample: NotebookTree {
        NotebookTree([
            node(1, nil, "Work", sort: 1), node(2, 1, "Clients", sort: 0), node(3, 2, "Acme", sort: 0),
            node(4, nil, "Home", sort: 0), node(5, 1, "Admin", sort: 1),
        ])
    }

    func testRootsChildrenAndDepth() {
        let tree = sample
        XCTAssertEqual(tree.roots, [id(4), id(1)])
        XCTAssertEqual(tree.children(of: id(1)), [id(2), id(5)])
        XCTAssertEqual(tree.depth(of: id(3)), 3)
        XCTAssertEqual(tree.descendants(of: id(1)), [id(2), id(3), id(5)])
        XCTAssertEqual(tree.path(of: id(3)), ["Work", "Clients", "Acme"])
    }

    func testIDForPath() {
        let tree = sample
        XCTAssertEqual(tree.id(forPath: "work/clients"), id(2))
        XCTAssertEqual(tree.id(forPath: "Acme"), id(3))
        XCTAssertEqual(tree.id(forPath: "Work/Acme"), nil)
        XCTAssertNil(tree.id(forPath: "Nope"))
    }

    func testOrphanBecomesTopLevel() {
        let tree = NotebookTree([node(1, 99, "Orphan")])
        XCTAssertEqual(tree.roots, [id(1)])
        XCTAssertNil(tree.effectiveParent(of: id(1)))
    }

    func testCycleBrokenAtLowestUUID() {
        let tree = NotebookTree([node(3, 2, "C"), node(2, 1, "B"), node(1, 3, "A")])
        XCTAssertEqual(tree.roots, [id(1)])
        XCTAssertEqual(tree.effectiveParent(of: id(2)), id(1))
        XCTAssertEqual(tree.depth(of: id(3)), 3)
        XCTAssertEqual(NotebookTree([node(1, 1, "Self")]).roots, [id(1)])
    }

    func testCanMoveRespectsDepthAndCycles() {
        let tree = sample
        XCTAssertFalse(tree.canMove(id(1), under: id(3)))
        XCTAssertFalse(tree.canMove(id(1), under: id(1)))
        XCTAssertTrue(tree.canMove(id(4), under: id(3)))
        XCTAssertTrue(tree.canMove(id(3), under: nil))
        // Work holds three levels; under Home it would reach depth 4, under Acme depth 6.
        XCTAssertTrue(tree.canMove(id(1), under: id(4)))
        let deep = NotebookTree([node(1, nil, "A"), node(2, 1, "B"), node(3, 2, "C"), node(4, 3, "D"), node(5, nil, "E")])
        XCTAssertFalse(deep.canMove(id(5), under: id(4)))
        XCTAssertTrue(deep.canMove(id(5), under: id(3)))
    }

    func testFlattenedHonoursExpansion() {
        let tree = sample
        XCTAssertEqual(tree.flattened(expanded: nil).map(\.id), [id(4), id(1), id(2), id(3), id(5)])
        XCTAssertEqual(tree.flattened(expanded: [id(1)]).map(\.id), [id(4), id(1), id(2), id(5)])
        XCTAssertEqual(tree.flattened(expanded: []).map(\.depth), [1, 1])
    }
}
