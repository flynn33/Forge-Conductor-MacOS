// StjornarvaldManagerCoordinator.swift
// What: Owns the manager's single bounded policy indexing and evaluation loop.
// How: One cancellable task composes durable stores and publishes typed health.
// Why: Manager restart must resume policy work without making Forge bootstrap depend on it.

import Foundation

public enum StjornarvaldManagerState: String, Codable, Sendable {
    case stopped, starting, running, degraded, stopping
}

public struct StjornarvaldManagerHealth: Codable, Sendable, Equatable {
    public let state: StjornarvaldManagerState
    public let policyIdentity: String
    public let evaluatorID: String
    public let startedAt: Date?
    public let lastEvaluationAt: Date?
    public let lastCommittedCursor: Int64
    public let processedObservationCount: Int
    public let indexedSourceBatchCount: Int
    public let consecutiveFailureCount: Int
    public let lastError: String?

    public var degraded: Bool { state == .degraded }
}

public struct StjornarvaldManagerSnapshot: Codable, Sendable, Equatable {
    public static let schemaVersion = "1.0.0"
    public let schemaVersion: String
    public let health: StjornarvaldManagerHealth
    public let governingPolicy: GoverningPolicyIdentity
    public let sources: [DevelopmentPolicySource]
    public let violationEvents: [PolicyViolationEvent]
    public let nextEventCursor: Int64?
    public let limitations: [String]
}

public enum StjornarvaldObservationReceiptState: String, Codable, Sendable {
    case persisted, deferred, rejected
}

public struct StjornarvaldObservationSubmissionReceipt: Codable, Sendable, Equatable {
    public let observationID: UUID
    public let state: StjornarvaldObservationReceiptState
    public let sequence: Int64?
}

public struct StjornarvaldObservationReceiptBatch: Codable, Sendable, Equatable {
    public let receipts: [StjornarvaldObservationSubmissionReceipt]
    public let developmentContinues: Bool
}

public struct StjornarvaldNoticeBatch: Codable, Sendable, Equatable {
    public let deliveryID: String
    public let notices: [CodingAgentPolicyNotice]
    public let controlsExecution: Bool
}

public struct StjornarvaldViolationPageItem: Codable, Sendable, Equatable {
    public let violation: PolicyViolation
    public let latestEventSequence: Int64
}

public struct StjornarvaldViolationPage: Codable, Sendable, Equatable {
    public let violations: [StjornarvaldViolationPageItem]
    public let nextCursor: Int64?
    public let controlsExecution: Bool
}

public enum StjornarvaldScanReceiptState: String, Codable, Sendable {
    case scheduled
    case deferred
}

public struct StjornarvaldScanReceipt: Codable, Sendable, Equatable {
    public let requestID: UUID
    public let state: StjornarvaldScanReceiptState
    public let acceptedAt: Date
    public let projectID: String?
    public let projectGeneration: Int?
    public let reason: String
    public let developmentContinues: Bool
}

public struct StjornarvaldNoticePresentationReceipt: Codable, Sendable, Equatable {
    public let requestID: UUID
    public let deliveryIDs: [String]
    public let state: PolicyNoticeDeliveryState
    public let controlsExecution: Bool
}

public enum StjornarvaldExportFormat: String, Codable, Sendable, CaseIterable {
    case jsonl, json, markdown, csv
}

public enum StjornarvaldExportReceiptState: String, Codable, Sendable {
    case unavailable
}

public struct StjornarvaldExportReceipt: Codable, Sendable, Equatable {
    public let requestID: UUID
    public let format: StjornarvaldExportFormat
    public let state: StjornarvaldExportReceiptState
    public let destination: String?
    public let message: String
    public let controlsExecution: Bool
}

public final class StjornarvaldManagerCoordinator: @unchecked Sendable {
    public static let maximumSourceBatchesPerActivation = 8
    public static let maximumObservationsPerActivation = 32
    public static let idleInterval: TimeInterval = 1
    public static let maximumBackoff: TimeInterval = 30

    private let lock = NSLock()
    private var sourceCatalog: StjornarvaldPolicySourceCatalog?
    private var observationRepository: StjornarvaldObservationRepository?
    private var logStore: StjornarvaldPolicyLogStore?
    private var observationService: StjornarvaldObservationService?
    private var policyReporter: StjornarvaldCodingAgentPolicyReporter?
    private var evaluator: StjornarvaldPolicyEvaluator?
    private let evaluatorIdentity: StjornarvaldEvaluatorIdentity
    private let evaluatorID: String
    private let diagnostics: @Sendable (String) -> Void
    private var task: Task<Void, Never>?
    private var desiredRunning = false
    private var state: StjornarvaldManagerState
    private var startedAt: Date?
    private var lastEvaluationAt: Date?
    private var lastCommittedCursor: Int64 = 0
    private var processedObservationCount = 0
    private var indexedSourceBatchCount = 0
    private var consecutiveFailureCount = 0
    private var lastError: String?
    private var scanReceipts: [UUID: StjornarvaldScanReceipt] = [:]
    private var scanReceiptOrder: [UUID] = []

    public init(
        paths: AppPaths,
        evaluatorID: String = "manager-stjornarvald",
        diagnostics: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.evaluatorID = evaluatorID
        self.diagnostics = diagnostics
        self.evaluatorIdentity = StjornarvaldEvaluatorIdentity(
            evaluatorID: evaluatorID,
            processID: ProcessInfo.processInfo.processIdentifier,
            bootID: UUID().uuidString.lowercased()
        )
        self.observationService = StjornarvaldObservationService(
            databaseURL: paths.stjornarvaldPolicyLogSQLite,
            outboxURL: paths.stjornarvaldOutboxDir.appendingPathComponent(
                "manager-observations", isDirectory: true
            ),
            diagnostics: diagnostics
        )
        do {
            let rules = try StjornarvaldPolicyRuleRepository(paths: paths)
            _ = try rules.installRavenBaseline()
            let observations = try StjornarvaldObservationRepository(paths: paths)
            observationRepository = observations
            let log = try StjornarvaldPolicyLogStore(
                databaseURL: paths.stjornarvaldPolicyLogSQLite,
                jsonlURL: paths.stjornarvaldPolicyLogJSONL
            )
            logStore = log
            let reporter = StjornarvaldCodingAgentPolicyReporter(paths: paths, diagnostics: diagnostics)
            policyReporter = reporter
            sourceCatalog = try StjornarvaldPolicySourceCatalog(paths: paths, diagnostics: diagnostics)
            evaluator = StjornarvaldPolicyEvaluator(
                observationRepository: observations,
                ruleRepository: rules,
                detectorRegistry: StjornarvaldDetectorRegistry(
                    detectors: [RavenNativeStackObservationDetector()]
                ),
                lifecycleService: StjornarvaldViolationLifecycleService(store: log),
                policyReporter: reporter,
                identity: evaluatorIdentity
            )
            state = .stopped
        } catch {
            sourceCatalog = nil
            observationRepository = nil
            logStore = nil
            policyReporter = nil
            evaluator = nil
            state = .degraded
            lastError = Self.boundedError(error)
            diagnostics("stjornarvald manager initialization degraded: \(error.localizedDescription)")
        }
    }

    deinit { stop() }

    public func start() {
        lock.lock()
        desiredRunning = true
        guard task == nil else { lock.unlock(); return }
        guard evaluator != nil, sourceCatalog != nil else {
            state = .degraded
            lock.unlock()
            return
        }
        state = .starting
        startedAt = Date()
        task = makeTask()
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        desiredRunning = false
        guard let current = task else {
            if state != .degraded { state = .stopped }
            lock.unlock()
            return
        }
        state = .stopping
        lock.unlock()
        current.cancel()
    }

    public func shutdown() async {
        stop()
        let current = currentTask()
        _ = await current?.result
        closeResources()
    }

    private func closeResources() {
        lock.lock()
        defer { lock.unlock() }
        evaluator = nil
        policyReporter = nil
        observationService = nil
        logStore = nil
        observationRepository = nil
        sourceCatalog = nil
        state = .stopped
    }

    private func currentTask() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return task
    }

    public func health() -> StjornarvaldManagerHealth {
        lock.lock()
        defer { lock.unlock() }
        return StjornarvaldManagerHealth(
            state: state,
            policyIdentity: RavenForgeDevelopmentPolicyAdapter.identity.bindingID,
            evaluatorID: evaluatorID,
            startedAt: startedAt,
            lastEvaluationAt: lastEvaluationAt,
            lastCommittedCursor: lastCommittedCursor,
            processedObservationCount: processedObservationCount,
            indexedSourceBatchCount: indexedSourceBatchCount,
            consecutiveFailureCount: consecutiveFailureCount,
            lastError: lastError
        )
    }

    public func snapshot(
        eventCursor: Int64 = 0,
        limit: Int = 50
    ) throws -> StjornarvaldManagerSnapshot {
        guard eventCursor >= 0, (1...100).contains(limit),
              let sourceCatalog, let logStore else {
            throw StjornarvaldObservationError.unavailable(
                "Stjornarvald snapshot is unavailable or outside bounds"
            )
        }
        let page = try logStore.events(after: eventCursor, limit: limit + 1)
        let visible = Array(page.prefix(limit))
        return StjornarvaldManagerSnapshot(
            schemaVersion: StjornarvaldManagerSnapshot.schemaVersion,
            health: health(),
            governingPolicy: RavenForgeDevelopmentPolicyAdapter.identity,
            sources: try sourceCatalog.sources(limit: limit),
            violationEvents: visible,
            nextEventCursor: page.count > limit ? visible.last?.sequence : nil,
            limitations: [
                "Presented notices prove transport, not model comprehension or correction.",
                "Source bodies and unbounded history are excluded from this snapshot.",
            ]
        )
    }

    public func addSource(selectedURL: URL, requestID: UUID) async throws
        -> DevelopmentPolicySource {
        guard let sourceCatalog else {
            throw StjornarvaldPolicySourceError.unavailable("manager source catalog unavailable")
        }
        return try await sourceCatalog.add(selectedURL: selectedURL, requestID: requestID)
    }

    public func refreshSource(sourceID: PolicySourceID, requestID: UUID) async throws
        -> DevelopmentPolicySource {
        guard let sourceCatalog else {
            throw StjornarvaldPolicySourceError.unavailable("manager source catalog unavailable")
        }
        try await sourceCatalog.refresh(sourceID: sourceID, requestID: requestID)
        guard let source = try sourceCatalog.sources(limit: 10_000).first(where: { $0.id == sourceID }) else {
            throw StjornarvaldPolicySourceError.invalidRequest("refreshed source is unavailable")
        }
        return source
    }

    public func removeSource(sourceID: PolicySourceID, requestID: UUID) async throws
        -> DevelopmentPolicySource {
        guard let sourceCatalog else {
            throw StjornarvaldPolicySourceError.unavailable("manager source catalog unavailable")
        }
        try await sourceCatalog.remove(sourceID: sourceID, requestID: requestID)
        guard let source = try sourceCatalog.sources(limit: 10_000).first(where: { $0.id == sourceID }) else {
            throw StjornarvaldPolicySourceError.invalidRequest("removed source is unavailable")
        }
        return source
    }

    public func submitObservations(
        _ observations: [DevelopmentObservation]
    ) -> StjornarvaldObservationReceiptBatch {
        let bounded = Array(observations.prefix(64))
        let receipts = bounded.map { observation in
            guard let observationService else {
                return StjornarvaldObservationSubmissionReceipt(
                    observationID: observation.id,
                    state: .deferred,
                    sequence: nil
                )
            }
            switch observationService.submitWithDisposition(observation) {
            case .persisted(let receipt):
                return StjornarvaldObservationSubmissionReceipt(
                    observationID: receipt.observationID,
                    state: .persisted,
                    sequence: receipt.sequence
                )
            case .deferred(let observationID):
                return StjornarvaldObservationSubmissionReceipt(
                    observationID: observationID,
                    state: .deferred,
                    sequence: nil
                )
            case .rejected(let observationID):
                return StjornarvaldObservationSubmissionReceipt(
                    observationID: observationID,
                    state: .rejected,
                    sequence: nil
                )
            }
        }
        return StjornarvaldObservationReceiptBatch(
            receipts: receipts,
            developmentContinues: true
        )
    }

    public func scheduleScan(
        requestID: UUID,
        projectID: String?,
        projectGeneration: Int?,
        reason: String
    ) throws -> StjornarvaldScanReceipt {
        guard projectID.map({ !$0.isEmpty && $0.utf8.count <= 1_024 }) ?? true,
              projectGeneration.map({ $0 > 0 }) ?? true,
              !reason.isEmpty,
              reason.utf8.count <= 1_024 else {
            throw StjornarvaldObservationError.invalidObservation(
                "scan target or reason is outside bounds"
            )
        }
        lock.lock()
        if let existing = scanReceipts[requestID] {
            lock.unlock()
            return existing
        }
        let receipt = StjornarvaldScanReceipt(
            requestID: requestID,
            state: desiredRunning && evaluator != nil ? .scheduled : .deferred,
            acceptedAt: Date(),
            projectID: projectID,
            projectGeneration: projectGeneration,
            reason: reason,
            developmentContinues: true
        )
        scanReceipts[requestID] = receipt
        scanReceiptOrder.append(requestID)
        if scanReceiptOrder.count > 256 {
            let expired = scanReceiptOrder.removeFirst()
            scanReceipts.removeValue(forKey: expired)
        }
        let current = receipt.state == .scheduled ? task : nil
        lock.unlock()

        // Cancellation interrupts the bounded idle wait. The run loop's
        // desired-running transition starts one successor task, while durable
        // evaluator cursors prevent duplicate violation events.
        current?.cancel()
        return receipt
    }

    public func violationPage(
        cursor: Int64,
        limit: Int,
        projectID: String?,
        state: PolicyViolationProjectionState?
    ) throws -> StjornarvaldViolationPage {
        guard cursor >= 0, (1...100).contains(limit), let logStore else {
            throw StjornarvaldObservationError.unavailable(
                "Stjornarvald violations are unavailable or outside bounds"
            )
        }
        let page = try logStore.violations(
            afterEventSequence: cursor,
            projectID: projectID,
            state: state,
            limit: limit + 1
        )
        let visible = page.prefix(limit).map {
            StjornarvaldViolationPageItem(
                violation: $0.violation,
                latestEventSequence: $0.latestEventSequence
            )
        }
        return StjornarvaldViolationPage(
            violations: visible,
            nextCursor: page.count > limit ? visible.last?.latestEventSequence : nil,
            controlsExecution: false
        )
    }

    public func unavailableExportReceipt(
        requestID: UUID,
        format: StjornarvaldExportFormat,
        destination: String?
    ) throws -> StjornarvaldExportReceipt {
        guard destination.map({
            !$0.isEmpty && $0.utf8.count <= 4_096 && ($0 as NSString).isAbsolutePath
        }) ?? true else {
            throw StjornarvaldObservationError.invalidObservation(
                "export destination must be a bounded absolute path"
            )
        }
        return StjornarvaldExportReceipt(
            requestID: requestID,
            format: format,
            state: .unavailable,
            destination: destination,
            message: "Policy export implementation is scheduled for RF-SJ-08.",
            controlsExecution: false
        )
    }

    public func pendingNotices(
        deliveryID: String,
        projectID: String?,
        projectGeneration: Int?,
        runID: String?,
        sessionID: String?,
        clientID: String?,
        maximumCount: Int,
        maximumBytes: Int
    ) async throws -> StjornarvaldNoticeBatch {
        guard !deliveryID.isEmpty, deliveryID.utf8.count <= 1_024,
              (1...64).contains(maximumCount),
              (512...StjornarvaldPolicyNoticeFormatter.maximumPresentationBytes)
                .contains(maximumBytes) else {
            throw StjornarvaldPolicyNoticeError.invalid(
                "notice delivery identity or limits are outside bounds"
            )
        }
        let notices: [CodingAgentPolicyNotice]
        if let projectID, let projectGeneration, let runID {
            guard projectGeneration > 0 else {
                throw StjornarvaldPolicyNoticeError.invalid(
                    "managed notice target generation must be positive"
                )
            }
            let snapshot = await policyReporter?.context(
                projectID: projectID,
                projectGeneration: projectGeneration,
                runID: runID,
                sessionID: sessionID,
                deliveryID: deliveryID,
                maximumCount: maximumCount,
                maximumBytes: maximumBytes
            )
            notices = snapshot?.pendingNotices ?? []
        } else if let clientID {
            let presentation = await policyReporter?.interactivePresentation(
                deliveryID: deliveryID,
                projectID: projectID,
                projectGeneration: projectGeneration,
                clientID: clientID,
                maximumCount: maximumCount,
                maximumBytes: maximumBytes
            )
            notices = presentation?.notices ?? []
        } else {
            throw StjornarvaldPolicyNoticeError.invalid(
                "notice request requires a managed run target or client identity"
            )
        }
        return StjornarvaldNoticeBatch(
            deliveryID: deliveryID,
            notices: notices,
            controlsExecution: false
        )
    }

    public func markNoticePresented(deliveryID: String) async throws {
        guard let policyReporter else {
            throw StjornarvaldPolicyNoticeError.unavailable("manager reporter unavailable")
        }
        try await policyReporter.confirmPresented(deliveryIDs: [deliveryID])
    }

    public func markNoticesPresented(deliveryIDs: [String]) async throws {
        guard let policyReporter else {
            throw StjornarvaldPolicyNoticeError.unavailable("manager reporter unavailable")
        }
        try await policyReporter.confirmPresented(deliveryIDs: deliveryIDs)
    }

    private static func processSourceBatches(
        sourceCatalog: StjornarvaldPolicySourceCatalog?
    ) throws -> Int {
        guard let sourceCatalog else { return 0 }
        var count = 0
        for source in try sourceCatalog.sources(includeRemoved: false)
            where count < Self.maximumSourceBatchesPerActivation
                && source.interpretationState != .indexed
                && source.interpretationState != .sourceUnavailable {
            _ = try sourceCatalog.runNextBatch(
                sourceID: source.id,
                maximumWorkItems: 32,
                maximumBytes: 1_048_576
            )
            count += 1
        }
        return count
    }

    private func recordRunning() {
        lock.lock()
        state = .running
        lock.unlock()
    }

    private func recordSuccess(
        report: StjornarvaldEvaluationRunReport,
        sourceBatches: Int
    ) {
        lock.lock()
        state = .running
        lastEvaluationAt = Date()
        lastCommittedCursor = report.lastCommittedCursor
        processedObservationCount += report.processedObservationIDs.count
        indexedSourceBatchCount += sourceBatches
        consecutiveFailureCount = 0
        lastError = nil
        lock.unlock()
    }

    private func recordFailure(_ error: Error) -> TimeInterval {
        lock.lock()
        state = .degraded
        consecutiveFailureCount = min(consecutiveFailureCount + 1, 30)
        lastError = Self.boundedError(error)
        let failures = consecutiveFailureCount
        lock.unlock()
        diagnostics("stjornarvald manager work deferred: \(error.localizedDescription)")
        return min(pow(2, Double(max(0, failures - 1))), Self.maximumBackoff)
    }

    private func makeTask() -> Task<Void, Never> {
        let evaluator = self.evaluator
        let sourceCatalog = self.sourceCatalog
        return Task { [weak self, evaluator, sourceCatalog] in
            self?.recordRunning()
            while !Task.isCancelled {
                guard self != nil else { return }
                do {
                    let sourceBatches = try Self.processSourceBatches(
                        sourceCatalog: sourceCatalog
                    )
                    guard let evaluator else { return }
                    let report = try await evaluator.runOnce(
                        maximumObservations: Self.maximumObservationsPerActivation
                    )
                    self?.recordSuccess(report: report, sourceBatches: sourceBatches)
                    if sourceBatches == 0, report.processedObservationIDs.isEmpty {
                        try await Task.sleep(for: .seconds(Self.idleInterval))
                    }
                } catch is CancellationError {
                    break
                } catch {
                    guard let delay = self?.recordFailure(error) else { return }
                    do { try await Task.sleep(for: .seconds(delay)) }
                    catch { break }
                }
            }
            self?.finishRunLoop()
        }
    }

    private func finishRunLoop() {
        lock.lock()
        task = nil
        let shouldReleaseLease: Bool
        if desiredRunning, evaluator != nil, sourceCatalog != nil {
            state = .starting
            task = makeTask()
            shouldReleaseLease = false
        } else if state != .degraded {
            state = .stopped
            shouldReleaseLease = true
        } else {
            shouldReleaseLease = true
        }
        lock.unlock()
        if shouldReleaseLease {
            do { try observationRepository?.releaseLease(identity: evaluatorIdentity) }
            catch {
                diagnostics(
                    "stjornarvald evaluator lease release deferred: \(error.localizedDescription)"
                )
            }
        }
    }

    private static func boundedError(_ error: Error) -> String {
        String(error.localizedDescription.prefix(1_024))
    }
}
