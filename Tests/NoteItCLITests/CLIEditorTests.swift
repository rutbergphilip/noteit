import Foundation
import NoteItAPI
@testable import NoteItCLI
import XCTest

final class CLIEditorTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CLIEditorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testEditorRunsInCallersProcessGroup() throws {
        let file = try temporaryDirectory().appendingPathComponent("note.md")
        let result = try CLIEditor.spawnAndWait("f() { ps -o pgid= -p $$ > \"$1\"; }; f", file)
        XCTAssertEqual(result, .exited(0))
        let group = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(group, String(getpgrp()))
    }

    func testEditorGetsDefaultSignalsWhileNoteItIgnoresThem() throws {
        let file = try temporaryDirectory().appendingPathComponent("note.md")
        XCTAssertEqual(try CLIEditor.spawnAndWait("kill -QUIT $$; :", file), .signaled(SIGQUIT))
        XCTAssertEqual(try CLIEditor.spawnAndWait("exit 7; :", file), .exited(7))
        XCTAssertEqual(try CLIEditor.spawnAndWait("printf '%s' \"$1\" > \"$1\"; :", file), .exited(0))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), file.path)
    }

    /// Runs the built `noteit edit` under a pseudo-terminal, where it used to stop with SIGTTIN/SIGTTOU.
    func testEditUnderTerminalDoesNotStop() async throws {
        let binary = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("NoteItCLI")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw XCTSkip("NoteItCLI isn't built.") }
        let id = UUID()
        let harness = CLIHarness { context in
            .json(NoteDTO(summary: summary(id, title: "Plan"), format: .markdown, body: "# Plan\n\nOld\n"))
        }
        try await harness.start()
        defer { harness.stop() }
        try harness.signIn()

        let directory = try temporaryDirectory()
        let editor = directory.appendingPathComponent("editor.sh")
        try Data("""
        #!/bin/sh
        stty size > /dev/null || exit 3
        stty -echo && stty echo || exit 4
        IFS= read -r typed < /dev/tty || exit 5
        printf '%s\\n' "$typed" >> "$1"

        """.utf8).write(to: editor)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: editor.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", binary.path, "edit", id.uuidString]
        process.environment = harness.environment.merging(["EDITOR": editor.path, "PATH": "/usr/bin:/bin"]) { $1 }
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = expectation(description: "noteit edit exits")
        process.terminationHandler = { _ in exited.fulfill() }
        try process.run()
        input.fileHandleForWriting.write(Data("typed in the terminal\n".utf8))
        await fulfillment(of: [exited], timeout: 20)
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            return XCTFail("noteit edit didn't finish under a terminal.")
        }
        try? input.fileHandleForWriting.close()

        XCTAssertEqual(process.terminationStatus, 0)
        let patch = try XCTUnwrap(harness.responder.requests.value.last { $0.method == "PATCH" })
        let body = try APIJSON.decoder().decode(PatchNoteRequest.self, from: patch.body)
        XCTAssertEqual(body.body, "# Plan\n\nOld\ntyped in the terminal\n")
    }
}
