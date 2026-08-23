// LifecycleOwnershipTests.swift
// Verifies deterministic release of manager-owned dispatch sources, listeners,
// and the subprocess/pipe resources used to classify dashboard ports.

import XCTest
import Dispatch
@testable import ForgeConductorCore

final class LifecycleOwnershipTests: XCTestCase {
    func testManagerRuntimeCancelsOwnedDispatchSources() {
        let runtime = ManagerRuntime()
        let queue = DispatchQueue(label: "forge.tests.lifecycle")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 60)
        timer.setEventHandler {}
        timer.resume()

        let signalSource = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: queue)
        signalSource.setEventHandler {}
        signalSource.resume()

        runtime.watchdog = timer
        runtime.signalSources = [signalSource]

        runtime.cancelWatchdog()
        runtime.cancelSignalSources()

        XCTAssertNil(runtime.watchdog)
        XCTAssertTrue(runtime.signalSources.isEmpty)
    }

    func testManagerOwnerReleasesListenerAcrossTenCycles() throws {
        for cycle in 0..<10 {
            let home = FileManager.default.temporaryDirectory
                .appendingPathComponent("forge-lifecycle-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: home) }

            let port = 40_000 + cycle
            weak var releasedNode: ManagerNode?
            do {
                let app = try ForgeApp.bootstrap(home: home)
                try app.config.update([
                    "dashboard": ["port": port] as [String: Any],
                ], save: true)
                let node = ManagerNode(app: app)
                releasedNode = node
                _ = try node.startService()
                XCTAssertTrue(node.isServiceActive())
            }

            XCTAssertNil(releasedNode, "manager owner survived cycle \(cycle)")
            assertPortReleased(port, cycle: cycle)
        }
    }

    func testPortInspectionProcessAndPipeCompleteTenCycles() {
        for cycle in 0..<10 {
            let state = DashboardPortGuard.inspect(
                host: "127.0.0.1",
                port: 50_000 + cycle
            )
            switch state {
            case .free, .unknown:
                break
            default:
                XCTFail("unexpected occupied test port in cycle \(cycle): \(state)")
            }
        }
    }

    private func assertPortReleased(_ port: Int, cycle: Int) {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let state = DashboardPortGuard.inspect(host: "127.0.0.1", port: port)
            switch state {
            case .free, .unknown:
                return
            default:
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        XCTFail("dashboard listener survived manager release in cycle \(cycle)")
    }
}
