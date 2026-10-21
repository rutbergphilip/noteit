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

    private func installer(tool: URL? = nil, needsMoving: Bool = false, completions: [CLIInstaller.Completion] = []) -> CLIInstaller {
        let commands = commands
        return CLIInstaller(linkURL: bin.appendingPathComponent("noteit"), toolURL: tool ?? self.tool,
                            runPrivileged: { commands.append($0) }, appNeedsMoving: { needsMoving }, completions: completions)
    }

    /// The three completion files in the test app, linked from folders under `root`.
    private func completions(shipped: Bool = true) throws -> [CLIInstaller.Completion] {
        let app = root.appendingPathComponent("Apps/NoteIt.app")
        let links = ["share/zsh/site-functions/_noteit", "etc/bash_completion.d/noteit", "share/fish/vendor_completions.d/noteit.fish"]
        return try zip(CLIInstaller.completions(in: app), links).map { completion, link in
            if shipped {
                try FileManager.default.createDirectory(at: completion.fileURL.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: completion.fileURL.path, contents: Data("# script".utf8))
            }
            return CLIInstaller.Completion(fileURL: completion.fileURL, linkURL: root.appendingPathComponent(link))
        }
    }

    private func destination(_ completion: CLIInstaller.Completion) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: completion.linkURL.path)
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

    func testInstallLinksCompletions() throws {
        let completions = try completions()
        XCTAssertEqual(completions.map(\.fileURL.lastPathComponent), ["_noteit", "noteit.bash", "noteit.fish"])
        XCTAssertEqual(CLIInstaller.completionLinks.map(\.1), ["/usr/local/share/zsh/site-functions/_noteit",
                                                              "/usr/local/etc/bash_completion.d/noteit",
                                                              "/usr/local/share/fish/vendor_completions.d/noteit.fish"])
        try installer(completions: completions).install()
        for completion in completions {
            XCTAssertEqual(destination(completion), completion.fileURL.path)
        }
        XCTAssertEqual(installer(completions: completions).state(), .installed)
        XCTAssertEqual(commands.all, [])

        try installer(completions: completions).uninstall()
        XCTAssertEqual(installer(completions: completions).state(), .notInstalled)
        XCTAssertTrue(completions.allSatisfy { destination($0) == nil })
    }

    func testInstallWithoutCompletionsNeedsFix() throws {
        let completions = try completions()
        try link(to: tool)
        XCTAssertEqual(installer(completions: completions).state(), .completionsMissing)
        XCTAssertEqual(installer().state(), .installed)

        let other = root.appendingPathComponent("Old/NoteIt.app/Contents/Resources/completions/_noteit")
        try FileManager.default.createDirectory(at: completions[0].linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: completions[0].linkURL, withDestinationURL: other)
        try installer(completions: Array(completions.prefix(1))).install()
        XCTAssertEqual(destination(completions[0]), completions[0].fileURL.path)
        XCTAssertEqual(installer(completions: completions).state(), .completionsMissing)

        try installer(completions: completions).install()
        XCTAssertEqual(installer(completions: completions).state(), .installed)
    }

    func testCompletionsNotShippedAreSkipped() throws {
        let completions = try completions(shipped: false)
        try installer(completions: completions).install()
        XCTAssertEqual(installer(completions: completions).state(), .installed)
        XCTAssertTrue(completions.allSatisfy { destination($0) == nil })
    }

    func testForeignCompletionFilesAreLeftAlone() throws {
        let completions = try completions()
        let fileManager = FileManager.default
        for completion in completions {
            try fileManager.createDirectory(at: completion.linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        fileManager.createFile(atPath: completions[0].linkURL.path, contents: Data("# mine".utf8))
        let foreign = root.appendingPathComponent("opt/othertool/share/noteit.bash")
        try fileManager.createSymbolicLink(at: completions[1].linkURL, withDestinationURL: foreign)
        let otherApp = try makeApp("Other.app", bundleID: "com.example.other")
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/completions/noteit.fish")
        try fileManager.createSymbolicLink(at: completions[2].linkURL, withDestinationURL: otherApp)

        try installer(completions: completions).install()
        XCTAssertEqual(installer(completions: completions).state(), .installed)
        XCTAssertEqual(try String(contentsOf: completions[0].linkURL, encoding: .utf8), "# mine")
        XCTAssertEqual(destination(completions[1]), foreign.path)
        XCTAssertEqual(destination(completions[2]), otherApp.path)

        try installer(completions: completions).uninstall()
        XCTAssertTrue(fileManager.fileExists(atPath: completions[0].linkURL.path))
        XCTAssertEqual(destination(completions[1]), foreign.path)
        XCTAssertEqual(destination(completions[2]), otherApp.path)
        XCTAssertEqual(commands.all, [])
    }

    func testPrivilegedInstallAndUninstallUseOneCommand() throws {
        let completions = try completions()
        let share = root.appendingPathComponent("share")
        try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: share.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: share.path) }

        try installer(completions: completions).install()
        let link = bin.appendingPathComponent("noteit").path
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link), tool.path)
        XCTAssertEqual(commands.all, [completions.map { completion in
            "mkdir -p '\(completion.linkURL.deletingLastPathComponent().path)' && ln -sfh '\(completion.fileURL.path)' '\(completion.linkURL.path)'"
        }.joined(separator: " && ")])
        XCTAssertEqual(installer(completions: completions).state(), .completionsMissing)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: share.path)
        try installer(completions: completions).install()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: bin.path)
        try installer(completions: completions).uninstall()
        XCTAssertEqual(commands.all.last, "rm -f " + ([link] + completions.map(\.linkURL.path)).map { "'\($0)'" }.joined(separator: " "))
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
