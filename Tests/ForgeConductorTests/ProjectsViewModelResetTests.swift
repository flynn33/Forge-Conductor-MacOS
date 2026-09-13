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

    private static let resetReceiptJSON = """
    {"prior_generation":1,"new_generation":2,"invalidated_binding_count":1,"completed_at":"2026-09-12T21:05:00Z"}
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

    private static func projectJSON(generation: UInt64, withReceipt: Bool) -> String {
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
          "project_id": "\(Self.projectID)",
          "display_name": "Fixture Project",
          "canonical_root": "/tmp/fixture-project",
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

    // MARK: - Recording fixture client

    private actor FakeOperatorClient: OperatorManagerClientProtocol {
        struct ResetCall: Sendable, Equatable {
            let projectID: String
            let generation: UInt64
        }

        struct StatusCall: Sendable, Equatable {
            let projectID: String
        }

        private let snapshot: OperatorSnapshot?
        private let resetReceipt: OperatorResetReceipt?
        private let resetError: OperatorManagerClientError?
        private let statusProject: OperatorProject?
        private let statusError: OperatorManagerClientError?
        private var gateArmed = false
        private var gateReleased = false

        private(set) var resetCalls: [ResetCall] = []
        private(set) var statusCalls: [StatusCall] = []

        init(
            snapshot: OperatorSnapshot? = nil,
            resetReceipt: OperatorResetReceipt? = nil,
            resetError: OperatorManagerClientError? = nil,
            statusProject: OperatorProject? = nil,
            statusError: OperatorManagerClientError? = nil
        ) {
            self.snapshot = snapshot
            self.resetReceipt = resetReceipt
            self.resetError = resetError
            self.statusProject = statusProject
            self.statusError = statusError
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
            guard let snapshot else {
                throw OperatorManagerClientError.invalidPayload("fixture has no snapshot")
            }
            return snapshot
        }

        func projectStatus(projectID: String) async throws -> OperatorProject {
            statusCalls.append(StatusCall(projectID: projectID))
            if let statusError {
                throw statusError
            }
            guard let statusProject, statusProject.projectID == projectID else {
                throw OperatorManagerClientError.rejected(
                    status: 404,
                    message: "fixture has no project status for \(projectID)"
                )
            }
            return statusProject
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
            guard let resetReceipt else {
                throw OperatorManagerClientError.invalidPayload("fixture has no reset receipt")
            }
            return resetReceipt
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

        viewModel.resetSelectedProject()
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
            statusProject: try Self.fixture(
                OperatorProject.self,
                from: Self.projectJSON(generation: 2, withReceipt: true)
            )
        )
        let viewModel = await settledViewModel(client: client)

        await client.armResetGate()
        viewModel.resetSelectedProject()
        try await Task.sleep(for: .milliseconds(50))
        viewModel.resetSelectedProject()
        try await Task.sleep(for: .milliseconds(50))
        var resetCalls = await client.resetCalls
        XCTAssertEqual(resetCalls.count, 1)

        await client.releaseResetGate()
        await waitUntilIdle(viewModel)
        resetCalls = await client.resetCalls
        XCTAssertEqual(resetCalls.count, 1)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.projects.first?.projectGeneration, 2)

        viewModel.resetSelectedProject()
        await waitUntilIdle(viewModel)
        resetCalls = await client.resetCalls
        XCTAssertEqual(resetCalls.count, 2)
        XCTAssertEqual(resetCalls.last, FakeOperatorClient.ResetCall(projectID: Self.projectID, generation: 2))
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

        viewModel.resetSelectedProject()
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

        viewModel.resetSelectedProject()
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
}
