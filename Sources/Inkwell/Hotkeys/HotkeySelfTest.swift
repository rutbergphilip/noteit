#if DEBUG
import AppKit
import Carbon.HIToolbox

/// `Inkwell --self-test`: checks KeyCombo encoding, display strings and Carbon registration, then exits.
/// Never touches the persisted bindings in UserDefaults.
@MainActor
enum HotkeySelfTest {
    static func run() -> Int32 {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
            if !ok { failures += 1 }
        }

        let ctrlCmd = UInt32(controlKey | cmdKey)
        let cases: [(KeyCombo, String)] = [
            (KeyCombo(keyCode: kVK_ANSI_E, modifiers: controlKey | cmdKey), "⌃⌘E"),
            (KeyCombo(keyCode: kVK_ANSI_L, modifiers: shiftKey | cmdKey), "⇧⌘L"),
            (KeyCombo(keyCode: kVK_Space, modifiers: optionKey), "⌥Space"),
            (KeyCombo(keyCode: kVK_F5, modifiers: 0), "F5"),
            (KeyCombo(keyCode: kVK_F19, modifiers: controlKey | optionKey | shiftKey | cmdKey), "⌃⌥⇧⌘F19"),
            (KeyCombo(keyCode: kVK_LeftArrow, modifiers: controlKey | optionKey), "⌃⌥←"),
            (KeyCombo(keyCode: kVK_UpArrow, modifiers: cmdKey), "⌘↑"),
            (KeyCombo(keyCode: kVK_Return, modifiers: cmdKey), "⌘↩"),
            (KeyCombo(keyCode: kVK_ANSI_1, modifiers: controlKey), "⌃1"),
        ]
        for (combo, expected) in cases {
            check("displayString \(expected)", combo.displayString == expected, "got \"\(combo.displayString)\"")
        }

        check("valid: ⌃⌘E", cases[0].0.isValidGlobalHotkey)
        check("valid: bare F5", cases[3].0.isValidGlobalHotkey)
        check("invalid: bare A", !KeyCombo(keyCode: kVK_ANSI_A, modifiers: 0).isValidGlobalHotkey)
        check("invalid: ⇧A", !KeyCombo(keyCode: kVK_ANSI_A, modifiers: shiftKey).isValidGlobalHotkey)
        check("modifier mask strips non-modifier bits",
              KeyCombo(keyCode: UInt32(kVK_ANSI_E), modifiers: ctrlCmd | UInt32(alphaLock)).modifiers == ctrlCmd)
        check("NSEvent flags round-trip",
              KeyCombo.carbonModifiers(from: cases[4].0.modifierFlags) == cases[4].0.modifiers)

        do {
            let combo = cases[0].0
            let data = try JSONEncoder().encode(combo)
            let json = String(decoding: data, as: UTF8.self)
            let decoded = try JSONDecoder().decode(KeyCombo.self, from: data)
            check("KeyCombo JSON round-trip", decoded == combo, json)

            let bindings: [HotkeyAction: KeyCombo] = [.showMainWindow: cases[0].0, .quickCapture: cases[2].0]
            let blob = try HotkeyManager.encode(bindings)
            let back = try HotkeyManager.decode(blob)
            check("bindings JSON round-trip", back == bindings, String(decoding: blob, as: UTF8.self))
            let unknown = try HotkeyManager.decode(Data(#"{"bogus":{"keyCode":1,"modifiers":256}}"#.utf8))
            check("unknown actions ignored", unknown.isEmpty)
        } catch {
            check("JSON coding", false, "\(error)")
        }

        check("HotkeyAction ids round-trip",
              HotkeyAction.allCases.allSatisfy { HotkeyAction(hotkeyID: $0.hotkeyID) == $0 })

        let isolated = UserDefaults(suiteName: "inkwell.selftest.\(UUID().uuidString)")!
        let fresh = HotkeyManager(defaults: isolated)
        check("all actions unbound by default (fresh store)", fresh.bindings.isEmpty)
        check("all actions unbound in real defaults", HotkeyManager.shared.bindings.isEmpty,
              HotkeyManager.shared.bindings.map { "\($0.key.rawValue)=\($0.value.displayString)" }.joined(separator: ","))

        // Carbon registration of an unlikely combo, then unregister.
        let probe = KeyCombo(keyCode: kVK_F19, modifiers: controlKey | optionKey | shiftKey | cmdKey)
        var ref: EventHotKeyRef?
        let status = fresh.register(probe, id: 999, ref: &ref)
        check("Carbon RegisterEventHotKey \(probe.displayString)", status == noErr && ref != nil, "status \(status ?? -1)")
        if let ref { check("Carbon UnregisterEventHotKey", UnregisterEventHotKey(ref) == noErr) }

        print(failures == 0 ? "SELF-TEST OK (\(failures) failures)" : "SELF-TEST FAILED (\(failures) failures)")
        return failures == 0 ? 0 : 1
    }
}
#endif
