import Foundation

/// Everything a route handler gets for one request. Shape owned by the automation plan; built in foundations
/// Task 5.2.
public struct LocalAPIContext: Sendable {
    public let request: HTTPRequest
    public let route: RouteMatch
    /// nil for the unauthenticated routes.
    public let client: ClientRecord?
    public let origin: OriginDecision

    public init(request: HTTPRequest, route: RouteMatch, client: ClientRecord?, origin: OriginDecision) {
        self.request = request
        self.route = route
        self.client = client
        self.origin = origin
    }
}
