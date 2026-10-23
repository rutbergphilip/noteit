import AppKit
import NoteItSync

/// The noteit-doc device check's answer for this launch (web-app spec §3.4 item 6). The engine never waits for the
/// user inside a pass: `confirm` returns true only for a device list the user already accepted, and otherwise asks
/// once per launch and returns false, so the store stays as it is until a later pass.
struct UpgradeConfirmation {
    /// Device IDs the user accepted in this launch.
    var confirmed: Set<String>?
    var askedThisLaunch = false
    /// Devices already shown in the after-the-fact notice.
    var notifiedLate: Set<String> = []

    static let message = "These Macs will stop syncing until NoteIt is updated on them."

    /// The device list with each device's last sync time, for the sheet and the notice.
    static func deviceLines(_ blockers: [FeatureBlocker], now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return blockers.map { blocker in
            let seen = blocker.lastSync.map { "last synced \(formatter.localizedString(for: $0, relativeTo: now))" } ?? "never synced"
            return "• \(blocker.deviceName) (\(seen))"
        }.joined(separator: "\n")
    }

    /// True when `blockers` are exactly the devices accepted in this launch; a new blocking device needs a new answer.
    func accepts(_ blockers: [FeatureBlocker]) -> Bool {
        confirmed == Set(blockers.map(\.deviceID))
    }
}

extension SyncController {
    /// Gives the engine the device-check question and the late-device notice.
    func installUpgradeHandlers(_ engine: SyncEngine) async {
        await engine.setFeatureConfirm { [weak self] blockers in
            await self?.confirmUpgrade(blockers) ?? false
        }
        await engine.setLateBlockersHandler { [weak self] blockers in
            await self?.noticeLateBlockers(blockers)
        }
    }

    func confirmUpgrade(_ blockers: [FeatureBlocker]) -> Bool {
        if upgradeConfirmation.accepts(blockers) { return true }
        guard !upgradeConfirmation.askedThisLaunch else { return false }
        upgradeConfirmation.askedThisLaunch = true
        // Shown after the pass returns; Continue records the answer and syncs again.
        DispatchQueue.main.async { [weak self] in self?.askToUpgrade(blockers) }
        return false
    }

    private func askToUpgrade(_ blockers: [FeatureBlocker]) {
        guard NSApp?.isRunning == true else { return }
        let alert = NSAlert()
        alert.messageText = "Switch your storage to the portable format?"
        alert.informativeText = UpgradeConfirmation.message + "\n\n" + UpgradeConfirmation.deviceLines(blockers)
            + "\n\nNotes on those Macs aren't lost; they sync again once NoteIt is updated."
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\r"
        let proceed = alert.addButton(withTitle: "Continue")
        proceed.keyEquivalent = ""
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        upgradeConfirmation.confirmed = Set(blockers.map(\.deviceID))
        requestSync(after: 0)
    }

    func noticeLateBlockers(_ blockers: [FeatureBlocker]) {
        let fresh = blockers.filter { !upgradeConfirmation.notifiedLate.contains($0.deviceID) }
        guard !fresh.isEmpty else { return }
        upgradeConfirmation.notifiedLate.formUnion(fresh.map(\.deviceID))
        NSLog("NoteItSync: devices without noteit-doc registered during the upgrade: %@", fresh.map(\.deviceName).joined(separator: ", "))
        DispatchQueue.main.async {
            guard NSApp?.isRunning == true else { return }
            let alert = NSAlert()
            alert.messageText = "Your storage now uses the portable format"
            alert.informativeText = String(UpgradeConfirmation.message.dropLast()) + ":\n\n" + UpgradeConfirmation.deviceLines(fresh)
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}
