import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Borderless floating panel that can take keyboard focus without activating Inkwell.
final class QuickCapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class QuickCaptureModel: ObservableObject {
    @Published var title = ""
    @Published var body = ""
    @Published var notebookID: UUID?
    @Published var focusToken = 0

    var isEmpty: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Spotlight-style quick capture: ⌘↩ saves, Esc dismisses, clicking elsewhere dismisses.
@MainActor
final class QuickCaptureController: NSObject, NSWindowDelegate {
    static let shared = QuickCaptureController()
    static let size = NSSize(width: 580, height: 330)

    private var panel: QuickCapturePanel?
    private var keyMonitor: Any?
    private let model = QuickCaptureModel()
    private var shownAt = Date.distantPast

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        isVisible ? dismiss() : show()
    }

    /// Shows the panel. An unsaved draft is kept until it is saved or explicitly discarded;
    /// an explicit `title`/`body` payload fills empty fields and is appended to an existing body.
    func show(title: String? = nil, body: String? = nil) {
        let panel = panel ?? makePanel()
        self.panel = panel
        if model.isEmpty {
            model.notebookID = NoteStore.shared.defaultNotebookIDForNewNotes
        }
        if let title, !title.isEmpty {
            if model.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                model.title = title
            } else {
                model.body = model.body.isEmpty ? title : model.body + "\n\n" + title
            }
        }
        if let body, !body.isEmpty {
            model.body = model.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? body : model.body + "\n\n" + body
        }

        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let origin = NSPoint(x: visible.midX - Self.size.width / 2,
                                 y: visible.maxY - visible.height * 0.22 - Self.size.height)
            panel.setFrame(NSRect(origin: origin, size: Self.size), display: false)
        }
        shownAt = Date()
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
        installKeyMonitor()
        model.focusToken += 1
    }

    func dismiss() {
        guard let panel, panel.isVisible else { return }
        removeKeyMonitor()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                panel.alphaValue = 1
            }
        })
    }

    func save() {
        guard !model.isEmpty else {
            NSSound.beep()
            return
        }
        guard NoteStore.shared.captureNote(title: model.title, body: model.body, in: model.notebookID) != nil else {
            NSSound.beep()
            return
        }
        clearDraft()
        dismiss()
    }

    /// Throws away the current draft (Discard button or ⇧⌘⌫) and closes the panel.
    func discard() {
        clearDraft()
        dismiss()
    }

    private func clearDraft() {
        model.title = ""
        model.body = ""
        model.notebookID = NoteStore.shared.defaultNotebookIDForNewNotes
    }

    // MARK: - Panel

    private func makePanel() -> QuickCapturePanel {
        let panel = QuickCapturePanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.title = "Quick Capture"
        panel.delegate = self

        let root = QuickCaptureView(
            model: model,
            store: NoteStore.shared,
            onSave: { [weak self] in self?.save() },
            onCancel: { [weak self] in self?.dismiss() },
            onDiscard: { [weak self] in self?.discard() }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: Self.size)
        panel.contentView = hosting
        return panel
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = Int(event.keyCode)
            let command = event.modifierFlags.contains(.command)
            let shift = event.modifierFlags.contains(.shift)
            let windowNumber = event.windowNumber
            let swallow = MainActor.assumeIsolated { () -> Bool in
                let controller = QuickCaptureController.shared
                guard let panel = controller.panel, panel.windowNumber == windowNumber else { return false }
                switch keyCode {
                case kVK_Escape:
                    controller.dismiss()
                    return true
                case kVK_Return where command, kVK_ANSI_KeypadEnter where command:
                    controller.save()
                    return true
                case kVK_Delete where command && shift:
                    controller.discard()
                    return true
                default:
                    return false
                }
            }
            return swallow ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    nonisolated func windowDidResignKey(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Clicking anywhere else dismisses, like Spotlight. Keep unsaved text for next time.
            // Ignore the key-window shuffle that can happen right after showing (e.g. during launch).
            if Date().timeIntervalSince(self.shownAt) < 0.5 {
                self.panel?.makeKey()
            } else if !(self.panel?.isKeyWindow ?? false) {
                self.dismiss()
            }
        }
    }
}

struct QuickCaptureView: View {
    @ObservedObject var model: QuickCaptureModel
    @ObservedObject var store: NoteStore
    var onSave: () -> Void
    var onCancel: () -> Void
    var onDiscard: () -> Void

    private enum Field { case title, body }
    @FocusState private var focus: Field?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(LinearGradient(colors: [Color(hex: "#6E5BFF"), Color(hex: "#3A3FD9")],
                                                 startPoint: .top, endPoint: .bottom))
                    )
                Text("Quick Capture")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                NotebookMenuPicker(selection: $model.notebookID, store: store)
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 10)

            TextField("Title", text: $model.title)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .semibold))
                .focused($focus, equals: .title)
                .onSubmit { focus = .body }
                .padding(.horizontal, 18)
                .padding(.bottom, 6)

            ZStack(alignment: .topLeading) {
                if model.body.isEmpty {
                    Text("Start typing your note…")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $model.body)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                    .focused($focus, equals: .body)
            }
            .padding(.horizontal, 13)
            .frame(maxHeight: .infinity)

            Divider().opacity(0.6)

            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    Keycap(label: "esc", size: 10)
                    Text("to dismiss — draft is kept")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

                Spacer()

                if !model.isEmpty {
                    Button("Discard", role: .destructive, action: onDiscard)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .help("Discard this draft (⇧⌘⌫)")
                }

                Button(action: onSave) {
                    HStack(spacing: 6) {
                        Text("Save Note")
                        Text("⌘↩").opacity(0.75)
                    }
                    .padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(model.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
        }
        .frame(width: QuickCaptureController.size.width, height: QuickCaptureController.size.height)
        .background(VisualEffectBackground(material: .popover))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .onChange(of: model.focusToken) {
            DispatchQueue.main.async {
                focus = model.title.isEmpty && !model.body.isEmpty ? .body : .title
            }
        }
    }
}
