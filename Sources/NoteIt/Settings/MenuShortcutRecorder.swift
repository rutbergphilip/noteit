import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Click-to-record control for a menu shortcut. Works like `ShortcutRecorder`: Esc cancels and
/// Delete/Backspace leaves the command without a shortcut.
struct MenuShortcutRecorder: View {
    let command: MenuShortcutCommand
    @ObservedObject private var store = MenuShortcutStore.shared
    @ObservedObject private var hotkeys = HotkeyManager.shared

    @State private var isRecording = false
    @State private var liveModifiers: NSEvent.ModifierFlags = []
    @State private var token = UUID()
    @State private var warning: String?
    /// The shortcut a heads-up is about; nil for a rejection.
    @State private var warningShortcut: MenuShortcut?
    @State private var shake: CGFloat = 0

    private var shortcut: MenuShortcut? { store.current(command) }

    private var visibleWarning: String? {
        guard let warning else { return nil }
        if let warningShortcut, warningShortcut != shortcut { return nil }
        return warning
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            ShortcutRecorderField(
                isRecording: isRecording,
                keycaps: shortcut?.keycaps,
                liveModifiers: liveModifiers,
                shake: shake,
                accessibilityLabel: "\(command.title) shortcut",
                accessibilityValue: shortcut?.display ?? "None",
                onToggle: { isRecording ? stopRecording() : startRecording() },
                onCancel: { stopRecording() },
                onClear: shortcut == nil ? nil : {
                    warning = nil
                    store.clear(command)
                }
            )
            ShortcutRecorderStatus(message: visibleWarning.map { .warning($0) })
        }
        .animation(.easeOut(duration: 0.15), value: isRecording)
        .animation(.easeOut(duration: 0.15), value: visibleWarning)
        .onDisappear { stopRecording() }
    }

    // MARK: - Recording

    private func startRecording() {
        guard !ShortcutRecordingSession.isActive(token) else { return }
        warning = nil
        liveModifiers = []
        isRecording = true
        ShortcutRecordingSession.begin(
            token: token,
            onEvent: { key in handle(key) },
            onEnd: {
                isRecording = false
                liveModifiers = []
            }
        )
    }

    private func stopRecording() {
        ShortcutRecordingSession.end(token)
        isRecording = false
        liveModifiers = []
    }

    /// Returns true to swallow the event while recording.
    private func handle(_ key: RecordedKey) -> Bool {
        guard isRecording else { return false }
        let flags = key.flags.intersection([.command, .option, .control, .shift])
        if key.isFlagsChanged {
            liveModifiers = flags
            return true
        }

        switch Int(key.keyCode) {
        case kVK_Escape where flags.isEmpty:
            stopRecording()
            return true
        case kVK_Delete where flags.isEmpty, kVK_ForwardDelete where flags.isEmpty:
            store.clear(command)
            stopRecording()
            return true
        default:
            break
        }

        guard let recorded = MenuShortcutRules.shortcut(keyCode: Int(key.keyCode), characters: key.commandCharacters,
                                                        charactersIgnoringModifiers: key.charactersIgnoringModifiers,
                                                        modifierFlags: flags) else {
            reject("That key can't be used in a shortcut.")
            return true
        }
        let combo = KeyCombo(keyCode: UInt32(key.keyCode), modifiers: KeyCombo.carbonModifiers(from: flags))
        let verdict = MenuShortcutRules.evaluate(recorded, for: command, store: store, keyCombo: combo,
                                                 globalBindings: hotkeys.bindings)
        switch verdict {
        case .reject(let message):
            reject(message)
        case .accept(let notice):
            stopRecording()
            store.set(recorded, for: command)
            if let notice {
                warn(notice, about: recorded)
            } else if HotkeyManager.isSystemShortcut(combo) {
                warn("\(recorded.display) is also a macOS shortcut and may not work.", about: recorded)
            }
        }
        return true
    }

    private func warn(_ message: String, about shortcut: MenuShortcut) {
        warning = message
        warningShortcut = shortcut
    }

    private func reject(_ message: String) {
        warning = message
        warningShortcut = nil
        NSSound.beep()
        withAnimation(.linear(duration: 0.3)) { shake += 1 }
    }
}
