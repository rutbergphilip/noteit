import AppKit
import SwiftUI

/// The first-run guide's pages and when it shows (docs/specs/2026-10-19-surfaces-polish-design.md §6).
enum OnboardingPath {
    case new
    case existing
}

enum OnboardingPage: Equatable {
    case welcome
    case syncFirst
    case hotkeys
    case menuBar
    case importNotes
    case anotherMac
    case done
}

enum OnboardingFlow {
    /// Raised when a later version of the guide should show again.
    static let currentVersion = 1

    /// Pages for the chosen path; before a choice there is only the question.
    static func pages(for path: OnboardingPath?) -> [OnboardingPage] {
        switch path {
        case nil: [.welcome]
        case .new: [.welcome, .hotkeys, .menuBar, .importNotes, .anotherMac, .done]
        case .existing: [.welcome, .syncFirst, .hotkeys, .menuBar, .done]
        }
    }

    /// Automatically only on the launch that seeded a fresh library, and not again once finished or skipped.
    static func shouldShowAutomatically(seededThisLaunch: Bool, completedVersion: Int) -> Bool {
        seededThisLaunch && completedVersion < currentVersion
    }
}

/// The Welcome window: a short guide for a new library. Skip Setup and closing both finish it.
@MainActor
final class WelcomeWindow: NSObject, NSWindowDelegate {
    static let shared = WelcomeWindow()
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Welcome to NoteIt"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: WelcomeView(close: { [weak self] in self?.window?.close() }))
        window.center()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(OnboardingFlow.currentVersion, forKey: PrefKey.onboardingCompletedVersion)
        window = nil
    }
}

struct WelcomeView: View {
    let close: () -> Void
    @State private var path: OnboardingPath?
    @State private var index = 0
    @AppStorage(PrefKey.showMenuBarIcon) private var showMenuBarIcon = true
    @ObservedObject private var sync = SyncController.shared

    private var pages: [OnboardingPage] { OnboardingFlow.pages(for: path) }
    private var page: OnboardingPage { pages[min(index, pages.count - 1)] }
    private var isLast: Bool { index >= pages.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 40)
                .padding(.top, 32)
            Divider()
            footer
        }
        .frame(width: 560, height: 460)
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .welcome:
            VStack(spacing: Tokens.Space.s12) {
                AppIconView(size: 64)
                Text("Welcome to NoteIt").font(Tokens.Font.captureTitle)
                Text("NoteIt is for fast notes on this Mac. Your notes stay on your Mac unless you set up sync.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 380)
                VStack(spacing: Tokens.Space.s8) {
                    choice("New to NoteIt", .new)
                    choice("I use NoteIt on another Mac", .existing)
                }
                .padding(.top, Tokens.Space.s12)
            }
        case .syncFirst:
            step("Sync first", "Connect this Mac to the storage your other Mac syncs with. Your notes will appear here.") {
                Button("Set Up Sync…") { SettingsTabRouter.show(.sync) }
                Text(sync.isConfigured ? "Sync is set up. Your notes arrive in a moment." : "Not set up yet. You can continue and do it later.")
                    .font(Tokens.Font.cardMeta)
                    .foregroundStyle(.secondary)
            }
        case .hotkeys:
            step("Hotkeys", "Record shortcuts that work from any app, or skip: nothing is bound unless you record it.") {
                VStack(spacing: Tokens.Space.s10) {
                    ForEach([HotkeyAction.quickCapture, .showMainWindow, .commandPalette]) { action in
                        HStack {
                            Text(action.title)
                            Spacer()
                            ShortcutRecorder(action: action).frame(width: 190)
                        }
                    }
                }
                .frame(maxWidth: 400)
            }
        case .menuBar:
            step("Menu bar", "The menu bar icon opens search and a quick-note composer from anywhere.") {
                Toggle("Show menu bar icon", isOn: $showMenuBarIcon)
                Text("Hide the Dock icon or launch at login in Settings › General.")
                    .font(Tokens.Font.cardMeta)
                    .foregroundStyle(.secondary)
                Button("Open Settings…") { SettingsTabRouter.show(.general) }
            }
        case .importNotes:
            step("Bring your notes", "Import from Apple Notes, Evernote, Notion or a folder of Markdown files. Importing twice never makes duplicates.") {
                Button("Import…") { ImportSheetPresenter.show() }
            }
        case .anotherMac:
            step("Another Mac", "Use NoteIt on another Mac by syncing through a folder or storage you own. Notes are encrypted before they leave this Mac.") {
                Button("Set Up Sync…") { SettingsTabRouter.show(.sync) }
                Text("Or not now: you can do this any time in Settings › Sync.")
                    .font(Tokens.Font.cardMeta)
                    .foregroundStyle(.secondary)
            }
        case .done:
            step("You're set", "A few things worth knowing.") {
                VStack(alignment: .leading, spacing: Tokens.Space.s8) {
                    Label("⇧⌘P opens the command palette; ⌘O finds any note.", systemImage: "command")
                    Label("Quick Capture floats over any app and keeps your draft.", systemImage: "bolt")
                    Label("⌃⌘I shows a note's word count and dates.", systemImage: "info.circle")
                }
                .font(Tokens.Font.row)
                Button("Start Writing") {
                    close()
                    WindowRouter.showMainWindow()
                    WindowRouter.focusEditor()
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, Tokens.Space.s8)
            }
        }
    }

    private func choice(_ title: String, _ value: OnboardingPath) -> some View {
        Button {
            path = value
            index = 1
        } label: {
            Text(title).frame(width: 240)
        }
        .controlSize(.large)
    }

    private func step<Content: View>(_ title: String, _ message: String, @ViewBuilder _ body: () -> Content) -> some View {
        VStack(spacing: Tokens.Space.s12) {
            Text(title).font(Tokens.Font.captureTitle)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 400)
            VStack(spacing: Tokens.Space.s10, content: body)
                .padding(.top, Tokens.Space.s8)
        }
    }

    private var footer: some View {
        HStack {
            Button("Skip Setup", action: close)
                .buttonStyle(.link)
            Spacer()
            HStack(spacing: 6) {
                ForEach(0..<pages.count, id: \.self) { dot in
                    Circle()
                        .fill(dot == index ? Tokens.Color.accent : Tokens.Color.fillQuiet)
                        .frame(width: 6, height: 6)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Page \(index + 1) of \(pages.count)")
            Spacer()
            Button("Back") { index -= 1 }
                .disabled(index == 0)
            Button("Continue") { index += 1 }
                .keyboardShortcut(.defaultAction)
                .disabled(isLast || page == .welcome)
        }
        .padding(Tokens.Space.s16)
    }
}
