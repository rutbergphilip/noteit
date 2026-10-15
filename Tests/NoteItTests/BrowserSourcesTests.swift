import AppKit
import XCTest
@testable import NoteIt

final class BrowserSourcesTests: XCTestCase {
    private let safari = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]
    private let chromium = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium",
        "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev", "com.microsoft.edgemac.Canary",
        "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
        "com.vivaldi.Vivaldi", "company.thebrowser.Browser",
    ]

    func testSupportedBundleIDs() {
        XCTAssertEqual(BrowserSources.supportedBundleIDs, Set(safari + chromium))
        XCTAssertFalse(BrowserSources.supportedBundleIDs.contains("org.mozilla.firefox"))
        XCTAssertFalse(BrowserSources.supportedBundleIDs.contains("com.operasoftware.Opera"))
    }

    func testSafariScripts() throws {
        for id in safari {
            let script = try XCTUnwrap(BrowserSources.appleScript(forBundleID: id))
            XCTAssertTrue(script.contains("if application id \"\(id)\" is running then"), id)
            XCTAssertTrue(script.contains("tell application id \"\(id)\""), id)
            XCTAssertTrue(script.contains("URL of current tab of front window"), id)
            XCTAssertTrue(script.contains("name of current tab of front window"), id)
            XCTAssertFalse(script.contains("active tab"), id)
            XCTAssertTrue(script.contains("pageURL & linefeed & pageTitle"), id)
        }
    }

    func testChromiumScripts() throws {
        for id in chromium {
            let script = try XCTUnwrap(BrowserSources.appleScript(forBundleID: id))
            XCTAssertTrue(script.contains("if application id \"\(id)\" is running then"), id)
            XCTAssertTrue(script.contains("tell application id \"\(id)\""), id)
            XCTAssertTrue(script.contains("URL of active tab of front window"), id)
            XCTAssertTrue(script.contains("title of active tab of front window"), id)
            XCTAssertFalse(script.contains("current tab"), id)
        }
    }

    func testRunningGuardWrapsTell() throws {
        let script = try XCTUnwrap(BrowserSources.appleScript(forBundleID: "com.google.Chrome"))
        let guardRange = try XCTUnwrap(script.range(of: "is running then"))
        let tellRange = try XCTUnwrap(script.range(of: "tell application id"))
        XCTAssertLessThan(guardRange.lowerBound, tellRange.lowerBound)
        XCTAssertFalse(script.contains("activate"))
        XCTAssertFalse(script.contains("launch"))
    }

    func testScriptsAreWrappedInShortTimeout() throws {
        for id in BrowserSources.supportedBundleIDs {
            let script = try XCTUnwrap(BrowserSources.appleScript(forBundleID: id))
            let open = try XCTUnwrap(script.range(of: "with timeout of 2 seconds"), id)
            let close = try XCTUnwrap(script.range(of: "end timeout"), id)
            let tell = try XCTUnwrap(script.range(of: "tell application id"), id)
            let running = try XCTUnwrap(script.range(of: "is running then"), id)
            XCTAssertLessThan(open.upperBound, running.lowerBound, id)
            XCTAssertLessThan(tell.upperBound, close.lowerBound, id)
            XCTAssertTrue(script.contains("if errorNumber is -1712 then error number errorNumber"), id)
        }
    }

    func testScriptsCompileForInstalledBrowsers() throws {
        var compiled = 0
        for id in BrowserSources.supportedBundleIDs.sorted() {
            guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil else { continue }
            let source = try XCTUnwrap(BrowserSources.appleScript(forBundleID: id))
            let script = try XCTUnwrap(NSAppleScript(source: source), id)
            var error: NSDictionary?
            XCTAssertTrue(script.compileAndReturnError(&error), "\(id): \(String(describing: error))")
            compiled += 1
        }
        if compiled == 0 {
            throw XCTSkip("No supported browser installed")
        }
    }

    func testUnsupportedBundleIDsHaveNoScript() {
        XCTAssertNil(BrowserSources.appleScript(forBundleID: "org.mozilla.firefox"))
        XCTAssertNil(BrowserSources.appleScript(forBundleID: "com.operasoftware.Opera"))
        XCTAssertNil(BrowserSources.appleScript(forBundleID: "com.apple.TextEdit"))
        XCTAssertNil(BrowserSources.appleScript(forBundleID: ""))
        XCTAssertNil(BrowserSources.appleScript(forBundleID: "com.apple.safari"))
    }

    func testParseURLAndTitle() {
        let result = BrowserSources.parse("https://example.com/page\nExample Page\n")
        XCTAssertEqual(result.url, URL(string: "https://example.com/page"))
        XCTAssertEqual(result.title, "Example Page")
    }

    func testParseMultilineTitleAndCRLF() {
        let result = BrowserSources.parse("  http://example.com \r\n  Line one\nLine two  ")
        XCTAssertEqual(result.url, URL(string: "http://example.com"))
        XCTAssertEqual(result.title, "Line one\nLine two")
    }

    func testParseFileURL() {
        let result = BrowserSources.parse("file:///Sites/page.html\nLocal")
        XCTAssertEqual(result.url?.isFileURL, true)
        XCTAssertEqual(result.url?.path, "/Sites/page.html")
    }

    func testParseBlankOutput() {
        for output in ["", "\n", "  \n  ", "\n\n\n"] {
            let result = BrowserSources.parse(output)
            XCTAssertNil(result.url, output)
            XCTAssertNil(result.title, output)
        }
    }

    func testParseTitleWithoutURL() {
        let result = BrowserSources.parse("\nNew Tab")
        XCTAssertNil(result.url)
        XCTAssertEqual(result.title, "New Tab")
    }

    func testParseURLOnly() {
        let result = BrowserSources.parse("https://example.com")
        XCTAssertEqual(result.url, URL(string: "https://example.com"))
        XCTAssertNil(result.title)
    }

    func testParseRejectsOtherSchemes() {
        for bad in ["javascript:alert(1)", "data:text/html,x", "about:blank", "chrome://newtab/", "favorites://", "not a url", "https://"] {
            let result = BrowserSources.parse("\(bad)\nTitle")
            XCTAssertNil(result.url, bad)
            XCTAssertEqual(result.title, "Title", bad)
        }
    }
}
