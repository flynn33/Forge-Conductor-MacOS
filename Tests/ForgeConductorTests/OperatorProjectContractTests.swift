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
    nonisolated(unsafe) private static var responseSequences: [String: [Data]] = [:]
    nonisolated(unsafe) private static var paths: [String] = []
    nonisolated(unsafe) private static var bodies: [String: [Data]] = [:]

    static func configure(
        responses: [String: Data],
        statuses: [String: Int] = [:],
        failures: [String: Int] = [:],
        responseSequences: [String: [Data]] = [:]
    ) {
        lock.lock()
        self.responses = responses
        self.statuses = statuses
        failuresRemaining = failures
        self.responseSequences = responseSequences
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
        var data: Data?
        if var sequence = Self.responseSequences[path], !sequence.isEmpty {
            data = sequence.removeFirst()
            Self.responseSequences[path] = sequence
        } else {
            data = Self.responses[path]
        }
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
    func testInstructionArtifactOwnsToolsAndCustomGatesWhileRetainingAutomaticSelections() throws {
        let runID = RunID()
        let projectID = ProjectID()
        let builtIn = ProjectInstructionQueueStore.builtInCompletionGate
        let artifact = ProjectRunInstructionArtifact(
            runID: runID,
            projectID: projectID,
            projectGeneration: .initial,
            mission: "Follow the immutable instruction artifact.",
            sourcePath: "/tmp/forge-authority-artifact",
            contentSHA256: String(repeating: "c", count: 64),
            allowedTools: ["instruction_catalog", "instruction_read", "shell_exec"],
            completionGates: [builtIn, "owner.package-qualification"],
            documentCount: 2,
            instructionByteCount: 1_024,
            unresolvedDocumentCount: 0,
            createdAt: "2026-09-23T12:00:00Z"
        )
        let request = OperatorRunStartRequest(
            runID: runID.description,
            projectID: projectID.description,
            projectGeneration: ProjectGeneration.initial.rawValue,
            assignmentID: nil,
            mission: "Temporary draft mission",
            providerID: nil,
            adapterID: nil,
            modelKey: nil,
            allowedTools: ["fs_read"],
            completionGates: [
                "owner.unrelated-draft-qualification",
                CompletionCheckPreset.testsPass.rawValue,
                builtIn,
            ],
            networkAllowed: false,
            expectedProviderConfigurationRevision: "provider-revision",
            expectedToolCatalogRevision: String(repeating: "d", count: 64),
            maximumInlineOutputBytes: 64 * 1_024
        )

        let bound = request.usingInstructionArtifact(artifact)

        XCTAssertEqual(bound.mission, artifact.mission)
        XCTAssertEqual(bound.instructionArtifactSHA256, artifact.contentSHA256)
        XCTAssertEqual(bound.allowedTools, artifact.allowedTools)
        XCTAssertEqual(bound.completionGates, [
            builtIn,
            "owner.package-qualification",
            CompletionCheckPreset.testsPass.rawValue,
        ])
        XCTAssertFalse(bound.completionGates?.contains("owner.unrelated-draft-qualification") == true)
    }

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
        XCTAssertEqual(
            Set(try XCTUnwrap(defaultRequest.completionGates)),
            Set([ProjectInstructionQueueStore.builtInCompletionGate]
                + CompletionCheckPreset.defaults.map(\.rawValue))
        )
        XCTAssertEqual(defaultRequest.failurePolicy, .default)
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
                "completion_gates", "failure_policy",
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
        viewModel.failureBehavior = .pauseForReview
        viewModel.failureInstructions = "Preserve the failing evidence for operator review."
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
        XCTAssertEqual(
            Set(try XCTUnwrap(overrideRequest.completionGates)),
            Set([ProjectInstructionQueueStore.builtInCompletionGate, "fixture-check"]
                + CompletionCheckPreset.defaults.map(\.rawValue))
        )
        XCTAssertEqual(overrideRequest.networkAllowed, true)
        XCTAssertEqual(overrideRequest.failurePolicy.behavior, .pauseForReview)
        XCTAssertEqual(overrideRequest.failurePolicy.maximumRetries, 0)
        XCTAssertEqual(
            overrideRequest.failurePolicy.customInstructions,
            "Preserve the failing evidence for operator review."
        )

        let overrideDigest = String(repeating: "b", count: 64)
        let overrideBootstrap = "Follow the run instruction artifact. Snapshot: \(overrideDigest)"
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
                "/api/manager/runs/instruction-artifacts/import": try JSONSupport.data(from: [
                    "ok": true,
                    "run_id": "__REQUEST_RUN_ID__",
                    "project_id": projectID,
                    "project_generation": UInt64(1),
                    "mission": overrideBootstrap,
                    "source_path": "/private/tmp/override-instructions.txt",
                    "content_sha256": overrideDigest,
                    "document_count": 1,
                    "instruction_byte_count": 28,
                    "unresolved_document_count": 0,
                    "created_at": "2026-09-19T00:00:00Z",
                ]),
                "/api/manager/runs/prepare": try Self.preparedArtifactRunData(
                    projectID: projectID,
                    generation: 1,
                    snapshotSHA256: overrideDigest,
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
    func testQuickPasteAndSelectedOrDroppedSourceUseArtifactReferenceBeforePrepareAndStart() async throws {
        let projectID = UUID().uuidString.lowercased()
        let project = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Self.projectData(
                projectID: projectID,
                generation: 1,
                root: "/tmp/operator-large-paste",
                resetPriorGeneration: 0
            )) as? [String: Any]
        )
        let quickInstructions = "Preserve this concise requirement."
        let digest = String(repeating: "c", count: 64)
        let bootstrap = "Read the complete run-bound instruction artifact. Snapshot: \(digest)"
        OperatorProjectContractURLProtocol.configure(responses: [
            "/api/manager/operator/snapshot": try JSONSupport.data(from: [
                "projects": [project],
                "runs": [],
                "provider": [
                    "adapter_id": ManagerNode.nativeSessionHostAdapterID,
                    "provider_id": "lmstudio",
                    "health": "contract_valid",
                    "model_key": "fixture/artifact-model",
                ],
                "run_preparation": [
                    "state": "ready",
                    "provider_id": "lmstudio",
                    "adapter_id": ManagerNode.nativeSessionHostAdapterID,
                    "model_key": "fixture/artifact-model",
                    "schema_version": 1,
                    "provider_configuration_revision": "fixture-artifact-provider",
                    "tool_catalog_revision": String(repeating: "a", count: 64),
                    "allowed_tools": ["instruction_catalog", "instruction_read"],
                    "completion_gates": [ProjectInstructionQueueStore.builtInCompletionGate],
                    "network_allowed": false,
                ],
            ]),
            "/api/manager/autonomy/status": try JSONSupport.data(from: [
                "started": true,
                "active_run_ids": [],
                "deferred_run_ids": [],
            ]),
            "/api/manager/runs/instruction-artifacts/import": try JSONSupport.data(from: [
                "ok": true,
                "run_id": "__REQUEST_RUN_ID__",
                "project_id": projectID,
                "project_generation": UInt64(1),
                "mission": bootstrap,
                "source_path": "/private/tmp/staged.txt",
                "content_sha256": digest,
                "document_count": 1,
                "instruction_byte_count": quickInstructions.utf8.count,
                "unresolved_document_count": 0,
                "created_at": "2026-09-19T00:00:00Z",
            ]),
            "/api/manager/runs/prepare": try Self.preparedArtifactRunData(
                projectID: projectID,
                generation: 1,
                snapshotSHA256: digest
            ),
            "/api/manager/runs/start": try JSONSupport.data(from: [
                "run_id": "__REQUEST_RUN_ID__",
                "project_id": projectID,
                "project_generation": UInt64(1),
                "mission": bootstrap,
                "state": "created",
                "continuity_mode": ContinuityMode.managedAutonomous.rawValue,
                "provider_id": "lmstudio",
                "adapter_id": ManagerNode.nativeSessionHostAdapterID,
                "model_key": "fixture/artifact-model",
                "completion_gates": [ProjectInstructionQueueStore.builtInCompletionGate],
                "passed_gates": [],
            ]),
        ])
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
        viewModel.mission = quickInstructions
        viewModel.startRun()
        try await Self.waitUntilStartIdle(viewModel)

        XCTAssertNil(viewModel.errorMessage)
        let paths = OperatorProjectContractURLProtocol.requestedPaths()
        let importIndex = try XCTUnwrap(paths.firstIndex(of: "/api/manager/runs/instruction-artifacts/import"))
        let prepareIndex = try XCTUnwrap(paths.firstIndex(of: "/api/manager/runs/prepare"))
        let startIndex = try XCTUnwrap(paths.firstIndex(of: "/api/manager/runs/start"))
        XCTAssertLessThan(importIndex, prepareIndex)
        XCTAssertLessThan(prepareIndex, startIndex)
        let importData = try XCTUnwrap(OperatorProjectContractURLProtocol.requestedBodies(
            path: "/api/manager/runs/instruction-artifacts/import"
        ).first)
        let importBody = try JSONSupport.object(from: importData)
        let stagedPath = try XCTUnwrap(importBody["source_path"] as? String)
        XCTAssertNil(importBody["package_ids"])
        XCTAssertNil(importBody["mission"])
        let prepareData = try XCTUnwrap(OperatorProjectContractURLProtocol.requestedBodies(
            path: "/api/manager/runs/prepare"
        ).first)
        let prepareBody = try JSONSupport.object(from: prepareData)
        XCTAssertEqual(prepareBody["mission"] as? String, bootstrap)
        XCTAssertEqual(prepareBody["instruction_artifact_sha256"] as? String, digest)
        XCTAssertNil(prepareBody["local_instruction_source_path"])
        XCTAssertNotEqual(prepareBody["mission"] as? String, quickInstructions)
        let startData = try XCTUnwrap(OperatorProjectContractURLProtocol.requestedBodies(
            path: "/api/manager/runs/start"
        ).first)
        let startBody = try JSONSupport.object(from: startData)
        XCTAssertEqual(startBody["instruction_artifact_sha256"] as? String, digest)
        XCTAssertNil(startBody["local_instruction_source_path"])
        let cleanupDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while FileManager.default.fileExists(atPath: stagedPath),
              ContinuousClock.now < cleanupDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedPath))

        let selectedSource = FileManager.default.temporaryDirectory.appendingPathComponent(
            "forge-selected-\(UUID().uuidString.lowercased()).txt"
        )
        defer { try? FileManager.default.removeItem(at: selectedSource) }
        try quickInstructions.write(to: selectedSource, atomically: true, encoding: .utf8)
        XCTAssertTrue(viewModel.setInstructionSource(selectedSource))
        XCTAssertTrue(viewModel.canStart)
        viewModel.startRun()
        try await Self.waitUntilStartIdle(viewModel)
        XCTAssertNil(viewModel.errorMessage)
        let importBodies = OperatorProjectContractURLProtocol.requestedBodies(
            path: "/api/manager/runs/instruction-artifacts/import"
        )
        XCTAssertEqual(importBodies.count, 2)
        let selectedImport = try JSONSupport.object(from: importBodies[1])
        XCTAssertEqual(selectedImport["source_path"] as? String, selectedSource.path)
        XCTAssertNil(selectedImport["package_ids"])
        XCTAssertNil(selectedImport["mission"])
    }

    @MainActor
    func testExistingInstructionPackageSelectionUsesStoredIdentityBeforePrepare() async throws {
        let projectID = UUID().uuidString.lowercased()
        let packageID = UUID().uuidString.lowercased()
        let digest = String(repeating: "e", count: 64)
        let bootstrap = "Follow the selected stored package. Snapshot: \(digest)"
        let project = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.projectData(
            projectID: projectID,
            generation: 1,
            root: "/tmp/operator-selected-package",
            resetPriorGeneration: 0
        )) as? [String: Any])
        OperatorProjectContractURLProtocol.configure(responses: [
            "/api/manager/operator/snapshot": try JSONSupport.data(from: [
                "projects": [project],
                "runs": [],
                "provider": [
                    "adapter_id": ManagerNode.nativeSessionHostAdapterID,
                    "provider_id": "lmstudio",
                    "health": "contract_valid",
                    "model_key": "fixture/package-model",
                ],
                "run_preparation": [
                    "state": "ready",
                    "provider_id": "lmstudio",
                    "adapter_id": ManagerNode.nativeSessionHostAdapterID,
                    "model_key": "fixture/package-model",
                    "schema_version": 1,
                    "provider_configuration_revision": "fixture-package-provider",
                    "tool_catalog_revision": String(repeating: "a", count: 64),
                    "allowed_tools": ["instruction_catalog", "instruction_read"],
                    "completion_gates": [ProjectInstructionQueueStore.builtInCompletionGate],
                    "network_allowed": false,
                ],
            ]),
            "/api/manager/autonomy/status": try JSONSupport.data(from: [
                "started": true,
                "active_run_ids": [],
                "deferred_run_ids": [],
            ]),
            "/api/manager/projects/instruction-packages": try JSONSupport.data(from: [
                "project_id": projectID,
                "project_generation": UInt64(1),
                "revision": UInt64(4),
                "running": false,
                "packages": [[
                    "id": packageID,
                    "project_id": projectID,
                    "project_generation": UInt64(1),
                    "package_id": "stored-package",
                    "version": "1",
                    "display_name": "Stored Package",
                    "mission": bootstrap,
                    "source_path": "/source/no-longer-required.md",
                    "content_sha256": digest,
                    "allowed_tools": ["instruction_catalog", "instruction_read"],
                    "completion_gates": [ProjectInstructionQueueStore.builtInCompletionGate],
                    "document_count": 1,
                    "instruction_byte_count": 42,
                    "unresolved_document_count": 0,
                    "import_ready": true,
                    "position": 0,
                    "state": "queued",
                    "created_at": "2026-09-19T00:00:00Z",
                    "updated_at": "2026-09-19T00:00:00Z",
                ]],
            ]),
            "/api/manager/runs/instruction-artifacts/import": try JSONSupport.data(from: [
                "ok": true,
                "run_id": "__REQUEST_RUN_ID__",
                "project_id": projectID,
                "project_generation": UInt64(1),
                "mission": bootstrap,
                "source_path": "/source/no-longer-required.md",
                "content_sha256": digest,
                "document_count": 1,
                "instruction_byte_count": 42,
                "unresolved_document_count": 0,
                "created_at": "2026-09-19T00:00:00Z",
            ]),
            "/api/manager/runs/prepare": try Self.preparedArtifactRunData(
                projectID: projectID,
                generation: 1,
                snapshotSHA256: digest
            ),
            "/api/manager/runs/start": try JSONSupport.data(from: [
                "run_id": "__REQUEST_RUN_ID__",
                "project_id": projectID,
                "project_generation": UInt64(1),
                "mission": bootstrap,
                "state": "created",
                "continuity_mode": ContinuityMode.managedAutonomous.rawValue,
                "provider_id": "lmstudio",
                "adapter_id": ManagerNode.nativeSessionHostAdapterID,
                "model_key": "fixture/package-model",
                "completion_gates": [ProjectInstructionQueueStore.builtInCompletionGate],
                "passed_gates": [],
            ]),
        ])
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
        XCTAssertEqual(viewModel.availableInstructionPackages.map(\.id), [packageID])
        viewModel.toggleInstructionPackage(packageID)
        XCTAssertTrue(viewModel.canStart)
        XCTAssertEqual(viewModel.taskDraft.packageIDs, [packageID])
        XCTAssertTrue(viewModel.taskDraft.quickInstructions.isEmpty)
        viewModel.startRun()
        try await Self.waitUntilStartIdle(viewModel)

        XCTAssertNil(viewModel.errorMessage)
        let body = try JSONSupport.object(from: try XCTUnwrap(
            OperatorProjectContractURLProtocol.requestedBodies(
                path: "/api/manager/runs/instruction-artifacts/import"
            ).first
        ))
        XCTAssertEqual(body["package_ids"] as? [String], [packageID])
        XCTAssertNil(body["source_path"])
        let paths = OperatorProjectContractURLProtocol.requestedPaths()
        XCTAssertLessThan(
            try XCTUnwrap(paths.firstIndex(of: "/api/manager/runs/instruction-artifacts/import")),
            try XCTUnwrap(paths.firstIndex(of: "/api/manager/runs/prepare"))
        )
    }

    @MainActor
    func testMissingModelReturnsFocusedRecoveryWithoutSubmittingRun() async throws {
        let projectID = UUID().uuidString.lowercased()
        let project = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Self.projectData(
                    projectID: projectID,
                    generation: 1,
                    root: "/tmp/operator-waiting-project",
                    resetPriorGeneration: 0
                )
            ) as? [String: Any]
        )
        let detail = "Save a local model in Model connection. Forge will reuse it automatically for this task."
        let readiness = ManagerRunPreparationResult(
            projectID: projectID,
            projectGeneration: 1,
            readiness: .waitingDependency,
            detail: detail,
            recoveryAction: .configureProvider
        )
        let waitingDigest = String(repeating: "f", count: 64)
        OperatorProjectContractURLProtocol.configure(responses: [
            "/api/manager/operator/snapshot": try JSONSupport.data(from: [
                "projects": [project],
                "runs": [],
                "provider": [
                    "adapter_id": ManagerNode.nativeSessionHostAdapterID,
                    "health": "unavailable",
                ],
                "run_preparation": [
                    "state": "waiting_dependency",
                    "adapter_id": ManagerNode.nativeSessionHostAdapterID,
                    "schema_version": 1,
                    "allowed_tools": ["fs_read"],
                    "completion_gates": [ProjectInstructionQueueStore.builtInCompletionGate],
                    "network_allowed": false,
                    "detail": "A saved local model is not available yet.",
                ],
            ]),
            "/api/manager/autonomy/status": try JSONSupport.data(from: [
                "started": true,
                "active_run_ids": [],
                "deferred_run_ids": [],
            ]),
            "/api/manager/runs/instruction-artifacts/import": try JSONSupport.data(from: [
                "ok": true,
                "run_id": "__REQUEST_RUN_ID__",
                "project_id": projectID,
                "project_generation": UInt64(1),
                "mission": "Follow the run instruction artifact. Snapshot: \(waitingDigest)",
                "source_path": "/private/tmp/waiting-instructions.txt",
                "content_sha256": waitingDigest,
                "document_count": 1,
                "instruction_byte_count": 37,
                "unresolved_document_count": 0,
                "created_at": "2026-09-19T00:00:00Z",
            ]),
            "/api/manager/runs/prepare": try JSONSupport.data(from: readiness.asDictionary()),
        ])
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
        viewModel.mission = "Prepare with minimal ordinary inputs."
        XCTAssertTrue(viewModel.canStart)
        XCTAssertNil(viewModel.makeStartRequest()?.modelKey)

        viewModel.startRun()
        try await Self.waitUntilStartIdle(viewModel)
        XCTAssertEqual(viewModel.projectRunPreparation?.readiness, .waitingDependency)
        XCTAssertEqual(viewModel.preparationRecoveryAction, .configureProvider)
        XCTAssertEqual(viewModel.notice, detail)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.startRequiresReconciliation)
        XCTAssertEqual(
            OperatorProjectContractURLProtocol.requestedBodies(
                path: "/api/manager/runs/start"
            ).count,
            0
        )
    }

    @MainActor
    func testStaleProjectGenerationIsAutomaticallyRepreparedBeforeOneStart() async throws {
        let projectID = UUID().uuidString.lowercased()
        let project = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Self.projectData(
                    projectID: projectID,
                    generation: 1,
                    root: "/tmp/operator-generation-project",
                    resetPriorGeneration: 0
                )
            ) as? [String: Any]
        )
        let mission = "Continue from the current project generation."
        let generationDigest = String(repeating: "7", count: 64)
        let generationBootstrap = "Follow the run instruction artifact. Snapshot: \(generationDigest)"
        let stale = ManagerRunPreparationResult(
            projectID: projectID,
            projectGeneration: 2,
            readiness: .automaticallyPreparing,
            detail: "The selected project changed. Forge is refreshing its current generation before Start.",
            recoveryAction: .retryPreparation
        )
        OperatorProjectContractURLProtocol.configure(
            responses: [
                "/api/manager/operator/snapshot": try JSONSupport.data(from: [
                    "projects": [project],
                    "runs": [],
                    "provider": [
                        "adapter_id": ManagerNode.nativeSessionHostAdapterID,
                        "provider_id": "lmstudio",
                        "health": "contract_valid",
                        "model_key": "fixture/generation-model",
                    ],
                    "run_preparation": [
                        "state": "ready",
                        "provider_id": "lmstudio",
                        "adapter_id": ManagerNode.nativeSessionHostAdapterID,
                        "model_key": "fixture/generation-model",
                        "schema_version": 1,
                        "provider_configuration_revision": "fixture-generation-provider",
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
                "/api/manager/runs/start": try JSONSupport.data(from: [
                    "run_id": "__REQUEST_RUN_ID__",
                    "project_id": projectID,
                    "project_generation": UInt64(2),
                    "mission": generationBootstrap,
                    "state": "created",
                    "continuity_mode": ContinuityMode.managedAutonomous.rawValue,
                    "provider_id": "lmstudio",
                    "adapter_id": ManagerNode.nativeSessionHostAdapterID,
                    "model_key": "fixture/generation-model",
                    "completion_gates": [ProjectInstructionQueueStore.builtInCompletionGate],
                    "passed_gates": [],
                ]),
            ],
            responseSequences: [
                "/api/manager/runs/instruction-artifacts/import": [
                    try JSONSupport.data(from: [
                        "ok": true,
                        "run_id": "__REQUEST_RUN_ID__",
                        "project_id": projectID,
                        "project_generation": UInt64(1),
                        "mission": generationBootstrap,
                        "source_path": "/private/tmp/generation-instructions.txt",
                        "content_sha256": generationDigest,
                        "document_count": 1,
                        "instruction_byte_count": mission.utf8.count,
                        "unresolved_document_count": 0,
                        "created_at": "2026-09-19T00:00:00Z",
                    ]),
                    try JSONSupport.data(from: [
                        "ok": true,
                        "run_id": "__REQUEST_RUN_ID__",
                        "project_id": projectID,
                        "project_generation": UInt64(2),
                        "mission": generationBootstrap,
                        "source_path": "/private/tmp/generation-instructions.txt",
                        "content_sha256": generationDigest,
                        "document_count": 1,
                        "instruction_byte_count": mission.utf8.count,
                        "unresolved_document_count": 0,
                        "created_at": "2026-09-19T00:00:00Z",
                    ]),
                ],
                "/api/manager/runs/prepare": [
                    try JSONSupport.data(from: stale.asDictionary()),
                    try Self.preparedArtifactRunData(
                        projectID: projectID,
                        generation: 2,
                        snapshotSHA256: generationDigest,
                        providerConfigurationRevision: "fixture-generation-provider",
                        modelKey: "fixture/generation-model",
                        allowedTools: ["fs_read"],
                        completionGates: [ProjectInstructionQueueStore.builtInCompletionGate],
                        networkAllowed: false
                    ),
                ],
            ]
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
        try await Self.waitUntilStartIdle(viewModel)

        let prepareBodies = OperatorProjectContractURLProtocol.requestedBodies(
            path: "/api/manager/runs/prepare"
        )
        XCTAssertEqual(prepareBodies.count, 2)
        let refreshedPreparation = try JSONSupport.object(from: prepareBodies[1])
        XCTAssertEqual((refreshedPreparation["project_generation"] as? NSNumber)?.uint64Value, 2)
        let startBodies = OperatorProjectContractURLProtocol.requestedBodies(
            path: "/api/manager/runs/start"
        )
        XCTAssertEqual(startBodies.count, 1)
        let submittedStart = try JSONSupport.object(from: startBodies[0])
        XCTAssertEqual((submittedStart["project_generation"] as? NSNumber)?.uint64Value, 2)
        XCTAssertEqual(viewModel.lastStartedRunID, submittedStart["run_id"] as? String)
        XCTAssertFalse(viewModel.startRequiresReconciliation)
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
        let replayDigest = String(repeating: "9", count: 64)
        let replayBootstrap = "Follow the run instruction artifact. Snapshot: \(replayDigest)"
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
                "/api/manager/runs/instruction-artifacts/import": try JSONSupport.data(from: [
                    "ok": true,
                    "run_id": "__REQUEST_RUN_ID__",
                    "project_id": projectID,
                    "project_generation": UInt64(1),
                    "mission": replayBootstrap,
                    "source_path": "/private/tmp/replay-instructions.txt",
                    "content_sha256": replayDigest,
                    "document_count": 1,
                    "instruction_byte_count": mission.utf8.count,
                    "unresolved_document_count": 0,
                    "created_at": "2026-09-19T00:00:00Z",
                ]),
                "/api/manager/runs/prepare": try Self.preparedArtifactRunData(
                    projectID: projectID,
                    generation: 1,
                    snapshotSHA256: replayDigest,
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
                    "mission": replayBootstrap,
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

    func testTaskDeletionUsesExactTypedIdentityAndValidatesReceipt() async throws {
        let runID = UUID().uuidString.lowercased()
        let projectID = UUID().uuidString.lowercased()
        OperatorProjectContractURLProtocol.configure(responses: [
            "/api/manager/runs/delete": try JSONSupport.data(from: [
                "run_id": runID,
                "project_id": projectID,
                "project_generation": UInt64(3),
                "prior_state": "completed",
                "deleted_at": "2026-09-21T12:00:00Z",
            ]),
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

        let receipt = try await client.deleteRun(
            runID: runID,
            projectID: projectID,
            generation: 3
        )

        XCTAssertEqual(receipt.runID.description, runID)
        XCTAssertEqual(receipt.projectID.description, projectID)
        XCTAssertEqual(receipt.projectGeneration.rawValue, 3)
        XCTAssertEqual(receipt.priorState, .completed)
        XCTAssertEqual(
            OperatorProjectContractURLProtocol.requestedPaths(),
            ["/api/manager/runs/delete"]
        )
        let request = try JSONSupport.object(
            from: try XCTUnwrap(
                OperatorProjectContractURLProtocol.requestedBodies(
                    path: "/api/manager/runs/delete"
                ).first
            )
        )
        XCTAssertEqual(Set(request.keys), ["run_id", "project_id", "project_generation"])
        XCTAssertEqual(request["run_id"] as? String, runID)
        XCTAssertEqual(request["project_id"] as? String, projectID)
        XCTAssertEqual(request["project_generation"] as? UInt64, 3)
    }

    func testInstructionQueueClientLoadsStableBoundedPages() async throws {
        let projectID = UUID().uuidString.lowercased()
        func package(_ position: Int) -> [String: Any] {
            [
                "id": UUID().uuidString.lowercased(),
                "project_id": projectID,
                "project_generation": UInt64(3),
                "package_id": "package-\(position)",
                "version": "1",
                "display_name": "Package \(position)",
                "mission": "Follow package \(position).",
                "source_path": "/tmp/package-\(position).md",
                "content_sha256": String(repeating: position == 0 ? "a" : "b", count: 64),
                "allowed_tools": ["instruction_catalog", "instruction_read"],
                "completion_gates": [ProjectInstructionQueueStore.builtInCompletionGate],
                "position": position,
                "state": "queued",
                "created_at": "2026-09-18T00:00:00Z",
                "updated_at": "2026-09-18T00:00:00Z",
            ]
        }
        let first = try JSONSupport.data(from: [
            "project_id": projectID,
            "project_generation": UInt64(3),
            "revision": UInt64(9),
            "running": false,
            "total_packages": 2,
            "cursor": 0,
            "next_cursor": 1,
            "packages": [package(0)],
        ])
        let second = try JSONSupport.data(from: [
            "project_id": projectID,
            "project_generation": UInt64(3),
            "revision": UInt64(9),
            "running": false,
            "total_packages": 2,
            "cursor": 1,
            "packages": [package(1)],
        ])
        OperatorProjectContractURLProtocol.configure(
            responses: [:],
            responseSequences: [
                "/api/manager/projects/instruction-packages": [first, second],
            ]
        )
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
        XCTAssertEqual(loaded.packages.map(\.position), [0, 1])
        XCTAssertEqual(loaded.totalPackages, 2)
        let bodies = OperatorProjectContractURLProtocol.requestedBodies(
            path: "/api/manager/projects/instruction-packages"
        )
        XCTAssertEqual(bodies.count, 2)
        let continuation = try JSONSupport.object(from: bodies[1])
        XCTAssertEqual(continuation["cursor"] as? Int, 1)
        XCTAssertEqual(continuation["limit"] as? Int, 128)
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
        let result = ManagerRunPreparationResult(
            projectID: projectID,
            projectGeneration: generation,
            readiness: .ready,
            detail: descriptor.detail,
            recoveryAction: .none,
            descriptor: descriptor
        )
        return try JSONSupport.data(from: result.asDictionary())
    }

    private static func preparedArtifactRunData(
        projectID: String,
        generation: UInt64,
        snapshotSHA256: String,
        providerConfigurationRevision: String = "fixture-artifact-provider",
        modelKey: String = "fixture/artifact-model",
        allowedTools: [String] = ["instruction_catalog", "instruction_read"],
        completionGates: [String] = [ProjectInstructionQueueStore.builtInCompletionGate],
        networkAllowed: Bool = false
    ) throws -> Data {
        let descriptor = try ManagerPreparedRunDescriptor.make(
            detail: "The exact artifact-backed run inputs are ready.",
            projectID: projectID,
            projectGeneration: generation,
            source: ManagerPreparedRunSource(
                kind: .instructionArtifact,
                reference: "instruction-artifact:fixture",
                snapshotSHA256: snapshotSHA256
            ),
            documents: [ManagerPreparedRunDocumentReference(
                reference: "instruction-snapshot:\(snapshotSHA256)/.forge/canonical/document-000001.txt",
                byteCount: 52_000,
                sha256: String(repeating: "d", count: 64)
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
        let result = ManagerRunPreparationResult(
            projectID: projectID,
            projectGeneration: generation,
            readiness: .ready,
            detail: descriptor.detail,
            recoveryAction: .none,
            descriptor: descriptor
        )
        return try JSONSupport.data(from: result.asDictionary())
    }
}
