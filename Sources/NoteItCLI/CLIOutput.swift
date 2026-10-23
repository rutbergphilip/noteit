import Foundation
import NoteItAPI

/// A failure with its own exit code and message.
struct CLIFailure: Error, Equatable {
    var exit: CLIExit
    var message: String
}

/// Terminal input and output, replaceable in tests.
struct CLIIO {
    var out: (String) -> Void
    var err: (String) -> Void
    var readLine: () -> String?
    var stdinIsTerminal: Bool
    var readStdin: () -> Data

    static func live() -> CLIIO {
        CLIIO(
            out: { FileHandle.standardOutput.write(Data($0.utf8)) },
            err: { FileHandle.standardError.write(Data($0.utf8)) },
            readLine: { Swift.readLine(strippingNewline: true) },
            stdinIsTerminal: isatty(STDIN_FILENO) != 0,
            readStdin: { FileHandle.standardInput.readDataToEndOfFile() }
        )
    }

    func line(_ text: String) { out(text + "\n") }
    func errorLine(_ text: String) { err(text + "\n") }

    /// The API's JSON unchanged, ending in a newline.
    func passThrough(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        out(text.hasSuffix("\n") ? text : text + "\n")
    }
}

enum CLIOutput {
    static func timestamp(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    static func title(_ title: String) -> String {
        let flat = oneLine(title)
        return flat.isEmpty ? "Untitled" : flat
    }

    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// `noteit list`: id, last edited, title.
    static func noteLines(_ notes: [NoteSummaryDTO], timeZone: TimeZone) -> [String] {
        notes.map { "\($0.id.uuidString)  \(timestamp($0.updatedAt, timeZone: timeZone))  \(title($0.title))" }
    }

    static func searchLines(_ results: [SearchResultDTO]) -> [String] {
        results.flatMap { result -> [String] in
            let snippet = oneLine(result.snippet)
            let head = "\(result.note.id.uuidString)  \(title(result.note.title))"
            return snippet.isEmpty ? [head] : [head, "    " + snippet]
        }
    }

    static func notebookLines(_ response: NotebooksResponseDTO) -> [String] {
        response.notebooks.map { notebook in
            let count = notebook.noteCount == 1 ? "1 note" : "\(notebook.noteCount) notes"
            let name = (notebook.path?.joined(separator: " › ")).flatMap { $0.isEmpty ? nil : $0 } ?? notebook.name
            return "\(notebook.id.uuidString)  \(name)  (\(count))"
        }
    }

    static func tagLines(_ tags: [TagDTO]) -> [String] {
        tags.map { "\($0.name)  (\($0.noteCount))" }
    }

    static func clientLine(_ client: ClientDTO) -> String {
        "Signed in as “\(client.name)” with \(client.scopes.map(\.rawValue).joined(separator: ", ")) access."
    }

    // MARK: - Exit codes

    static func exit(for code: APIErrorCode) -> CLIExit {
        switch code {
        case .unauthorized, .tokenRevoked, .pairingDenied, .pairingFailed: return .unauthorized
        case .notFound, .noteDeleted: return .notFound
        case .revisionMismatch: return .conflict
        case .apiDisabled, .notReady: return .unreachable
        case .badRequest, .forbiddenScope, .originNotAllowed, .noteUnreadable, .pairingInProgress, .cursorExpired,
             .lengthRequired, .tooLarge, .unsupportedMediaType, .misdirected, .rateLimited, .internal, .notImplemented,
             .notAvailable, .readOnly, .noteLocked, .editorRequired:
            return .error
        }
    }

    static let notReachableMessage = "Couldn't reach NoteIt. Open NoteIt and try again."

    /// The exit code and the message after `noteit: `.
    static func report(_ error: Error) -> (CLIExit, String) {
        switch error {
        case let failure as CLIFailure:
            return (failure.exit, failure.message)
        case let usage as CLIUsageError:
            return (.usage, usage.message)
        case let api as NoteItAPIError:
            if let code = api.code { return (exit(for: code), api.message) }
            return (api.status == 404 ? .notFound : .error, api.message)
        case is URLError:
            return (.unreachable, notReachableMessage)
        default:
            return (.error, error.localizedDescription)
        }
    }
}
