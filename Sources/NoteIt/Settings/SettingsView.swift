import SwiftUI

/// NoteIt › Settings… (⌘,)
struct SettingsView: View {
    /// Program §9's Settings tabs, in order. Hidden tabs are reserved for their owners, who flip `isAvailable` in the
    /// task that builds the tab. Foundations Task 6.3.
    enum Tab: String, Hashable, CaseIterable {
        case general, shortcuts, editor, sync, data, sharing, smart, integrations, plugins, about

        /// False until the owner builds the tab: data (markdown-storage), sharing, smart (private-ai) and plugins.
        var isAvailable: Bool {
            switch self {
            case .general, .shortcuts, .editor, .sync, .integrations, .about: true
            case .data, .sharing, .smart, .plugins: false
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .shortcuts: "command"
            case .editor: "textformat"
            case .sync: "arrow.triangle.2.circlepath.icloud"
            case .data: "externaldrive"
            case .sharing: "person.2"
            case .smart: "sparkles"
            case .integrations: "point.3.connected.trianglepath.dotted"
            case .plugins: "puzzlepiece.extension"
            case .about: "info.circle"
            }
        }

        /// The tab a stored or requested raw value opens: General when it's unknown or not available yet.
        static func resolved(_ rawValue: String) -> Tab {
            Tab(rawValue: rawValue)?.availableOrGeneral ?? .general
        }

        var availableOrGeneral: Tab { isAvailable ? self : .general }
    }

    @AppStorage(SettingsTabRouter.key) private var tabRaw = Tab.general.rawValue

    private var tab: Binding<Tab> {
        Binding(get: { Tab.resolved(tabRaw) }, set: { tabRaw = $0.availableOrGeneral.rawValue })
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
            IntegrationsSettingsView()
                .tabItem { Label("Integrations", systemImage: Tab.integrations.symbol) }
                .tag(Tab.integrations)
            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(Tab.about)
        }
        .frame(width: Tokens.Size.settingsWidth)
        .onReceive(NotificationCenter.default.publisher(for: .noteItShowSettingsTab)) { note in
            if let raw = note.object as? String {
                tabRaw = Tab.resolved(raw).rawValue
            }
        }
    }
}

/// Opens Settings on a specific tab (the selection lives in UserDefaults, so it works before the window exists).
@MainActor
enum SettingsTabRouter {
    static let key = "settingsTab"

    /// A tab that isn't available yet opens General.
    static func show(_ tab: SettingsView.Tab, using openSettings: OpenSettingsAction? = nil) {
        let tab = tab.availableOrGeneral
        UserDefaults.standard.set(tab.rawValue, forKey: key)
        NotificationCenter.default.post(name: .noteItShowSettingsTab, object: tab.rawValue)
        SettingsOpener.open(using: openSettings)
    }
}

extension Notification.Name {
    /// Object: a `SettingsView.Tab` raw value: "general" | "shortcuts" | "editor" | "sync" | "data" | "sharing" |
    /// "smart" | "integrations" | "plugins" | "about". One that isn't available yet (or unknown) opens General.
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
