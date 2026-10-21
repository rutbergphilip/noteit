import Foundation
import NoteItSync

/// Links the `noteit` tool bundled at `Contents/Helpers/noteit` into `/usr/local/bin`, and its shell completion files
/// into the folders zsh, bash and fish read, asking for an administrator password once, and only when a folder isn't
/// writable.
struct CLIInstaller: Sendable {
    enum State: Equatable {
        case notInstalled
        case installed
        /// The tool is linked, but a completion file this copy ships isn't.
        case completionsMissing
        /// The link points into another copy of NoteIt, possibly one that has since been deleted.
        case otherCopy(String)
        /// Something NoteIt didn't make is at the link path: a link to another tool, or a regular file.
        case pointsElsewhere(String)
    }

    /// A completion script in the app and where a shell looks for it.
    struct Completion: Sendable, Equatable {
        var fileURL: URL
        var linkURL: URL
    }

    static let defaultLinkPath = "/usr/local/bin/noteit"
    static let cancelledCode = -128
    static let toolPathInBundle = ["Contents", "Helpers", "noteit"]
    static let completionsPathInBundle = ["Contents", "Resources", "completions"]
    /// File names in `Contents/Resources/completions` (written by scripts/build_app.sh) and their link paths.
    static let completionLinks = [
        ("_noteit", "/usr/local/share/zsh/site-functions/_noteit"),
        ("noteit.bash", "/usr/local/etc/bash_completion.d/noteit"),
        ("noteit.fish", "/usr/local/share/fish/vendor_completions.d/noteit.fish"),
    ]

    var linkURL: URL
    var toolURL: URL?
    var runPrivileged: @Sendable (String) throws -> Void
    /// True when the app runs from somewhere a link shouldn't point to, like a translocated or disk image copy.
    var appNeedsMoving: @Sendable () -> Bool = { false }
    var completions: [Completion] = []

    static func live() -> CLIInstaller {
        CLIInstaller(linkURL: URL(fileURLWithPath: defaultLinkPath), toolURL: bundledTool(in: Bundle.main),
                     runPrivileged: { try runWithAdministratorPrivileges($0) },
                     appNeedsMoving: { needsMoving(Bundle.main.bundleURL) },
                     completions: completions(in: Bundle.main.bundleURL))
    }

    static func completions(in bundleURL: URL) -> [Completion] {
        let folder = completionsPathInBundle.reduce(bundleURL) { $0.appendingPathComponent($1) }
        return completionLinks.map { Completion(fileURL: folder.appendingPathComponent($0.0), linkURL: URL(fileURLWithPath: $0.1)) }
    }

    /// Completion files this copy ships.
    var bundledCompletions: [Completion] {
        completions.filter { FileManager.default.fileExists(atPath: $0.fileURL.path) }
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
        if let toolURL, target.standardizedFileURL.path == toolURL.standardizedFileURL.path {
            return completionsToLink().isEmpty ? .installed : .completionsMissing
        }
        return isNoteItTool(target) ? .otherCopy(target.path) : .pointsElsewhere(target.path)
    }

    /// Bundled completions whose link is missing or points into another copy of NoteIt. Anything else already at a
    /// link path belongs to someone else and is left alone.
    func completionsToLink() -> [Completion] {
        bundledCompletions.filter { completion in
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: completion.linkURL.path) else {
                return !FileManager.default.fileExists(atPath: completion.linkURL.path)
            }
            let target = Self.resolve(destination, link: completion.linkURL)
            return target.standardizedFileURL.path != completion.fileURL.standardizedFileURL.path && Self.isNoteItCompletion(target)
        }
    }

    /// Completion links that point into this or another copy of NoteIt.
    func linkedCompletions() -> [Completion] {
        completions.filter { completion in
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: completion.linkURL.path) else {
                return false
            }
            let target = Self.resolve(destination, link: completion.linkURL)
            return target.standardizedFileURL.path == completion.fileURL.standardizedFileURL.path || Self.isNoteItCompletion(target)
        }
    }

    static func isNoteItCompletion(_ url: URL) -> Bool {
        let components = url.standardizedFileURL.pathComponents
        guard let name = components.last, completionLinks.contains(where: { $0.0 == name }) else { return false }
        return pointsIntoNoteItApp(url, pathInBundle: completionsPathInBundle + [name])
    }

    func install() throws {
        guard let toolURL else { throw CLIInstallerError.notBundled }
        if appNeedsMoving() { throw CLIInstallerError.needsMove }
        let fileManager = FileManager.default
        let destination = try? fileManager.destinationOfSymbolicLink(atPath: linkURL.path)
        let isLink = destination != nil
        if !isLink, fileManager.fileExists(atPath: linkURL.path) { throw CLIInstallerError.occupied(linkURL.path) }
        if let destination, !isNoteItTool(resolve(destination)) { throw CLIInstallerError.foreignLink(linkURL.path) }
        let links = [(target: toolURL.path, link: linkURL.path)]
            + completionsToLink().map { (target: $0.fileURL.path, link: $0.linkURL.path) }
        for (index, entry) in links.enumerated() {
            do {
                let link = URL(fileURLWithPath: entry.link)
                try fileManager.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
                if (try? fileManager.destinationOfSymbolicLink(atPath: link.path)) != nil { try fileManager.removeItem(at: link) }
                try fileManager.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: entry.target))
            } catch where Self.isPermissionError(error) {
                try runPrivileged(Self.installCommand(links: Array(links[index...])))
                return
            }
        }
    }

    /// Removes the tool's link and the completion links into any copy of NoteIt.
    func uninstall() throws {
        var links: [URL] = []
        if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path) {
            guard isNoteItTool(resolve(destination)) else { throw CLIInstallerError.foreignLink(linkURL.path) }
            links.append(linkURL)
        }
        links += linkedCompletions().map(\.linkURL)
        for (index, link) in links.enumerated() {
            do {
                try FileManager.default.removeItem(at: link)
            } catch where Self.isPermissionError(error) {
                try runPrivileged("rm -f " + links[index...].map { Self.quoted($0.path) }.joined(separator: " "))
                return
            }
        }
    }

    static func installCommand(tool: String, link: String) -> String {
        installCommand(links: [(tool, link)])
    }

    /// One shell command for every link, so the password is asked for once.
    static func installCommand(links: [(target: String, link: String)]) -> String {
        links.map { target, link in
            let folder = (link as NSString).deletingLastPathComponent
            return "mkdir -p \(quoted(folder)) && ln -sfh \(quoted(target)) \(quoted(link))"
        }.joined(separator: " && ")
    }

    /// Single-quotes `text` for `/bin/sh`, so `'` becomes `'\''`.
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    func isNoteItTool(_ url: URL) -> Bool {
        if let toolURL, url.standardizedFileURL.path == toolURL.standardizedFileURL.path { return true }
        return Self.pointsIntoNoteItApp(url)
    }

    /// True for `*.app/<pathInBundle>` inside a NoteIt bundle, or inside any `.app` that no longer has an
    /// `Info.plist`, so links left by a deleted copy can still be fixed or removed.
    static func pointsIntoNoteItApp(_ url: URL, pathInBundle: [String] = toolPathInBundle) -> Bool {
        let components = url.standardizedFileURL.pathComponents
        guard components.count >= pathInBundle.count + 2, Array(components.suffix(pathInBundle.count)) == pathInBundle,
              components[components.count - pathInBundle.count - 1].hasSuffix(".app") else { return false }
        let bundle = pathInBundle.reduce(url.standardizedFileURL) { url, _ in url.deletingLastPathComponent() }
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
        Self.resolve(destination, link: linkURL)
    }

    private static func resolve(_ destination: String, link: URL) -> URL {
        destination.hasPrefix("/") ? URL(fileURLWithPath: destination)
            : link.deletingLastPathComponent().appendingPathComponent(destination)
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
