import Foundation
@testable import NoteIt
import NoteItSync
import XCTest

final class CLIInstallerTests: XCTestCase {
    private var root: URL!
    private var tool: URL!
    private var bin: URL!
    private let commands = LockedCommands()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CLIInstallerTests-\(UUID().uuidString)")
        tool = root.appendingPathComponent("Apps/NoteIt.app/Contents/Helpers/noteit")
        bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: tool.path, contents: Data(), attributes: [.posixPermissions: 0o755])
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: bin.path) {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        }
        try? FileManager.default.removeItem(at: root)
    }

    private func installer(tool: URL? = nil, needsMoving: Bool = false) -> CLIInstaller {
        let commands = commands
        return CLIInstaller(linkURL: bin.appendingPathComponent("noteit"), toolURL: tool ?? self.tool,
                            runPrivileged: { commands.append($0) }, appNeedsMoving: { needsMoving })
    }

    private func makeApp(_ name: String, bundleID: String) throws -> URL {
        let app = root.appendingPathComponent("Apps/\(name)")
        let helper = app.appendingPathComponent("Contents/Helpers/noteit")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: helper.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": bundleID],
                                                       format: .xml, options: 0)
        try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
        return helper
    }

    @discardableResult private func link(to target: URL) throws -> URL {
        let link = bin.appendingPathComponent("noteit")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        return link
    }

    func testStateNotInstalled() {
        XCTAssertEqual(installer().state(), .notInstalled)
    }

    func testInstallCreatesLink() throws {
        try installer().install()
        let link = bin.appendingPathComponent("noteit")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), tool.path)
        XCTAssertEqual(installer().state(), .installed)
        XCTAssertEqual(commands.all, [])

        try installer().uninstall()
        XCTAssertEqual(installer().state(), .notInstalled)
    }

    func testInstallFallsBackToPrivileged() throws {
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: bin.path)
        try installer().install()
        let link = bin.appendingPathComponent("noteit").path
        XCTAssertEqual(commands.all, ["mkdir -p '\(bin.path)' && ln -sfh '\(tool.path)' '\(link)'"])
        XCTAssertEqual(installer().state(), .notInstalled)
    }

    func testStatePointsElsewhere() throws {
        let other = root.appendingPathComponent("Other/NoteIt.app/Contents/Helpers/noteit")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("noteit"), withDestinationURL: other)
        XCTAssertEqual(installer().state(), .otherCopy(other.path))

        try installer().install()
        XCTAssertEqual(installer().state(), .installed)

        try FileManager.default.removeItem(at: bin.appendingPathComponent("noteit"))
        FileManager.default.createFile(atPath: bin.appendingPathComponent("noteit").path, contents: Data("x".utf8))
        XCTAssertEqual(installer().state(), .pointsElsewhere(bin.appendingPathComponent("noteit").path))
        XCTAssertThrowsError(try installer().install()) { error in
            XCTAssertEqual(error as? CLIInstallerError, .occupied(self.bin.appendingPathComponent("noteit").path))
        }
    }

    func testUninstallRefusesForeignLink() throws {
        let foreign = root.appendingPathComponent("opt/othertool/bin/noteit")
        let link = bin.appendingPathComponent("noteit")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: foreign)
        XCTAssertThrowsError(try installer().uninstall()) { error in
            XCTAssertEqual(error as? CLIInstallerError, .foreignLink(link.path))
        }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), foreign.path)

        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../Apps/NoteIt.app/Contents/Helpers/noteit")
        XCTAssertEqual(installer().state(), .installed)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: bin.path)
        try installer().uninstall()
        XCTAssertEqual(commands.all, ["rm -f '\(link.path)'"])
    }

    func testInstallRefusesForeignLink() throws {
        let otherApp = try makeApp("Other.app", bundleID: "com.example.other")
        for target in [root.appendingPathComponent("opt/othertool/bin/noteit"), otherApp] {
            let link = try link(to: target)
            XCTAssertEqual(installer().state(), .pointsElsewhere(target.path))
            XCTAssertThrowsError(try installer().install()) { error in
                XCTAssertEqual(error as? CLIInstallerError, .foreignLink(link.path))
            }
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
            try FileManager.default.removeItem(at: link)
        }
        XCTAssertEqual(commands.all, [])
    }

    func testRenamedAppCopiesCountAsNoteIt() throws {
        let renamed = try makeApp("NoteIt 2.app", bundleID: AppIdentity.bundleID)
        try link(to: renamed)
        XCTAssertEqual(installer().state(), .otherCopy(renamed.path))
        try installer().uninstall()
        XCTAssertEqual(installer().state(), .notInstalled)

        let loose = root.appendingPathComponent("build/noteit")
        try FileManager.default.createDirectory(at: loose.deletingLastPathComponent(), withIntermediateDirectories: true)
        try installer(tool: loose).install()
        XCTAssertEqual(installer(tool: loose).state(), .installed)
        try installer(tool: loose).uninstall()
        XCTAssertEqual(installer(tool: loose).state(), .notInstalled)
    }

    func testInstallRefusedWhenAppNeedsMoving() {
        XCTAssertThrowsError(try installer(needsMoving: true).install()) { error in
            XCTAssertEqual(error as? CLIInstallerError, .needsMove)
            XCTAssertEqual(error.localizedDescription, "Move NoteIt to your Applications folder first.")
        }
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: bin.appendingPathComponent("noteit").path))
        XCTAssertEqual(commands.all, [])

        XCTAssertTrue(CLIInstaller.needsMoving(
            URL(fileURLWithPath: "/private/var/folders/xy/T/AppTranslocation/ABC/d/NoteIt.app")))
        XCTAssertFalse(CLIInstaller.needsMoving(root))
    }

    func testQuotingInPrivilegedCommand() {
        XCTAssertEqual(CLIInstaller.quoted("it's"), #"'it'\''s'"#)
        XCTAssertEqual(CLIInstaller.installCommand(tool: "/Users/o'neil/Apps/NoteIt.app/Contents/Helpers/noteit",
                                                   link: "/usr/local/bin/noteit"),
                       #"mkdir -p '/usr/local/bin' && ln -sfh '/Users/o'\''neil/Apps/NoteIt.app/Contents/Helpers/noteit' '/usr/local/bin/noteit'"#)
        XCTAssertEqual(CLIInstaller.quoted("$(rm -rf ~) `x` \"y\""), #"'$(rm -rf ~) `x` "y"'"#)
    }
}

private final class LockedCommands: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [String] = []

    var all: [String] { lock.withLock { commands } }
    func append(_ command: String) { lock.withLock { commands.append(command) } }
}
