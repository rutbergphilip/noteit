import Foundation
import NoteItAPI
import XCTest

final class CLIVersionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CLIVersionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testHelperInsideAppReadsShortVersion() throws {
        let executable = try makeApp(version: "1.2.3", folder: "Helpers")
        XCTAssertEqual(CLIVersion.current(executableURL: executable), "1.2.3")
    }

    func testSymlinkOutsideAppResolves() throws {
        let executable = try makeApp(version: "1.2.3", folder: "Helpers")
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let link = bin.appendingPathComponent("noteit")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)
        XCTAssertEqual(CLIVersion.current(executableURL: link), "1.2.3")
    }

    func testOutsideAnyAppIsDev() throws {
        let executable = root.appendingPathComponent("noteit")
        try Data().write(to: executable)
        XCTAssertEqual(CLIVersion.current(executableURL: executable), "dev")
        XCTAssertEqual(CLIVersion.current(executableURL: nil), CLIVersion.unbundled)
    }

    func testMissingKeyIsDev() throws {
        let executable = try makeApp(version: nil, folder: "Helpers")
        XCTAssertEqual(CLIVersion.current(executableURL: executable), "dev")
    }

    func testMacOSFolderIsDev() throws {
        let executable = try makeApp(version: "1.2.3", folder: "MacOS")
        XCTAssertEqual(CLIVersion.current(executableURL: executable), "dev")
    }

    private func makeApp(version: String?, folder: String) throws -> URL {
        let contents = root.appendingPathComponent("Fake.app/Contents", isDirectory: true)
        let folderURL = contents.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        var plist: [String: Any] = ["CFBundleIdentifier": "example.fake"]
        if let version { plist["CFBundleShortVersionString"] = version }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        let executable = folderURL.appendingPathComponent("noteit")
        try Data().write(to: executable)
        return executable
    }
}
