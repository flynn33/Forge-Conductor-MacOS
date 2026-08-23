// LatestValueMailbox.swift
// What: Delivers a producer stream through one in-flight consumer and one replaceable value.
// How: A single long-lived consumer drains an AsyncStream buffered with newest-value capacity one.
// Why: Presentation pressure stays bounded without creating one task for every telemetry frame.

import Foundation

public final class LatestValueMailbox<Element: Sendable>: @unchecked Sendable {
    public enum PublishResult: Sendable, Equatable {
        case enqueued
        case replaced
        case staleGeneration
        case stopped
    }

    public struct Snapshot: Sendable, Equatable {
        public let generation: UInt64
        public let active: Bool
        public let inFlight: Bool
        public let hasBufferedLatest: Bool
        public let pendingLogicalSlots: Int
        public let maximumPendingLogicalSlots: Int
        public let published: UInt64
        public let delivered: UInt64
        public let replaced: UInt64
        public let dropped: UInt64
        public let stale: UInt64
        public let postStopAttempts: UInt64
    }

    public typealias Delivery = @Sendable (Element, UInt64) async -> Bool

    private let lock = NSLock()
    private let diagnostics: RuntimeDiagnostics
    private var generation: UInt64 = 0
    private var active = false
    private var inFlight = false
    private var hasBufferedLatest = false
    private var maximumPendingLogicalSlots = 0
    private var published: UInt64 = 0
    private var delivered: UInt64 = 0
    private var replaced: UInt64 = 0
    private var dropped: UInt64 = 0
    private var stale: UInt64 = 0
    private var postStopAttempts: UInt64 = 0
    private var continuation: AsyncStream<Element>.Continuation?
    private var consumerTask: Task<Void, Never>?

    public init(diagnostics: RuntimeDiagnostics = .shared) {
        self.diagnostics = diagnostics
    }

    /// Starts a new subscriber generation and its only consumer task.
    @discardableResult
    public func start(delivery: @escaping Delivery) -> UInt64 {
        let pair = AsyncStream<Element>.makeStream(bufferingPolicy: .bufferingNewest(1))

        lock.lock()
        let priorContinuation = continuation
        let priorTask = consumerTask
        generation &+= 1
        let activeGeneration = generation
        active = true
        inFlight = false
        hasBufferedLatest = false
        continuation = pair.continuation
        consumerTask = nil
        updateDepthLocked()
        lock.unlock()

        priorContinuation?.finish()
        priorTask?.cancel()

        let task = Task { [weak self] in
            for await value in pair.stream {
                guard !Task.isCancelled, let self,
                      self.beginDelivery(generation: activeGeneration)
                else { break }
                let accepted = await delivery(value, activeGeneration)
                self.endDelivery(generation: activeGeneration, accepted: accepted)
            }
        }

        lock.lock()
        if active, generation == activeGeneration {
            consumerTask = task
        } else {
            task.cancel()
        }
        lock.unlock()
        return activeGeneration
    }

    /// Publishes synchronously from any producer queue without creating a task.
    @discardableResult
    public func publish(_ value: Element, generation requestedGeneration: UInt64) -> PublishResult {
        lock.lock()
        guard active else {
            postStopAttempts &+= 1
            dropped &+= 1
            lock.unlock()
            diagnostics.increment(.telemetrySnapshotsDropped)
            return .stopped
        }
        guard requestedGeneration == generation else {
            stale &+= 1
            lock.unlock()
            diagnostics.increment(.telemetrySnapshotsStale)
            return .staleGeneration
        }
        guard let continuation else {
            postStopAttempts &+= 1
            dropped &+= 1
            lock.unlock()
            diagnostics.increment(.telemetrySnapshotsDropped)
            return .stopped
        }

        published &+= 1
        diagnostics.increment(.telemetryPresentationEnqueued)
        let result = continuation.yield(value)
        let outcome: PublishResult
        switch result {
        case .enqueued:
            hasBufferedLatest = true
            outcome = .enqueued
        case .dropped:
            hasBufferedLatest = true
            replaced &+= 1
            diagnostics.increment(.telemetrySnapshotsReplaced)
            outcome = .replaced
        case .terminated:
            active = false
            hasBufferedLatest = false
            postStopAttempts &+= 1
            dropped &+= 1
            diagnostics.increment(.telemetrySnapshotsDropped)
            outcome = .stopped
        @unknown default:
            active = false
            hasBufferedLatest = false
            dropped &+= 1
            diagnostics.increment(.telemetrySnapshotsDropped)
            outcome = .stopped
        }
        updateDepthLocked()
        lock.unlock()
        return outcome
    }

    /// Invalidates the generation, clears the buffered value, and cancels the consumer.
    public func stop() {
        lock.lock()
        guard active || continuation != nil || consumerTask != nil else {
            lock.unlock()
            return
        }
        active = false
        hasBufferedLatest = false
        inFlight = false
        let oldContinuation = continuation
        let oldTask = consumerTask
        continuation = nil
        consumerTask = nil
        updateDepthLocked()
        lock.unlock()

        oldContinuation?.finish()
        oldTask?.cancel()
    }

    public func isActive(generation requestedGeneration: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return active && generation == requestedGeneration
    }

    public func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            generation: generation,
            active: active,
            inFlight: inFlight,
            hasBufferedLatest: hasBufferedLatest,
            pendingLogicalSlots: pendingSlotsLocked,
            maximumPendingLogicalSlots: maximumPendingLogicalSlots,
            published: published,
            delivered: delivered,
            replaced: replaced,
            dropped: dropped,
            stale: stale,
            postStopAttempts: postStopAttempts
        )
    }

    deinit {
        continuation?.finish()
        consumerTask?.cancel()
    }

    private func beginDelivery(generation requestedGeneration: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard active, requestedGeneration == generation else {
            stale &+= 1
            diagnostics.increment(.telemetrySnapshotsStale)
            return false
        }
        hasBufferedLatest = false
        inFlight = true
        updateDepthLocked()
        return true
    }

    private func endDelivery(generation requestedGeneration: UInt64, accepted: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard active, requestedGeneration == generation else {
            stale &+= 1
            diagnostics.increment(.telemetrySnapshotsStale)
            return
        }
        inFlight = false
        if accepted {
            delivered &+= 1
            diagnostics.increment(.telemetrySnapshotsDelivered)
        } else {
            dropped &+= 1
            diagnostics.increment(.telemetrySnapshotsDropped)
        }
        updateDepthLocked()
    }

    private var pendingSlotsLocked: Int {
        (inFlight ? 1 : 0) + (hasBufferedLatest ? 1 : 0)
    }

    private func updateDepthLocked() {
        let depth = pendingSlotsLocked
        maximumPendingLogicalSlots = max(maximumPendingLogicalSlots, depth)
        diagnostics.set(.telemetryLogicalQueueDepth, to: depth)
        diagnostics.recordMaximum(.telemetryMaximumQueueDepth, candidate: maximumPendingLogicalSlots)
    }
}
