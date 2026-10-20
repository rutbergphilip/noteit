import SwiftUI

/// Settings › Integrations. Links for now; the Local API, Shortcuts, Spotlight and Share sections come later.
struct IntegrationsSettingsView: View {
    @AppStorage(PrefKey.urlSchemeChangesWithoutAsking) private var changesWithoutAsking = false

    var body: some View {
        Form {
            Section {
                Toggle("Allow links to change notes without asking", isOn: $changesWithoutAsking)
                SettingsFootnote(text: "Links from other apps that create or add to a note ask first. Links that only open something never ask.")
            } header: {
                Text("Links")
            }
        }
        .formStyle(.grouped)
        .frame(height: 200)
    }
}
