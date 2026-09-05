import XCTest
#if SWIFT_PACKAGE
@testable import ForgeConductorApp
#else
@testable import Forge_Conductor
#endif
@testable import ForgeConductorCore

private final class OperatorProjectContractURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [String: Data] = [:]
    nonisolated(unsafe) private static var paths: [String] = []

    static func configure(responses: [String: Data]) {
        lock.lock()
        self.responses = responses
        paths = []
        lock.unlock()
    }

    static func requestedPaths() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.lock.lock()
        Self.paths.append(path)
        let data = Self.responses[path]
        Self.lock.unlock()
        guard let data,
              let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private struct OperatorProjectContractCredential: ManagerMutationCredentialProviding {
    func bearerToken() throws -> String {
        String(repeating: "a", count: ManagerControlCredentialStore.tokenCharacterCount)
    }
}

private enum OperatorProjectContractFixtureError: Error {
    case unexpectedCall
}

private final class OperatorProjectContractClient: OperatorManagerClientProtocol, @unchecked Sendable {
    let registration: OperatorProjectRegistrationOutcome
    let status: OperatorProject
    let resetReceipt: OperatorResetReceipt

    init(
        registration: OperatorProjectRegistrationOutcome,
        status: OperatorProject,
        resetReceipt: OperatorResetReceipt
    ) {
        self.registration = registration
        self.status = status
        self.resetReceipt = resetReceipt
    }

    func snapshot(limit: Int, cursor: String?) async throws -> OperatorSnapshot {
        throw OperatorProjectContractFixtureError.unexpectedCall
    }
    func autonomyStatus() async throws -> OperatorAutonomySummary {
        throw OperatorProjectContractFixtureError.unexpectedCall
    }
    func settings() async throws -> ManagerSettings {
        throw OperatorProjectContractFixtureError.unexpectedCall
    }
    func updateSettings(_ patch: ManagerSettingsPatch) async throws -> ManagerSettings {
        throw OperatorProjectContractFixtureError.unexpectedCall
    }
    func registerProject(
        _ request: OperatorProjectRegistrationRequest
    ) async throws -> OperatorProjectRegistrationOutcome { registration }
    func projectStatus(projectID: String) async throws -> OperatorProject { status }
    func resetProject(
        projectID: String,
        generation: UInt64
    ) async throws -> OperatorResetReceipt { resetReceipt }
    func relinkProject(
        projectID: String,
        generation: UInt64,
        path: String
    ) async throws -> OperatorRelinkReceipt {
        throw OperatorProjectContractFixtureError.unexpectedCall
    }
    func startRun(_ request: OperatorRunStartRequest) async throws -> OperatorRun {
        throw OperatorProjectContractFixtureError.unexpectedCall
    }
    func runStatus(runID: String) async throws -> OperatorRun {
        throw OperatorProjectContractFixtureError.unexpectedCall
    }
    func controlRun(
        runID: String,
        action: OperatorRunControlAction
    ) async throws -> OperatorRun {
        throw OperatorProjectContractFixtureError.unexpectedCall
    }
    func cancelRuntimeJob(jobID: String) async throws -> OperatorRuntimeJob {
        throw OperatorProjectContractFixtureError.unexpectedCall
    }
    func providerConfiguration() async throws -> ProviderConfigurationSnapshot {
        throw OperatorProjectContractFixtureError.unexpectedCall
    }
    func updateProviderConfiguration(_ update: ProviderConfigurationUpdate) async throws -> ProviderConfigurationSnapshot {
        throw OperatorProjectContractFixtureError.unexpectedCall
    }
    func providerModels() async throws -> ProviderModelInventory {
        throw OperatorProjectContractFixtureError.unexpectedCall
    }
    func probeProvider(
        adapterID: String,
        mode: OperatorProviderProbeMode
    ) async throws -> OperatorProvider {
        throw OperatorProjectContractFixtureError.unexpectedCall
    }
}

final class OperatorProjectContractTests: XCTestCase {
    func testCommittedRegistrationFetchesFullProjectWithoutLosingReconciledFlag() async throws {
        let projectID = UUID().uuidString.lowercased()
        let project = try Self.project(
            projectID: projectID,
            generation: 7,
            root: "/tmp/operator-project",
            resetPriorGeneration: 6
        )
        let registration = ManagerProjectRegistrationResult(
            registrationState: .committed,
            projectID: projectID,
            displayName: "Operator Project",
            canonicalRoot: "/tmp/operator-project",
            projectGeneration: 7,
            lifecycleState: "active",
            requestPath: "/tmp/operator-project",
            requestedDisplayName: "Operator Project",
            repositoryIdentityAssertion: nil,
            reconciled: true
        )
        OperatorProjectContractURLProtocol.configure(responses: [
            "/api/manager/projects/register": try JSONEncoder().encode(registration),
            "/api/manager/projects/status": try Self.projectData(
                projectID: projectID,
                generation: 7,
                root: "/tmp/operator-project",
                resetPriorGeneration: 6
            ),
        ])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OperatorProjectContractURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = OperatorManagerHTTPClient(
            host: "127.0.0.1",
            port: 8_899,
            session: session,
            credentials: OperatorProjectContractCredential()
        )

        let outcome = try await client.registerProject(
            OperatorProjectRegistrationRequest(
                path: "/tmp/operator-project",
                displayName: "Operator Project",
                repositoryIdentity: nil
            )
        )
        guard case .committed(let actual, let reconciled) = outcome else {
            return XCTFail("Expected a committed full project")
        }
        XCTAssertTrue(reconciled)
        XCTAssertEqual(actual, project)
        XCTAssertEqual(actual.bindings.count, 1)
        XCTAssertEqual(actual.memory?.state, "available_unverified")
        XCTAssertEqual(actual.continuity?.state, "queued")
        XCTAssertEqual(actual.migrationWarnings, ["fixture_warning"])
        XCTAssertEqual(actual.resetReceipt?.newGeneration, 7)
        XCTAssertEqual(actual.pendingTransition?.kind, "registration")
        XCTAssertEqual(
            OperatorProjectContractURLProtocol.requestedPaths(),
            ["/api/manager/projects/register", "/api/manager/projects/status"]
        )
    }

    @MainActor
    func testProjectsViewModelPreservesFullRegistrationAndResetProjection() async throws {
        let projectID = UUID().uuidString.lowercased()
        let registered = try Self.project(
            projectID: projectID,
            generation: 7,
            root: "/tmp/operator-project",
            resetPriorGeneration: 6
        )
        let reset = try Self.project(
            projectID: projectID,
            generation: 8,
            root: "/tmp/operator-project",
            resetPriorGeneration: 7
        )
        let client = OperatorProjectContractClient(
            registration: .committed(project: registered, reconciled: true),
            status: reset,
            resetReceipt: try XCTUnwrap(reset.resetReceipt)
        )
        let viewModel = ProjectsViewModel(client: client)

        viewModel.register(path: "/tmp/operator-project", displayName: "Operator Project")
        try await Self.waitUntilIdle(viewModel)
        XCTAssertEqual(viewModel.selectedProject, registered)
        XCTAssertTrue(viewModel.notice?.contains("Reconciled") == true)

        viewModel.resetSelectedProject()
        try await Self.waitUntilIdle(viewModel)
        XCTAssertEqual(viewModel.selectedProject, reset)
        XCTAssertEqual(viewModel.selectedProject?.projectGeneration, 8)
        XCTAssertEqual(viewModel.selectedProject?.resetReceipt?.priorGeneration, 7)
        XCTAssertEqual(viewModel.selectedProject?.resetReceipt?.newGeneration, 8)
        XCTAssertEqual(viewModel.selectedProject?.bindings.count, 1)
        XCTAssertEqual(viewModel.selectedProject?.continuity?.state, "queued")
    }

    private static func project(
        projectID: String,
        generation: UInt64,
        root: String,
        resetPriorGeneration: UInt64
    ) throws -> OperatorProject {
        try JSONDecoder().decode(
            OperatorProject.self,
            from: projectData(
                projectID: projectID,
                generation: generation,
                root: root,
                resetPriorGeneration: resetPriorGeneration
            )
        )
    }

    private static func projectData(
        projectID: String,
        generation: UInt64,
        root: String,
        resetPriorGeneration: UInt64
    ) throws -> Data {
        try JSONSupport.data(from: [
            "project_id": projectID,
            "display_name": "Operator Project",
            "canonical_root": root,
            "project_generation": generation,
            "lifecycle_state": "active",
            "bindings": [[
                "binding_id": "11111111-1111-4111-8111-111111111111",
                "owner_kind": "mcp_client",
                "owner_id": "operator-client",
                "active": true,
            ]],
            "memory": [
                "state": "available_unverified",
                "database_bytes": 4_096,
                "record_count": 3,
                "last_integrity_check": "2026-09-01T00:00:00Z",
                "detail": "fixture",
            ],
            "continuity": [
                "state": "queued",
                "latest_handoff_id": "22222222-2222-4222-8222-222222222222",
                "latest_handoff_sha256": String(repeating: "a", count: 64),
                "migration_state": "current",
            ],
            "migration_warnings": ["fixture_warning"],
            "reset_receipt": [
                "prior_generation": resetPriorGeneration,
                "new_generation": generation,
                "invalidated_binding_count": 2,
                "completed_at": "2026-09-01T00:00:00Z",
            ],
            "pending_transition": [
                "kind": "registration",
                "state": "reconciliation_required",
                "request_path": root,
                "operation_id": "33333333-3333-4333-8333-333333333333",
                "created_at": "2026-09-01T00:00:00Z",
            ],
            "created_at": "2026-09-01T00:00:00Z",
            "updated_at": "2026-09-01T00:00:00Z",
        ])
    }

    @MainActor
    private static func waitUntilIdle(_ viewModel: ProjectsViewModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while viewModel.isLoading, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNil(viewModel.errorMessage)
    }
}
