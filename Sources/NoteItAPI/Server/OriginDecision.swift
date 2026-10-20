import Foundation

/// How a request's `Origin` was judged: a native client (no origin), a paired browser extension, or refused.
/// Shape owned by the automation plan; built in foundations Task 5.2.
public enum OriginDecision: Equatable, Sendable {
    case native
    case extensionOrigin(String)
    case rejected
}
