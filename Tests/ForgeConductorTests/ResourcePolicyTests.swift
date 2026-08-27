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
        let highCapacity = ResourcePolicy(
            physicalMemoryBytes: 32 * ResourcePolicy.gibibyte + 1
        )

        XCTAssertEqual(constrained.tier, .constrained)
        XCTAssertEqual(standard.tier, .standard)
        XCTAssertEqual(expanded.tier, .expanded)
        XCTAssertEqual(highCapacity.tier, .highCapacity)
        XCTAssertEqual(constrained.nominalLimits.telemetryHistoryPoints, 600)
        XCTAssertEqual(standard.nominalLimits.processOutputBytesPerStream, 8 * 1_048_576)
        XCTAssertEqual(expanded.nominalLimits.mcpResponseBytes, 4 * 1_048_576)
        XCTAssertEqual(constrained.nominalExecutionLimits.maximumActiveManagedGenerations, 1)
        XCTAssertEqual(constrained.nominalExecutionLimits.maximumActiveRuntimeJobs, 2)
        XCTAssertEqual(constrained.nominalExecutionLimits.maximumCPUHeavyRuntimeJobs, 1)
        XCTAssertEqual(constrained.nominalExecutionLimits.maximumInMemoryEvents, 1_000)
        XCTAssertEqual(standard.nominalExecutionLimits.maximumActiveManagedGenerations, 1)
        XCTAssertEqual(standard.nominalExecutionLimits.maximumActiveRuntimeJobs, 2)
        XCTAssertEqual(standard.nominalExecutionLimits.maximumInMemoryEvents, 2_500)
        XCTAssertEqual(expanded.nominalExecutionLimits.maximumActiveManagedGenerations, 2)
        XCTAssertEqual(expanded.nominalExecutionLimits.maximumActiveRuntimeJobs, 4)
        XCTAssertEqual(expanded.nominalExecutionLimits.maximumInMemoryEvents, 5_000)
        XCTAssertEqual(highCapacity.nominalExecutionLimits.maximumActiveManagedGenerations, 2)
        XCTAssertEqual(highCapacity.nominalExecutionLimits.maximumActiveRuntimeJobs, 6)
        XCTAssertEqual(highCapacity.nominalExecutionLimits.maximumInMemoryEvents, 10_000)
    }

    func testEveryPhysicalMemoryBoundarySelectsTheConservativeTier() {
        let gibibyte = ResourcePolicy.gibibyte
        XCTAssertEqual(ResourcePolicy(physicalMemoryBytes: 8 * gibibyte).tier, .constrained)
        XCTAssertEqual(ResourcePolicy(physicalMemoryBytes: 8 * gibibyte + 1).tier, .standard)
        XCTAssertEqual(ResourcePolicy(physicalMemoryBytes: 16 * gibibyte).tier, .standard)
        XCTAssertEqual(ResourcePolicy(physicalMemoryBytes: 16 * gibibyte + 1).tier, .expanded)
        XCTAssertEqual(ResourcePolicy(physicalMemoryBytes: 32 * gibibyte).tier, .expanded)
        XCTAssertEqual(ResourcePolicy(physicalMemoryBytes: 32 * gibibyte + 1).tier, .highCapacity)
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

    func testExecutionAndModelCeilingsAreBoundedAndTightenUnderPressure() {
        for tierMemory in [
            8 * ResourcePolicy.gibibyte,
            16 * ResourcePolicy.gibibyte,
            32 * ResourcePolicy.gibibyte,
            64 * ResourcePolicy.gibibyte,
        ] {
            let policy = ResourcePolicy(physicalMemoryBytes: tierMemory)
            let nominal = policy.executionLimits(for: .nominal)
            let warning = policy.executionLimits(for: .warning)
            let critical = policy.executionLimits(for: .critical)

            XCTAssertEqual(nominal, policy.nominalExecutionLimits)
            XCTAssertGreaterThanOrEqual(critical.maximumActiveManagedGenerations, 1)
            XCTAssertGreaterThanOrEqual(critical.maximumActiveRuntimeJobs, 1)
            XCTAssertGreaterThanOrEqual(critical.maximumCPUHeavyRuntimeJobs, 1)
            XCTAssertLessThanOrEqual(
                critical.maximumCPUHeavyRuntimeJobs,
                critical.maximumActiveRuntimeJobs
            )
            XCTAssertLessThanOrEqual(
                warning.maximumActiveManagedGenerations,
                nominal.maximumActiveManagedGenerations
            )
            XCTAssertLessThanOrEqual(
                critical.maximumActiveRuntimeJobs,
                warning.maximumActiveRuntimeJobs
            )
            XCTAssertLessThanOrEqual(
                critical.maximumInMemoryEvents,
                warning.maximumInMemoryEvents
            )
            XCTAssertLessThanOrEqual(
                critical.modelPolicy.maximumLoadedInstances,
                warning.modelPolicy.maximumLoadedInstances
            )
            XCTAssertLessThanOrEqual(
                warning.modelPolicy.maximumParallelRequests,
                nominal.modelPolicy.maximumParallelRequests
            )
            XCTAssertLessThanOrEqual(
                nominal.modelPolicy.defaultLoadedInstances,
                nominal.modelPolicy.maximumLoadedInstances
            )
            XCTAssertTrue(nominal.modelPolicy.jitLoadingRequired)
            XCTAssertTrue(nominal.modelPolicy.autoEvictRequired)
            XCTAssertTrue(critical.modelPolicy.serializeSuccessorCreation)
        }
    }

    func testRuntimeJobAdmissionMatchesTheResolvedHostTier() {
        let policy = ResourcePolicy.current.nominalExecutionLimits
        let runtime = RuntimeJobLimits.current
        XCTAssertEqual(runtime.maximumConcurrentJobs, policy.maximumActiveRuntimeJobs)
        XCTAssertEqual(runtime.maximumCPUHeavyJobs, policy.maximumCPUHeavyRuntimeJobs)
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

    func testSubscriberCapsAndBackgroundRefreshQuiesceAfterRemovalAndStop() throws {
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
        XCTAssertEqual(app.telemetry.listenerCount, 0)
        XCTAssertEqual(concreteEngine.listenerCount, 0)

        app.telemetry.startBackgroundRefresh(intervalSec: 0.25)
        XCTAssertTrue(app.telemetry.realtimeEngine.isRunning)
        XCTAssertEqual(concreteEngine.listenerCount, 1)
        app.telemetry.stopBackgroundRefresh()
        XCTAssertFalse(app.telemetry.realtimeEngine.isRunning)
        XCTAssertEqual(concreteEngine.listenerCount, 0)

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
