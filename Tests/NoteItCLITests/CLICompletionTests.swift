import Foundation
import NoteItAPI
import NoteItDocTestSupport
import NoteItSync
@testable import NoteItCLI
import XCTest

final class CLICompletionTests: XCTestCase {
    private var harnesses: [CLIHarness] = []

    override func tearDown() {
        harnesses.forEach { $0.stop() }
        harnesses = []
        super.tearDown()
    }

    private func harness(_ answer: @escaping @Sendable (LocalAPIContext) -> HTTPResponse) async throws -> CLIHarness {
        let harness = CLIHarness(answer: answer)
        harnesses.append(harness)
        try await harness.start()
        return harness
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CLICompletionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func script(_ shell: CompletionShell) async -> String {
        let terminal = Terminal()
        let exit = await offlineCLI(terminal).run(["completion", shell.rawValue])
        XCTAssertEqual(exit, .ok)
        XCTAssertEqual(terminal.err, "")
        return terminal.out
    }

    /// Runs `executable` and returns its exit status and combined output.
    private func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    // MARK: The command table

    func testCompletionSpecMatchesParser() throws {
        let allOptions = CommandSpec.all.flatMap { $0.valueOptions + $0.flags } + CommandSpec.globalValueOptions
            + CommandSpec.globalFlags
        XCTAssertEqual(Set(CompletionScript.optionSummaries.keys), Set(allOptions))
        let flags = Set(CommandSpec.all.flatMap(\.flags) + CommandSpec.globalFlags)
        XCTAssertTrue(flags.isDisjoint(with: CompletionScript.allValueOptions), "an option is a flag somewhere and takes a value elsewhere")

        for spec in CommandSpec.all {
            XCTAssertTrue(Set(spec.optionValues.keys).isSubset(of: spec.valueOptions + CommandSpec.globalValueOptions), spec.name)
            for option in spec.valueOptions + CommandSpec.globalValueOptions {
                XCTAssertNoThrow(try CLIArguments.parse([spec.name, "--\(option)", "x"]).get(), "\(spec.name) --\(option)")
            }
            for flag in spec.flags + CommandSpec.globalFlags {
                XCTAssertNoThrow(try CLIArguments.parse([spec.name, "--\(flag)"]).get(), "\(spec.name) --\(flag)")
            }
            for other in Set(allOptions).subtracting(spec.valueOptions + spec.flags + CommandSpec.globalValueOptions
                                                     + CommandSpec.globalFlags) {
                XCTAssertThrowsError(try CLIArguments.parse([spec.name, "--\(other)", "x"]).get(), "\(spec.name) --\(other)")
            }
        }
    }

    func testScriptsListEveryCommandAndOption() async {
        for shell in CompletionShell.allCases {
            let script = await script(shell)
            for spec in CommandSpec.all {
                XCTAssertTrue(script.contains(spec.name), "\(shell) \(spec.name)")
                let options = spec.valueOptions + spec.flags + CommandSpec.globalValueOptions + CommandSpec.globalFlags
                for option in options {
                    let mentioned = switch shell {
                    case .zsh: script.contains("--\(option)=[") || script.contains("--\(option)[")
                    case .bash: script.contains("--\(option) ") || script.contains("--\(option)'")
                    case .fish: script.contains("'__noteit_using \(spec.name)' -l \(option) ")
                        || script.contains("'__noteit_using \(spec.name)' -s h -l \(option) ")
                    }
                    XCTAssertTrue(mentioned, "\(shell) \(spec.name) --\(option)")
                }
            }
            XCTAssertTrue(script.contains("__complete"), "\(shell)")
            XCTAssertTrue(script.contains(shell == .fish ? "-l version" : "--version"), "\(shell)")
        }
        let fish = await script(.fish)
        XCTAssertTrue(fish.contains("complete -c noteit -n '__noteit_argument show 0' -a '(__noteit_values notes)'"))
        XCTAssertTrue(fish.contains("complete -c noteit -n '__noteit_using list' -l notebook -r -f -a '(__noteit_values notebooks)'"))
        let bash = await script(.bash)
        XCTAssertTrue(bash.contains("'attach 0') _noteit_values notes ;;"))
        XCTAssertTrue(bash.contains("'attach 1') COMPREPLY=($(compgen -f -- \"$cur\")) ;;"))
        XCTAssertTrue(bash.contains("'new --tag') _noteit_values tags ;;"))
        let zsh = await script(.zsh)
        XCTAssertTrue(zsh.hasPrefix("#compdef noteit\n"))
        XCTAssertTrue(zsh.contains("'*--tag=[Tag, repeat for more]:tag:_noteit_values tags'"))
    }

    func testScriptsPassSyntaxChecks() async throws {
        let directory = try temporaryDirectory()
        for shell in [CompletionShell.zsh, .bash] {
            try Data(await script(shell).utf8).write(to: directory.appendingPathComponent(shell.rawValue))
        }
        for shell in ["zsh", "bash"] {
            let (status, output) = try run("/bin/\(shell)", ["-n", directory.appendingPathComponent(shell).path])
            XCTAssertEqual(status, 0, "\(shell): \(output)")
        }
        let functions = directory.appendingPathComponent("functions")
        try FileManager.default.createDirectory(at: functions, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: directory.appendingPathComponent("zsh"), to: functions.appendingPathComponent("_noteit"))
        let (status, output) = try run("/bin/zsh", ["-fc", "autoload -Uz compinit; fpath=(\(functions.path) $fpath); compinit -u -D; whence -v _noteit; print -r -- $_comps[noteit]"])
        XCTAssertEqual(status, 0, output)
        XCTAssertTrue(output.contains("_noteit is an autoload shell function"), output)
        XCTAssertTrue(output.hasSuffix("_noteit\n"), output)
    }

    /// A `noteit` on PATH that logs the prefix it's given and prints the candidates starting with it.
    private func fakeNoteit(in directory: URL) throws -> (path: String, log: URL) {
        let bin = directory.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let log = directory.appendingPathComponent("prefixes")
        let tool = bin.appendingPathComponent("noteit")
        try Data(#"""
            #!/bin/sh
            printf '%s\n' "$3" >> "$NOTEIT_FAKE_LOG"
            printf 'Work Pro\t2 notes\nit'"'"'s\t1 note\na:b c\t1 note\nhome\t1 note\n' | while IFS= read -r line; do
                case $line in "$3"*) printf '%s\n' "$line" ;; esac
            done
            """#.utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return ("\(bin.path):/usr/bin:/bin", log)
    }

    func testBashPassesTheUnquotedWordAndHandlesColons() async throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("noteit.bash")
        try Data(await script(.bash).utf8).write(to: file)
        let (path, log) = try fakeNoteit(in: directory)
        // bash 3.2 splits COMP_WORDS at spaces only; bash 4 and later also at = and :, as in the second word lists.
        // Either way readline replaces only the text after the last = or :.
        let cases: [(line: String, words: [[String]], replies: [String], prefix: String)] = [
            (#"noteit new --tag Work\ P"#, [["noteit", "new", "--tag", #"Work\ P"#]], ["Work Pro"], "Work P"),
            (#"noteit new --tag "Work P"#, [["noteit", "new", "--tag", #""Work P"#]], ["Work Pro"], "Work P"),
            (#"noteit new --tag it\'"#, [["noteit", "new", "--tag", #"it\'"#]], ["it's"], "it'"),
            ("noteit new --tag=Wo", [["noteit", "new", "--tag=Wo"], ["noteit", "new", "--tag", "=", "Wo"]], ["Work Pro"], "Wo"),
            ("noteit new --tag a:", [["noteit", "new", "--tag", "a:"], ["noteit", "new", "--tag", "a", ":"]], ["b c"], "a:"),
            (#"noteit new --tag=a:b\ "#, [["noteit", "new", #"--tag=a:b\ "#],
                                          ["noteit", "new", "--tag", "=", "a", ":", #"b\ "#]], ["b c"], "a:b "),
            ("noteit new --tag a:b --tag h", [["noteit", "new", "--tag", "a:b", "--tag", "h"],
                                              ["noteit", "new", "--tag", "a", ":", "b", "--tag", "h"]], ["home"], "h"),
        ]
        for example in cases {
            for split in example.words {
                try? FileManager.default.removeItem(at: log)
                let command = """
                    source \(CompletionScript.shellQuoted(file.path))
                    COMP_WORDBREAKS=$'"\\'><=;|&(:'
                    COMP_WORDS=(\(split.map(CompletionScript.shellQuoted).joined(separator: " "))); COMP_CWORD=\(split.count - 1)
                    COMP_LINE=\(CompletionScript.shellQuoted(example.line)); COMP_POINT=${#COMP_LINE}
                    _noteit
                    printf '%s\\n' "${COMPREPLY[@]}"
                    """
                let (status, output) = try run("/bin/bash", ["--noprofile", "--norc", "-c", command],
                                               environment: ["PATH": path, "NOTEIT_FAKE_LOG": log.path])
                XCTAssertEqual(status, 0, "\(split): \(output)")
                XCTAssertEqual(output, example.replies.map { $0 + "\n" }.joined(), "\(split)")
                let prefixes = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
                XCTAssertEqual(prefixes, example.prefix + "\n", "\(split)")
            }
        }
    }

    func testZshPassesTheUnquotedPrefix() async throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("_noteit")
        try Data(await script(.zsh).utf8).write(to: file)
        let (path, log) = try fakeNoteit(in: directory)
        let command = #"""
            compdef() { : }
            _describe() { print -rl -- "${(@P)argv[-1]}" }
            source "$1"
            PREFIX='Work\ P' _noteit_values tags
            PREFIX="it\\'" _noteit_values tags
            PREFIX='a\:' _noteit_values tags
            """#
        let (status, output) = try run("/bin/zsh", ["-fc", command, "zsh", file.path],
                                       environment: ["PATH": path, "NOTEIT_FAKE_LOG": log.path])
        XCTAssertEqual(status, 0, output)
        XCTAssertEqual(output, "Work Pro:2 notes\nit's:1 note\na\\:b c:1 note\n")
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "Work P\nit'\na:\n")
    }

    func testFishScriptPassesSyntaxCheck() async throws {
        let fish = ["/opt/homebrew/bin/fish", "/usr/local/bin/fish", "/usr/bin/fish"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let fish else { throw XCTSkip("fish isn't installed") }
        let file = try temporaryDirectory().appendingPathComponent("noteit.fish")
        try Data(await script(.fish).utf8).write(to: file)
        let (status, output) = try run(fish, ["-n", file.path])
        XCTAssertEqual(status, 0, output)
    }

    func testCompletionCommandUsage() async {
        let terminal = Terminal()
        let exit = await offlineCLI(terminal).run(["completion", "tcsh"])
        XCTAssertEqual(exit, .usage)
        XCTAssertEqual(terminal.err, "noteit: Give a shell: zsh, bash or fish.\nRun noteit help completion for its options.\n")

        let help = Terminal()
        _ = await offlineCLI(help).run(["help", "completion"])
        XCTAssertTrue(help.out.contains("autoload -Uz compinit && compinit"), help.out)
    }

    // MARK: noteit __complete

    func testCompletePrintsNothingWithoutTheAPI() async throws {
        for environment in [[:], ["NOTEIT_TOKEN": "nit_x"], ["NOTEIT_TOKEN": "nit_x", "NOTEIT_API_URL": "http://example.com"],
                            ["NOTEIT_TOKEN": "nit_x", "NOTEIT_PROFILE": "Bad Name"]] {
            for arguments in [["__complete", "notes"], ["__complete", "tags", "h"], ["__complete", "bogus"], ["__complete"]] {
                let terminal = Terminal()
                let exit = await offlineCLI(terminal, environment: environment).run(arguments)
                XCTAssertEqual(exit, .ok, "\(environment) \(arguments)")
                XCTAssertEqual(terminal.out, "", "\(environment) \(arguments)")
                XCTAssertEqual(terminal.err, "", "\(environment) \(arguments)")
            }
        }

        let harness = try await harness { _ in .json([TagDTO(name: "home", noteCount: 1)]) }
        let exit = await harness.run(["__complete", "tags"])
        XCTAssertEqual(exit, .ok)
        XCTAssertEqual(harness.terminal.out, "", "not signed in")
        XCTAssertEqual(harness.responder.requests.value.count, 0)

        let rejected = try await self.harness { _ in .error(.unauthorized, "No.") }
        rejected.environment["NOTEIT_TOKEN"] = "nit_revoked"
        let rejectedExit = await rejected.run(["__complete", "tags"])
        XCTAssertEqual(rejectedExit, .ok)
        XCTAssertEqual(rejected.terminal.out + rejected.terminal.err, "")
    }

    func testCompleteFormatsCandidates() async throws {
        let groceries = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let locked = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        var secret = summary(locked, title: "Diary\tentry")
        secret.locked = true
        let notes = [summary(groceries, title: "Groceries"), secret, summary(title: "")]
        let notebooks = NotebooksResponseDTO(notebooks: [
            NotebookDTO(id: UUID(), name: "Home Stuff", symbol: "house", color: "blue", sortIndex: 0, noteCount: 1),
            NotebookDTO(id: UUID(), name: "Work", symbol: "case", color: "red", sortIndex: 1, noteCount: 3),
        ], defaultNotebookID: nil)
        let harness = try await harness { context in
            switch context.route.spec.id {
            case RouteID.notesList.rawValue: .json(Page(items: notes, nextCursor: nil))
            case RouteID.notebooksList.rawValue: .json(notebooks)
            case RouteID.tags.rawValue: .json([TagDTO(name: "home", noteCount: 2), TagDTO(name: "two\nlines", noteCount: 1)])
            default: .error(.notFound, "No.")
            }
        }
        try harness.signIn()

        func complete(_ arguments: String...) async -> String {
            harness.terminal.out = ""
            let exit = await harness.run(["__complete"] + arguments)
            XCTAssertEqual(exit, .ok)
            XCTAssertEqual(harness.terminal.err, "")
            return harness.terminal.out
        }
        let allNotes = await complete("notes")
        XCTAssertEqual(allNotes, """
            11111111-2222-3333-4444-555555555555\tGroceries
            AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE\tDiary entry
            \(notes[2].id.uuidString)\tUntitled

            """)
        XCTAssertEqual(harness.responder.requests.value.last?.query, ["limit": "200"])
        let notesWithPrefix = await complete("notes", "aaa")
        XCTAssertEqual(notesWithPrefix, "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE\tDiary entry\n")
        let allNotebooks = await complete("notebooks")
        XCTAssertEqual(allNotebooks, "Home Stuff\t1 note\nWork\t3 notes\n")
        let notebooksWithPrefix = await complete("notebooks", "ho")
        XCTAssertEqual(notebooksWithPrefix, "Home Stuff\t1 note\n")
        let tags = await complete("tags")
        XCTAssertEqual(tags, "home\t2 notes\n")
        XCTAssertFalse(harness.responder.requests.value.isEmpty)
    }

    func testCompleteGivesUpAfterTheTimeout() async throws {
        let harness = try await harness { _ in
            Thread.sleep(forTimeInterval: TestTiming.scaled(1))
            return .json([TagDTO(name: "home", noteCount: 1)])
        }
        try harness.signIn()
        var candidates = CompletionCandidates(context: harness.context())
        candidates.timeout = .milliseconds(50)
        let start = Date()
        await candidates.run(["tags"])
        XCTAssertLessThan(Date().timeIntervalSince(start), TestTiming.scaled(0.8))
        XCTAssertEqual(harness.terminal.out, "")
    }

    func testCompleteGivesUpWhenTheKeychainBlocks() async throws {
        let harness = try await harness { _ in .json([TagDTO(name: "home", noteCount: 1)]) }
        var context = harness.context()
        context.keychain = CLIKeychain(store: BlockingSecretStore(), service: "test.noteit.cli")
        var candidates = CompletionCandidates(context: context)
        candidates.timeout = .milliseconds(50)
        let start = Date()
        await candidates.run(["tags"])
        XCTAssertLessThan(Date().timeIntervalSince(start), TestTiming.scaled(0.8))
        XCTAssertEqual(harness.terminal.out, "")
    }
}

/// A Keychain read that hangs, like one waiting for the user to answer an "allow access" dialog.
private struct BlockingSecretStore: SecretStore {
    func read(service: String, account: String) -> String? {
        Thread.sleep(forTimeInterval: TestTiming.scaled(2))
        return "nit_x"
    }

    func write(_ value: String, service: String, account: String) throws {}
    func remove(service: String, account: String) throws {}
}
