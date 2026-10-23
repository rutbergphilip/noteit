import Foundation
import Network
import NoteItSync
import os

/// Answers the built-in note, notebook, tag, attachment, search and daily routes (the app's `LocalAPIHandlers`).
public protocol LocalAPIResponder: Sendable {
    func respond(_ context: LocalAPIContext) async -> HTTPResponse
}

public enum LocalHTTPServerError: Error, Equatable, Sendable {
    case noPorts
    case alreadyRunning
    /// `stop()` was called before a pending `start(ports:)` finished.
    case stopped
    case portInUse(UInt16)
    case failed(String)
}

/// The Local API transport: an HTTP/1.1 server on 127.0.0.1 only, built on Network.framework (automation spec §6.1).
/// Every request goes through the pipeline of spec §6.6 before a handler sees it. Routes are `APIRoutes.all` plus the
/// routes in `routeRegistry`.
public final class LocalHTTPServer: @unchecked Sendable {
    public static let maxConnections = 32
    /// Registered routes may raise their body limit up to this.
    public static let maxBodyCap = 60_000_000

    let registry: ClientRegistry
    let pairing: PairingBroker
    let changes: ChangeHub
    let limiter: RateLimiter
    let responder: LocalAPIResponder
    let ping: @Sendable () -> PingDTO
    let limits: HTTPParserLimits
    let routeRegistry: LocalAPIRouteRegistry
    let queue = DispatchQueue(label: "\(AppIdentity.bundleID).local-api")
    private let queueKey = DispatchSpecificKey<Bool>()
    private let logger = Logger(subsystem: AppIdentity.bundleID, category: "LocalAPI")

    var idleTimeout: TimeInterval = 30
    var heartbeatInterval: TimeInterval = 15
    /// After answering and closing early, unread request bytes are drained this long, up to this many (RFC 9112 §9.6).
    var lingerTimeout: TimeInterval = 2
    var lingerDiscardLimit = 16_000_000
    /// Tests: runs on the queue right after a listener starts and before it's ready.
    var listenerStarted: (() -> Void)?

    // Touched on `queue` only.
    private var listener: NWListener?
    /// Set while `start(ports:)` runs; `stop()` clears it so the pending start gives up.
    private var startToken: UUID?
    private var pendingListener: NWListener?
    private var connections: [ObjectIdentifier: Connection] = [:]
    /// Over-capacity connections being answered `503`; capped separately so they can't pile up.
    private var rejected: [ObjectIdentifier: Connection] = [:]
    private var port: UInt16 = 0

    private let hooksLock = NSLock()
    private var authenticatedHandler: (@Sendable (UUID) -> Void)?
    private var lastUsedProvider: (@Sendable (UUID) -> Date?)?

    public init(registry: ClientRegistry, pairing: PairingBroker, changes: ChangeHub, limiter: RateLimiter,
                responder: LocalAPIResponder, ping: @escaping @Sendable () -> PingDTO, limits: HTTPParserLimits = .init(),
                routeRegistry: LocalAPIRouteRegistry = .shared) {
        self.registry = registry
        self.pairing = pairing
        self.changes = changes
        self.limiter = limiter
        self.responder = responder
        self.ping = ping
        self.limits = limits
        self.routeRegistry = routeRegistry
        queue.setSpecific(key: queueKey, value: true)
        let previous = registry.onRevoke
        registry.onRevoke = { [changes] id in
            previous?(id)
            changes.closeAll(client: id)
        }
    }

    /// Called with the client id after each request that authenticated (for `lastUsedAt`).
    public var onAuthenticated: (@Sendable (UUID) -> Void)? {
        get { hooksLock.withLock { authenticatedHandler } }
        set { hooksLock.withLock { authenticatedHandler = newValue } }
    }

    /// `lastUsedAt` for `GET /v1/me` and `GET /v1/clients`.
    public var lastUsed: (@Sendable (UUID) -> Date?)? {
        get { hooksLock.withLock { lastUsedProvider } }
        set { hooksLock.withLock { lastUsedProvider = newValue } }
    }

    /// Tests: connections holding a slot, and over-capacity ones being answered `503`.
    var connectionCounts: (open: Int, rejected: Int) { onQueue { (connections.count, rejected.count) } }

    /// Tries each port in order and returns the bound one. Port 0 = ephemeral (tests). Throws `.portInUse(port)`
    /// when the last port tried was taken.
    /// Throws `.alreadyRunning` while running or while another start is pending, and `.stopped` when `stop()` is
    /// called before binding finishes.
    public func start(ports: [UInt16]) async throws -> UInt16 {
        let token = UUID()
        let claimed = onQueue { () -> Bool in
            guard listener == nil, startToken == nil else { return false }
            startToken = token
            return true
        }
        guard claimed else { throw LocalHTTPServerError.alreadyRunning }
        defer { onQueue { if startToken == token { startToken = nil } } }
        var lastError = LocalHTTPServerError.noPorts
        for port in ports {
            do {
                return try await bind(port, token: token)
            } catch LocalHTTPServerError.stopped {
                throw LocalHTTPServerError.stopped
            } catch let error as LocalHTTPServerError {
                lastError = error
            }
        }
        throw lastError
    }

    /// Stops listening and closes every connection; a request still being handled is answered with
    /// `503 api_disabled`.
    public func stop() {
        onQueue {
            startToken = nil
            pendingListener?.cancel()
            pendingListener = nil
            listener?.cancel()
            listener = nil
            for connection in Array(connections.values) + Array(rejected.values) { connection.shutDown() }
        }
    }

    // MARK: - Listening

    private func bind(_ port: UInt16, token: UUID) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1",
                                                     port: port == 0 ? .any : NWEndpoint.Port(rawValue: port) ?? .any)
        parameters.allowLocalEndpointReuse = false
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw Self.mapError(error, port: port)
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            queue.async { [self] in
                guard startToken == token else {
                    return continuation.resume(throwing: LocalHTTPServerError.stopped)
                }
                pendingListener = listener
                let once = Once()
                // Holds the listener until it settles, so a cancel from `stop()` still resumes the continuation.
                listener.stateUpdateHandler = { [weak self] state in
                    guard !once.done else { return }
                    guard let self else {
                        once.done = true
                        listener.cancel()
                        return continuation.resume(throwing: LocalHTTPServerError.stopped)
                    }
                    let current = self.startToken == token && self.pendingListener === listener
                    defer { if once.done { listener.stateUpdateHandler = nil } }
                    switch state {
                    case .ready:
                        once.done = true
                        guard current else {
                            listener.cancel()
                            return continuation.resume(throwing: LocalHTTPServerError.stopped)
                        }
                        let bound = listener.port?.rawValue ?? port
                        self.pendingListener = nil
                        self.listener = listener
                        self.port = bound
                        continuation.resume(returning: bound)
                    case .failed(let error), .waiting(let error):
                        once.done = true
                        listener.cancel()
                        if current { self.pendingListener = nil }
                        continuation.resume(throwing: current ? Self.mapError(error, port: port) : LocalHTTPServerError.stopped)
                    case .cancelled:
                        once.done = true
                        if current { self.pendingListener = nil }
                        continuation.resume(throwing: current ? LocalHTTPServerError.failed("The listener was cancelled.")
                                                              : LocalHTTPServerError.stopped)
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.start(queue: queue)
                listenerStarted?()
            }
        }
    }

    private static func mapError(_ error: Error, port: UInt16) -> LocalHTTPServerError {
        if case .posix(let code) = error as? NWError, code == .EADDRINUSE || code == .EACCES {
            return .portInUse(port)
        }
        return .failed(String(describing: error))
    }

    private func accept(_ nwConnection: NWConnection) {
        let connection = Connection(server: self, connection: nwConnection, policy: RequestPolicy(port: port))
        guard connections.count < Self.maxConnections else {
            guard rejected.count < Self.maxConnections else { return nwConnection.cancel() }
            var response = HTTPResponse.error(.rateLimited, "Too many open connections. Try again in a moment.")
            response.status = 503
            response.headers["Retry-After"] = "1"
            rejected[ObjectIdentifier(connection)] = connection
            connection.reject(response)
            return
        }
        connections[ObjectIdentifier(connection)] = connection
        connection.start()
    }

    fileprivate func removed(_ connection: Connection) {
        connections.removeValue(forKey: ObjectIdentifier(connection))
        rejected.removeValue(forKey: ObjectIdentifier(connection))
    }

    /// The parser takes the largest body any route allows; each route's own limit is checked against the head.
    fileprivate func parser() -> HTTPParser {
        var parserLimits = limits
        let registered = routeRegistry.routes.compactMap(\.maxBodyBytes).max() ?? 0
        parserLimits.maxBinaryBody = min(max(limits.maxBinaryBody, registered), Self.maxBodyCap)
        return HTTPParser(limits: parserLimits)
    }

    private func onQueue<T>(_ body: () -> T) -> T {
        DispatchQueue.getSpecific(key: queueKey) == true ? body() : queue.sync(execute: body)
    }

    // MARK: - Pipeline

    enum Outcome {
        case response(HTTPResponse, close: Bool)
        case stream(client: ClientRecord, cursor: String?, cors: HTTPHeaders)
    }

    /// `admitted`: `screen` already let this request's head through (and took its rate-limit token).
    func handle(_ request: HTTPRequest, policy: RequestPolicy, admitted: Bool = false) async -> Outcome {
        let started = DispatchTime.now()
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                             reason: "Local API request")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let (outcome, pattern) = await pipeline(request, policy: policy, admitted: admitted)
        log(request, pattern: pattern, outcome: outcome, started: started)
        return outcome
    }

    /// Runs the head-only steps of the pipeline (Host, Origin, route, Content-Type, the route's body limit against
    /// `contentLength`, rate limit, auth) before a body is read. nil = read the body; otherwise answer and close.
    func screen(_ head: HTTPRequest, contentLength: Int, policy: RequestPolicy) -> HTTPResponse? {
        let started = DispatchTime.now()
        let (gate, pattern) = admit(head, bodyLength: contentLength, policy: policy, consumeRate: true)
        guard case .done(let outcome) = gate else { return nil }
        log(head, pattern: pattern, outcome: outcome, started: started)
        guard case .response(let response, _) = outcome else { return Self.error(.badRequest) }
        return response
    }

    private func log(_ request: HTTPRequest, pattern: String?, outcome: Outcome, started: DispatchTime) {
        let status: Int
        switch outcome {
        case .response(let response, _): status = response.status
        case .stream: status = 200
        }
        let milliseconds = (DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
        logger.info("\(request.method, privacy: .public) \(pattern ?? "-", privacy: .public) \(status) \(milliseconds) ms")
    }

    private struct Admission {
        let match: RouteMatch
        let origin: OriginDecision
        let cors: HTTPHeaders
        let client: ClientRecord?
    }

    private enum Gate {
        case admitted(Admission)
        case done(Outcome)
    }

    private static func withCORS(_ response: HTTPResponse, _ cors: HTTPHeaders) -> Outcome {
        var response = response
        for (name, value) in cors.pairs { response.headers[name] = value }
        return .response(response, close: false)
    }

    /// Spec §6.6 up to the handler. Needs only the head plus the body's length.
    private func admit(_ request: HTTPRequest, bodyLength: Int, policy: RequestPolicy,
                       consumeRate: Bool) -> (Gate, String?) {
        guard policy.checkHost(request) else {
            return (.done(.response(Self.error(.misdirected), close: true)), nil)
        }
        let origin = policy.classifyOrigin(request)
        guard origin != .rejected else { return (.done(.response(Self.error(.originNotAllowed), close: false)), nil) }
        let cors = policy.corsHeaders(for: origin)
        func reply(_ response: HTTPResponse) -> Gate { .done(Self.withCORS(response, cors)) }
        if let preflight = policy.preflight(request) { return (reply(preflight), nil) }

        let router = Router(routes: APIRoutes.all + routeRegistry.routes)
        let match: RouteMatch
        switch router.match(method: request.method, path: request.path) {
        case .success(let found):
            match = found
        case .failure(.notFound):
            return (reply(Self.error(.notFound, "There is no route at that path.")), nil)
        case .failure:
            var response = Self.error(.badRequest, "That method isn't allowed on this path.")
            response.status = 405
            response.headers["Allow"] = router.allowedMethods(path: request.path).joined(separator: ", ")
            return (reply(response), nil)
        }
        let spec = match.spec
        let pattern = spec.pattern

        if let code = policy.checkContentType(request, route: spec) { return (reply(Self.error(code)), pattern) }
        let defaultLimit = spec.body == .binary ? limits.maxBinaryBody : limits.maxJSONBody
        if bodyLength > min(spec.maxBodyBytes ?? defaultLimit, Self.maxBodyCap) {
            return (reply(Self.error(.tooLarge)), pattern)
        }

        let bearer = request.headers["Authorization"]
        let client = spec.scope == nil ? nil : registry.authenticate(bearer: bearer)
        if consumeRate, let wait = limiter.consume(client: client?.id.uuidString ?? "anon",
                                                   bucket: client == nil ? .unauthenticated : spec.bucket) {
            var response = Self.error(.rateLimited)
            response.headers["Retry-After"] = String(wait)
            return (reply(response), pattern)
        }

        if let required = spec.scope {
            guard let client else {
                return (reply(Self.error(registry.wasRevoked(bearer: bearer) ? .tokenRevoked : .unauthorized)), pattern)
            }
            guard RequestPolicy.originBindingAllows(record: client, decision: origin,
                                                    extensionBundle: request.headers[RequestPolicy.extensionBundleHeader]) else {
                return (reply(Self.error(.unauthorized, "This token can't be used from this origin.")), pattern)
            }
            guard client.scopes.contains(where: { $0.allows(required) }) else {
                return (reply(Self.error(.forbiddenScope)), pattern)
            }
        }
        return (.admitted(Admission(match: match, origin: origin, cors: cors, client: client)), pattern)
    }

    private func pipeline(_ request: HTTPRequest, policy: RequestPolicy, admitted: Bool) async -> (Outcome, String?) {
        let admission: Admission
        switch admit(request, bodyLength: request.body.count, policy: policy, consumeRate: !admitted) {
        case (.done(let outcome), let pattern): return (outcome, pattern)
        case (.admitted(let found), _): admission = found
        }
        let (match, origin, cors, client) = (admission.match, admission.origin, admission.cors, admission.client)
        let spec = match.spec
        let pattern = spec.pattern
        func reply(_ response: HTTPResponse) -> Outcome { Self.withCORS(response, cors) }
        if let client { onAuthenticated?(client.id) }

        let context = LocalAPIContext(request: request, route: match, client: client, origin: origin)
        guard let route = RouteID(rawValue: spec.id) else {
            guard let handler = routeRegistry.handler(for: spec.id) else { return (reply(Self.error(.notFound)), pattern) }
            return (reply(await handler(context)), pattern)
        }
        switch route {
        case .ping:
            var dto = ping()
            for name in routeRegistry.capabilities where !dto.capabilities.contains(name) {
                dto.capabilities.append(name)
            }
            return (reply(.json(dto)), pattern)
        case .openapi:
            let body = OpenAPIDocument.data(registry: routeRegistry, appVersion: ping().appVersion)
            return (reply(HTTPResponse(status: 200, headers: HTTPHeaders([("Content-Type", "application/json; charset=utf-8")]),
                                       body: body)), pattern)
        case .pairStart, .pairComplete:
            return (reply(pair(route, request: request, origin: origin)), pattern)
        case .me:
            return (reply(.json(clientDTO(context.client!))), pattern)
        case .meDelete:
            return (reply(revoke(context.client!.id)), pattern)
        case .changes:
            guard let limit = Self.limit(request.query["limit"]) else {
                return (reply(Self.error(.badRequest, "limit must be a number from 1 to 500.")), pattern)
            }
            switch changes.changes(since: request.query["since"], limit: limit) {
            case .success(let page): return (reply(.json(page)), pattern)
            case .failure(let code): return (reply(Self.error(code)), pattern)
            }
        case .events:
            let cursor = request.headers["Last-Event-ID"] ?? request.query["since"]
            return (.stream(client: context.client!, cursor: cursor, cors: cors), pattern)
        case .clientsList:
            return (reply(.json(registry.clients.map(clientDTO))), pattern)
        case .clientDelete:
            guard let id = match.params["id"].flatMap(UUID.init(uuidString:)) else {
                return (reply(Self.error(.notFound)), pattern)
            }
            return (reply(revoke(id)), pattern)
        default:
            return (reply(await responder.respond(context)), pattern)
        }
    }

    private func pair(_ route: RouteID, request: HTTPRequest, origin: OriginDecision) -> HTTPResponse {
        let stored: String?
        switch RequestPolicy.storedOrigin(for: origin, extensionBundle: request.headers[RequestPolicy.extensionBundleHeader]) {
        case .success(let value):
            stored = value
        case .failure(let code):
            return Self.error(code, "Safari extensions must send \(RequestPolicy.extensionBundleHeader) with their bundle identifier.")
        }
        let decoder = APIJSON.decoder()
        if route == .pairStart {
            guard let body = try? decoder.decode(PairStartRequest.self, from: request.body) else {
                return Self.error(.badRequest, "Send clientName, kind (cli, extension, mcp or script) and scopes.")
            }
            switch pairing.start(body, origin: stored) {
            case .success(let response): return .json(response)
            case .failure(let code): return Self.error(code)
            }
        }
        guard let body = try? decoder.decode(PairCompleteRequest.self, from: request.body) else {
            return Self.error(.badRequest, "Send pairingID and code.")
        }
        switch pairing.complete(body, origin: stored) {
        case .success(let response): return .json(response)
        case .failure(let code): return Self.error(code)
        }
    }

    private func revoke(_ id: UUID) -> HTTPResponse {
        do {
            try registry.revoke(id)
            return HTTPResponse(status: 204)
        } catch let code as APIErrorCode {
            return Self.error(code, "No client with that id.")
        } catch {
            return Self.error(.internal, "The client couldn't be removed.")
        }
    }

    private func clientDTO(_ record: ClientRecord) -> ClientDTO {
        ClientDTO(id: record.id, name: record.name, kind: record.kind, scopes: record.scopes, origin: record.origin,
                  tokenHint: record.tokenHint, createdAt: record.createdAt, lastUsedAt: lastUsed?(record.id))
    }

    private static func limit(_ text: String?) -> Int? {
        guard let text else { return 50 }
        guard let value = Int(text), (1...500).contains(value) else { return nil }
        return value
    }

    static func error(_ code: APIErrorCode, _ message: String? = nil) -> HTTPResponse {
        .error(code, message ?? defaultMessage(code))
    }

    static func defaultMessage(_ code: APIErrorCode) -> String {
        switch code {
        case .badRequest: return "The request is malformed."
        case .unauthorized: return "A valid token is required."
        case .tokenRevoked: return "This token was revoked."
        case .forbiddenScope: return "This token doesn't have the scope this route needs."
        case .originNotAllowed: return "Requests from this origin aren't allowed."
        case .pairingDenied: return "Pairing was denied in NoteIt."
        case .pairingFailed: return "Pairing failed. Check the code shown in NoteIt, or start again."
        case .pairingInProgress: return "Another pairing is in progress."
        case .notFound: return "Not found."
        case .cursorExpired: return "The cursor has expired. List again with updatedSince."
        case .lengthRequired: return "Request bodies need Content-Length."
        case .tooLarge: return "The request is too large."
        case .unsupportedMediaType: return "This route needs Content-Type: application/json."
        case .misdirected: return "The Host header must be 127.0.0.1 or localhost with the API's port."
        case .rateLimited: return "Too many requests. Try again after Retry-After seconds."
        case .apiDisabled: return "The Local API was turned off."
        case .notReady: return "Your library is still opening. Try again in a moment."
        default: return "The request failed."
        }
    }
}

/// Touched on the server queue only.
private final class Once: @unchecked Sendable {
    var done = false
}

// MARK: - Connection

/// One TCP connection. Every property is touched on the server's queue only.
private final class Connection: @unchecked Sendable {
    private weak var server: LocalHTTPServer?
    private let connection: NWConnection
    private let policy: RequestPolicy
    private let queue: DispatchQueue
    private var buffer = Data()
    private var busy = false
    private var receiving = false
    private var closed = false
    private var stopping = false
    /// The head of the request in `buffer` passed `screen`; its body is still arriving.
    private var headAdmitted = false
    private var idleTimer: DispatchWorkItem?
    /// Set while lingering: the response is out (or going) and further bytes are discarded up to this many.
    private var discardBudget: Int?
    private var lingerSent = false
    private var lingerPeerDone = false
    private var subscription: UUID?
    private var heartbeat: DispatchSourceTimer?

    init(server: LocalHTTPServer, connection: NWConnection, policy: RequestPolicy) {
        self.server = server
        self.connection = connection
        self.policy = policy
        self.queue = server.queue
    }

    func start() {
        begin()
        armIdleTimer()
        receive()
    }

    /// Answers without reading a request, e.g. `503` when the server is full.
    func reject(_ response: HTTPResponse) {
        begin()
        respondAndLinger(response, unreadBody: nil)
    }

    private func begin() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        connection.start(queue: queue)
    }

    /// The server is stopping: idle connections and streams close now, a busy one after answering `api_disabled`.
    func shutDown() {
        if busy, discardBudget == nil {
            stopping = true
        } else {
            close()
        }
    }

    private var isStream: Bool { subscription != nil }

    private func receive() {
        guard !receiving, !closed else { return }
        receiving = true
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            self.receiving = false
            if let budget = self.discardBudget {
                let remaining = budget - (data?.count ?? 0)
                self.discardBudget = remaining
                if isComplete || error != nil || remaining <= 0 { return self.finishLinger() }
                return self.receive()
            }
            if isComplete || error != nil {
                self.close()
                return
            }
            if self.isStream {
                self.receive()
                return
            }
            if let data { self.buffer.append(data) }
            self.process()
        }
    }

    private func process() {
        guard !busy, !closed, !isStream, let server else { return }
        let parser = server.parser()
        if !headAdmitted, case .head(let head, let bodyStart, let contentLength) = parser.parseHead(buffer),
           buffer.count - bodyStart < contentLength {
            // Don't buffer a body the request would be refused for anyway.
            if let response = server.screen(head, contentLength: contentLength, policy: policy) {
                return respondAndLinger(response, unreadBody: contentLength - (buffer.count - bodyStart))
            }
            headAdmitted = true
        }
        switch parser.parse(buffer) {
        case .needMore:
            armIdleTimer()
            receive()
        case .failure(let status, let code):
            var response = LocalHTTPServer.error(code)
            response.status = status
            respondAndLinger(response, unreadBody: nil)
        case .request(let request, let consumed):
            buffer.removeFirst(consumed)
            busy = true
            idleTimer?.cancel()
            let policy = policy
            let admitted = headAdmitted
            headAdmitted = false
            Task { [weak self] in
                let outcome = await server.handle(request, policy: policy, admitted: admitted)
                server.queue.async { self?.finish(outcome, request: request) }
            }
        }
    }

    private func finish(_ outcome: LocalHTTPServer.Outcome, request: HTTPRequest) {
        guard !closed else { return }
        busy = false
        if stopping {
            write(LocalHTTPServer.error(.apiDisabled).serialized(keepAlive: false)) { [weak self] in self?.close() }
            return
        }
        switch outcome {
        case .response(let response, let close):
            let keepAlive = !close && request.headers["Connection"]?.lowercased() != "close"
            write(response.serialized(keepAlive: keepAlive)) { [weak self] in
                if keepAlive { self?.process() } else { self?.close() }
            }
        case .stream(let client, let cursor, let cors):
            startStream(client: client, cursor: cursor, cors: cors, request: request)
        }
    }

    // MARK: Server-Sent Events

    private func startStream(client: ClientRecord, cursor: String?, cors: HTTPHeaders, request: HTTPRequest) {
        guard let server else { return close() }
        let result = server.changes.subscribe(client: client.id, after: cursor, onClose: { [weak self, queue] in
            queue.async { self?.endStreamRevoked() }
        }, { [weak self, queue] change in
            queue.async { self?.sendEvent(change) }
        })
        switch result {
        case .failure(let code):
            var response = LocalHTTPServer.error(code)
            for (name, value) in cors.pairs { response.headers[name] = value }
            write(response.serialized(keepAlive: true)) { [weak self] in self?.process() }
            return
        case .success(let id):
            subscription = id
        }
        var head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\n"
            + "X-Content-Type-Options: nosniff\r\nConnection: keep-alive\r\n"
        for (name, value) in cors.pairs { head += "\(name): \(value)\r\n" }
        write(Data((head + "\r\n").utf8))

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + server.heartbeatInterval, repeating: server.heartbeatInterval)
        timer.setEventHandler { [weak self] in self?.write(Data(": ping\n\n".utf8)) }
        timer.resume()
        heartbeat = timer
        receive()

        // Revoked between authentication and subscribing.
        if !server.registry.clients.contains(where: { $0.id == client.id }) {
            server.changes.closeAll(client: client.id)
        }
    }

    private func sendEvent(_ change: ChangeDTO) {
        guard !closed, isStream, let json = try? APIJSON.encoder().encode(change) else { return }
        write(Data("id: \(change.cursor)\nevent: change\ndata: ".utf8) + json + Data("\n\n".utf8))
    }

    private func endStreamRevoked() {
        guard !closed, isStream else { return }
        subscription = nil
        write(Data("event: revoked\ndata: {}\n\n".utf8)) { [weak self] in self?.close() }
    }

    // MARK: Plumbing

    private func write(_ data: Data, then: (() -> Void)? = nil) {
        guard !closed else { return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, !self.closed else { return }
            if error != nil { return self.close() }
            then?()
        })
    }

    /// Lingering close (RFC 9112 §9.6): send the response, shut down the write side, then discard what the client
    /// still sends until it closes, `lingerDiscardLimit` bytes or `lingerTimeout`, so it can read the response instead
    /// of having its upload reset. The connection keeps its slot until then.
    private func respondAndLinger(_ response: HTTPResponse, unreadBody: Int?) {
        guard let server, !closed else { return }
        busy = true
        buffer.removeAll()
        let limit = server.lingerDiscardLimit
        discardBudget = unreadBody.map { min(max($0, 0) + 65_536, limit) } ?? limit
        idleTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in self?.close() }
        idleTimer = timer
        queue.asyncAfter(deadline: .now() + server.lingerTimeout, execute: timer)
        write(response.serialized(keepAlive: false)) { [weak self] in
            guard let self else { return }
            self.connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                 completion: .contentProcessed { [weak self] error in
                guard let self, !self.closed else { return }
                if error != nil { return self.close() }
                self.lingerSent = true
                if self.lingerPeerDone { self.close() }
            })
        }
        receive()
    }

    private func finishLinger() {
        lingerPeerDone = true
        if lingerSent { close() }
    }

    private func armIdleTimer() {
        guard let server, !isStream else { return }
        idleTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in
            guard let self, !self.busy, !self.isStream else { return }
            self.close()
        }
        idleTimer = timer
        queue.asyncAfter(deadline: .now() + server.idleTimeout, execute: timer)
    }

    func close() {
        guard !closed else { return }
        closed = true
        idleTimer?.cancel()
        heartbeat?.cancel()
        if let subscription { server?.changes.unsubscribe(subscription) }
        subscription = nil
        connection.cancel()
        server?.removed(self)
    }
}
