import AppKit
import NoteItAPI
import SwiftUI

/// Settings › Integrations: the Local API, connected apps, the command line tool, links and Spotlight. The Share
/// section comes later.
struct IntegrationsSettingsView: View {
    @AppStorage(PrefKey.urlSchemeChangesWithoutAsking) private var changesWithoutAsking = false
    @AppStorage(PrefKey.spotlightEnabled) private var spotlightEnabled = true
    @AppStorage(PrefKey.spotlightIncludesText) private var spotlightIncludesText = true
    @AppStorage(PrefKey.localAPIEnabled) private var localAPIEnabled = false
    @AppStorage(PrefKey.localAPIPort) private var localAPIPort = 0
    @ObservedObject private var api = LocalAPIController.shared
    @State private var portText = ""
    @State private var portError: String?
    @State private var showsNewToken = false
    @State private var confirmRevokeAll = false
    @State private var revokeError: String?
    @FocusState private var portFocused: Bool

    var body: some View {
        Form {
            Section {
                Toggle("Allow apps on this Mac to use NoteIt", isOn: $localAPIEnabled)
                LabeledContent("Status") {
                    Label(LocalAPIStatusText.text(api.status, enabled: localAPIEnabled),
                          systemImage: LocalAPIStatusText.symbol(api.status))
                        .foregroundStyle(LocalAPIStatusText.color(api.status))
                }
                LabeledContent("Port") {
                    TextField("Port", text: $portText, prompt: Text("Automatic"))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                        .focused($portFocused)
                        .onSubmit(commitPort)
                        .onChange(of: portFocused) { _, focused in if !focused { commitPort() } }
                }
                if let portError {
                    SettingsFootnote(text: portError, symbol: "xmark.octagon.fill", color: .red)
                }
                SettingsFootnote(text: "Apps you pair can read and change notes through a connection that only this Mac can reach.")
            } header: {
                Text("Local API")
            }

            Section {
                ConnectedAppsList(generation: api.clientsGeneration, revokeError: $revokeError)
                if let revokeError {
                    SettingsFootnote(text: revokeError, symbol: "xmark.octagon.fill", color: .red)
                }
                HStack {
                    Spacer()
                    Button("Revoke All…", role: .destructive) { confirmRevokeAll = true }
                        .disabled(AutomationService.shared.clients.list().isEmpty)
                    Button("New Token…") { showsNewToken = true }
                }
            } header: {
                Text("Connected apps")
            }

            CommandLineToolSection()

            Section {
                Toggle("Allow links to change notes without asking", isOn: $changesWithoutAsking)
                SettingsFootnote(text: "Links from other apps that create or add to a note ask first. Links that only open something never ask.")
            } header: {
                Text("Links")
            }

            Section {
                Toggle("Show notes in Spotlight", isOn: $spotlightEnabled)
                Toggle("Include note text", isOn: $spotlightIncludesText)
                    .disabled(!spotlightEnabled)
                HStack {
                    Spacer()
                    Button("Rebuild Spotlight Index") { SpotlightIndexer.shared.rebuildNow() }
                        .disabled(!spotlightEnabled)
                }
                SettingsFootnote(text: "Notes are added to this Mac's Spotlight index. They never leave your Mac.")
            } header: {
                Text("Spotlight")
            }
        }
        .formStyle(.grouped)
        .frame(height: 560)
        .onAppear { portText = localAPIPort == 0 ? "" : String(localAPIPort) }
        .sheet(isPresented: $showsNewToken, onDismiss: { api.clientsDidChange() }) {
            NewTokenSheet()
        }
        .confirmationDialog("Revoke all connected apps?", isPresented: $confirmRevokeAll) {
            Button("Revoke All", role: .destructive) {
                do {
                    try AutomationService.shared.clients.revokeAll()
                    revokeError = nil
                } catch {
                    revokeError = IntegrationsSettingsView.describe(error)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every paired app and token stops working right away. Apps need to pair again to use NoteIt.")
        }
    }

    static func describe(_ error: Error) -> String {
        (error as? AutomationError)?.message ?? error.localizedDescription
    }

    private func commitPort() {
        let trimmed = portText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.localizedCaseInsensitiveCompare("Automatic") == .orderedSame {
            portText = ""
            portError = nil
            localAPIPort = 0
            return
        }
        guard let port = Int(trimmed), (1024...65535).contains(port) else {
            portError = "Enter a port from 1024 to 65535, or leave it empty for Automatic."
            return
        }
        portError = nil
        portText = String(port)
        localAPIPort = port
    }
}

enum LocalAPIStatusText {
    static func text(_ status: LocalAPIController.Status, enabled: Bool) -> String {
        switch status {
        case .on(let port): "On — 127.0.0.1:\(port)"
        case .off: enabled ? "Starting…" : "Off"
        case .portInUse(let port): "Port \(port) is in use by another app"
        case .failed(let reason): "Couldn't start: \(reason)"
        }
    }

    static func symbol(_ status: LocalAPIController.Status) -> String {
        switch status {
        case .on: "checkmark.circle.fill"
        case .off: "circle"
        case .portInUse, .failed: "exclamationmark.triangle.fill"
        }
    }

    static func color(_ status: LocalAPIController.Status) -> Color {
        switch status {
        case .on: .green
        case .off: .secondary
        case .portInUse, .failed: .orange
        }
    }
}

private struct ConnectedAppsList: View {
    let generation: Int
    @Binding var revokeError: String?
    @State private var refresh = 0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let clients = AutomationService.shared.clients.list().sorted { $0.createdAt < $1.createdAt }
            let _ = (generation, refresh)
            if clients.isEmpty {
                Text("No apps are paired. Apps ask to pair, and NoteIt shows a code to confirm.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 10) {
                    ForEach(clients, id: \.id) { client in
                        row(client, now: context.date)
                    }
                }
            }
        }
    }

    private func row(_ client: ClientDTO, now: Date) -> some View {
        HStack(spacing: 10) {
            Image(systemName: Self.symbol(client.kind))
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(client.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(Self.details(client, now: now))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(client.origin ?? client.tokenHint)
            }
            Spacer()
            Button("Revoke") {
                do {
                    try AutomationService.shared.clients.revoke(client.id)
                    revokeError = nil
                } catch {
                    revokeError = IntegrationsSettingsView.describe(error)
                }
                refresh += 1
            }
            .controlSize(.small)
        }
    }

    static func symbol(_ kind: ClientKind) -> String {
        switch kind {
        case .cli: "terminal"
        case .extension: "puzzlepiece.extension"
        case .mcp: "sparkles"
        case .script: "applescript"
        }
    }

    static func details(_ client: ClientDTO, now: Date) -> String {
        let used = client.lastUsedAt.map { "Last used \(SyncStatusPresentation.relative($0, now: now))" } ?? "Never used"
        return "\(NewTokenSheet.Access(client.scopes).title) · \(used)"
    }
}

private struct NewTokenSheet: View {
    enum Access: Hashable, CaseIterable {
        case read, write, admin

        init(_ scopes: [APIScope]) {
            switch scopes.max() ?? .read {
            case .read: self = .read
            case .write: self = .write
            case .admin: self = .admin
            }
        }

        var title: String {
            switch self {
            case .read: "Read"
            case .write: "Read and change"
            case .admin: "Read, change and manage apps"
            }
        }

        var scope: APIScope {
            switch self {
            case .read: .read
            case .write: .write
            case .admin: .admin
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var access = Access.write
    @State private var token: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Token")
                .font(.headline)
            if let token {
                Text(token)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                SettingsFootnote(text: "You won't see this token again.", symbol: "exclamationmark.triangle.fill", color: .orange)
                HStack {
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(token, forType: .string)
                    }
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                Form {
                    TextField("Name", text: $name, prompt: Text("My script"))
                    Picker("Access", selection: $access) {
                        ForEach(Access.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
                if let error {
                    SettingsFootnote(text: error, symbol: "xmark.octagon.fill", color: .red)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Create") { create() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func create() {
        do {
            token = try AutomationService.shared.clients.issue(name: name, kind: .script, scopes: [access.scope], origin: nil).token
            error = nil
        } catch {
            self.error = IntegrationsSettingsView.describe(error)
        }
    }
}

/// Install, fix or remove the `/usr/local/bin/noteit` link to the tool inside the app, and its shell completion links.
struct CommandLineToolSection: View {
    @State private var state = CLIInstaller.live().state()
    @State private var working = false
    @State private var error: String?
    private let installer = CLIInstaller.live()

    var body: some View {
        Section {
            LabeledContent("Status") {
                HStack {
                    Text(statusText).foregroundStyle(.secondary)
                    if installer.toolURL != nil { button }
                }
            }
            if let error {
                SettingsFootnote(text: error, symbol: "xmark.octagon.fill", color: .red)
            }
            if state == .installed, !installer.bundledCompletions.isEmpty {
                SettingsFootnote(text: "Tab completion in zsh needs this line in ~/.zshrc: autoload -Uz compinit && compinit")
            }
            SettingsFootnote(text: "Also available with Homebrew: brew install --cask noteit")
        } header: {
            Text("Command line tool")
        }
        .onAppear { state = installer.state() }
    }

    private var statusText: String {
        guard installer.toolURL != nil else { return "Not included in this copy of NoteIt" }
        switch state {
        case .notInstalled: return "Not installed"
        case .installed: return "Installed at \(installer.linkURL.path)"
        case .completionsMissing: return "Installed without shell completion"
        case .otherCopy: return "Points to another copy of NoteIt"
        case .pointsElsewhere: return "\(installer.linkURL.path) is used by something else"
        }
    }

    @ViewBuilder private var button: some View {
        switch state {
        case .notInstalled: Button("Install…") { perform { try installer.install() } }.disabled(working)
        case .installed: Button("Uninstall") { perform { try installer.uninstall() } }.disabled(working)
        case .otherCopy, .completionsMissing: Button("Fix") { perform { try installer.install() } }.disabled(working)
        case .pointsElsewhere: EmptyView()
        }
    }

    private func perform(_ action: @escaping @Sendable () throws -> Void) {
        working = true
        Task {
            do {
                try await AppleScriptThread.shared.run(action)
                error = nil
            } catch CLIInstallerError.cancelled {
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
            state = installer.state()
            working = false
        }
    }
}
