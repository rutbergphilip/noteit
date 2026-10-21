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

extension CLIEditorTests {
    func testAbandonRemovesTheFileAndStopsTheEditor() throws {
        let file = try temporaryDirectory().appendingPathComponent("note.md")
        try Data("draft".utf8).write(to: file)
        let editor = Process()
        editor.executableURL = URL(fileURLWithPath: "/bin/sleep")
        editor.arguments = ["30"]
        try editor.run()
        XCTAssertEqual(CLIEditor.abandon(file, child: editor.processIdentifier, signal: SIGTERM), 143)
        editor.waitUntilExit()
        XCTAssertEqual(editor.terminationReason, .uncaughtSignal)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(CLIEditor.abandon(file, child: 0, signal: SIGHUP), 129)
    }

    /// A SIGTERM sent while the editor is being spawned waits for its pid instead of leaving it running.
    func testStopSignalDuringSpawnReachesTheEditor() throws {
        let file = try temporaryDirectory().appendingPathComponent("note.md")
        try Data("draft".utf8).write(to: file)
        let stopped = expectation(description: "stop handler runs")
        let stopGuard = CLIEditor.StopSignalGuard(file: file) { code in
            XCTAssertEqual(code, 128 + SIGTERM)
            stopped.fulfill()
        }
        defer { stopGuard.cancel() }
        let editor = Process()
        editor.executableURL = URL(fileURLWithPath: "/bin/sleep")
        editor.arguments = ["30"]
        stopGuard.recordChild {
            try? editor.run()
            kill(getpid(), SIGTERM)
            Thread.sleep(forTimeInterval: 0.3)
            return editor.processIdentifier
        }
        wait(for: [stopped], timeout: 10)
        editor.waitUntilExit()
        XCTAssertEqual(editor.terminationReason, .uncaughtSignal)
        XCTAssertEqual(editor.terminationStatus, SIGTERM)
        XCTAssertEqual(stopGuard.caught, SIGTERM)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    /// Stops the built `noteit edit` with SIGTERM and SIGHUP while its editor is running.
    func testStopSignalRemovesTemporaryFile() async throws {
        let binary = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("NoteItCLI")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw XCTSkip("NoteItCLI isn't built.") }
        let id = UUID()
        let harness = CLIHarness { _ in
            .json(NoteDTO(summary: summary(id, title: "Plan"), format: .markdown, body: "# Plan\n"))
        }
        try await harness.start()
        defer { harness.stop() }
        try harness.signIn()

        for number in [SIGTERM, SIGHUP] {
            let directory = try temporaryDirectory()
            let started = directory.appendingPathComponent("started")
            let editor = directory.appendingPathComponent("editor.sh")
            try Data("#!/bin/sh\necho \"$1\" > '\(started.path).tmp'\nmv '\(started.path).tmp' '\(started.path)'\nexec sleep 30\n".utf8)
                .write(to: editor)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: editor.path)

            let process = Process()
            process.executableURL = binary
            process.arguments = ["edit", id.uuidString]
            process.environment = harness.environment.merging(["EDITOR": editor.path, "PATH": "/usr/bin:/bin"]) { $1 }
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let exited = expectation(description: "noteit edit exits")
            process.terminationHandler = { _ in exited.fulfill() }
            try process.run()
            let deadline = Date().addingTimeInterval(20)
            while !FileManager.default.fileExists(atPath: started.path), Date() < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let temporary = try String(contentsOf: started, encoding: .utf8).trimmingCharacters(in: .newlines)
            XCTAssertTrue(FileManager.default.fileExists(atPath: temporary))
            kill(process.processIdentifier, number)
            await fulfillment(of: [exited], timeout: 20)
            XCTAssertEqual(process.terminationReason, .exit)
            XCTAssertEqual(process.terminationStatus, 128 + number)
            XCTAssertFalse(FileManager.default.fileExists(atPath: temporary))
        }
    }
}
