import Foundation
import NoteItAPI
@testable import NoteItCLI
import NoteItSync

final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Never the login Keychain.
final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let items = Box<[String: String]>([:])

    func read(service: String, account: String) -> String? { items.value["\(service)/\(account)"] }
    func write(_ value: String, service: String, account: String) throws { items.value["\(service)/\(account)"] = value }
    func remove(service: String, account: String) throws { items.value["\(service)/\(account)"] = nil }
}

/// Captured terminal output and scripted input for one CLI run.
final class Terminal {
    var out = ""
    var err = ""
    var lines: [String] = []
    var stdin: Data?
    var openedURLs: [URL] = []

    var io: CLIIO {
        CLIIO(out: { self.out += $0 }, err: { self.err += $0 },
              readLine: { self.lines.isEmpty ? nil : self.lines.removeFirst() },
              stdinIsTerminal: stdin == nil, readStdin: { self.stdin ?? Data() })
    }
}

/// Records requests and answers from a closure.
struct ScriptedResponder: LocalAPIResponder {
    let requests = Box<[HTTPRequest]>([])
    let answer: @Sendable (LocalAPIContext) -> HTTPResponse

    func respond(_ context: LocalAPIContext) async -> HTTPResponse {
        requests.value.append(context.request)
        return answer(context)
    }
}

/// A Local API server on port 0 and a CLI pointed at it with `NOTEIT_API_URL`.
final class CLIHarness {
    let clients = ClientRegistry(store: InMemoryClientStore())
    let responder: ScriptedResponder
    let server: LocalHTTPServer
    let secrets = InMemorySecretStore()
    let terminal = Terminal()
    let session = URLSession(configuration: .ephemeral)
    var environment: [String: String] = [:]
    var editor: (String, URL) throws -> Int32 = { _, _ in 0 }

    init(answer: @escaping @Sendable (LocalAPIContext) -> HTTPResponse = { _ in .error(.notFound, "No note with that id.") }) {
        responder = ScriptedResponder(answer: answer)
        server = LocalHTTPServer(registry: clients, pairing: PairingBroker(registry: clients, code: { "123456" }),
                                 changes: ChangeHub(), limiter: RateLimiter(), responder: responder,
                                 ping: { PingDTO(name: "NoteIt", apiVersion: 1, appVersion: "9.9", capabilities: []) },
                                 routeRegistry: LocalAPIRouteRegistry())
    }

    func start() async throws {
        let port = try await server.start(ports: [0])
        environment["NOTEIT_API_URL"] = "http://127.0.0.1:\(port)"
    }

    func signIn(scopes: [APIScope] = [.read, .write]) throws {
        let (_, token) = try clients.issue(name: "Test", kind: .cli, scopes: scopes, origin: nil)
        environment["NOTEIT_TOKEN"] = token
    }

    var keychain: CLIKeychain { CLIKeychain(store: secrets, service: "test.noteit.cli") }

    func run(_ arguments: [String]) async -> CLIExit {
        let environment = environment
        let terminal = terminal
        let context = CLIContext(
            io: terminal.io, environment: environment,
            locator: AppLocator(environment: environment, readDiscovery: { nil }, launchApp: {},
                                ping: { _ in true }, sleep: { _ in }),
            keychain: keychain, session: session, hostName: { "Studio" },
            openURL: { terminal.openedURLs.append($0) }, executableURL: nil,
            timeZone: TimeZone(identifier: "Europe/Stockholm")!, runEditor: editor)
        return await CLI(context: context).run(arguments)
    }

    func stop() {
        server.stop()
        session.invalidateAndCancel()
    }
}

/// A CLI that never reaches a server, for what happens before connecting.
func offlineCLI(_ terminal: Terminal, environment: [String: String] = [:], executableURL: URL? = nil) -> CLI {
    CLI(context: CLIContext(
        io: terminal.io, environment: environment,
        locator: AppLocator(environment: [:], readDiscovery: { nil }, launchApp: {}, ping: { _ in false }, sleep: { _ in }),
        keychain: CLIKeychain(store: InMemorySecretStore(), service: "test.noteit.cli"), session: .shared,
        hostName: { nil }, openURL: { _ in }, executableURL: executableURL, timeZone: TimeZone(identifier: "UTC")!,
        runEditor: { _, _ in 0 }))
}

func summary(_ id: UUID = UUID(), title: String, updatedAt: Date = Date(timeIntervalSince1970: 1_790_000_000),
             revision: UUID? = UUID()) -> NoteSummaryDTO {
    NoteSummaryDTO(id: id, title: title, notebookID: nil, notebookName: nil, tags: [], pinned: false, createdAt: updatedAt,
                   updatedAt: updatedAt, revision: revision, deletedAt: nil, preview: "", conflict: false, locked: false,
                   url: "noteit://note/\(id.uuidString)")
}
