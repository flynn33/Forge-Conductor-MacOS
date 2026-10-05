import Foundation
import Metal
import XCTest
@testable import ForgeConductorCore

final class ComputeTelemetryProvenanceTests: XCTestCase {
    func testEqualMeasuredSamplesRemainPerLogicalAfterWarmup() throws {
        let ticks = CPUCounterSequence([
            [.init(user: 0, system: 0, idle: 100, nice: 0), .init(user: 0, system: 0, idle: 100, nice: 0)],
            [.init(user: 22, system: 0, idle: 178, nice: 0), .init(user: 22, system: 0, idle: 178, nice: 0)],
        ])
        let collector = CPUCollector(perCoreTickProvider: { ticks.next() }, hostTickProvider: { nil })
        let first = collector.collect()
        XCTAssertEqual(first.sampleQuality, .warmingUp)
        XCTAssertEqual(first.perCPU, [0, 0])
        let measured = collector.collect()
        XCTAssertEqual(measured.sampleQuality, .perLogicalProcessor)
        XCTAssertEqual(measured.perCPU, [22, 22])
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(measured.observedAt), try XCTUnwrap(first.observedAt))
    }

    func testHostFallbackIsDistinctFromEqualMeasuredSamples() {
        let ticks = CPUCounterSequence([
            [.init(user: 0, system: 0, idle: 100, nice: 0)],
            [.init(user: 22, system: 0, idle: 178, nice: 0)],
        ])
        let collector = CPUCollector(perCoreTickProvider: { nil }, hostTickProvider: { ticks.next()?.first })
        XCTAssertEqual(collector.collect().sampleQuality, .warmingUp)
        let fallback = collector.collect()
        XCTAssertEqual(fallback.sampleQuality, .hostAggregateFallback)
        XCTAssertEqual(fallback.perCPU.count, fallback.countLogical)
        XCTAssertTrue(fallback.perCPU.allSatisfy { $0 == 22 })
    }

    func testUnavailableRetainsNumericalCompatibilityWithoutClaimingIdle() {
        let collector = CPUCollector(perCoreTickProvider: { nil }, hostTickProvider: { nil })
        let missing = collector.collect()
        XCTAssertEqual(missing.sampleQuality, .unavailable)
        XCTAssertEqual(missing.percent, 0)
        XCTAssertEqual(missing.perCPU.count, missing.countLogical)
        XCTAssertNotNil(missing.observedAt)
    }

    func testTopologyChangeReestablishesBaselineInsteadOfReusingOldIndices() {
        let ticks = CPUCounterSequence([
            [.init(user: 0, system: 0, idle: 100, nice: 0)],
            [.init(user: 20, system: 0, idle: 180, nice: 0)],
            [.init(user: 20, system: 0, idle: 180, nice: 0), .init(user: 0, system: 0, idle: 100, nice: 0)],
        ])
        let collector = CPUCollector(perCoreTickProvider: { ticks.next() }, hostTickProvider: { nil })
        XCTAssertEqual(collector.collect().sampleQuality, .warmingUp)
        XCTAssertEqual(collector.collect().sampleQuality, .perLogicalProcessor)
        let changed = collector.collect()
        XCTAssertEqual(changed.sampleQuality, .warmingUp)
        XCTAssertEqual(changed.perCPU, [0, 0])
    }

    func testLegacyInitializersKeepUnknownProvenanceAndTransportKeys() {
        let cpu = CPUMetrics(percent: 0, perCPU: [0], countLogical: 1, countPhysical: 1,
                             freqMHz: nil, freqPerCoreMHz: nil, loadAvg: (0, 0, 0), brand: "Observed CPU", user: 0, system: 0, idle: 100)
        let gpu = GPUMetrics(vendor: "Observed", name: "Observed GPU", utilGPU: 0,
                             utilRenderer: nil, utilTiler: nil, memUsedMiB: nil,
                             memTotalMiB: 0, cores: nil, metal: true)
        XCTAssertEqual(cpu.sampleQuality, .unknown)
        XCTAssertNil(cpu.observedAt)
        XCTAssertNil(gpu.registryID)
        XCTAssertNil(gpu.observedAt)
        var taggedCPU = cpu
        taggedCPU.sampleQuality = .perLogicalProcessor
        taggedCPU.observedAt = 42
        var taggedGPU = gpu
        taggedGPU.registryID = 123
        taggedGPU.observedAt = 31
        XCTAssertEqual(Set(cpu.asDictionary().keys), Set(taggedCPU.asDictionary().keys))
        XCTAssertEqual(Set(gpu.asDictionary().keys), Set(taggedGPU.asDictionary().keys))
        XCTAssertFalse(taggedCPU.asDictionary().keys.contains("sample_quality"))
        XCTAssertFalse(taggedGPU.asDictionary().keys.contains("registry_id"))
    }

    func testGPUCounterAssociationRejectsMergedUnmatchedAndUnknownSources() {
        XCTAssertEqual(GPUCounterAssociation.sharedRegistryID([123, 123, 123, 123]), 123)
        XCTAssertEqual(GPUCounterAssociation.sharedRegistryID([123]), 123)
        XCTAssertNil(GPUCounterAssociation.sharedRegistryID([123, 456]))
        XCTAssertNil(GPUCounterAssociation.sharedRegistryID([123, nil]))
        XCTAssertNil(GPUCounterAssociation.sharedRegistryID([]))
        XCTAssertNil(GPUCounterAssociation.sharedRegistryID([0]))
    }

    func testRealtimeCompositionRetainsOriginalGPUObservationTime() throws {
        let collector = SystemCollector()
        let full = collector.collectMetrics(tier: .full)
        let original = try XCTUnwrap(full.gpu.first?.observedAt)
        let realtime = collector.collectMetrics(tier: .realtime)
        XCTAssertEqual(realtime.gpu.first?.observedAt, original)
        XCTAssertGreaterThanOrEqual(realtime.ts, full.ts)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(realtime.cpu.observedAt), try XCTUnwrap(full.cpu.observedAt))
        let medium = collector.collectMetrics(tier: .medium)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(medium.gpu.first?.observedAt), original)
    }

    func testObservedGPUIdentityMatchesNativeMetalDeviceWhenAvailable() throws {
        let sample = try XCTUnwrap(GPUCollector().collect().first)
        XCTAssertNotNil(sample.observedAt)
        if let registryID = sample.registryID {
            XCTAssertTrue(MTLCopyAllDevices().contains { $0.registryID == registryID },
                          "A collector association on this host must name a Metal device rather than attach unrelated counters")
        }
    }
}

private final class CPUCounterSequence: @unchecked Sendable {
    private let lock = NSLock()
    private let samples: [[CPUCollector.CoreTicks]]
    private var index = 0

    init(_ samples: [[CPUCollector.CoreTicks]]) { self.samples = samples }

    func next() -> [CPUCollector.CoreTicks]? {
        lock.lock()
        defer { lock.unlock() }
        guard samples.indices.contains(index) else { return nil }
        defer { index += 1 }
        return samples[index]
    }
}
