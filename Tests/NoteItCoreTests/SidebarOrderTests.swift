import NoteItCore
import XCTest

final class SidebarOrderTests: XCTestCase {
    func testLibraryRowsFollowProgramOrder() {
        XCTAssertEqual(
            SidebarLibraryRow.allCases,
            [.allNotes, .today, .tasks, .pinned, .recent, .conflicts, .recentlyDeleted]
        )
    }

    func testEveryFixedSelectionHasARow() {
        let fixed: [SidebarSelection] = [.allNotes, .pinned, .recent, .conflicts, .recentlyDeleted, .today, .tasks]
        for selection in fixed {
            XCTAssertNotNil(row(for: selection), "\(selection) has no library row")
        }
        XCTAssertNil(row(for: .smartFolder(UUID())))
        XCTAssertNil(row(for: .notebook(UUID())))
        XCTAssertNil(row(for: .tag("work")))
    }

    // Exhaustive so a new SidebarSelection case has to be placed here.
    private func row(for selection: SidebarSelection) -> SidebarLibraryRow? {
        switch selection {
        case .allNotes: return .allNotes
        case .today: return .today
        case .tasks: return .tasks
        case .pinned: return .pinned
        case .recent: return .recent
        case .conflicts: return .conflicts
        case .recentlyDeleted: return .recentlyDeleted
        case .smartFolder, .notebook, .tag: return nil
        }
    }
}
