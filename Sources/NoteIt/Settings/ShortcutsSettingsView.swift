import SwiftUI

struct ShortcutsSettingsView: View {
    @ObservedObject private var manager = HotkeyManager.shared

    var body: some View {
        Form {
            Section {
                ForEach(HotkeyAction.allCases) { action in
                    HotkeyRow(action: action)
                }
            } header: {
                Text("Global Shortcuts")
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    SettingsFootnote(text: "Shortcuts work from any app. No special permissions needed.", symbol: "globe")
                    Spacer()
                    if !manager.bindings.isEmpty {
                        Button("Clear All") { manager.clearAll() }
                            .controlSize(.small)
                    }
                }
                .padding(.top, 4)
            }
        }
        .formStyle(.grouped)
        .frame(height: 330)
    }
}

private struct HotkeyRow: View {
    let action: HotkeyAction

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: action.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.Radius.tile, style: .continuous)
                        .fill(LinearGradient(colors: [tint.opacity(0.85), tint], startPoint: .top, endPoint: .bottom))
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                    .font(.system(size: 13, weight: .medium))
                Text(action.description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            ShortcutRecorder(action: action)
        }
        .padding(.vertical, 4)
    }

    private var tint: Color {
        switch action {
        case .showMainWindow: Tokens.Color.tileShowHide
        case .newNote: Tokens.Color.tileNewNote
        case .quickCapture: Tokens.Color.tileQuickCapture
        }
    }
}
