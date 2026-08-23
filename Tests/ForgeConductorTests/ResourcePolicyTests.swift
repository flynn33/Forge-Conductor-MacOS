// ResourcePolicyTests.swift
// Verifies absolute tier ceilings, pressure reductions, bounded diagnostic rotation,
// and release of repeated application/session composition roots.

import XCTest
@testable import ForgeConductorCore

final class ResourcePolicyTests: XCTestCase {
    func testPhysicalMemoryTiersMatchDeclaredAbsoluteCeilings() {
        let constrained = ResourcePolicy(physicalMemoryBytes: 8 * ResourcePolicy.gibibyte)
        let standard = ResourcePolicy(physicalMemoryBytes: 16 * ResourcePolicy.gibibyte)
        let expanded = ResourcePolicy(physicalMemoryBytes: 32 * ResourcePolicy.gibibyte)

        XCTAssertEqual(constrained.tier, .constrained)
        XCTAssertEqual(standard.tier, .standard)
        XCTAssertEqual(expanded.tier, .expanded)
        XCTAssertEqual(constrained.nominalLimits.telemetryHistoryPoints, 600)
        XCTAssertEqual(standard.nominalLimits.processOutputBytesPerStream, 8 * 1_048_576)
        XCTAssertEqual(expanded.nominalLimits.mcpResponseBytes, 4 * 1_048_576)
    }

    func testMemoryPressureOnlyReducesOptionalRetention() {
        for tierMemory in [
            8 * ResourcePolicy.gibibyte,
            16 * ResourcePolicy.gibibyte,
            32 * ResourcePolicy.gibibyte,
        ] {
            let policy = ResourcePolicy(physicalMemoryBytes: tierMemory)
            let nominal = policy.limits(for: .nominal)
            let warning = policy.limits(for: .warning)
            let critical = policy.limits(for: .critical)

            XCTAssertLessThanOrEqual(warning.telemetryHistoryPoints, nominal.telemetryHistoryPoints)
            XCTAssertLessThanOrEqual(critical.telemetryHistoryPoints, warning.telemetryHistoryPoints)
            XCTAssertLessThanOrEqual(critical.searchCacheBytes, warning.searchCacheBytes)
            XCTAssertGreaterThanOrEqual(critical.mcpResponseBytes, 262_144)
            XCTAssertGreaterThanOrEqual(critical.activeGaugeFPS, 15)
        }
    }

    func testTelemetryPressureUpdatesEnforcedCapacity() throws {
        let home = temporaryHome("telemetry-pressure")
        defer { try? FileManager.default.removeItem(at: home) }
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }

        let nominal = app.telemetry.resourceLimits.telemetryHistoryPoints
        _ = app.telemetry.applyMemoryPressure(.critical)
        let critical = app.telemetry.resourceLimits.telemetryHistoryPoints
        XCTAssertLessThanOrEqual(critical, nominal)
        XCTAssertLessThanOrEqual(app.telemetry.currentFrame().history.count, critical)
    }

    func testDiagnosticRingAndEveryDurableRoleLogRotateWithinLimits() throws {
        let home = temporaryHome("diagnostic-bounds")
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = AppPaths(home: home)
        try paths.ensureLayout()
        let log = DiagnosticLog(
            paths: paths,
            ringLimit: 5,
            maximumLogBytes: 512,
            retainedArchives: 2
        )

        for index in 0..<80 {
            log.log(DiagnosticRecord(
                event: "agent_pressure_\(index)",
                severity: .warn,
                category: .agent,
                fields: ["detail": String(repeating: "x", count: 128)]
            ))
        }

        XCTAssertEqual(log.recent(limit: .max).count, 5)
        for url in [
            paths.masterDiagnostics,
            paths.toolDiagnostics,
            paths.agentDiagnostics,
            paths.failoverDiagnostics,
        ] {
            let matching = try FileManager.default.contentsOfDirectory(
                at: paths.logsDir,
                includingPropertiesForKeys: nil
            ).filter { $0.lastPathComponent == url.lastPathComponent
                || $0.lastPathComponent.hasPrefix("\(url.lastPathComponent).") }
            XCTAssertLessThanOrEqual(matching.count, 3)
            XCTAssertFalse(matching.isEmpty)
        }
    }

    func testApplicationCompositionRootReleasesAcrossTenCycles() throws {
        for cycle in 0..<10 {
            let home = temporaryHome("app-release-\(cycle)")
            var app: ForgeApp? = try ForgeApp.bootstrap(home: home)
            weak let released = app
            app?.shutdown()
            app = nil
            XCTAssertNil(released, "application owner survived cycle \(cycle)")
            try? FileManager.default.removeItem(at: home)
        }
    }

    func testSubscriberAndPerClientStateCapsAreEnforced() throws {
        let home = temporaryHome("client-caps")
        defer { try? FileManager.default.removeItem(at: home) }
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }

        var telemetryIDs: [UUID] = []
        var engineIDs: [UUID] = []
        for _ in 0..<200 {
            telemetryIDs.append(app.telemetry.addListener { _ in })
            engineIDs.append(app.telemetry.realtimeEngine.addListener { _ in })
        }
        XCTAssertEqual(app.telemetry.listenerCount, TelemetryService.maximumListeners)
        let concreteEngine = try XCTUnwrap(app.telemetry.realtimeEngine as? RealtimeMetricsEngine)
        XCTAssertEqual(concreteEngine.listenerCount, RealtimeMetricsEngine.maximumListeners)
        for id in telemetryIDs { app.telemetry.removeListener(id) }
        for id in engineIDs { app.telemetry.realtimeEngine.removeListener(id) }

        for index in 0..<300 {
            let client = ClientID("client-\(index)")
            _ = try app.tools.call(name: "missing_tool", arguments: [:], clientID: client)
            app.continuityAutomation.adopt(
                clientID: client,
                paths: (0..<20).map { "/tmp/project-\(index)/path-\($0)" }
            )
        }
        XCTAssertEqual(app.tools.trackedClientCount, ToolRouter.maxTrackedClients)
        XCTAssertEqual(
            app.continuityAutomation.trackedClientCount,
            ContinuityAutomation.maxTrackedClients
        )
        let roots = app.continuityAutomation.snapshot(for: ClientID("client-299"))["implicit_roots"]
            as? [String] ?? []
        XCTAssertLessThanOrEqual(roots.count, ContinuityAutomation.maxImplicitRootsPerClient)
    }

    private func temporaryHome(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-\(label)-\(UUID().uuidString)", isDirectory: true)
    }
}
