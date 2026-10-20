import Foundation
import NoteItCore

/// `noteit://<host>` hosts that other sub-projects add. Automation's `URLSchemeHandler` looks up
/// `URLCommand.registered(host:url:)` here. Shape owned by the automation plan; built in foundations Task 5.4.
@MainActor final class URLRouteRegistry {
    static let shared = URLRouteRegistry()

    /// Gets the whole URL, fragment included.
    typealias Handler = @MainActor (URL) -> Void

    private var handlers: [String: Handler] = [:]

    /// Tests use their own instance.
    init() {}

    /// Traps on a reserved host, a host already registered, or a host with characters outside `[a-z0-9-]`.
    func register(host: String, handler: @escaping Handler) {
        if let problem = problem(with: host) {
            preconditionFailure("URL host \(host): \(problem)")
        }
        handlers[host] = handler
    }

    /// Mirrors `register`'s checks.
    func canRegister(host: String) -> Bool {
        problem(with: host) == nil
    }

    func handler(for host: String) -> Handler? {
        handlers[host]
    }

    /// Sorted.
    var hosts: [String] {
        handlers.keys.sorted()
    }

    private func problem(with host: String) -> String? {
        if URLCommand.reservedHosts.contains(host.lowercased()) { return "reserved" }
        if host.isEmpty || host.range(of: "^[a-z0-9-]+$", options: .regularExpression) == nil {
            return "only a-z, 0-9 and - are allowed"
        }
        if handlers[host] != nil { return "already registered" }
        return nil
    }
}
