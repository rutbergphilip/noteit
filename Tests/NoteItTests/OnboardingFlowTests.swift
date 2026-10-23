import XCTest
@testable import NoteIt

final class OnboardingFlowTests: XCTestCase {
    func testShowsOnlyOnAFreshLibraryNotYetFinished() {
        XCTAssertTrue(OnboardingFlow.shouldShowAutomatically(seededThisLaunch: true, completedVersion: 0))
        XCTAssertFalse(OnboardingFlow.shouldShowAutomatically(seededThisLaunch: true, completedVersion: OnboardingFlow.currentVersion))
        XCTAssertFalse(OnboardingFlow.shouldShowAutomatically(seededThisLaunch: false, completedVersion: 0), "upgrading users don't see it")
    }

    func testEachPathHasItsPages() {
        XCTAssertEqual(OnboardingFlow.pages(for: nil), [.welcome])
        XCTAssertEqual(OnboardingFlow.pages(for: .new), [.welcome, .hotkeys, .menuBar, .importNotes, .anotherMac, .done])
        XCTAssertEqual(OnboardingFlow.pages(for: .existing), [.welcome, .syncFirst, .hotkeys, .menuBar, .done])
        XCTAssertFalse(OnboardingFlow.pages(for: .existing).contains(.importNotes), "notes come from the other Mac")
    }
}
