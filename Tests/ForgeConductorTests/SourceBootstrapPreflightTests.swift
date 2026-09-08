import XCTest
#if SWIFT_PACKAGE
import ForgeNativeSessionHostPlugin
#endif
@testable import ForgeConductorCore

/// Fixture transports use the production serializer locally; no network API is
/// called. Their execution method validates the same request with this encoder.
enum SourceBootstrapFixtureWire {
    static func root(_ request: LMStudioRootRequest, maximumRequestBytes: Int = 512 * 1_024,
        maximumOutputTokens: Int = 4_096) async throws -> ProviderRequestPreflight {
        let client = try LMStudioRESTClient(configuration: .init(modelKey: request.modelKey,
            maximumRequestBytes: maximumRequestBytes, maximumOutputTokens: maximumOutputTokens))
        return try await client.preflightRoot(request)
    }

    static func continuation(_ request: LMStudioContinuationRequest, maximumRequestBytes: Int = 512 * 1_024,
        maximumOutputTokens: Int = 4_096) async throws -> ProviderRequestPreflight {
        let client = try LMStudioRESTClient(configuration: .init(modelKey: request.modelKey,
            maximumRequestBytes: maximumRequestBytes, maximumOutputTokens: maximumOutputTokens))
        return try await client.preflightContinuation(request)
    }
}

final class SourceBootstrapPreflightTests: XCTestCase {
    func testActualRootAndEscapedAcknowledgementBodiesAreDurablyPinnedBeforeDispatch() async throws {
        try await withFixture { fixture in
            let transport = ExactBootstrapTransport { turnID, actualPreflight in
                let operation = try XCTUnwrap(ContinuityStateEngine(memory: fixture.app.projectMemory).sourceBootstrap(
                    operationID: fixture.acceptance.operationID, authorization: fixture.acceptance.authorization))
                let grant = try await fixture.app.projectContexts.repository.issueContinuityBootstrapGrant(
                    envelope: operation.envelope, candidateID: XCTUnwrap(operation.successorSessionID), lease: fixture.lease)
                let retained = try await fixture.app.projectContexts.repository.sourceDerivedProviderTurnPreflight(
                    turnID: turnID, lease: fixture.lease, bootstrapGrant: grant)
                XCTAssertEqual(try XCTUnwrap(retained).preflight, actualPreflight,
                    "The actual dispatcher must observe the committed request receipt")
                let turn = try await fixture.app.projectContexts.repository.providerTurn(turnID)
                XCTAssertEqual(turn?.state, .submitted)
            }
            let receipt = try await execute(fixture, transport: transport)
            let observed = await transport.snapshot()
            XCTAssertEqual(observed.probes, 2, "Observed dispatch must not perform a hidden second probe")
            XCTAssertEqual(observed.roots.count, 1)
            XCTAssertEqual(observed.followups.count, 1)
            let operation = try XCTUnwrap(ContinuityStateEngine(memory: fixture.app.projectMemory).sourceBootstrap(
                operationID: fixture.acceptance.operationID, authorization: fixture.acceptance.authorization))
            let grant = try await fixture.app.projectContexts.repository.issueContinuityBootstrapGrant(
                envelope: operation.envelope, candidateID: XCTUnwrap(operation.successorSessionID), lease: fixture.lease)
            let root = try XCTUnwrap(observed.roots.first)
            let acknowledgement = try XCTUnwrap(observed.followups.first)
            let rootID = try XCTUnwrap(root.operationID.flatMap(UUID.init(uuidString:)))
            let ackID = try XCTUnwrap(acknowledgement.operationID.flatMap(UUID.init(uuidString:)))
            let rootStored = try await fixture.app.projectContexts.repository.sourceDerivedProviderTurnPreflight(
                turnID: rootID, lease: fixture.lease, bootstrapGrant: grant)
            let ackStored = try await fixture.app.projectContexts.repository.sourceDerivedProviderTurnPreflight(
                turnID: ackID, lease: fixture.lease, bootstrapGrant: grant)
            let expectedRoot = try await SourceBootstrapFixtureWire.root(root)
            let expectedAck = try await SourceBootstrapFixtureWire.continuation(acknowledgement)
            XCTAssertEqual(try XCTUnwrap(rootStored).preflight, expectedRoot)
            XCTAssertEqual(try XCTUnwrap(ackStored).preflight, expectedAck)
            XCTAssertEqual(rootStored?.intent.turnID, rootID)
            XCTAssertEqual(ackStored?.intent.previousResponseID, receipt.rootTurn.responseID)
            XCTAssertGreaterThan(expectedRoot.bodyByteCount, root.userInput.utf8.count)
            XCTAssertGreaterThan(expectedAck.bodyByteCount, receipt.retrieval.outputJSON.count)
            XCTAssertEqual(acknowledgement.input, [.functionCallOutput(callID: "exact-context-call",
                output: String(decoding: receipt.retrieval.outputJSON, as: UTF8.self))])
            XCTAssertEqual(operation.state, .successorAcknowledged)
            XCTAssertNotNil(operation.retrievalProofSHA256)
            XCTAssertNotNil(operation.acknowledgementProofSHA256)
            let run = try await fixture.app.projectContexts.repository.autonomousRun(fixture.acceptance.runID)
            XCTAssertEqual(run?.state, .awaitingBootstrap)
            XCTAssertNil(run?.activeSessionID)
        }
    }

    func testActualSupportedOutputCapControlsAdmissionWithinTightContext() async throws {
        let policy = BudgetPolicy(context: .init(mode: .manual, maxContextTokens: 8_192,
            responseReserveTokens: 1_024, futureToolReserveTokens: 0, handoffReserveTokens: 0,
            recoveryReserveTokens: 0, safetyReserveTokens: 0), automaticHandoffEnabled: true)
        for mode in [ExactBootstrapTransport.Mode.normal, .reducedOutput] {
            try await withFixture(policy: policy) { fixture in
                let transport = ExactBootstrapTransport(mode: mode)
                do {
                    let receipt = try await execute(fixture, transport: transport)
                    XCTAssertEqual(mode, .reducedOutput, "The larger supported cap must exceed this context budget")
                    XCTAssertEqual(receipt.retrieval.sourceIdentity, fixture.acceptance.sourceIdentity)
                } catch {
                    if mode == .reducedOutput { throw error }
                    XCTAssertTrue(error is ContextBudgetError, "Unexpected error: \(error)")
                }
                let observed = await transport.snapshot()
                XCTAssertEqual(observed.roots.count, mode == .reducedOutput ? 1 : 0)
                XCTAssertEqual(observed.followups.count, mode == .reducedOutput ? 1 : 0)
            }
        }
    }

    func testExactEncodedRootAndAcknowledgementLimitsRejectBeforeTheirPost() async throws {
        for mode in [ExactBootstrapTransport.Mode.smallRoot, .smallAcknowledgement] {
            try await withFixture { fixture in
                let transport = ExactBootstrapTransport(mode: mode)
                do { _ = try await execute(fixture, transport: transport); XCTFail("Ignored exact encoded body limit") }
                catch { XCTAssertTrue(error is LMStudioProviderError, "Unexpected error: \(error)") }
                let observed = await transport.snapshot()
                XCTAssertEqual(observed.roots.count, mode == .smallRoot ? 0 : 1)
                XCTAssertEqual(observed.followups.count, 0)
                let operation = try XCTUnwrap(ContinuityStateEngine(memory: fixture.app.projectMemory).sourceBootstrap(
                    operationID: fixture.acceptance.operationID, authorization: fixture.acceptance.authorization))
                XCTAssertNotEqual(operation.state, .successorAcknowledged)
                XCTAssertNil(operation.acknowledgementProofSHA256)
            }
        }
    }

    func testUnknownSubmittedRootAfterAdapterRestartIsLookupOnlyWithoutProbe() async throws {
        try await withFixture { fixture in
            let first = ExactBootstrapTransport(mode: .unknownRoot)
            do { _ = try await execute(fixture, transport: first); XCTFail("Unknown root completed") } catch {}
            let restarted = ExactBootstrapTransport()
            do { _ = try await execute(fixture, transport: restarted); XCTFail("Unknown root was dispatched again") }
            catch { XCTAssertEqual(error as? LMStudioProviderError, .conflict) }
            let firstStats = await first.snapshot()
            let restartedStats = await restarted.snapshot()
            XCTAssertEqual(firstStats.roots.count, 1)
            XCTAssertEqual(restartedStats.probes, 0)
            XCTAssertEqual(restartedStats.roots.count, 0)
            XCTAssertEqual(restartedStats.followups.count, 0)
            let rootID = try XCTUnwrap(firstStats.roots.first?.operationID.flatMap(UUID.init(uuidString:)))
            let retained = try await fixture.app.projectContexts.repository.providerTurn(rootID)
            XCTAssertEqual(retained?.state, .submitted)
        }
    }

    private func execute(_ fixture: ExactBootstrapFixture, transport: ExactBootstrapTransport)
        async throws -> SourceBootstrapReceipt {
        let adapter = try LMStudioManagedSessionHostAdapterV2(
            storageDirectory: fixture.app.paths.home.appendingPathComponent("exact-bootstrap-provider"), transport: transport)
        let worker = ManagedContinuityWorker(repository: fixture.app.projectContexts.repository,
            memory: fixture.app.projectMemory, adapterResolver: { _ in adapter })
        let broker = try ToolInvocationBroker(repository: fixture.app.projectContexts.repository,
            executor: fixture.app.tools,
            classifier: ProductionToolReplayCatalog.classifier(productionToolNames: fixture.app.tools.toolNames))
        return try await worker.executeSourceBootstrap(acceptance: fixture.acceptance, lease: fixture.lease,
            broker: broker, continuity: fixture.app.continuity,
            policyResolver: { try fixture.app.config.budgetPolicySelection(scope: $0) })
    }

    private func withFixture(policy: BudgetPolicy = BudgetPolicy(automaticHandoffEnabled: true),
        _ body: (ExactBootstrapFixture) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bootstrap-preflight-\(UUID().uuidString)")
            .resolvingSymlinksInPath().standardizedFileURL
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let app = try ForgeApp.bootstrap(home: root.appendingPathComponent("home"))
        defer { _ = app.shutdown(); try? FileManager.default.removeItem(at: root) }
        let prior = try app.config.budgetPolicySelection(scope: .globalDefault)
        _ = try app.config.updateBudgetPolicy(.init(scope: .globalDefault, expectedRevision: prior.revision,
            expectedGlobalRevision: prior.globalRevision, operation: .set,
            policy: policy))
        let initialized = try app.projectMemory.initializeUnchecked(path: project.path)
        let projectID = ProjectID(try XCTUnwrap((initialized["project_id"] as? String).flatMap(UUID.init(uuidString:))))
        let repository = app.projectContexts.repository
        _ = try await repository.registerProjectUnchecked(projectID: projectID, displayName: "Exact bootstrap", canonicalRoot: project)
        let client = ClientID("exact-bootstrap-transport")
        let owner = ProjectBindingOwner(kind: .mcpClient, id: client.rawValue)
        let scope = ToolAuthorizationScope(canonicalRoots: [project], writableRoots: [],
            allowedTools: ["context_get"], networkAllowed: false, maximumInlineOutputBytes: 65_536)
        let binding = try await repository.bind(owner: owner, projectID: projectID, generation: .initial, authorizationScope: scope)
        let assignment = try ContinuityTaskAssignment(assignmentID: "exact-bootstrap-assignment",
            assignmentBytes: Data("Approved exact bootstrap fixture".utf8), mission: "Restore the approved task",
            providerID: "lmstudio", adapterID: "forge.native-session-host", modelKey: "fixture/exact-bootstrap",
            specification: .init(allowedTools: ["context_get"], completionGates: ["restored"]), authorizationScope: scope)
        let setup = try await repository.authorizeContinuityTask(projectID: projectID, expectedGeneration: .initial,
            approvedAssignment: assignment, callerContext: binding.invocationContext(clientID: client), callerOwner: owner)
        let committed = try app.store.handoffCommit(.init(id: "exact-bootstrap-source", createdAt: "2026-09-08T10:00:00Z",
            updatedAt: "2026-09-08T10:00:00Z", source: .model, resumeReady: true,
            goal: "Retain the exact escaped output: \"quote\" \\ path\nnext line"),
            authorization: setup.record.authorization, automaticHandoffEnabled: true)
        let policy = try app.config.budgetPolicySelection(scope: .init(kind: .projectOverride,
            projectID: projectID.description, projectGeneration: 1))
        let acceptance = try await repository.acceptContinuityIngress(source: committed.revision,
            operationID: XCTUnwrap(committed.delivery?.operationID), policySelection: policy)
        let lease = try await repository.acquireRunLease(runID: acceptance.runID, ownerID: "exact-bootstrap-owner")
        try await body(.init(app: app, acceptance: acceptance, lease: lease))
    }
}

private struct ExactBootstrapFixture: Sendable {
    let app: ForgeApp
    let acceptance: ContinuityIngressAcceptanceReceipt
    let lease: RunLease
}

private actor ExactBootstrapTransport: LMStudioManagedTransportObservedDispatching {
    enum Mode: Sendable { case normal, reducedOutput, smallRoot, smallAcknowledgement, unknownRoot }
    private let mode: Mode
    private var probes = 0
    private var roots: [LMStudioRootRequest] = []
    private var followups: [LMStudioContinuationRequest] = []
    private let beforeDispatch: (@Sendable (UUID, ProviderRequestPreflight) async throws -> Void)?
    init(mode: Mode = .normal,
        beforeDispatch: (@Sendable (UUID, ProviderRequestPreflight) async throws -> Void)? = nil) {
        self.mode = mode
        self.beforeDispatch = beforeDispatch
    }

    func probe() async throws -> LMStudioProviderCapabilities {
        probes += 1
        return .init(modelKey: "fixture/exact-bootstrap", loadedInstanceID: "fixture/exact-bootstrap@32768",
            contextLength: 32_768, maximumContextLength: 131_072, parallelism: 1, flashAttention: true,
            trainedForToolUse: true, streamingVerified: true, functionToolContractVerified: true,
            usageReportingVerified: true, capabilityFingerprintSHA256: String(repeating: "a", count: 64),
            contractProbeResponseID: "exact-bootstrap-probe")
    }
    func createRoot(_ request: LMStudioRootRequest, observedFingerprint: String) async throws -> LMStudioResponseTurn {
        guard observedFingerprint == String(repeating: "a", count: 64) else {
            throw ManagedModelProviderContractError.invalidValue("fixture observation differs")
        }
        return try await createRoot(request)
    }
    func continueSession(_ request: LMStudioContinuationRequest, observedFingerprint: String) async throws -> LMStudioResponseTurn {
        guard observedFingerprint == String(repeating: "a", count: 64) else {
            throw ManagedModelProviderContractError.invalidValue("fixture observation differs")
        }
        return try await continueSession(request)
    }
    func preflightRoot(_ request: LMStudioRootRequest) async throws -> ProviderRequestPreflight {
        try await SourceBootstrapFixtureWire.root(request,
            maximumRequestBytes: mode == .smallRoot ? 1_024 : 512 * 1_024,
            maximumOutputTokens: mode == .reducedOutput ? 1_024 : 4_096)
    }
    func preflightContinuation(_ request: LMStudioContinuationRequest) async throws -> ProviderRequestPreflight {
        try await SourceBootstrapFixtureWire.continuation(request,
            maximumRequestBytes: mode == .smallAcknowledgement ? 1_024 : 512 * 1_024,
            maximumOutputTokens: mode == .reducedOutput ? 1_024 : 4_096)
    }
    func createRoot(_ request: LMStudioRootRequest) async throws -> LMStudioResponseTurn {
        let preflight = try await preflightRoot(request)
        if let beforeDispatch {
            try await beforeDispatch(XCTUnwrap(request.operationID.flatMap(UUID.init(uuidString:))), preflight)
        }
        roots.append(request)
        if mode == .unknownRoot { throw LMStudioProviderError.deadlineExceeded(phase: "total") }
        let identity = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(request.userInput.utf8)) as? [String: Any])
        let sourceID = try XCTUnwrap(identity["continuity_id"] as? String)
        return try turn(responseID: "exact-root-response", parent: nil, callID: "exact-context-call",
            name: "context_get", arguments: ["handoff_id": sourceID])
    }
    func continueSession(_ request: LMStudioContinuationRequest) async throws -> LMStudioResponseTurn {
        let preflight = try await preflightContinuation(request)
        if let beforeDispatch {
            try await beforeDispatch(XCTUnwrap(request.operationID.flatMap(UUID.init(uuidString:))), preflight)
        }
        followups.append(request)
        let tool = try XCTUnwrap(request.tools.first)
        let definition = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(tool)) as? [String: Any])
        let parameters = try XCTUnwrap(definition["parameters"] as? [String: Any])
        let properties = try XCTUnwrap(parameters["properties"] as? [String: [String: Any]])
        var arguments: [String: Any] = [:]
        for (key, property) in properties { arguments[key] = try XCTUnwrap(property["const"]) }
        return try turn(responseID: "exact-ack-response", parent: request.previousResponseID,
            callID: "exact-ack-call", name: "forge_continuity_ack", arguments: arguments)
    }
    private func turn(responseID: String, parent: String?, callID: String, name: String,
        arguments: [String: Any]) throws -> LMStudioResponseTurn {
        .init(responseID: responseID, previousResponseID: parent, model: "fixture/exact-bootstrap", status: "completed",
            assistantText: "", functionCalls: [.init(itemID: "item-" + callID, callID: callID, name: name,
                arguments: String(decoding: try ForgeJSONCanonicalizationV1.data(from: arguments), as: UTF8.self))],
            usage: .init(inputTokens: parent == nil ? 600 : 1_200, outputTokens: 80, totalTokens: parent == nil ? 680 : 1_280))
    }
    func receipt(forIdempotencyKey key: String) async -> LMStudioResponseTurn? { nil }
    func cancel(operationID: String) async {}
    func snapshot() -> (probes: Int, roots: [LMStudioRootRequest], followups: [LMStudioContinuationRequest]) {
        (probes, roots, followups)
    }
}
