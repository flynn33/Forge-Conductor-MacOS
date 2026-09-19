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
    nonisolated(unsafe) private static var statuses: [String: Int] = [:]
    nonisolated(unsafe) private static var failuresRemaining: [String: Int] = [:]
    nonisolated(unsafe) private static var paths: [String] = []
    nonisolated(unsafe) private static var bodies: [String: [Data]] = [:]

    static func configure(
        responses: [String: Data],
        statuses: [String: Int] = [:],
        failures: [String: Int] = [:]
    ) {
        lock.lock()
        self.responses = responses
        self.statuses = statuses
        failuresRemaining = failures
        paths = []
        bodies = [:]
        lock.unlock()
    }

    static func requestedPaths() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }

    static func requestedBodies(path: String) -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        return bodies[path] ?? []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.lock.lock()
        Self.paths.append(path)
        let requestBody = Self.bodyData(from: request)
        Self.bodies[path, default: []].append(requestBody)
        var data = Self.responses[path]
        let status = Self.statuses[path] ?? 200
        let shouldFail = (Self.failuresRemaining[path] ?? 0) > 0
        if shouldFail {
            Self.failuresRemaining[path, default: 0] -= 1
        }
        Self.lock.unlock()
        if shouldFail {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        if let responseData = data,
           var object = try? JSONSupport.object(from: responseData),
           object["run_id"] as? String == "__REQUEST_RUN_ID__",
           let requestObject = try? JSONSupport.object(from: requestBody),
           let runID = requestObject["run_id"] as? String {
            object["run_id"] = runID
            data = try? JSONSupport.data(from: object)
        }
        guard let data,
              let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: status,
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

    private static func bodyData(from request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
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
    let archiveReceipt: OperatorProjectArchiveReceipt?

    init(
        registration: OperatorProjectRegistrationOutcome,
        status: OperatorProject,
        resetReceipt: OperatorResetReceipt,
        archiveReceipt: OperatorProjectArchiveReceipt? = nil
    ) {
        self.registration = registration
        self.status = status
        self.resetReceipt = resetReceipt
        self.archiveReceipt = archiveReceipt
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
    func removeProject(
        projectID: String,
        generation: UInt64
    ) async throws -> OperatorProjectArchiveReceipt {
        guard let archiveReceipt else { throw OperatorProjectContractFixtureError.unexpectedCall }
        return archiveReceipt
    }
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
    @MainActor
    func testConfiguredAutonomyStartNeedsOnlyProjectAndInstructions() async throws {
        let projectID = UUID().uuidString.lowercased()
        let project = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Self.projectData(
                    projectID: projectID,
                    generation: 1,
                    root: "/tmp/operator-project",
                    resetPriorGeneration: 0
                )
            ) as? [String: Any]
        )
        OperatorProjectContractURLProtocol.configure(responses: [
            "/api/manager/operator/snapshot": try JSONSupport.data(from: [
                "projects": [project],
                "runs": [],
                "provider": [
                    "adapter_id": "forge.native-session-host",
                    "provider_id": "lmstudio",
                    "health": "contract_valid",
                    "model_key": "fixture/tool-model",
                ],
                "run_preparation": [
                    "state": "ready",
                    "provider_id": "lmstudio",
                    "adapter_id": "forge.native-session-host",
                    "model_key": "fixture/tool-model",
                    "schema_version": 1,
                    "provider_configuration_revision": "fixture-provider-revision",
                    "tool_catalog_revision": String(repeating: "a", count: 64),
                    "allowed_tools": ["fs_read", "fs_edit", "shell_exec"],
                    "completion_gates": [ProjectInstructionQueueStore.builtInCompletionGate],
                    "network_allowed": false,
                ],
            ]),
            "/api/manager/autonomy/status": try JSONSupport.data(from: [
                "started": true,
                "active_run_ids": [],
                "deferred_run_ids": [],
            ]),
        ])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OperatorProjectContractURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let viewModel = AutonomyViewModel(
            client: OperatorManagerHTTPClient(
                host: "127.0.0.1",
                port: 8_899,
                session: session,
                credentials: OperatorProjectContractCredential()
            )
        )

        viewModel.load()
        try await Self.waitUntilIdle(viewModel)
        viewModel.mission = "Repair the selected project."

        XCTAssertEqual(viewModel.selectedProjectID, projectID)
        XCTAssertEqual(viewModel.providerID, "lmstudio")
        XCTAssertEqual(viewModel.modelKey, "fixture/tool-model")
        XCTAssertFalse(viewModel.allowedTools.isEmpty)
        XCTAssertEqual(viewModel.completionGates, ProjectInstructionQueueStore.builtInCompletionGate)
        XCTAssertTrue(viewModel.canStart)
        let defaultRequest = try XCTUnwrap(viewModel.makeStartRequest())
        XCTAssertNil(defaultRequest.providerID)
        XCTAssertNil(defaultRequest.adapterID)
        XCTAssertNil(defaultRequest.modelKey)
        XCTAssertNil(defaultRequest.allowedTools)
        XCTAssertNil(defaultRequest.completionGates)
        XCTAssertNil(defaultRequest.networkAllowed)
        let defaultBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(defaultRequest))
                as? [String: Any]
        )
        XCTAssertEqual(
            Set(defaultBody.keys),
            [
                "run_id", "project_id", "project_generation", "mission",
                "expected_provider_configuration_revision",
                "expected_tool_catalog_revision",
                "maximum_inline_output_bytes",
            ]
        )
        XCTAssertEqual(
            defaultBody["expected_provider_configuration_revision"] as? String,
            "fixture-provider-revision"
        )
        XCTAssertEqual(
            defaultBody["expected_tool_catalog_revision"] as? String,
            String(repeating: "a", count: 64)
        )

        viewModel.modelKey = "fixture/pinned-model"
        viewModel.allowedTools = "fs_read"
        viewModel.completionGates = "fixture-check"
        viewModel.networkAllowed = true
        viewModel.load()
        try await Self.waitUntilIdle(viewModel)

        XCTAssertEqual(viewModel.modelKey, "fixture/pinned-model")
        XCTAssertEqual(viewModel.allowedTools, "fs_read")
        XCTAssertEqual(viewModel.completionGates, "fixture-check")
        XCTAssertTrue(viewModel.networkAllowed)
        let overrideRequest = try XCTUnwrap(viewModel.makeStartRequest())
        XCTAssertNil(overrideRequest.providerID)
        XCTAssertNil(overrideRequest.adapterID)
        XCTAssertEqual(overrideRequest.modelKey, "fixture/pinned-model")
        XCTAssertEqual(overrideRequest.allowedTools, ["fs_read"])
        XCTAssertEqual(overrideRequest.completionGates, ["fixture-check"])
        XCTAssertEqual(overrideRequest.networkAllowed, true)

        OperatorProjectContractURLProtocol.configure(
            responses: [
                "/api/manager/operator/snapshot": try JSONSupport.data(from: [
                    "projects": [project],
                    "runs": [],
                    "provider": [
                        "adapter_id": "forge.native-session-host",
                        "provider_id": "lmstudio",
                        "health": "contract_valid",
                        "model_key": "fixture/new-default-model",
                    ],
                    "run_preparation": [
                        "state": "ready",
                        "provider_id": "lmstudio",
                        "adapter_id": "forge.native-session-host",
                        "model_key": "fixture/new-default-model",
                        "schema_version": 1,
                        "provider_configuration_revision": "fixture-provider-revision-2",
                        "tool_catalog_revision": String(repeating: "a", count: 64),
                        "allowed_tools": ["fs_read", "fs_edit", "shell_exec"],
                        "completion_gates": [ProjectInstructionQueueStore.builtInCompletionGate],
                        "network_allowed": false,
                    ],
                ]),
                "/api/manager/autonomy/status": try JSONSupport.data(from: [
                    "started": true,
                    "active_run_ids": [],
                    "deferred_run_ids": [],
                ]),
                "/api/manager/runs/prepare": try Self.preparedRunData(
                    projectID: projectID,
                    generation: 1,
                    mission: "Repair the selected project.",
                    providerConfigurationRevision: "fixture-provider-revision-2",
                    modelKey: "fixture/pinned-model",
                    allowedTools: ["fs_read"],
                    completionGates: ["fixture-check"],
                    networkAllowed: true
                ),
                "/api/manager/runs/start": try JSONSupport.data(from: [
                    "ok": false,
                    "code": "run_preparation_stale",
                    "message": "The saved provider configuration changed.",
                    "retryable": true,
                ]),
            ],
            statuses: ["/api/manager/runs/start": 409]
        )
        viewModel.startRun()
        let staleDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while (viewModel.isStarting || viewModel.isLoading),
              ContinuousClock.now < staleDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(viewModel.isStarting)
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertFalse(viewModel.startRequiresReconciliation)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.notice?.contains("refreshing changed run preparation") == true)
        XCTAssertEqual(
            viewModel.runPreparation?.providerConfigurationRevision,
            "fixture-provider-revision-2"
        )
        XCTAssertEqual(viewModel.providerID, "lmstudio")
        XCTAssertEqual(viewModel.modelKey, "fixture/pinned-model")
        XCTAssertEqual(viewModel.allowedTools, "fs_read")
        XCTAssertEqual(viewModel.completionGates, "fixture-check")
        XCTAssertTrue(viewModel.networkAllowed)
        let preparedBodies = OperatorProjectContractURLProtocol.requestedBodies(
            path: "/api/manager/runs/prepare"
        )
        XCTAssertEqual(preparedBodies.count, 1)
        let startBodies = OperatorProjectContractURLProtocol.requestedBodies(
            path: "/api/manager/runs/start"
        )
        XCTAssertEqual(startBodies.count, 1)
        let submittedStart = try JSONSupport.object(from: try XCTUnwrap(startBodies.first))
        XCTAssertEqual(
            (submittedStart["expected_prepared_run_revision"] as? String)?.count,
            64
        )
        XCTAssertEqual(
            submittedStart["expected_provider_configuration_revision"] as? String,
            "fixture-provider-revision-2"
        )
    }

    @MainActor
    func testPreparedStartDoubleClickAndLostReplyReplayOneExactRunIdentity() async throws {
        let projectID = UUID().uuidString.lowercased()
        let project = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Self.projectData(
                    projectID: projectID,
                    generation: 1,
                    root: "/tmp/operator-replay-project",
                    resetPriorGeneration: 0
                )
            ) as? [String: Any]
        )
        let mission = "Replay this exact prepared start."
        OperatorProjectContractURLProtocol.configure(
            responses: [
                "/api/manager/operator/snapshot": try JSONSupport.data(from: [
                    "projects": [project],
                    "runs": [],
                    "provider": [
                        "adapter_id": ManagerNode.nativeSessionHostAdapterID,
                        "provider_id": "lmstudio",
                        "health": "contract_valid",
                        "model_key": "fixture/replay-model",
                    ],
                    "run_preparation": [
                        "state": "ready",
                        "provider_id": "lmstudio",
                        "adapter_id": ManagerNode.nativeSessionHostAdapterID,
                        "model_key": "fixture/replay-model",
                        "schema_version": 1,
                        "provider_configuration_revision": "fixture-replay-provider",
                        "tool_catalog_revision": String(repeating: "a", count: 64),
                        "allowed_tools": ["fs_read"],
                        "completion_gates": [ProjectInstructionQueueStore.builtInCompletionGate],
                        "network_allowed": false,
                    ],
                ]),
                "/api/manager/autonomy/status": try JSONSupport.data(from: [
                    "started": true,
                    "active_run_ids": [],
                    "deferred_run_ids": [],
                ]),
                "/api/manager/runs/prepare": try Self.preparedRunData(
                    projectID: projectID,
                    generation: 1,
                    mission: mission,
                    providerConfigurationRevision: "fixture-replay-provider",
                    modelKey: "fixture/replay-model",
                    allowedTools: ["fs_read"],
                    completionGates: [ProjectInstructionQueueStore.builtInCompletionGate],
                    networkAllowed: false
                ),
                "/api/manager/runs/start": try JSONSupport.data(from: [
                    "run_id": "__REQUEST_RUN_ID__",
                    "project_id": projectID,
                    "project_generation": UInt64(1),
                    "mission": mission,
                    "state": "created",
                    "continuity_mode": ContinuityMode.managedAutonomous.rawValue,
                    "provider_id": "lmstudio",
                    "adapter_id": ManagerNode.nativeSessionHostAdapterID,
                    "model_key": "fixture/replay-model",
                    "completion_gates": [ProjectInstructionQueueStore.builtInCompletionGate],
                    "passed_gates": [],
                ]),
            ],
            failures: ["/api/manager/runs/start": 1]
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OperatorProjectContractURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let viewModel = AutonomyViewModel(client: OperatorManagerHTTPClient(
            host: "127.0.0.1",
            port: 8_899,
            session: session,
            credentials: OperatorProjectContractCredential()
        ))
        viewModel.load()
        try await Self.waitUntilIdle(viewModel)
        viewModel.mission = mission

        viewModel.startRun()
        viewModel.startRun()
        try await Self.waitUntilStartIdle(viewModel)
        XCTAssertTrue(viewModel.startRequiresReconciliation)
        XCTAssertEqual(
            OperatorProjectContractURLProtocol.requestedBodies(
                path: "/api/manager/runs/start"
            ).count,
            1
        )

        viewModel.reconcileStart()
        try await Self.waitUntilStartIdle(viewModel)
        let startBodies = OperatorProjectContractURLProtocol.requestedBodies(
            path: "/api/manager/runs/start"
        )
        XCTAssertEqual(startBodies.count, 2)
        XCTAssertEqual(startBodies[0], startBodies[1])
        XCTAssertEqual(
            OperatorProjectContractURLProtocol.requestedBodies(
                path: "/api/manager/runs/prepare"
            ).count,
            1
        )
        let submitted = try JSONSupport.object(from: startBodies[0])
        XCTAssertEqual(viewModel.lastStartedRunID, submitted["run_id"] as? String)
        XCTAssertFalse(viewModel.startRequiresReconciliation)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testProjectRemovalAndInstructionQueueUseTypedManagerContracts() async throws {
        let projectID = UUID().uuidString.lowercased()
        let packageID = UUID().uuidString.lowercased()
        let queue: [String: Any] = [
            "ok": true,
            "project_id": projectID,
            "project_generation": 3,
            "revision": 8,
            "running": false,
            "packages": [[
                "id": packageID,
                "project_id": projectID,
                "project_generation": 3,
                "package_id": "first-package",
                "version": "1",
                "display_name": "First Package",
                "mission": "Complete the first package.",
                "source_path": "/tmp/first.md",
                "content_sha256": String(repeating: "a", count: 64),
                "allowed_tools": ["fs_read"],
                "completion_gates": ["forge.package.tool-success"],
                "position": 0,
                "state": "queued",
                "created_at": "2026-09-18T00:00:00Z",
                "updated_at": "2026-09-18T00:00:00Z",
            ]],
        ]
        OperatorProjectContractURLProtocol.configure(responses: [
            "/api/manager/projects/remove": try JSONSupport.data(from: [
                "ok": true,
                "project_id": projectID,
                "prior_generation": 3,
                "archived_generation": 4,
                "invalidated_binding_count": 2,
                "completed_at": "2026-09-18T00:00:00Z",
                "replayed": false,
            ]),
            "/api/manager/projects/instruction-packages": try JSONSupport.data(from: queue),
            "/api/manager/projects/instruction-packages/start": try JSONSupport.data(
                from: queue.merging(["running": true]) { _, latest in latest }
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

        let loaded = try await client.instructionQueue(projectID: projectID, generation: 3)
        XCTAssertEqual(loaded.packages.map(\.id), [packageID])
        XCTAssertEqual(loaded.packages.first?.position, 0)
        let started = try await client.startInstructionQueue(projectID: projectID, generation: 3)
        XCTAssertTrue(started.running)
        let removed = try await client.removeProject(projectID: projectID, generation: 3)
        XCTAssertEqual(removed.archivedGeneration, 4)
        XCTAssertEqual(removed.invalidatedBindingCount, 2)
        XCTAssertEqual(
            OperatorProjectContractURLProtocol.requestedPaths(),
            [
                "/api/manager/projects/instruction-packages",
                "/api/manager/projects/instruction-packages/start",
                "/api/manager/projects/remove",
            ]
        )
    }

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
                repositoryIdentity: nil,
                authorizeProjectRoot: true
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
        let registrationBodies = OperatorProjectContractURLProtocol.requestedBodies(
            path: "/api/manager/projects/register"
        )
        let registrationBody = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: XCTUnwrap(registrationBodies.first))
                as? [String: Any]
        )
        XCTAssertEqual(registrationBody["authorize_project_root"] as? Bool, true)
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
            resetReceipt: OperatorResetReceipt(
                projectID: projectID,
                priorGeneration: 7,
                newGeneration: 8,
                invalidatedBindingCount: 1,
                completedAt: "2026-09-13T00:00:00Z"
            )
        )
        let viewModel = ProjectsViewModel(client: client)

        viewModel.register(path: "/tmp/operator-project", displayName: "Operator Project")
        try await Self.waitUntilIdle(viewModel)
        XCTAssertEqual(viewModel.selectedProject, registered)
        XCTAssertTrue(viewModel.notice?.contains("Reconciled") == true)

        viewModel.resetProject(try XCTUnwrap(viewModel.resetConfirmationForSelectedProject()))
        try await Self.waitUntilIdle(viewModel)
        XCTAssertEqual(viewModel.selectedProject, reset)
        XCTAssertEqual(viewModel.selectedProject?.projectGeneration, 8)
        XCTAssertEqual(viewModel.selectedProject?.resetReceipt?.priorGeneration, 7)
        XCTAssertEqual(viewModel.selectedProject?.resetReceipt?.newGeneration, 8)
        XCTAssertEqual(viewModel.selectedProject?.bindings.count, 1)
        XCTAssertEqual(viewModel.selectedProject?.continuity?.state, "queued")
    }

    @MainActor
    func testProjectsViewModelRemovesConfirmedProjectFromVisibleList() async throws {
        let projectID = UUID().uuidString.lowercased()
        let project = try Self.project(
            projectID: projectID,
            generation: 7,
            root: "/tmp/operator-project",
            resetPriorGeneration: 6
        )
        let client = OperatorProjectContractClient(
            registration: .committed(project: project, reconciled: false),
            status: project,
            resetReceipt: OperatorResetReceipt(
                projectID: projectID,
                priorGeneration: 7,
                newGeneration: 8,
                invalidatedBindingCount: 0,
                completedAt: "2026-09-18T00:00:00Z"
            ),
            archiveReceipt: OperatorProjectArchiveReceipt(
                projectID: projectID,
                priorGeneration: 7,
                archivedGeneration: 8,
                invalidatedBindingCount: 1,
                completedAt: "2026-09-18T00:00:00Z",
                replayed: false
            )
        )
        let viewModel = ProjectsViewModel(client: client)

        viewModel.register(path: project.canonicalRoot, displayName: project.displayName)
        try await Self.waitUntilIdle(viewModel)
        let confirmation = try XCTUnwrap(viewModel.removeConfirmationForSelectedProject())
        viewModel.removeProject(confirmation)
        try await Self.waitUntilIdle(viewModel)

        XCTAssertTrue(viewModel.projects.isEmpty)
        XCTAssertNil(viewModel.selectedProjectID)
        XCTAssertNil(viewModel.instructionQueue)
        XCTAssertTrue(viewModel.notice?.contains("Removed Operator Project") == true)
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

    @MainActor
    private static func waitUntilIdle(_ viewModel: AutonomyViewModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while viewModel.isLoading, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    private static func waitUntilStartIdle(_ viewModel: AutonomyViewModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while viewModel.isStarting, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(viewModel.isStarting)
    }

    private static func preparedRunData(
        projectID: String,
        generation: UInt64,
        mission: String,
        providerConfigurationRevision: String,
        modelKey: String,
        allowedTools: [String],
        completionGates: [String],
        networkAllowed: Bool
    ) throws -> Data {
        let missionData = Data(mission.utf8)
        let sourceSHA256 = JSONSupport.sha256Hex(missionData)
        let descriptor = try ManagerPreparedRunDescriptor.make(
            detail: "The exact run inputs are ready.",
            projectID: projectID,
            projectGeneration: generation,
            source: ManagerPreparedRunSource(
                kind: .inlineMission,
                reference: "inline-mission:\(sourceSHA256)",
                snapshotSHA256: sourceSHA256
            ),
            documents: [ManagerPreparedRunDocumentReference(
                reference: "inline:mission",
                byteCount: missionData.count,
                sha256: sourceSHA256
            )],
            providerID: "lmstudio",
            adapterID: ManagerNode.nativeSessionHostAdapterID,
            modelKey: modelKey,
            providerConfigurationRevision: providerConfigurationRevision,
            toolCatalogRevision: String(repeating: "a", count: 64),
            allowedTools: allowedTools,
            networkAllowed: networkAllowed,
            validationPlan: ManagerPreparedRunValidationPlan(
                completionGates: completionGates
            ),
            continuityMode: .managedAutonomous,
            budgetPolicy: BudgetPolicySelection(
                scope: BudgetPolicyScope(
                    kind: .projectOverride,
                    projectID: projectID,
                    projectGeneration: Int(generation)
                ),
                revision: 0,
                globalRevision: 1,
                inherited: true,
                policy: .default
            ),
            maximumInlineOutputBytes: 64 * 1_024
        )
        return try JSONSupport.data(from: descriptor.asDictionary())
    }
}
