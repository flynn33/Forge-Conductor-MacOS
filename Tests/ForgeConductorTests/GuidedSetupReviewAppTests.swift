import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import ForgeConductorApp
#else
@testable import Forge_Conductor
#endif
@testable import ForgeConductorCore

@MainActor
final class GuidedSetupReviewAppTests: XCTestCase {
    func testIdleRegisteredProjectCanBeReviewedWithoutBecomingDashboardActive() async throws {
        let client = try GuidedSetupReviewClient()
        let model = GuidedSetupReviewViewModel(client: client)
        await model.loadProjects()
        await model.loadSelection()

        let evidence = try await client.snapshot(limit: 100, cursor: nil)
        XCTAssertTrue(evidence.runs.isEmpty)
        XCTAssertTrue(evidence.projects.allSatisfy { $0.bindings.isEmpty })
        XCTAssertNil(RigOperationalSnapshot.trackedProject(operatorSnapshot: evidence, liveMCPClientIDs: []))
        let snapshot = model.snapshot(base: .unavailable)
        let fingerprint = try XCTUnwrap(snapshot.guidedSetupPreparationFingerprint)
        let progress = GuidedSetupProgress.compose(
            managerReady: true,
            snapshot: snapshot,
            reviewedPreparationFingerprint: fingerprint
        )
        XCTAssertEqual(progress.preparationState, .reviewed(fingerprint: fingerprint))
        XCTAssertEqual(progress.recommendedStep, .start)
        XCTAssertNil(snapshot.activeRunState)
        XCTAssertNil(model.errorMessage)
        let requests = await client.requestNames()
        XCTAssertTrue(requests.allSatisfy {
            ["snapshot", "providerIntegrations", "providerConfiguration", "projectStatus", "instructionQueue"].contains($0)
        }, "Preparation may only read state; it must not activate, bind, probe or dispatch")
    }

    func testMultipleProjectsRequireSelectionAndClearPriorReviewImmediately() async throws {
        let client = try GuidedSetupReviewClient(includeSecondProject: true)
        let model = GuidedSetupReviewViewModel(client: client)
        await model.loadProjects()
        XCTAssertNil(model.selectedProjectID)
        XCTAssertNil(model.snapshot(base: .unavailable).guidedSetupPreparationFingerprint)

        model.selectedProjectID = GuidedSetupReviewClient.firstID
        await model.loadSelection()
        let first = try XCTUnwrap(model.snapshot(base: .unavailable).guidedSetupPreparationFingerprint)
        model.selectedProjectID = GuidedSetupReviewClient.secondID
        XCTAssertNil(model.instructionQueue)
        XCTAssertNil(model.snapshot(base: .unavailable).guidedSetupPreparationFingerprint)
        await model.loadSelection()
        XCTAssertEqual(model.loadedProject?.projectID, GuidedSetupReviewClient.secondID)
        XCTAssertNotEqual(first, model.snapshot(base: .unavailable).guidedSetupPreparationFingerprint)
    }

    func testSelectionDriftRejectsAnOlderInFlightProjectResponse() async throws {
        let client = try GuidedSetupReviewClient(includeSecondProject: true)
        let model = GuidedSetupReviewViewModel(client: client)
        await model.loadProjects(preferredProjectID: GuidedSetupReviewClient.firstID)
        await client.holdProjectStatus(GuidedSetupReviewClient.firstID)
        let oldLoad = Task { await model.loadSelection() }
        try await waitForHeldStatus(client)
        model.selectedProjectID = GuidedSetupReviewClient.secondID
        await model.loadSelection()
        let second = try XCTUnwrap(model.snapshot(base: .unavailable).guidedSetupPreparationFingerprint)
        await client.releaseProjectStatus()
        await oldLoad.value
        XCTAssertEqual(model.loadedProject?.projectID, GuidedSetupReviewClient.secondID)
        XCTAssertEqual(second, model.snapshot(base: .unavailable).guidedSetupPreparationFingerprint)
        let queueProjects = await client.queueProjectIDs()
        XCTAssertEqual(queueProjects, [GuidedSetupReviewClient.secondID])
    }

    func testCancelledSheetLoadCannotPublishReviewEvidence() async throws {
        let client = try GuidedSetupReviewClient()
        let model = GuidedSetupReviewViewModel(client: client)
        await model.loadProjects()
        await client.holdProjectStatus(GuidedSetupReviewClient.firstID)
        let load = Task { await model.loadSelection() }
        try await waitForHeldStatus(client)
        load.cancel()
        await client.releaseProjectStatus()
        await load.value
        XCTAssertNil(model.loadedProject)
        XCTAssertNil(model.instructionQueue)
        XCTAssertNil(model.snapshot(base: .unavailable).guidedSetupPreparationFingerprint)
        XCTAssertFalse(model.isLoading)
    }

    func testProviderConfigurationRevisionInvalidatesExactReview() async throws {
        let client = try GuidedSetupReviewClient()
        let model = GuidedSetupReviewViewModel(client: client)
        await model.loadProjects()
        await model.loadSelection()
        let reviewed = try XCTUnwrap(model.snapshot(base: .unavailable).guidedSetupPreparationFingerprint)
        await client.changeProviderRevision("configuration-2")
        await model.loadSelection()
        let progress = GuidedSetupProgress.compose(
            managerReady: true,
            snapshot: model.snapshot(base: .unavailable),
            reviewedPreparationFingerprint: reviewed
        )
        guard case .needsReview(let current) = progress.preparationState else {
            return XCTFail("A saved provider configuration change must require a new exact review")
        }
        XCTAssertNotEqual(current, reviewed)
    }

    func testRefreshOfSameProjectRejectsAnOlderInFlightSelectionLoad() async throws {
        let client = try GuidedSetupReviewClient()
        let model = GuidedSetupReviewViewModel(client: client)
        await model.loadProjects()
        await model.loadSelection()
        let reviewed = try XCTUnwrap(model.snapshot(base: .unavailable).guidedSetupPreparationFingerprint)
        await client.holdProjectStatus(GuidedSetupReviewClient.firstID)
        let oldLoad = Task { await model.loadSelection() }
        try await waitForHeldStatus(client)

        await client.changeProviderRevision("configuration-after-refresh")
        await model.loadProjects(preferredProjectID: GuidedSetupReviewClient.firstID)
        XCTAssertEqual(model.selectedProjectID, GuidedSetupReviewClient.firstID)
        XCTAssertNil(model.instructionQueue)
        XCTAssertNil(model.snapshot(base: .unavailable).guidedSetupPreparationFingerprint)
        await client.releaseProjectStatus()
        await oldLoad.value
        XCTAssertNil(model.loadedProject,
                     "Refreshing unchanged selection must invalidate its older request, not just its queue")
        XCTAssertNil(model.snapshot(base: .unavailable).guidedSetupPreparationFingerprint)

        await model.loadSelection()
        let refreshed = try XCTUnwrap(model.snapshot(base: .unavailable).guidedSetupPreparationFingerprint)
        XCTAssertNotEqual(refreshed, reviewed)
        let queueProjects = await client.queueProjectIDs()
        XCTAssertEqual(queueProjects, [GuidedSetupReviewClient.firstID, GuidedSetupReviewClient.firstID],
                       "The superseded request must not request or publish an older instruction queue")
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.errorMessage)
    }

    func testQueueGenerationMismatchAndReadFailureCannotRetainReadyReview() async throws {
        let client = try GuidedSetupReviewClient()
        let model = GuidedSetupReviewViewModel(client: client)
        await model.loadProjects()
        await model.loadSelection()
        XCTAssertNotNil(model.snapshot(base: .unavailable).guidedSetupPreparationFingerprint)
        await client.setQueueGenerationOffset(1)
        await model.loadSelection()
        XCTAssertNotNil(model.errorMessage)
        XCTAssertNil(model.instructionQueue)
        XCTAssertNil(model.snapshot(base: .unavailable).guidedSetupPreparationFingerprint)
        await client.setQueueGenerationOffset(0)
        await model.loadSelection()
        XCTAssertNil(model.errorMessage)
        XCTAssertNotNil(model.snapshot(base: .unavailable).guidedSetupPreparationFingerprint)
        await client.failProviderConfiguration()
        await model.loadSelection()
        XCTAssertNotNil(model.errorMessage)
        XCTAssertNil(model.snapshot(base: .unavailable).guidedSetupPreparationFingerprint)
    }

    private func waitForHeldStatus(_ client: GuidedSetupReviewClient) async throws {
        for _ in 0..<200 {
            if await client.isStatusHeld() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw GuidedSetupReviewFixtureError.deadline
    }
}

private enum GuidedSetupReviewFixtureError: Error { case unexpectedCall, unavailable, deadline }

private actor GuidedSetupReviewClient: OperatorManagerClientProtocol {
    static let firstID = "11111111-1111-4111-8111-111111111111"
    static let secondID = "22222222-2222-4222-8222-222222222222"
    private let registeredProjects: [OperatorProject]
    private var requests: [String] = []
    private var queueProjects: [String] = []
    private var providerRevision = "configuration-1"
    private var providerConfigurationUnavailable = false
    private var queueGenerationOffset: UInt64 = 0
    private var heldProjectID: String?
    private var heldStatus: CheckedContinuation<Void, Never>?

    init(includeSecondProject: Bool = false) throws {
        registeredProjects = try (includeSecondProject ? [Self.firstID, Self.secondID] : [Self.firstID])
            .enumerated().map { offset, id in
                try Self.decode(OperatorProject.self, [
                    "project_id": id, "display_name": "Review Project \(offset + 1)",
                    "canonical_root": "/tmp/review-project-\(offset + 1)",
                    "project_generation": 4, "lifecycle_state": "active", "bindings": [],
                    "memory": ["state": "healthy", "database_bytes": 0, "record_count": 0],
                    "continuity": ["state": "ready", "migration_state": "not_required"],
                    "migration_warnings": [],
                ])
            }
    }

    func requestNames() -> [String] { requests }
    func queueProjectIDs() -> [String] { queueProjects }
    func changeProviderRevision(_ revision: String) { providerRevision = revision }
    func setQueueGenerationOffset(_ offset: UInt64) { queueGenerationOffset = offset }
    func failProviderConfiguration() { providerConfigurationUnavailable = true }
    func holdProjectStatus(_ projectID: String) { heldProjectID = projectID }
    func isStatusHeld() -> Bool { heldStatus != nil }
    func releaseProjectStatus() { heldStatus?.resume(); heldStatus = nil; heldProjectID = nil }

    func snapshot(limit: Int, cursor: String?) async throws -> OperatorSnapshot {
        requests.append("snapshot")
        return try Self.decode(OperatorSnapshot.self, [
            "projects": registeredProjects.map { project in [
                "project_id": project.projectID, "display_name": project.displayName,
                "canonical_root": project.canonicalRoot, "project_generation": project.projectGeneration,
                "lifecycle_state": "active", "bindings": [],
                "memory": ["state": "healthy", "database_bytes": 0, "record_count": 0],
                "continuity": ["state": "ready", "migration_state": "not_required"],
                "migration_warnings": [],
            ] },
            "provider": ["adapter_id": "forge.native-session-host", "provider_id": "fixture-provider",
                         "health": "contract_valid", "model_key": "fixture-model", "tool_use_capable": true],
        ])
    }

    func providerIntegrations() async throws -> ProviderIntegrationsSnapshot {
        requests.append("providerIntegrations")
        return ProviderIntegrationsSnapshot(
            selectionRevision: "selection-1", selectedProviderID: .lmStudio,
            providers: [], currentOperation: nil, recentOperations: []
        )
    }

    func providerConfiguration() async throws -> ProviderConfigurationSnapshot {
        requests.append("providerConfiguration")
        if providerConfigurationUnavailable { throw GuidedSetupReviewFixtureError.unavailable }
        return ProviderConfigurationSnapshot(
            revision: providerRevision, endpoint: "http://127.0.0.1:1234",
            modelKey: "fixture-model", credentialConfigured: false, saved: true
        )
    }

    func projectStatus(projectID: String) async throws -> OperatorProject {
        requests.append("projectStatus")
        if projectID == heldProjectID {
            await withCheckedContinuation { heldStatus = $0 }
        }
        guard let project = registeredProjects.first(where: { $0.projectID == projectID }) else {
            throw GuidedSetupReviewFixtureError.unavailable
        }
        return project
    }

    func instructionQueue(projectID: String, generation: UInt64) async throws -> OperatorInstructionQueue {
        requests.append("instructionQueue")
        queueProjects.append(projectID)
        let observedGeneration = generation + queueGenerationOffset
        return try Self.decode(OperatorInstructionQueue.self, [
            "project_id": projectID, "project_generation": observedGeneration, "revision": 1,
            "running": false, "packages": [[
                "id": "33333333-3333-4333-8333-333333333333", "project_id": projectID,
                "project_generation": observedGeneration, "package_id": "review-inputs", "version": "1",
                "display_name": "Review Inputs", "mission": "Review this project.",
                "source_path": "/tmp/review-inputs.md", "content_sha256": String(repeating: "c", count: 64),
                "allowed_tools": [], "completion_gates": ["tests"], "document_count": 1,
                "position": 0, "state": "queued", "created_at": "2026-10-04T00:00:00Z",
                "updated_at": "2026-10-04T00:00:00Z",
            ]],
        ])
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ object: [String: Any]) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object))
    }

    func autonomyStatus() async throws -> OperatorAutonomySummary { throw unexpected("autonomyStatus") }
    func settings() async throws -> ManagerSettings { throw unexpected("settings") }
    func updateSettings(_ patch: ManagerSettingsPatch) async throws -> ManagerSettings { throw unexpected("updateSettings") }
    func registerProject(_ request: OperatorProjectRegistrationRequest) async throws -> OperatorProjectRegistrationOutcome { throw unexpected("registerProject") }
    func resetProject(projectID: String, generation: UInt64) async throws -> OperatorResetReceipt { throw unexpected("resetProject") }
    func relinkProject(projectID: String, generation: UInt64, path: String) async throws -> OperatorRelinkReceipt { throw unexpected("relinkProject") }
    func startRun(_ request: OperatorRunStartRequest) async throws -> OperatorRun { throw unexpected("startRun") }
    func runStatus(runID: String) async throws -> OperatorRun { throw unexpected("runStatus") }
    func controlRun(runID: String, action: OperatorRunControlAction) async throws -> OperatorRun { throw unexpected("controlRun") }
    func cancelRuntimeJob(jobID: String) async throws -> OperatorRuntimeJob { throw unexpected("cancelRuntimeJob") }
    func updateProviderConfiguration(_ update: ProviderConfigurationUpdate) async throws -> ProviderConfigurationSnapshot { throw unexpected("updateProviderConfiguration") }
    func providerModels() async throws -> ProviderModelInventory { throw unexpected("providerModels") }
    func probeProvider(adapterID: String, mode: OperatorProviderProbeMode) async throws -> OperatorProvider { throw unexpected("probeProvider") }
    private func unexpected(_ request: String) -> GuidedSetupReviewFixtureError {
        requests.append(request)
        return .unexpectedCall
    }
}
