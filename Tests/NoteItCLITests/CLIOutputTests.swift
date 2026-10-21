import Foundation
import NoteItAPI
@testable import NoteItCLI
import XCTest

final class CLIOutputTests: XCTestCase {
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
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CLIOutputTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testListHumanOutput() async throws {
        let first = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let second = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let notes = [
            summary(first, title: "Groceries", updatedAt: Date(timeIntervalSince1970: 1_790_000_000)),
            summary(second, title: "", updatedAt: Date(timeIntervalSince1970: 1_790_003_600)),
        ]
        XCTAssertEqual(CLIOutput.noteLines(notes, timeZone: TimeZone(identifier: "UTC")!), [
            "11111111-2222-3333-4444-555555555555  2026-09-21 14:13  Groceries",
            "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE  2026-09-21 15:13  Untitled",
        ])

        let harness = try await harness { context in
            guard context.route.spec.id == RouteID.notesList.rawValue else { return .error(.notFound, "No.") }
            return .json(Page(items: notes, nextCursor: nil))
        }
        try harness.signIn()
        let exit = await harness.run(["list", "--tag", "home", "--limit", "20"])
        XCTAssertEqual(exit, .ok)
        XCTAssertEqual(harness.terminal.out, """
            11111111-2222-3333-4444-555555555555  2026-09-21 16:13  Groceries
            AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE  2026-09-21 17:13  Untitled

            """)
        XCTAssertEqual(harness.responder.requests.value.first?.query, ["tag": "home", "limit": "20"])

        let badLimit = await harness.run(["list", "--limit", "0"])
        XCTAssertEqual(badLimit, .usage)
    }

    func testJSONOutputPassesThrough() async throws {
        let raw = #"{"items":[],"nextCursor":null,"later":{"unknown":true}}"#
        let harness = try await harness { _ in
            HTTPResponse(status: 200, headers: HTTPHeaders([("Content-Type", "application/json")]), body: Data(raw.utf8))
        }
        try harness.signIn()
        let exit = await harness.run(["list", "--json"])
        XCTAssertEqual(exit, .ok)
        XCTAssertEqual(harness.terminal.out, raw + "\n")

        harness.terminal.out = ""
        let searchExit = await harness.run(["search", "two", "words", "--json"])
        XCTAssertEqual(searchExit, .ok)
        XCTAssertEqual(harness.terminal.out, raw + "\n")
        XCTAssertEqual(harness.responder.requests.value.last?.query["q"], "two words")
    }

    func testExitCodeMapping() {
        let expected: [APIErrorCode: CLIExit] = [
            .badRequest: .error, .unauthorized: .unauthorized, .tokenRevoked: .unauthorized, .forbiddenScope: .error,
            .originNotAllowed: .error, .pairingDenied: .unauthorized, .pairingFailed: .unauthorized, .notFound: .notFound,
            .noteDeleted: .notFound, .noteUnreadable: .error, .pairingInProgress: .error, .cursorExpired: .error,
            .lengthRequired: .error, .revisionMismatch: .conflict, .tooLarge: .error, .unsupportedMediaType: .error,
            .misdirected: .error, .rateLimited: .error, .internal: .error, .apiDisabled: .unreachable,
            .notImplemented: .error, .notAvailable: .error, .readOnly: .error, .noteLocked: .error, .editorRequired: .error,
            .notReady: .unreachable,
        ]
        XCTAssertEqual(Set(expected.keys), Set(APIErrorCode.allCases))
        for code in APIErrorCode.allCases {
            XCTAssertEqual(CLIOutput.exit(for: code), expected[code], code.rawValue)
            let error = NoteItAPIError(status: code.httpStatus, code: code, message: "m")
            XCTAssertEqual(CLIOutput.report(error).0, expected[code], code.rawValue)
        }
        XCTAssertEqual(CLIOutput.report(URLError(.cannotConnectToHost)).0, .unreachable)
        XCTAssertEqual(CLIOutput.report(CLIUsageError(message: "x")).0, .usage)
        XCTAssertEqual(CLIOutput.report(NoteItAPIError(status: 404, code: nil, message: "x")).0, .notFound)
        XCTAssertEqual(CLIOutput.report(NoteItAPIError(status: 502, code: nil, message: "x")).0, .error)
    }

    func testVersionUnbundledPrintsDev() async throws {
        let directory = try temporaryDirectory()
        let loose = directory.appendingPathComponent("noteit")
        FileManager.default.createFile(atPath: loose.path, contents: Data())
        let cli = offlineCLI(Terminal())
        XCTAssertEqual(cli.version(executableURL: loose), "noteit dev")
        XCTAssertEqual(cli.version(executableURL: nil), "noteit dev")

        let terminal = Terminal()
        let exit = await offlineCLI(terminal, executableURL: nil).run(["--version"])
        XCTAssertEqual(exit, .ok)
        XCTAssertEqual(terminal.out, "noteit dev\n")
    }

    func testVersionInsideSyntheticApp() async throws {
        let directory = try temporaryDirectory()
        let contents = directory.appendingPathComponent("Fake.app/Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Helpers"), withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "1.2.3"],
                                                       format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        let tool = contents.appendingPathComponent("Helpers/noteit")
        FileManager.default.createFile(atPath: tool.path, contents: Data())

        let terminal = Terminal()
        let exit = await offlineCLI(terminal, executableURL: tool).run(["--version"])
        XCTAssertEqual(exit, .ok)
        XCTAssertEqual(terminal.out, "noteit 1.2.3\n")
    }

    func testAuthLoginPairsAndStoresTokenForProfile() async throws {
        let harness = try await harness { _ in .error(.notFound, "No.") }
        harness.terminal.lines = ["000 000", "123 456"]
        let exit = await harness.run(["auth", "login", "--profile", "work", "--scopes", "write,read"])
        XCTAssertEqual(exit, .ok)
        XCTAssertEqual(harness.terminal.err, "Enter the code shown in NoteIt: That code didn't match. Try again.\nEnter the code shown in NoteIt: ")
        XCTAssertEqual(harness.terminal.out, "Paired as “noteit CLI on Studio” with read, write access.\n")
        let token = try XCTUnwrap(harness.keychain.token(profile: "work"))
        XCTAssertNil(harness.keychain.token(profile: "default"))
        let record = try XCTUnwrap(harness.clients.authenticate(bearer: token))
        XCTAssertEqual(record.name, "noteit CLI on Studio")
        XCTAssertEqual(record.kind, .cli)
        XCTAssertEqual(record.scopes, [.read, .write])
    }

    func testAuthLoginOpensSettingsWhenApiIsOff() async {
        let terminal = Terminal()
        let cli = CLI(context: CLIContext(
            io: terminal.io, environment: [:],
            locator: AppLocator(environment: [:], readDiscovery: {
                DiscoveryFile(pid: 1, appVersion: "1", apiEnabled: false, port: nil, baseURL: nil, startedAt: Date())
            }, launchApp: {}, ping: { _ in false }, sleep: { _ in }),
            keychain: CLIKeychain(store: InMemorySecretStore(), service: "test.noteit.cli"), session: .shared,
            hostName: { nil }, openURL: { terminal.openedURLs.append($0) }, executableURL: nil, timeZone: .current,
            runEditor: { _, _ in 0 }))
        let exit = await cli.run(["auth", "login"])
        XCTAssertEqual(exit, .unreachable)
        XCTAssertEqual(terminal.err, "noteit: The Local API is off. Turn it on in NoteIt › Settings › Integrations.\n")
        XCTAssertEqual(terminal.openedURLs, [URL(string: "noteit://settings?tab=integrations")!])
    }

    func testNotSignedInExits4() async throws {
        let harness = try await harness { _ in .error(.notFound, "No.") }
        let exit = await harness.run(["list"])
        XCTAssertEqual(exit, .unauthorized)
        XCTAssertEqual(harness.terminal.err, "noteit: Not signed in. Run noteit auth login.\n")

        harness.environment["NOTEIT_TOKEN"] = "nit_wrong"
        harness.terminal.err = ""
        let wrong = await harness.run(["tags"])
        XCTAssertEqual(wrong, .unauthorized)
    }

    func testNewReadsPipedStdin() async throws {
        let id = UUID()
        let harness = try await harness { _ in
            .json(NoteDTO(summary: summary(id, title: "From the terminal"), format: .markdown, body: ""), status: 201)
        }
        try harness.signIn()
        harness.terminal.stdin = Data("piped text\n\n".utf8)
        let exit = await harness.run(["new", "--title", "From the terminal", "--tag", "cli", "--tag", "x"])
        XCTAssertEqual(exit, .ok)
        XCTAssertEqual(harness.terminal.out, id.uuidString + "\n")
        let request = try XCTUnwrap(harness.responder.requests.value.first)
        let body = try APIJSON.decoder().decode(CreateNoteRequest.self, from: request.body)
        XCTAssertEqual(body, CreateNoteRequest(title: "From the terminal", body: "piped text", tags: ["cli", "x"]))
    }

    func testDailyUnavailableExits1() async throws {
        let harness = try await harness { _ in .error(.notImplemented, "Daily notes aren't available in this version.") }
        try harness.signIn()
        for arguments in [["append", "--today", "hello"], ["today"], ["today", "hello"]] {
            harness.terminal.err = ""
            harness.terminal.stdin = arguments == ["today"] ? Data() : nil
            let exit = await harness.run(arguments)
            XCTAssertEqual(exit, .error, "\(arguments)")
            XCTAssertEqual(harness.terminal.err, "noteit: Daily notes aren't available in this version.\n")
        }
        XCTAssertEqual(harness.responder.requests.value.map(\.method), ["POST", "GET", "POST"])
    }

    func testEditConflictSavesCopy() async throws {
        let id = UUID()
        let revision = UUID()
        let copyID = UUID()
        let harness = try await harness { context in
            switch context.route.spec.id {
            case RouteID.noteGet.rawValue:
                return .json(NoteDTO(summary: summary(id, title: "Plan", revision: revision), format: .markdown,
                                     body: "# Plan\n\nOld"))
            case RouteID.notePatch.rawValue:
                return .error(.revisionMismatch, "This note changed since you read it.")
            default:
                return .json(NoteDTO(summary: summary(copyID, title: "Plan (edited in terminal)"), format: .markdown, body: ""),
                             status: 201)
            }
        }
        try harness.signIn()
        harness.editor = { _, file in
            try Data("# Plan\n\nNew".utf8).write(to: file)
            return 0
        }
        let exit = await harness.run(["edit", id.uuidString.lowercased()])
        XCTAssertEqual(exit, .conflict)
        let requests = harness.responder.requests.value
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[1].headers["If-Match"], "\"\(revision.uuidString)\"")
        let copy = try APIJSON.decoder().decode(CreateNoteRequest.self, from: requests[2].body)
        XCTAssertEqual(copy.title, "Plan (edited in terminal)")
        XCTAssertEqual(copy.body, "New")
        XCTAssertTrue(harness.terminal.err.contains(copyID.uuidString))
    }
}
