import AppKit
import XCTest
@testable import NoteIt

/// A dismissal animation that completes after Quick Capture was shown again must not hide it.
@MainActor
final class QuickCaptureDismissalTests: XCTestCase {
    private var panel: NSPanel!

    override func setUp() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: [.borderless],
                        backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
    }

    override func tearDown() {
        panel.orderOut(nil)
        panel = nil
        QuickCaptureVisibility.shared.isCapturing = false
    }

    func testStaleDismissalKeepsReopenedPanel() {
        let controller = QuickCaptureController()
        controller.beginPresentation()
        panel.orderFront(nil)
        let dismissing = controller.presentationGeneration

        controller.beginPresentation() // reopened during the fade-out
        panel.alphaValue = 0.4
        controller.finishDismissal(panel, generation: dismissing)

        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(panel.alphaValue, 0.4, accuracy: 0.001)
        XCTAssertTrue(QuickCaptureVisibility.shared.isCapturing)
    }

    func testCurrentDismissalHidesPanelAndClearsCapturing() {
        let controller = QuickCaptureController()
        controller.beginPresentation()
        panel.orderFront(nil)
        panel.alphaValue = 0

        controller.finishDismissal(panel, generation: controller.presentationGeneration)

        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(panel.alphaValue, 1, accuracy: 0.001)
        XCTAssertFalse(QuickCaptureVisibility.shared.isCapturing)
    }
}
