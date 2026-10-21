import Foundation
@testable import NoteIt
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

    private func installer(tool: URL? = nil) -> CLIInstaller {
        let commands = commands
        return CLIInstaller(linkURL: bin.appendingPathComponent("noteit"), toolURL: tool ?? self.tool,
                            runPrivileged: { commands.append($0) })
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
        XCTAssertEqual(commands.all, ["mkdir -p '\(bin.path)' && ln -sf '\(tool.path)' '\(link)'"])
        XCTAssertEqual(installer().state(), .notInstalled)
    }

    func testStatePointsElsewhere() throws {
        let other = root.appendingPathComponent("Other/NoteIt.app/Contents/Helpers/noteit")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("noteit"), withDestinationURL: other)
        XCTAssertEqual(installer().state(), .pointsElsewhere(other.path))

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

    func testQuotingInPrivilegedCommand() {
        XCTAssertEqual(CLIInstaller.quoted("it's"), #"'it'\''s'"#)
        XCTAssertEqual(CLIInstaller.installCommand(tool: "/Users/o'neil/Apps/NoteIt.app/Contents/Helpers/noteit",
                                                   link: "/usr/local/bin/noteit"),
                       #"mkdir -p '/usr/local/bin' && ln -sf '/Users/o'\''neil/Apps/NoteIt.app/Contents/Helpers/noteit' '/usr/local/bin/noteit'"#)
        XCTAssertEqual(CLIInstaller.quoted("$(rm -rf ~) `x` \"y\""), #"'$(rm -rf ~) `x` "y"'"#)
    }
}

private final class LockedCommands: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [String] = []

    var all: [String] { lock.withLock { commands } }
    func append(_ command: String) { lock.withLock { commands.append(command) } }
}
