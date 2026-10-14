import XCTest
@testable import NoteIt

final class AppUpdaterTests: XCTestCase {
    private let app = URL(fileURLWithPath: "/Applications/NoteIt.app")
    private let info: [String: Any] = [
        "SUFeedURL": "https://example.com/appcast.xml",
        "SUPublicEDKey": "key",
    ]

    func testEnabledForAppBundleWithFeedAndKey() {
        XCTAssertTrue(AppUpdater.isUpdatingSupported(bundleURL: app, info: info))
    }

    func testDisabledOutsideAppBundle() {
        let debugDir = URL(fileURLWithPath: "/repo/.build/debug", isDirectory: true)
        XCTAssertFalse(AppUpdater.isUpdatingSupported(bundleURL: debugDir, info: info))
        XCTAssertFalse(AppUpdater.isUpdatingSupported(bundleURL: Bundle.main.bundleURL, info: Bundle.main.infoDictionary))
    }

    func testDisabledWithoutFeedOrKey() {
        XCTAssertFalse(AppUpdater.isUpdatingSupported(bundleURL: app, info: nil))
        XCTAssertFalse(AppUpdater.isUpdatingSupported(bundleURL: app, info: [:]))
        XCTAssertFalse(AppUpdater.isUpdatingSupported(bundleURL: app, info: ["SUFeedURL": "https://example.com/appcast.xml"]))
        XCTAssertFalse(AppUpdater.isUpdatingSupported(bundleURL: app, info: ["SUPublicEDKey": "key"]))
        XCTAssertFalse(AppUpdater.isUpdatingSupported(bundleURL: app, info: ["SUFeedURL": " ", "SUPublicEDKey": "key"]))
        XCTAssertFalse(AppUpdater.isUpdatingSupported(bundleURL: app, info: ["SUFeedURL": 1, "SUPublicEDKey": "key"]))
    }
}
