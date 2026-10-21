import Foundation
import NoteItAPI
import XCTest

final class AppLocatorTests: XCTestCase {
    private let apiURL = URL(string: "http://127.0.0.1:47600/v1")!

    private func discovery(enabled: Bool) -> DiscoveryFile {
        DiscoveryFile(pid: 1, appVersion: "1.0", apiEnabled: enabled, port: enabled ? 47600 : nil,
                      baseURL: enabled ? apiURL : nil, startedAt: Date())
    }

    private final class Probe: @unchecked Sendable {
        let lock = NSLock()
        var launches = 0
        var sleeps: [Duration] = []
        var pings = 0
        var file: DiscoveryFile?
        var pingResult = true

        func with<T>(_ body: (Probe) -> T) -> T { lock.withLock { body(self) } }
    }

    private func locator(_ probe: Probe, environment: [String: String] = [:],
                         onLaunch: @escaping @Sendable (Probe) -> Void = { _ in }) -> AppLocator {
        AppLocator(
            environment: environment,
            readDiscovery: { probe.with { $0.file } },
            launchApp: {
                probe.with { $0.launches += 1 }
                onLaunch(probe)
            },
            ping: { _ in probe.with { $0.pings += 1; return $0.pingResult } },
            sleep: { duration in probe.with { $0.sleeps.append(duration) } }
        )
    }

    func testLocatorEnvOverride() async {
        let probe = Probe()
        let result = await locator(probe, environment: ["NOTEIT_API_URL": "http://127.0.0.1:5000"]).locate(launch: true)
        XCTAssertEqual(result, .ready(URL(string: "http://127.0.0.1:5000/v1")!))
        let withPath = await locator(probe, environment: ["NOTEIT_API_URL": "http://localhost:5000/v1/"]).locate(launch: true)
        XCTAssertEqual(withPath, .ready(URL(string: "http://localhost:5000/v1")!))
        XCTAssertEqual(probe.launches, 0)
        XCTAssertEqual(probe.pings, 0)
    }

    func testLocatorReady() async {
        let probe = Probe()
        probe.file = discovery(enabled: true)
        let result = await locator(probe).locate(launch: true)
        XCTAssertEqual(result, .ready(apiURL))
        XCTAssertEqual(probe.launches, 0)
        XCTAssertEqual(probe.pings, 1)
    }

    func testLocatorApiDisabled() async {
        let probe = Probe()
        probe.file = discovery(enabled: false)
        let result = await locator(probe).locate(launch: true)
        XCTAssertEqual(result, .apiDisabled)
        XCTAssertEqual(probe.launches, 0)
        XCTAssertEqual(probe.pings, 0)
    }

    func testLocatorLaunchesOnceAndWaits() async {
        let probe = Probe()
        let ready = discovery(enabled: true)
        let starting = discovery(enabled: false)
        let locator = AppLocator(
            environment: [:],
            readDiscovery: {
                probe.with { probe in
                    guard probe.launches > 0 else { return nil }
                    switch probe.sleeps.count {
                    case 0, 1: return nil
                    case 2: return starting
                    default: return ready
                    }
                }
            },
            launchApp: { probe.with { $0.launches += 1 } },
            ping: { _ in probe.with { $0.pings += 1; return true } },
            sleep: { duration in probe.with { $0.sleeps.append(duration) } }
        )
        let result = await locator.locate(launch: true)
        XCTAssertEqual(result, .ready(apiURL))
        XCTAssertEqual(probe.launches, 1)
        XCTAssertEqual(probe.sleeps, [.milliseconds(200), .milliseconds(200), .milliseconds(200)])

        let noLaunch = Probe()
        let notRunning = await self.locator(noLaunch).locate(launch: false)
        XCTAssertEqual(notRunning, .notRunning)
        XCTAssertEqual(noLaunch.launches, 0)
    }

    func testLocatorTimesOut() async {
        let probe = Probe()
        let result = await locator(probe).locate(launch: true, timeout: .seconds(10))
        XCTAssertEqual(result, .notRunning)
        XCTAssertEqual(probe.launches, 1)
        XCTAssertEqual(probe.sleeps.count, 50)

        let off = discovery(enabled: false)
        let on = discovery(enabled: true)
        let stillOff = Probe()
        let disabled = await locator(stillOff, onLaunch: { probe in probe.file = off })
            .locate(launch: true, timeout: .seconds(1))
        XCTAssertEqual(disabled, .apiDisabled)
        XCTAssertEqual(stillOff.sleeps.count, 5)

        let failing = Probe()
        let unreachable = await locator(failing, onLaunch: { probe in probe.file = on; probe.pingResult = false })
            .locate(launch: true, timeout: .seconds(1))
        XCTAssertEqual(unreachable, .notRunning)
        XCTAssertEqual(failing.launches, 1)
    }
}
