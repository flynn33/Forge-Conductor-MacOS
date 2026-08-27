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
    case highCapacity = "high_capacity"
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

/// Bounded provider-model defaults for one physical-memory tier. These values are
/// ceilings, not scheduling targets; provider capacity and model-size estimates may
/// lower them further at admission time.
public struct ResourceModelPolicy: Sendable, Codable, Equatable {
    public let defaultLoadedInstances: Int
    public let maximumLoadedInstances: Int
    public let maximumParallelRequests: Int
    public let idleTTLSeconds: Int
    public let jitLoadingRequired: Bool
    public let autoEvictRequired: Bool
    public let serializeSuccessorCreation: Bool
}

/// Manager/runtime/event limits that must be resolved from the same memory tier.
/// Keeping these together prevents each long-lived owner from independently assuming
/// that it can consume the machine's entire scheduling and retention budget.
public struct ResourceExecutionLimits: Sendable, Codable, Equatable {
    public let maximumActiveManagedGenerations: Int
    public let maximumActiveRuntimeJobs: Int
    public let maximumCPUHeavyRuntimeJobs: Int
    public let maximumInMemoryEvents: Int
    public let modelPolicy: ResourceModelPolicy
}

public struct ResourcePolicy: Sendable, Equatable {
    public static let gibibyte: UInt64 = 1_073_741_824
    public static var current: ResourcePolicy {
        ResourcePolicy(physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)
    }

    public let tier: ResourceMemoryTier
    public let nominalLimits: ResourceLimits
    public let nominalExecutionLimits: ResourceExecutionLimits

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
            nominalExecutionLimits = ResourceExecutionLimits(
                maximumActiveManagedGenerations: 1,
                maximumActiveRuntimeJobs: 2,
                maximumCPUHeavyRuntimeJobs: 1,
                maximumInMemoryEvents: 1_000,
                modelPolicy: ResourceModelPolicy(
                    defaultLoadedInstances: 1,
                    maximumLoadedInstances: 1,
                    maximumParallelRequests: 1,
                    idleTTLSeconds: 300,
                    jitLoadingRequired: true,
                    autoEvictRequired: true,
                    serializeSuccessorCreation: true
                )
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
            nominalExecutionLimits = ResourceExecutionLimits(
                maximumActiveManagedGenerations: 1,
                maximumActiveRuntimeJobs: 2,
                maximumCPUHeavyRuntimeJobs: 1,
                maximumInMemoryEvents: 2_500,
                modelPolicy: ResourceModelPolicy(
                    defaultLoadedInstances: 1,
                    maximumLoadedInstances: 1,
                    maximumParallelRequests: 2,
                    idleTTLSeconds: 600,
                    jitLoadingRequired: true,
                    autoEvictRequired: true,
                    serializeSuccessorCreation: true
                )
            )
        } else if physicalMemoryBytes <= 32 * Self.gibibyte {
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
            nominalExecutionLimits = ResourceExecutionLimits(
                maximumActiveManagedGenerations: 2,
                maximumActiveRuntimeJobs: 4,
                maximumCPUHeavyRuntimeJobs: 2,
                maximumInMemoryEvents: 5_000,
                modelPolicy: ResourceModelPolicy(
                    defaultLoadedInstances: 1,
                    maximumLoadedInstances: 2,
                    maximumParallelRequests: 2,
                    idleTTLSeconds: 900,
                    jitLoadingRequired: true,
                    autoEvictRequired: true,
                    serializeSuccessorCreation: false
                )
            )
        } else {
            tier = .highCapacity
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
            nominalExecutionLimits = ResourceExecutionLimits(
                maximumActiveManagedGenerations: 2,
                maximumActiveRuntimeJobs: 6,
                maximumCPUHeavyRuntimeJobs: 3,
                maximumInMemoryEvents: 10_000,
                modelPolicy: ResourceModelPolicy(
                    defaultLoadedInstances: 1,
                    maximumLoadedInstances: 2,
                    maximumParallelRequests: 4,
                    idleTTLSeconds: 1_200,
                    jitLoadingRequired: true,
                    autoEvictRequired: true,
                    serializeSuccessorCreation: false
                )
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

    /// Pressure can only tighten scheduling, model, and event-retention ceilings.
    /// Required capability remains available because every executable limit floors at one.
    public func executionLimits(for pressure: ResourcePressureLevel) -> ResourceExecutionLimits {
        let divisor: Int
        switch pressure {
        case .nominal: divisor = 1
        case .warning: divisor = 2
        case .critical: divisor = 4
        }
        let base = nominalExecutionLimits
        let baseModel = base.modelPolicy
        let maximumLoadedInstances = max(1, baseModel.maximumLoadedInstances / divisor)
        return ResourceExecutionLimits(
            maximumActiveManagedGenerations: max(
                1, base.maximumActiveManagedGenerations / divisor
            ),
            maximumActiveRuntimeJobs: max(1, base.maximumActiveRuntimeJobs / divisor),
            maximumCPUHeavyRuntimeJobs: min(
                max(1, base.maximumCPUHeavyRuntimeJobs / divisor),
                max(1, base.maximumActiveRuntimeJobs / divisor)
            ),
            maximumInMemoryEvents: max(500, base.maximumInMemoryEvents / divisor),
            modelPolicy: ResourceModelPolicy(
                defaultLoadedInstances: min(
                    max(1, baseModel.defaultLoadedInstances / divisor),
                    maximumLoadedInstances
                ),
                maximumLoadedInstances: maximumLoadedInstances,
                maximumParallelRequests: max(1, baseModel.maximumParallelRequests / divisor),
                idleTTLSeconds: max(60, baseModel.idleTTLSeconds / divisor),
                jitLoadingRequired: baseModel.jitLoadingRequired,
                autoEvictRequired: baseModel.autoEvictRequired,
                serializeSuccessorCreation: baseModel.serializeSuccessorCreation
                    || pressure != .nominal
            )
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
