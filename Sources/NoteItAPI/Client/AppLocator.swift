import Foundation
import NoteItSync

public enum LocatorResult: Sendable, Equatable {
    case ready(URL)
    case apiDisabled
    case notRunning
}

/// Finds the Local API: `NOTEIT_API_URL`, then the discovery file, then (optionally) launches NoteIt in the
/// background and waits for it.
public struct AppLocator: Sendable {
    public static let pollInterval: Duration = .milliseconds(200)

    public var environment: [String: String]
    public var readDiscovery: @Sendable () -> DiscoveryFile?
    public var launchApp: @Sendable () throws -> Void
    public var ping: @Sendable (URL) async -> Bool
    public var sleep: @Sendable (Duration) async -> Void

    public init(environment: [String: String], readDiscovery: @escaping @Sendable () -> DiscoveryFile?,
                launchApp: @escaping @Sendable () throws -> Void, ping: @escaping @Sendable (URL) async -> Bool,
                sleep: @escaping @Sendable (Duration) async -> Void) {
        self.environment = environment
        self.readDiscovery = readDiscovery
        self.launchApp = launchApp
        self.ping = ping
        self.sleep = sleep
    }

    public static func live() -> AppLocator {
        let environment = ProcessInfo.processInfo.environment
        return AppLocator(
            environment: environment,
            readDiscovery: { DiscoveryFile.read(from: DiscoveryFile.directory(environment: environment)) },
            launchApp: {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                process.arguments = ["-g", "-b", AppIdentity.bundleID]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
            },
            ping: { baseURL in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 2
                let session = URLSession(configuration: configuration)
                defer { session.finishTasksAndInvalidate() }
                let client = NoteItAPIClient(baseURL: baseURL, token: nil, session: session)
                return (try? await client.send(.GET, "/ping", as: PingDTO.self)) != nil
            },
            sleep: { duration in try? await Task.sleep(for: duration) }
        )
    }

    public static let invalidAPIURLMessage =
        "NOTEIT_API_URL must be an http address on this Mac (127.0.0.1, localhost or [::1]), such as http://127.0.0.1:47600."

    /// `NOTEIT_API_URL` may be given with or without the trailing `/v1`. Only loopback hosts are accepted, because
    /// the token is sent to it.
    public static func apiURL(from text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              NoteItAPIClient.isLoopback(url)
        else { return nil }
        return url.path.hasSuffix(APIRoutes.basePath) ? url : URL(string: trimmed + APIRoutes.basePath)
    }

    /// The value of `NOTEIT_API_URL` when it is set but not usable.
    public static func invalidAPIURL(in environment: [String: String]) -> String? {
        guard let override = AppEnvironment.nonEmpty("API_URL", in: environment), apiURL(from: override) == nil else { return nil }
        return override
    }

    /// An unusable `NOTEIT_API_URL` gives `.notRunning` rather than falling back to another copy of NoteIt.
    public func locate(launch: Bool, timeout: Duration = .seconds(10)) async -> LocatorResult {
        if let override = AppEnvironment.nonEmpty("API_URL", in: environment) {
            return Self.apiURL(from: override).map(LocatorResult.ready) ?? .notRunning
        }
        if let file = readDiscovery() {
            if !file.apiEnabled { return .apiDisabled }
            if let baseURL = file.loopbackBaseURL, await ping(baseURL) { return .ready(baseURL) }
        }
        guard launch else { return .notRunning }
        do {
            try launchApp()
        } catch {
            return .notRunning
        }
        // A starting app writes `apiEnabled: false` until its server has bound, so that only counts at the end.
        var waited: Duration = .zero
        var sawDisabled = false
        while waited < timeout {
            await sleep(Self.pollInterval)
            waited += Self.pollInterval
            guard let file = readDiscovery() else { continue }
            sawDisabled = !file.apiEnabled
            if file.apiEnabled, let baseURL = file.loopbackBaseURL, await ping(baseURL) { return .ready(baseURL) }
        }
        return sawDisabled ? .apiDisabled : .notRunning
    }
}
