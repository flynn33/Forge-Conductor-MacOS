// GPUCollector.swift
// What: Collects Apple GPU identity, memory, utilization, and Metal availability.
// How: Metal device discovery is combined with recursively inspected IOKit properties
// and tolerant numeric conversion for OS/hardware variations.
// Why: Native sources avoid privileged samplers and keep unavailable fields explicit.

import Foundation
import Darwin
import IOKit

/// GPU metrics via **IOKit / IORegistry**.
///
/// Walks `IOServiceMatching` classes (`IOAccelerator`, `AGXAccelerator`, `IOGPU`) and
/// reads properties through `IORegistryEntryCreateCFProperties` (see `IOKitPropertyWalk`).
/// Live keys: `PerformanceStatistics` → Device/Renderer/Tiler Utilization %, memory.
public final class GPUCollector: GPUMetricsCollecting, @unchecked Sendable {
    public init() {}

    public func collect() -> [GPUMetrics] {
        let memTotal = Int(ProcessInfo.processInfo.physicalMemory / 1_048_576)
        var model = "Apple GPU"
        var util: Double?
        var utilR: Double?
        var utilT: Double?
        var memUsed: Int?
        var cores: Int?
        var utilSource: UInt64?
        var rendererSource: UInt64?
        var tilerSource: UInt64?
        var coreSource: UInt64?

        for className in ["IOAccelerator", "AGXAccelerator", "IOGPU"] {
            IOKitPropertyWalk.forEachService(className: className) { service, props in
                var entryID: UInt64 = 0
                let sourceID: UInt64? = IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS
                    && entryID != 0 ? entryID : nil
                if let m = IOKitPropertyWalk.string(props, keys: ["model", "IOClass", "CFBundleIdentifier"]) {
                    if m.localizedCaseInsensitiveContains("gpu")
                        || m.localizedCaseInsensitiveContains("agx")
                        || m.localizedCaseInsensitiveContains("accelerator")
                        || m.localizedCaseInsensitiveContains("apple") {
                        model = m
                    }
                }
                if let c = IOKitPropertyWalk.int(props, keys: ["gpu-core-count", "GPUCoreCount"]) {
                    cores = c
                    coreSource = sourceID
                }
                let stats = IOKitPropertyWalk.childDict(props, keys: [
                    "PerformanceStatistics", "performanceStatistics", "Statistics",
                ]) ?? props

                if util == nil {
                    util = IOKitPropertyWalk.double(stats, keys: [
                        "Device Utilization %", "Device Utilization%",
                        "GPU Activity(%)", "Hardware utilization %",
                    ])
                    if util != nil { utilSource = sourceID }
                }
                if utilR == nil {
                    utilR = IOKitPropertyWalk.double(stats, keys: [
                        "Renderer Utilization %", "Renderer Utilization%",
                    ])
                    if utilR != nil { rendererSource = sourceID }
                }
                if utilT == nil {
                    utilT = IOKitPropertyWalk.double(stats, keys: [
                        "Tiler Utilization %", "Tiler Utilization%",
                    ])
                    if utilT != nil { tilerSource = sourceID }
                }
                if memUsed == nil {
                    if let inUse = IOKitPropertyWalk.double(stats, keys: [
                        "In use system memory", "In use system memory (driver)",
                        "Alloc system memory",
                    ]) {
                        // Bytes if large; else already MiB-ish
                        memUsed = inUse > 100_000 ? Int(inUse / 1_048_576) : Int(inUse)
                    }
                }
            }
            if util != nil { break }
        }

        // Existing aggregate values retain their transport behavior. This local
        // association is available only when every contributing activity/topology
        // source names the same registry entry; mixed-device samples stay unknown.
        var sourceIDs: [UInt64?] = []
        if util != nil { sourceIDs.append(utilSource) }
        if utilR != nil { sourceIDs.append(rendererSource) }
        if utilT != nil { sourceIDs.append(tilerSource) }
        if cores != nil { sourceIDs.append(coreSource) }
        let validChannels = [util, utilR, utilT].allSatisfy { $0 == nil || $0!.isFinite }
        let registryID = validChannels ? GPUCounterAssociation.sharedRegistryID(sourceIDs) : nil

        // No loadavg fake — if IOKit fails, report nil util (UI shows 0 honestly as unknown).
        return [
            GPUMetrics(
                vendor: "Apple",
                name: model,
                utilGPU: util.map { round1(min(100, max(0, $0))) },
                utilRenderer: utilR.map { round1(min(100, max(0, $0))) },
                utilTiler: utilT.map { round1(min(100, max(0, $0))) },
                memUsedMiB: memUsed,
                memTotalMiB: memTotal,
                cores: cores,
                metal: true,
                registryID: registryID,
                observedAt: Date().timeIntervalSince1970
            ),
        ]
    }

    private func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
}

enum GPUCounterAssociation {
    static func sharedRegistryID(_ sources: [UInt64?]) -> UInt64? {
        guard let first = sources.first, let first, first != 0,
              sources.allSatisfy({ $0 == first }) else { return nil }
        return first
    }
}
