import AppKit
import Combine
import NoteItAPI
import NoteItSync

/// Runs the Local API server while Settings › Integrations allows it, keeps `local-api.json` current, feeds
/// library changes to the event stream and shows the pairing window.
@MainActor
final class LocalAPIController: ObservableObject {
    enum Status: Equatable {
        case off
        case on(UInt16)
        case portInUse(UInt16)
        case failed(String)
    }

    nonisolated static let automaticPorts: [UInt16] = Array(47600...47609)
    nonisolated static let lastUsedInterval: TimeInterval = 60

    static let shared = LocalAPIController.makeShared()

    @Published private(set) var status: Status = .off
    /// Bumped when a client pairs or is revoked, so Settings can refresh its list.
    @Published private(set) var clientsGeneration = 0

    let registry: ClientRegistry
    let hub: ChangeHub
    let pairing: PairingBroker
    let clients: AutomationClients

    private let server: LocalHTTPServer
    private let service: AutomationService
    private let defaults: UserDefaults
    private let discoveryDirectory: URL?
    private let ports: [UInt16]
    private let forceEnabled: Bool
    private let appVersion: String
    private let startedAt = Date()
    private let lastUsed: LastUsedTracker
    private let feed: LibraryChangeFeed
    private var feedSubscription: AnyCancellable?
    private var defaultsObserver: NSObjectProtocol?
    private var applied: [UInt16]??
    private var transition: Task<Void, Never>?
    private var pairingWindow: PairingWindow?

    init(service: AutomationService, defaults: UserDefaults = .standard, clientStore: ClientStore,
         discoveryDirectory: URL?, automaticPorts: [UInt16] = LocalAPIController.automaticPorts,
         routeRegistry: LocalAPIRouteRegistry = .shared, forceEnabled: Bool = false,
         appVersion: String = LocalAPIController.bundleVersion, showsPairingWindow: Bool = true) {
        self.service = service
        self.defaults = defaults
        self.discoveryDirectory = discoveryDirectory
        self.ports = automaticPorts
        self.forceEnabled = forceEnabled
        self.appVersion = appVersion
        let registry = ClientRegistry(store: clientStore)
        let hub = ChangeHub()
        let pairing = PairingBroker(registry: registry)
        let lastUsed = LastUsedTracker(defaults: defaults)
        self.registry = registry
        self.hub = hub
        self.pairing = pairing
        self.lastUsed = lastUsed
        clients = AutomationClients(registry: registry, lastUsed: { lastUsed.date(for: $0) })
        let version = appVersion
        let dailyAvailable = service.dailyNotesAvailable
        server = LocalHTTPServer(
            registry: registry, pairing: pairing, changes: hub, limiter: RateLimiter(),
            responder: LocalAPIHandlers(service: service, registry: routeRegistry),
            ping: { PingDTO(name: "NoteIt", apiVersion: 1, appVersion: version, capabilities: (dailyAvailable() ? ["daily"] : []) + ["events", "attachments"]) },
            routeRegistry: routeRegistry)
        server.onAuthenticated = { [weak lastUsed] id in lastUsed?.touch(id) }
        server.lastUsed = { [weak lastUsed] id in lastUsed?.date(for: id) }

        feed = LibraryChangeFeed(store: service.store)
        feedSubscription = feed.subscribe { [hub] changes in
            for change in changes { hub.publish(kind: change.kind, id: change.id, op: change.op, at: change.at) }
        }
        let revoked = registry.onRevoke
        registry.onRevoke = { [weak self] id in
            revoked?(id)
            Task { @MainActor in self?.clientsGeneration += 1 }
        }
        if showsPairingWindow {
            pairing.onEvent = { [weak self] event in
                Task { @MainActor in self?.handlePairing(event) }
            }
        }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.reconcile() }
        }
        writeDiscovery()
        reconcile()
    }

    deinit {
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
    }

    var isEnabled: Bool { forceEnabled || defaults.bool(forKey: PrefKey.localAPIEnabled) }

    /// 0 means automatic.
    var pinnedPort: UInt16? {
        let value = defaults.integer(forKey: PrefKey.localAPIPort)
        return (1024...65535).contains(value) ? UInt16(value) : nil
    }

    func clientsDidChange() {
        clientsGeneration += 1
    }

    /// Waits for every pending start or stop.
    func settle() async {
        while let current = transition {
            await current.value
            if transition == nil || transition == current { return }
        }
    }

    /// Stops the server and removes `local-api.json`, for quitting.
    func shutDown() {
        transition?.cancel()
        server.stop()
        if let discoveryDirectory { DiscoveryFile.remove(from: discoveryDirectory) }
    }

    func reconcile() {
        let wanted: [UInt16]? = isEnabled ? (pinnedPort.map { [$0] } ?? ports) : nil
        if let applied, applied == wanted { return }
        applied = .some(wanted)
        let previous = transition
        let task = Task { @MainActor [weak self] in
            await previous?.value
            await self?.apply(wanted)
        }
        transition = task
    }

    private func apply(_ wanted: [UInt16]?) async {
        server.stop()
        guard let wanted else {
            if let request = pairing.current { pairing.deny(request.id) }
            setStatus(.off)
            return
        }
        await service.assignMissingRevisionsForLocalAPI()
        guard case .some(.some(wanted)) = applied else { return }
        do {
            let port = try await server.start(ports: wanted)
            setStatus(.on(port))
        } catch LocalHTTPServerError.portInUse(let port) {
            setStatus(.portInUse(port))
        } catch LocalHTTPServerError.stopped {
            return
        } catch {
            setStatus(.failed(String(describing: error)))
        }
    }

    private func setStatus(_ new: Status) {
        status = new
        writeDiscovery()
    }

    private func writeDiscovery() {
        guard let discoveryDirectory else { return }
        var port: UInt16?
        if case .on(let bound) = status { port = bound }
        let file = DiscoveryFile(pid: ProcessInfo.processInfo.processIdentifier, appVersion: appVersion,
                                 apiEnabled: port != nil, port: port,
                                 baseURL: port.flatMap { URL(string: "http://127.0.0.1:\($0)/v1") }, startedAt: startedAt)
        do {
            try file.write(to: discoveryDirectory)
        } catch {
            NSLog("NoteIt: couldn't write \(DiscoveryFile.fileName): \(error)")
        }
    }

    // MARK: - Pairing

    private func handlePairing(_ event: PairingEvent) {
        switch event {
        case .started(let request):
            let window = pairingWindow ?? PairingWindow()
            pairingWindow = window
            window.show(request,
                        deny: { [weak self] in self?.pairing.deny(request.id) },
                        grant: { [weak self] scopes in self?.pairing.setGrantedScopes(scopes, for: request.id) },
                        expire: { [weak self] in _ = self?.pairing.current })
        case .finished(let id, let success):
            if success { clientsGeneration += 1 }
            if success { pairingWindow?.showPaired(id) } else { pairingWindow?.close(id) }
        case .cancelled(let id, let reason):
            if reason == PairingBroker.tooManyAttemptsReason {
                pairingWindow?.showMessage(reason, for: id)
            } else {
                pairingWindow?.close(id)
            }
        }
    }

    // MARK: - Shared instance

    nonisolated static var bundleVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    private static func makeShared() -> LocalAPIController {
        #if DEBUG
        if AppEnvironment.value("LOCAL_API_DEBUG") == "1", AppEnvironment.nonEmpty("DATA_DIR") != nil {
            let controller = LocalAPIController(service: .shared, clientStore: InMemoryClientStore(),
                                                discoveryDirectory: DiscoveryFile.directory(), forceEnabled: true)
            if let (_, token) = try? controller.registry.issue(name: "Debug", kind: .script, scopes: [.admin], origin: nil) {
                FileHandle.standardError.write(Data("NOTEIT_LOCAL_API_TOKEN=\(token)\n".utf8))
            }
            return controller
        }
        #endif
        return LocalAPIController(service: .shared, clientStore: KeychainClientStore(),
                                  discoveryDirectory: DiscoveryFile.directory())
    }
}

/// `lastUsedAt` per client: kept in memory for every request, written to `localAPIClientLastUsed` at most once a
/// minute per client.
final class LastUsedTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var dates: [UUID: Date]
    private var written: [UUID: Date]
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date

    init(defaults: UserDefaults, now: @escaping @Sendable () -> Date = { Date() }) {
        self.defaults = defaults
        self.now = now
        let stored = defaults.dictionary(forKey: PrefKey.localAPIClientLastUsed) as? [String: Date] ?? [:]
        let loaded = Dictionary(stored.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } },
                                uniquingKeysWith: { first, _ in first })
        dates = loaded
        written = loaded
    }

    func date(for id: UUID) -> Date? { lock.withLock { dates[id] } }

    func touch(_ id: UUID) {
        let date = now()
        let snapshot = lock.withLock { () -> [String: Date]? in
            dates[id] = date
            if let last = written[id], date.timeIntervalSince(last) < LocalAPIController.lastUsedInterval { return nil }
            written[id] = date
            return Dictionary(uniqueKeysWithValues: written.map { ($0.key.uuidString, $0.value) })
        }
        if let snapshot { defaults.set(snapshot, forKey: PrefKey.localAPIClientLastUsed) }
    }
}
