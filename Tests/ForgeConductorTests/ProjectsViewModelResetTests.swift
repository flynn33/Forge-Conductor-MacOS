// ProjectsViewModelResetTests.swift
// Focused store tests for the native project reset action: confirmed success,
// duplicate submission while a reset is in flight, service failure, a refresh
// failure after a committed reset, and the no-confirmation cancel path.
// The fixture client is fully in-memory and isolated from live manager state.

import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import ForgeConductorApp
#else
@testable import Forge_Conductor
#endif
@testable import ForgeConductorCore

@MainActor
final class ProjectsViewModelResetTests: XCTestCase {
    private static let projectID = "6F9E2A64-1C4B-4D3A-9B2E-0A1B2C3D4E5F"
    private static let secondProjectID = "0A1B2C3D-4E5F-4678-9A0B-1C2D3E4F5A6B"

    private static let resetReceiptJSON = """
    {"project_id":"\(projectID)","prior_generation":1,"new_generation":2,"invalidated_binding_count":1,"completed_at":"2026-09-12T21:05:00Z"}
    """

    private static let secondResetReceiptJSON = """
    {"project_id":"\(projectID)","prior_generation":2,"new_generation":3,"invalidated_binding_count":0,"completed_at":"2026-09-12T21:06:00Z"}
    """

    private static let clearReceiptJSON = """
    {"operation_id":"B8F91C02-8916-4E7B-B4AF-305A897E19A2","project_id":"\(projectID)","mode":"memory_and_continuity","prior_generation":1,"new_generation":2,"memory_record_count":3,"continuity_record_count":4,"run_history_count":0,"invalidated_binding_count":1,"completed_at":"2026-09-14T12:00:00Z","replayed":false}
    """

    // MARK: - Fixture helpers

    private static func fixture<T: Decodable>(
        _ type: T.Type,
        from json: String
    ) throws -> T {
        let data = json.data(using: .utf8)
        guard let data else {
            throw OperatorManagerClientError.invalidPayload("fixture JSON is not valid UTF-8")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func projectJSON(
        generation: UInt64,
        withReceipt: Bool,
        projectID: String? = nil,
        displayName: String = "Fixture Project"
    ) -> String {
        let resolvedProjectID = projectID ?? Self.projectID
        let receipt = withReceipt
            ? """
              {
                  "prior_generation": 1,
                  "new_generation": 2,
                  "invalidated_binding_count": 1,
                  "completed_at": "2026-09-12T21:05:00Z"
              }
              """
            : "null"
        return """
        {
          "project_id": "\(resolvedProjectID)",
          "display_name": "\(displayName)",
          "canonical_root": "/tmp/\(resolvedProjectID.lowercased())",
          "project_generation": \(generation),
          "lifecycle_state": "active",
          "bindings": [
            {
              "binding_id": "fixture-binding",
              "owner_kind": "agent_session",
              "owner_id": "fixture-session",
              "run_id": null,
              "active": true
            }
          ],
          "memory": {
            "state": "healthy",
            "detail": "Fixture project memory store",
            "database_bytes": 1024,
            "record_count": 3,
            "last_integrity_check": "2026-09-12T21:05:00Z"
          },
          "continuity": {
            "state": "idle",
            "latest_handoff_id": "fixture-handoff",
            "latest_handoff_sha256": "fixture-sha256",
            "migration_state": "none"
          },
          "migration_warnings": [],
          "reset_receipt": \(receipt)
        }
        """
    }

    private static func snapshotJSON() -> String {
        """
        {
          "projects": [\(projectJSON(generation: 1, withReceipt: false))]
        }
        """
    }

    private static func twoProjectSnapshotJSON() -> String {
        """
        {
          "projects": [
            \(projectJSON(generation: 1, withReceipt: false)),
            \(projectJSON(
                generation: 4,
                withReceipt: false,
                projectID: secondProjectID,
                displayName: "Second Project"
            ))
          ]
        }
        """
    }

    // MARK: - Recording fixture client

    private actor FakeOperatorClient: OperatorManagerClientProtocol {
        struct ResetCall: Sendable, Equatable {
            let projectID: String
            let generation: UInt64
        }

        struct StatusCall: Sendable, Equatable {
            let projectID: String
        }

        struct ClearCall: Sendable, Equatable {
            let operationID: UUID
            let projectID: String
            let generation: UInt64
            let mode: OperatorProjectContentClearMode
        }

        private let snapshot: OperatorSnapshot?
        private let subsequentSnapshot: OperatorSnapshot?
        private let resetReceipt: OperatorResetReceipt?
        private let subsequentResetReceipt: OperatorResetReceipt?
        private let resetError: OperatorManagerClientError?
        private let statusProject: OperatorProject?
        private let subsequentStatusProject: OperatorProject?
        private let statusError: OperatorManagerClientError?
        private let clearReceipt: OperatorProjectContentClearReceipt?
        private let failFirstClear: Bool
        private var gateArmed = false
        private var gateReleased = false
        private var snapshotCallCount = 0

        private(set) var resetCalls: [ResetCall] = []
        private(set) var statusCalls: [StatusCall] = []
        private(set) var clearCalls: [ClearCall] = []

        init(
            snapshot: OperatorSnapshot? = nil,
            subsequentSnapshot: OperatorSnapshot? = nil,
            resetReceipt: OperatorResetReceipt? = nil,
            subsequentResetReceipt: OperatorResetReceipt? = nil,
            resetError: OperatorManagerClientError? = nil,
            statusProject: OperatorProject? = nil,
            subsequentStatusProject: OperatorProject? = nil,
            statusError: OperatorManagerClientError? = nil,
            clearReceipt: OperatorProjectContentClearReceipt? = nil,
            failFirstClear: Bool = false
        ) {
            self.snapshot = snapshot
            self.subsequentSnapshot = subsequentSnapshot
            self.resetReceipt = resetReceipt
            self.subsequentResetReceipt = subsequentResetReceipt
            self.resetError = resetError
            self.statusProject = statusProject
            self.subsequentStatusProject = subsequentStatusProject
            self.statusError = statusError
            self.clearReceipt = clearReceipt
            self.failFirstClear = failFirstClear
        }

        /// Holds the next reset in flight until released.
        func armResetGate() {
            gateArmed = true
            gateReleased = false
        }

        func releaseResetGate() {
            gateReleased = true
        }

        // MARK: Exercised by these tests

        func snapshot(limit: Int, cursor: String?) async throws -> OperatorSnapshot {
            snapshotCallCount += 1
            let response = snapshotCallCount > 1
                ? (subsequentSnapshot ?? snapshot)
                : snapshot
            guard let response else {
                throw OperatorManagerClientError.invalidPayload("fixture has no snapshot")
            }
            return response
        }

        func projectStatus(projectID: String) async throws -> OperatorProject {
            statusCalls.append(StatusCall(projectID: projectID))
            if let statusError {
                throw statusError
            }
            let response = statusCalls.count > 1
                ? (subsequentStatusProject ?? statusProject)
                : statusProject
            guard let response else {
                throw OperatorManagerClientError.rejected(
                    status: 404,
                    message: "fixture has no project status for \(projectID)"
                )
            }
            return response
        }

        func resetProject(
            projectID: String,
            generation: UInt64
        ) async throws -> OperatorResetReceipt {
            resetCalls.append(ResetCall(projectID: projectID, generation: generation))
            if gateArmed {
                while !gateReleased {
                    try? await Task.sleep(for: .milliseconds(5))
                }
                gateArmed = false
            }
            if let resetError {
                throw resetError
            }
            let response = resetCalls.count > 1
                ? (subsequentResetReceipt ?? resetReceipt)
                : resetReceipt
            guard let response else {
                throw OperatorManagerClientError.invalidPayload("fixture has no reset receipt")
            }
            return response
        }

        func clearProjectContent(
            operationID: UUID,
            projectID: String,
            generation: UInt64,
            mode: OperatorProjectContentClearMode
        ) async throws -> OperatorProjectContentClearReceipt {
            clearCalls.append(ClearCall(
                operationID: operationID,
                projectID: projectID,
                generation: generation,
                mode: mode
            ))
            if failFirstClear, clearCalls.count == 1 {
                throw OperatorManagerClientError.reconciliationRequired(
                    code: "response_lost",
                    message: "replay the original operation"
                )
            }
            guard let clearReceipt else {
                throw OperatorManagerClientError.invalidPayload("fixture has no clear receipt")
            }
            return OperatorProjectContentClearReceipt(
                operationID: operationID.uuidString,
                projectID: clearReceipt.projectID,
                mode: clearReceipt.mode,
                priorGeneration: clearReceipt.priorGeneration,
                newGeneration: clearReceipt.newGeneration,
                memoryRecordCount: clearReceipt.memoryRecordCount,
                continuityRecordCount: clearReceipt.continuityRecordCount,
                runHistoryCount: clearReceipt.runHistoryCount,
                invalidatedBindingCount: clearReceipt.invalidatedBindingCount,
                completedAt: clearReceipt.completedAt,
                replayed: clearCalls.count > 1
            )
        }

        // MARK: Not exercised by these tests

        private var notInScope: OperatorManagerClientError {
            .invalidPayload("not exercised by this test")
        }

        func autonomyStatus() async throws -> OperatorAutonomySummary {
            throw notInScope
        }

        func settings() async throws -> ManagerSettings {
            throw notInScope
        }

        func updateSettings(_ patch: ManagerSettingsPatch) async throws -> ManagerSettings {
            throw notInScope
        }

        func registerProject(
            _ request: OperatorProjectRegistrationRequest
        ) async throws -> OperatorProjectRegistrationOutcome {
            throw notInScope
        }

        func relinkProject(
            projectID: String,
            generation: UInt64,
            path: String
        ) async throws -> OperatorRelinkReceipt {
            throw notInScope
        }

        func startRun(_ request: OperatorRunStartRequest) async throws -> OperatorRun {
            throw notInScope
        }

        func runStatus(runID: String) async throws -> OperatorRun {
            throw notInScope
        }

        func controlRun(
            runID: String,
            action: OperatorRunControlAction
        ) async throws -> OperatorRun {
            throw notInScope
        }

        func cancelRuntimeJob(jobID: String) async throws -> OperatorRuntimeJob {
            throw notInScope
        }

        func providerConfiguration() async throws -> ProviderConfigurationSnapshot {
            throw notInScope
        }

        func updateProviderConfiguration(
            _ update: ProviderConfigurationUpdate
        ) async throws -> ProviderConfigurationSnapshot {
            throw notInScope
        }

        func providerModels() async throws -> ProviderModelInventory {
            throw notInScope
        }

        func probeProvider(
            adapterID: String,
            mode: OperatorProviderProbeMode
        ) async throws -> OperatorProvider {
            throw notInScope
        }
    }

    // MARK: - Store test support

    private func settledViewModel(
        client: FakeOperatorClient,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> ProjectsViewModel {
        let viewModel = ProjectsViewModel(client: client)
        viewModel.load()
        let deadline = Date().addingTimeInterval(10)
        while viewModel.isLoading {
            if Date() >= deadline {
                XCTFail("ViewModel did not become idle within 10 seconds", file: file, line: line)
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return viewModel
    }

    private func waitUntilIdle(
        _ viewModel: ProjectsViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(10)
        while viewModel.isLoading {
            if Date() >= deadline {
                XCTFail("ViewModel did not become idle within 10 seconds", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - Tests

    /// Confirmed success: the action invokes the service once with the selected
    /// project and its generation, then reports the real receipt and refreshed row.
    func testConfirmedResetInvokesServiceWithSelectedProjectAndReportsReceipt() async throws {
        let client = FakeOperatorClient(
            snapshot: try Self.fixture(OperatorSnapshot.self, from: Self.snapshotJSON()),
            resetReceipt: try Self.fixture(OperatorResetReceipt.self, from: Self.resetReceiptJSON),
            statusProject: try Self.fixture(
                OperatorProject.self,
                from: Self.projectJSON(generation: 2, withReceipt: true)
            )
        )
        let viewModel = await settledViewModel(client: client)
        XCTAssertEqual(viewModel.projects.count, 1)
        XCTAssertEqual(viewModel.selectedProjectID, Self.projectID)

        viewModel.resetProject(try XCTUnwrap(viewModel.resetConfirmationForSelectedProject()))
        await waitUntilIdle(viewModel)

        let resetCalls = await client.resetCalls
        let statusCalls = await client.statusCalls
        XCTAssertEqual(resetCalls, [FakeOperatorClient.ResetCall(projectID: Self.projectID, generation: 1)])
        XCTAssertEqual(statusCalls, [FakeOperatorClient.StatusCall(projectID: Self.projectID)])
        XCTAssertEqual(viewModel.notice, "Reset generation 1 → 2; fenced 1 binding(s).")
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.projects.first?.projectGeneration, 2)
        XCTAssertEqual(viewModel.projects.first?.resetReceipt?.newGeneration, 2)
        XCTAssertEqual(viewModel.projects.first?.resetReceipt?.invalidatedBindingCount, 1)
        XCTAssertEqual(viewModel.selectedProjectID, Self.projectID)
        XCTAssertNotNil(viewModel.lastUpdated)
    }

    /// Duplicate prevention: a second confirm while the first reset is in flight
    /// must not dispatch a second service call; a fresh confirm after settling does.
    func testDuplicateResetSubmissionWhileInFlightDispatchesOnce() async throws {
        let client = FakeOperatorClient(
            snapshot: try Self.fixture(OperatorSnapshot.self, from: Self.snapshotJSON()),
            resetReceipt: try Self.fixture(OperatorResetReceipt.self, from: Self.resetReceiptJSON),
            subsequentResetReceipt: try Self.fixture(
                OperatorResetReceipt.self,
                from: Self.secondResetReceiptJSON
            ),
            statusProject: try Self.fixture(
                OperatorProject.self,
                from: Self.projectJSON(generation: 2, withReceipt: true)
            ),
            subsequentStatusProject: try Self.fixture(
                OperatorProject.self,
                from: Self.projectJSON(generation: 3, withReceipt: false)
            )
        )
        let viewModel = await settledViewModel(client: client)

        await client.armResetGate()
        let firstConfirmation = try XCTUnwrap(viewModel.resetConfirmationForSelectedProject())
        viewModel.resetProject(firstConfirmation)
        try await Task.sleep(for: .milliseconds(50))
        viewModel.resetProject(firstConfirmation)
        try await Task.sleep(for: .milliseconds(50))
        var resetCalls = await client.resetCalls
        XCTAssertEqual(resetCalls.count, 1)

        await client.releaseResetGate()
        await waitUntilIdle(viewModel)
        resetCalls = await client.resetCalls
        XCTAssertEqual(resetCalls.count, 1)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.projects.first?.projectGeneration, 2)

        viewModel.resetProject(try XCTUnwrap(viewModel.resetConfirmationForSelectedProject()))
        await waitUntilIdle(viewModel)
        resetCalls = await client.resetCalls
        XCTAssertEqual(resetCalls.count, 2)
        XCTAssertEqual(resetCalls.last, FakeOperatorClient.ResetCall(projectID: Self.projectID, generation: 2))
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.projects.first?.projectGeneration, 3)
    }

    /// Service failure: the real error is shown, no success is reported, and the
    /// displayed project state is left untouched.
    func testResetServiceFailureShowsRealErrorAndKeepsDisplayedState() async throws {
        let client = FakeOperatorClient(
            snapshot: try Self.fixture(OperatorSnapshot.self, from: Self.snapshotJSON()),
            resetError: .rejected(
                status: 409,
                message: "project generation is stale (expected 2, found 1)"
            ),
            statusProject: try Self.fixture(
                OperatorProject.self,
                from: Self.projectJSON(generation: 2, withReceipt: true)
            )
        )
        let viewModel = await settledViewModel(client: client)

        viewModel.resetProject(try XCTUnwrap(viewModel.resetConfirmationForSelectedProject()))
        await waitUntilIdle(viewModel)

        let resetCalls = await client.resetCalls
        let statusCalls = await client.statusCalls
        XCTAssertEqual(resetCalls.count, 1)
        XCTAssertEqual(statusCalls.count, 0)
        XCTAssertEqual(
            viewModel.errorMessage,
            OperatorManagerClientError.rejected(
                status: 409,
                message: "project generation is stale (expected 2, found 1)"
            ).localizedDescription
        )
        XCTAssertNil(viewModel.notice)
        XCTAssertEqual(viewModel.projects.first?.projectGeneration, 1)
        XCTAssertNil(viewModel.projects.first?.resetReceipt)
        XCTAssertEqual(viewModel.selectedProjectID, Self.projectID)
    }

    /// Honest reporting after a commit: the reset receipt is reported even when
    /// the post-reset refresh fails, with the real refresh error shown alongside.
    func testCommittedResetSurvivesRefreshFailure() async throws {
        let client = FakeOperatorClient(
            snapshot: try Self.fixture(OperatorSnapshot.self, from: Self.snapshotJSON()),
            resetReceipt: try Self.fixture(OperatorResetReceipt.self, from: Self.resetReceiptJSON),
            statusError: .rejected(status: 500, message: "project status unavailable after reset")
        )
        let viewModel = await settledViewModel(client: client)

        viewModel.resetProject(try XCTUnwrap(viewModel.resetConfirmationForSelectedProject()))
        await waitUntilIdle(viewModel)

        let resetCalls = await client.resetCalls
        XCTAssertEqual(resetCalls.count, 1)
        XCTAssertEqual(viewModel.notice, "Reset generation 1 → 2; fenced 1 binding(s).")
        XCTAssertEqual(
            viewModel.errorMessage,
            OperatorManagerClientError.rejected(
                status: 500,
                message: "project status unavailable after reset"
            ).localizedDescription
        )
        // The refresh failed, so the pre-reset row stays displayed and the selection is untouched.
        XCTAssertEqual(viewModel.projects.first?.projectGeneration, 1)
        XCTAssertEqual(viewModel.selectedProjectID, Self.projectID)
    }

    /// Cancel path at the store seam: selecting a project (i.e. never confirming
    /// the alert) must never dispatch a reset.
    func testSelectionWithoutConfirmationIssuesNoReset() async throws {
        let client = FakeOperatorClient(
            snapshot: try Self.fixture(OperatorSnapshot.self, from: Self.snapshotJSON())
        )
        let viewModel = await settledViewModel(client: client)

        viewModel.selectedProjectID = Self.projectID
        try await Task.sleep(for: .milliseconds(50))

        let resetCalls = await client.resetCalls
        let statusCalls = await client.statusCalls
        XCTAssertEqual(resetCalls.count, 0)
        XCTAssertEqual(statusCalls.count, 0)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.selectedProjectID, Self.projectID)
    }

    /// A selection change before confirmation invalidates the captured authority;
    /// the user must inspect and confirm the new selection explicitly.
    func testSelectionDriftBeforeConfirmationRequiresFreshConfirmation() async throws {
        let client = FakeOperatorClient(
            snapshot: try Self.fixture(
                OperatorSnapshot.self,
                from: Self.twoProjectSnapshotJSON()
            ),
            resetReceipt: try Self.fixture(OperatorResetReceipt.self, from: Self.resetReceiptJSON),
            statusProject: try Self.fixture(
                OperatorProject.self,
                from: Self.projectJSON(generation: 2, withReceipt: true)
            )
        )
        let viewModel = await settledViewModel(client: client)
        let confirmation = try XCTUnwrap(viewModel.resetConfirmationForSelectedProject())

        viewModel.selectedProjectID = Self.secondProjectID
        viewModel.resetProject(confirmation)

        let resetCalls = await client.resetCalls
        XCTAssertEqual(resetCalls, [])
        XCTAssertEqual(viewModel.selectedProjectID, Self.secondProjectID)
        XCTAssertEqual(
            viewModel.errorMessage,
            "The selected project or generation changed. Confirm the reset again."
        )
    }

    func testGenerationDriftBeforeConfirmationRequiresFreshConfirmation() async throws {
        let refreshedSnapshot = """
        {"projects":[\(Self.projectJSON(generation: 2, withReceipt: false))]}
        """
        let client = FakeOperatorClient(
            snapshot: try Self.fixture(OperatorSnapshot.self, from: Self.snapshotJSON()),
            subsequentSnapshot: try Self.fixture(
                OperatorSnapshot.self,
                from: refreshedSnapshot
            )
        )
        let viewModel = await settledViewModel(client: client)
        let staleConfirmation = try XCTUnwrap(
            viewModel.resetConfirmationForSelectedProject()
        )

        viewModel.load()
        await waitUntilIdle(viewModel)
        XCTAssertEqual(viewModel.selectedProject?.projectGeneration, 2)
        viewModel.resetProject(staleConfirmation)

        let resetCalls = await client.resetCalls
        XCTAssertEqual(resetCalls, [])
        XCTAssertEqual(
            viewModel.errorMessage,
            "The selected project or generation changed. Confirm the reset again."
        )
    }

    /// Navigation after dispatch cannot retarget the already confirmed request,
    /// and a later refresh must preserve the user's new selection.
    func testSelectionDriftWhileResetIsInFlightPreservesRequestAndNewSelection() async throws {
        let client = FakeOperatorClient(
            snapshot: try Self.fixture(
                OperatorSnapshot.self,
                from: Self.twoProjectSnapshotJSON()
            ),
            resetReceipt: try Self.fixture(OperatorResetReceipt.self, from: Self.resetReceiptJSON),
            statusProject: try Self.fixture(
                OperatorProject.self,
                from: Self.projectJSON(generation: 2, withReceipt: true)
            )
        )
        let viewModel = await settledViewModel(client: client)
        let confirmation = try XCTUnwrap(viewModel.resetConfirmationForSelectedProject())
        await client.armResetGate()

        viewModel.resetProject(confirmation)
        try await Task.sleep(for: .milliseconds(50))
        viewModel.selectedProjectID = Self.secondProjectID
        await client.releaseResetGate()
        await waitUntilIdle(viewModel)

        let resetCalls = await client.resetCalls
        XCTAssertEqual(
            resetCalls,
            [FakeOperatorClient.ResetCall(projectID: Self.projectID, generation: 1)]
        )
        XCTAssertEqual(viewModel.selectedProjectID, Self.secondProjectID)
        XCTAssertEqual(
            viewModel.projects.first(where: { $0.projectID == Self.projectID })?.projectGeneration,
            2
        )
        XCTAssertNil(viewModel.errorMessage)
    }

    func testResetRejectsReceiptForDifferentProject() async throws {
        let mismatchedReceipt = OperatorResetReceipt(
            projectID: Self.secondProjectID,
            priorGeneration: 1,
            newGeneration: 2,
            invalidatedBindingCount: 0,
            completedAt: "2026-09-12T21:05:00Z"
        )
        let client = FakeOperatorClient(
            snapshot: try Self.fixture(OperatorSnapshot.self, from: Self.snapshotJSON()),
            resetReceipt: mismatchedReceipt
        )
        let viewModel = await settledViewModel(client: client)

        viewModel.resetProject(try XCTUnwrap(viewModel.resetConfirmationForSelectedProject()))
        await waitUntilIdle(viewModel)

        XCTAssertNil(viewModel.notice)
        let statusCalls = await client.statusCalls
        XCTAssertEqual(statusCalls.count, 0)
        XCTAssertEqual(
            viewModel.errorMessage,
            OperatorManagerClientError.invalidPayload(
                "project reset receipt did not match the confirmed project generation"
            ).localizedDescription
        )
    }

    func testResetRejectsNonSuccessorReceiptGeneration() async throws {
        let invalidReceipt = OperatorResetReceipt(
            projectID: Self.projectID,
            priorGeneration: 1,
            newGeneration: 3,
            invalidatedBindingCount: 0,
            completedAt: "2026-09-12T21:05:00Z"
        )
        let client = FakeOperatorClient(
            snapshot: try Self.fixture(OperatorSnapshot.self, from: Self.snapshotJSON()),
            resetReceipt: invalidReceipt
        )
        let viewModel = await settledViewModel(client: client)

        viewModel.resetProject(try XCTUnwrap(viewModel.resetConfirmationForSelectedProject()))
        await waitUntilIdle(viewModel)

        XCTAssertNil(viewModel.notice)
        let statusCalls = await client.statusCalls
        XCTAssertEqual(statusCalls.count, 0)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    /// A valid receipt is a committed outcome. A mismatched refresh must be
    /// surfaced without erasing that receipt or replacing an unrelated row.
    func testCommittedResetRejectsMismatchedRefreshedIdentity() async throws {
        let client = FakeOperatorClient(
            snapshot: try Self.fixture(
                OperatorSnapshot.self,
                from: Self.twoProjectSnapshotJSON()
            ),
            resetReceipt: try Self.fixture(OperatorResetReceipt.self, from: Self.resetReceiptJSON),
            statusProject: try Self.fixture(
                OperatorProject.self,
                from: Self.projectJSON(
                    generation: 2,
                    withReceipt: false,
                    projectID: Self.secondProjectID,
                    displayName: "Second Project"
                )
            )
        )
        let viewModel = await settledViewModel(client: client)

        viewModel.resetProject(try XCTUnwrap(viewModel.resetConfirmationForSelectedProject()))
        await waitUntilIdle(viewModel)

        XCTAssertEqual(viewModel.notice, "Reset generation 1 → 2; fenced 1 binding(s).")
        XCTAssertEqual(
            viewModel.errorMessage,
            OperatorManagerClientError.invalidPayload(
                "project status did not match the committed reset receipt"
            ).localizedDescription
        )
        XCTAssertEqual(
            viewModel.projects.first(where: { $0.projectID == Self.projectID })?.projectGeneration,
            1
        )
    }

    func testMaximumGenerationIsRejectedBeforeDispatch() async throws {
        let snapshot = """
        {"projects":[\(Self.projectJSON(generation: UInt64.max, withReceipt: false))]}
        """
        let client = FakeOperatorClient(
            snapshot: try Self.fixture(OperatorSnapshot.self, from: snapshot)
        )
        let viewModel = await settledViewModel(client: client)

        viewModel.resetProject(try XCTUnwrap(viewModel.resetConfirmationForSelectedProject()))

        let resetCalls = await client.resetCalls
        XCTAssertEqual(resetCalls.count, 0)
        XCTAssertEqual(viewModel.errorMessage, "The confirmed project generation cannot be advanced.")
    }

    func testConfirmedContentClearUsesPinnedIdentityAndRefreshesCommittedGeneration() async throws {
        let client = FakeOperatorClient(
            snapshot: try Self.fixture(OperatorSnapshot.self, from: Self.snapshotJSON()),
            statusProject: try Self.fixture(
                OperatorProject.self,
                from: Self.projectJSON(generation: 2, withReceipt: false)
            ),
            clearReceipt: try Self.fixture(
                OperatorProjectContentClearReceipt.self,
                from: Self.clearReceiptJSON
            )
        )
        let viewModel = await settledViewModel(client: client)
        let confirmation = try XCTUnwrap(
            viewModel.clearConfirmationForSelectedProject(mode: .memoryAndContinuity)
        )

        viewModel.clearProjectContent(confirmation)
        await waitUntilIdle(viewModel)

        let calls = await client.clearCalls
        XCTAssertEqual(calls, [FakeOperatorClient.ClearCall(
            operationID: confirmation.operationID,
            projectID: Self.projectID,
            generation: 1,
            mode: .memoryAndContinuity
        )])
        XCTAssertNil(viewModel.pendingClearConfirmation)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.projects.first?.projectGeneration, 2)
        XCTAssertEqual(
            viewModel.notice,
            "Cleared memory and continuity for Fixture Project; generation 1 → 2."
        )
    }

    func testContentClearLostResponseReconcilesTheSameOperationIdentity() async throws {
        let client = FakeOperatorClient(
            snapshot: try Self.fixture(OperatorSnapshot.self, from: Self.snapshotJSON()),
            statusProject: try Self.fixture(
                OperatorProject.self,
                from: Self.projectJSON(generation: 2, withReceipt: false)
            ),
            clearReceipt: try Self.fixture(
                OperatorProjectContentClearReceipt.self,
                from: Self.clearReceiptJSON
            ),
            failFirstClear: true
        )
        let viewModel = await settledViewModel(client: client)
        let confirmation = try XCTUnwrap(
            viewModel.clearConfirmationForSelectedProject(mode: .memoryAndContinuity)
        )

        viewModel.clearProjectContent(confirmation)
        await waitUntilIdle(viewModel)
        XCTAssertEqual(viewModel.pendingClearConfirmation, confirmation)
        XCTAssertNil(viewModel.notice)

        viewModel.reconcilePendingContentClear()
        await waitUntilIdle(viewModel)
        let calls = await client.clearCalls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].operationID, confirmation.operationID)
        XCTAssertEqual(calls[1].operationID, confirmation.operationID)
        XCTAssertNil(viewModel.pendingClearConfirmation)
        XCTAssertEqual(viewModel.projects.first?.projectGeneration, 2)
    }

    func testContentClearSelectionDriftAndCancelIssueNoRequest() async throws {
        let client = FakeOperatorClient(
            snapshot: try Self.fixture(
                OperatorSnapshot.self,
                from: Self.twoProjectSnapshotJSON()
            ),
            clearReceipt: try Self.fixture(
                OperatorProjectContentClearReceipt.self,
                from: Self.clearReceiptJSON
            )
        )
        let viewModel = await settledViewModel(client: client)
        let cancelled = try XCTUnwrap(
            viewModel.clearConfirmationForSelectedProject(mode: .memory)
        )
        var clearCalls = await client.clearCalls
        XCTAssertEqual(clearCalls.count, 0)

        viewModel.selectedProjectID = Self.secondProjectID
        viewModel.clearProjectContent(cancelled)

        clearCalls = await client.clearCalls
        XCTAssertEqual(clearCalls.count, 0)
        XCTAssertEqual(
            viewModel.errorMessage,
            "The confirmed project or generation changed. Confirm clearing again."
        )
        XCTAssertEqual(viewModel.selectedProjectID, Self.secondProjectID)
    }
}
