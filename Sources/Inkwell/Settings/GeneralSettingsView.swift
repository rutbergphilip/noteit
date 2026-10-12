import ServiceManagement
import SwiftUI

struct GeneralSettingsView: View {
    @AppStorage(PrefKey.hideDockIcon) private var hideDockIcon = false
    @AppStorage(PrefKey.showMenuBarIcon) private var showMenuBarIcon = true

    @State private var launchAtLogin = false
    @State private var loginStatus: SMAppService.Status = .notRegistered
    @State private var loginError: String?

    /// SMAppService.mainApp only works for a real .app bundle.
    private var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    var body: some View {
        Form {
            Section {
                Picker("Show Inkwell in", selection: dockBinding) {
                    Text("Dock and menu bar").tag(false)
                    Text("Menu bar only").tag(true)
                }
                .pickerStyle(.menu)

                Toggle("Show menu bar icon", isOn: $showMenuBarIcon)
                    .disabled(hideDockIcon)
                if hideDockIcon {
                    SettingsFootnote(text: "The menu bar icon stays visible while Inkwell is hidden from the Dock, so you can always get back to your notes.")
                }
            } header: {
                Text("Appearance")
            }

            Section {
                Toggle("Launch at login", isOn: loginBinding)
                    .disabled(!isBundled)
                if !isBundled {
                    SettingsFootnote(text: "Available when Inkwell runs from its app bundle.", symbol: "info.circle")
                } else if let loginError {
                    SettingsFootnote(text: loginError, symbol: "exclamationmark.triangle.fill", color: .orange)
                } else if loginStatus == .requiresApproval {
                    HStack {
                        SettingsFootnote(text: "Allow Inkwell in Login Items to finish setup.", symbol: "exclamationmark.circle")
                        Spacer()
                        Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                            .controlSize(.small)
                    }
                }
            } header: {
                Text("Startup")
            }
        }
        .formStyle(.grouped)
        .frame(height: 300)
        .onAppear(perform: refreshLoginStatus)
    }

    private var dockBinding: Binding<Bool> {
        Binding(
            get: { hideDockIcon },
            set: { hide in
                // Menu-bar-only without a menu bar icon would make Inkwell unreachable.
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
    }
}
