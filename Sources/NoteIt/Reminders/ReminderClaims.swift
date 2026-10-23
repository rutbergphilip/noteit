import Foundation
import NoteItSync

/// With sync on, a Mac claims a reminder in the sync store before showing it (organise spec 7.3). The Mac in use
/// claims at once; an idle Mac waits, so it only rings when no other Mac did. Without sync, offline or on any error
/// the reminder is shown.
@MainActor
final class ReminderClaims: ReminderClaiming {
    static let idleDelay: TimeInterval = 20
    static let sweepInterval: TimeInterval = 24 * 60 * 60

    private let claim: (UUID, Date) async -> ClaimOutcome?
    private let sleep: (TimeInterval) async -> Void
    private let sweep: ((Date) async -> Void)?
    private let defaults: UserDefaults
    private static let lastSweepKey = "reminderClaimsLastSweep"

    init(claim: @escaping (UUID, Date) async -> ClaimOutcome?,
         sleep: @escaping (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
         sweep: ((Date) async -> Void)? = nil, defaults: UserDefaults = .standard) {
        self.claim = claim
        self.sleep = sleep
        self.sweep = sweep
        self.defaults = defaults
    }

    static func live(_ controller: SyncController) -> ReminderClaims {
        ReminderClaims(claim: { [weak controller] id, date in await controller?.claimReminder(id, at: date) },
                       sweep: { [weak controller] now in await controller?.sweepReminderClaims(now: now) })
    }

    func shouldDeliver(_ id: UUID, at date: Date, userActive: Bool) async -> Bool {
        if !userActive { await sleep(Self.idleDelay) }
        let outcome = await claim(id, date)
        await sweepIfDue(now: Date())
        switch outcome {
        case .alreadyClaimed: return false
        case .claimed, .unavailable, nil: return true
        }
    }

    private func sweepIfDue(now: Date) async {
        guard let sweep else { return }
        if let last = defaults.object(forKey: Self.lastSweepKey) as? Date, now.timeIntervalSince(last) < Self.sweepInterval { return }
        defaults.set(now, forKey: Self.lastSweepKey)
        await sweep(now)
    }
}
