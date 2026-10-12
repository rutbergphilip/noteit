import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Click-to-record control for a global hotkey.
///
/// While recording: the next key press with ⌘/⌃/⌥ (or an F-key) is captured, Esc cancels,
/// Delete/Backspace clears the binding. Existing global hotkeys are suspended meanwhile.
struct ShortcutRecorder: View {
    let action: HotkeyAction
    @ObservedObject private var manager = HotkeyManager.shared

    @State private var isRecording = false
    @State private var liveModifiers: NSEvent.ModifierFlags = []
    @State private var token = UUID()
    @State private var warning: String?
    @State private var isHovering = false
    @State private var shake: CGFloat = 0

    private var combo: KeyCombo? { manager.displayedCombo(for: action) }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            field
            if let message = statusMessage {
                Label(message.text, systemImage: message.symbol)
                    .font(.caption)
                    .foregroundStyle(message.color)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: isRecording)
        .animation(.easeOut(duration: 0.15), value: warning)
        .onDisappear { stopRecording() }
    }

    // MARK: - Field

    private var field: some View {
        HStack(spacing: 6) {
            Group {
                if isRecording {
                    recordingContent
                } else if let combo {
                    KeycapRow(keys: combo.keycaps)
                } else {
                    Text("Record Shortcut")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)

            if isRecording {
                Button { stopRecording() } label: {
                    Image(systemName: "escape")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Cancel (Esc)")
            } else if combo != nil {
                Button {
                    warning = nil
                    manager.setCombo(nil, for: action)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear shortcut")
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 8)
        .frame(width: 170, height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isRecording ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(isRecording ? Color.accentColor : Color.primary.opacity(isHovering ? 0.25 : 0.14),
                              lineWidth: isRecording ? 1.5 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { isRecording ? stopRecording() : startRecording() }
        .onHover { isHovering = $0 }
        .modifier(ShakeEffect(travel: shake))
        .help(isRecording ? "Press a shortcut — Esc to cancel, ⌫ to clear" : "Click to record a shortcut")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(action.title) shortcut")
        .accessibilityValue(combo?.displayString ?? "None")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { isRecording ? stopRecording() : startRecording() }
    }

    @ViewBuilder
    private var recordingContent: some View {
        let symbols = KeyCombo(keyCode: 0, modifiers: KeyCombo.carbonModifiers(from: liveModifiers)).modifierSymbols
        if symbols.isEmpty {
            Text("Type Shortcut…")
                .foregroundStyle(Color.accentColor)
        } else {
            KeycapRow(keys: symbols + ["…"])
        }
    }

    private struct StatusMessage {
        var text: String
        var symbol: String
        var color: Color
    }

    private var statusMessage: StatusMessage? {
        if let warning {
            return StatusMessage(text: warning, symbol: "exclamationmark.triangle.fill", color: .orange)
        }
        if !isRecording, let status = manager.registrationErrors[action] {
            return StatusMessage(text: HotkeyManager.describe(status), symbol: "exclamationmark.octagon.fill", color: .red)
        }
        return nil
    }

    // MARK: - Recording

    private func startRecording() {
        guard !ShortcutRecordingSession.isActive(token) else { return }
        warning = nil
        liveModifiers = []
        isRecording = true
        // Ends any other recorder's session first (synchronously), so hotkeys are suspended exactly once.
        ShortcutRecordingSession.begin(
            token: token,
            onEvent: { keyCode, flags, isFlagsChanged in
                handle(keyCode: keyCode, flags: flags, isFlagsChanged: isFlagsChanged)
            },
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
    private func handle(keyCode: UInt16, flags: NSEvent.ModifierFlags, isFlagsChanged: Bool) -> Bool {
        guard isRecording else { return false }
        if isFlagsChanged {
            liveModifiers = flags.intersection([.command, .option, .control, .shift])
            return true
        }

        let combo = KeyCombo(keyCode: UInt32(keyCode), modifiers: KeyCombo.carbonModifiers(from: flags))
        let bare = combo.modifiers == 0
        switch Int(keyCode) {
        case kVK_Escape where bare:
            stopRecording()
            return true
        case kVK_Delete where bare, kVK_ForwardDelete where bare:
            manager.setCombo(nil, for: action)
            stopRecording()
            return true
        default:
            break
        }

        guard combo.isValidGlobalHotkey else {
            reject("Include ⌘, ⌃ or ⌥ — or use a function key.")
            return true
        }
        if let other = manager.action(using: combo, excluding: action) {
            reject("\(combo.displayString) is already used for “\(other.title)”.")
            return true
        }

        stopRecording()
        manager.setCombo(combo, for: action)
        if HotkeyManager.isSystemShortcut(combo) {
            warning = "\(combo.displayString) is also a macOS shortcut and may not work."
        } else if combo.modifiers == UInt32(cmdKey) || combo.modifiers == UInt32(cmdKey | shiftKey) {
            warning = "Heads-up: \(combo.displayString) is common in other apps and will be taken over everywhere."
        }
        return true
    }

    private func reject(_ message: String) {
        warning = message
        NSSound.beep()
        withAnimation(.linear(duration: 0.3)) { shake += 1 }
    }
}

/// The single app-wide shortcut recording session. Starting a new one ends the previous one,
/// and suspend/resume of the global hotkeys is always balanced (one suspend per session).
@MainActor
enum ShortcutRecordingSession {
    private static var currentToken: UUID?
    private static var onEnd: (() -> Void)?
    private static var monitor: Any?
    private static var observers: [NSObjectProtocol] = []

    static func isActive(_ token: UUID) -> Bool { currentToken == token }

    static func begin(token: UUID,
                      onEvent: @escaping @MainActor (UInt16, NSEvent.ModifierFlags, Bool) -> Bool,
                      onEnd: @escaping @MainActor () -> Void) {
        if let current = currentToken { end(current) }
        currentToken = token
        self.onEnd = onEnd
        HotkeyManager.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            // Local monitors are invoked synchronously on the main thread.
            let keyCode = event.keyCode
            let flags = event.modifierFlags
            let isFlagsChanged = event.type == .flagsChanged
            let swallow = MainActor.assumeIsolated { () -> Bool in
                guard currentToken == token else { return false }
                return onEvent(keyCode, flags, isFlagsChanged)
            }
            return swallow ? nil : event
        }
        // Stop when the window loses focus or closes (e.g. Settings closed while recording).
        let center = NotificationCenter.default
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { _ in
                Task { @MainActor in end(token) }
            })
        }
    }

    /// Ends the session if `token` owns it; no-op otherwise.
    static func end(_ token: UUID) {
        guard currentToken == token else { return }
        currentToken = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        let callback = onEnd
        onEnd = nil
        HotkeyManager.shared.resume()
        callback?()
    }
}

/// Row of keycap-style chips, e.g. ⌃ ⌘ E.
struct KeycapRow: View {
    let keys: [String]
    var size: CGFloat = 11

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Keycap(label: key, size: size)
            }
        }
    }
}

struct Keycap: View {
    let label: String
    var size: CGFloat = 11

    var body: some View {
        Text(label)
            .font(.system(size: size, weight: .medium, design: .rounded))
            .foregroundStyle(.primary)
            .padding(.horizontal, label.count > 1 ? 5 : 0)
            .frame(minWidth: size + 8, minHeight: size + 7)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(color: .black.opacity(0.18), radius: 0, x: 0, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
            )
    }
}

private struct ShakeEffect: GeometryEffect {
    var travel: CGFloat
    var animatableData: CGFloat {
        get { travel }
        set { travel = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 5 * sin(travel * .pi * 4), y: 0))
    }
}
