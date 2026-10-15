import AppKit
import ApplicationServices

enum AccessibilityAccess {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt and opens Privacy & Security › Accessibility.
    static func requestAccess() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct AXFailure: Error, Equatable {
    var code: AXError
}

/// Synchronous Accessibility reads with a short messaging timeout, run off the main thread so a hung
/// app can't stall NoteIt (and so reading NoteIt's own windows doesn't deadlock).
enum AXRead {
    static let messagingTimeout: Float = 0.5

    static func perform<T>(_ body: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: body())
            }
        }
    }

    static func application(_ pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> Result<AXUIElement, AXFailure> {
        copyValue(element, attribute).flatMap { value in
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return .failure(AXFailure(code: .noValue)) }
            let child = value as! AXUIElement
            AXUIElementSetMessagingTimeout(child, messagingTimeout)
            return .success(child)
        }
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> Result<String, AXFailure> {
        copyValue(element, attribute).flatMap { value in
            guard let string = value as? String else { return .failure(AXFailure(code: .noValue)) }
            return .success(string)
        }
    }

    static func setBool(_ element: AXUIElement, _ attribute: String, _ value: Bool) -> Bool {
        AXUIElementSetAttributeValue(element, attribute as CFString, (value ? kCFBooleanTrue : kCFBooleanFalse)!)
            == .success
    }

    private static func copyValue(_ element: AXUIElement, _ attribute: String) -> Result<CFTypeRef, AXFailure> {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else { return .failure(AXFailure(code: error)) }
        guard let value else { return .failure(AXFailure(code: .noValue)) }
        return .success(value)
    }
}
