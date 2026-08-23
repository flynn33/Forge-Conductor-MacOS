// LatestValueMailboxTests.swift
// Verifies bounded newest-value delivery, generation invalidation, and stop behavior.

import XCTest
@testable import ForgeConductorCore

final class LatestValueMailboxTests: XCTestCase {
    func testProducerPressureUsesAtMostTwoLogicalSlotsAndConvergesToLatest() async throws {
        let diagnostics = RuntimeDiagnostics()
        let mailbox = LatestValueMailbox<Int>(diagnostics: diagnostics)
        let probe = BlockingDeliveryProbe()
        let generation = mailbox.start { value, _ in
            await probe.receive(value)
        }

        XCTAssertEqual(mailbox.publish(1, generation: generation), .enqueued)
        try await eventually { await probe.values() == [1] }

        for value in 2 ... 1_000 {
            mailbox.publish(value, generation: generation)
        }

        let pressured = mailbox.snapshot()
        XCTAssertLessThanOrEqual(pressured.pendingLogicalSlots, 2)
        XCTAssertLessThanOrEqual(pressured.maximumPendingLogicalSlots, 2)
        XCTAssertEqual(pressured.pendingLogicalSlots, 2)
        XCTAssertGreaterThan(pressured.replaced, 900)

        await probe.releaseFirst()
        try await eventually { await probe.values().last == 1_000 }

        let settled = mailbox.snapshot()
        XCTAssertLessThanOrEqual(settled.maximumPendingLogicalSlots, 2)
        XCTAssertEqual(settled.delivered, 2)
        XCTAssertEqual(settled.pendingLogicalSlots, 0)
        XCTAssertEqual(
            diagnostics.snapshot().gauges[RuntimeGauge.telemetryMaximumQueueDepth.rawValue],
            2
        )
        mailbox.stop()
    }

    func testStaleGenerationAndPostStopValuesNeverReachNewSubscriber() async throws {
        let mailbox = LatestValueMailbox<Int>(diagnostics: RuntimeDiagnostics())
        let first = RecordingDeliveryProbe()
        let firstGeneration = mailbox.start { value, _ in
            await first.receive(value)
        }
        mailbox.stop()
        XCTAssertEqual(mailbox.publish(10, generation: firstGeneration), .stopped)

        let second = RecordingDeliveryProbe()
        let secondGeneration = mailbox.start { value, _ in
            await second.receive(value)
        }
        XCTAssertNotEqual(firstGeneration, secondGeneration)
        XCTAssertEqual(mailbox.publish(11, generation: firstGeneration), .staleGeneration)
        XCTAssertEqual(mailbox.publish(12, generation: secondGeneration), .enqueued)
        try await eventually { await second.values() == [12] }

        mailbox.stop()
        XCTAssertEqual(mailbox.publish(13, generation: secondGeneration), .stopped)
        try await Task.sleep(for: .milliseconds(20))
        let secondValues = await second.values()
        let firstValues = await first.values()
        XCTAssertEqual(secondValues, [12])
        XCTAssertTrue(firstValues.isEmpty)
    }

    func testStopClearsBufferedLatestDuringInFlightDelivery() async throws {
        let mailbox = LatestValueMailbox<Int>(diagnostics: RuntimeDiagnostics())
        let probe = BlockingDeliveryProbe()
        let generation = mailbox.start { value, _ in
            await probe.receive(value)
        }

        mailbox.publish(1, generation: generation)
        try await eventually { await probe.values() == [1] }
        mailbox.publish(2, generation: generation)
        XCTAssertEqual(mailbox.snapshot().pendingLogicalSlots, 2)

        mailbox.stop()
        await probe.releaseFirst()
        try await Task.sleep(for: .milliseconds(20))

        let deliveredValues = await probe.values()
        XCTAssertEqual(deliveredValues, [1])
        XCTAssertFalse(mailbox.snapshot().active)
        XCTAssertEqual(mailbox.snapshot().pendingLogicalSlots, 0)
    }

    private func eventually(
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("condition did not become true before timeout")
    }
}

private actor RecordingDeliveryProbe {
    private var received: [Int] = []

    func receive(_ value: Int) -> Bool {
        received.append(value)
        return true
    }

    func values() -> [Int] { received }
}

private actor BlockingDeliveryProbe {
    private var received: [Int] = []
    private var firstGate: CheckedContinuation<Void, Never>?

    func receive(_ value: Int) async -> Bool {
        received.append(value)
        if received.count == 1 {
            await withCheckedContinuation { continuation in
                firstGate = continuation
            }
        }
        return true
    }

    func releaseFirst() {
        firstGate?.resume()
        firstGate = nil
    }

    func values() -> [Int] { received }
}
