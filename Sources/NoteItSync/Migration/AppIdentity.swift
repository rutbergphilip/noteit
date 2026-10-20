import Foundation

/// Product identity. `bundleID` is the single source of truth; `scripts/build_app.sh` reads it from here.
public enum AppIdentity {
    public static let name = "NoteIt"
    public static let bundleID = "io.github.rutbergphilip.noteit"
    /// Application Support folder name.
    public static let dataFolderName = "NoteIt"
    public static let keychainService = bundleID + ".sync"
    /// The `noteit://` URL scheme. Added for the automation plan in foundations Task 5.1.
    public static let urlScheme = "noteit"
    /// Keychain service holding the Local API's client records (automation).
    public static let localAPIKeychainService = bundleID + ".local-api"
    /// Keychain service holding the `noteit` command's token (automation).
    public static let cliKeychainService = bundleID + ".cli"

    /// Identifiers of the app's former name, Inkwell. Read only to migrate existing users.
    public enum Legacy {
        public static let bundleID = "com.inkwell.app"
        public static let dataFolderName = "Inkwell"
        public static let keychainService = "com.inkwell.app.sync"
        public static let environmentPrefix = "INKWELL_"
    }
}
