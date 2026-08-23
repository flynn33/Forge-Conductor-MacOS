// ResourcePolicy.swift
// What: Defines absolute resource ceilings and memory-pressure adaptations.
// How: A physical-memory tier supplies bounded limits; warning and critical pressure
// reduce optional retention without changing feature availability or durable data.
// Why: Long-running telemetry, diagnostics, subprocess, and memory services must never
// acquire an unbounded mode as machine capacity or workload changes.

import Foundation
import Dispatch

public enum ResourceMemoryTier: String, Sendable, Codable, CaseIterable {
    case constrained
    case standard
    case expanded
}

public enum ResourcePressureLevel: String, Sendable, Codable {
    case nominal
    case warning
    case critical
}

public struct ResourceLimits: Sendable, Codable, Equatable {
    public let telemetryHistoryPoints: Int
    public let diagnosticRingRecords: Int
    public let processOutputBytesPerStream: Int
    public let logFileBytes: UInt64
    public let retainedLogArchives: Int
    public let activeModelStreamBytes: Int
    public let decodedMemoryCacheBytes: Int
    public let searchCacheBytes: Int
    public let memorySearchDefaultLimit: Int
    public let memorySearchHardLimit: Int
    public let mcpResponseBytes: Int
    public let activeGaugeFPS: Int
}

public struct ResourcePolicy: Sendable, Equatable {
    public static let gibibyte: UInt64 = 1_073_741_824
    public static var current: ResourcePolicy {
        ResourcePolicy(physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)
    }

    public let tier: ResourceMemoryTier
    public let nominalLimits: ResourceLimits

    public init(physicalMemoryBytes: UInt64) {
        if physicalMemoryBytes <= 8 * Self.gibibyte {
            tier = .constrained
            nominalLimits = ResourceLimits(
                telemetryHistoryPoints: 600,
                diagnosticRingRecords: 1_000,
                processOutputBytesPerStream: 4 * 1_048_576,
                logFileBytes: 4 * 1_048_576,
                retainedLogArchives: 2,
                activeModelStreamBytes: 4 * 1_048_576,
                decodedMemoryCacheBytes: 16 * 1_048_576,
                searchCacheBytes: 8 * 1_048_576,
                memorySearchDefaultLimit: 20,
                memorySearchHardLimit: 100,
                mcpResponseBytes: 1_048_576,
                activeGaugeFPS: 30
            )
        } else if physicalMemoryBytes <= 16 * Self.gibibyte {
            tier = .standard
            nominalLimits = ResourceLimits(
                telemetryHistoryPoints: 1_200,
                diagnosticRingRecords: 2_000,
                processOutputBytesPerStream: 8 * 1_048_576,
                logFileBytes: 8 * 1_048_576,
                retainedLogArchives: 3,
                activeModelStreamBytes: 8 * 1_048_576,
                decodedMemoryCacheBytes: 32 * 1_048_576,
                searchCacheBytes: 16 * 1_048_576,
                memorySearchDefaultLimit: 30,
                memorySearchHardLimit: 150,
                mcpResponseBytes: 2 * 1_048_576,
                activeGaugeFPS: 60
            )
        } else {
            tier = .expanded
            nominalLimits = ResourceLimits(
                telemetryHistoryPoints: 2_400,
                diagnosticRingRecords: 4_000,
                processOutputBytesPerStream: 16 * 1_048_576,
                logFileBytes: 8 * 1_048_576,
                retainedLogArchives: 3,
                activeModelStreamBytes: 16 * 1_048_576,
                decodedMemoryCacheBytes: 64 * 1_048_576,
                searchCacheBytes: 32 * 1_048_576,
                memorySearchDefaultLimit: 50,
                memorySearchHardLimit: 200,
                mcpResponseBytes: 4 * 1_048_576,
                activeGaugeFPS: 60
            )
        }
    }

    public func limits(for pressure: ResourcePressureLevel) -> ResourceLimits {
        let divisor: Int
        switch pressure {
        case .nominal: divisor = 1
        case .warning: divisor = 2
        case .critical: divisor = 4
        }
        let base = nominalLimits
        return ResourceLimits(
            telemetryHistoryPoints: max(300, base.telemetryHistoryPoints / divisor),
            diagnosticRingRecords: max(500, base.diagnosticRingRecords / divisor),
            processOutputBytesPerStream: max(1_048_576, base.processOutputBytesPerStream / divisor),
            logFileBytes: max(1_048_576, base.logFileBytes / UInt64(divisor)),
            retainedLogArchives: pressure == .critical ? 1 : base.retainedLogArchives,
            activeModelStreamBytes: max(1_048_576, base.activeModelStreamBytes / divisor),
            decodedMemoryCacheBytes: max(4 * 1_048_576, base.decodedMemoryCacheBytes / divisor),
            searchCacheBytes: max(2 * 1_048_576, base.searchCacheBytes / divisor),
            memorySearchDefaultLimit: max(10, base.memorySearchDefaultLimit / divisor),
            memorySearchHardLimit: max(25, base.memorySearchHardLimit / divisor),
            mcpResponseBytes: max(262_144, base.mcpResponseBytes / divisor),
            activeGaugeFPS: max(15, base.activeGaugeFPS / divisor)
        )
    }
}

/// Process-local memory-pressure signal owner with explicit, idempotent lifecycle.
public final class ResourcePressureMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "forge.resources.memory-pressure", qos: .utility)
    private let lock = NSLock()
    private var source: DispatchSourceMemoryPressure?
    private var handler: (@Sendable (ResourcePressureLevel) -> Void)?

    public init() {}

    public func start(handler: @escaping @Sendable (ResourcePressureLevel) -> Void) {
        stop()
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: queue
        )
        lock.lock()
        self.handler = handler
        self.source = source
        lock.unlock()
        source.setEventHandler { [weak self] in
            self?.deliverCurrentPressure()
        }
        source.resume()
    }

    public func stop() {
        lock.lock()
        let owned = source
        source = nil
        handler = nil
        lock.unlock()
        owned?.setEventHandler {}
        owned?.cancel()
    }

    deinit {
        stop()
    }

    private func deliverCurrentPressure() {
        lock.lock()
        let data = source?.data ?? []
        let callback = handler
        lock.unlock()
        callback?(data.contains(.critical) ? .critical : .warning)
    }
}
