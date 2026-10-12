import AppKit
import Carbon.HIToolbox
import Combine

/// Registers system-wide hotkeys with Carbon's `RegisterEventHotKey`.
///
/// Carbon hotkeys are delivered to the app by the window server and do **not** require
/// Accessibility (or Input Monitoring) permission, unlike `CGEventTap`/global `NSEvent` monitors.
@MainActor
final class HotkeyManager: ObservableObject {
    static let shared = HotkeyManager()
    static let defaultsKey = "hotkeyBindings"

    /// Persisted bindings. Missing action == unbound (the default for every action).
    @Published private(set) var bindings: [HotkeyAction: KeyCombo] = [:]
    /// Actions whose combo could not be registered (e.g. already taken system-wide), with the OSStatus.
    @Published private(set) var registrationErrors: [HotkeyAction: OSStatus] = [:]
    /// Display-only overlay (debug screenshots). Never persisted, registered or used for conflict checks.
    @Published private(set) var previewBindings: [HotkeyAction: KeyCombo] = [:]

    /// Invoked on the main actor when a registered hotkey is pressed.
    var handler: ((HotkeyAction) -> Void)?

    private let defaults: UserDefaults
    private var hotKeyRefs: [HotkeyAction: EventHotKeyRef] = [:]
    private var eventHandlerRef: EventHandlerRef?
    private var suspendCount = 0
    private var started = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        bindings = Self.loadBindings(from: defaults)
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        installEventHandler()
        registerAll()
    }

    /// Temporarily unregisters every hotkey (used while the shortcut recorder is listening,
    /// so pressing an existing combo records it instead of firing it).
    func suspend() {
        suspendCount += 1
        if suspendCount == 1 { unregisterAll() }
    }

    func resume() {
        guard suspendCount > 0 else { return }
        suspendCount -= 1
        if suspendCount == 0 { registerAll() }
    }

    // MARK: - Bindings

    func combo(for action: HotkeyAction) -> KeyCombo? { bindings[action] }

    /// What the UI shows: the real binding, else a debug preview.
    func displayedCombo(for action: HotkeyAction) -> KeyCombo? { bindings[action] ?? previewBindings[action] }

    func action(using combo: KeyCombo, excluding excluded: HotkeyAction? = nil) -> HotkeyAction? {
        bindings.first { $0.key != excluded && $0.value == combo }?.key
    }

    func setCombo(_ combo: KeyCombo?, for action: HotkeyAction) {
        previewBindings[action] = nil
        if let combo { bindings[action] = combo } else { bindings[action] = nil }
        save()
        registerAll()
    }

    func clearAll() {
        previewBindings = [:]
        bindings = [:]
        save()
        registerAll()
    }

    #if DEBUG
    /// Debug/screenshot aid: shows a binding in the UI without persisting or registering it.
    func previewBinding(_ combo: KeyCombo, for action: HotkeyAction) {
        previewBindings[action] = combo
    }
    #endif

    // MARK: - Persistence

    static func encode(_ bindings: [HotkeyAction: KeyCombo]) throws -> Data {
        let raw = Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(raw)
    }

    static func decode(_ data: Data) throws -> [HotkeyAction: KeyCombo] {
        let raw = try JSONDecoder().decode([String: KeyCombo].self, from: data)
        var result: [HotkeyAction: KeyCombo] = [:]
        for (key, combo) in raw {
            if let action = HotkeyAction(rawValue: key) { result[action] = combo }
        }
        return result
    }

    private static func loadBindings(from defaults: UserDefaults) -> [HotkeyAction: KeyCombo] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [:] }
        return (try? decode(data)) ?? [:]
    }

    private func save() {
        if bindings.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else if let data = try? Self.encode(bindings) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    // MARK: - Carbon

    private func installEventHandler() {
        guard eventHandlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), inkwellHotKeyHandler, 1, &spec, nil, &eventHandlerRef)
    }

    private func registerAll() {
        unregisterAll()
        guard started, suspendCount == 0 else { return }
        var errors: [HotkeyAction: OSStatus] = [:]
        for action in HotkeyAction.allCases {
            guard let combo = bindings[action] else { continue }
            if let status = register(combo, id: action.hotkeyID, ref: &hotKeyRefs[action]), status != noErr {
                errors[action] = status
            }
        }
        if errors != registrationErrors { registrationErrors = errors }
    }

    /// Registers a combo; returns the OSStatus (noErr on success).
    @discardableResult
    func register(_ combo: KeyCombo, id: UInt32, ref: inout EventHotKeyRef?) -> OSStatus? {
        let hotKeyID = EventHotKeyID(signature: inkwellHotKeySignature, id: id)
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &newRef)
        ref = status == noErr ? newRef : nil
        return status
    }

    private func unregisterAll() {
        for ref in hotKeyRefs.values { UnregisterEventHotKey(ref) }
        hotKeyRefs.removeAll()
    }

    fileprivate func handle(hotkeyID: UInt32) {
        guard suspendCount == 0, let action = HotkeyAction(hotkeyID: hotkeyID) else { return }
        handler?(action)
    }

    // MARK: - System shortcut detection

    /// True if macOS itself uses this combo (Spotlight, Mission Control, screenshots…).
    static func isSystemShortcut(_ combo: KeyCombo) -> Bool {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr, let array = unmanaged?.takeRetainedValue() as? [[String: Any]] else {
            return false
        }
        for entry in array {
            guard (entry[kHISymbolicHotKeyEnabled as String] as? Bool) ?? false,
                  let code = (entry[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint32Value,
                  let mods = (entry[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value else { continue }
            if code == combo.keyCode && (mods & KeyCombo.supportedModifiers) == combo.modifiers { return true }
        }
        return false
    }

    static func describe(_ status: OSStatus) -> String {
        if status == OSStatus(eventHotKeyExistsErr) {
            return "Another app is already using this shortcut."
        }
        if status == OSStatus(eventHotKeyInvalidErr) {
            return "macOS doesn't allow this shortcut."
        }
        return "Couldn't register this shortcut (error \(status))."
    }
}

let inkwellHotKeySignature: OSType = {
    "INKW".utf8.reduce(0) { ($0 << 8) | OSType($1) }
}()

private let inkwellHotKeyHandler: EventHandlerUPP = { _, event, _ in
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr, hotKeyID.signature == inkwellHotKeySignature else { return OSStatus(eventNotHandledErr) }
    let id = hotKeyID.id
    Task { @MainActor in HotkeyManager.shared.handle(hotkeyID: id) }
    return noErr
}
