// RuntimeObservabilityTests.swift
// Verifies fixed-cardinality runtime metrics and privacy-safe diagnostic snapshots.

import XCTest
@testable import ForgeConductorCore

final class RuntimeObservabilityTests: XCTestCase {
    func testRuntimeMetricsUseFixedKeysAndClampNonnegativeGauges() {
        let diagnostics = RuntimeDiagnostics()
        diagnostics.increment(.telemetryEventsProduced, by: 3)
        diagnostics.increment(.telemetrySnapshotsPublished)
        diagnostics.set(.telemetryLogicalQueueDepth, to: -4)
        XCTAssertEqual(diagnostics.adjust(.telemetryLogicalQueueDepth, by: 2), 2)
        diagnostics.recordMaximum(.telemetryMaximumQueueDepth, candidate: 2)
        diagnostics.recordMaximum(.telemetryMaximumQueueDepth, candidate: 1)

        let snapshot = diagnostics.snapshot()
        XCTAssertEqual(snapshot.counters.count, RuntimeCounter.allCases.count)
        XCTAssertEqual(snapshot.gauges.count, RuntimeGauge.allCases.count)
        XCTAssertEqual(snapshot.counters[RuntimeCounter.telemetryEventsProduced.rawValue], 3)
        XCTAssertEqual(snapshot.counters[RuntimeCounter.telemetrySnapshotsPublished.rawValue], 1)
        XCTAssertEqual(snapshot.gauges[RuntimeGauge.telemetryLogicalQueueDepth.rawValue], 2)
        XCTAssertEqual(snapshot.gauges[RuntimeGauge.telemetryMaximumQueueDepth.rawValue], 2)
    }

    func testRuntimeSnapshotDictionaryContainsOnlyNumericMetricMaps() throws {
        let diagnostics = RuntimeDiagnostics()
        diagnostics.increment(.memoryWrites)
        diagnostics.set(.memoryRecordCount, to: 7)

        let dictionary = diagnostics.snapshot().asDictionary()
        XCTAssertNotNil(dictionary["captured_at"] as? String)
        let counters = try XCTUnwrap(dictionary["counters"] as? [String: UInt64])
        let gauges = try XCTUnwrap(dictionary["gauges"] as? [String: Int64])
        XCTAssertEqual(counters[RuntimeCounter.memoryWrites.rawValue], 1)
        XCTAssertEqual(gauges[RuntimeGauge.memoryRecordCount.rawValue], 7)
    }

    func testSignpostBoundariesAcceptStableNumericOperationIdentifiers() {
        let telemetry = RuntimeSignposts.beginTelemetryPresentation(sequence: 41)
        RuntimeSignposts.endTelemetryPresentation(telemetry, sequence: 41)
        let process = RuntimeSignposts.processLaunch(operation: 42)
        RuntimeSignposts.processExit(process, operation: 42)
        let memory = RuntimeSignposts.memoryOperation(operation: 43)
        RuntimeSignposts.memoryOperationEnded(memory, operation: 43)
    }
}
