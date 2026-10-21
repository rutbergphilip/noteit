import AppKit
import CoreSpotlight
import NoteItSync
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let hideDockIconKey = PrefKey.hideDockIcon

    private var observers: [NSObjectProtocol] = []
    private var reminderScheduler: ReminderScheduler?
    private var lastHideDockIcon: Bool?
    /// Last (hideDockIcon, showMenuBarIcon) pair seen by the defaults observer.
    private var lastVisibilityPrefs: (hide: Bool, showMenuBar: Bool)?
    private var defaultsSyncScheduled = false
    private let captureServiceProvider = CaptureServiceProvider()
    #if DEBUG
    private var debugWindow: NSWindow?
    #endif

    func applicationWillFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if CommandLine.arguments.contains("--self-test") {
            exit(HotkeySelfTest.run())
        }
        if AppEnvironment.value("SYNC_SELFTEST") == "1" {
            exit(SyncSelfTest.run())
        }
        #endif
        UserDefaults.standard.register(defaults: [
            PrefKey.showMenuBarIcon: true,
            PrefKey.editorFontSize: PrefDefault.editorFontSize,
            PrefKey.captureIncludesBrowserLinks: true,
            PrefKey.urlSchemeChangesWithoutAsking: false,
            PrefKey.localAPIEnabled: false,
            PrefKey.localAPIPort: 0,
            PrefKey.spotlightEnabled: true,
            PrefKey.spotlightIncludesText: true,
        ])
        URLSchemeHandler.shared.install()
        applyActivationPolicy()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.bundleURL.pathExtension != "app", let artwork = AppResources.appIcon {
            // Unbundled runs (`swift run`) have no .icns; show the same artwork in the Dock.
            NSApp.applicationIconImage = artwork
        }
        NoteStore.shared.installLinkIndex()
        SpotlightIndexer.shared.start()
        NoteStore.shared.startRecentlyDeletedMaintenance()
        AutomationService.shared.staged.purgeExpired(now: Date())
        _ = AppUpdater.shared
        LinkingAPIRoutes.register(in: .shared, store: NoteStore.shared)
        OrganiseRoutes.register(in: .shared, store: NoteStore.shared)
        _ = LocalAPIController.shared
        PasteAndMatchStyleShortcut.install()
        ReminderNotifications.shared.configure()
        let scheduler = ReminderScheduler(store: .shared, notifications: ReminderNotifications.shared,
                                          claims: ReminderClaims.live(.shared),
                                          defaults: .standard, clock: Date.init)
        reminderScheduler = scheduler
        scheduler.start()
        let center = NotificationCenter.default

        // Notification callbacks never assume main-actor isolation: they hop with a Task instead, because
        // they can be delivered synchronously from inside SwiftUI/KVO processing (or on another thread).
        observers.append(center.addObserver(forName: .noteItNewNote, object: nil, queue: nil) { _ in
            Task { @MainActor in
                WindowRouter.showMainWindow()
                NoteStore.shared.createNoteInCurrentContext()
                WindowRouter.focusEditor()
            }
        })
        observers.append(center.addObserver(forName: .noteItFocusSearch, object: nil, queue: nil) { _ in
            Task { @MainActor in WindowRouter.focusSearch() }
        })
        observers.append(center.addObserver(forName: .noteItShowMainWindow, object: nil, queue: nil) { _ in
            Task { @MainActor in WindowRouter.showMainWindow() }
        })
        // Posted synchronously by every defaults write (incl. MenuBarExtra's @AppStorage during a SwiftUI
        // update). Hop to the next main-actor turn and coalesce; never touch defaults inside the callback.
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleDefaultsSync() }
        })

        // Carbon global hotkeys need no Accessibility permission. All unbound by default. Capture Selection
        // reads the selected text in other apps, which needs Accessibility; that's opt-in.
        HotkeyManager.shared.handler = { action in
            switch action {
            case .showMainWindow:
                WindowRouter.toggleMainWindow()
            case .newNote:
                NotificationCenter.default.post(name: .noteItNewNote, object: nil)
            case .quickCapture:
                QuickCaptureController.shared.toggle()
            case .openQuickly:
                PaletteController.shared.hotkeyToggle(mode: .everything)
            case .commandPalette:
                PaletteController.shared.hotkeyToggle(mode: .commands)
            case .captureSelection:
                CaptureController.shared.captureSelection()
            case .openToday:
                WindowRouter.showMainWindow()
                NoteStore.shared.openDailyNote(for: Date())
                WindowRouter.focusEditor()
            case .showTasks:
                WindowRouter.showMainWindow()
                NoteStore.shared.showTasks()
            }
        }
        HotkeyManager.shared.start()
        NSApp.servicesProvider = captureServiceProvider
        NSUpdateDynamicServices()
        SyncController.shared.start()

        handleDebugArguments()
        DispatchQueue.main.async {
            LaunchMigration.presentPendingNotices()
            LegacyAppMonitor.shared.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NoteStore.shared.flush()
        SpotlightIndexer.shared.finishBeforeQuit()
        AutomationService.shared.staged.removeAll()
        LocalAPIController.shared.shutDown()
    }

    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType,
              let raw = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              let id = UUID(uuidString: raw) else { return false }
        WindowRouter.showMainWindow()
        NoteStore.shared.reveal(id)
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { WindowRouter.showMainWindow() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidResignActive(_ notification: Notification) {
        NoteStore.shared.flush()
    }

    private func scheduleDefaultsSync() {
        guard !defaultsSyncScheduled else { return }
        defaultsSyncScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.defaultsSyncScheduled = false
            let defaults = UserDefaults.standard
            let prefs = (hide: defaults.bool(forKey: PrefKey.hideDockIcon),
                         showMenuBar: defaults.bool(forKey: PrefKey.showMenuBarIcon))
            if let last = self.lastVisibilityPrefs, last == prefs { return }
            self.lastVisibilityPrefs = prefs
            self.applyActivationPolicy()
        }
    }

    /// `.accessory` (menu bar only) when "hideDockIcon" is set, otherwise `.regular`.
    func applyActivationPolicy() {
        let defaults = UserDefaults.standard
        var hide = defaults.bool(forKey: PrefKey.hideDockIcon)
        // Never leave NoteIt without both a Dock and a menu bar icon (e.g. the icon was ⌘-dragged out).
        if hide, defaults.object(forKey: PrefKey.showMenuBarIcon) != nil, !defaults.bool(forKey: PrefKey.showMenuBarIcon) {
            defaults.set(false, forKey: PrefKey.hideDockIcon)
            hide = false
        }
        guard hide != lastHideDockIcon else { return }
        let isInitial = lastHideDockIcon == nil
        lastHideDockIcon = hide

        let frontWindow = NSApp.keyWindow ?? NSApp.mainWindow
        NSApp.setActivationPolicy(hide ? .accessory : .regular)
        guard !isInitial, NSApp.isRunning else { return }
        // Switching policy can deactivate the app; keep whatever the user was looking at (Settings) frontmost.
        Task { @MainActor in
            NSApp.activate()
            frontWindow?.makeKeyAndOrderFront(nil)
        }
    }

    /// Developer launch arguments used for screenshots/testing. Compiled into debug builds only.
    private func handleDebugArguments() {
        #if DEBUG
        let args = CommandLine.arguments
        if args.contains("--debug-dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            MainActor.assumeIsolated {
                if args.contains("--debug-preview-bindings") {
                    // Display-only overlay: never persisted or registered.
                    HotkeyManager.shared.previewBinding(KeyCombo(keyCode: 14, modifiers: 4352), for: .showMainWindow)
                    HotkeyManager.shared.previewBinding(KeyCombo(keyCode: 49, modifiers: 2048), for: .quickCapture)
                }
                if args.contains("--debug-open-settings") {
                    SettingsOpener.open()
                    if let index = args.firstIndex(of: "--debug-settings-tab"), index + 1 < args.count {
                        let tab = args[index + 1]
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            NotificationCenter.default.post(name: .noteItShowSettingsTab, object: tab)
                        }
                    }
                }
                if args.contains("--debug-menubar-preview") {
                    // Hosts the menu bar panel content in a regular window so it can be screenshotted.
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 460),
                                          styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
                    window.title = "Menu Bar Preview"
                    window.titlebarAppearsTransparent = true
                    window.titleVisibility = .hidden
                    window.isReleasedWhenClosed = false
                    window.contentView = NSHostingView(rootView: MenuBarView().environmentObject(NoteStore.shared))
                    window.center()
                    NSApp.activate()
                    window.makeKeyAndOrderFront(nil)
                    self.debugWindow = window
                }
                if args.contains("--debug-show-conflicts") {
                    let store = NoteStore.shared
                    store.selection = .conflicts
                    store.selectedNoteID = store.notes(for: .conflicts, search: "").first?.id
                }
                if args.contains("--debug-quick-capture") {
                    QuickCaptureController.shared.show()
                }
                if let index = args.firstIndex(of: "--debug-find"), index + 1 < args.count,
                   let model = FindReplaceModel.anyVisible() {
                    let replacement = args.firstIndex(of: "--debug-replace").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
                    model.open(replace: replacement != nil)
                    model.query = args[index + 1]
                    if let replacement { model.replacement = replacement }
                }
            }
        }
        #endif
    }
}
