import Combine
import Foundation
import Sparkle

/// In-app updates through Sparkle. Only active in a real app bundle that has a feed URL and public key,
/// so `swift run`, tests and debug builds never start an updater.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    let isEnabled: Bool
    @Published private(set) var canCheckForUpdates = false

    private let controller: SPUStandardUpdaterController?
    private var cancellable: AnyCancellable?

    private init() {
        isEnabled = Self.isUpdatingSupported(bundleURL: Bundle.main.bundleURL, info: Bundle.main.infoDictionary)
        guard isEnabled else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        cancellable = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.canCheckForUpdates = value }
    }

    nonisolated static func isUpdatingSupported(bundleURL: URL, info: [String: Any]?) -> Bool {
        guard bundleURL.pathExtension == "app", let info else { return false }
        func hasValue(_ key: String) -> Bool {
            guard let value = info[key] as? String else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return hasValue("SUFeedURL") && hasValue("SUPublicEDKey")
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            objectWillChange.send()
            controller?.updater.automaticallyChecksForUpdates = newValue
        }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
