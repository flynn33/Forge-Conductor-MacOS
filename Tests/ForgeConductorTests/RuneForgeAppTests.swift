import AppKit
import Foundation
import XCTest
@testable import ForgeConductorCore
#if SWIFT_PACKAGE
@testable import ForgeConductorApp
#else
@testable import Forge_Conductor
#endif

@MainActor
final class RuneForgeAppTests: XCTestCase {
    func testNativePickerAcceptsFilesAndFoldersWithoutContentTypeAllowlist() {
        let panel = RuneForgePolicyPicker.makePanel()

        XCTAssertTrue(panel.canChooseFiles)
        XCTAssertTrue(panel.canChooseDirectories)
        XCTAssertFalse(panel.canCreateDirectories)
        XCTAssertTrue(panel.allowsMultipleSelection)
        XCTAssertTrue(panel.allowsOtherFileTypes)
        XCTAssertTrue(panel.allowedContentTypes.isEmpty)
        XCTAssertEqual(panel.prompt, "Add Development Policy")
        XCTAssertEqual(
            panel.message,
            "Choose any file or folder containing development policy, governance, or guidance."
        )
    }

    func testTestSelectionHookRequiresExplicitUITestLaunch() {
        let path = "/tmp/rune-policy-selection.opaque"
        XCTAssertEqual(
            RuneForgePolicyPicker.select(
                arguments: ["Forge Conductor", "--uitesting"],
                environment: [RuneForgePolicyPicker.testSelectionEnvironmentKey: path]
            ).first?.path,
            path
        )
    }

    func testNativeExportPickerUsesExactFormatAndUITestHook() {
        let jsonl = RuneForgePolicyPicker.makeExportPanel(format: .jsonl)
        XCTAssertTrue(jsonl.canCreateDirectories)
        XCTAssertFalse(jsonl.isExtensionHidden)
        XCTAssertFalse(jsonl.allowsOtherFileTypes)
        XCTAssertEqual(jsonl.prompt, "Export Policy Log")
        XCTAssertEqual(jsonl.nameFieldStringValue, "stjornarvald-policy-log.jsonl")
        XCTAssertEqual(jsonl.allowedContentTypes.first?.preferredFilenameExtension, "jsonl")

        let path = "/tmp/stjornarvald-export.csv"
        XCTAssertEqual(
            RuneForgePolicyPicker.selectExportDestination(
                format: .csv,
                arguments: ["Forge Conductor", "--uitesting"],
                environment: [RuneForgePolicyPicker.testExportEnvironmentKey: path]
            )?.path,
            path
        )
    }

    func testSelectedSourceAppearsImmediatelyAndSurvivesDeferredManager() async throws {
        let client = DeferredRuneForgeClient()
        let viewModel = RuneForgeViewModel(client: client)
        let source = URL(fileURLWithPath: "/tmp/policy.unsupported-format")

        viewModel.addPolicySource(source)

        XCTAssertEqual(viewModel.sources.count, 1)
        XCTAssertEqual(viewModel.sources.first?.displayName, "policy.unsupported-format")
        XCTAssertEqual(viewModel.sources.first?.interpretationState, .accepted)
        XCTAssertTrue(viewModel.sources.first?.isOptimistic == true)

        try await waitUntil { viewModel.errorMessage != nil }
        XCTAssertEqual(viewModel.sources.count, 1)
        XCTAssertEqual(viewModel.sources.first?.interpretationState, .refreshPending)
        XCTAssertTrue(viewModel.sources.first?.latestObservation?.contains("remains visible") == true)
    }

    func testSuccessfulCatalogConfirmationReplacesOptimisticSource() async throws {
        let source = DevelopmentPolicySource(
            displayName: "policy-folder",
            selectedPath: "/tmp/policy-folder",
            rootKind: .directory,
            interpretationState: .cataloging,
            latestObservation: "Directory discovery is in progress."
        )
        let client = ConfirmingRuneForgeClient(source: source)
        let viewModel = RuneForgeViewModel(client: client)

        viewModel.addPolicySource(URL(fileURLWithPath: source.selectedPath, isDirectory: true))
        try await waitUntil { viewModel.sources.first?.sourceID == source.id }

        XCTAssertEqual(viewModel.sources.count, 1)
        XCTAssertFalse(viewModel.sources[0].isOptimistic)
        XCTAssertEqual(viewModel.sources[0].interpretationState, .cataloging)
        XCTAssertEqual(
            RuneForgeViewModel.sourceStateTitle(viewModel.sources[0].interpretationState),
            "Cataloging"
        )
    }

    func testOptimisticSourcePresentationIsBounded() {
        let viewModel = RuneForgeViewModel(client: DeferredRuneForgeClient())

        for index in 0...RuneForgeViewModel.maximumSources {
            viewModel.addPolicySource(
                URL(fileURLWithPath: "/tmp/policy-\(index).opaque")
            )
        }

        XCTAssertEqual(viewModel.sources.count, RuneForgeViewModel.maximumSources)
        XCTAssertEqual(viewModel.sources.first?.displayName, "policy-0.opaque")
        XCTAssertNil(
            viewModel.sources.first(where: { $0.displayName == "policy-100.opaque" })
        )
    }

    func testPolicyFeedEventsAreNewestFirstAndBounded() async {
        let events = (1...RuneForgeViewModel.maximumEvents + 1).map {
            policyEvent(sequence: Int64($0))
        }
        let viewModel = RuneForgeViewModel(
            client: SnapshotRuneForgeClient(snapshot: policySnapshot(events: events))
        )

        await viewModel.refreshNow()

        XCTAssertEqual(viewModel.events.count, RuneForgeViewModel.maximumEvents)
        XCTAssertEqual(viewModel.events.first?.sequence, Int64(RuneForgeViewModel.maximumEvents + 1))
        XCTAssertEqual(viewModel.events.last?.sequence, 2)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testZeroViolationsRetainsExplicitEvaluationCoverageAndUnknownFallback() async {
        let coverage = "Automatic detection covers 1 of 15 indexed Raven rules; other rules are guidance."
        let viewModel = RuneForgeViewModel(client: SnapshotRuneForgeClient(
            snapshot: policySnapshot(events: [], limitations: [coverage])))
        XCTAssertEqual(viewModel.evaluationCoverageDescription,
                       "Automatic policy evaluation coverage is unavailable.")
        await viewModel.refreshNow()
        XCTAssertTrue(viewModel.violations.isEmpty)
        XCTAssertEqual(viewModel.evaluationCoverageDescription, coverage)
    }

    func testProjectLogIDsIncludeRegisteredAndObservedProjectsExactlyOnce() {
        let observed = policyEvent(sequence: 1, projectID: "project-observed")
        XCTAssertEqual(
            RuneForgeViewModel.projectLogIDs(
                registeredProjectIDs: ["project-registered", "project-observed"],
                events: [observed]
            ),
            ["project-observed", "project-registered"]
        )
        let filters = StjornarvaldExportFilters(projectID: "project-observed")
        XCTAssertEqual(filters.projectID, "project-observed")
        XCTAssertNil(filters.projectGeneration)
    }

    func testPolicyEventStateTitlesExposeEveryStateWithoutRelyingOnColor() {
        XCTAssertEqual(RuneForgeViewModel.eventStateTitle(.opened), "Policy violation")
        XCTAssertEqual(RuneForgeViewModel.eventStateTitle(.repeated), "Repeated")
        XCTAssertEqual(RuneForgeViewModel.eventStateTitle(.evidenceUpdated), "Evidence updated")
        XCTAssertEqual(RuneForgeViewModel.eventStateTitle(.corrected), "Corrected")
        XCTAssertEqual(RuneForgeViewModel.eventStateTitle(.reopened), "Reopened")
        XCTAssertEqual(RuneForgeViewModel.eventStateTitle(.disputed), "Interpretation observation")
    }

    func testNewerPolicyReorderSurvivesOlderLateSuccess() async throws {
        try await assertNewerPolicyReorderSurvivesOlderCompletion(.success)
    }

    func testNewerPolicyReorderSurvivesOlderLateCancellation() async throws {
        try await assertNewerPolicyReorderSurvivesOlderCompletion(.cancelled)
    }

    func testNewerPolicyReorderSurvivesOlderLateFailure() async throws {
        try await assertNewerPolicyReorderSurvivesOlderCompletion(.failure)
    }

    func testCurrentPolicyReorderCancellationRestoresPriorOrder() async throws {
        try await assertCurrentPolicyReorderRestoresPriorOrder(.cancelled)
    }

    func testCurrentPolicyReorderFailureRestoresPriorOrderAndError() async throws {
        try await assertCurrentPolicyReorderRestoresPriorOrder(.failure)
    }

    private func assertCurrentPolicyReorderRestoresPriorOrder(
        _ completion: ControlledRuneReorderClient.Completion
    ) async throws {
        let sources = ["A", "B", "C"].map {
            DevelopmentPolicySource(displayName: $0, selectedPath: "/tmp/rune-current-reorder-\($0)")
        }
        let client = ControlledRuneReorderClient(
            snapshot: policySnapshot(events: [], sources: sources)
        )
        let model = RuneForgeViewModel(client: client)
        defer {
            model.stop()
            client.cancelPendingRequests()
        }
        await model.refreshNow()
        model.movePolicySource(sources[0].id.description, to: sources[2].id.description)
        try await waitUntil { client.requestCount == 1 }
        XCTAssertEqual(model.sources.compactMap(\.sourceID), [sources[1].id, sources[2].id, sources[0].id])
        client.complete(request: 0, with: completion)
        try await waitUntil { client.returnedRequests == [0] }
        await Task.yield()
        XCTAssertEqual(model.sources.compactMap(\.sourceID), sources.map(\.id))
        XCTAssertEqual(client.pendingRequestCount, 0)
        XCTAssertNil(model.noticeMessage)
        switch completion {
        case .failure: XCTAssertNotNil(model.errorMessage)
        case .cancelled: XCTAssertNil(model.errorMessage)
        case .success: XCTFail("This rollback control requires cancellation or failure")
        }
    }

    private func assertNewerPolicyReorderSurvivesOlderCompletion(
        _ completion: ControlledRuneReorderClient.Completion
    ) async throws {
        let sources = ["A", "B", "C"].map {
            DevelopmentPolicySource(displayName: $0, selectedPath: "/tmp/rune-reorder-\($0)")
        }
        let client = ControlledRuneReorderClient(
            snapshot: policySnapshot(events: [], sources: sources)
        )
        let model = RuneForgeViewModel(client: client)
        defer {
            model.stop()
            client.cancelPendingRequests()
        }
        await model.refreshNow()
        XCTAssertEqual(model.sources.compactMap(\.sourceID), sources.map(\.id))

        model.movePolicySource(sources[0].id.description, to: sources[2].id.description)
        try await waitUntil { client.requestCount == 1 }
        let olderOrder = [sources[1].id, sources[2].id, sources[0].id]
        XCTAssertEqual(client.requestedOrders.first, olderOrder)
        XCTAssertEqual(model.sources.compactMap(\.sourceID), olderOrder)

        model.movePolicySource(sources[1].id.description, to: sources[0].id.description)
        try await waitUntil { client.requestCount == 2 }
        let newerOrder = [sources[2].id, sources[0].id, sources[1].id]
        XCTAssertEqual(client.requestedOrders.last, newerOrder)
        XCTAssertEqual(model.sources.compactMap(\.sourceID), newerOrder)

        client.complete(request: 1, with: .success)
        try await waitUntil { client.returnedRequests == [1] }
        await Task.yield()
        XCTAssertEqual(model.sources.compactMap(\.sourceID), newerOrder)
        XCTAssertEqual(model.noticeMessage, "Development Policy priority updated.")
        XCTAssertNil(model.errorMessage)

        // The protocol client deliberately finishes an already-cancelled request
        // after the newer response. Its same-main-actor return is the completion
        // witness; no network delay or unbounded sleep establishes this order.
        client.complete(request: 0, with: completion)
        try await waitUntil { client.returnedRequests == [1, 0] }
        await Task.yield()
        XCTAssertEqual(client.cancelledAtReturn[0], true)
        XCTAssertEqual(client.requestCount, 2)
        XCTAssertEqual(client.pendingRequestCount, 0)
        XCTAssertEqual(model.sources.compactMap(\.sourceID), newerOrder)
        XCTAssertEqual(model.noticeMessage, "Development Policy priority updated.")
        XCTAssertNil(model.errorMessage)
    }

    private func policySnapshot(events: [PolicyViolationEvent], limitations: [String] = [], sources: [DevelopmentPolicySource] = []) -> StjornarvaldManagerSnapshot {
        let sourceID = PolicySourceID()
        return StjornarvaldManagerSnapshot(
            schemaVersion: StjornarvaldManagerSnapshot.schemaVersion,
            health: StjornarvaldManagerHealth(
                state: .running,
                policyIdentity: "fixture-policy",
                evaluatorID: "fixture-evaluator",
                startedAt: Date(timeIntervalSince1970: 1),
                lastEvaluationAt: Date(timeIntervalSince1970: 2),
                lastCommittedCursor: events.last?.sequence ?? 0,
                processedObservationCount: events.count,
                indexedSourceBatchCount: 1,
                consecutiveFailureCount: 0,
                lastError: nil
            ),
            governingPolicy: GoverningPolicyIdentity(
                bindingID: "fixture-policy",
                authority: "Fixture",
                repositoryURL: "https://example.invalid/policy",
                version: "1",
                revision: "fixture-revision",
                sourceID: sourceID
            ),
            sources: sources,
            violationEvents: events,
            nextEventCursor: nil,
            limitations: limitations
        )
    }

    private func policyEvent(sequence: Int64, projectID: String? = nil) -> PolicyViolationEvent {
        let sourceID = PolicySourceID()
        let rule = PolicyRule(
            id: PolicyRuleID("fixture-rule-\(sequence)"),
            source: PolicySourceReference(
                sourceID: sourceID,
                revision: "fixture-revision",
                path: "/tmp/policy.md",
                locator: "line \(sequence)"
            ),
            statement: "Keep the implementation native.",
            policyArea: "runtime",
            applicability: "fixture",
            confidence: 1
        )
        let candidate = PolicyViolationCandidate(
            rule: rule,
            observationID: UUID(),
            scope: DevelopmentObservationScope(projectID: projectID),
            subjectIdentity: "fixture-subject",
            summary: "Fixture policy event \(sequence)",
            evidenceReferences: ["fixture.swift:\(sequence)"],
            explanation: "The fixture observed a policy mismatch.",
            confidence: 0.9,
            assumptions: ["The fixture is representative."],
            alternatives: ["Retain the native implementation."],
            suggestedCorrection: "Use the approved native framework."
        )
        return PolicyViolationEvent(
            schemaVersion: "1.0.0",
            sequence: sequence,
            id: UUID(),
            type: .opened,
            occurredAt: Date(timeIntervalSince1970: TimeInterval(sequence)),
            violationID: PolicyViolationID(),
            fingerprint: "fixture-fingerprint-\(sequence)",
            candidate: candidate,
            noticeState: "presented",
            priorEventSHA256: nil,
            eventSHA256: String(repeating: "a", count: 64),
            developmentContinues: true
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        predicate: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !predicate() {
            guard clock.now < deadline else { return XCTFail("condition timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private struct SnapshotRuneForgeClient: RuneForgeManagerClientProtocol {
    let snapshot: StjornarvaldManagerSnapshot

    func runeForgeSnapshot() async throws -> StjornarvaldManagerSnapshot { snapshot }

    func addRuneForgeSource(
        path: String,
        requestID: UUID
    ) async throws -> DevelopmentPolicySource { throw URLError(.unsupportedURL) }

    func refreshRuneForgeSource(
        sourceID: PolicySourceID,
        requestID: UUID
    ) async throws -> DevelopmentPolicySource { throw URLError(.unsupportedURL) }

    func removeRuneForgeSource(
        sourceID: PolicySourceID,
        requestID: UUID
    ) async throws -> DevelopmentPolicySource { throw URLError(.unsupportedURL) }

    func runeForgeViolations(
        cursor: Int64,
        limit: Int,
        state: PolicyViolationProjectionState?
    ) async throws -> StjornarvaldViolationPage {
        StjornarvaldViolationPage(violations: [], nextCursor: nil, controlsExecution: false)
    }

    func scheduleRuneForgeScan(
        requestID: UUID,
        reason: String
    ) async throws -> StjornarvaldScanReceipt { throw URLError(.unsupportedURL) }

    func requestRuneForgeExport(
        format: StjornarvaldExportFormat,
        destination: String,
        filters: StjornarvaldExportFilters,
        requestID: UUID
    ) async throws -> StjornarvaldExportReceipt { throw URLError(.unsupportedURL) }
}

private struct DeferredRuneForgeClient: RuneForgeManagerClientProtocol {
    func runeForgeSnapshot() async throws -> StjornarvaldManagerSnapshot {
        throw URLError(.cannotConnectToHost)
    }

    func addRuneForgeSource(
        path: String,
        requestID: UUID
    ) async throws -> DevelopmentPolicySource {
        try await Task.sleep(for: .milliseconds(25))
        throw URLError(.cannotConnectToHost)
    }

    func refreshRuneForgeSource(
        sourceID: PolicySourceID,
        requestID: UUID
    ) async throws -> DevelopmentPolicySource { throw URLError(.cannotConnectToHost) }

    func removeRuneForgeSource(
        sourceID: PolicySourceID,
        requestID: UUID
    ) async throws -> DevelopmentPolicySource { throw URLError(.cannotConnectToHost) }

    func runeForgeViolations(
        cursor: Int64,
        limit: Int,
        state: PolicyViolationProjectionState?
    ) async throws -> StjornarvaldViolationPage { throw URLError(.cannotConnectToHost) }

    func scheduleRuneForgeScan(
        requestID: UUID,
        reason: String
    ) async throws -> StjornarvaldScanReceipt { throw URLError(.cannotConnectToHost) }

    func requestRuneForgeExport(
        format: StjornarvaldExportFormat,
        destination: String,
        filters: StjornarvaldExportFilters,
        requestID: UUID
    ) async throws -> StjornarvaldExportReceipt { throw URLError(.cannotConnectToHost) }
}

private struct ConfirmingRuneForgeClient: RuneForgeManagerClientProtocol {
    let source: DevelopmentPolicySource

    func runeForgeSnapshot() async throws -> StjornarvaldManagerSnapshot {
        throw URLError(.cannotConnectToHost)
    }

    func addRuneForgeSource(
        path: String,
        requestID: UUID
    ) async throws -> DevelopmentPolicySource { source }

    func refreshRuneForgeSource(
        sourceID: PolicySourceID,
        requestID: UUID
    ) async throws -> DevelopmentPolicySource { source }

    func removeRuneForgeSource(
        sourceID: PolicySourceID,
        requestID: UUID
    ) async throws -> DevelopmentPolicySource { source }

    func runeForgeViolations(
        cursor: Int64,
        limit: Int,
        state: PolicyViolationProjectionState?
    ) async throws -> StjornarvaldViolationPage { throw URLError(.cannotConnectToHost) }

    func scheduleRuneForgeScan(
        requestID: UUID,
        reason: String
    ) async throws -> StjornarvaldScanReceipt { throw URLError(.cannotConnectToHost) }

    func requestRuneForgeExport(
        format: StjornarvaldExportFormat,
        destination: String,
        filters: StjornarvaldExportFilters,
        requestID: UUID
    ) async throws -> StjornarvaldExportReceipt { throw URLError(.cannotConnectToHost) }
}

@MainActor
private final class ControlledRuneReorderClient: RuneForgeManagerClientProtocol {
    enum Completion { case success, cancelled, failure }
    private let snapshot: StjornarvaldManagerSnapshot
    private var continuations: [Int: CheckedContinuation<[DevelopmentPolicySource], Error>] = [:]
    private(set) var requestedOrders: [[PolicySourceID]] = []
    private(set) var returnedRequests: [Int] = []
    private(set) var cancelledAtReturn: [Int: Bool] = [:]
    var requestCount: Int { requestedOrders.count }
    var pendingRequestCount: Int { continuations.count }

    init(snapshot: StjornarvaldManagerSnapshot) { self.snapshot = snapshot }

    func reorderRuneForgeSources(sourceIDs: [PolicySourceID]) async throws -> [DevelopmentPolicySource] {
        guard requestedOrders.count < 2 else { throw URLError(.badServerResponse) }
        let request = requestedOrders.count
        requestedOrders.append(sourceIDs)
        defer {
            cancelledAtReturn[request] = Task.isCancelled
            returnedRequests.append(request)
        }
        return try await withCheckedThrowingContinuation { continuation in
            continuations[request] = continuation
        }
    }

    func complete(request: Int, with completion: Completion) {
        guard let continuation = continuations.removeValue(forKey: request) else {
            XCTFail("Missing pending reorder request \(request)")
            return
        }
        switch completion {
        case .success:
            let byID = Dictionary(uniqueKeysWithValues: snapshot.sources.map { ($0.id, $0) })
            continuation.resume(returning: requestedOrders[request].compactMap { byID[$0] })
        case .cancelled: continuation.resume(throwing: CancellationError())
        case .failure: continuation.resume(throwing: URLError(.cannotConnectToHost))
        }
    }

    func cancelPendingRequests() {
        let pending = continuations.values
        continuations.removeAll()
        for continuation in pending { continuation.resume(throwing: CancellationError()) }
    }

    func runeForgeSnapshot() async throws -> StjornarvaldManagerSnapshot { snapshot }
    func addRuneForgeSource(path: String, requestID: UUID) async throws -> DevelopmentPolicySource {
        throw URLError(.unsupportedURL)
    }
    func refreshRuneForgeSource(sourceID: PolicySourceID, requestID: UUID) async throws -> DevelopmentPolicySource {
        throw URLError(.unsupportedURL)
    }
    func removeRuneForgeSource(sourceID: PolicySourceID, requestID: UUID) async throws -> DevelopmentPolicySource {
        throw URLError(.unsupportedURL)
    }
    func runeForgeViolations(cursor: Int64, limit: Int,
                             state: PolicyViolationProjectionState?) async throws -> StjornarvaldViolationPage {
        StjornarvaldViolationPage(violations: [], nextCursor: nil, controlsExecution: false)
    }
    func scheduleRuneForgeScan(requestID: UUID, reason: String) async throws -> StjornarvaldScanReceipt {
        throw URLError(.unsupportedURL)
    }
    func requestRuneForgeExport(format: StjornarvaldExportFormat, destination: String,
                               filters: StjornarvaldExportFilters,
                               requestID: UUID) async throws -> StjornarvaldExportReceipt {
        throw URLError(.unsupportedURL)
    }
}
