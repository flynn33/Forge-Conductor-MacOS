import Foundation
import XCTest
@testable import ForgeConductorCore

final class AutonomousContinuityAcceptanceTests: XCTestCase {
    private var root: URL!
    private var home: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "forge-autonomous-continuity-\(UUID().uuidString)",
            isDirectory: true
        )
        home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testThresholdRolloverAutomaticallyContinuesFreshSuccessorsAcrossProjects() async throws {
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        _ = try app.config.update(["allowed_roots": [root.path]], save: true)
        let alpha = try registerProject(app: app, name: "alpha")
        let beta = try registerProject(app: app, name: "beta")
        let alphaFile = try fixtureFile(in: alpha.root, contents: "alpha acceptance\n")
        let betaFile = try fixtureFile(in: beta.root, contents: "beta acceptance\n")
        let alphaProof = try readProof(path: alphaFile.path, app: app)
        let betaProof = try readProof(path: betaFile.path, app: app)

        let provider = AutonomousRolloverAcceptanceProvider(fixtures: [
            alpha.record.projectID.description: .init(path: alphaFile.path, proof: alphaProof),
            beta.record.projectID.description: .init(path: betaFile.path, proof: betaProof),
        ])
        let runtime = try ManagedAutonomyRuntime(
            app: app,
            registry: autonomousRolloverRegistry(provider: provider),
            managerID: "acceptance-rollover-manager",
            maximumConcurrentRuns: 2
        )
        _ = try await runtime.start()

        let alphaRun = try await runtime.createRun(runRequest(
            project: alpha,
            mission: "Exercise alpha automatic threshold rollover"
        ))
        let betaRun = try await runtime.createRun(runRequest(
            project: beta,
            mission: "Exercise beta automatic threshold rollover"
        ))
        let completedAlpha = try await waitForRun(
            repository: app.projectContexts.repository,
            runtime: runtime,
            runID: alphaRun.runID,
            state: .completed
        )
        let completedBeta = try await waitForRun(
            repository: app.projectContexts.repository,
            runtime: runtime,
            runID: betaRun.runID,
            state: .completed
        )

        let snapshot = await provider.snapshot()
        XCTAssertEqual(Set(snapshot.rootProjectIDs), [
            alpha.record.projectID.description,
            beta.record.projectID.description,
        ])
        XCTAssertEqual(Set(snapshot.continuationProjectIDs), [
            alpha.record.projectID.description,
            beta.record.projectID.description,
        ])
        XCTAssertEqual(snapshot.rootProjectIDs.count, 2)
        XCTAssertEqual(snapshot.continuationProjectIDs.count, 2)
        XCTAssertEqual(snapshot.bootstrapProjectIDs.count, 2)
        XCTAssertEqual(snapshot.exactAcknowledgementCount, 2)
        XCTAssertEqual(snapshot.exactAutomaticInputCount, 2)

        try await assertCompletedRollover(
            completedAlpha,
            project: alpha,
            proof: alphaProof,
            repository: app.projectContexts.repository,
            memory: app.projectMemory
        )
        try await assertCompletedRollover(
            completedBeta,
            project: beta,
            proof: betaProof,
            repository: app.projectContexts.repository,
            memory: app.projectMemory
        )
        XCTAssertNotEqual(
            completedAlpha.specification.work.metadata["continuity_operation_id"],
            completedBeta.specification.work.metadata["continuity_operation_id"]
        )
        await runtime.shutdown()
    }

    func testTransientProviderOutageSurvivesManagerRestartAndReconcilesOneTurn() async throws {
        let proof = String(repeating: "c", count: 64)
        let clock = AcceptanceClock(Date(timeIntervalSince1970: 10_000))
        let provider = RestartAcceptanceProvider(
            scenario: .transientOutage,
            completionProof: proof
        )
        var activeApp: ForgeApp? = try ForgeApp.bootstrap(home: home, clock: clock)
        defer { activeApp?.shutdown() }
        let project = try registerProject(app: try XCTUnwrap(activeApp), name: "outage")
        var runtime: ManagedAutonomyRuntime? = try ManagedAutonomyRuntime(
            app: try XCTUnwrap(activeApp),
            registry: restartAcceptanceRegistry(provider: provider),
            managerID: "acceptance-outage-before-restart",
            maximumConcurrentRuns: 1
        )
        _ = try await runtime?.start()
        let created = try await runtime?.createRun(runRequest(
            project: project,
            mission: "Recover one durable provider turn after an outage",
            initialEvidence: [proof]
        ))
        let runID = try XCTUnwrap(created?.runID)
        let waiting = try await waitForRun(
            repository: try XCTUnwrap(activeApp).projectContexts.repository,
            runtime: try XCTUnwrap(runtime),
            runID: runID,
            state: .waitingProvider
        )
        XCTAssertEqual(waiting.lastErrorCode, "acceptance_provider_unavailable")
        XCTAssertNotNil(waiting.retryAt)

        await runtime?.shutdown()
        runtime = nil
        activeApp?.shutdown()
        activeApp = nil
        clock.advance(by: 60)

        let restartedApp = try ForgeApp.bootstrap(home: home, clock: clock)
        activeApp = restartedApp
        let restartedRuntime = try ManagedAutonomyRuntime(
            app: restartedApp,
            registry: restartAcceptanceRegistry(provider: provider),
            managerID: "acceptance-outage-after-restart",
            maximumConcurrentRuns: 1
        )
        runtime = restartedRuntime
        let report = try await restartedRuntime.start()
        XCTAssertEqual(report.discoveredRuns, 1)
        XCTAssertEqual(report.activatedRuns, [runID])
        let completed = try await waitForRun(
            repository: restartedApp.projectContexts.repository,
            runtime: restartedRuntime,
            runID: runID,
            state: .completed
        )
        XCTAssertEqual(completed.specification.work.metadata["completion_gate.fixture_read.proof_sha256"], proof)
        let snapshot = await provider.snapshot()
        XCTAssertEqual(snapshot.rootAttempts, 2)
        XCTAssertEqual(snapshot.completedRoots, 1)
        XCTAssertEqual(Set(snapshot.idempotencyKeys).count, 1)
        await restartedRuntime.shutdown()
        runtime = nil
    }

    func testProviderConfigurationBlockRemainsQuiescentAcrossManagerRestart() async throws {
        let proof = String(repeating: "d", count: 64)
        let provider = RestartAcceptanceProvider(
            scenario: .blockedConfiguration,
            completionProof: proof
        )
        var activeApp: ForgeApp? = try ForgeApp.bootstrap(home: home)
        defer { activeApp?.shutdown() }
        let project = try registerProject(app: try XCTUnwrap(activeApp), name: "configuration")
        var runtime: ManagedAutonomyRuntime? = try ManagedAutonomyRuntime(
            app: try XCTUnwrap(activeApp),
            registry: restartAcceptanceRegistry(provider: provider),
            managerID: "acceptance-configuration-before-restart",
            maximumConcurrentRuns: 1
        )
        _ = try await runtime?.start()
        let created = try await runtime?.createRun(runRequest(
            project: project,
            mission: "Persist a provider configuration block",
            initialEvidence: [proof]
        ))
        let runID = try XCTUnwrap(created?.runID)
        let blocked = try await waitForRun(
            repository: try XCTUnwrap(activeApp).projectContexts.repository,
            runtime: try XCTUnwrap(runtime),
            runID: runID,
            state: .blockedConfiguration
        )
        XCTAssertEqual(blocked.lastErrorCode, "acceptance_provider_unauthorized")
        XCTAssertNil(blocked.retryAt)

        await runtime?.shutdown()
        runtime = nil
        activeApp?.shutdown()
        activeApp = nil

        let restartedApp = try ForgeApp.bootstrap(home: home)
        activeApp = restartedApp
        let restartedRuntime = try ManagedAutonomyRuntime(
            app: restartedApp,
            registry: restartAcceptanceRegistry(provider: provider),
            managerID: "acceptance-configuration-after-restart",
            maximumConcurrentRuns: 1
        )
        runtime = restartedRuntime
        let report = try await restartedRuntime.start()
        XCTAssertEqual(report.discoveredRuns, 1)
        XCTAssertTrue(report.activatedRuns.isEmpty)
        try await Task.sleep(for: .milliseconds(100))
        try await restartedRuntime.tick()
        let retained = try await restartedRuntime.run(runID)
        XCTAssertEqual(retained.state, .blockedConfiguration)
        XCTAssertEqual(retained.lastErrorCode, "acceptance_provider_unauthorized")
        let snapshot = await provider.snapshot()
        XCTAssertEqual(snapshot.rootAttempts, 1)
        XCTAssertEqual(snapshot.completedRoots, 0)
        await restartedRuntime.shutdown()
        runtime = nil
    }

    private func registerProject(app: ForgeApp, name: String) throws -> AcceptanceProject {
        let projectRoot = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let initialized = try app.projectMemory.initializeUnchecked(
            path: projectRoot.path,
            displayName: "Acceptance \(name.capitalized)"
        )
        let projectID = try XCTUnwrap(initialized["project_id"] as? String)
        let descriptor = try app.projectMemory.identities.descriptor(projectID: projectID)
        let record = try app.projectContexts.registerProjectUnchecked(
            descriptor: descriptor,
            canonicalRoot: projectRoot
        )
        return AcceptanceProject(root: projectRoot, record: record)
    }

    private func fixtureFile(in projectRoot: URL, contents: String) throws -> URL {
        let file = projectRoot.appendingPathComponent("acceptance.txt")
        try Data(contents.utf8).write(to: file, options: .atomic)
        return file
    }

    private func readProof(path: String, app: ForgeApp) throws -> String {
        let result = try XCTUnwrap(try FilesystemToolPack().handle(
            name: "fs_read",
            arguments: ["path": path],
            clientID: ClientID("acceptance-proof"),
            app: app
        ))
        return JSONSupport.sha256Hex(try JSONSupport.canonicalJSON(result.payload))
    }

    private func runRequest(
        project: AcceptanceProject,
        mission: String,
        initialEvidence: [String] = []
    ) -> AutonomousRunRequest {
        AutonomousRunRequest(
            projectID: project.record.projectID,
            projectGeneration: project.record.generation,
            assignmentID: "FC-E2E-001",
            mission: mission,
            providerID: "acceptance-provider",
            adapterID: "acceptance-adapter",
            modelKey: "acceptance-model",
            specification: AutonomousRunSpecification(
                allowedTools: ["fs_read"],
                completionGates: ["fixture_read"],
                work: AutonomousRunWork(
                    currentPhase: "FC-ROLL-001",
                    workItem: "automatic-successor-continuation",
                    nextAction: "Continue without operator intervention",
                    evidenceReferences: initialEvidence
                )
            ),
            authorizationScope: ToolAuthorizationScope(
                canonicalRoots: [project.root],
                allowedTools: ["fs_read"],
                networkAllowed: false,
                maximumInlineOutputBytes: 64 * 1_024
            )
        )
    }

    private func waitForRun(
        repository: ProjectControlPlaneRepository,
        runtime: ManagedAutonomyRuntime,
        runID: RunID,
        state: AutonomousRunState,
        timeout: Duration = .seconds(10)
    ) async throws -> AutonomousRunRecord {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let run = try await repository.autonomousRun(runID), run.state == state {
                return run
            }
            try await runtime.tick()
            try await Task.sleep(for: .milliseconds(25))
        }
        let final = try await repository.autonomousRun(runID)
        XCTFail(
            "Timed out waiting for \(state.rawValue); final state was "
                + "\(final?.state.rawValue ?? "missing"), error="
                + "\(final?.lastErrorCode ?? "none"): \(final?.lastErrorSummary ?? "none")"
        )
        return try XCTUnwrap(final)
    }

    private func assertCompletedRollover(
        _ run: AutonomousRunRecord,
        project: AcceptanceProject,
        proof: String,
        repository: ProjectControlPlaneRepository,
        memory: ProjectMemoryService
    ) async throws {
        XCTAssertEqual(run.projectID, project.record.projectID)
        XCTAssertEqual(run.projectGeneration, project.record.generation)
        XCTAssertEqual(run.specification.work.metadata["completion_gate.fixture_read.proof_sha256"], proof)
        XCTAssertTrue(run.specification.work.evidenceReferences.contains(proof))
        let operationString = try XCTUnwrap(
            run.specification.work.metadata["continuity_operation_id"]
        )
        let operationID = try XCTUnwrap(UUID(uuidString: operationString))
        let projectMemory = try memory.repositoryForProject(project.record.projectID.description)
        let operation = try XCTUnwrap(try projectMemory.continuityOperationV2(
            id: operationID.uuidString.lowercased()
        ))
        let candidates = try await repository.providerSessions(operationID: operationID)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertTrue(candidates.allSatisfy {
            $0.projectID == project.record.projectID
                && $0.projectGeneration == project.record.generation
                && $0.runID == run.runID
        })
        let predecessorValue = try await repository.providerSession(
            operation.predecessorSessionID
        )
        let predecessor = try XCTUnwrap(predecessorValue)
        let successor = try XCTUnwrap(candidates.first { $0.accepted })
        XCTAssertEqual(predecessor.status, .sealed)
        XCTAssertEqual(successor.status, .active)
        XCTAssertNotEqual(predecessor.sessionID, successor.sessionID)
        do {
            _ = try await repository.invocationContext(
                for: ProjectBindingOwner(kind: .providerSession, id: predecessor.sessionID)
            )
            XCTFail("A sealed predecessor retained tool authority")
        } catch {}
        _ = try await repository.invocationContext(
            for: ProjectBindingOwner(kind: .providerSession, id: successor.sessionID)
        )

        XCTAssertEqual(operation.projectID, project.record.projectID.description)
        XCTAssertEqual(operation.projectGeneration, project.record.generation.rawValue)
        XCTAssertEqual(operation.runID, run.runID.description)
        XCTAssertEqual(operation.state, .predecessorSealed)
        XCTAssertTrue(operation.continuationIssued)
        XCTAssertNotNil(operation.acknowledgementSHA256)
    }
}

private struct AcceptanceProject {
    let root: URL
    let record: ProjectControlRecord
}

private actor AutonomousRolloverAcceptanceProvider: ManagedModelProvider,
    SessionHostAdapter, SessionHostAdapterV2 {
    struct Fixture: Sendable {
        let path: String
        let proof: String
    }

    struct Snapshot: Sendable {
        let rootProjectIDs: [String]
        let continuationProjectIDs: [String]
        let bootstrapProjectIDs: [String]
        let exactAcknowledgementCount: Int
        let exactAutomaticInputCount: Int
    }

    nonisolated let providerID = "acceptance-provider"
    nonisolated let identifier = "acceptance-adapter"
    nonisolated let version = "1"

    private let fixtures: [String: Fixture]
    private var providerTurns: [String: ProviderTurn] = [:]
    private var bootstrapReceipts: [String: BootstrapReceipt] = [:]
    private var projectByBootstrapResponse: [String: String] = [:]
    private var rootProjectIDs: [String] = []
    private var continuationProjectIDs: [String] = []
    private var bootstrapProjectIDs: [String] = []
    private var exactAcknowledgementCount = 0
    private var exactAutomaticInputCount = 0

    init(fixtures: [String: Fixture]) {
        self.fixtures = fixtures
    }

    func probe() async throws -> ProviderCapabilities {
        try ProviderCapabilities(
            providerID: providerID,
            providerVersion: "acceptance-1",
            modelKey: "acceptance-model",
            providerInstanceID: "acceptance-instance",
            contextLength: 4_096,
            maximumContextLength: 4_096,
            statefulResponses: true,
            streaming: true,
            customTools: true,
            mcp: false,
            structuredOutput: false,
            usageReporting: true,
            idempotencyLookup: true,
            capabilityFingerprintSHA256: String(repeating: "a", count: 64)
        )
    }

    func createRoot(_ request: ProviderRootRequest) async throws -> ProviderTurn {
        if let existing = providerTurns[request.idempotencyKey] { return existing }
        guard let entry = fixtures.first(where: { request.input.contains($0.key) }) else {
            throw AutonomyError.invalidRequest("acceptance root did not name an exact project")
        }
        let projectID = entry.key
        let arguments = try JSONSerialization.data(
            withJSONObject: ["path": entry.value.path],
            options: [.sortedKeys]
        )
        let suffix = String(projectID.prefix(12))
        let turn = try ProviderTurn(
            requestID: "threshold-request-\(suffix)",
            responseID: "threshold-response-\(projectID)",
            providerID: providerID,
            providerVersion: "acceptance-1",
            modelKey: request.modelKey,
            providerInstanceID: "acceptance-instance",
            messages: ["Read the exact project fixture before rollover"],
            toolCalls: [try ProviderToolCall(
                callID: "threshold-read-\(suffix)",
                name: "fs_read",
                argumentsJSON: arguments
            )],
            usage: try ProviderUsage(
                capacity: 4_096,
                inputTokens: 2_828,
                outputTokens: 32,
                source: .providerExact,
                confidence: 1
            ),
            completed: true,
            finishReason: .toolCalls
        )
        rootProjectIDs.append(projectID)
        providerTurns[request.idempotencyKey] = turn
        return turn
    }

    func continueSession(_ request: ProviderContinuationRequest) async throws -> ProviderTurn {
        if let existing = providerTurns[request.idempotencyKey] { return existing }
        guard let projectID = projectByBootstrapResponse[request.previousResponseID],
              let fixture = fixtures[projectID] else {
            throw AutonomyError.intentConflict
        }
        let expectedInput = try ManagedContinuityWorker.automaticContinuationInput()
        guard request.input == expectedInput else { throw AutonomyError.intentConflict }
        exactAutomaticInputCount += 1
        let message = try JSONSupport.canonicalJSON([
            "forge_run_status": "completion_requested",
            "summary": "The acknowledged successor continued the exact project",
            "gate_evidence": ["fixture_read": fixture.proof],
        ])
        let suffix = String(projectID.prefix(12))
        let turn = try ProviderTurn(
            requestID: "automatic-request-\(suffix)",
            responseID: "automatic-response-\(projectID)",
            previousResponseID: request.previousResponseID,
            providerID: providerID,
            providerVersion: "acceptance-1",
            modelKey: request.modelKey,
            providerInstanceID: "acceptance-instance",
            messages: [message],
            toolCalls: [],
            usage: try ProviderUsage(
                capacity: 4_096,
                inputTokens: 128,
                outputTokens: 32,
                source: .providerExact,
                confidence: 1
            ),
            completed: true,
            finishReason: .stop
        )
        continuationProjectIDs.append(projectID)
        providerTurns[request.idempotencyKey] = turn
        return turn
    }

    func lookup(idempotencyKey: String) async throws -> ProviderTurn? {
        providerTurns[idempotencyKey]
    }

    func cancel(requestID: String) async {}

    func capabilitiesV2() async throws -> HostCapabilitiesV2 {
        HostCapabilitiesV2(
            atomicCreateAndBootstrap: true,
            freshRoot: true,
            usageReporting: true,
            idempotencyLookup: true,
            projectGenerationFencing: true
        )
    }

    func createAndBootstrap(
        request: SessionCreationRequestV2,
        handoffJSON: Data,
        challenge: BootstrapChallenge
    ) async throws -> BootstrapReceipt {
        if let existing = bootstrapReceipts[request.idempotencyKey] { return existing }
        guard let object = try JSONSerialization.jsonObject(with: handoffJSON) as? [String: Any],
              let decoded = ContinuityHandoffV2.fromDictionary(object),
              let handoffID = UUID(uuidString: decoded.handoffID) else {
            throw ProjectMemoryError.invalidRequest("acceptance adapter received an invalid handoff")
        }
        let handoff = try decoded.validated()
        guard handoff.projectID == request.projectID.description,
              handoff.projectGeneration == request.projectGeneration.rawValue,
              handoff.runID == request.runID.description,
              handoff.operationID.caseInsensitiveCompare(
                request.operationID.uuidString
              ) == .orderedSame,
              handoff.bootstrapNonce == challenge.nonce,
              challenge.acknowledgementContractVersion == 2 else {
            throw ProjectMemoryError.conflict("acceptance bootstrap scope did not match")
        }
        let acknowledgement = BootstrapAcknowledgementV2(
            projectID: request.projectID,
            projectGeneration: request.projectGeneration,
            runID: request.runID,
            operationID: request.operationID,
            handoffID: handoffID,
            handoffSHA256: handoff.contentSHA256,
            nonce: challenge.nonce
        )
        try acknowledgement.validate(handoff: handoff)
        exactAcknowledgementCount += 1
        let responseID = "bootstrap-response-\(request.projectID.description)"
        let receipt = BootstrapReceipt(
            acknowledgement: acknowledgement,
            internalSessionID: "fresh-successor-\(request.operationID.uuidString.lowercased())",
            providerResponseID: responseID,
            modelKey: request.modelKey,
            adapterID: identifier,
            usage: ContextBudgetStatus(
                capacity: 4_096,
                used: 128,
                reserved: 768,
                remaining: 3_200,
                source: "provider_exact",
                confidence: 1,
                action: .normal
            )
        )
        bootstrapProjectIDs.append(request.projectID.description)
        projectByBootstrapResponse[responseID] = request.projectID.description
        bootstrapReceipts[request.idempotencyKey] = receipt
        return receipt
    }

    func receipt(forIdempotencyKey key: String) async throws -> BootstrapReceipt? {
        bootstrapReceipts[key]
    }

    func cancel(operationID: UUID) async {}

    func capabilities() async throws -> HostCapabilities {
        HostCapabilities(
            create: true,
            bootstrap: true,
            usageReporting: true,
            resume: false,
            idempotency: true,
            queryByIdempotencyKey: true
        )
    }

    func createSession(_ request: SessionCreationRequest) async throws -> HostSession {
        throw ContinuityRunError.hostCapabilityUnavailable
    }

    func session(forIdempotencyKey key: String) async throws -> HostSession? { nil }

    func bootstrap(_ session: HostSession, handoff: ContinuityHandoff) async throws {
        throw ContinuityRunError.hostCapabilityUnavailable
    }

    func awaitAcknowledgement(
        session: HostSession,
        handoffID: String,
        timeout: Duration
    ) async throws -> HandoffAcknowledgement {
        throw ContinuityRunError.hostCapabilityUnavailable
    }

    func cancel(operationID: String) async {}

    func snapshot() -> Snapshot {
        Snapshot(
            rootProjectIDs: rootProjectIDs,
            continuationProjectIDs: continuationProjectIDs,
            bootstrapProjectIDs: bootstrapProjectIDs,
            exactAcknowledgementCount: exactAcknowledgementCount,
            exactAutomaticInputCount: exactAutomaticInputCount
        )
    }
}

private struct RestartAcceptanceFailure: ManagedProviderFailure, LocalizedError {
    let managedProviderFailureDisposition: ManagedProviderFailureDisposition
    let managedProviderFailureCode: String
    let managedProviderRetryDelay: TimeInterval?
    var errorDescription: String? { managedProviderFailureCode }
}

private actor RestartAcceptanceProvider: ManagedModelProvider {
    enum Scenario: Sendable {
        case transientOutage
        case blockedConfiguration
    }

    struct Snapshot: Sendable {
        let rootAttempts: Int
        let completedRoots: Int
        let idempotencyKeys: [String]
    }

    nonisolated let providerID = "acceptance-provider"
    private let scenario: Scenario
    private let completionProof: String
    private var rootAttempts = 0
    private var completedRoots = 0
    private var idempotencyKeys: [String] = []
    private var receipts: [String: ProviderTurn] = [:]

    init(scenario: Scenario, completionProof: String) {
        self.scenario = scenario
        self.completionProof = completionProof
    }

    func probe() async throws -> ProviderCapabilities {
        try ProviderCapabilities(
            providerID: providerID,
            providerVersion: "acceptance-restart-1",
            modelKey: "acceptance-model",
            providerInstanceID: "acceptance-restart-instance",
            contextLength: 32_768,
            maximumContextLength: 32_768,
            statefulResponses: true,
            streaming: true,
            customTools: true,
            mcp: false,
            structuredOutput: false,
            usageReporting: true,
            idempotencyLookup: true,
            capabilityFingerprintSHA256: String(repeating: "b", count: 64)
        )
    }

    func createRoot(_ request: ProviderRootRequest) async throws -> ProviderTurn {
        if let existing = receipts[request.idempotencyKey] { return existing }
        rootAttempts += 1
        idempotencyKeys.append(request.idempotencyKey)
        switch scenario {
        case .transientOutage where rootAttempts == 1:
            throw RestartAcceptanceFailure(
                managedProviderFailureDisposition: .waitingProvider,
                managedProviderFailureCode: "acceptance_provider_unavailable",
                managedProviderRetryDelay: 0.01
            )
        case .blockedConfiguration:
            throw RestartAcceptanceFailure(
                managedProviderFailureDisposition: .blockedConfiguration,
                managedProviderFailureCode: "acceptance_provider_unauthorized",
                managedProviderRetryDelay: nil
            )
        case .transientOutage:
            let turn = try ProviderTurn(
                requestID: "restart-request",
                responseID: "restart-response",
                providerID: providerID,
                providerVersion: "acceptance-restart-1",
                modelKey: request.modelKey,
                providerInstanceID: "acceptance-restart-instance",
                messages: ["The durable provider turn reconciled after restart"],
                toolCalls: [],
                usage: try ProviderUsage(
                    capacity: 32_768,
                    inputTokens: 128,
                    outputTokens: 32,
                    source: .providerExact,
                    confidence: 1
                ),
                completed: true,
                finishReason: .stop
            )
            completedRoots += 1
            receipts[request.idempotencyKey] = turn
            return turn
        }
    }

    func continueSession(_ request: ProviderContinuationRequest) async throws -> ProviderTurn {
        if let existing = receipts[request.idempotencyKey] { return existing }
        guard case .transientOutage = scenario,
              request.previousResponseID == "restart-response" else {
            throw AutonomyError.invalidRequest("restart acceptance cannot continue this session")
        }
        let message = try JSONSupport.canonicalJSON([
            "forge_run_status": "completion_requested",
            "summary": "The restarted provider continued durable work",
            "gate_evidence": ["fixture_read": completionProof],
        ])
        let turn = try ProviderTurn(
            requestID: "restart-continuation-request",
            responseID: "restart-continuation-response",
            previousResponseID: request.previousResponseID,
            providerID: providerID,
            providerVersion: "acceptance-restart-1",
            modelKey: request.modelKey,
            providerInstanceID: "acceptance-restart-instance",
            messages: [message],
            toolCalls: [],
            usage: try ProviderUsage(
                capacity: 32_768,
                inputTokens: 192,
                outputTokens: 32,
                source: .providerExact,
                confidence: 1
            ),
            completed: true,
            finishReason: .stop
        )
        receipts[request.idempotencyKey] = turn
        return turn
    }

    func lookup(idempotencyKey: String) async throws -> ProviderTurn? {
        receipts[idempotencyKey]
    }

    func cancel(requestID: String) async {}

    func snapshot() -> Snapshot {
        Snapshot(
            rootAttempts: rootAttempts,
            completedRoots: completedRoots,
            idempotencyKeys: idempotencyKeys
        )
    }
}

private struct RestartAcceptanceUnavailableAdapter: SessionHostAdapter, Sendable {
    let identifier = "acceptance-adapter"
    let version = "1"

    func capabilities() async throws -> HostCapabilities {
        HostCapabilities(
            create: false,
            bootstrap: false,
            usageReporting: false,
            resume: false,
            idempotency: true,
            queryByIdempotencyKey: true
        )
    }

    func createSession(_ request: SessionCreationRequest) async throws -> HostSession {
        throw ContinuityRunError.hostCapabilityUnavailable
    }

    func session(forIdempotencyKey key: String) async throws -> HostSession? { nil }

    func bootstrap(_ session: HostSession, handoff: ContinuityHandoff) async throws {
        throw ContinuityRunError.hostCapabilityUnavailable
    }

    func awaitAcknowledgement(
        session: HostSession,
        handoffID: String,
        timeout: Duration
    ) async throws -> HandoffAcknowledgement {
        throw ContinuityRunError.hostCapabilityUnavailable
    }

    func cancel(operationID: String) async {}
}

private func autonomousRolloverRegistry(
    provider: AutonomousRolloverAcceptanceProvider
) -> HostAdapterRegistry {
    let registry = HostAdapterRegistry()
    registry.register(
        manifest: acceptanceManifest(),
        managedProviderFactory: { _ in provider },
        factory: { _ in provider }
    )
    return registry
}

private func restartAcceptanceRegistry(
    provider: RestartAcceptanceProvider
) -> HostAdapterRegistry {
    let registry = HostAdapterRegistry()
    registry.register(
        manifest: acceptanceManifest(),
        managedProviderFactory: { _ in provider },
        factory: { _ in RestartAcceptanceUnavailableAdapter() }
    )
    return registry
}

private func acceptanceManifest() -> HostPluginManifest {
    HostPluginManifest(
        identifier: "acceptance-adapter",
        version: "1",
        minimumContractVersion: 2,
        hostType: "fixture",
        capabilities: HostCapabilities(
            create: true,
            bootstrap: true,
            usageReporting: true,
            resume: false,
            idempotency: true,
            queryByIdempotencyKey: true
        ),
        configurationKeys: [],
        privacyRequirements: [],
        migrationVersion: 1
    )
}

private final class AcceptanceClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.withLock { value }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { value = value.addingTimeInterval(interval) }
    }
}
