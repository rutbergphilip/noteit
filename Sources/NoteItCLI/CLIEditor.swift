import Foundation

/// The `$VISUAL`/`$EDITOR` round trip for `noteit edit`.
enum CLIEditor {
    static func command(environment: [String: String]) -> String {
        for name in ["VISUAL", "EDITOR"] {
            if let value = environment[name]?.trimmingCharacters(in: .whitespaces), !value.isEmpty { return value }
        }
        return "vi"
    }

    /// Writes `text` to a private temporary file, runs the editor on it with the terminal attached, and returns
    /// the edited text, or nil when the editor failed. The file is removed afterwards.
    static func edit(_ text: String, environment: [String: String],
                     run: (String, URL) throws -> Int32 = runEditor) throws -> String? {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("noteit-\(UUID().uuidString).md")
        guard FileManager.default.createFile(atPath: file.path, contents: Data(text.utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path])
        }
        defer { try? FileManager.default.removeItem(at: file) }
        guard try run(command(environment: environment), file) == 0 else { return nil }
        return try String(contentsOf: file, encoding: .utf8)
    }

    /// The editor value may carry arguments (`code --wait`), so it runs through the shell with the path as `$1`.
    static func runEditor(_ command: String, _ file: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command + " \"$1\"", "noteit", file.path]
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
