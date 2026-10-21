import Foundation

/// The `$VISUAL`/`$EDITOR` round trip for `noteit edit`.
enum CLIEditor {
    static func command(environment: [String: String]) -> String {
        for name in ["VISUAL", "EDITOR"] {
            if let value = environment[name]?.trimmingCharacters(in: .whitespaces), !value.isEmpty { return value }
        }
        return "vi"
    }

    /// Writes `text` to a private temporary file, runs the editor on it with the terminal attached, and returns
    /// the edited text, or nil when the editor failed. The file is removed afterwards.
    static func edit(_ text: String, environment: [String: String],
                     run: (String, URL) throws -> Int32 = runEditor) throws -> String? {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("noteit-\(UUID().uuidString).md")
        guard FileManager.default.createFile(atPath: file.path, contents: Data(text.utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path])
        }
        defer { try? FileManager.default.removeItem(at: file) }
        guard try run(command(environment: environment), file) == 0 else { return nil }
        return try String(contentsOf: file, encoding: .utf8)
    }

    enum Termination: Equatable {
        case exited(Int32)
        case signaled(Int32)
    }

    /// Like git, an editor killed by SIGINT or SIGQUIT ends noteit with the same signal's exit status.
    static func runEditor(_ command: String, _ file: URL) throws -> Int32 {
        switch try spawnAndWait(command, file) {
        case .exited(let code):
            return code
        case .signaled(let signal):
            if signal == SIGINT || signal == SIGQUIT {
                try? FileManager.default.removeItem(at: file)
                exit(128 + signal)
            }
            return 128 + signal
        }
    }

    /// The signals a child gets back at their default action, whatever noteit is doing with them.
    static let defaultedSignals = [SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGPIPE, SIGTSTP, SIGTTIN, SIGTTOU]

    /// Runs `/bin/sh -c '<command> "$1"' sh <file>` in noteit's own process group with the terminal inherited,
    /// so terminal editors stay in the foreground. The value may carry arguments (`code --wait`).
    /// SIGINT and SIGQUIT are ignored while waiting, as git does; the editor gets them from the terminal.
    static func spawnAndWait(_ command: String, _ file: URL) throws -> Termination {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in defaultedSignals { sigaddset(&defaults, signal) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var unmasked = sigset_t()
        sigemptyset(&unmasked)
        posix_spawnattr_setsigmask(&attributes, &unmasked)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        let stopGuard = StopSignalGuard(file: file)
        defer { stopGuard.cancel() }
        let previousInterrupt = signal(SIGINT, SIG_IGN)
        let previousQuit = signal(SIGQUIT, SIG_IGN)
        defer {
            signal(SIGINT, previousInterrupt)
            signal(SIGQUIT, previousQuit)
        }

        let arguments = ["/bin/sh", "-c", command + " \"$1\"", "sh", file.path]
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let pid = try stopGuard.recordChild {
            var pid: pid_t = 0
            let spawned = posix_spawn(&pid, "/bin/sh", nil, &attributes, &argv, environ)
            guard spawned == 0 else { throw POSIXError(POSIXErrorCode(rawValue: spawned) ?? .EIO) }
            return pid
        }
        let termination = try wait(for: pid)
        if let number = stopGuard.caught { _exit(abandon(file, child: 0, signal: number)) }
        return termination
    }

    /// For SIGTERM and SIGHUP while the editor runs: passes the signal on to the editor, removes the temporary
    /// file and returns noteit's exit status, 128 + signal.
    static func abandon(_ file: URL, child: pid_t, signal: Int32) -> Int32 {
        if child > 0 { kill(child, signal) }
        try? FileManager.default.removeItem(at: file)
        return 128 + signal
    }

    /// Catches SIGTERM and SIGHUP from before the editor starts until it has finished. SIGINT and SIGQUIT need
    /// no handler: noteit ignores them, and an editor they kill is handled in `runEditor`.
    final class StopSignalGuard: @unchecked Sendable {
        static let signals = [SIGTERM, SIGHUP]

        private let lock = NSLock()
        private var pid: pid_t = 0
        private var caughtSignal: Int32?
        private var sources: [DispatchSourceSignal] = []
        private var previous: [(Int32, sig_t?)] = []

        /// Runs the spawn holding the lock the handlers take, so a SIGTERM or SIGHUP that arrives meanwhile waits
        /// for the pid and still reaches the editor. Masking the signals wouldn't help: a dispatch signal source
        /// fires when the signal is sent, whatever the thread masks are.
        func recordChild(_ spawn: () throws -> pid_t) rethrows -> pid_t {
            lock.lock()
            defer { lock.unlock() }
            pid = try spawn()
            return pid
        }

        /// Set before the editor is signalled, so the waiting thread, woken by its exit, leaves the same way.
        var caught: Int32? { lock.withLock { caughtSignal } }

        init(file: URL, stop: @escaping @Sendable (Int32) -> Void = { _exit($0) }) {
            for number in Self.signals {
                let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
                source.setEventHandler { [unowned self] in
                    let child = self.lock.withLock {
                        self.caughtSignal = number
                        return self.pid
                    }
                    stop(CLIEditor.abandon(file, child: child, signal: number))
                }
                source.resume()
                sources.append(source)
                previous.append((number, signal(number, SIG_IGN)))
            }
        }

        func cancel() {
            for (number, handler) in previous { signal(number, handler) }
            sources.forEach { $0.cancel() }
        }
    }

    static func wait(for pid: pid_t) throws -> Termination {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            guard errno == EINTR else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECHILD) }
        }
        let signal = status & 0x7f
        return signal == 0 ? .exited((status >> 8) & 0xff) : .signaled(signal)
    }
}
