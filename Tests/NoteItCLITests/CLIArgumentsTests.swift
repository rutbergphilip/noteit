import Foundation
@testable import NoteItCLI
import XCTest

final class CLIArgumentsTests: XCTestCase {
    /// `noteit new …`: value options title, notebook, tag and profile; flags open, json, no-launch and help.
    private func parse(_ arguments: [String]) throws -> CLIInvocation {
        try CLIArguments.parse(["new"] + arguments).get()
    }

    func testParseOptionsAndPositionals() throws {
        let parsed = try parse(["hello", "--title", "Groceries", "--notebook=Home Stuff", "--open", "-", "--json"])
        XCTAssertEqual(parsed, CLIInvocation(command: "new", positionals: ["hello", "-"],
                                             options: ["title": ["Groceries"], "notebook": ["Home Stuff"]], flags: ["open", "json"]))
        XCTAssertEqual(parsed.positionals, ["hello", "-"])
        XCTAssertEqual(parsed.value("title"), "Groceries")
        XCTAssertEqual(parsed.value("notebook"), "Home Stuff")
        XCTAssertEqual(parsed.flags, ["open", "json"])
        XCTAssertEqual(try parse(["--title=a=b"]).value("title"), "a=b")
        XCTAssertEqual(try parse(["--title="]).value("title"), "")
        XCTAssertEqual(try parse(["-h"]).flags, ["help"])
        XCTAssertThrowsError(try parse(["--title"])) { error in
            XCTAssertEqual(error as? CLIUsageError, CLIUsageError(message: "--title needs a value."))
        }
        XCTAssertThrowsError(try parse(["--open=yes"])) { error in
            XCTAssertEqual(error as? CLIUsageError, CLIUsageError(message: "--open doesn't take a value."))
        }
    }

    func testRepeatedTags() throws {
        let parsed = try parse(["--tag", "home", "text", "--tag=work", "--tag", "--title"])
        XCTAssertEqual(parsed.values("tag"), ["home", "work", "--title"])
        XCTAssertEqual(parsed.positionals, ["text"])
        XCTAssertEqual(try parse(["--title", "a", "--title", "b"]).value("title"), "b")
    }

    func testDoubleDash() throws {
        let parsed = try parse(["--open", "--", "--title", "-", "--bogus"])
        XCTAssertEqual(parsed.positionals, ["--title", "-", "--bogus"])
        XCTAssertEqual(parsed.flags, ["open"])
        XCTAssertNil(parsed.value("title"))
    }

    func testUnknownOption() async throws {
        XCTAssertThrowsError(try parse(["--bogus"])) { error in
            XCTAssertEqual(error as? CLIUsageError, CLIUsageError(message: "Unknown option --bogus."))
        }
        XCTAssertThrowsError(try parse(["-x"])) { error in
            XCTAssertEqual(error as? CLIUsageError, CLIUsageError(message: "Unknown option -x."))
        }
        XCTAssertEqual(try CLIArguments.parse(["search", "x", "--limit", "5"]).get().value("limit"), "5")
        XCTAssertEqual(CLIArguments.parse(["show", "--limit", "5"]),
                       .failure(CLIUsageError(message: "Unknown option --limit.")))
        XCTAssertEqual(CLIArguments.parse(["frobnicate"]),
                       .failure(CLIUsageError(message: "Unknown command “frobnicate”. Run noteit help for a list.")))
        XCTAssertEqual(CLIArguments.parse([]), .failure(CLIUsageError(message: "No command given. Run noteit help for a list.")))
        let terminal = Terminal()
        let exit = await offlineCLI(terminal).run(["new", "hello", "--bogus=1"])
        XCTAssertEqual(exit, .usage)
        XCTAssertEqual(terminal.err, "noteit: Unknown option --bogus.\nRun noteit help new for its options.\n")
        XCTAssertEqual(terminal.out, "")
    }

    func testProfileFromFlagAndEnv() throws {
        XCTAssertEqual(try CLIProfile.resolve(flag: nil, environment: [:]), "default")
        XCTAssertEqual(try CLIProfile.resolve(flag: nil, environment: ["NOTEIT_PROFILE": "work"]), "work")
        XCTAssertEqual(try CLIProfile.resolve(flag: nil, environment: ["NOTEIT_PROFILE": ""]), "default")
        XCTAssertEqual(try CLIProfile.resolve(flag: "home", environment: ["NOTEIT_PROFILE": "work"]), "home")
    }

    func testProfileNameRules() async throws {
        for good in ["default", "a", "work-2", String(repeating: "x", count: 32), "mcpx", "my-mcp", "mcp-"] {
            XCTAssertNoThrow(try CLIProfile.validate(good), good)
        }
        for bad in ["", "Work", "under_score", "spa ce", "é", String(repeating: "x", count: 33)] {
            XCTAssertThrowsError(try CLIProfile.validate(bad), bad)
        }
        for reserved in ["mcp", "mcp-claude-desktop", "mcp-1"] {
            XCTAssertThrowsError(try CLIProfile.validate(reserved), reserved) { error in
                XCTAssertEqual((error as? CLIUsageError)?.message, "The profile name “\(reserved)” is kept for noteit mcp.")
            }
        }
        XCTAssertThrowsError(try CLIProfile.resolve(flag: "mcp-claude-desktop", environment: [:]))
        XCTAssertThrowsError(try CLIProfile.resolve(flag: nil, environment: ["NOTEIT_PROFILE": "mcp-claude-desktop"]))

        let terminal = Terminal()
        let exit = await offlineCLI(terminal, environment: ["NOTEIT_PROFILE": "mcp-claude-desktop"]).run(["list"])
        XCTAssertEqual(exit, .usage)
        XCTAssertTrue(terminal.err.hasPrefix("noteit: The profile name “mcp-claude-desktop” is kept for noteit mcp.\n"))
    }

    func testMcpCommandExits2InWave1() async {
        for arguments in [["mcp"], ["mcp", "serve", "--profile", "mcp-claude-desktop"], ["help", "mcp"]] {
            let terminal = Terminal()
            let exit = await offlineCLI(terminal).run(arguments)
            XCTAssertEqual(exit, .usage, "\(arguments)")
            XCTAssertEqual(terminal.err, "noteit mcp isn't in this version of NoteIt.\n")
            XCTAssertEqual(terminal.out, "")
        }
    }

    func testHelpForEveryCommand() async {
        let overview = Terminal()
        let exit = await offlineCLI(overview).run(["help"])
        XCTAssertEqual(exit, .ok)
        for spec in CommandSpec.all {
            XCTAssertTrue(overview.out.contains("  \(spec.name) "), spec.name)

            let terminal = Terminal()
            let helpExit = await offlineCLI(terminal).run(["help", spec.name])
            XCTAssertEqual(helpExit, .ok, spec.name)
            XCTAssertTrue(terminal.out.hasPrefix("usage: \(spec.usage)\n\n\(spec.summary)\n"), spec.name)

            let flag = Terminal()
            let flagExit = await offlineCLI(flag).run([spec.name, "--help"])
            XCTAssertEqual(flagExit, .ok, spec.name)
            XCTAssertEqual(flag.out, terminal.out, spec.name)
        }
        let unknown = Terminal()
        let unknownExit = await offlineCLI(unknown).run(["help", "frobnicate"])
        XCTAssertEqual(unknownExit, .usage)
        let bare = Terminal()
        let bareExit = await offlineCLI(bare).run([])
        XCTAssertEqual(bareExit, .usage)
        XCTAssertEqual(bare.err, overview.out)
    }
}
