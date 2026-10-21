import SwiftUI

struct ShortcutsSettingsView: View {
    @ObservedObject private var manager = HotkeyManager.shared
    @ObservedObject private var menuShortcuts = MenuShortcutStore.shared

    var body: some View {
        Form {
            Section {
                ForEach(HotkeyAction.allCases) { action in
                    HotkeyRow(action: action)
                }
            } header: {
                Text("Global")
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    SettingsFootnote(text: "Global shortcuts work from any app. They're off until you set one. Only Capture Selection needs a permission, to read the selected text.",
                                     symbol: "globe")
                    Spacer()
                    if !manager.bindings.isEmpty {
                        Button("Clear All") { manager.clearAll() }
                            .controlSize(.small)
                    }
                }
                .padding(.top, 4)
            }

            Section {
                ForEach(MenuShortcutCommand.allCases) { command in
                    MenuShortcutRow(command: command)
                }
            } header: {
                Text("In NoteIt")
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    SettingsFootnote(text: "Menu shortcuts work while NoteIt is the active app.", symbol: "menubar.rectangle")
                    Spacer()
                    if menuShortcuts.hasCustomizations {
                        Button("Restore Defaults") { menuShortcuts.resetAll() }
                            .controlSize(.small)
                    }
                }
                .padding(.top, 4)
            }
        }
        .formStyle(.grouped)
        .frame(height: 560)
    }
}

private struct MenuShortcutRow: View {
    let command: MenuShortcutCommand
    @ObservedObject private var store = MenuShortcutStore.shared

    var body: some View {
        let customized = store.isCustomized(command)
        let blocker = store.resetBlocker(for: command)
        HStack(alignment: .top, spacing: 8) {
            Text(command.title)
                .font(.system(size: 13))
                .frame(height: 28)
            Spacer(minLength: 12)
            Button { store.reset(command) } label: {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .frame(height: 28)
            .help(resetHelp(blocker))
            .opacity(customized ? (blocker == nil ? 1 : 0.4) : 0)
            .disabled(!customized || blocker != nil)
            .accessibilityHidden(!customized)
            .accessibilityLabel("Restore default shortcut for \(command.title)")
            MenuShortcutRecorder(command: command)
        }
        .padding(.vertical, 1)
    }

    private func resetHelp(_ blocker: MenuShortcutCommand?) -> String {
        guard let shortcut = command.defaultShortcut?.display else { return "Remove the shortcut" }
        guard let blocker else { return "Restore \(shortcut)" }
        return "\(shortcut) is used for “\(blocker.title)”."
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
                        .fill(tint)
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
        case .openQuickly: Tokens.Color.tileOpenQuickly
        case .commandPalette: Tokens.Color.tileCommandPalette
        case .captureSelection: Tokens.Color.tileCaptureSelection
        case .openToday: Tokens.Color.tileOpenToday
        case .showTasks: Tokens.Color.tileShowTasks
        }
    }
}
