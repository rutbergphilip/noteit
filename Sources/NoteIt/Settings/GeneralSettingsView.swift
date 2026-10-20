import AppKit
import ServiceManagement
import SwiftUI

struct GeneralSettingsView: View {
    @AppStorage(PrefKey.hideDockIcon) private var hideDockIcon = false
    @AppStorage(PrefKey.showMenuBarIcon) private var showMenuBarIcon = true
    @AppStorage(PrefKey.captureIncludesBrowserLinks) private var captureIncludesBrowserLinks = true

    @ObservedObject private var updater = AppUpdater.shared

    @State private var launchAtLogin = false
    @State private var loginStatus: SMAppService.Status = .notRegistered
    @State private var loginError: String?
    @State private var accessibilityTrusted = AccessibilityAccess.isTrusted

    /// SMAppService.mainApp only works for a real .app bundle.
    private var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    var body: some View {
        Form {
            ForEach(GeneralSettingsSection.allCases.filter(\.isAvailable), id: \.self) { section in
                sectionView(section)
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: GeneralSettingsLayout.minHeight,
               idealHeight: GeneralSettingsLayout.idealHeight(updatesEnabled: updater.isEnabled))
        .onAppear(perform: refreshLoginStatus)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            let window = note.object as? NSWindow
            if window?.identifier?.rawValue == SettingsOpener.windowIdentifier {
                refreshAccessibility()
            }
        }
    }

    @ViewBuilder
    private func sectionView(_ section: GeneralSettingsSection) -> some View {
        switch section {
        case .appearance: appearanceSection
        case .startup: startupSection
        case .capture: captureSection
        case .emailIn, .reminders, .cheatSheet: EmptyView()
        case .updates:
            if updater.isEnabled { updatesSection }
        }
    }

    private var appearanceSection: some View {
        Section {
            Picker(GeneralSettingsLabel.showNoteItIn, selection: dockBinding) {
                Text("Dock and menu bar").tag(false)
                Text("Menu bar only").tag(true)
            }
            .pickerStyle(.menu)

            Toggle(GeneralSettingsLabel.showMenuBarIcon, isOn: $showMenuBarIcon)
                .disabled(hideDockIcon)
            if hideDockIcon {
                SettingsFootnote(text: "The menu bar icon stays visible while NoteIt is hidden from the Dock, so you can always get back to your notes.")
            }
        } header: {
            Text("Appearance")
        }
    }

    private var startupSection: some View {
        Section {
            Toggle(GeneralSettingsLabel.launchAtLogin, isOn: loginBinding)
                .disabled(!isBundled)
            if !isBundled {
                SettingsFootnote(text: "Available when NoteIt runs from its app bundle.", symbol: "info.circle")
            } else if let loginError {
                SettingsFootnote(text: loginError, symbol: "exclamationmark.triangle.fill", color: .orange)
            } else if loginStatus == .requiresApproval {
                HStack {
                    SettingsFootnote(text: "Allow NoteIt in Login Items to finish setup.", symbol: "exclamationmark.circle")
                    Spacer()
                    Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                        .controlSize(.small)
                }
            }
        } header: {
            Text("Startup")
        }
    }

    private var captureSection: some View {
        Section {
            accessibilityRow
            Toggle(GeneralSettingsLabel.includePageLinks, isOn: $captureIncludesBrowserLinks)
            SettingsFootnote(text: "Works in Safari and Chrome-based browsers. macOS asks once per browser before NoteIt can read the page address.")
        } header: {
            Text("Capture")
        } footer: {
            SettingsFootnote(text: "Set a Capture Selection shortcut in Settings › Shortcuts, or select text and choose right-click › Services › Capture to NoteIt. Captures go to the notebook chosen for new notes in Settings › Editor.",
                             symbol: "text.quote")
                .padding(.top, 4)
        }
    }

    private var updatesSection: some View {
        Section {
            HStack {
                Toggle(GeneralSettingsLabel.checkForUpdates, isOn: $updater.automaticallyChecksForUpdates)
                Spacer()
                Button("Check Now") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        } header: {
            Text("Updates")
        }
    }

    private var accessibilityRow: some View {
        LabeledContent {
            if accessibilityTrusted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Tokens.Color.success)
            } else {
                HStack(spacing: 8) {
                    Text("Not allowed")
                        .foregroundStyle(.secondary)
                    Button("Allow…") { AccessibilityAccess.requestAccess() }
                }
            }
        } label: {
            Text(GeneralSettingsLabel.readSelectedText)
            Text("Accessibility permission, for the Capture Selection shortcut")
        }
        .task {
            // Permission is granted in System Settings, so poll while this row is on screen.
            while !Task.isCancelled {
                if SettingsOpener.settingsWindow?.isVisible != false { refreshAccessibility() }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func refreshAccessibility() {
        let trusted = AccessibilityAccess.isTrusted
        if trusted != accessibilityTrusted { accessibilityTrusted = trusted }
    }

    private var dockBinding: Binding<Bool> {
        Binding(
            get: { hideDockIcon },
            set: { hide in
                // Menu-bar-only without a menu bar icon would make NoteIt unreachable.
                if hide { showMenuBarIcon = true }
                hideDockIcon = hide
            }
        )
    }

    private var loginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { enable in
                loginError = nil
                do {
                    if enable {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    loginError = "Couldn't \(enable ? "enable" : "disable") launch at login: \(error.localizedDescription)"
                }
                refreshLoginStatus()
            }
        )
    }

    private func refreshLoginStatus() {
        guard isBundled else { return }
        loginStatus = SMAppService.mainApp.status
        launchAtLogin = loginStatus == .enabled || loginStatus == .requiresApproval
        UserDefaults.standard.set(launchAtLogin, forKey: PrefKey.launchAtLogin)
    }
}

/// The General tab's sections, in program §9 order. Owners only flip `isAvailable` and fill their case in
/// `GeneralSettingsView`; they don't add or move cases. Foundations Task 6.5.
enum GeneralSettingsSection: String, CaseIterable {
    case appearance, startup, capture
    /// capture-plus.
    case emailIn
    /// organise.
    case reminders
    /// surfaces-polish.
    case cheatSheet
    case updates

    /// False for emailIn, reminders and cheatSheet until their owners ship them. Updates also needs the updater.
    var isAvailable: Bool {
        switch self {
        case .appearance, .startup, .capture, .updates: true
        case .emailIn, .reminders, .cheatSheet: false
        }
    }

    /// The labels of the section's rows, in order, as `GeneralSettingsView` shows them.
    var rowLabels: [String] {
        switch self {
        case .appearance: [GeneralSettingsLabel.showNoteItIn, GeneralSettingsLabel.showMenuBarIcon]
        case .startup: [GeneralSettingsLabel.launchAtLogin]
        case .capture: [GeneralSettingsLabel.readSelectedText, GeneralSettingsLabel.includePageLinks]
        case .emailIn, .reminders, .cheatSheet: []
        case .updates: [GeneralSettingsLabel.checkForUpdates]
        }
    }
}

enum GeneralSettingsLabel {
    static let showNoteItIn = "Show NoteIt in"
    static let showMenuBarIcon = "Show menu bar icon"
    static let launchAtLogin = "Launch at login"
    static let readSelectedText = "Read selected text"
    static let includePageLinks = "Include page links from browsers"
    static let checkForUpdates = "Check for Updates Automatically"
}

/// The General tab's window sizes. It opens at its previous fixed height and can be made shorter, which scrolls the
/// form instead of clipping it.
enum GeneralSettingsLayout {
    static let minHeight: CGFloat = 320

    static func idealHeight(updatesEnabled: Bool) -> CGFloat {
        updatesEnabled ? 620 : 540
    }
}
