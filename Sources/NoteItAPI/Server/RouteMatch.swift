import Foundation

/// A route the router matched, with its path parameters. Shape owned by the automation plan; built in foundations
/// Task 5.2.
public struct RouteMatch: Sendable {
    public let spec: RouteSpec
    public let params: [String: String]

    public init(spec: RouteSpec, params: [String: String]) {
        self.spec = spec
        self.params = params
    }
}
