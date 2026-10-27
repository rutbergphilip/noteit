import AppKit
import NoteItSync
import SwiftUI

struct SyncSettingsView: View {
    @ObservedObject private var sync = SyncController.shared

    var body: some View {
        Group {
            if let config = sync.configuration {
                SyncConnectedView(config: config)
            } else {
                SyncSetupView()
            }
        }
        .frame(height: sync.configuration == nil ? 560 : 500)
    }
}

// MARK: - Setup (disconnected)

private struct SyncSetupView: View {
    @ObservedObject private var sync = SyncController.shared

    @State private var provider: SyncProvider?
    @State private var folderURL: URL?
    @State private var folderBookmark: Data?
    @State private var endpoint = ""
    @State private var region = ""
    @State private var bucket = ""
    @State private var pathStyle = false
    @State private var prefix = ""
    @State private var accessKey = ""
    @State private var secret = ""
    @State private var encrypt = true
    @State private var passphrase = ""
    @State private var confirmation = ""
    /// The destination already holds an encrypted library: only ask for its passphrase.
    @State private var joinExisting = false
    @State private var busy: BusyAction?
    @State private var feedback: Feedback?

    private enum BusyAction { case testing, connecting }

    private struct Feedback: Equatable {
        var text: String
        var isError: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            form
            if provider != nil { actionBar }
        }
        .onChange(of: destinationFingerprint) { _, _ in
            joinExisting = false
            feedback = nil
        }
        .onChange(of: region) { old, new in updateEndpoint(oldRegion: old, newRegion: new) }
    }

    private var form: some View {
        Form {
            Section {
                ProviderGrid(selection: providerBinding)
            } header: {
                Text("Storage")
            } footer: {
                if provider == nil {
                    SettingsFootnote(text: "Your notes sync through storage you own. NoteIt doesn't run a server and never sees your data.",
                                     symbol: "hand.raised")
                        .padding(.top, 2)
                }
            }

            if let provider {
                Section {
                    if provider == .folder {
                        folderForm
                    } else {
                        s3Form(provider)
                    }
                } header: {
                    Text(provider.displayName)
                } footer: {
                    SettingsFootnote(text: provider.helpText).padding(.top, 2)
                }

                Section {
                    encryptionForm
                } header: {
                    Text("Encryption")
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Forms

    private var folderForm: some View {
        LabeledContent("Folder") {
            HStack(spacing: 8) {
                if let folderURL {
                    Label {
                        Text((folderURL.path as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } icon: {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: folderURL.path))
                            .resizable()
                            .frame(width: 16, height: 16)
                    }
                    .help(folderURL.path)
                } else {
                    Text("None selected")
                        .foregroundStyle(.secondary)
                }
                Button(folderURL == nil ? "Choose Folder…" : "Change…", action: chooseFolder)
            }
        }
    }

    @ViewBuilder
    private func s3Form(_ provider: SyncProvider) -> some View {
        TextField("Endpoint", text: $endpoint, prompt: Text(provider.endpointTemplate))
        if let endpointProblem {
            SettingsFootnote(text: endpointProblem, symbol: "xmark.octagon.fill", color: .red)
        }
        TextField("Region", text: $region, prompt: Text(provider.defaultRegion))
        TextField("Bucket", text: $bucket, prompt: Text("my-notes"))
        if provider.allowsKeyPrefix {
            TextField("Folder inside bucket", text: $prefix, prompt: Text("Optional"))
        }
        Toggle("Path-style addressing", isOn: $pathStyle)
        TextField("Access key ID", text: $accessKey)
        SecureField("Secret access key", text: $secret)
    }

    @ViewBuilder
    private var encryptionForm: some View {
        if joinExisting {
            Label {
                Text("This location already has an encrypted NoteIt library.")
            } icon: {
                Image(systemName: "lock.fill").foregroundStyle(.green)
            }
            SecureField("Passphrase", text: $passphrase, prompt: Text("Enter the passphrase used on your other Mac"))
            SettingsFootnote(text: PassphraseHint.text)
        } else {
            Toggle(isOn: $encrypt) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("End-to-end encryption")
                    Text("Notes are encrypted on this Mac before they're uploaded.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            if encrypt {
                SecureField("Passphrase", text: $passphrase, prompt: Text("At least 8 characters"))
                SecureField("Confirm passphrase", text: $confirmation)
                SettingsFootnote(text: PassphraseHint.text)
                if !passphrase.isEmpty {
                    PassphraseMeter(passphrase: passphrase, confirmation: confirmation)
                }
                SettingsFootnote(text: "If you lose this passphrase, your synced notes can't be decrypted. NoteIt never sees or stores it outside your Mac's keychain.",
                                 symbol: "exclamationmark.triangle.fill", color: .orange)
            } else {
                SettingsFootnote(text: "Without encryption, anyone with access to the storage can read your notes.",
                                 symbol: "info.circle")
            }
        }
    }

    private var actionBar: some View {
        HStack(alignment: .center, spacing: 10) {
            Group {
                if let busy {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(busy == .testing ? "Testing…" : "Connecting…")
                            .foregroundStyle(.secondary)
                    }
                } else if let feedback {
                    Label {
                        Text(feedback.text).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: feedback.isError ? "xmark.octagon.fill" : "checkmark.circle.fill")
                            .foregroundStyle(feedback.isError ? .red : .green)
                    }
                    .foregroundStyle(feedback.isError ? .primary : .secondary)
                    .textSelection(.enabled)
                }
            }
            .font(.callout)
            Spacer(minLength: 0)

            Button("Test Connection") { Task { await test() } }
                .disabled(busy != nil || !destinationComplete)
            Button("Connect & Sync") { Task { await connect() } }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(busy != nil || !canConnect)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: State

    private var providerBinding: Binding<SyncProvider?> {
        Binding(get: { provider }, set: { new in
            guard new != provider, let new else { return }
            provider = new
            guard new.isS3 else { return }
            region = new.defaultRegion
            pathStyle = new.defaultPathStyle
            if let defaultBucket = new.defaultBucket { bucket = defaultBucket }
            switch new {
            case .awsS3: endpoint = "https://s3.\(new.defaultRegion).amazonaws.com"
            case .backblazeB2: endpoint = "https://s3.\(new.defaultRegion).backblazeb2.com"
            default: endpoint = new.endpointTemplate
            }
        })
    }

    private func updateEndpoint(oldRegion: String, newRegion: String) {
        guard let provider, provider == .awsS3 || provider == .backblazeB2 else { return }
        let host = provider == .awsS3 ? "amazonaws.com" : "backblazeb2.com"
        if endpoint == "https://s3.\(oldRegion).\(host)" || endpoint.isEmpty || endpoint.contains("<") {
            endpoint = "https://s3.\(newRegion.isEmpty ? "<region>" : newRegion).\(host)"
        }
    }

    private var destinationFingerprint: String {
        [provider?.rawValue ?? "", folderURL?.path ?? "", endpoint, region, bucket, prefix, accessKey, "\(pathStyle)"].joined(separator: "|")
    }

    private var trimmedEndpoint: String { endpoint.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Cloud providers always offer https; plain http is only for self-hosted servers on the local network.
    private var endpointProblem: String? {
        guard let provider, provider.isS3, !provider.allowsPlainHTTP, trimmedEndpoint.lowercased().hasPrefix("http://") else { return nil }
        return SyncSetupError.insecureEndpoint(provider).errorDescription
    }

    private var destinationComplete: Bool {
        guard let provider else { return false }
        if provider == .folder { return folderURL != nil }
        return endpointProblem == nil && !trimmedEndpoint.isEmpty && !trimmedEndpoint.contains("<") && !bucket.trimmingCharacters(in: .whitespaces).isEmpty
            && !accessKey.trimmingCharacters(in: .whitespaces).isEmpty && !secret.isEmpty
    }

    private var canConnect: Bool {
        guard destinationComplete else { return false }
        if joinExisting { return !passphrase.isEmpty }
        if encrypt { return PassphraseStrength(passphrase) > .tooShort && passphrase == confirmation }
        return true
    }

    private func makeConfiguration() -> SyncConfiguration? {
        guard let provider else { return nil }
        var config = SyncConfiguration(provider: provider, encrypted: joinExisting || encrypt)
        if provider == .folder {
            config.folderPath = folderURL?.path
            config.folderBookmark = folderBookmark
        } else {
            guard let url = URL(string: trimmedEndpoint) else { return config }
            config.s3 = S3Config(
                endpoint: url,
                region: region.trimmingCharacters(in: .whitespaces).isEmpty ? provider.defaultRegion : region.trimmingCharacters(in: .whitespaces),
                bucket: bucket.trimmingCharacters(in: .whitespaces),
                pathStyle: pathStyle,
                prefix: provider.allowsKeyPrefix
                    ? prefix.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "/"))) : ""
            )
        }
        return config
    }

    // MARK: Actions

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder your other Macs can reach. NoteIt stores its files in an “\(RemoteLayout.folder)” subfolder."
        if let folderURL { panel.directoryURL = folderURL }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folderURL = url
        folderBookmark = SyncConfiguration.makeBookmark(for: url)
    }

    private func test() async {
        guard let config = makeConfiguration() else { return }
        busy = .testing
        feedback = nil
        let result = await sync.testConnection(config, accessKey: trimmed(accessKey), secret: secret)
        busy = nil
        switch result {
        case .success(let inspection):
            if inspection == .encrypted { enterJoinMode() }
            feedback = Feedback(text: inspection.summary, isError: { if case .unsupported = inspection { return true }; return false }())
        case .failure(let error):
            feedback = Feedback(text: SyncController.describe(error), isError: true)
        }
    }

    private func connect() async {
        guard let config = makeConfiguration() else { return }
        busy = .connecting
        feedback = nil
        defer { busy = nil }
        if !joinExisting {
            switch await sync.testConnection(config, accessKey: trimmed(accessKey), secret: secret) {
            case .success(.encrypted):
                enterJoinMode()
                feedback = Feedback(text: "Found an encrypted library. Enter its passphrase to join it.", isError: false)
                return
            case .success(.unsupported(let version)):
                feedback = Feedback(text: SyncController.describe(SyncError.unsupportedFormat(version)), isError: true)
                return
            case .failure(let error):
                feedback = Feedback(text: SyncController.describe(error), isError: true)
                return
            default:
                break
            }
        }
        do {
            let usesPassphrase = joinExisting || encrypt
            try await sync.connect(config, accessKey: trimmed(accessKey), secret: secret, passphrase: usesPassphrase ? passphrase : nil)
            passphrase = ""
            confirmation = ""
            secret = ""
        } catch SyncError.passphraseRequired {
            enterJoinMode()
            feedback = Feedback(text: "Found an encrypted library. Enter its passphrase to join it.", isError: false)
        } catch {
            feedback = Feedback(text: SyncController.describe(error), isError: true)
        }
    }

    private func enterJoinMode() {
        guard !joinExisting else { return }
        joinExisting = true
        passphrase = ""
        confirmation = ""
    }

    private func trimmed(_ value: String) -> String? {
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    #if DEBUG
    init() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--debug-sync-provider"), index + 1 < args.count,
              let preset = SyncProvider(rawValue: args[index + 1]) else { return }
        _provider = State(initialValue: preset)
        if preset == .folder, let path = AppEnvironment.value("DATA_DIR") {
            _folderURL = State(initialValue: URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("remote"))
        } else if preset.isS3 {
            _region = State(initialValue: preset.defaultRegion)
            _pathStyle = State(initialValue: preset.defaultPathStyle)
            _endpoint = State(initialValue: preset.endpointTemplate)
            if let defaultBucket = preset.defaultBucket { _bucket = State(initialValue: defaultBucket) }
            if let i = args.firstIndex(of: "--debug-sync-endpoint"), i + 1 < args.count {
                _endpoint = State(initialValue: args[i + 1])
            }
        }
    }
    #endif
}

private struct ProviderGrid: View {
    @Binding var selection: SyncProvider?

    private let perRow = 3

    private var rows: [[SyncProvider]] {
        stride(from: 0, to: SyncProvider.allCases.count, by: perRow).map {
            Array(SyncProvider.allCases[$0..<min($0 + perRow, SyncProvider.allCases.count)])
        }
    }

    /// Each card spans two of 2×perRow columns so a short last row can be centred.
    var body: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            ForEach(rows, id: \.self) { row in
                GridRow {
                    let inset = perRow - row.count
                    if inset > 0 { Color.clear.gridCellColumns(inset).frame(height: 0) }
                    ForEach(row) { provider in
                        ProviderCard(provider: provider, isSelected: selection == provider) {
                            withAnimation(.easeOut(duration: 0.15)) { selection = provider }
                        }
                        .gridCellColumns(2)
                    }
                    if inset > 0 { Color.clear.gridCellColumns(inset).frame(height: 0) }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ProviderCard: View {
    let provider: SyncProvider
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                ProviderIcon(provider: provider, size: 26)
                Text(provider.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(provider.hint)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(height: 28, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(isHovered ? 0.07 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isSelected ? 1.5 : 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel("\(provider.displayName). \(provider.hint)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct ProviderIcon: View {
    let provider: SyncProvider
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: provider.symbol)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                    .fill(LinearGradient(colors: [tint.opacity(0.85), tint], startPoint: .top, endPoint: .bottom))
            )
    }

    private var tint: Color {
        switch provider {
        case .folder: Tokens.Color.SyncProvider.folder
        case .awsS3: Tokens.Color.SyncProvider.awsS3
        case .cloudflareR2: Tokens.Color.SyncProvider.cloudflareR2
        case .backblazeB2: Tokens.Color.SyncProvider.backblazeB2
        case .googleCloud: Tokens.Color.SyncProvider.googleCloud
        case .minio: Tokens.Color.SyncProvider.minio
        case .customS3: Tokens.Color.SyncProvider.customS3
        case .noteItServer: Tokens.Color.SyncProvider.noteItServer
        }
    }
}

private struct PassphraseMeter: View {
    let passphrase: String
    let confirmation: String

    var body: some View {
        let strength = PassphraseStrength(passphrase)
        HStack(spacing: 10) {
            HStack(spacing: 3) {
                ForEach(1...4, id: \.self) { level in
                    Capsule()
                        .fill(level <= strength.rawValue ? color(strength) : Color.primary.opacity(0.1))
                        .frame(width: 34, height: 4)
                }
            }
            Text(strength.label)
                .font(.callout)
                .foregroundStyle(color(strength))
            Spacer()
            if !confirmation.isEmpty {
                Label(confirmation == passphrase ? "Passphrases match" : "Doesn't match",
                      systemImage: confirmation == passphrase ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(confirmation == passphrase ? .green : .red)
            }
        }
        .animation(.easeOut(duration: 0.15), value: strength)
    }

    private func color(_ strength: PassphraseStrength) -> Color {
        switch strength {
        case .tooShort, .weak: .red
        case .fair: .orange
        case .good: .yellow
        case .strong: .green
        }
    }
}

// MARK: - Connected

private struct SyncConnectedView: View {
    let config: SyncConfiguration
    @ObservedObject private var sync = SyncController.shared
    @EnvironmentObject private var store: NoteStore

    @State private var deviceName = ""
    @State private var confirmDisconnect = false
    @State private var unlockPassphrase = ""
    @State private var unlockError: String?
    @State private var unlocking = false
    @State private var editingCredentials = false
    @State private var newAccessKey = ""
    @State private var newSecret = ""
    @State private var credentialsBusy = false
    @State private var credentialsFeedback: (text: String, isError: Bool)?
    @State private var cleanupBusy = false
    @State private var cleanupResult: String?
    @FocusState private var nameFocused: Bool

    /// "Clean Up Unused Storage…" (web-app spec §3.4.9): only after the confirmation, never automatically.
    private var cleanupRow: some View {
        let state = CleanupButtonState(connected: sync.status != .needsPassphrase && sync.lastSync != nil,
                                       available: sync.cleanupAvailable)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                SettingsFootnote(text: "Removes copies of notes that were never finished saving.")
                Spacer()
                Button("Clean Up Unused Storage…") { confirmCleanup() }
                    .disabled(!state.isEnabled || cleanupBusy)
            }
            if let caption = state.caption {
                SettingsFootnote(text: caption)
            }
            if let cleanupResult {
                Text(cleanupResult)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func confirmCleanup() {
        let response = CleanupConfirmation.makeAlert().runModal()
        guard response == .alertSecondButtonReturn else { return }
        cleanupBusy = true
        Task {
            cleanupResult = await CleanupConfirmation.handle(response: response, cleaner: sync)
            cleanupBusy = false
        }
    }

    var body: some View {
        Form {
            Section {
                statusCard
                if sync.status == .needsPassphrase {
                    unlockForm
                }
            } header: {
                Text("Status")
            }

            Section {
                TextField("Name", text: $deviceName)
                    .focused($nameFocused)
                    .onSubmit { sync.rename(device: deviceName) }
                    .onChange(of: nameFocused) { _, focused in if !focused { sync.rename(device: deviceName) } }
                LabeledContent("Encryption") {
                    Label(config.encrypted ? "End-to-end encrypted" : "Not encrypted",
                          systemImage: config.encrypted ? "lock.fill" : "lock.open")
                        .foregroundStyle(config.encrypted ? .green : .secondary)
                }
                LabeledContent("Conflicts") {
                    if sync.conflictCount == 0 {
                        Text("None").foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 8) {
                            Label("\(sync.conflictCount) conflict \(sync.conflictCount == 1 ? "copy" : "copies")",
                                  systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Button("Show") { showConflicts() }
                                .controlSize(.small)
                        }
                    }
                }
            } header: {
                Text("This Mac")
            } footer: {
                if sync.conflictCount > 0 {
                    SettingsFootnote(text: "When a note changed on two Macs at once, both versions are kept. Review the copies, delete the one you don't need, or choose Mark Resolved.")
                        .padding(.top, 2)
                }
            }

            if config.provider.isS3 {
                Section {
                    credentialsForm
                } header: {
                    Text("Credentials")
                }
            }

            Section {
                devicesList
            } header: {
                Text("Devices")
            }

            Section {
                cleanupRow
            } header: {
                Text("Storage")
            }

            Section {
                HStack {
                    SettingsFootnote(text: "Notes stay on this Mac when you disconnect.")
                    Spacer()
                    Button("Disconnect…", role: .destructive) { confirmDisconnect = true }
                }
            }
        }
        .formStyle(.grouped)
        .background(InitialFocusClearer())
        .onAppear {
            deviceName = config.deviceName
            Task { await sync.refreshDevices() }
        }
        .onChange(of: sync.lastSync) { _, _ in Task { await sync.refreshDevices() } }
        .confirmationDialog("Disconnect from \(config.provider.displayName)?", isPresented: $confirmDisconnect) {
            Button("Disconnect", role: .destructive) { Task { await sync.disconnect() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your notes stay on this Mac and in \(config.destination). Syncing stops and the saved credentials are removed from the keychain.")
        }
    }

    private var statusCard: some View {
        let presentation = SyncStatusPresentation(status: sync.status, lastSync: sync.lastSync)
        return HStack(alignment: .center, spacing: 12) {
            ProviderIcon(provider: config.provider, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(config.provider.displayName)
                    .font(.system(size: 13, weight: .semibold))
                Text(config.destination)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(config.folderPath ?? config.destination)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        SyncStatusIcon(presentation: presentation)
                            .foregroundStyle(presentation.tint == .secondary ? .green : presentation.tint)
                        Text(presentation.headline(now: context.date))
                            .foregroundStyle(presentation.tint == .secondary ? .secondary : presentation.tint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.callout)
                }
                if let errors = sync.lastReport?.errors, !errors.isEmpty, case .idle = sync.status {
                    Text("\(errors.count) \(errors.count == 1 ? "item" : "items") will be retried on the next sync.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(errors.prefix(5).joined(separator: "\n"))
                }
            }
            Spacer(minLength: 8)
            Button {
                sync.syncNow()
            } label: {
                Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(sync.status == .syncing || sync.status == .needsPassphrase)
        }
        .padding(.vertical, 4)
    }

    private var unlockForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SecureField("Passphrase", text: $unlockPassphrase, prompt: Text("Enter the passphrase used on your other Mac"))
                    .onSubmit { Task { await unlock() } }
                Button("Unlock") { Task { await unlock() } }
                    .disabled(unlockPassphrase.isEmpty || unlocking)
            }
            SettingsFootnote(text: PassphraseHint.text)
            if let unlockError {
                SettingsFootnote(text: unlockError, symbol: "xmark.octagon.fill", color: .red)
            }
        }
    }

    @ViewBuilder
    private var credentialsForm: some View {
        if editingCredentials || sync.credentialsRejected {
            if sync.credentialsRejected {
                SettingsFootnote(text: "\(config.provider.displayName) rejected the saved access key. Enter a working key to resume syncing.",
                                 symbol: "exclamationmark.triangle.fill", color: .orange)
            }
            TextField("Access key ID", text: $newAccessKey)
            SecureField("Secret access key", text: $newSecret)
            if let credentialsFeedback {
                SettingsFootnote(text: credentialsFeedback.text,
                                 symbol: credentialsFeedback.isError ? "xmark.octagon.fill" : "checkmark.circle.fill",
                                 color: credentialsFeedback.isError ? .red : .green)
            }
            HStack {
                if credentialsBusy { ProgressView().controlSize(.small) }
                Spacer()
                if !sync.credentialsRejected {
                    Button("Cancel") { resetCredentialsForm() }
                }
                Button("Test") { Task { await submitCredentials(save: false) } }
                Button("Save") { Task { await submitCredentials(save: true) } }
                    .keyboardShortcut(.defaultAction)
            }
            .disabled(credentialsBusy || newAccessKey.trimmingCharacters(in: .whitespaces).isEmpty || newSecret.isEmpty)
        } else {
            LabeledContent("Access key ID") {
                HStack(spacing: 8) {
                    Text(sync.savedAccessKey ?? "—")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Update Credentials…") {
                        newAccessKey = sync.savedAccessKey ?? ""
                        editingCredentials = true
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private func resetCredentialsForm() {
        editingCredentials = false
        newAccessKey = ""
        newSecret = ""
        credentialsFeedback = nil
    }

    private func submitCredentials(save: Bool) async {
        credentialsBusy = true
        credentialsFeedback = nil
        defer { credentialsBusy = false }
        let key = newAccessKey.trimmingCharacters(in: .whitespaces)
        do {
            if save {
                try await sync.updateCredentials(accessKey: key, secret: newSecret)
                resetCredentialsForm()
            } else {
                try await sync.testCredentials(accessKey: key, secret: newSecret)
                credentialsFeedback = ("These credentials work.", false)
            }
        } catch {
            credentialsFeedback = (SyncController.describe(error), true)
        }
    }

    @ViewBuilder
    private var devicesList: some View {
        if sync.devices.isEmpty {
            Text("Your Macs appear here after their first sync.")
                .foregroundStyle(.secondary)
        } else {
            ForEach(sync.devices, id: \.deviceID) { device in
                let isThisMac = device.deviceID == config.deviceID
                HStack(spacing: 10) {
                    Image(systemName: "laptopcomputer")
                        .font(.system(size: 15))
                        .foregroundStyle(isThisMac ? Color.accentColor : .secondary)
                        .frame(width: 22)
                    Text(isThisMac ? config.deviceName : device.name)
                        .lineLimit(1)
                    if isThisMac {
                        Text("This Mac")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                    }
                    Spacer()
                    Text(isThisMac ? lastSeenThisMac : "Seen \(SyncStatusPresentation.relative(device.lastSync))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var lastSeenThisMac: String {
        sync.lastSync.map { "Synced \(SyncStatusPresentation.relative($0))" } ?? ""
    }

    private func unlock() async {
        unlocking = true
        unlockError = nil
        defer { unlocking = false }
        do {
            try await sync.unlock(passphrase: unlockPassphrase)
            unlockPassphrase = ""
        } catch {
            unlockError = SyncController.describe(error)
        }
    }

    private func showConflicts() {
        store.searchText = ""
        store.selection = .conflicts
        WindowRouter.showMainWindow()
    }
}

/// AppKit makes the first text field in a newly shown view key; this clears that initial focus once.
private struct InitialFocusClearer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ClearingView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ClearingView: NSView {
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeObserver()
            guard let window else { return }
            Self.clear(window)
            if !window.isKeyWindow {
                observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self, weak window] _ in
                    MainActor.assumeIsolated {
                        self?.removeObserver()
                        if let window { Self.clear(window) }
                    }
                }
            }
        }

        private func removeObserver() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }

        private static func clear(_ window: NSWindow) {
            DispatchQueue.main.async { [weak window] in
                guard let window, window.firstResponder is NSText else { return }
                window.makeFirstResponder(nil)
            }
        }
    }
}
