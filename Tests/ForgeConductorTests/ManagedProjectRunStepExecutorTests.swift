import Foundation
import XCTest
@testable import ForgeConductorCore

final class ManagedProjectRunStepExecutorTests: XCTestCase {
    func testDurableBootstrapHoldRejectsDirectCoordinatorAndStaleExecutorSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("managed-bootstrap-hold-\(UUID().uuidString)")
        let repository = try ProjectControlPlaneRepository(databaseURL: root.appendingPathComponent("control.sqlite3"))
        do {
            let fixture = try await makeBootstrapHeldApplicationRun(repository: repository, root: root)
            let toolExecutor = ManagedStepToolExecutor()
            let broker = ToolInvocationBroker(repository: repository, executor: toolExecutor,
                classifier: StaticToolReplayClassifier(classifications: ["fixture.read": .readOnly]))
            let stepper = try ManagedProjectRunStepExecutor(repository: repository,
                providerResolver: { _ in
                    XCTFail("Held ingress resolved an ordinary provider")
                    throw AutonomyError.invalidRequest("unexpected provider resolution")
                }, toolDefinitionResolver: { _ in
                    XCTFail("Held ingress prepared ordinary provider tools")
                    return []
                }, broker: broker)
            let coordinator = try ProjectRunCoordinator(runID: fixture.run.runID, repository: repository,
                managerID: "held-coordinator", stepExecutor: stepper,
                completionValidator: EvidenceBoundCompletionValidator())
            do {
                _ = try await coordinator.runActivation()
                XCTFail("Direct coordinator bypassed the persisted bootstrap hold")
            } catch {
                XCTAssertEqual(error as? AutonomyError, .bootstrapRequired(fixture.run.runID))
            }

            let held = fixture.run
            let stale = AutonomousRunRecord(runID: held.runID, projectID: held.projectID,
                projectGeneration: held.projectGeneration, assignmentID: held.assignmentID, mission: held.mission,
                state: .running, continuityMode: held.continuityMode, providerID: held.providerID, modelKey: held.modelKey,
                activeSessionID: nil, activeOperationID: held.activeOperationID, specification: held.specification,
                completionRequestJSON: nil, lastErrorCode: nil, lastErrorSummary: nil, retryAt: nil,
                continuationPending: false, revision: held.revision, createdAt: held.createdAt, updatedAt: held.updatedAt)
            let lease = try await repository.acquireRunLease(runID: held.runID, ownerID: "held-direct-executor")
            let context = ToolInvocationContext(projectID: held.projectID, projectGeneration: held.projectGeneration,
                clientID: ClientID("held-direct-executor"), runID: held.runID,
                authorizationScope: .init(canonicalRoots: [fixture.projectRoot], writableRoots: [],
                    allowedTools: ["context_get", "fs_read"], networkAllowed: false, maximumInlineOutputBytes: 65_536))
            do {
                _ = try await stepper.prepareNextStep(for: stale)
                XCTFail("Stale running snapshot bypassed durable admission during preparation")
            } catch {
                XCTAssertEqual(error as? AutonomyError, .bootstrapRequired(held.runID))
            }
            for kind in [RunSideEffectKind.providerTurn, .continuity] {
                do {
                    _ = try await stepper.execute(RunSideEffectIntent(kind: kind,
                        idempotencyKey: "held-\(kind.rawValue)", payloadSHA256: String(repeating: "a", count: 64),
                        summary: "Stale ordinary execution attempt"), run: stale, context: context, lease: lease)
                    XCTFail("Stale running snapshot dispatched \(kind.rawValue)")
                } catch {
                    XCTAssertEqual(error as? AutonomyError, .bootstrapRequired(held.runID))
                }
            }
            _ = try await repository.releaseRunLease(lease)
            XCTAssertEqual(toolExecutor.callCount, 0)
            let retained = try await repository.autonomousRun(held.runID)
            XCTAssertEqual(retained?.state, .awaitingBootstrap)
            XCTAssertNil(retained?.activeSessionID)
            XCTAssertNil(retained?.specification.work.pendingIntent)
        } catch {
            await repository.close()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        await repository.close()
        try? FileManager.default.removeItem(at: root)
    }

    func testManagedProviderRootToolContinuationAndDeterministicCompletion() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-managed-step-\(UUID().uuidString)", isDirectory: true)
        let repository = try ProjectControlPlaneRepository(
            databaseURL: root.appendingPathComponent("control-plane.sqlite3")
        )
        defer {
            Task { await repository.close() }
            try? FileManager.default.removeItem(at: root)
        }

        let projectID = ProjectID()
        let projectRoot = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectRoot,
            withIntermediateDirectories: true
        )
        _ = try await repository.registerProjectUnchecked(
            projectID: projectID,
            displayName: "Managed Step Fixture",
            canonicalRoot: projectRoot
        )
        let run = try await repository.createAutonomousRun(AutonomousRunRequest(
            projectID: projectID,
            projectGeneration: .initial,
            mission: "Read the fixture and request deterministic completion",
            providerID: "fixture-provider",
            adapterID: "fixture-adapter",
            modelKey: "fixture-model",
            specification: AutonomousRunSpecification(
                allowedTools: ["fixture.read"],
                completionGates: ["tests"]
            ),
            authorizationScope: ToolAuthorizationScope(
                canonicalRoots: [projectRoot],
                allowedTools: ["fixture.read"],
                networkAllowed: false,
                maximumInlineOutputBytes: 64 * 1_024
            )
        ))
        let provider = ManagedStepFixtureProvider()
        let toolExecutor = ManagedStepToolExecutor()
        let broker = ToolInvocationBroker(
            repository: repository,
            executor: toolExecutor,
            classifier: try StaticToolReplayClassifier(
                productionToolNames: toolExecutor.toolNames,
                classifications: ["fixture.read": .readOnly]
            )
        )
        let stepper = try ManagedProjectRunStepExecutor(
            repository: repository,
            providerResolver: { adapterID in
                XCTAssertEqual(adapterID, "fixture-adapter")
                return provider
            },
            toolDefinitionResolver: { allowedTools in
                XCTAssertEqual(allowedTools, ["fixture.read"])
                return [Data(
                    """
                    {"type":"function","name":"fixture.read","description":"Read fixture","parameters":{"type":"object","properties":{},"required":[]},"strict":true}
                    """.utf8
                )]
            },
            broker: broker
        )
        let validator = try GateValidatorRegistry(validators: [CompletionGateValidator(gate: "tests") { candidate in
            let snapshot = await provider.snapshot()
            let invocation = try await repository.toolInvocation(
                sessionID: candidate.activeSessionID ?? "", providerCallID: "call-read"
            )
            return CompletionGateResult(
                gate: "tests",
                passed: invocation?.runID == candidate.runID && invocation?.projectID == candidate.projectID
                    && invocation?.projectGeneration == candidate.projectGeneration && invocation?.state == .completed
                    && toolExecutor.callCount == 1 && snapshot.receivedToolOutput
                    && snapshot.previousResponseID == "resp-root",
                summary: "Assert the actual bound tool execution and provider continuation",
                evidenceReferences: invocation?.resultSHA256.map { [$0] } ?? []
            )
        }])
        let coordinator = try ProjectRunCoordinator(
            runID: run.runID,
            repository: repository,
            managerID: "managed-step-manager",
            stepExecutor: stepper,
            completionValidator: validator,
            maximumSteps: 8
        )

        let result = try await coordinator.runActivation()
        XCTAssertEqual(result.finalState, .completed)
        XCTAssertEqual(toolExecutor.callCount, 1)
        let snapshot = await provider.snapshot()
        XCTAssertEqual(snapshot.rootCalls, 1)
        XCTAssertEqual(snapshot.continuationCalls, 1)
        XCTAssertEqual(snapshot.previousResponseID, "resp-root")
        XCTAssertTrue(snapshot.receivedToolOutput)
        let storedValue = try await repository.autonomousRun(run.runID)
        let stored = try XCTUnwrap(storedValue)
        XCTAssertEqual(stored.state, .completed)
        XCTAssertNotNil(stored.activeSessionID)
        XCTAssertEqual(stored.specification.work.metadata["provider_response_id"], "resp-final")
    }

    func testTemporaryProviderFailurePersistsWaitingStateAndAmbiguousTurn() async throws {
        let result = try await runFailureCase(
            ManagedStepProviderFailure(
                disposition: .waitingProvider,
                code: "fixture_provider_unavailable",
                retryDelay: 17
            )
        )
        XCTAssertEqual(result.run.state, .waitingProvider)
        XCTAssertEqual(result.run.lastErrorCode, "fixture_provider_unavailable")
        XCTAssertNotNil(result.run.retryAt)
        XCTAssertEqual(result.turn.state, .ambiguous)
        XCTAssertEqual(result.turn.lastErrorCode, "fixture_provider_unavailable")
    }

    func testProviderConfigurationFailureBlocksRunAndRetainsExactTurn() async throws {
        let result = try await runFailureCase(
            ManagedStepProviderFailure(
                disposition: .blockedConfiguration,
                code: "fixture_provider_unauthorized"
            )
        )
        XCTAssertEqual(result.run.state, .blockedConfiguration)
        XCTAssertEqual(result.run.lastErrorCode, "fixture_provider_unauthorized")
        XCTAssertNil(result.run.retryAt)
        XCTAssertEqual(result.turn.state, .retryWait)
        XCTAssertEqual(result.turn.lastErrorCode, "fixture_provider_unauthorized")
    }

    func testProviderContextOverflowPersistsObservationAndRequestsRollover() async throws {
        let result = try await runFailureCase(
            ManagedStepProviderFailure(
                disposition: .contextOverflow,
                code: "fixture_context_overflow"
            ),
            persistedBudget: true
        )
        XCTAssertEqual(result.run.state, .rollingOver)
        XCTAssertEqual(result.run.specification.work.metadata["provider_overflow"], "true")
        XCTAssertEqual(
            result.run.specification.work.metadata["provider_overflow_code"],
            "fixture_context_overflow"
        )
        XCTAssertEqual(result.turn.state, .failed)
        XCTAssertEqual(result.observation?.source, .providerOverflow)
        XCTAssertEqual(result.observation?.triggerPoint, .providerOverflow)
        XCTAssertEqual(result.observation?.action, .emergency)
    }

    func testTerminalProviderFailurePersistsTerminalRunAndTurn() async throws {
        let result = try await runFailureCase(
            ManagedStepProviderFailure(
                disposition: .failedTerminal,
                code: "fixture_malformed_response"
            )
        )
        XCTAssertEqual(result.run.state, .failedTerminal)
        XCTAssertEqual(result.run.lastErrorCode, "fixture_malformed_response")
        XCTAssertEqual(result.turn.state, .failed)
        XCTAssertEqual(result.turn.lastErrorCode, "fixture_malformed_response")
    }

    func testInFlightShutdownCancelsProviderAndRetainsDurableRunForRecovery() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-managed-cancel-\(UUID().uuidString)", isDirectory: true)
        let repository = try ProjectControlPlaneRepository(
            databaseURL: root.appendingPathComponent("control-plane.sqlite3")
        )
        defer {
            Task { await repository.close() }
            try? FileManager.default.removeItem(at: root)
        }
        let projectRoot = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let projectID = ProjectID()
        _ = try await repository.registerProjectUnchecked(
            projectID: projectID,
            displayName: "Managed Cancellation Fixture",
            canonicalRoot: projectRoot
        )
        let run = try await repository.createAutonomousRun(AutonomousRunRequest(
            projectID: projectID,
            projectGeneration: .initial,
            mission: "Cancel one in-flight managed provider request",
            providerID: "blocking-provider",
            adapterID: "blocking-adapter",
            modelKey: "blocking-model",
            specification: AutonomousRunSpecification(
                allowedTools: ["fixture.read"],
                completionGates: ["tests"]
            ),
            authorizationScope: ToolAuthorizationScope(
                canonicalRoots: [projectRoot],
                allowedTools: ["fixture.read"],
                networkAllowed: false,
                maximumInlineOutputBytes: 64 * 1_024
            )
        ))
        let provider = ManagedBlockingFixtureProvider()
        let toolExecutor = ManagedStepToolExecutor()
        let broker = ToolInvocationBroker(
            repository: repository,
            executor: toolExecutor,
            classifier: try StaticToolReplayClassifier(
                productionToolNames: toolExecutor.toolNames,
                classifications: ["fixture.read": .readOnly]
            )
        )
        let stepper = try ManagedProjectRunStepExecutor(
            repository: repository,
            providerResolver: { _ in provider },
            toolDefinitionResolver: { _ in [] },
            broker: broker
        )
        let coordinator = try ProjectRunCoordinator(
            runID: run.runID,
            repository: repository,
            managerID: "managed-cancel-manager",
            stepExecutor: stepper,
            completionValidator: EvidenceBoundCompletionValidator(),
            maximumSteps: 8
        )
        let activation = Task { try await coordinator.runActivation() }
        await provider.waitUntilStarted()
        await coordinator.stop()
        let stopped = try await activation.value

        let cancelSnapshot = await provider.snapshot()
        let idempotencyKey = try XCTUnwrap(cancelSnapshot.idempotencyKey)
        let expectedTurnID = managedStepStableUUID("turn:\(idempotencyKey)")
        XCTAssertEqual(cancelSnapshot.cancelRequestIDs, [expectedTurnID.uuidString.lowercased()])
        XCTAssertEqual(stopped.finalState, .running)
        let retainedValue = try await repository.autonomousRun(run.runID)
        XCTAssertEqual(retainedValue?.state, .running)
        XCTAssertNotNil(retainedValue?.specification.work.pendingIntent)
        let turnValue = try await repository.providerTurn(expectedTurnID)
        XCTAssertEqual(turnValue?.state, .ambiguous)
    }

    private func runFailureCase(
        _ failure: ManagedStepProviderFailure,
        persistedBudget: Bool = false
    ) async throws -> ManagedStepFailureResult {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-managed-failure-\(UUID().uuidString)", isDirectory: true)
        let repository = try ProjectControlPlaneRepository(
            databaseURL: root.appendingPathComponent("control-plane.sqlite3")
        )
        defer {
            Task { await repository.close() }
            try? FileManager.default.removeItem(at: root)
        }
        let projectRoot = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let projectID = ProjectID()
        _ = try await repository.registerProjectUnchecked(
            projectID: projectID,
            displayName: "Managed Failure Fixture",
            canonicalRoot: projectRoot
        )
        let run = try await repository.createAutonomousRun(AutonomousRunRequest(
            projectID: projectID,
            projectGeneration: .initial,
            mission: "Exercise typed managed-provider recovery",
            providerID: "failure-provider",
            adapterID: "failure-adapter",
            modelKey: "failure-model",
            specification: AutonomousRunSpecification(
                allowedTools: ["fixture.read"],
                completionGates: ["tests"]
            ),
            authorizationScope: ToolAuthorizationScope(
                canonicalRoots: [projectRoot],
                allowedTools: ["fixture.read"],
                networkAllowed: false,
                maximumInlineOutputBytes: 64 * 1_024
            )
        ))
        let provider = ManagedFailureFixtureProvider(failure: failure)
        let toolExecutor = ManagedStepToolExecutor()
        let broker = ToolInvocationBroker(
            repository: repository,
            executor: toolExecutor,
            classifier: try StaticToolReplayClassifier(
                productionToolNames: toolExecutor.toolNames,
                classifications: ["fixture.read": .readOnly]
            )
        )
        let evaluator: any ManagedRunBudgetEvaluating = persistedBudget
            ? PersistedManagedRunBudgetEvaluator(repository: repository)
            : NoManagedRunBudgetEvaluator()
        let stepper = try ManagedProjectRunStepExecutor(
            repository: repository,
            providerResolver: { _ in provider },
            toolDefinitionResolver: { _ in [] },
            broker: broker,
            budget: evaluator
        )
        let coordinator = try ProjectRunCoordinator(
            runID: run.runID,
            repository: repository,
            managerID: "managed-failure-manager",
            stepExecutor: stepper,
            completionValidator: EvidenceBoundCompletionValidator(),
            maximumSteps: 5
        )
        _ = try await coordinator.runActivation()
        let storedRunValue = try await repository.autonomousRun(run.runID)
        let storedRun = try XCTUnwrap(storedRunValue)
        let providerSnapshot = await provider.snapshot()
        let idempotencyKey = try XCTUnwrap(providerSnapshot.idempotencyKey)
        let turnID = managedStepStableUUID("turn:\(idempotencyKey)")
        let turnValue = try await repository.providerTurn(turnID)
        let turn = try XCTUnwrap(turnValue)
        let observation: ContextBudgetObservation?
        if let sessionID = storedRun.activeSessionID {
            observation = try await repository.latestContextBudgetObservation(
                identity: ContextBudgetIdentity(
                    runID: storedRun.runID,
                    projectID: storedRun.projectID,
                    projectGeneration: storedRun.projectGeneration,
                    sessionID: sessionID
                )
            )
        } else {
            observation = nil
        }
        return ManagedStepFailureResult(run: storedRun, turn: turn, observation: observation)
    }
}

private struct ManagedStepFailureResult {
    let run: AutonomousRunRecord
    let turn: ProviderTurnRecord
    let observation: ContextBudgetObservation?
}

private struct ManagedStepProviderFailure: ManagedProviderFailure, LocalizedError {
    let disposition: ManagedProviderFailureDisposition
    let code: String
    let retryDelay: TimeInterval?

    init(
        disposition: ManagedProviderFailureDisposition,
        code: String,
        retryDelay: TimeInterval? = nil
    ) {
        self.disposition = disposition
        self.code = code
        self.retryDelay = retryDelay
    }

    var managedProviderFailureDisposition: ManagedProviderFailureDisposition { disposition }
    var managedProviderFailureCode: String { code }
    var managedProviderRetryDelay: TimeInterval? { retryDelay }
    var errorDescription: String? { "Fixture managed-provider failure: \(code)" }
}

private actor ManagedFailureFixtureProvider: ManagedModelProvider {
    struct Snapshot: Sendable { let idempotencyKey: String? }

    nonisolated let providerID = "failure-provider"
    private let failure: ManagedStepProviderFailure
    private var idempotencyKey: String?

    init(failure: ManagedStepProviderFailure) { self.failure = failure }

    func probe() async throws -> ProviderCapabilities {
        try ProviderCapabilities(
            providerID: providerID,
            providerVersion: "fixture-1",
            modelKey: "failure-model",
            providerInstanceID: "fixture-instance",
            contextLength: 32_768,
            maximumContextLength: 65_536,
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
        idempotencyKey = request.idempotencyKey
        throw failure
    }

    func continueSession(_ request: ProviderContinuationRequest) async throws -> ProviderTurn {
        idempotencyKey = request.idempotencyKey
        throw failure
    }

    func lookup(idempotencyKey: String) async throws -> ProviderTurn? { nil }
    func cancel(requestID: String) async {}
    func snapshot() -> Snapshot { Snapshot(idempotencyKey: idempotencyKey) }
}

private actor ManagedBlockingFixtureProvider: ManagedModelProvider {
    struct Snapshot: Sendable {
        let idempotencyKey: String?
        let cancelRequestIDs: [String]
    }

    nonisolated let providerID = "blocking-provider"
    private var idempotencyKey: String?
    private var cancelRequestIDs: [String] = []
    private var requestContinuation: CheckedContinuation<ProviderTurn, Error>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var started = false

    func probe() async throws -> ProviderCapabilities {
        try ProviderCapabilities(
            providerID: providerID,
            providerVersion: "fixture-1",
            modelKey: "blocking-model",
            providerInstanceID: "fixture-instance",
            contextLength: 32_768,
            maximumContextLength: 65_536,
            statefulResponses: true,
            streaming: true,
            customTools: true,
            mcp: false,
            structuredOutput: false,
            usageReporting: true,
            idempotencyLookup: true,
            capabilityFingerprintSHA256: String(repeating: "c", count: 64)
        )
    }

    func createRoot(_ request: ProviderRootRequest) async throws -> ProviderTurn {
        idempotencyKey = request.idempotencyKey
        started = true
        let waiters = startWaiters
        startWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
        return try await withCheckedThrowingContinuation { continuation in
            requestContinuation = continuation
        }
    }

    func continueSession(_ request: ProviderContinuationRequest) async throws -> ProviderTurn {
        throw AutonomyError.invalidRequest("blocking fixture does not continue sessions")
    }

    func lookup(idempotencyKey: String) async throws -> ProviderTurn? { nil }

    func cancel(requestID: String) async {
        cancelRequestIDs.append(requestID)
        let continuation = requestContinuation
        requestContinuation = nil
        continuation?.resume(throwing: ManagedStepProviderFailure(
            disposition: .cancelled,
            code: "fixture_cancelled"
        ))
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func snapshot() -> Snapshot {
        Snapshot(idempotencyKey: idempotencyKey, cancelRequestIDs: cancelRequestIDs)
    }
}

private func managedStepStableUUID(_ value: String) -> UUID {
    let digest = JSONSupport.sha256Hex(value)
    return UUID(uuidString:
        "\(digest.prefix(8))-\(digest.dropFirst(8).prefix(4))-\(digest.dropFirst(12).prefix(4))-\(digest.dropFirst(16).prefix(4))-\(digest.dropFirst(20).prefix(12))"
    )!
}

private actor ManagedStepFixtureProvider: ManagedModelProvider {
    struct Snapshot: Sendable {
        let rootCalls: Int
        let continuationCalls: Int
        let previousResponseID: String?
        let receivedToolOutput: Bool
    }

    nonisolated let providerID = "fixture-provider"
    private var rootCalls = 0
    private var continuationCalls = 0
    private var previousResponseID: String?
    private var receivedToolOutput = false
    private var receipts: [String: ProviderTurn] = [:]

    func probe() async throws -> ProviderCapabilities {
        try ProviderCapabilities(
            providerID: providerID,
            providerVersion: "fixture-1",
            modelKey: "fixture-model",
            providerInstanceID: "fixture-instance",
            contextLength: 32_768,
            maximumContextLength: 65_536,
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
        if let existing = receipts[request.idempotencyKey] { return existing }
        rootCalls += 1
        let call = try ProviderToolCall(
            callID: "call-read",
            name: "fixture.read",
            argumentsJSON: Data("{}".utf8)
        )
        let turn = try ProviderTurn(
            requestID: "req-root",
            responseID: "resp-root",
            providerID: providerID,
            providerVersion: "fixture-1",
            modelKey: "fixture-model",
            providerInstanceID: "fixture-instance",
            messages: [],
            toolCalls: [call],
            usage: try ProviderUsage(
                capacity: 32_768,
                inputTokens: 1_000,
                outputTokens: 50,
                source: .providerExact,
                confidence: 1
            ),
            completed: true,
            finishReason: .toolCalls
        )
        receipts[request.idempotencyKey] = turn
        return turn
    }

    func continueSession(_ request: ProviderContinuationRequest) async throws -> ProviderTurn {
        if let existing = receipts[request.idempotencyKey] { return existing }
        continuationCalls += 1
        previousResponseID = request.previousResponseID
        let object = try JSONSerialization.jsonObject(with: request.input) as? [[String: Any]]
        receivedToolOutput = object?.first?["type"] as? String == "function_call_output"
        let output = object?.first?["output"] as? String ?? ""
        let proof = JSONSupport.sha256Hex(output)
        let message = try JSONSupport.canonicalJSON([
            "forge_run_status": "completion_requested",
            "summary": "Fixture work is ready for validation",
            "gate_evidence": ["tests": proof],
        ])
        let turn = try ProviderTurn(
            requestID: "req-final",
            responseID: "resp-final",
            previousResponseID: request.previousResponseID,
            providerID: providerID,
            providerVersion: "fixture-1",
            modelKey: "fixture-model",
            providerInstanceID: "fixture-instance",
            messages: [message],
            toolCalls: [],
            usage: try ProviderUsage(
                capacity: 32_768,
                inputTokens: 1_200,
                outputTokens: 80,
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
            rootCalls: rootCalls,
            continuationCalls: continuationCalls,
            previousResponseID: previousResponseID,
            receivedToolOutput: receivedToolOutput
        )
    }
}

private final class ManagedStepToolExecutor: ToolExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var toolNames: [String] { ["fixture.read"] }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func call(
        name: String,
        arguments: [String: Any],
        clientID: ClientID
    ) throws -> ToolResult {
        execute(name: name)
    }

    func call(
        name: String,
        arguments: [String: Any],
        context: ToolInvocationContext
    ) throws -> ToolResult {
        execute(name: name)
    }

    private func execute(name: String) -> ToolResult {
        lock.lock()
        count += 1
        lock.unlock()
        return .success(["tool": name, "value": "fixture-output"])
    }
}
