import Foundation

/// Written by the Mac that showed a reminder, so other Macs don't show it too (organise spec 7.3).
public struct ReminderClaim: Codable, Sendable, Equatable {
    public var id: UUID
    public var deviceID: String
    public var deliveredAt: Date

    public init(id: UUID, deviceID: String, deliveredAt: Date) {
        self.id = id
        self.deviceID = deviceID
        self.deliveredAt = deliveredAt
    }
}

public enum ClaimOutcome: Sendable, Equatable {
    case claimed, alreadyClaimed, unavailable(String)
}

extension SyncEngine {
    /// A conditional create of the reminder's claim. Any failure other than "already exists" is `unavailable`, and
    /// the caller shows the reminder: a duplicate is better than a missed one.
    public func claimReminder(_ id: UUID, at date: Date) async -> ClaimOutcome {
        let key = RemoteLayout.reminderClaim(id)
        do {
            let plain = try Self.encode(ReminderClaim(id: id, deviceID: deviceID, deliveredAt: date))
            let sealed = try session.current.cipher.seal(plain, context: Self.context(key))
            try await backend.put(key, data: sealed, ifMatch: nil, ifNoneMatch: true)
            return .claimed
        } catch StorageError.preconditionFailed {
            return .alreadyClaimed
        } catch {
            return .unavailable(String(describing: error))
        }
    }

    /// Deletes this device's claims older than `age`. Claims that don't open (for example during a key change) and
    /// other devices' claims are left alone. Returns how many were deleted.
    public func sweepReminderClaims(olderThan age: TimeInterval, now date: Date) async throws -> Int {
        let cutoff = date.addingTimeInterval(-age)
        var deleted = 0
        for object in try await backend.list(prefix: RemoteLayout.reminderClaimsPrefix) where object.key.hasSuffix(".json") {
            let claim: ReminderClaim
            do {
                let sealed = try await backend.get(object.key).data
                claim = try Self.decode(ReminderClaim.self, from: try session.current.cipher.open(sealed, context: Self.context(object.key)))
            } catch StorageError.notFound {
                continue
            } catch let error as StorageError {
                throw error
            } catch {
                continue
            }
            guard claim.deviceID == deviceID, claim.deliveredAt < cutoff else { continue }
            do {
                try await backend.delete(object.key)
                deleted += 1
            } catch StorageError.notFound {}
        }
        return deleted
    }
}
