import Foundation

public typealias LocalAPIHandler = @Sendable (LocalAPIContext) async -> HTTPResponse

/// `APIErrorCode` is an `Error`, so it can be `Result`'s failure type.
public typealias SearchModeHandler = @Sendable (_ query: SearchQuery, _ context: LocalAPIContext) async
    -> Result<[SearchResultDTO], APIErrorCode>

public struct SearchQuery: Sendable {
    public var q: String
    public var notebook: String?
    public var tag: String?
    public var limit: Int

    public init(q: String, notebook: String? = nil, tag: String? = nil, limit: Int) {
        self.q = q
        self.notebook = notebook
        self.tag = tag
        self.limit = limit
    }
}

/// Routes, search modes and capabilities that other sub-projects add to the Local API. The server routes over
/// `APIRoutes.all` plus `routes`. Shape owned by the automation plan; built in foundations Task 5.2.
public final class LocalAPIRouteRegistry: @unchecked Sendable {
    public static let shared = LocalAPIRouteRegistry()

    private let lock = NSLock()
    private let trapsOnProblems: Bool
    private var registeredRoutes: [(spec: RouteSpec, handler: LocalAPIHandler)] = []
    private var registeredSearchModes: [(name: String, handler: SearchModeHandler)] = []
    private var capabilitySet: Set<String> = []

    /// Tests use their own instance.
    public convenience init() {
        self.init(trapsOnProblems: true)
    }

    /// With `trapsOnProblems` false, bad registrations are kept so `validate()` can report them (tests only).
    init(trapsOnProblems: Bool) {
        self.trapsOnProblems = trapsOnProblems
    }

    /// Traps on a method and path that `APIRoutes.all` or an earlier route already has, a duplicate id, an id that
    /// isn't `<slug>.<name>`, or a nil scope.
    public func register(_ spec: RouteSpec, handler: @escaping LocalAPIHandler) {
        locked {
            let problems = Self.routeProblems(spec, before: registeredRoutes.map(\.spec))
            check(problems)
            registeredRoutes.append((spec, handler))
        }
    }

    /// Traps on `keyword` (built in), a name already taken, or a name that isn't kebab-case.
    public func registerSearchMode(_ name: String, handler: @escaping SearchModeHandler) {
        locked {
            check(Self.searchModeProblems(name, before: registeredSearchModes.map(\.name)))
            registeredSearchModes.append((name, handler))
        }
    }

    /// Traps on a name that isn't kebab-case; adding a name twice keeps one.
    public func addCapability(_ name: String) {
        locked {
            check(Self.capabilityProblems(name))
            capabilitySet.insert(name)
        }
    }

    /// Removing a name that isn't there does nothing.
    public func removeCapability(_ name: String) {
        _ = locked { capabilitySet.remove(name) }
    }

    public var routes: [RouteSpec] { locked { registeredRoutes.map(\.spec) } }

    /// Sorted.
    public var searchModes: [String] { locked { registeredSearchModes.map(\.name).sorted() } }

    /// Sorted; the current set, which `GET /v1/ping` lists.
    public var capabilities: [String] { locked { capabilitySet.sorted() } }

    public func handler(for id: String) -> LocalAPIHandler? {
        locked { registeredRoutes.first { $0.spec.id == id }?.handler }
    }

    public func searchMode(_ name: String) -> SearchModeHandler? {
        locked { registeredSearchModes.first { $0.name == name }?.handler }
    }

    /// The trap conditions as messages, one per problem, for tests.
    public func validate() -> [String] {
        locked {
            var problems: [String] = []
            for (index, entry) in registeredRoutes.enumerated() {
                problems += Self.routeProblems(entry.spec, before: registeredRoutes[..<index].map(\.spec))
            }
            for (index, entry) in registeredSearchModes.enumerated() {
                problems += Self.searchModeProblems(entry.name, before: registeredSearchModes[..<index].map(\.name))
            }
            for name in capabilitySet.sorted() {
                problems += Self.capabilityProblems(name)
            }
            return problems
        }
    }

    // MARK: - Checks

    static func routeProblems(_ spec: RouteSpec, before earlier: [RouteSpec]) -> [String] {
        var problems: [String] = []
        let key = routeKey(spec)
        if let builtIn = APIRoutes.all.first(where: { routeKey($0) == key }) {
            problems.append("Route \(spec.id): \(key) conflicts with built-in route \(builtIn.id)")
        }
        if let other = earlier.first(where: { routeKey($0) == key }) {
            problems.append("Route \(spec.id): \(key) conflicts with registered route \(other.id)")
        }
        if earlier.contains(where: { $0.id == spec.id }) || APIRoutes.all.contains(where: { $0.id == spec.id }) {
            problems.append("Route \(spec.id): duplicate id")
        }
        if !matches(spec.id, routeIDPattern) {
            problems.append("Route \(spec.id): id isn't \"<slug>.<name>\"")
        }
        if spec.scope == nil {
            problems.append("Route \(spec.id): registered routes need a scope")
        }
        return problems
    }

    static func searchModeProblems(_ name: String, before earlier: [String]) -> [String] {
        var problems: [String] = []
        if name == "keyword" {
            problems.append("Search mode keyword is built in")
        }
        if earlier.contains(name) {
            problems.append("Search mode \(name): already registered")
        }
        if !matches(name, kebabCase) {
            problems.append("Search mode \(name): not kebab-case")
        }
        return problems
    }

    static func capabilityProblems(_ name: String) -> [String] {
        matches(name, kebabCase) ? [] : ["Capability \(name): not kebab-case"]
    }

    private static let kebabCase = "^[a-z0-9]+(-[a-z0-9]+)*$"
    private static let routeIDPattern = "^[a-z0-9]+(-[a-z0-9]+)*\\.[A-Za-z0-9]+([-_][A-Za-z0-9]+)*$"

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    /// Method and path with parameter names dropped, so `/v1/notes/{id}` and `/v1/notes/{x}` conflict.
    private static func routeKey(_ spec: RouteSpec) -> String {
        let path = spec.pattern.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.hasPrefix("{") && $0.hasSuffix("}") ? "{}" : String($0) }
            .joined(separator: "/")
        return "\(spec.method.rawValue) \(path)"
    }

    private func check(_ problems: [String]) {
        guard trapsOnProblems, !problems.isEmpty else { return }
        preconditionFailure(problems.joined(separator: "; "))
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
