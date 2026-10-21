@testable import NoteIt
import NoteItCore
import XCTest

final class SidebarOrderTests: XCTestCase {
    func testSectionsFollowProgramOrderWithRecentlyDeletedLast() {
        XCTAssertEqual(SidebarSection.visible(hasSmartFolders: true, hasTags: true, showsRecentlyDeleted: true),
                       [.library, .smartFolders, .notebooks, .tags, .recentlyDeleted])
    }

    func testEmptySectionsAreHidden() {
        XCTAssertEqual(SidebarSection.visible(hasSmartFolders: false, hasTags: false, showsRecentlyDeleted: false),
                       [.library, .notebooks])
        XCTAssertEqual(SidebarSection.visible(hasSmartFolders: true, hasTags: false, showsRecentlyDeleted: true),
                       [.library, .smartFolders, .notebooks, .recentlyDeleted])
    }

    func testLibraryRowsKeepTheirOrder() {
        XCTAssertEqual(SidebarLibraryRow.allCases, [.allNotes, .today, .tasks, .pinned, .recent, .conflicts, .recentlyDeleted])
    }
}
