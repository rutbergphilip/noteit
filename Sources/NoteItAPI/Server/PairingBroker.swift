import Foundation

public struct PairingRequest: Sendable, Equatable {
    public var id: UUID
    public var clientName: String
    public var kind: ClientKind
    public var requestedScopes: [APIScope]
    /// The stored form: the full extension origin, or `safari-web-extension:<bundle id>` for Safari.
    public var origin: String?
    public var code: String
    public var expiresAt: Date

    public init(id: UUID, clientName: String, kind: ClientKind, requestedScopes: [APIScope], origin: String?,
                code: String, expiresAt: Date) {
        self.id = id
        self.clientName = clientName
        self.kind = kind
        self.requestedScopes = requestedScopes
        self.origin = origin
        self.code = code
        self.expiresAt = expiresAt
    }
}

public enum PairingEvent: Sendable, Equatable {
    case started(PairingRequest)
    case finished(UUID, success: Bool)
    case cancelled(UUID, reason: String)
}

/// The pairing state machine (automation spec §6.5): one open pairing at a time, a 6-digit code that lives for
/// 120 seconds, and 5 wrong codes cancel it.
public final class PairingBroker: @unchecked Sendable {
    public static let lifetime: TimeInterval = 120
    public static let maxAttempts = 5
    public static let maxNameLength = 64

    /// `PairingEvent.cancelled` reasons.
    public static let deniedReason = "Denied"
    public static let expiredReason = "Expired"
    public static let tooManyAttemptsReason = "Pairing cancelled after too many wrong codes"

    private struct Pending {
        var request: PairingRequest
        var granted: [APIScope]
        var attempts = 0
    }

    private let registry: ClientRegistry
    private let now: @Sendable () -> Date
    private let code: @Sendable () -> String
    private let lock = NSLock()
    private var pending: Pending?
    private var denied: Set<UUID> = []
    private var eventHandler: (@Sendable (PairingEvent) -> Void)?

    public init(registry: ClientRegistry, now: @escaping @Sendable () -> Date = { Date() },
                code: @escaping @Sendable () -> String = { APIToken.pairingCode() }) {
        self.registry = registry
        self.now = now
        self.code = code
    }

    /// Called outside the broker's lock, on the caller's thread.
    public var onEvent: (@Sendable (PairingEvent) -> Void)? {
        get { lock.withLock { eventHandler } }
        set { lock.withLock { eventHandler = newValue } }
    }

    /// The pairing waiting for its code, if any.
    public var current: PairingRequest? {
        let (request, events) = lock.withLock { () -> (PairingRequest?, [PairingEvent]) in
            let events = expireLocked()
            return (pending?.request, events)
        }
        emit(events)
        return request
    }

    /// `origin` is the stored origin the server computed with `RequestPolicy.storedOrigin(for:extensionBundle:)`;
    /// a non-nil origin caps the scopes at `write`.
    public func start(_ request: PairStartRequest, origin: String?) -> Result<PairStartResponse, APIErrorCode> {
        let name = Self.sanitizedName(request.clientName)
        var scopes = APIScope.normalized(request.scopes)
        if origin != nil {
            scopes = APIScope.normalized(scopes.map { min($0, .write) })
        }
        guard !name.isEmpty, !scopes.isEmpty else { return .failure(.badRequest) }

        let (result, events) = lock.withLock { () -> (Result<PairStartResponse, APIErrorCode>, [PairingEvent]) in
            var events = expireLocked()
            guard pending == nil else { return (.failure(.pairingInProgress), events) }
            let pairing = PairingRequest(id: UUID(), clientName: name, kind: request.kind, requestedScopes: scopes,
                                         origin: origin, code: code(), expiresAt: now().addingTimeInterval(Self.lifetime))
            pending = Pending(request: pairing, granted: scopes)
            events.append(.started(pairing))
            return (.success(PairStartResponse(pairingID: pairing.id, expiresAt: pairing.expiresAt)), events)
        }
        emit(events)
        return result
    }

    /// Narrows the scopes the pairing will grant; scopes that weren't requested are ignored.
    public func setGrantedScopes(_ scopes: [APIScope], for id: UUID) {
        lock.withLock {
            guard var pairing = pending, pairing.request.id == id else { return }
            let ceiling = pairing.request.requestedScopes.max() ?? .read
            pairing.granted = APIScope.normalized(scopes.filter { ceiling.allows($0) })
            pending = pairing
        }
    }

    public func deny(_ id: UUID) {
        let wasPending = lock.withLock { () -> Bool in
            guard pending?.request.id == id else { return false }
            pending = nil
            denied.insert(id)
            return true
        }
        if wasPending { emit([.cancelled(id, reason: Self.deniedReason)]) }
    }

    /// `origin` must be the same stored origin `start` got.
    public func complete(_ request: PairCompleteRequest, origin: String?) -> Result<PairCompleteResponse, APIErrorCode> {
        enum Step { case fail(APIErrorCode), issue(Pending) }
        let typed = request.code.filter { !$0.isWhitespace }
        let (step, events) = lock.withLock { () -> (Step, [PairingEvent]) in
            var events = expireLocked()
            if denied.contains(request.pairingID) { return (.fail(.pairingDenied), events) }
            guard var pairing = pending, pairing.request.id == request.pairingID, pairing.request.origin == origin else {
                return (.fail(.pairingFailed), events)
            }
            guard Self.constantTimeEqual(typed, pairing.request.code) else {
                pairing.attempts += 1
                if pairing.attempts >= Self.maxAttempts {
                    pending = nil
                    events.append(.cancelled(pairing.request.id, reason: Self.tooManyAttemptsReason))
                } else {
                    pending = pairing
                }
                return (.fail(.pairingFailed), events)
            }
            pending = nil
            if pairing.granted.isEmpty {
                denied.insert(pairing.request.id)
                events.append(.cancelled(pairing.request.id, reason: Self.deniedReason))
                return (.fail(.pairingDenied), events)
            }
            return (.issue(pairing), events)
        }
        emit(events)

        switch step {
        case .fail(let code):
            return .failure(code)
        case .issue(let pairing):
            do {
                let (record, token) = try registry.issue(name: pairing.request.clientName, kind: pairing.request.kind,
                                                         scopes: pairing.granted, origin: pairing.request.origin,
                                                         now: now())
                emit([.finished(pairing.request.id, success: true)])
                return .success(PairCompleteResponse(token: token, clientID: record.id, scopes: record.scopes))
            } catch {
                emit([.finished(pairing.request.id, success: false)])
                return .failure(.internal)
            }
        }
    }

    /// Control characters removed, surrounding white space trimmed, at most 64 characters.
    static func sanitizedName(_ name: String) -> String {
        let cleaned = String(String.UnicodeScalarView(name.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }))
        return String(cleaned.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxNameLength))
    }

    private func expireLocked() -> [PairingEvent] {
        guard let pairing = pending, now() >= pairing.request.expiresAt else { return [] }
        pending = nil
        return [.cancelled(pairing.request.id, reason: Self.expiredReason)]
    }

    private func emit(_ events: [PairingEvent]) {
        guard !events.isEmpty, let handler = onEvent else { return }
        events.forEach(handler)
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8), right = Array(rhs.utf8)
        var difference = UInt8(left.count == right.count ? 0 : 1)
        for index in right.indices {
            difference |= right[index] ^ (index < left.count ? left[index] : 0)
        }
        return difference == 0
    }
}
