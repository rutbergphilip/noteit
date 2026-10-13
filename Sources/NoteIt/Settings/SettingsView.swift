import SwiftUI

/// NoteIt › Settings… (⌘,)
struct SettingsView: View {
    enum Tab: String, Hashable { case general, shortcuts, editor, sync, about }

    @AppStorage(SettingsTabRouter.key) private var tabRaw = Tab.general.rawValue

    private var tab: Binding<Tab> {
        Binding(get: { Tab(rawValue: tabRaw) ?? .general }, set: { tabRaw = $0.rawValue })
    }

    var body: some View {
        TabView(selection: tab) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)
            ShortcutsSettingsView()
                .tabItem { Label("Shortcuts", systemImage: "command") }
                .tag(Tab.shortcuts)
            EditorSettingsView()
                .tabItem { Label("Editor", systemImage: "textformat") }
                .tag(Tab.editor)
            SyncSettingsView()
                .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath.icloud") }
                .tag(Tab.sync)
            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(Tab.about)
        }
        .frame(width: Tokens.Size.settingsWidth)
        .onReceive(NotificationCenter.default.publisher(for: .noteItShowSettingsTab)) { note in
            if let raw = note.object as? String {
                tabRaw = (Tab(rawValue: raw) ?? .general).rawValue
            }
        }
    }
}

/// Opens Settings on a specific tab (the selection lives in UserDefaults, so it works before the window exists).
@MainActor
enum SettingsTabRouter {
    static let key = "settingsTab"

    static func show(_ tab: SettingsView.Tab, using openSettings: OpenSettingsAction? = nil) {
        UserDefaults.standard.set(tab.rawValue, forKey: key)
        NotificationCenter.default.post(name: .noteItShowSettingsTab, object: tab.rawValue)
        SettingsOpener.open(using: openSettings)
    }
}

extension Notification.Name {
    /// Object: "general" | "shortcuts" | "editor" | "sync" | "about".
    static let noteItShowSettingsTab = Notification.Name("noteItShowSettingsTab")
}

/// Small grey explanatory text used under settings rows.
struct SettingsFootnote: View {
    let text: String
    var symbol: String?
    var color: Color = .secondary

    var body: some View {
        Group {
            if let symbol {
                Label(text, systemImage: symbol)
            } else {
                Text(text)
            }
        }
        .font(.callout)
        .foregroundStyle(color)
        .fixedSize(horizontal: false, vertical: true)
    }
}
