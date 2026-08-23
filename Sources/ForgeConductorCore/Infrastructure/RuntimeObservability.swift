// RuntimeObservability.swift
// What: Defines bounded diagnostic counters, gauges, snapshots, and signposts.
// How: Fixed-key storage under one lock records only numeric operational state.
// Why: Queue, lifecycle, and resource behavior must be measurable without retaining payloads.

import Foundation
import os

public enum RuntimeCounter: String, CaseIterable, Sendable {
    case telemetryEventsProduced = "telemetry.events.produced"
    case telemetrySnapshotsPublished = "telemetry.snapshots.published"
    case telemetryPresentationEnqueued = "telemetry.presentation.enqueued"
    case telemetrySnapshotsDelivered = "telemetry.snapshots.delivered"
    case telemetrySnapshotsReplaced = "telemetry.snapshots.replaced"
    case telemetrySnapshotsDropped = "telemetry.snapshots.dropped"
    case telemetrySnapshotsStale = "telemetry.snapshots.stale"
    case telemetryPostStopDeliveries = "telemetry.snapshots.post_stop"
    case gaugeDraws = "gauge.draws"
    case gaugeCommandQueuesCreated = "gauge.command_queues.created"
    case gaugePipelinesCreated = "gauge.pipelines.created"
    case gaugeBuffersCreated = "gauge.buffers.created"
    case gaugeDrawsSkippedHidden = "gauge.draws.skipped_hidden"
    case gaugeDrawsSkippedStatic = "gauge.draws.skipped_static"
    case processLaunches = "process.launches"
    case processExits = "process.exits"
    case memoryWrites = "memory.writes"
    case memorySearches = "memory.searches"
    case continuityCheckpoints = "continuity.checkpoints"
    case continuityHandoffs = "continuity.handoffs"
}

public enum RuntimeGauge: String, CaseIterable, Sendable {
    case telemetryLogicalQueueDepth = "telemetry.queue.depth"
    case telemetryMaximumQueueDepth = "telemetry.queue.maximum"
    case telemetryHistorySize = "telemetry.history.size"
    case telemetryListenerCount = "telemetry.listeners"
    case gaugeVisibleSurfaces = "gauge.surfaces.visible"
    case gaugeActiveSurfaces = "gauge.surfaces.active"
    case gaugeBufferCapacityBytes = "gauge.buffer.capacity_bytes"
    case activeLongLivedTasks = "lifecycle.tasks.active"
    case activeSubscriptions = "lifecycle.subscriptions.active"
    case childProcesses = "lifecycle.child_processes"
    case processReaders = "lifecycle.process_readers"
    case openProjectContexts = "lifecycle.projects.open"
    case openDatabases = "memory.databases.open"
    case memoryRecordCount = "memory.records"
    case memoryDatabaseBytes = "memory.database.bytes"
    case memoryWALBytes = "memory.wal.bytes"
}

public struct RuntimeDiagnosticSnapshot: Sendable, Equatable {
    public let capturedAt: Date
    public let counters: [String: UInt64]
    public let gauges: [String: Int64]

    public func asDictionary() -> [String: Any] {
        [
            "captured_at": ISO8601.string(from: capturedAt),
            "counters": counters,
            "gauges": gauges,
        ]
    }
}

/// Fixed-cardinality runtime metrics. Values saturate instead of wrapping.
public final class RuntimeDiagnostics: @unchecked Sendable {
    public static let shared = RuntimeDiagnostics()

    private let lock = NSLock()
    private var counters: [RuntimeCounter: UInt64]
    private var gauges: [RuntimeGauge: Int64]

    public init() {
        counters = Dictionary(uniqueKeysWithValues: RuntimeCounter.allCases.map { ($0, 0) })
        gauges = Dictionary(uniqueKeysWithValues: RuntimeGauge.allCases.map { ($0, 0) })
    }

    public func increment(_ counter: RuntimeCounter, by amount: UInt64 = 1) {
        lock.lock()
        let result = (counters[counter] ?? 0).addingReportingOverflow(amount)
        counters[counter] = result.overflow ? UInt64.max : result.partialValue
        lock.unlock()
    }

    public func set(_ gauge: RuntimeGauge, to value: Int) {
        lock.lock()
        gauges[gauge] = Int64(max(0, value))
        lock.unlock()
    }

    @discardableResult
    public func adjust(_ gauge: RuntimeGauge, by delta: Int) -> Int {
        lock.lock()
        let current = gauges[gauge] ?? 0
        let proposed = current.addingReportingOverflow(Int64(delta))
        gauges[gauge] = proposed.overflow ? (delta >= 0 ? Int64.max : 0) : max(0, proposed.partialValue)
        let value = gauges[gauge] ?? 0
        lock.unlock()
        return Int(clamping: value)
    }

    public func recordMaximum(_ gauge: RuntimeGauge, candidate: Int) {
        lock.lock()
        gauges[gauge] = max(gauges[gauge] ?? 0, Int64(max(0, candidate)))
        lock.unlock()
    }

    public func snapshot() -> RuntimeDiagnosticSnapshot {
        lock.lock()
        let counterSnapshot = Dictionary(uniqueKeysWithValues: counters.map { ($0.key.rawValue, $0.value) })
        let gaugeSnapshot = Dictionary(uniqueKeysWithValues: gauges.map { ($0.key.rawValue, $0.value) })
        lock.unlock()
        return RuntimeDiagnosticSnapshot(
            capturedAt: Date(),
            counters: counterSnapshot,
            gauges: gaugeSnapshot
        )
    }
}

/// Stable numeric signposts. No payload, path, prompt, command, or query text is emitted.
public enum RuntimeSignposts {
    private static let telemetry = OSLog(
        subsystem: "com.forge-conductor.app",
        category: "TelemetryDelivery"
    )
    private static let process = OSLog(
        subsystem: "com.forge-conductor.app",
        category: "ProcessSupervisor"
    )
    private static let memory = OSLog(
        subsystem: "com.forge-conductor.app",
        category: "MemoryRepository"
    )

    public static func beginTelemetryPresentation(sequence: UInt64) -> OSSignpostID {
        let identifier = OSSignpostID(log: telemetry)
        os_signpost(.begin, log: telemetry, name: "AggregateToPresent", signpostID: identifier, "sequence=%llu", sequence)
        return identifier
    }

    public static func endTelemetryPresentation(_ identifier: OSSignpostID, sequence: UInt64) {
        os_signpost(.end, log: telemetry, name: "AggregateToPresent", signpostID: identifier, "sequence=%llu", sequence)
    }

    public static func processLaunch(operation: UInt64) -> OSSignpostID {
        let identifier = OSSignpostID(log: process)
        os_signpost(.begin, log: process, name: "LaunchToExit", signpostID: identifier, "operation=%llu", operation)
        return identifier
    }

    public static func processExit(_ identifier: OSSignpostID, operation: UInt64) {
        os_signpost(.end, log: process, name: "LaunchToExit", signpostID: identifier, "operation=%llu", operation)
    }

    public static func memoryOperation(operation: UInt64) -> OSSignpostID {
        let identifier = OSSignpostID(log: memory)
        os_signpost(.begin, log: memory, name: "MemoryOperation", signpostID: identifier, "operation=%llu", operation)
        return identifier
    }

    public static func memoryOperationEnded(_ identifier: OSSignpostID, operation: UInt64) {
        os_signpost(.end, log: memory, name: "MemoryOperation", signpostID: identifier, "operation=%llu", operation)
    }
}
