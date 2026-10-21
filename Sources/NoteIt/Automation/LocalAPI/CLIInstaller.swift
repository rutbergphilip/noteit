import Foundation
import NoteItSync

/// Links the `noteit` tool bundled at `Contents/Helpers/noteit` into `/usr/local/bin`, asking for an administrator
/// password only when the folder isn't writable.
struct CLIInstaller: Sendable {
    enum State: Equatable {
        case notInstalled
        case installed
        /// The link points into another copy of NoteIt, possibly one that has since been deleted.
        case otherCopy(String)
        /// Something NoteIt didn't make is at the link path: a link to another tool, or a regular file.
        case pointsElsewhere(String)
    }

    static let defaultLinkPath = "/usr/local/bin/noteit"
    static let cancelledCode = -128

    var linkURL: URL
    var toolURL: URL?
    var runPrivileged: @Sendable (String) throws -> Void
    /// True when the app runs from somewhere a link shouldn't point to, like a translocated or disk image copy.
    var appNeedsMoving: @Sendable () -> Bool = { false }

    static func live() -> CLIInstaller {
        CLIInstaller(linkURL: URL(fileURLWithPath: defaultLinkPath), toolURL: bundledTool(in: Bundle.main),
                     runPrivileged: { try runWithAdministratorPrivileges($0) },
                     appNeedsMoving: { needsMoving(Bundle.main.bundleURL) })
    }

    static func bundledTool(in bundle: Bundle) -> URL? {
        let url = bundle.bundleURL.appendingPathComponent("Contents/Helpers/noteit")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    func state() -> State {
        let fileManager = FileManager.default
        guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: linkURL.path) else {
            return fileManager.fileExists(atPath: linkURL.path) ? .pointsElsewhere(linkURL.path) : .notInstalled
        }
        let target = resolve(destination)
        if let toolURL, target.standardizedFileURL.path == toolURL.standardizedFileURL.path { return .installed }
        return isNoteItTool(target) ? .otherCopy(target.path) : .pointsElsewhere(target.path)
    }

    func install() throws {
        guard let toolURL else { throw CLIInstallerError.notBundled }
        if appNeedsMoving() { throw CLIInstallerError.needsMove }
        let fileManager = FileManager.default
        let destination = try? fileManager.destinationOfSymbolicLink(atPath: linkURL.path)
        let isLink = destination != nil
        if !isLink, fileManager.fileExists(atPath: linkURL.path) { throw CLIInstallerError.occupied(linkURL.path) }
        if let destination, !isNoteItTool(resolve(destination)) { throw CLIInstallerError.foreignLink(linkURL.path) }
        do {
            try fileManager.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if isLink { try fileManager.removeItem(at: linkURL) }
            try fileManager.createSymbolicLink(at: linkURL, withDestinationURL: toolURL)
        } catch where Self.isPermissionError(error) {
            try runPrivileged(Self.installCommand(tool: toolURL.path, link: linkURL.path))
        }
    }

    func uninstall() throws {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path) else { return }
        guard isNoteItTool(resolve(destination)) else { throw CLIInstallerError.foreignLink(linkURL.path) }
        do {
            try FileManager.default.removeItem(at: linkURL)
        } catch where Self.isPermissionError(error) {
            try runPrivileged("rm -f \(Self.quoted(linkURL.path))")
        }
    }

    static func installCommand(tool: String, link: String) -> String {
        let folder = (link as NSString).deletingLastPathComponent
        return "mkdir -p \(quoted(folder)) && ln -sfh \(quoted(tool)) \(quoted(link))"
    }

    /// Single-quotes `text` for `/bin/sh`, so `'` becomes `'\''`.
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    func isNoteItTool(_ url: URL) -> Bool {
        if let toolURL, url.standardizedFileURL.path == toolURL.standardizedFileURL.path { return true }
        return Self.pointsIntoNoteItApp(url)
    }

    /// True for `*.app/Contents/Helpers/noteit` inside a NoteIt bundle, or inside any `.app` that no longer has an
    /// `Info.plist`, so links left by a deleted copy can still be fixed or removed.
    static func pointsIntoNoteItApp(_ url: URL) -> Bool {
        let components = url.standardizedFileURL.pathComponents
        guard components.count >= 5, components.suffix(3) == ["Contents", "Helpers", "noteit"],
              components[components.count - 4].hasSuffix(".app") else { return false }
        let bundle = url.standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let plistURL = bundle.appendingPathComponent("Contents/Info.plist")
        guard FileManager.default.fileExists(atPath: plistURL.path) else { return true }
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return false }
        return plist["CFBundleIdentifier"] as? String == AppIdentity.bundleID
    }

    /// True when `bundleURL` is translocated, or on a read-only, ejectable or removable volume.
    static func needsMoving(_ bundleURL: URL) -> Bool {
        if isTranslocated(bundleURL) { return true }
        let keys: Set<URLResourceKey> = [.volumeIsReadOnlyKey, .volumeIsEjectableKey, .volumeIsRemovableKey]
        guard let values = try? bundleURL.resourceValues(forKeys: keys) else { return false }
        return values.volumeIsReadOnly == true || values.volumeIsEjectable == true || values.volumeIsRemovable == true
    }

    static func isTranslocated(_ url: URL) -> Bool {
        typealias IsTranslocated = @convention(c) (CFURL, UnsafeMutablePointer<Bool>, UnsafeMutableRawPointer?) -> UInt8
        if let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY) {
            defer { dlclose(handle) }
            if let symbol = dlsym(handle, "SecTranslocateIsTranslocatedURL") {
                var translocated = false
                let check = unsafeBitCast(symbol, to: IsTranslocated.self)
                if check(url as CFURL, &translocated, nil) != 0, translocated { return true }
            }
        }
        return url.standardizedFileURL.path.contains("/AppTranslocation/")
    }

    static func isPermissionError(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == NSFileWriteNoPermissionError { return true }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(EACCES) || error.code == Int(EPERM) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error { return isPermissionError(underlying) }
        return false
    }

    private func resolve(_ destination: String) -> URL {
        destination.hasPrefix("/") ? URL(fileURLWithPath: destination)
            : linkURL.deletingLastPathComponent().appendingPathComponent(destination)
    }

    /// `do shell script … with administrator privileges`, which shows the system's password prompt.
    private static func runWithAdministratorPrivileges(_ command: String) throws {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        guard let script = NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges") else {
            throw CLIInstallerError.failed("The install script couldn't be created.")
        }
        var info: NSDictionary?
        script.executeAndReturnError(&info)
        guard let info else { return }
        let code = info[NSAppleScript.errorNumber] as? Int ?? 0
        if code == cancelledCode { throw CLIInstallerError.cancelled }
        throw CLIInstallerError.failed(info[NSAppleScript.errorMessage] as? String ?? "Error \(code).")
    }
}

enum CLIInstallerError: Error, Equatable, LocalizedError {
    case notBundled
    case occupied(String)
    case foreignLink(String)
    case needsMove
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notBundled: "This copy of NoteIt doesn't include the command line tool."
        case .occupied(let path): "Something else is already at \(path). Move it away and try again."
        case .foreignLink(let path): "\(path) wasn't installed by NoteIt, so it was left alone."
        case .needsMove: "Move NoteIt to your Applications folder first."
        case .cancelled: "Cancelled."
        case .failed(let message): "Couldn't install the command line tool: \(message)"
        }
    }
}
