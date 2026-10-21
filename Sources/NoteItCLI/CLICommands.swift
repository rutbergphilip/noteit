import Foundation
import NoteItAPI
import NoteItSync
import UniformTypeIdentifiers

/// One row of the command table, which drives both parsing and `noteit help`.
struct CommandSpec {
    let name: String
    let usage: String
    let summary: String
    var valueOptions: [String] = []
    var flags: [String] = []

    static let globalValueOptions = ["profile"]
    static let globalFlags = ["json", "no-launch", "help"]

    static let all: [CommandSpec] = [
        CommandSpec(name: "new", usage: "noteit new [TEXT|-] [--title T] [--notebook N] [--tag t]… [--open]",
                    summary: "Create a note and print its id. Reads stdin when TEXT is - or stdin is piped.",
                    valueOptions: ["title", "notebook", "tag"], flags: ["open"]),
        CommandSpec(name: "append", usage: "noteit append (ID | --title T | --today) [TEXT|-] [--start] [--time]",
                    summary: "Add text to the end of a note, or to the start with --start. --time adds the time.",
                    valueOptions: ["title"], flags: ["today", "start", "time"]),
        CommandSpec(name: "show", usage: "noteit show ID [--format markdown|text|html]",
                    summary: "Print a note's text.", valueOptions: ["format"]),
        CommandSpec(name: "list", usage: "noteit list [--notebook N] [--tag t] [--limit n]",
                    summary: "List notes, one per line: id, last edited, title.",
                    valueOptions: ["notebook", "tag", "limit"]),
        CommandSpec(name: "search", usage: "noteit search QUERY [--limit n]",
                    summary: "Search notes and print each match with a snippet.", valueOptions: ["limit"]),
        CommandSpec(name: "edit", usage: "noteit edit ID",
                    summary: "Edit a note's Markdown in $VISUAL or $EDITOR (vi if neither is set)."),
        CommandSpec(name: "rm", usage: "noteit rm ID [--permanent]",
                    summary: "Move a note to Recently Deleted. --permanent deletes a note already there for good.",
                    flags: ["permanent"]),
        CommandSpec(name: "open", usage: "noteit open ID", summary: "Show a note in NoteIt."),
        CommandSpec(name: "notebooks", usage: "noteit notebooks", summary: "List notebooks."),
        CommandSpec(name: "tags", usage: "noteit tags", summary: "List tags with their note counts."),
        CommandSpec(name: "attach", usage: "noteit attach ID FILE", summary: "Add a file to the end of a note."),
        CommandSpec(name: "today", usage: "noteit today [TEXT|-]",
                    summary: "Print today's daily note, or add a line to it."),
        CommandSpec(name: "watch", usage: "noteit watch", summary: "Print changes to your notes as JSON lines."),
        CommandSpec(name: "api", usage: "noteit api METHOD PATH [--data JSON|@file]",
                    summary: "Send a request to the Local API and print the response, for scripts.",
                    valueOptions: ["data"]),
        CommandSpec(name: "auth", usage: "noteit auth login [--scopes read,write] | logout | status",
                    summary: "Pair with NoteIt, sign out, or show who you're signed in as.", valueOptions: ["scopes"]),
        CommandSpec(name: "status", usage: "noteit status", summary: "Show whether NoteIt and the Local API are reachable."),
        CommandSpec(name: "help", usage: "noteit help [COMMAND]", summary: "Show help for noteit or one command."),
    ]

    static func named(_ name: String) -> CommandSpec? { all.first { $0.name == name } }
}

/// Everything a command touches outside itself, so tests can replace it.
struct CLIContext {
    var io: CLIIO
    var environment: [String: String]
    var locator: AppLocator
    var keychain: CLIKeychain
    var session: URLSession
    var hostName: () -> String?
    var openURL: (URL) throws -> Void
    var executableURL: URL?
    var timeZone: TimeZone
    var runEditor: (String, URL) throws -> Int32

    static func live() -> CLIContext {
        CLIContext(io: .live(), environment: ProcessInfo.processInfo.environment, locator: .live(), keychain: CLIKeychain(),
                   session: .shared, hostName: { Host.current().localizedName }, openURL: openWithLaunchServices,
                   executableURL: Bundle.main.executableURL, timeZone: .current, runEditor: CLIEditor.runEditor)
    }

    static func openWithLaunchServices(_ url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.absoluteString]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CLIFailure(exit: .error, message: "Couldn't open \(url.absoluteString).") }
    }
}

/// Ends the command with `exit` after it has printed its own message.
struct CLIQuietExit: Error {
    var exit: CLIExit
}

struct CLI {
    static let mcpMessage = "noteit mcp isn't in this version of NoteIt."
    static let dailyUnavailableMessage = "Daily notes aren't available in this version."
    static let apiOffMessage = "The Local API is off. Turn it on in NoteIt › Settings › Integrations."
    static let notSignedInMessage = "Not signed in. Run noteit auth login."
    static let codePrompt = "Enter the code shown in NoteIt: "

    var context: CLIContext
    private var io: CLIIO { context.io }

    func run(_ arguments: [String]) async -> CLIExit {
        do {
            try await dispatch(arguments)
            return .ok
        } catch let quiet as CLIQuietExit {
            return quiet.exit
        } catch {
            let (exit, message) = CLIOutput.report(error)
            io.errorLine("noteit: \(message)")
            if exit == .usage, let name = arguments.first, CommandSpec.named(name) != nil, name != "help" {
                io.errorLine("Run noteit help \(name) for its options.")
            }
            return exit
        }
    }

    /// `noteit --version`; CLIVersion is the only place the version is worked out.
    func version(executableURL: URL? = Bundle.main.executableURL) -> String {
        "noteit \(CLIVersion.current(executableURL: executableURL))"
    }

    private func dispatch(_ arguments: [String]) async throws {
        guard let name = arguments.first else {
            io.err(Self.overview())
            throw CLIQuietExit(exit: .usage)
        }
        switch name {
        case "--version":
            io.line(version(executableURL: context.executableURL))
            return
        case "--help", "-h":
            io.out(Self.overview())
            return
        case "mcp":
            io.errorLine(Self.mcpMessage)
            throw CLIQuietExit(exit: .usage)
        default:
            break
        }
        let parsed = try CLIArguments.parse(arguments).get()
        guard let spec = CommandSpec.named(parsed.command) else { throw CLIUsageError(message: "Unknown command “\(name)”.") }
        if parsed.has("help") {
            io.out(Self.help(for: spec))
            return
        }
        if name == "help" { return try help(parsed) }
        let profile = try CLIProfile.resolve(flag: parsed.value("profile"), environment: context.environment)
        let command = Command(cli: self, parsed: parsed, profile: profile)
        switch name {
        case "new": try await command.new()
        case "append": try await command.append()
        case "show": try await command.show()
        case "list": try await command.list()
        case "search": try await command.search()
        case "edit": try await command.edit()
        case "rm": try await command.remove()
        case "open": try command.open()
        case "notebooks": try await command.notebooks()
        case "tags": try await command.tags()
        case "attach": try await command.attach()
        case "today": try await command.today()
        case "watch": try await command.watch()
        case "api": try await command.api()
        case "auth": try await command.auth()
        case "status": try await command.status()
        default: throw CLIUsageError(message: "Unknown command “\(name)”.")
        }
    }

    private func help(_ parsed: CLIInvocation) throws {
        guard let topic = parsed.positionals.first else {
            io.out(Self.overview())
            return
        }
        if topic == "mcp" {
            io.errorLine(Self.mcpMessage)
            throw CLIQuietExit(exit: .usage)
        }
        guard parsed.positionals.count == 1, let spec = CommandSpec.named(topic) else {
            throw CLIUsageError(message: "There's no command called “\(topic)”. Run noteit help for a list.")
        }
        io.out(Self.help(for: spec))
    }

    static func overview() -> String {
        let width = CommandSpec.all.map(\.name.count).max() ?? 0
        let rows = CommandSpec.all.map { "  " + $0.name.padding(toLength: width + 2, withPad: " ", startingAt: 0) + $0.summary }
        return (["usage: noteit COMMAND [options]", "", "Commands:"] + rows + [""] + globalOptionLines()
            + ["", "Run noteit help COMMAND for a command's options."]).joined(separator: "\n") + "\n"
    }

    static func help(for spec: CommandSpec) -> String {
        (["usage: \(spec.usage)", "", spec.summary, ""] + globalOptionLines()).joined(separator: "\n") + "\n"
    }

    private static func globalOptionLines() -> [String] {
        [
            "Options for every command:",
            "  --json          Print the Local API's JSON unchanged",
            "  --profile NAME  Use another sign-in (also NOTEIT_PROFILE); the default is \"default\"",
            "  --no-launch     Don't open NoteIt when it isn't running",
            "  --version       Print noteit's version",
        ]
    }
}

/// One run of a command with its parsed arguments.
private struct Command {
    let cli: CLI
    let parsed: CLIInvocation
    let profile: String

    private var context: CLIContext { cli.context }
    private var io: CLIIO { context.io }
    private var json: Bool { parsed.has("json") }

    // MARK: Connecting

    private var storedToken: String? {
        AppEnvironment.nonEmpty("TOKEN", in: context.environment) ?? context.keychain.token(profile: profile)
    }

    private func connect(signedIn: Bool = true, launch: Bool? = nil) async throws -> NoteItAPIClient {
        var token: String?
        if signedIn {
            guard let stored = storedToken else { throw CLIFailure(exit: .unauthorized, message: CLI.notSignedInMessage) }
            token = stored
        } else {
            token = storedToken
        }
        if AppLocator.invalidAPIURL(in: context.environment) != nil {
            io.errorLine("noteit: " + AppLocator.invalidAPIURLMessage)
            throw CLIQuietExit(exit: .usage)
        }
        let launches = launch ?? !parsed.has("no-launch")
        switch await context.locator.locate(launch: launches) {
        case .ready(let url):
            return NoteItAPIClient(baseURL: url, token: token, session: context.session)
        case .apiDisabled:
            throw CLIFailure(exit: .unreachable, message: CLI.apiOffMessage)
        case .notRunning:
            throw CLIFailure(exit: .unreachable, message: launches ? CLIOutput.notReachableMessage : "NoteIt isn't running.")
        }
    }

    /// The response body of a 2xx reply; anything else throws its API error.
    private func fetch(_ client: NoteItAPIClient, _ method: HTTPMethod, _ path: String, query: [String: String] = [:],
                       json body: (any Encodable)? = nil, headers: [String: String] = [:]) async throws -> Data {
        var data: Data?
        var allHeaders = headers
        if let body {
            data = try APIJSON.encoder().encode(body)
            allHeaders["Content-Type"] = "application/json"
        }
        let (status, reply) = try await client.sendRaw(method, path, query: query, body: data, headers: allHeaders)
        guard (200..<300).contains(status) else { throw NoteItAPIError(status: status, body: reply) }
        return reply
    }

    private func decode<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
        try APIJSON.decoder().decode(type, from: data)
    }

    // MARK: Inputs

    private func noteID(_ text: String?) throws -> String {
        guard let text else { throw CLIUsageError(message: "Give a note id.") }
        guard let id = UUID(uuidString: text) else { throw CLIUsageError(message: "“\(text)” isn't a note id.") }
        return id.uuidString
    }

    /// The text argument, or stdin when it is `-`, or absent while stdin isn't a terminal. Trailing newlines from
    /// stdin are dropped.
    private func text(_ argument: String?) -> String? {
        if let argument, argument != "-" { return argument }
        guard argument == "-" || !io.stdinIsTerminal else { return nil }
        var text = String(decoding: io.readStdin(), as: UTF8.self)
        while text.hasSuffix("\n") || text.hasSuffix("\r") { text.removeLast() }
        return text
    }

    private func noExtraArguments(after count: Int) throws {
        if parsed.positionals.count > count {
            throw CLIUsageError(message: "Unexpected “\(parsed.positionals[count])”. Put text with spaces in quotes.")
        }
    }

    private func limit() throws -> String? {
        guard let value = parsed.value("limit") else { return nil }
        guard let number = Int(value), (1...500).contains(number) else {
            throw CLIUsageError(message: "--limit must be a number from 1 to 500.")
        }
        return String(number)
    }

    private func daily<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as NoteItAPIError where error.code == .notImplemented {
            throw CLIFailure(exit: .error, message: CLI.dailyUnavailableMessage)
        }
    }

    // MARK: Notes

    func new() async throws {
        try noExtraArguments(after: 1)
        let body = text(parsed.positionals.first)
        let title = parsed.value("title")
        guard body != nil || title != nil else { throw CLIUsageError(message: "Give the note's text, or pipe it in.") }
        let notebook = parsed.value("notebook")
        let notebookID = notebook.flatMap(UUID.init(uuidString:))
        let tags = parsed.values("tag")
        let request = CreateNoteRequest(title: title, body: body ?? "", notebookID: notebookID,
                                        notebook: notebookID == nil ? notebook : nil, tags: tags.isEmpty ? nil : tags)
        let client = try await connect()
        let data = try await fetch(client, .POST, "/notes", json: request)
        let note = try decode(data, as: NoteDTO.self)
        if parsed.has("open") {
            _ = try await client.send(.POST, "/notes/\(note.summary.id.uuidString)/open", as: APINoContent.self)
        }
        json ? io.passThrough(data) : io.line(note.summary.id.uuidString)
    }

    func append() async throws {
        let today = parsed.has("today")
        let title = parsed.value("title")
        let byID = !today && title == nil
        guard [today, title != nil].filter({ $0 }).count <= 1 else {
            throw CLIUsageError(message: "Use one of ID, --title or --today.")
        }
        let textIndex = byID ? 1 : 0
        try noExtraArguments(after: textIndex + 1)
        let id = byID ? try noteID(parsed.positionals.first) : nil
        let argument = parsed.positionals.count > textIndex ? parsed.positionals[textIndex] : nil
        guard let text = text(argument), !text.isEmpty else {
            throw CLIUsageError(message: "Give the text to add, or pipe it in.")
        }
        if today {
            guard !parsed.has("start") else { throw CLIUsageError(message: "--start doesn't work with --today.") }
            let client = try await connect()
            let data = try await daily {
                try await fetch(client, .POST, "/daily/append", json: DailyAppendRequest(text: text))
            }
            if json { io.passThrough(data) }
            return
        }
        let client = try await connect()
        let target: String
        if let id {
            target = id
        } else {
            target = try await noteID(titled: title ?? "", client: client)
        }
        let request = AppendRequest(text: text, position: parsed.has("start") ? .start : nil,
                                    timestamp: parsed.has("time") ? true : nil)
        let data = try await fetch(client, .POST, "/notes/\(target)/append", json: request)
        if json { io.passThrough(data) }
    }

    private func noteID(titled title: String, client: NoteItAPIClient) async throws -> String {
        let page = try await client.send(.GET, "/notes", query: ["q": title, "limit": "500"], as: Page<NoteSummaryDTO>.self)
        let match = page.items.first { $0.title == title }
            ?? page.items.first { $0.title.compare(title, options: [.caseInsensitive]) == .orderedSame }
        guard let match else { throw CLIFailure(exit: .notFound, message: "No note is titled “\(title)”.") }
        return match.id.uuidString
    }

    func show() async throws {
        try noExtraArguments(after: 1)
        let id = try noteID(parsed.positionals.first)
        let format = parsed.value("format") ?? "markdown"
        guard ["markdown", "text", "html"].contains(format) else {
            throw CLIUsageError(message: "--format must be markdown, text or html.")
        }
        let client = try await connect()
        let data = try await fetch(client, .GET, "/notes/\(id)", query: ["format": format])
        if json { return io.passThrough(data) }
        let body = try decode(data, as: NoteDTO.self).body
        io.out(body.hasSuffix("\n") || body.isEmpty ? body : body + "\n")
    }

    func list() async throws {
        try noExtraArguments(after: 0)
        var query: [String: String] = [:]
        query["notebook"] = parsed.value("notebook")
        query["tag"] = parsed.value("tag")
        query["limit"] = try limit()
        let client = try await connect()
        let data = try await fetch(client, .GET, "/notes", query: query)
        if json { return io.passThrough(data) }
        CLIOutput.noteLines(try decode(data, as: Page<NoteSummaryDTO>.self).items, timeZone: context.timeZone).forEach(io.line)
    }

    func search() async throws {
        let text = parsed.positionals.joined(separator: " ")
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { throw CLIUsageError(message: "Give something to search for.") }
        var query = ["q": text]
        query["limit"] = try limit()
        let client = try await connect()
        let data = try await fetch(client, .GET, "/search", query: query)
        if json { return io.passThrough(data) }
        CLIOutput.searchLines(try decode(data, as: SearchResponseDTO.self).results).forEach(io.line)
    }

    func edit() async throws {
        try noExtraArguments(after: 1)
        let id = try noteID(parsed.positionals.first)
        let client = try await connect()
        let note = try await client.send(.GET, "/notes/\(id)", query: ["format": "markdown"], as: NoteDTO.self)
        guard let edited = try CLIEditor.edit(note.body, environment: context.environment, run: context.runEditor) else {
            throw CLIFailure(exit: .error, message: "The editor quit with an error, so the note wasn't changed.")
        }
        guard edited != note.body else {
            io.line("No changes.")
            return
        }
        var headers: [String: String] = [:]
        if let revision = note.summary.revision { headers["If-Match"] = "\"\(revision.uuidString)\"" }
        do {
            _ = try await client.send(.PATCH, "/notes/\(id)", json: PatchNoteRequest(body: edited, format: .markdown),
                                      headers: headers, as: NoteDTO.self)
        } catch let error as NoteItAPIError where error.code == .revisionMismatch {
            let title = "\(CLIOutput.title(note.summary.title)) (edited in terminal)"
            let copy = try await client.send(.POST, "/notes",
                                             json: CreateNoteRequest(title: title, body: Self.dropTitleLine(edited, title: note.summary.title),
                                                                     format: .markdown, notebookID: note.summary.notebookID),
                                             as: NoteDTO.self)
            io.errorLine("noteit: The note changed in NoteIt while you were editing it, so your text was saved as a new note, “\(title)” (\(copy.summary.id.uuidString)).")
            throw CLIQuietExit(exit: .conflict)
        }
    }

    /// The copy gets its own title, so the original title line isn't repeated under it.
    static func dropTitleLine(_ markdown: String, title: String) -> String {
        var lines = markdown.components(separatedBy: "\n")
        guard let first = lines.first else { return markdown }
        let heading = first.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, heading == title.trimmingCharacters(in: .whitespaces) else { return markdown }
        lines.removeFirst()
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        return lines.joined(separator: "\n")
    }

    func remove() async throws {
        try noExtraArguments(after: 1)
        let id = try noteID(parsed.positionals.first)
        let client = try await connect()
        _ = try await client.send(.DELETE, "/notes/\(id)", query: parsed.has("permanent") ? ["permanent": "true"] : [:],
                                  as: APINoContent.self)
    }

    func open() throws {
        try noExtraArguments(after: 1)
        let id = try noteID(parsed.positionals.first)
        guard let url = URL(string: "\(AppIdentity.urlScheme)://note/\(id)") else { return }
        try context.openURL(url)
    }

    func notebooks() async throws {
        try noExtraArguments(after: 0)
        let client = try await connect()
        let data = try await fetch(client, .GET, "/notebooks")
        if json { return io.passThrough(data) }
        CLIOutput.notebookLines(try decode(data, as: NotebooksResponseDTO.self)).forEach(io.line)
    }

    func tags() async throws {
        try noExtraArguments(after: 0)
        let client = try await connect()
        let data = try await fetch(client, .GET, "/tags")
        if json { return io.passThrough(data) }
        CLIOutput.tagLines(try decode(data, as: [TagDTO].self)).forEach(io.line)
    }

    func attach() async throws {
        try noExtraArguments(after: 2)
        let id = try noteID(parsed.positionals.first)
        guard parsed.positionals.count == 2 else { throw CLIUsageError(message: "Give the file to attach.") }
        let file = URL(fileURLWithPath: parsed.positionals[1])
        let contents: Data
        do {
            contents = try Data(contentsOf: file)
        } catch {
            throw CLIFailure(exit: .error, message: "Couldn't read \(file.path).")
        }
        let type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let client = try await connect()
        let (status, data) = try await client.sendRaw(.POST, "/notes/\(id)/attachments", body: contents, headers: [
            "Content-Type": type,
            "X-NoteIt-Filename": NoteItAPIClient.encode(file.lastPathComponent),
        ])
        guard (200..<300).contains(status) else { throw NoteItAPIError(status: status, body: data) }
        if json { io.passThrough(data) }
    }

    func today() async throws {
        try noExtraArguments(after: 1)
        let client = try await connect()
        let argument = parsed.positionals.first
        if let text = text(argument), !text.isEmpty || argument != nil {
            guard !text.isEmpty else { throw CLIUsageError(message: "Give the text to add, or pipe it in.") }
            let data = try await daily { try await fetch(client, .POST, "/daily/append", json: DailyAppendRequest(text: text)) }
            if json { io.passThrough(data) }
            return
        }
        let data = try await daily { try await fetch(client, .GET, "/daily") }
        if json { return io.passThrough(data) }
        let body = try decode(data, as: NoteDTO.self).body
        io.out(body.hasSuffix("\n") || body.isEmpty ? body : body + "\n")
    }

    func watch() async throws {
        try noExtraArguments(after: 0)
        let client = try await connect()
        let encoder = APIJSON.encoder()
        for try await change in client.events(since: nil) {
            io.line(String(decoding: try encoder.encode(change), as: UTF8.self))
        }
    }

    func api() async throws {
        try noExtraArguments(after: 2)
        guard parsed.positionals.count == 2 else { throw CLIUsageError(message: "Give a method and a path, such as GET /v1/notes.") }
        guard let method = HTTPMethod(rawValue: parsed.positionals[0].uppercased()), method != .OPTIONS else {
            throw CLIUsageError(message: "The method must be GET, POST, PATCH or DELETE.")
        }
        var path = parsed.positionals[1]
        if !path.hasPrefix("/") { path = "/" + path }
        if path == APIRoutes.basePath || path.hasPrefix(APIRoutes.basePath + "/") || path.hasPrefix(APIRoutes.basePath + "?") {
            path.removeFirst(APIRoutes.basePath.count)
        }
        var body: Data?
        var headers: [String: String] = [:]
        if let data = parsed.value("data") {
            body = try requestBody(data)
            headers["Content-Type"] = "application/json"
        }
        let client = try await connect(signedIn: false)
        let (status, reply) = try await client.sendRaw(method, path, body: body, headers: headers)
        if !reply.isEmpty { io.passThrough(reply) }
        guard (200..<300).contains(status) else { throw NoteItAPIError(status: status, body: reply) }
    }

    private func requestBody(_ value: String) throws -> Data {
        guard value.hasPrefix("@") else { return Data(value.utf8) }
        let path = String(value.dropFirst())
        if path == "-" { return io.readStdin() }
        do {
            return try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw CLIFailure(exit: .error, message: "Couldn't read \(path).")
        }
    }

    // MARK: Housekeeping

    func auth() async throws {
        guard let action = parsed.positionals.first else { throw CLIUsageError(message: "Use auth login, auth logout or auth status.") }
        try noExtraArguments(after: 1)
        switch action {
        case "login": try await login()
        case "logout": try await logout()
        case "status": try await authStatus()
        default: throw CLIUsageError(message: "Use auth login, auth logout or auth status.")
        }
    }

    private func scopes() throws -> [APIScope] {
        guard let value = parsed.value("scopes") else { return [.read, .write] }
        var scopes: [APIScope] = []
        for name in value.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !name.isEmpty {
            guard let scope = APIScope(rawValue: name) else {
                throw CLIUsageError(message: "--scopes takes read, write and admin, separated by commas.")
            }
            scopes.append(scope)
        }
        guard !scopes.isEmpty else { throw CLIUsageError(message: "--scopes takes read, write and admin, separated by commas.") }
        return APIScope.normalized(scopes)
    }

    private func login() async throws {
        let scopes = try scopes()
        let client: NoteItAPIClient
        do {
            client = try await connect(signedIn: false)
        } catch let failure as CLIFailure where failure.message == CLI.apiOffMessage {
            if io.stdinIsTerminal, let url = URL(string: "\(AppIdentity.urlScheme)://settings?tab=integrations") {
                try? context.openURL(url)
            }
            throw failure
        }
        let name = "noteit CLI on \(context.hostName() ?? "this Mac")"
        let started = try await client.send(.POST, "/pair/start", json: PairStartRequest(clientName: name, kind: .cli, scopes: scopes),
                                            as: PairStartResponse.self)
        for attempt in 1...PairingBroker.maxAttempts {
            io.err(CLI.codePrompt)
            guard let line = io.readLine() else { throw CLIFailure(exit: .unauthorized, message: "Pairing cancelled.") }
            let code = line.filter { !$0.isWhitespace }
            do {
                let paired = try await client.send(.POST, "/pair/complete",
                                                   json: PairCompleteRequest(pairingID: started.pairingID, code: code),
                                                   as: PairCompleteResponse.self)
                try context.keychain.save(paired.token, profile: profile)
                io.line("Paired as “\(name)” with \(paired.scopes.map(\.rawValue).joined(separator: ", ")) access.")
                return
            } catch let error as NoteItAPIError where error.code == .pairingFailed && attempt < PairingBroker.maxAttempts {
                io.errorLine("That code didn't match. Try again.")
            }
        }
    }

    private func logout() async throws {
        guard let token = storedToken else {
            io.line("Not signed in.")
            return
        }
        if case .ready(let url) = await context.locator.locate(launch: false) {
            let client = NoteItAPIClient(baseURL: url, token: token, session: context.session)
            _ = try? await client.sendRaw(.DELETE, "/me", body: nil)
        }
        try context.keychain.remove(profile: profile)
        io.line("Signed out.")
    }

    private func authStatus() async throws {
        let client = try await connect()
        let data = try await fetch(client, .GET, "/me")
        json ? io.passThrough(data) : io.line(CLIOutput.clientLine(try decode(data, as: ClientDTO.self)))
    }

    func status() async throws {
        try noExtraArguments(after: 0)
        let client = try await connect(signedIn: false, launch: false)
        let pingData = try await fetch(client, .GET, "/ping")
        if json { return io.passThrough(pingData) }
        let ping = try decode(pingData, as: PingDTO.self)
        io.line("NoteIt \(ping.appVersion) is running. Local API: \(client.baseURL.absoluteString)")
        guard client.token != nil else {
            io.line(CLI.notSignedInMessage)
            throw CLIQuietExit(exit: .unauthorized)
        }
        let me = try await client.send(.GET, "/me", as: ClientDTO.self)
        io.line(CLIOutput.clientLine(me))
    }
}
