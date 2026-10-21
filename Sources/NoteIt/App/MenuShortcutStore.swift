import AppKit
import SwiftUI

/// A user's change to a menu shortcut: a different shortcut, or none at all.
enum MenuShortcutOverride: Equatable {
    case shortcut(MenuShortcut)
    case noShortcut

    static func resolve(_ override: MenuShortcutOverride?, for command: MenuShortcutCommand) -> MenuShortcut? {
        switch override {
        case .shortcut(let shortcut)?: shortcut
        case .noShortcut?: nil
        case nil: command.defaultShortcut
        }
    }
}

/// The menu shortcuts chosen in Settings › Shortcuts › In NoteIt. Only changes from the defaults are saved,
/// as JSON under `menuShortcutOverrides`.
@MainActor
final class MenuShortcutStore: ObservableObject {
    static let shared = MenuShortcutStore(defaults: .standard, table: .live)
    nonisolated static let defaultsKey = "menuShortcutOverrides"

    @Published private(set) var overrides: [MenuShortcutCommand: MenuShortcutOverride]

    private let defaults: UserDefaults
    private let table: MenuShortcutTable?

    convenience init(defaults: UserDefaults) {
        self.init(defaults: defaults, table: nil)
    }

    private init(defaults: UserDefaults, table: MenuShortcutTable?) {
        self.defaults = defaults
        self.table = table
        overrides = Self.loadOverrides(from: defaults)
        table?.update(overrides)
    }

    func current(_ command: MenuShortcutCommand) -> MenuShortcut? {
        MenuShortcutOverride.resolve(overrides[command], for: command)
    }

    func set(_ shortcut: MenuShortcut, for command: MenuShortcutCommand) {
        overrides[command] = shortcut == command.defaultShortcut ? nil : .shortcut(shortcut)
        save()
    }

    /// Leaves the command without a shortcut.
    func clear(_ command: MenuShortcutCommand) {
        overrides[command] = command.defaultShortcut == nil ? nil : .noShortcut
        save()
    }

    /// Back to the default shortcut, unless another command has taken it in the meantime.
    func reset(_ command: MenuShortcutCommand) {
        guard resetBlocker(for: command) == nil else { return }
        overrides[command] = nil
        save()
    }

    /// The command now using `command`'s default shortcut, which stops it from being restored.
    func resetBlocker(for command: MenuShortcutCommand) -> MenuShortcutCommand? {
        guard isCustomized(command), let shortcut = command.defaultShortcut else { return nil }
        return self.command(using: shortcut, excluding: command)
    }

    func resetAll() {
        overrides = [:]
        save()
    }

    func isCustomized(_ command: MenuShortcutCommand) -> Bool { overrides[command] != nil }

    var hasCustomizations: Bool { !overrides.isEmpty }

    func command(using shortcut: MenuShortcut, excluding excluded: MenuShortcutCommand? = nil) -> MenuShortcutCommand? {
        for command in MenuShortcutCommand.allCases where command != excluded {
            if current(command) == shortcut { return command }
        }
        return nil
    }

    private func save() {
        if let table {
            table.update(overrides)
            DispatchQueue.main.async { Self.refreshMainMenu() }
        }
        if overrides.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else if let data = MenuShortcutCoding.encode(overrides) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    /// SwiftUI only rebuilds menu items when a menu is about to open, and key presses go through the stale
    /// items until then, so the main menu is asked to update right away.
    nonisolated private static func refreshMainMenu() {
        MainActor.assumeIsolated {
            guard let menu = NSApp?.mainMenu else { return }
            refresh(menu)
        }
    }

    private static func refresh(_ menu: NSMenu) {
        menu.delegate?.menuNeedsUpdate?(menu)
        for item in menu.items {
            if let submenu = item.submenu { refresh(submenu) }
        }
    }

    nonisolated static func loadOverrides(from defaults: UserDefaults) -> [MenuShortcutCommand: MenuShortcutOverride] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [:] }
        return MenuShortcutCoding.decode(data)
    }
}

/// The JSON stored under `menuShortcutOverrides`, e.g. `{"find":{"key":"j","modifiers":["command"]},"print":{"none":true}}`.
enum MenuShortcutCoding {
    private struct StoredEntry: Codable {
        var key: String?
        var modifiers: [String]?
        var none: Bool?
    }

    /// Decodes one entry without failing the whole dictionary.
    private struct LenientEntry: Decodable {
        let entry: StoredEntry?

        init(from decoder: Decoder) throws {
            entry = try? StoredEntry(from: decoder)
        }
    }

    private static let modifierNames: [(String, EventModifiers)] = [
        ("control", .control), ("option", .option), ("shift", .shift), ("command", .command),
    ]

    static func encode(_ overrides: [MenuShortcutCommand: MenuShortcutOverride]) -> Data? {
        var stored: [String: StoredEntry] = [:]
        for (command, override) in overrides {
            switch override {
            case .noShortcut:
                stored[command.rawValue] = StoredEntry(none: true)
            case .shortcut(let shortcut):
                let names = modifierNames.filter { shortcut.modifiers.contains($0.1) }.map(\.0)
                stored[command.rawValue] = StoredEntry(key: String(shortcut.key.character), modifiers: names)
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(stored)
    }

    /// Unknown commands, unknown modifiers and shortcuts that wouldn't be accepted when recording are dropped.
    static func decode(_ data: Data) -> [MenuShortcutCommand: MenuShortcutOverride] {
        guard let stored = try? JSONDecoder().decode([String: LenientEntry].self, from: data) else { return [:] }
        var result: [MenuShortcutCommand: MenuShortcutOverride] = [:]
        for (id, lenient) in stored {
            guard let command = MenuShortcutCommand(rawValue: id), let entry = lenient.entry,
                  let override = override(from: entry) else { continue }
            if case .shortcut(let shortcut) = override, shortcut == command.defaultShortcut { continue }
            result[command] = override
        }
        return result
    }

    private static func override(from entry: StoredEntry) -> MenuShortcutOverride? {
        if entry.none == true, entry.key == nil { return .noShortcut }
        guard entry.none != true, let key = entry.key, key.count == 1, let character = key.first,
              let names = entry.modifiers else { return nil }
        var modifiers: EventModifiers = []
        for name in names {
            guard let match = modifierNames.first(where: { $0.0 == name }) else { return nil }
            modifiers.insert(match.1)
        }
        let shortcut = MenuShortcut(KeyEquivalent(character), modifiers)
        return shortcut.isValid ? .shortcut(shortcut) : nil
    }
}
