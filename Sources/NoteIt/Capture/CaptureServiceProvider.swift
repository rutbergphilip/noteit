import AppKit

/// Handles Services › Capture to NoteIt (the `NSServices` entry written by scripts/build_app.sh).
@MainActor
final class CaptureServiceProvider: NSObject {
    @objc func captureService(_ pboard: NSPasteboard, userData: String?, error: NSErrorPointer) {
        let text = pboard.string(forType: .string)
        let app = NSWorkspace.shared.frontmostApplication
        Task { await CaptureController.shared.captureServiceText(text, from: app) }
    }
}
