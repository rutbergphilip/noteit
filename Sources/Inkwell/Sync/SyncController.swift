import AppKit
import Combine
import InkwellSync

enum SyncStatus: Equatable {
    case notConfigured
    case idle(lastSync: Date?)
    case syncing
    case offline(String)
    case error(String)
    case needsPassphrase

    var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }
}

/// What "Test Connection" found at the destination.
enum RemoteInspection: Equatable {
    case empty, plaintext, encrypted, unsupported(Int)

    var summary: String {
        switch self {
        case .empty: "Connected. The location is empty and ready for your library."
        case .plaintext: "Connected. Found an unencrypted Inkwell library."
        case .encrypted: "Connected. Found an encrypted Inkwell library."
        case .unsupported: "Connected, but the library was created by a newer version of Inkwell."
        }
    }
}

enum SyncSetupError: LocalizedError {
    case folderUnavailable(String)
    case missingField(String)
    case invalidEndpoint
    case storageReset
    case keychain(String)

    var errorDescription: String? {
        switch self {
        case .folderUnavailable(let path): "The folder “\(path)” isn't available. Is the drive or NAS connected?"
        case .missingField(let name): "Enter \(name)."
        case .invalidEndpoint: "The endpoint must be a full URL, such as https://s3.eu-north-1.amazonaws.com."
        case .storageReset: "Sync storage was reset or moved. Disconnect and connect again to start over."
        case .keychain(let message): message
        }
    }
}

/// Owns sync scheduling and status. Nothing runs (no timers, no tasks, no observers) until sync is configured;
/// then a single loop runs passes off the main thread and coalesces every trigger into at most one follow-up.
@MainActor
final class SyncController: ObservableObject {
    static let shared = SyncController(store: .shared)

    @Published private(set) var status: SyncStatus = .notConfigured
    @Published private(set) var configuration: SyncConfiguration?
    @Published private(set) var lastReport: SyncReport?
    @Published private(set) var lastSync: Date?
    @Published private(set) var devices: [DeviceInfo] = []
    @Published private(set) var conflictCount = 0

    var isConfigured: Bool { configuration != nil }

    static let lastSyncKey = "syncLastSync"
    static let foregroundInterval: TimeInterval = 60
    static let backgroundInterval: TimeInterval = 600
    static let localChangeDebounce: TimeInterval = 2
    static let localChangeMaxDelay: TimeInterval = 10
    static let maxBackoff: TimeInterval = 600

    private let store: NoteStore
    private var session: Session?
    private var loop: Task<Void, Never>?
    private var sleeper: Task<Void, Never>?
    private var timerDue = Date.distantFuture
    private var localChangeDue: Date?
    private var firstPendingLocalChange: Date?
    private var lastPassStarted: Date?
    private var passInFlight = false
    private var showSyncingImmediately = false
    private var failures = 0
    private var paused = false
    private var generation = 0
    private var pendingDeviceRename = false
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var notesSubscription: AnyCancellable?
    private var intervalOverride: TimeInterval?
    /// DEBUG overrides keep everything in memory: nothing goes to UserDefaults or the keychain.
    private var ephemeralSecrets: Secrets?

    private struct Secrets: Sendable {
        var accessKey: String?
        var secret: String?
        var passphrase: String?
    }

    private final class Session: @unchecked Sendable {
        let engine: SyncEngine
        let backend: StorageBackend
        let cipher: SyncCipher
        let adapter: NoteStoreSyncAdapter
        let folder: URL?
        let scoped: Bool

        init(engine: SyncEngine, backend: StorageBackend, cipher: SyncCipher, adapter: NoteStoreSyncAdapter, folder: URL?, scoped: Bool) {
            self.engine = engine
            self.backend = backend
            self.cipher = cipher
            self.adapter = adapter
            self.folder = folder
            self.scoped = scoped
        }
    }

    private struct Destination: Sendable {
        var backend: StorageBackend
        var folder: URL?
        var scoped: Bool
    }

    init(store: NoteStore) {
        self.store = store
    }

    private var stateURL: URL { store.rootURL.appendingPathComponent("sync-state.json") }

    // MARK: - Lifecycle

    func start() {
        #if DEBUG
        if startFromDebugEnvironment() { return }
        #endif
        guard let config = SyncConfiguration.load() else { return }
        activate(config, session: nil)
    }

    /// Validates the destination, creates or joins the remote library, stores secrets and starts syncing.
    func connect(_ config: SyncConfiguration, accessKey: String?, secret: String?, passphrase: String?) async throws {
        var config = config
        let destination = try makeDestination(config, accessKey: accessKey, secret: secret)
        let encryptNew = config.encrypted
        let (manifest, cipher, created) = try await withAccess(destination) {
            try await Self.offMain {
                try await destination.backend.probe()
                return try await SyncEngine.connectReportingCreation(backend: destination.backend, passphrase: passphrase, encryptNew: encryptNew)
            }
        }
        config.encrypted = manifest.encryption != nil

        let secrets = Secrets(accessKey: config.provider.isS3 ? accessKey : nil,
                              secret: config.provider.isS3 ? secret : nil,
                              passphrase: config.encrypted ? passphrase : nil)
        if ephemeralSecrets != nil {
            ephemeralSecrets = secrets
        } else {
            do {
                try Keychain.set(secrets.accessKey, for: .s3AccessKey)
                try Keychain.set(secrets.secret, for: .s3Secret)
                try Keychain.set(secrets.passphrase, for: .passphrase)
            } catch {
                Keychain.deleteAll()
                throw SyncSetupError.keychain("Couldn't save your credentials to the keychain. \(error.localizedDescription)")
            }
            config.save()
        }

        deactivate()
        try? FileManager.default.removeItem(at: stateURL)
        store.clearAllSyncDeletions()
        if created {
            store.discardSeedManifest()
        } else {
            let removed = store.removePristineSeedContent()
            if removed != (0, 0) { NSLog("InkwellSync: removed \(removed.notes) unedited sample notes and \(removed.notebooks) sample notebooks before joining") }
        }
        let adapter = NoteStoreSyncAdapter(store: store, deviceID: config.deviceID)
        let engine = SyncEngine(backend: destination.backend, cipher: cipher, local: adapter, stateURL: stateURL,
                                deviceID: config.deviceID, deviceName: config.deviceName)
        let session = Session(engine: engine, backend: destination.backend, cipher: cipher, adapter: adapter,
                              folder: destination.folder, scoped: destination.scoped)
        lastSync = nil
        UserDefaults.standard.removeObject(forKey: Self.lastSyncKey)
        activate(config, session: session)
    }

    /// Re-enters the passphrase after the keychain lost it or it changed on another Mac.
    func unlock(passphrase: String) async throws {
        guard let config = configuration else { return }
        let destination = try makeDestination(config, accessKey: secrets.accessKey, secret: secrets.secret)
        _ = try await withAccess(destination) {
            try await Self.offMain {
                try await SyncEngine.connect(backend: destination.backend, passphrase: passphrase, encryptNew: config.encrypted)
            }
        }
        if ephemeralSecrets != nil {
            ephemeralSecrets?.passphrase = passphrase
        } else {
            do {
                try Keychain.set(passphrase, for: .passphrase)
            } catch {
                throw SyncSetupError.keychain("Couldn't save the passphrase to the keychain. \(error.localizedDescription)")
            }
        }
        session = nil
        paused = false
        failures = 0
        status = .idle(lastSync: lastSync)
        requestSync(after: 0)
    }

    /// Stops syncing and forgets the destination. Notes on this Mac are never touched.
    func disconnect() {
        deactivate()
        configuration = nil
        status = .notConfigured
        lastReport = nil
        lastSync = nil
        devices = []
        conflictCount = 0
        if ephemeralSecrets != nil {
            ephemeralSecrets = Secrets()
        } else {
            SyncConfiguration.clear()
            Keychain.deleteAll()
        }
        UserDefaults.standard.removeObject(forKey: Self.lastSyncKey)
        removeLocalSyncFiles()
    }

    func testConnection(_ config: SyncConfiguration, accessKey: String?, secret: String?) async -> Result<RemoteInspection, Error> {
        do {
            let destination = try makeDestination(config, accessKey: accessKey, secret: secret)
            let inspection = try await withAccess(destination) {
                try await Self.offMain { () async throws -> RemoteInspection in
                    try await destination.backend.probe()
                    return try await Self.inspect(destination.backend)
                }
            }
            return .success(inspection)
        } catch {
            return .failure(error)
        }
    }

    func syncNow() {
        guard isConfigured else { return }
        if paused, status != .needsPassphrase {
            paused = false
            session = nil
        }
        failures = 0
        showSyncingImmediately = true
        requestSync(after: 0)
    }

    func rename(device name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var config = configuration, !trimmed.isEmpty, trimmed != config.deviceName else { return }
        config.deviceName = trimmed
        configuration = config
        if ephemeralSecrets == nil { config.save() }
        pendingDeviceRename = true
        requestSync(after: 0.5)
    }

    func refreshDevices() async {
        guard let session else { return }
        let gen = generation
        let destination = Destination(backend: session.backend, folder: session.folder, scoped: session.scoped)
        let result = try? await withAccess(destination) {
            try await Self.offMain { try await session.engine.devices() }
        }
        guard gen == generation, let result else { return }
        if result != devices { devices = result }
    }

    // MARK: - Activation

    private func activate(_ config: SyncConfiguration, session: Session?) {
        generation += 1
        configuration = config
        self.session = session
        NoteStore.syncJournalEnabled = true
        paused = false
        failures = 0
        if lastSync == nil, let stored = UserDefaults.standard.object(forKey: Self.lastSyncKey) as? Date {
            lastSync = stored
        }
        status = .idle(lastSync: lastSync)
        observe()
        timerDue = .distantFuture
        localChangeDue = nil
        firstPendingLocalChange = nil
        loop = Task { [weak self] in await self?.runLoop() }
        requestSync(after: session == nil ? 1 : 0)
    }

    private func deactivate() {
        generation += 1
        loop?.cancel()
        loop = nil
        sleeper?.cancel()
        sleeper = nil
        session?.adapter.deactivate()
        session = nil
        pendingDeviceRename = false
        NoteStore.syncJournalEnabled = false
        for token in observers { NotificationCenter.default.removeObserver(token) }
        for token in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        observers = []
        workspaceObservers = []
        notesSubscription = nil
    }

    private func removeLocalSyncFiles() {
        try? FileManager.default.removeItem(at: stateURL)
        store.clearAllSyncDeletions()
        // A pass that was already running may still write the state file; clean up after it.
        if passInFlight {
            let gen = generation
            Task { [weak self] in
                while let self, self.passInFlight { try? await Task.sleep(for: .milliseconds(200)) }
                guard let self, gen == self.generation, !self.isConfigured else { return }
                try? FileManager.default.removeItem(at: self.stateURL)
                self.store.clearAllSyncDeletions()
            }
        }
    }

    private func observe() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .inkwellLocalChange, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in self?.noteLocalChange() }
        })
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in self?.appBecameActive() }
        })
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.requestSync(after: 5) }
        })
        notesSubscription = store.$notes
            .map { notes in notes.reduce(0) { $0 + ($1.conflictSource == nil ? 0 : 1) } }
            .removeDuplicates()
            .sink { [weak self] count in self?.conflictCount = count }
    }

    // MARK: - Scheduling

    private func requestSync(after delay: TimeInterval) {
        guard loop != nil else { return }
        let due = Date().addingTimeInterval(delay)
        if due < timerDue { timerDue = due }
        sleeper?.cancel()
    }

    private func noteLocalChange() {
        guard loop != nil else { return }
        let now = Date()
        let first = firstPendingLocalChange ?? now
        firstPendingLocalChange = first
        localChangeDue = min(now.addingTimeInterval(Self.localChangeDebounce), first.addingTimeInterval(Self.localChangeMaxDelay))
        sleeper?.cancel()
    }

    private func appBecameActive() {
        let age = lastPassStarted.map { Date().timeIntervalSince($0) } ?? .infinity
        requestSync(after: age > 15 ? 0.5 : Self.foregroundInterval)
    }

    private var nextDue: Date {
        paused ? .distantFuture : min(timerDue, localChangeDue ?? .distantFuture)
    }

    private func runLoop() async {
        while !Task.isCancelled {
            let wait = nextDue.timeIntervalSinceNow
            if wait > 0 {
                let nap = Task<Void, Never> { try? await Task.sleep(for: .seconds(min(wait, 3600))) }
                sleeper = nap
                await nap.value
                if sleeper == nap { sleeper = nil }
                continue
            }
            timerDue = .distantFuture
            localChangeDue = nil
            firstPendingLocalChange = nil
            let retryAfter = await performPass()
            if Task.isCancelled { break }
            let delay = retryAfter ?? interval
            let due = Date().addingTimeInterval(delay)
            if due < timerDue { timerDue = due }
        }
    }

    private var interval: TimeInterval {
        if let intervalOverride { return intervalOverride }
        return isForeground ? Self.foregroundInterval : Self.backgroundInterval
    }

    private var isForeground: Bool {
        NSApp.isActive || NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel) }
    }

    // MARK: - Pass

    /// Returns a retry delay when the pass failed, nil to use the normal interval.
    private func performPass() async -> TimeInterval? {
        guard let config = configuration else { return nil }
        let gen = generation
        lastPassStarted = Date()
        passInFlight = true
        // Background passes usually finish in milliseconds; only show "Syncing" if one takes a while.
        let immediate = showSyncingImmediately || !(status.isIdle)
        showSyncingImmediately = false
        let indicator: Task<Void, Never>? = immediate ? nil : Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, let self, self.passInFlight, gen == self.generation else { return }
            self.status = .syncing
        }
        if immediate { status = .syncing }
        defer {
            indicator?.cancel()
            passInFlight = false
        }
        do {
            let session = try await ensureSession(config)
            guard gen == generation else { return nil }
            let destination = Destination(backend: session.backend, folder: session.folder, scoped: session.scoped)
            let report = try await withAccess(destination) {
                try await Self.offMain { try await session.engine.sync() }
            }
            guard gen == generation else { return nil }
            let now = Date()
            if lastReport != report { lastReport = report }
            lastSync = now
            if ephemeralSecrets == nil { UserDefaults.standard.set(now, forKey: Self.lastSyncKey) }
            failures = 0
            status = .idle(lastSync: now)
            #if DEBUG
            if intervalOverride != nil, report != SyncReport() {
                NSLog("InkwellSync: pass pushed=\(report.pushed) pulled=\(report.pulled) deleted=\(report.deleted) conflicts=\(report.conflicts) skipped=\(report.skipped) errors=\(report.errors.count)")
            }
            #endif
            return nil
        } catch {
            guard gen == generation else { return nil }
            return handle(error)
        }
    }

    private func handle(_ error: Error) -> TimeInterval? {
        switch error {
        case SyncError.passphraseRequired, SyncError.wrongPassphrase:
            status = .needsPassphrase
            pause()
            return nil
        case SyncError.unsupportedFormat, SyncError.encryptionMismatch, SyncSetupError.storageReset, SyncSetupError.missingField, SyncSetupError.invalidEndpoint:
            status = .error(Self.describe(error))
            pause()
            return nil
        case StorageError.unauthorized:
            status = .error("Access was denied. Check your access key and secret in Settings.")
            pause()
            return nil
        case StorageError.notFound(let key) where key == RemoteLayout.manifest():
            status = .error(SyncSetupError.storageReset.errorDescription ?? "")
            pause()
            return nil
        case SyncSetupError.folderUnavailable, StorageError.network:
            status = .offline(Self.describe(error))
        default:
            status = .error(Self.describe(error))
        }
        session = nil
        failures += 1
        let base = intervalOverride ?? 15
        return min(Self.maxBackoff, base * pow(2, Double(failures - 1)))
    }

    private func pause() {
        paused = true
        session = nil
    }

    private func ensureSession(_ config: SyncConfiguration) async throws -> Session {
        if let session, !pendingDeviceRename { return session }
        if let session, pendingDeviceRename {
            pendingDeviceRename = false
            var state = SyncState.load(from: stateURL)
            state.lastDeviceWrite = nil
            try? state.save(to: stateURL)
            let engine = SyncEngine(backend: session.backend, cipher: session.cipher, local: session.adapter, stateURL: stateURL,
                                    deviceID: config.deviceID, deviceName: config.deviceName)
            let renewed = Session(engine: engine, backend: session.backend, cipher: session.cipher, adapter: session.adapter,
                                  folder: session.folder, scoped: session.scoped)
            self.session = renewed
            return renewed
        }
        pendingDeviceRename = false
        let secrets = secrets
        if config.encrypted, (secrets.passphrase ?? "").isEmpty { throw SyncError.passphraseRequired }
        let destination = try makeDestination(config, accessKey: secrets.accessKey, secret: secrets.secret)
        let cipher = try await withAccess(destination) {
            try await Self.offMain { () async throws -> SyncCipher in
                // Never recreate a vanished store: syncing against an empty remote would delete every note here.
                do {
                    _ = try await destination.backend.get(RemoteLayout.manifest())
                } catch StorageError.notFound {
                    throw SyncSetupError.storageReset
                }
                return try await SyncEngine.connect(backend: destination.backend, passphrase: secrets.passphrase, encryptNew: config.encrypted).1
            }
        }
        let adapter = NoteStoreSyncAdapter(store: store, deviceID: config.deviceID)
        let engine = SyncEngine(backend: destination.backend, cipher: cipher, local: adapter, stateURL: stateURL,
                                deviceID: config.deviceID, deviceName: config.deviceName)
        let session = Session(engine: engine, backend: destination.backend, cipher: cipher, adapter: adapter,
                              folder: destination.folder, scoped: destination.scoped)
        self.session = session
        return session
    }

    private var secrets: Secrets {
        if let ephemeralSecrets { return ephemeralSecrets }
        return Secrets(accessKey: Keychain.get(.s3AccessKey), secret: Keychain.get(.s3Secret), passphrase: Keychain.get(.passphrase))
    }

    // MARK: - Backends

    private func makeDestination(_ config: SyncConfiguration, accessKey: String?, secret: String?) throws -> Destination {
        if config.provider == .folder {
            guard let resolved = config.resolveFolder() else { throw SyncSetupError.missingField("a folder") }
            if let refreshed = resolved.refreshedBookmark, var current = configuration, current == config {
                current.folderBookmark = refreshed
                configuration = current
                if ephemeralSecrets == nil { current.save() }
            }
            var isDir: ObjCBool = false
            let accessing = resolved.scoped && resolved.url.startAccessingSecurityScopedResource()
            defer { if accessing { resolved.url.stopAccessingSecurityScopedResource() } }
            guard FileManager.default.fileExists(atPath: resolved.url.path, isDirectory: &isDir), isDir.boolValue else {
                throw SyncSetupError.folderUnavailable((resolved.url.path as NSString).abbreviatingWithTildeInPath)
            }
            return Destination(backend: FolderBackend(root: resolved.url), folder: resolved.url, scoped: resolved.scoped)
        }
        guard let s3 = config.s3 else { throw SyncSetupError.missingField("the bucket details") }
        guard let scheme = s3.endpoint.scheme?.lowercased(), ["http", "https"].contains(scheme), s3.endpoint.host != nil else {
            throw SyncSetupError.invalidEndpoint
        }
        guard !s3.bucket.isEmpty else { throw SyncSetupError.missingField("a bucket name") }
        guard let accessKey, !accessKey.isEmpty else { throw SyncSetupError.missingField("an access key") }
        guard let secret, !secret.isEmpty else { throw SyncSetupError.missingField("a secret key") }
        let backend = S3Backend(config: s3, credentials: S3Credentials(accessKeyID: accessKey, secretAccessKey: secret),
                                session: Self.urlSession)
        return Destination(backend: backend, folder: nil, scoped: false)
    }

    /// No response cache: stale listings or bodies would make sync decisions on old data.
    private static let urlSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration)
    }()

    private func withAccess<T>(_ destination: Destination, _ work: () async throws -> T) async throws -> T {
        let accessing = destination.scoped && (destination.folder?.startAccessingSecurityScopedResource() ?? false)
        defer { if accessing { destination.folder?.stopAccessingSecurityScopedResource() } }
        return try await work()
    }

    /// Runs engine work at utility priority off the main thread. A continuation is used instead of
    /// awaiting `.value` so the main-actor caller doesn't escalate the work's priority.
    private static func offMain<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .utility) {
                do { continuation.resume(returning: try await work()) } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func inspect(_ backend: StorageBackend) async throws -> RemoteInspection {
        let data: Data
        do {
            data = try await backend.get(RemoteLayout.manifest()).data
        } catch StorageError.notFound {
            return .empty
        }
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
            throw StorageError.invalidResponse("Unreadable manifest")
        }
        if manifest.formatVersion > 1 { return .unsupported(manifest.formatVersion) }
        return manifest.encryption == nil ? .plaintext : .encrypted
    }

    // MARK: - Messages

    static func describe(_ error: Error) -> String {
        switch error {
        case let error as SyncSetupError:
            return error.errorDescription ?? "Sync failed."
        case SyncError.passphraseRequired:
            return "Enter the passphrase used on your other Mac."
        case SyncError.wrongPassphrase:
            return "That passphrase doesn't match. Use the one you chose when you first set up sync."
        case SyncError.unsupportedFormat:
            return "This library was created by a newer version of Inkwell. Update Inkwell to keep syncing."
        case SyncError.encryptionMismatch:
            return "This location already holds an unencrypted Inkwell library. Turn off encryption to join it, or choose another location."
        case StorageError.unauthorized:
            return "Access was denied. Check the access key, secret and bucket permissions."
        case StorageError.network(let message):
            return "Can't reach the storage: \(message)"
        case StorageError.notFound(let key) where key == RemoteLayout.manifest():
            return SyncSetupError.storageReset.errorDescription ?? ""
        case StorageError.notFound:
            return "The bucket or folder wasn't found. Check its name and region."
        case StorageError.io(let message):
            return "Couldn't read or write the folder: \(message)"
        case StorageError.invalidResponse(let message):
            return "The storage returned an unexpected response: \(message)"
        case StorageError.preconditionFailed:
            return "Another Mac changed the library at the same time. Inkwell will try again."
        default:
            return error.localizedDescription
        }
    }

    // MARK: - DEBUG overrides

    #if DEBUG
    private struct DebugConfig: Decodable {
        var passphrase: String?
        var accessKey: String?
        var secret: String?
    }

    /// `INKWELL_SYNC_CONFIG` (SyncConfiguration JSON plus passphrase/accessKey/secret) connects headlessly
    /// on launch without touching UserDefaults or the keychain. `INKWELL_SYNC_INTERVAL` overrides the poll interval.
    private func startFromDebugEnvironment() -> Bool {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["INKWELL_SYNC_INTERVAL"], let seconds = TimeInterval(raw), seconds > 0 {
            intervalOverride = seconds
        }
        if let raw = env["INKWELL_DEBUG_EDIT_AFTER"], let delay = TimeInterval(raw) {
            scheduleDebugEdit(after: delay)
        }
        guard let json = env["INKWELL_SYNC_CONFIG"], let data = json.data(using: .utf8) else { return false }
        do {
            var config = try JSONDecoder().decode(SyncConfiguration.self, from: data)
            let extras = try JSONDecoder().decode(DebugConfig.self, from: data)
            if let path = config.folderPath, config.folderBookmark == nil {
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                config.folderPath = url.path
            }
            ephemeralSecrets = Secrets(accessKey: extras.accessKey, secret: extras.secret, passphrase: extras.passphrase)
            Task {
                do {
                    try await connect(config, accessKey: extras.accessKey, secret: extras.secret, passphrase: extras.passphrase)
                    NSLog("InkwellSync: connected (\(config.provider.rawValue), encrypted: \(config.encrypted))")
                } catch {
                    NSLog("InkwellSync: connect failed: \(Self.describe(error))")
                }
            }
        } catch {
            NSLog("InkwellSync: invalid INKWELL_SYNC_CONFIG: \(error)")
        }
        return true
    }

    /// Appends a line to the selected note as if the user typed it (headless two-instance testing).
    private func scheduleDebugEdit(after delay: TimeInterval) {
        Task { [store] in
            try? await Task.sleep(for: .seconds(delay))
            guard let id = store.selectedNoteID ?? store.notes.first?.id else { return }
            let text = NSMutableAttributedString(attributedString: store.body(for: id))
            let attributes = text.length > 0 ? text.attributes(at: text.length - 1, effectiveRange: nil) : [:]
            let stamp = Date().formatted(date: .omitted, time: .standard)
            text.append(NSAttributedString(string: "\nEdited on \(configuration?.deviceName ?? "this Mac") at \(stamp)", attributes: attributes))
            store.updateBody(id, text)
            NSLog("InkwellSync: debug edit of \(id.uuidString) at \(stamp)")
        }
    }
    #endif
}
