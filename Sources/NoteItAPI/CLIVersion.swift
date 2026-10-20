import Foundation

/// The CLI's version. `AppIdentity` has no version; it only exists in the app's `Info.plist`, which
/// `scripts/build_app.sh` writes, and the CLI ships at `<App>.app/Contents/Helpers/noteit`. Owned by the automation
/// plan; built in foundations Task 5.1.
public enum CLIVersion {
    public static let unbundled = "dev"

    /// Resolves symlinks in `executableURL`. When it is `<X>.app/Contents/Helpers/<name>`, returns
    /// `CFBundleShortVersionString` from `<X>.app/Contents/Info.plist`; otherwise, or when the file or key is
    /// missing, returns `unbundled` (swift run, tests).
    public static func current(executableURL: URL? = Bundle.main.executableURL) -> String {
        guard let executableURL else { return unbundled }
        let resolved = executableURL.resolvingSymlinksInPath()
        let helpers = resolved.deletingLastPathComponent()
        let contents = helpers.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard helpers.lastPathComponent == "Helpers",
              contents.lastPathComponent == "Contents",
              app.pathExtension == "app",
              let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = plist["CFBundleShortVersionString"] as? String,
              !version.isEmpty
        else { return unbundled }
        return version
    }
}
