import Foundation

/// The last `capacity` library changes of this launch, with cursors `<bootID>:<seq>`, and the event-stream
/// subscribers. Changes are never persisted, so a cursor from an earlier launch is expired.
public final class ChangeHub: @unchecked Sendable {
    public static let capacity = 5_000
    public static let maxSubscribersPerClient = 4
    public static let maxSubscribers = 16

    private struct Subscriber {
        let client: UUID
        let send: @Sendable (ChangeDTO) -> Void
        let onClose: (@Sendable () -> Void)?
    }

    public let bootID: String
    private let capacity: Int
    private let lock = NSLock()
    /// Held while changes are delivered, so every subscriber sees changes in order and a new subscriber's backlog
    /// comes before anything published after it.
    private let delivery = NSLock()
    private var buffer: [ChangeDTO] = []
    private var head = 0
    private var seq: UInt64 = 0
    private var droppedThrough: UInt64 = 0
    private var subscribers: [UUID: Subscriber] = [:]

    public init(bootID: String = UUID().uuidString.prefix(8).description, capacity: Int = ChangeHub.capacity) {
        self.bootID = bootID
        self.capacity = max(1, capacity)
    }

    public var currentCursor: String { lock.withLock { cursor(seq) } }

    public func publish(kind: ChangeKind, id: UUID, op: ChangeOp, at: Date) {
        delivery.withLock {
            let (change, targets) = lock.withLock { () -> (ChangeDTO, [Subscriber]) in
                seq += 1
                let change = ChangeDTO(cursor: cursor(seq), kind: kind, id: id, op: op, at: at)
                buffer.append(change)
                if buffer.count - head > capacity {
                    head += 1
                    droppedThrough = seq - UInt64(capacity)
                    if head > capacity {
                        buffer.removeFirst(head)
                        head = 0
                    }
                }
                return (change, Array(subscribers.values))
            }
            for subscriber in targets { subscriber.send(change) }
        }
    }

    /// Without `since`, no changes and the current cursor. `.cursorExpired` for a cursor from another launch or
    /// older than the buffer; `.badRequest` for one that isn't a cursor.
    public func changes(since cursor: String?, limit: Int) -> Result<ChangesPage, APIErrorCode> {
        lock.withLock {
            guard let cursor else { return .success(ChangesPage(changes: [], cursor: self.cursor(seq), hasMore: false)) }
            switch backlogLocked(after: cursor) {
            case .failure(let code):
                return .failure(code)
            case .success(let all):
                let page = Array(all.prefix(max(1, limit)))
                return .success(ChangesPage(changes: page, cursor: page.last?.cursor ?? cursor, hasMore: all.count > page.count))
            }
        }
    }

    /// Sends the changes after `cursor` (none without one), then every new change, through `send` until
    /// `unsubscribe` or `closeAll(client:)`; the latter calls `onClose`. At most 4 per client and 16 in all
    /// (`.rateLimited`).
    public func subscribe(client: UUID, after cursor: String?, onClose: (@Sendable () -> Void)? = nil,
                          _ send: @escaping @Sendable (ChangeDTO) -> Void) -> Result<UUID, APIErrorCode> {
        delivery.withLock {
            let result = lock.withLock { () -> Result<(UUID, [ChangeDTO]), APIErrorCode> in
                guard subscribers.count < Self.maxSubscribers,
                      subscribers.values.filter({ $0.client == client }).count < Self.maxSubscribersPerClient else {
                    return .failure(.rateLimited)
                }
                let backlog: [ChangeDTO]
                if let cursor {
                    switch backlogLocked(after: cursor) {
                    case .failure(let code): return .failure(code)
                    case .success(let changes): backlog = changes
                    }
                } else {
                    backlog = []
                }
                let id = UUID()
                subscribers[id] = Subscriber(client: client, send: send, onClose: onClose)
                return .success((id, backlog))
            }
            return result.map { id, backlog in
                backlog.forEach(send)
                return id
            }
        }
    }

    public func unsubscribe(_ subscription: UUID) {
        _ = lock.withLock { subscribers.removeValue(forKey: subscription) }
    }

    /// Removes the client's subscriptions and calls their `onClose` (used by revoke).
    public func closeAll(client: UUID) {
        let closed = lock.withLock { () -> [Subscriber] in
            let matching = subscribers.filter { $0.value.client == client }
            for key in matching.keys { subscribers.removeValue(forKey: key) }
            return Array(matching.values)
        }
        for subscriber in closed { subscriber.onClose?() }
    }

    /// Number of open subscriptions, for tests and status.
    public var subscriberCount: Int { lock.withLock { subscribers.count } }

    private func cursor(_ seq: UInt64) -> String { "\(bootID):\(seq)" }

    private func backlogLocked(after cursor: String) -> Result<[ChangeDTO], APIErrorCode> {
        guard let colon = cursor.lastIndex(of: ":"), let after = UInt64(cursor[cursor.index(after: colon)...]) else {
            return .failure(.badRequest)
        }
        guard cursor[..<colon] == bootID, after >= droppedThrough else { return .failure(.cursorExpired) }
        guard after <= seq else { return .failure(.badRequest) }
        let start = head + Int(after - (seq - UInt64(buffer.count - head)))
        return .success(Array(buffer[start...]))
    }
}
