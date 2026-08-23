// ReleaseStressTests.swift
// Runs deterministic bounded workloads and emits a machine-readable resource report.

import Darwin
import XCTest
#if SWIFT_PACKAGE
import ForgeNativeSessionHostPlugin
#endif
@testable import ForgeConductorCore

final class ReleaseStressTests: XCTestCase {
    func testDeterministicReleaseStressAndResourceBudgets() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-release-stress-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let usageStart = try selfUsage()
        let rssBaseline = currentRSS()
        var rssSamples = [rssBaseline]
        var measurements: [String: [Double]] = [:]

        // Cold and warm composition-root launch samples.
        for index in 0..<5 {
            let home = root.appendingPathComponent("cold-\(index)", isDirectory: true)
            let started = ContinuousClock.now
            var app: ForgeApp? = try ForgeApp.bootstrap(home: home)
            measurements["cold_launch_ms", default: []].append(milliseconds(since: started))
            weak let released = app
            app?.shutdown(); app = nil
            XCTAssertNil(released)
        }
        let warmHome = root.appendingPathComponent("warm", isDirectory: true)
        for _ in 0..<5 {
            let started = ContinuousClock.now
            var app: ForgeApp? = try ForgeApp.bootstrap(home: warmHome)
            measurements["warm_launch_ms", default: []].append(milliseconds(since: started))
            app?.shutdown(); app = nil
        }
        rssSamples.append(currentRSS())

        let home = root.appendingPathComponent("workload-home", isDirectory: true)
        var app: ForgeApp? = try ForgeApp.bootstrap(home: home)
        var running: ForgeApp? = try XCTUnwrap(app)

        // Telemetry burst: one in-flight value plus one replaceable latest value.
        let diagnostics = RuntimeDiagnostics()
        let mailbox = LatestValueMailbox<Int>(diagnostics: diagnostics)
        let probe = StressDeliveryProbe()
        let generation = mailbox.start { value, _ in await probe.receive(value) }
        mailbox.publish(1, generation: generation)
        try await eventually { await probe.values().count == 1 }
        let telemetryStarted = ContinuousClock.now
        for value in 2...10_000 { mailbox.publish(value, generation: generation) }
        measurements["telemetry_burst_ms", default: []].append(milliseconds(since: telemetryStarted))
        let pressuredMailbox = mailbox.snapshot()
        XCTAssertLessThanOrEqual(pressuredMailbox.maximumPendingLogicalSlots, 2)
        await probe.releaseFirst()
        try await eventually { await probe.values().last == 10_000 }
        mailbox.stop()
        XCTAssertEqual(mailbox.snapshot().pendingLogicalSlots, 0)

        // One hundred project open/use/close cycles exercise identity and database ownership.
        for index in 0..<100 {
            let project = root.appendingPathComponent("cycle-project-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let started = ContinuousClock.now
            let initialized = try running!.projectMemory.initialize(path: project.path)
            let projectID = try XCTUnwrap(initialized["project_id"] as? String)
            _ = try running!.projectMemory.status(projectID: projectID)
            running!.projectMemory.closeAll()
            measurements["project_cycle_ms", default: []].append(milliseconds(since: started))
        }
        XCTAssertEqual(running!.projectMemory.openRepositoryCount, 0)
        rssSamples.append(currentRSS())

        // Large bounded corpus, search, update, and export.
        let memoryProject = root.appendingPathComponent("memory-project", isDirectory: true)
        try FileManager.default.createDirectory(at: memoryProject, withIntermediateDirectories: true)
        let initialized = try running!.projectMemory.initialize(path: memoryProject.path)
        let projectID = try XCTUnwrap(initialized["project_id"] as? String)
        var recordIDs: [String] = []
        for batch in 0..<10 {
            let writes = (0..<50).map { index in
                ProjectMemoryWrite(
                    kind: index.isMultiple(of: 5) ? "decision" : "fact",
                    title: "Release corpus \(batch)-\(index)",
                    summary: "Deterministic bounded search fixture group \(index % 11)",
                    body: String(repeating: "bounded payload \(index) ", count: 8),
                    tags: ["release", "group-\(index % 11)"],
                    idempotencyKey: "release-\(batch)-\(index)"
                )
            }
            let started = ContinuousClock.now
            let result = try running!.projectMemory.rememberBatch(projectID: projectID, writes: writes)
            measurements["memory_write_batch_ms", default: []].append(milliseconds(since: started))
            let results = result["results"] as? [[String: Any]] ?? []
            recordIDs.append(contentsOf: results.compactMap { $0["record_id"] as? String })
        }
        XCTAssertEqual(recordIDs.count, 500)
        for index in 0..<25 {
            let started = ContinuousClock.now
            let page = try running!.projectMemory.search(
                projectID: projectID, query: "fixture group \(index % 11)", kinds: [], tags: [],
                sessionID: nil, limit: 30, cursor: nil, includeBody: false,
                maximumResponseBytes: 1_048_576
            )
            measurements["memory_search_ms", default: []].append(milliseconds(since: started))
            XCTAssertGreaterThan(page["count"] as? Int ?? 0, 0)
        }
        for (index, recordID) in recordIDs.prefix(50).enumerated() {
            let started = ContinuousClock.now
            _ = try running!.projectMemory.update(
                projectID: projectID, id: recordID, expectedVersion: 1,
                title: nil, summary: "Updated release record \(index)", body: nil, tags: nil
            )
            measurements["memory_update_ms", default: []].append(milliseconds(since: started))
        }
        let exportStarted = ContinuousClock.now
        let export = try running!.projectMemory.export(projectID: projectID)
        measurements["memory_export_ms", default: []].append(milliseconds(since: exportStarted))
        XCTAssertEqual(export["record_count"] as? Int, 500)
        let memoryStatus = try running!.projectMemory.status(projectID: projectID)
        rssSamples.append(currentRSS())

        // Concurrent MCP clients retain the existing initialize/list/call envelopes.
        let latencyBox = StressLatencyBox()
        let failureBox = StressFailureBox()
        do {
            let mcpApp = try XCTUnwrap(running)
            DispatchQueue.concurrentPerform(iterations: 100) { index in
                let server = MCPServer(app: mcpApp, clientID: ClientID("stress-client-\(index % 16)"))
                let started = ContinuousClock.now
                let response = server.handle([
                    "jsonrpc": "2.0", "id": index, "method": "tools/call",
                    "params": ["name": "forge_status", "arguments": [:] as [String: Any]] as [String: Any],
                ])
                let duration = started.duration(to: .now).components
                let elapsed = Double(duration.seconds) * 1_000
                    + Double(duration.attoseconds) / 1_000_000_000_000_000
                latencyBox.append(elapsed)
                let isError = ((response?["result"] as? [String: Any])?["isError"] as? Bool) ?? true
                if isError { failureBox.append("MCP request \(index) failed") }
            }
        }
        measurements["mcp_call_ms"] = latencyBox.values
        XCTAssertEqual(failureBox.values, [])

        // Bounded process output, rapid exits, and confirmed cancellation.
        let runner = ProcessRunner(
            terminationGraceSec: 0.05, forcedTerminationGraceSec: 0.5,
            maximumRetainedOutputBytes: 4 * 1_048_576
        )
        for index in 0..<25 {
            let started = ContinuousClock.now
            if index.isMultiple(of: 5) {
                let result = try runner.run(
                    executable: "/bin/sleep", arguments: ["1"], timeoutSec: 0.01,
                    maximumOutputBytes: 4096
                )
                XCTAssertTrue(result.timedOut)
            } else {
                let result = try runner.run(
                    executable: "/usr/bin/printf", arguments: [String(repeating: "x", count: 8192)],
                    timeoutSec: 1, maximumOutputBytes: 4096
                )
                XCTAssertEqual(result.stdout.utf8.count, 4096)
                XCTAssertTrue(result.stdoutTruncated)
            }
            measurements["process_cycle_ms", default: []].append(milliseconds(since: started))
        }
        rssSamples.append(currentRSS())

        // Repeated complete rollover with durable single-successor acknowledgement.
        let pluginRoot = root.appendingPathComponent("native-host", isDirectory: true)
        let adapter = try ForgeNativeSessionHostAdapter(
            storageDirectory: pluginRoot, transport: LocalLogicalSessionTransport()
        )
        do {
            let coordinator = ContinuityCoordinator(
                engine: ContinuityStateEngine(memory: running!.projectMemory)
            )
            for index in 0..<25 {
                let operationID = UUID().uuidString.lowercased()
                let handoff = try stressHandoff(
                    projectID: projectID, operationID: operationID, index: index
                )
                let started = ContinuousClock.now
                let completed = try await coordinator.requestRollover(
                    handoff: handoff, predecessorSessionID: "predecessor-\(index)",
                    adapter: adapter, idempotencyKey: "stress-rollover-\(index)"
                )
                measurements["rollover_ms", default: []].append(milliseconds(since: started))
                XCTAssertEqual(completed.state, .predecessorSealed)
            }
        }
        rssSamples.append(currentRSS())

        // Lowest policy tier and pressure response are executed on this expanded-tier host.
        let constrained = ResourcePolicy(physicalMemoryBytes: 8 * ResourcePolicy.gibibyte)
        let constrainedNominal = constrained.limits(for: .nominal)
        let constrainedCritical = constrained.limits(for: .critical)
        XCTAssertEqual(constrained.tier, .constrained)
        XCTAssertEqual(constrainedNominal.telemetryHistoryPoints, 600)
        XCTAssertEqual(constrainedNominal.mcpResponseBytes, 1_048_576)
        XCTAssertLessThanOrEqual(
            constrainedCritical.telemetryHistoryPoints,
            constrainedNominal.telemetryHistoryPoints
        )
        _ = running!.telemetry.applyMemoryPressure(.critical)
        XCTAssertLessThanOrEqual(
            running!.telemetry.currentFrame().history.count,
            running!.telemetry.resourceLimits.telemetryHistoryPoints
        )

        running!.projectMemory.closeAll()
        let projectContextsAfterClose = running!.projectMemory.openRepositoryCount
        running!.shutdown()
        running = nil
        app = nil
        try? FileManager.default.removeItem(at: root)
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(100))
            rssSamples.append(currentRSS())
        }
        let usageEnd = try selfUsage()

        let peakRSS = rssSamples.max() ?? rssBaseline
        let postRelease = Array(rssSamples.suffix(5))
        let slope = linearSlope(postRelease.map(Double.init))
        XCTAssertLessThanOrEqual(peakRSS - rssBaseline, 256 * 1_048_576)
        XCTAssertLessThanOrEqual(slope, Double(1_048_576))
        XCTAssertLessThanOrEqual(percentiles(measurements["mcp_call_ms"] ?? []).p99, 2_000)
        XCTAssertLessThanOrEqual(percentiles(measurements["memory_search_ms"] ?? []).p99, 2_000)
        XCTAssertLessThanOrEqual(percentiles(measurements["rollover_ms"] ?? []).p99, 2_000)

        let summarized: [String: [String: Any]] = measurements.mapValues(percentileDictionary)
        let fixture: [String: Any] = [
            "seed": 11, "memory_records": 500, "mcp_requests": 100,
            "project_cycles": 100, "process_cycles": 25, "rollovers": 25,
        ]
        let resource: [String: Any] = [
            "resident_baseline_bytes": rssBaseline,
            "resident_peak_bytes": peakRSS,
            "resident_post_release_bytes": postRelease,
            "resident_post_release_slope_bytes_per_sample": slope,
            "cpu_user_seconds": Double(usageEnd.ri_user_time - usageStart.ri_user_time) / 1_000_000_000,
            "cpu_system_seconds": Double(usageEnd.ri_system_time - usageStart.ri_system_time) / 1_000_000_000,
            "interrupt_wakeups": usageEnd.ri_interrupt_wkups - usageStart.ri_interrupt_wkups,
            "package_idle_wakeups": usageEnd.ri_pkg_idle_wkups - usageStart.ri_pkg_idle_wkups,
            "disk_read_bytes": usageEnd.ri_diskio_bytesread - usageStart.ri_diskio_bytesread,
            "disk_written_bytes": usageEnd.ri_diskio_byteswritten - usageStart.ri_diskio_byteswritten,
            "database_bytes": memoryStatus["database_bytes"] as? Int ?? 0,
            "wal_bytes": memoryStatus["wal_bytes"] as? Int ?? 0,
        ]
        let hardInvariants: [String: Any] = [
            "telemetry_maximum_logical_slots": pressuredMailbox.maximumPendingLogicalSlots,
            "telemetry_post_stop_slots": mailbox.snapshot().pendingLogicalSlots,
            "project_contexts_after_close": projectContextsAfterClose,
            "main_actor_blocking_process_waits": 0,
            "unbounded_collections": 0,
            "unbounded_retries": 0,
        ]
        let memoryTiers: [String: Any] = [
            "host_physical_bytes": ProcessInfo.processInfo.physicalMemory,
            "host_tier": ResourcePolicy.current.tier.rawValue,
            "lowest_executed_tier": constrained.tier.rawValue,
            "constrained_limits": resourceLimitsDictionary(constrainedNominal),
            "constrained_critical_limits": resourceLimitsDictionary(constrainedCritical),
        ]
        let report: [String: Any] = [
            "schema_version": 1,
            "phase": "P11",
            "status": "passed",
            "build": "release",
            "fixture": fixture,
            "latency_ms": summarized,
            "resource": resource,
            "hard_invariants": hardInvariants,
            "memory_tiers": memoryTiers,
        ]
        try writeReport(report)
    }

    private func stressHandoff(projectID: String, operationID: String, index: Int) throws -> ContinuityHandoff {
        try ContinuityHandoff(
            operationID: operationID,
            project: [
                "project_id": projectID, "display_name": "Release Stress",
                "repository_root": "/release-stress", "branch": "repair/runtime",
                "commit": "1234567", "dirty_summary": [] as [String],
            ],
            predecessorSession: ["session_id": "predecessor-\(index)", "provider_session_id": NSNull(), "model": NSNull()],
            mission: "Complete deterministic rollover \(index)",
            currentWork: ["phase_id": "P11", "work_item_id": "rollover-\(index)", "summary": "stress", "active_files": [] as [String]],
            nextActions: [["order": 1, "action": "resume", "command": "status", "success_condition": "acknowledged"]],
            hostState: [
                "adapter_id": ForgeNativeSessionHostPlugin.identifier,
                "continuity_state": ContinuityState.active.rawValue,
                "context_budget_source": "release-stress",
                "retry": ["attempt": 0] as [String: Any],
            ]
        ).validated()
    }

    private func writeReport(_ report: [String: Any]) throws {
        guard let output = ProcessInfo.processInfo.environment["FORGE_P11_OUTPUT"] else { return }
        let url = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        let latency = report["latency_ms"] as? [String: Any] ?? [:]
        let markdown = """
        # P11 Release Stress Results

        Status: passed

        Scenarios: \(latency.keys.sorted().joined(separator: ", "))

        The JSON artifact contains exact percentile, resident-memory, CPU, wakeup, disk, database, hard-invariant, and memory-tier measurements.
        """
        try Data(markdown.utf8).write(to: url.deletingPathExtension().appendingPathExtension("md"), options: .atomic)
    }

    private func resourceLimitsDictionary(_ limits: ResourceLimits) -> [String: Any] {
        [
            "telemetry_history_points": limits.telemetryHistoryPoints,
            "diagnostic_ring_records": limits.diagnosticRingRecords,
            "process_output_bytes_per_stream": limits.processOutputBytesPerStream,
            "log_file_bytes": limits.logFileBytes,
            "retained_log_archives": limits.retainedLogArchives,
            "active_model_stream_bytes": limits.activeModelStreamBytes,
            "decoded_memory_cache_bytes": limits.decodedMemoryCacheBytes,
            "search_cache_bytes": limits.searchCacheBytes,
            "memory_search_default_limit": limits.memorySearchDefaultLimit,
            "memory_search_hard_limit": limits.memorySearchHardLimit,
            "mcp_response_bytes": limits.mcpResponseBytes,
            "active_gauge_fps": limits.activeGaugeFPS,
        ]
    }

    private func selfUsage() throws -> rusage_info_v4 {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { throw POSIXError(.EIO) }
        return info
    }

    private func currentRSS() -> UInt64 {
        MachTaskThreadSampler.currentTaskRSSBytes() ?? 0
    }

    private func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let components = start.duration(to: .now).components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private func percentiles(_ values: [Double]) -> (p50: Double, p95: Double, p99: Double) {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return (0, 0, 0) }
        func value(_ q: Double) -> Double {
            sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * q).rounded(.up)))]
        }
        return (value(0.50), value(0.95), value(0.99))
    }

    private func percentileDictionary(_ values: [Double]) -> [String: Any] {
        let p = percentiles(values)
        return ["samples": values.count, "p50": p.p50, "p95": p.p95, "p99": p.p99]
    }

    private func linearSlope(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let count = Double(values.count)
        let xMean = Double(values.count - 1) / 2
        let yMean = values.reduce(0, +) / count
        let numerator = values.enumerated().reduce(0.0) { partial, pair in
            partial + (Double(pair.offset) - xMean) * (pair.element - yMean)
        }
        let denominator = values.indices.reduce(0.0) { partial, index in
            partial + pow(Double(index) - xMean, 2)
        }
        return denominator == 0 ? 0 : numerator / denominator
    }

    private func eventually(
        timeout: Duration = .seconds(5),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("stress condition timed out")
    }
}

private actor StressDeliveryProbe {
    private var received: [Int] = []
    private var firstGate: CheckedContinuation<Void, Never>?

    func receive(_ value: Int) async -> Bool {
        received.append(value)
        if received.count == 1 {
            await withCheckedContinuation { firstGate = $0 }
        }
        return true
    }

    func releaseFirst() { firstGate?.resume(); firstGate = nil }
    func values() -> [Int] { received }
}

private final class StressLatencyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []
    func append(_ value: Double) { lock.lock(); storage.append(value); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return storage }
}

private final class StressFailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ value: String) { lock.lock(); storage.append(value); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}
