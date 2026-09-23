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
    func testNativePickerAcceptsOneFileOrFolderWithoutContentTypeAllowlist() {
        let panel = RuneForgePolicyPicker.makePanel()

        XCTAssertTrue(panel.canChooseFiles)
        XCTAssertTrue(panel.canChooseDirectories)
        XCTAssertFalse(panel.canCreateDirectories)
        XCTAssertFalse(panel.allowsMultipleSelection)
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
            )?.path,
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
        XCTAssertEqual(viewModel.sources.first?.displayName, "policy-100.opaque")
        XCTAssertNil(
            viewModel.sources.first(where: { $0.displayName == "policy-0.opaque" })
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

    func testPolicyEventStateTitlesExposeEveryStateWithoutRelyingOnColor() {
        XCTAssertEqual(RuneForgeViewModel.eventStateTitle(.opened), "Policy violation")
        XCTAssertEqual(RuneForgeViewModel.eventStateTitle(.repeated), "Repeated")
        XCTAssertEqual(RuneForgeViewModel.eventStateTitle(.evidenceUpdated), "Evidence updated")
        XCTAssertEqual(RuneForgeViewModel.eventStateTitle(.corrected), "Corrected")
        XCTAssertEqual(RuneForgeViewModel.eventStateTitle(.reopened), "Reopened")
        XCTAssertEqual(RuneForgeViewModel.eventStateTitle(.disputed), "Interpretation observation")
    }

    private func policySnapshot(events: [PolicyViolationEvent]) -> StjornarvaldManagerSnapshot {
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
            sources: [],
            violationEvents: events,
            nextEventCursor: nil,
            limitations: []
        )
    }

    private func policyEvent(sequence: Int64) -> PolicyViolationEvent {
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
