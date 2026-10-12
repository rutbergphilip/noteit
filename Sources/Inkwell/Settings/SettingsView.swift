import SwiftUI

/// Inkwell › Settings… (⌘,)
struct SettingsView: View {
    enum Tab: Hashable { case general, shortcuts, editor, about }

    @State private var tab: Tab = .general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)
            ShortcutsSettingsView()
                .tabItem { Label("Shortcuts", systemImage: "command") }
                .tag(Tab.shortcuts)
            EditorSettingsView()
                .tabItem { Label("Editor", systemImage: "textformat") }
                .tag(Tab.editor)
            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(Tab.about)
        }
        .frame(width: 520)
        .onReceive(NotificationCenter.default.publisher(for: .inkwellShowSettingsTab)) { note in
            if let raw = note.object as? String {
                switch raw {
                case "shortcuts": tab = .shortcuts
                case "editor": tab = .editor
                case "about": tab = .about
                default: tab = .general
                }
            }
        }
    }
}

extension Notification.Name {
    /// Object: "general" | "shortcuts" | "editor" | "about".
    static let inkwellShowSettingsTab = Notification.Name("inkwellShowSettingsTab")
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
