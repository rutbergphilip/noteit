import Foundation

/// Reads `NOTEIT_<name>` from the environment, falling back to the legacy `INKWELL_<name>`.
public enum AppEnvironment {
    public static let prefix = "NOTEIT_"

    public static func value(_ name: String,
                             in environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        environment[prefix + name] ?? environment[AppIdentity.Legacy.environmentPrefix + name]
    }

    /// `value(name)` unless it is missing or empty.
    public static func nonEmpty(_ name: String,
                                in environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard let value = value(name, in: environment), !value.isEmpty else { return nil }
        return value
    }
}
