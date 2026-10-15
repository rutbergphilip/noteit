import AppKit
import SwiftUI

/// Never key or main, so showing or clicking it doesn't take focus from the app in front.
final class CaptureToastPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Takes the first click without NoteIt being active.
final class CaptureToastHostingView: NSHostingView<CaptureToastView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A notice's bookkeeping apart from its panel: each notice handles one click at most, and leaving the
/// screen always ends its part in the hide session, also when the panel was already ordered out.
struct CaptureToastLifecycle {
    private(set) var generation = 0
    private(set) var isPresented = false
    private(set) var acceptsEvents = false

    /// Call before ordering the panel front. A replacement notice joins the session of the one it replaces.
    @MainActor mutating func willShow(_ content: CaptureToastContent, appIsHidden: Bool,
                                      hider: TransientSurfaceHider) -> Int {
        generation += 1
        isPresented = true
        acceptsEvents = !content.isPending
        hider.surfaceWillAppear(.captureToast, appIsHidden: appIsHidden)
        return generation
    }

    /// Whether a click on the notice shown as `shown` should run. Later clicks are ignored.
    @MainActor mutating func accept(_ event: CaptureToastEvent, on content: CaptureToastContent, shown: Int,
                                    hider: TransientSurfaceHider) -> Bool {
        guard acceptsEvents, shown == generation else { return false }
        acceptsEvents = false
        if content.opensNoteIt(on: event) { hider.surfaceOpenedNoteIt() }
        return true
    }

    mutating func willDismiss() {
        acceptsEvents = false
    }

    /// Call once the notice shown as `shown` is off screen; does nothing if a newer notice replaced it.
    @MainActor mutating func didClose(_ shown: Int, hider: TransientSurfaceHider) {
        guard isPresented, shown == generation else { return }
        isPresented = false
        hider.surfaceDidClose(.captureToast)
    }
}

/// A notification-style notice in the top-right corner of the screen with the mouse.
@MainActor
final class CaptureToastController {
    static let shared = CaptureToastController(hider: .shared)
    static let displayDuration: TimeInterval = 3
    /// Notices with buttons stay longer, so there's time to read them.
    static let actionDisplayDuration: TimeInterval = 8
    /// A "Saving…" notice waits for the one replacing it; this only caps how long it can stay.
    static let pendingDisplayDuration: TimeInterval = 30
    static let lingerAfterHover: TimeInterval = 1.5
    static let hoverCheckInterval: TimeInterval = 0.25
    nonisolated static let margin: CGFloat = 12

    private let hider: TransientSurfaceHider
    private var panel: CaptureToastPanel?
    private var hosting: CaptureToastHostingView?
    private var dismissTask: Task<Void, Never>?
    private var lifecycle = CaptureToastLifecycle()
    private var hideObserver: NSObjectProtocol?

    var isVisible: Bool { panel?.isVisible ?? false }

    init(hider: TransientSurfaceHider) {
        self.hider = hider
        hideObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didHideNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeNow() }
        }
    }

    /// Top-right corner of `visibleFrame`, which already excludes the menu bar.
    nonisolated static func frame(for size: NSSize, in visibleFrame: NSRect) -> NSRect {
        NSRect(x: visibleFrame.maxX - size.width - margin,
               y: visibleFrame.maxY - size.height - margin,
               width: size.width, height: size.height)
    }

    static func duration(for content: CaptureToastContent) -> TimeInterval {
        if content.isPending { return pendingDisplayDuration }
        return content.buttons.isEmpty ? displayDuration : actionDisplayDuration
    }

    /// Shows `content`, replacing any notice on screen. `onEvent` runs once, for the first click; the notice
    /// then closes unless `onEvent` showed another one in its place.
    func show(_ content: CaptureToastContent, onEvent: @escaping (CaptureToastEvent) -> Void) {
        let panel = panel ?? makePanel()
        self.panel = panel
        guard let hosting else { return }
        let shown = lifecycle.willShow(content, appIsHidden: NSApp.isHidden, hider: hider)
        hosting.rootView = CaptureToastView(content: content) { [weak self] event in
            guard let self, self.lifecycle.accept(event, on: content, shown: shown, hider: self.hider) else { return }
            onEvent(event)
            if self.lifecycle.generation == shown { self.dismiss() }
        }
        let height = max(hosting.fittingSize.height, 44)
        let size = NSSize(width: Tokens.Size.toastWidth, height: height)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrame(Self.frame(for: size, in: visible), display: true)
        }
        panel.ignoresMouseEvents = content.isPending
        if !panel.isVisible { panel.alphaValue = 0 }
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
        scheduleDismiss(after: Self.duration(for: content))
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        lifecycle.willDismiss()
        let closing = lifecycle.generation
        guard let panel, panel.isVisible else {
            lifecycle.didClose(closing, hider: hider)
            return
        }
        panel.ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                guard closing == self.lifecycle.generation else { return }
                panel.orderOut(nil)
                panel.alphaValue = 1
                self.lifecycle.didClose(closing, hider: self.hider)
            }
        })
    }

    /// NoteIt was hidden with the notice up; it must not come back with NoteIt.
    private func closeNow() {
        guard lifecycle.isPresented else { return }
        dismissTask?.cancel()
        dismissTask = nil
        lifecycle.willDismiss()
        panel?.orderOut(nil)
        panel?.alphaValue = 1
        lifecycle.didClose(lifecycle.generation, hider: hider)
    }

    /// Counts down only while the pointer is off the notice; hovering holds it for at least `lingerAfterHover`.
    /// Polls the pointer, since tracking areas miss a notice that appears under a resting pointer.
    private func scheduleDismiss(after delay: TimeInterval) {
        dismissTask?.cancel()
        let scheduled = lifecycle.generation
        let tick = Self.hoverCheckInterval
        dismissTask = Task { @MainActor [weak self] in
            var remaining = delay
            while remaining > 0 {
                try? await Task.sleep(for: .seconds(tick))
                guard let self, !Task.isCancelled, scheduled == self.lifecycle.generation else { return }
                if self.isPointerOverNotice {
                    remaining = max(remaining, Self.lingerAfterHover)
                } else {
                    remaining -= tick
                }
            }
            self?.dismiss()
        }
    }

    private var isPointerOverNotice: Bool {
        guard let panel, panel.isVisible else { return false }
        return panel.frame.contains(NSEvent.mouseLocation)
    }

    private func makePanel() -> CaptureToastPanel {
        let size = NSSize(width: Tokens.Size.toastWidth, height: 64)
        let panel = CaptureToastPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.title = "NoteIt"

        let placeholder = CaptureToastContent(symbol: "checkmark", tone: .success, title: "")
        let hosting = CaptureToastHostingView(rootView: CaptureToastView(content: placeholder) { _ in })
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
        self.hosting = hosting
        return panel
    }
}

struct CaptureToastView: View {
    let content: CaptureToastContent
    let onEvent: (CaptureToastEvent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: content.symbol)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: Tokens.Radius.tile, style: .continuous)
                            .fill(tint)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(content.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                    if let message = content.message {
                        Text(message)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture { onEvent(.body) }

            if !content.buttons.isEmpty {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    ForEach(content.buttons, id: \.self) { button in
                        toastButton(button)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: Tokens.Size.toastWidth, alignment: .leading)
        .background(VisualEffectBackground(material: .popover))
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.panel, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: Tokens.Size.hairline)
        )
        .environment(\.controlActiveState, .key)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func toastButton(_ button: CaptureToastButton) -> some View {
        if button == content.buttons.last {
            Button(button.title) { onEvent(.button(button)) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        } else {
            Button(button.title) { onEvent(.button(button)) }
                .controlSize(.small)
        }
    }

    private var tint: Color {
        switch content.tone {
        case .success: Tokens.Color.success
        case .neutral: Tokens.Color.notebookGray
        case .warning: .orange
        }
    }
}
