import SwiftUI

/// Icon, wording and colour for a sync status, shared by the sidebar pill, the menu bar panel and Settings.
struct SyncStatusPresentation {
    let status: SyncStatus
    let lastSync: Date?

    var symbol: String {
        switch status {
        case .notConfigured: "icloud"
        case .idle: "checkmark.icloud"
        case .syncing: "arrow.triangle.2.circlepath"
        case .offline: "icloud.slash"
        case .error: "exclamationmark.icloud"
        case .needsPassphrase: "lock.icloud"
        case .waitingForLibrary: "hourglass"
        }
    }

    var shortLabel: String {
        switch status {
        case .notConfigured: "Sync Off"
        case .idle: "Synced"
        case .syncing: "Syncing"
        case .offline: "Offline"
        case .error: "Sync Issue"
        case .needsPassphrase: "Locked"
        case .waitingForLibrary: "Waiting"
        }
    }

    var tint: Color {
        switch status {
        case .error, .needsPassphrase: .orange
        case .syncing: .accentColor
        default: .secondary
        }
    }

    var isSyncing: Bool { status == .syncing }

    /// "Synced 2 minutes ago", "Syncing…", or the problem in plain words.
    func headline(now: Date = Date()) -> String {
        switch status {
        case .notConfigured: return "Sync is off"
        case .idle, .syncing:
            if status == .syncing { return "Syncing…" }
            guard let lastSync else { return "Waiting to sync" }
            return "Synced \(Self.relative(lastSync, now: now))"
        case .offline(let message): return "Offline — \(message)"
        case .error(let message): return message
        case .needsPassphrase: return "Enter your sync passphrase in Settings to keep syncing."
        case .waitingForLibrary: return "Waiting for the library folder…"
        }
    }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 45 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

/// Status glyph that spins while a pass is running.
struct SyncStatusIcon: View {
    let presentation: SyncStatusPresentation
    @State private var spin = false

    var body: some View {
        if presentation.isSyncing {
            if #available(macOS 15.0, *) {
                Image(systemName: presentation.symbol)
                    .symbolEffect(.rotate, options: .repeating)
            } else {
                Image(systemName: presentation.symbol)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 1.2).repeatForever(autoreverses: false), value: spin)
                    .onAppear { spin = true }
                    .onDisappear { spin = false }
            }
        } else {
            Image(systemName: presentation.symbol)
        }
    }
}

/// Compact pill for the sidebar footer. Hidden while sync isn't configured; opens Settings › Sync on click.
struct SyncStatusPill: View {
    @ObservedObject private var sync = SyncController.shared
    @Environment(\.openSettings) private var openSettings
    @State private var isHovered = false

    var body: some View {
        if sync.isConfigured {
            let presentation = SyncStatusPresentation(status: sync.status, lastSync: sync.lastSync)
            Button {
                SettingsTabRouter.show(.sync, using: openSettings)
            } label: {
                HStack(spacing: 4) {
                    SyncStatusIcon(presentation: presentation)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 14)
                    Text(presentation.shortLabel)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(presentation.tint)
                .padding(.leading, 7)
                .padding(.trailing, 9)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(isHovered ? 0.10 : 0.05))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(presentation.tint.opacity(presentation.tint == .secondary ? 0 : 0.35), lineWidth: 0.5)
                )
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .help(tooltip(presentation))
            .accessibilityLabel("Sync status: \(presentation.headline())")
            .animation(.easeOut(duration: 0.15), value: presentation.shortLabel)
        }
    }

    private func tooltip(_ presentation: SyncStatusPresentation) -> String {
        let destination = sync.configuration.map { "\($0.provider.displayName): \($0.destination)" } ?? ""
        return "\(presentation.headline())\n\(destination)\nClick to open Sync settings."
    }
}

/// One-line sync status with a Sync Now button, for the menu bar panel.
struct MenuBarSyncRow: View {
    @ObservedObject private var sync = SyncController.shared

    var body: some View {
        if sync.isConfigured {
            let presentation = SyncStatusPresentation(status: sync.status, lastSync: sync.lastSync)
            HStack(spacing: 6) {
                SyncStatusIcon(presentation: presentation)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(presentation.tint)
                    .frame(width: 14)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(presentation.headline(now: context.date))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Button("Sync Now") { sync.syncNow() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .disabled(presentation.isSyncing || sync.status == .needsPassphrase)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .help(presentation.headline())
        }
    }
}
