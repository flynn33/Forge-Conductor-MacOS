import Foundation
import ForgeConductorCore

struct ComputeGPUIdentity: Equatable, Sendable {
    var name: String
    var registryID: UInt64
}

enum ComputeActivityQuality: String, Equatable, Sendable {
    case measured, aggregateFallback, warmingUp, unavailable, unknown
}

struct ComputeChipChannel: Equatable, Sendable {
    var name: String
    var quality: ComputeActivityQuality
    var observedAt: TimeInterval?
    var activity: [Float?]
    var logicalCount: Int
    var hardwareCoreCount: Int? = nil
    var engineReadings: String = ""

    func isFresh(at now: TimeInterval) -> Bool {
        guard let observedAt, observedAt.isFinite, now.isFinite else { return false }
        let age = now - observedAt
        return age >= -0.25 && age <= 3
    }

    func label(at now: TimeInterval, paused: Bool) -> String {
        if paused { return "Paused" }
        switch quality {
        case .warmingUp: return "Warming up"
        case .unavailable: return "Activity unavailable"
        case .unknown: return "Provenance unavailable"
        case .measured, .aggregateFallback:
            guard isFresh(at: now) else { return "Stale activity" }
            guard let maximum = activity.compactMap({ $0 }).max() else { return "Activity unavailable" }
            let prefix = quality == .aggregateFallback ? "Aggregate · " : ""
            return prefix + (maximum < 0.01 ? "Idle" : maximum >= 0.7 ? "High activity" : "Active")
        }
    }

    func validActivity(at now: TimeInterval) -> [Float?] {
        guard (quality == .measured || quality == .aggregateFallback), isFresh(at: now) else {
            return Array(repeating: nil, count: activity.count)
        }
        return activity
    }
}

struct ComputeChipSnapshot: Equatable, Sendable {
    static let maximumCPURegions = 256
    static let gpuRegionCount = 16
    var cpu: ComputeChipChannel
    var gpu: ComputeChipChannel

    static func fraction(_ percent: Double?) -> Float? {
        guard let percent, percent.isFinite else { return nil }
        return Float(min(max(percent / 100, 0), 1))
    }

    static func project(cpu: CPUMetrics?, gpu: [GPUMetrics], devices: [ComputeGPUIdentity], now: TimeInterval) -> Self {
        let count = max(cpu?.countLogical ?? 0, 0)
        let regionCount = min(count, maximumCPURegions)
        let quality: ComputeActivityQuality
        switch cpu?.sampleQuality {
        case .perLogicalProcessor: quality = .measured
        case .hostAggregateFallback: quality = .aggregateFallback
        case .warmingUp: quality = .warmingUp
        case .unavailable: quality = .unavailable
        case .unknown: quality = .unknown
        case nil: quality = .unavailable
        }
        var cpuActivity: [Float?] = []
        cpuActivity.reserveCapacity(regionCount)
        for region in 0..<regionCount {
            if quality == .aggregateFallback {
                cpuActivity.append(fraction(cpu?.percent))
            } else if quality == .measured, let cpu {
                let lower = region * count / regionCount
                let upper = (region + 1) * count / regionCount
                let values = (lower..<upper).map { index in
                    index < cpu.perCPU.count ? fraction(cpu.perCPU[index]) : nil
                }
                // A grouped region never converts a missing logical processor into measured idle.
                let valid = values.compactMap { $0 }
                cpuActivity.append(valid.count == values.count && !valid.isEmpty
                    ? valid.reduce(0, +) / Float(valid.count) : nil)
            } else {
                cpuActivity.append(nil)
            }
        }
        let cpuName = cpu?.brand.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let matching = devices.lazy.compactMap { device -> (ComputeGPUIdentity, GPUMetrics)? in
            guard let sample = gpu.first(where: { $0.registryID == device.registryID }) else { return nil }
            return (device, sample)
        }.first
        let identity = matching?.0 ?? devices.first
        let gpuName = identity?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sample = matching?.1
        let aggregate = fraction(sample?.utilGPU)
        let gpuQuality: ComputeActivityQuality = aggregate == nil ? .unavailable : .measured
        let gpuActivity = (0..<gpuRegionCount).map { _ in aggregate }
        func reading(_ label: String, _ value: Double?) -> String? {
            guard let value = fraction(value) else { return nil }
            return "\(label) \(Int((value * 100).rounded()))%"
        }
        let engineReadings = [reading("Device", sample?.utilGPU), reading("Renderer", sample?.utilRenderer),
                              reading("Tiler", sample?.utilTiler)].compactMap { $0 }.joined(separator: " · ")
        return Self(
            cpu: .init(name: cpuName.isEmpty ? "CPU identity unavailable" : cpuName,
                       quality: count > 0 ? quality : .unavailable,
                       observedAt: cpu?.observedAt, activity: cpuActivity, logicalCount: count),
            gpu: .init(name: gpuName.isEmpty ? "GPU identity unavailable" : gpuName, quality: gpuQuality,
                       observedAt: sample?.observedAt, activity: gpuActivity, logicalCount: 0,
                       hardwareCoreCount: sample?.cores.flatMap { $0 > 0 ? $0 : nil },
                       engineReadings: engineReadings)
        )
    }

    var provenance: String {
        let source: String
        switch cpu.quality {
        case .measured:
            source = cpu.logicalCount > Self.maximumCPURegions
                ? "CPU: grouped logical-processor activity." : "CPU: logical-processor activity."
        case .aggregateFallback: source = "CPU: host aggregate fallback; regions illustrative."
        case .warmingUp: source = "CPU: measurement warming up."
        case .unknown: source = "CPU: provenance unavailable."
        case .unavailable: source = "CPU: activity unavailable."
        }
        return source + " GPU regions illustrative. Trace flow simulated."
    }
}
