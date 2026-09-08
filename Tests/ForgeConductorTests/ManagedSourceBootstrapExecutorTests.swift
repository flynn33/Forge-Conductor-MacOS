// Worker-to-native-adapter integration with real manager, broker and source stores.

import XCTest
import SQLite3
#if SWIFT_PACKAGE
import ForgeNativeSessionHostPlugin
#endif
@testable import ForgeConductorCore

final class ManagedSourceBootstrapExecutorTests: XCTestCase {
    func testWorkerNativeAdapterAndBrokerAcknowledgeTheExactCommittedSourceWhileHeld() async throws {
        try await withFixture { fixture in
            let transport = ManagedSourceFixtureTransport()
            var compatibility = try XCTUnwrap(fixture.app.store.handoffGet(id: fixture.acceptance.sourceIdentity.continuityID))
            compatibility.goal = "Changed compatibility latest value"
            try fixture.app.store.handoffUpsert(compatibility)
            let receipt = try await execute(app: fixture.app, acceptance: fixture.acceptance,
                lease: fixture.lease, transport: transport)
            let observed = await transport.snapshot()
            XCTAssertEqual(observed.roots.count, 1)
            XCTAssertEqual(observed.followups.count, 1)
            XCTAssertFalse(try XCTUnwrap(observed.roots.first).userInput.contains("Approved task progress"))
            let output = try XCTUnwrap(observed.followups.first?.input.first)
            XCTAssertEqual(output, .functionCallOutput(callID: "integration-context-call",
                output: String(decoding: receipt.retrieval.outputJSON, as: UTF8.self)))
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: receipt.retrieval.outputJSON) as? [String: Any])
            let packet = try XCTUnwrap(payload["packet"] as? [String: Any])
            XCTAssertEqual(try ForgeJSONCanonicalizationV1.data(from: packet), fixture.acceptance.source.canonicalPacketJSON)
            XCTAssertEqual(try XCTUnwrap(HandoffPacket.fromDictionary(packet)).goal,
                "Approved task progress: https://example.invalid/exact-source")
            XCTAssertEqual(receipt.retrieval.sourceIdentity, fixture.acceptance.sourceIdentity)
            XCTAssertEqual(try ManagedSourceSQLite.integer(fixture.app.paths.controlPlaneSQLite,
                "SELECT COUNT(*) FROM continuity_bootstrap_retrieval_proofs"), 1)
            XCTAssertEqual(try ManagedSourceSQLite.integer(fixture.app.paths.controlPlaneSQLite,
                "SELECT COUNT(*) FROM tool_invocations WHERE tool_name='context_get' AND state='completed'"), 1)
            let operation = try XCTUnwrap(ContinuityStateEngine(memory: fixture.app.projectMemory).sourceBootstrap(
                operationID: fixture.acceptance.operationID, authorization: fixture.acceptance.authorization))
            XCTAssertEqual(operation.state, .successorAcknowledged)
            XCTAssertEqual(operation.retrievalProofSHA256, receipt.retrieval.proofSHA256)
            XCTAssertEqual(operation.successorProviderResponseID, receipt.acknowledgementTurn.responseID)
            try await assertHeld(app: fixture.app, acceptance: fixture.acceptance)
        }
    }

    func testExplicitPermitBootstrapsWithAutomaticPolicyDisabledAndRetainsCapacityChecks() async throws {
        for smallCapacity in [false, true] {
            try await withFixture(explicit: true) { fixture in
                try setPolicy(app: fixture.app, enabled: false)
                let transport = ManagedSourceFixtureTransport(mode: smallCapacity ? .smallCapacity : .normal)
                do {
                    let receipt = try await execute(app: fixture.app, acceptance: fixture.acceptance,
                        lease: fixture.lease, transport: transport)
                    XCTAssertFalse(smallCapacity, "Explicit permission bypassed the actual model capacity")
                    XCTAssertEqual(receipt.retrieval.sourceIdentity, fixture.acceptance.sourceIdentity)
                } catch {
                    if !smallCapacity { throw error }
                }
                let observed = await transport.snapshot()
                XCTAssertEqual(observed.roots.count, smallCapacity ? 0 : 1)
                XCTAssertEqual(observed.followups.count, smallCapacity ? 0 : 1)
                XCTAssertFalse(try fixture.app.config.budgetPolicySelection(scope: .globalDefault).policy.automaticHandoffEnabled)
                try await assertHeld(app: fixture.app, acceptance: fixture.acceptance)
            }
        }
    }

    func testAcknowledgementCrashReopensWithSameCandidateNonceAndNoSecondProviderExchange() async throws {
        try await withFixture { fixture in
            let firstTransport = ManagedSourceFixtureTransport()
            do {
                _ = try await execute(app: fixture.app, acceptance: fixture.acceptance, lease: fixture.lease,
                    transport: firstTransport, crashAfter: .acknowledgementPersistence)
                XCTFail("Expected crash after durable acknowledgment")
            } catch let error as ManagedContinuityWorkerError {
                guard case .injectedCrash(.acknowledgementPersistence) = error else { return XCTFail("Unexpected crash: \(error)") }
            }
            let before = try XCTUnwrap(ContinuityStateEngine(memory: fixture.app.projectMemory).sourceBootstrap(
                operationID: fixture.acceptance.operationID, authorization: fixture.acceptance.authorization))
            XCTAssertEqual(before.state, .successorAcknowledged)
            let firstStats = await firstTransport.snapshot()
            XCTAssertEqual(firstStats.roots.count, 1)
            XCTAssertEqual(firstStats.followups.count, 1)
            _ = try await fixture.app.projectContexts.repository.releaseRunLease(fixture.lease)
            XCTAssertTrue(fixture.app.shutdown().completed)
            let reopened = try ForgeApp.bootstrap(home: fixture.app.paths.home)
            defer { _ = reopened.shutdown() }
            let lease = try await reopened.projectContexts.repository.acquireRunLease(runID: fixture.acceptance.runID,
                ownerID: "restarted-bootstrap-owner")
            let secondTransport = ManagedSourceFixtureTransport()
            let receipt = try await execute(app: reopened, acceptance: fixture.acceptance, lease: lease, transport: secondTransport)
            let secondStats = await secondTransport.snapshot()
            XCTAssertEqual(secondStats.roots.count, 0)
            XCTAssertEqual(secondStats.followups.count, 0)
            let after = try XCTUnwrap(ContinuityStateEngine(memory: reopened.projectMemory).sourceBootstrap(
                operationID: fixture.acceptance.operationID, authorization: fixture.acceptance.authorization))
            XCTAssertEqual(after, before)
            XCTAssertEqual(receipt.retrieval.candidateID, before.successorSessionID)
            XCTAssertEqual(receipt.retrieval.bootstrapNonce, before.bootstrapNonce)
            XCTAssertEqual(receipt.retrieval.proofSHA256, before.retrievalProofSHA256)
            XCTAssertEqual(try ManagedSourceSQLite.integer(reopened.paths.controlPlaneSQLite,
                "SELECT COUNT(*) FROM provider_turns"), 2)
            XCTAssertEqual(try ManagedSourceSQLite.integer(reopened.paths.controlPlaneSQLite,
                "SELECT COUNT(*) FROM continuity_bootstrap_retrieval_proofs"), 1)
            try await assertHeld(app: reopened, acceptance: fixture.acceptance)
        }
    }

    func testWrongAcknowledgementDisabledPolicyAndSmallActualCapacityRemainHeld() async throws {
        for scenario in [ManagedSourceFixtureTransport.Mode.wrongAcknowledgement, .disabledPolicy, .smallCapacity] {
            try await withFixture { fixture in
                if scenario == .disabledPolicy { try setPolicy(app: fixture.app, enabled: false) }
                let transport = ManagedSourceFixtureTransport(mode: scenario)
                do {
                    _ = try await execute(app: fixture.app, acceptance: fixture.acceptance,
                        lease: fixture.lease, transport: transport)
                    XCTFail("Unexpected source acknowledgment: \(scenario)")
                } catch { }
                let observed = await transport.snapshot()
                XCTAssertEqual(observed.roots.count, scenario == .wrongAcknowledgement ? 1 : 0)
                XCTAssertEqual(observed.followups.count, scenario == .wrongAcknowledgement ? 1 : 0)
                let operation = try XCTUnwrap(ContinuityStateEngine(memory: fixture.app.projectMemory).sourceBootstrap(
                    operationID: fixture.acceptance.operationID, authorization: fixture.acceptance.authorization))
                XCTAssertNotEqual(operation.state, .successorAcknowledged)
                XCTAssertNil(operation.acknowledgementProofSHA256)
                XCTAssertEqual(try ManagedSourceSQLite.integer(fixture.app.paths.controlPlaneSQLite,
                    "SELECT COUNT(*) FROM continuity_bootstrap_retrieval_proofs"), scenario == .wrongAcknowledgement ? 1 : 0)
                try await assertHeld(app: fixture.app, acceptance: fixture.acceptance)
            }
        }
    }

    func testKnownExactRecoveryLimitsRejectBeforeAnyProviderRoot() async throws {
        for (tools, reason) in [
            (BudgetToolPolicy(maxResultBytes: 1), "current bootstrap result-byte budget"),
            (BudgetToolPolicy(maxRetainedResultTokens: 1), "current bootstrap retained-result token budget"),
        ] {
            try await withFixture { fixture in
                let prior = try fixture.app.config.budgetPolicySelection(scope: .globalDefault)
                _ = try fixture.app.config.updateBudgetPolicy(.init(scope: .globalDefault,
                    expectedRevision: prior.revision, expectedGlobalRevision: prior.globalRevision,
                    operation: .set, policy: BudgetPolicy(tools: tools, automaticHandoffEnabled: true)))
                let transport = ManagedSourceFixtureTransport()
                do {
                    _ = try await execute(app: fixture.app, acceptance: fixture.acceptance,
                        lease: fixture.lease, transport: transport)
                    XCTFail("Known exact restoration limits must reject before remote creation")
                } catch { XCTAssertEqual(error as? ContinuityIngressError, .capacityExceeded(reason)) }
                let observed = await transport.snapshot()
                XCTAssertEqual(observed.roots.count, 0)
                XCTAssertEqual(observed.followups.count, 0)
                XCTAssertEqual(try ManagedSourceSQLite.integer(fixture.app.paths.controlPlaneSQLite,
                    "SELECT COUNT(*) FROM tool_invocations"), 0)
                XCTAssertEqual(try ManagedSourceSQLite.integer(fixture.app.paths.controlPlaneSQLite,
                    "SELECT COUNT(*) FROM continuity_bootstrap_retrieval_proofs"), 0)
                let retained = try fixture.app.store.continuityHandoffRevision(identity: fixture.acceptance.sourceIdentity,
                    authorization: fixture.acceptance.authorization)
                XCTAssertEqual(retained.canonicalPacketJSON, fixture.acceptance.source.canonicalPacketJSON)
                try await assertHeld(app: fixture.app, acceptance: fixture.acceptance)
            }
        }
    }

    func testRuntimeAutomaticallyRecoversHeldSourceAndRestartDoesNotRedispatchAcknowledgedWork() async throws {
        try await withFixture { fixture in
            _ = try await fixture.app.projectContexts.repository.releaseRunLease(fixture.lease)
            let transport = ManagedSourceFixtureTransport()
            let runtime = try ManagedAutonomyRuntime(app: fixture.app,
                registry: sourceRegistry(transport: transport), maximumConcurrentRuns: 1)
            do {
                let report = try await runtime.start()
                XCTAssertTrue(report.activatedRuns.contains(fixture.acceptance.runID))
                try await waitForAcknowledgedRecovery(app: fixture.app)
                let observed = await transport.snapshot()
                XCTAssertEqual(observed.roots.count, 1)
                XCTAssertEqual(observed.followups.count, 1)
                XCTAssertEqual(try ManagedSourceSQLite.integer(fixture.app.paths.controlPlaneSQLite,
                    "SELECT recovery_attempts FROM continuity_ingress_holds"), 1)
                try await assertHeld(app: fixture.app, acceptance: fixture.acceptance)
                await runtime.shutdown()
            } catch { await runtime.shutdown(); throw error }

            XCTAssertTrue(fixture.app.shutdown().completed)
            let reopened = try ForgeApp.bootstrap(home: fixture.app.paths.home)
            defer { _ = reopened.shutdown() }
            let restartedTransport = ManagedSourceFixtureTransport()
            let restarted = try ManagedAutonomyRuntime(app: reopened,
                registry: sourceRegistry(transport: restartedTransport), maximumConcurrentRuns: 1)
            do {
                let report = try await restarted.start()
                XCTAssertTrue(report.activatedRuns.contains(fixture.acceptance.runID))
                let activated = try await waitForSourceActivation(app: reopened, runID: fixture.acceptance.runID)
                XCTAssertNotNil(activated.activeSessionID)
                let observed = await restartedTransport.snapshot()
                XCTAssertEqual(observed.roots.count, 0)
                XCTAssertEqual(observed.followups.count, 0)
                XCTAssertEqual(try ManagedSourceSQLite.integer(reopened.paths.controlPlaneSQLite,
                    "SELECT recovery_attempts FROM continuity_ingress_holds"), 1)
                let candidates = try await reopened.projectContexts.repository.providerSessions(operationID: fixture.acceptance.operationID)
                XCTAssertEqual(candidates.filter { $0.accepted && $0.status == .active }.count, 1)
                XCTAssertEqual(candidates.first?.sessionID, activated.activeSessionID)
                await restarted.shutdown()
            } catch { await restarted.shutdown(); throw error }
        }
    }

    func testRuntimeRechecksAutomaticPolicyWithoutConsumingDisabledAttempts() async throws {
        try await withFixture { fixture in
            _ = try await fixture.app.projectContexts.repository.releaseRunLease(fixture.lease)
            try setPolicy(app: fixture.app, enabled: false)
            let transport = ManagedSourceFixtureTransport()
            let runtime = try ManagedAutonomyRuntime(app: fixture.app,
                registry: sourceRegistry(transport: transport), maximumConcurrentRuns: 1)
            do {
                let report = try await runtime.start()
                XCTAssertFalse(report.activatedRuns.contains(fixture.acceptance.runID))
                for _ in 0..<3 { try await runtime.tick() }
                let before = await transport.snapshot()
                XCTAssertEqual(before.roots.count, 0)
                XCTAssertEqual(try ManagedSourceSQLite.integer(fixture.app.paths.controlPlaneSQLite,
                    "SELECT recovery_attempts FROM continuity_ingress_holds"), 0)
                try setPolicy(app: fixture.app, enabled: true)
                try await runtime.tick()
                try await waitForAcknowledgedRecovery(app: fixture.app)
                let after = await transport.snapshot()
                XCTAssertEqual(after.roots.count, 1)
                XCTAssertEqual(after.followups.count, 1)
                try await assertHeld(app: fixture.app, acceptance: fixture.acceptance)
                await runtime.shutdown()
            } catch { await runtime.shutdown(); throw error }
        }
    }

    func testRuntimeCancelStopsTheOwnedBootstrapAndCannotRediscoverIt() async throws {
        try await withFixture { fixture in
            _ = try await fixture.app.projectContexts.repository.releaseRunLease(fixture.lease)
            let transport = ManagedSourceFixtureTransport(rootDelay: .seconds(30))
            let runtime = try ManagedAutonomyRuntime(app: fixture.app,
                registry: sourceRegistry(transport: transport), maximumConcurrentRuns: 1)
            do {
                _ = try await runtime.start()
                var rootStarted = false
                for _ in 0..<400 {
                    if await transport.snapshot().roots.count == 1 { rootStarted = true; break }
                    try await Task.sleep(for: .milliseconds(25))
                }
                XCTAssertTrue(rootStarted, "The actual registered adapter must enter the provider root")
                _ = try await runtime.controlRun(fixture.acceptance.runID, action: .cancel)
                var cancelled = false
                for _ in 0..<400 {
                    if try await fixture.app.projectContexts.repository.autonomousRun(fixture.acceptance.runID)?.state == .cancelled {
                        cancelled = true; break
                    }
                    try await Task.sleep(for: .milliseconds(25))
                }
                XCTAssertTrue(cancelled)
                for _ in 0..<3 { try await runtime.tick() }
                let observed = await transport.snapshot()
                XCTAssertEqual(observed.roots.count, 1)
                XCTAssertEqual(observed.followups.count, 0)
                let cancellationCount = await transport.cancellationCount()
                XCTAssertGreaterThan(cancellationCount, 0)
                XCTAssertEqual(try ManagedSourceSQLite.integer(fixture.app.paths.controlPlaneSQLite,
                    "SELECT COUNT(*) FROM continuity_ingress_holds WHERE recovery_ack_sha256 IS NOT NULL"), 0)
                let candidates = try await fixture.app.projectContexts.repository.providerSessions(operationID: fixture.acceptance.operationID)
                XCTAssertTrue(candidates.allSatisfy { !$0.accepted })
                await runtime.shutdown()
            } catch { await runtime.shutdown(); throw error }
        }
    }

    private func sourceRegistry(transport: ManagedSourceFixtureTransport) -> HostAdapterRegistry {
        let registry = HostAdapterRegistry()
        registry.register(manifest: ForgeNativeSessionHostPlugin.manifest,
            managedProviderFactory: { directory in
                try LMStudioManagedModelProvider(storageDirectory: directory, transport: transport)
            },
            factory: { directory in
                try LMStudioManagedSessionHostAdapter(storageDirectory: directory, transport: transport)
            })
        return registry
    }

    private func waitForAcknowledgedRecovery(app: ForgeApp) async throws {
        for _ in 0..<400 {
            if try ManagedSourceSQLite.integer(app.paths.controlPlaneSQLite,
                "SELECT COUNT(*) FROM continuity_ingress_holds WHERE recovery_ack_sha256 IS NOT NULL") == 1 { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("The actual manager did not durably verify the canonical source acknowledgment")
        throw ContinuityIngressError.integrityFailure("source recovery deadline")
    }

    private func waitForSourceActivation(app: ForgeApp, runID: RunID) async throws -> AutonomousRunRecord {
        for _ in 0..<400 {
            do {
                let run = try await app.projectContexts.repository.validateAutonomousRunExecutionAdmission(runID)
                if run.activeSessionID != nil { return run }
            } catch let error as AutonomyError {
                guard error == .bootstrapRequired(runID) else { throw error }
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("The restarted manager did not activate the acknowledged source")
        throw ContinuityIngressError.integrityFailure("source activation deadline")
    }

    private func execute(app: ForgeApp, acceptance: ContinuityIngressAcceptanceReceipt, lease: RunLease,
                         transport: ManagedSourceFixtureTransport,
                         crashAfter: ManagedContinuityCrashPoint? = nil) async throws -> SourceBootstrapReceipt {
        let adapter = try LMStudioManagedSessionHostAdapterV2(
            storageDirectory: app.paths.home.appendingPathComponent("bootstrap-provider"), transport: transport)
        let worker = ManagedContinuityWorker(repository: app.projectContexts.repository, memory: app.projectMemory,
            adapterResolver: { _ in adapter }, crashAfter: crashAfter)
        let broker = try ToolInvocationBroker(repository: app.projectContexts.repository, executor: app.tools,
            classifier: ProductionToolReplayCatalog.classifier(productionToolNames: app.tools.toolNames))
        return try await worker.executeSourceBootstrap(acceptance: acceptance, lease: lease,
            broker: broker, continuity: app.continuity,
            policyResolver: { scope in try app.config.budgetPolicySelection(scope: scope) })
    }

    private func assertHeld(app: ForgeApp, acceptance: ContinuityIngressAcceptanceReceipt) async throws {
        let run = try await app.projectContexts.repository.autonomousRun(acceptance.runID)
        XCTAssertEqual(run?.state, .awaitingBootstrap)
        XCTAssertNil(run?.activeSessionID)
        let candidates = try await app.projectContexts.repository.providerSessions(operationID: acceptance.operationID)
        XCTAssertTrue(candidates.allSatisfy { $0.status == .candidate && !$0.accepted })
        do {
            _ = try await app.projectContexts.repository.validateAutonomousRunExecutionAdmission(acceptance.runID)
            XCTFail("Bootstrap acknowledgment released the execution hold")
        } catch { XCTAssertEqual(error as? AutonomyError, .bootstrapRequired(acceptance.runID)) }
        XCTAssertEqual(try ManagedSourceSQLite.integer(app.paths.controlPlaneSQLite,
            "SELECT COUNT(*) FROM project_bindings WHERE owner_kind='provider_session' AND active=1"), 0)
        XCTAssertEqual(try ManagedSourceSQLite.integer(app.paths.controlPlaneSQLite,
            "SELECT COUNT(*) FROM context_budget_observations"), 0, "No predecessor measurement may be fabricated")
    }

    private func setPolicy(app: ForgeApp, enabled: Bool) throws {
        let prior = try app.config.budgetPolicySelection(scope: .globalDefault)
        _ = try app.config.updateBudgetPolicy(.init(scope: .globalDefault, expectedRevision: prior.revision,
            expectedGlobalRevision: prior.globalRevision, operation: .set,
            policy: BudgetPolicy(automaticHandoffEnabled: enabled)))
    }

    private func withFixture(explicit: Bool = false,
                             _ body: (ManagedSourceIntegrationFixture) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("managed-source-bootstrap-\(UUID().uuidString)")
            .resolvingSymlinksInPath().standardizedFileURL
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let app = try ForgeApp.bootstrap(home: root.appendingPathComponent("home"))
        defer { _ = app.shutdown(); try? FileManager.default.removeItem(at: root) }
        try setPolicy(app: app, enabled: true)
        let initialized = try app.projectMemory.initializeUnchecked(path: project.path)
        let projectID = ProjectID(try XCTUnwrap((initialized["project_id"] as? String).flatMap(UUID.init(uuidString:))))
        let repository = app.projectContexts.repository
        _ = try await repository.registerProjectUnchecked(projectID: projectID, displayName: "Source integration", canonicalRoot: project)
        let client = ClientID("integration-transport")
        let owner = ProjectBindingOwner(kind: .mcpClient, id: client.rawValue)
        let scope = ToolAuthorizationScope(canonicalRoots: [project], writableRoots: [],
            allowedTools: ["context_get"], networkAllowed: false, maximumInlineOutputBytes: 65_536)
        let binding = try await repository.bind(owner: owner, projectID: projectID, generation: .initial, authorizationScope: scope)
        let assignment = try ContinuityTaskAssignment(assignmentID: "approved-integration-task",
            assignmentBytes: Data("Native approved task document".utf8), mission: "Continue the exact approved task",
            providerID: "lmstudio", adapterID: "forge.native-session-host", modelKey: "fixture/integration-model",
            specification: AutonomousRunSpecification(allowedTools: ["context_get"], completionGates: ["integration"]),
            authorizationScope: scope)
        let setup = try await repository.authorizeContinuityTask(projectID: projectID, expectedGeneration: .initial,
            approvedAssignment: assignment, callerContext: binding.invocationContext(clientID: client), callerOwner: owner)
        let committed = try app.store.handoffCommit(HandoffPacket(id: "integration-exact-source",
            createdAt: "2026-09-08T10:00:00Z", updatedAt: "2026-09-08T10:00:00Z", source: .model,
            resumeReady: true, goal: "Approved task progress: https://example.invalid/exact-source"),
            authorization: setup.record.authorization, automaticHandoffEnabled: true)
        let policy = try app.config.budgetPolicySelection(scope: BudgetPolicyScope(kind: .projectOverride,
            projectID: projectID.description, projectGeneration: 1))
        let acceptance = try await repository.acceptContinuityIngress(source: committed.revision,
            operationID: XCTUnwrap(committed.delivery?.operationID), policySelection: policy)
        if explicit {
            _ = try await repository.submitExplicitContinuityIngress(taskID: setup.record.authorization.taskID,
                correlation: setup.correlation, context: binding.invocationContext(clientID: client), owner: owner,
                requestID: UUID(), continuityID: committed.revision.identity.continuityID, policySelection: policy) { _ in
                    committed.revision
                }
        }
        let lease = try await repository.acquireRunLease(runID: acceptance.runID, ownerID: "source-integration-owner")
        try await body(ManagedSourceIntegrationFixture(app: app, acceptance: acceptance, lease: lease))
    }
}

private struct ManagedSourceIntegrationFixture: Sendable {
    let app: ForgeApp
    let acceptance: ContinuityIngressAcceptanceReceipt
    let lease: RunLease
}

/// Only the transport is replaced. The native request ledger, normalized driver,
/// Core executor, broker, immutable source resolver and canonical journal are real.
private actor ManagedSourceFixtureTransport: LMStudioManagedTransportObservedDispatching {
    enum Mode: Sendable { case normal, wrongAcknowledgement, disabledPolicy, smallCapacity }
    private let mode: Mode
    private let rootDelay: Duration?
    private var cancellations = 0
    private var roots: [LMStudioRootRequest] = []
    private var followups: [LMStudioContinuationRequest] = []
    init(mode: Mode = .normal, rootDelay: Duration? = nil) { self.mode = mode; self.rootDelay = rootDelay }
    func probe() async throws -> LMStudioProviderCapabilities {
        let capacity = mode == .smallCapacity ? 1_024 : 32_768
        return LMStudioProviderCapabilities(modelKey: "fixture/integration-model", loadedInstanceID: "fixture/integration-model@\(capacity)",
            contextLength: capacity, maximumContextLength: 131_072, parallelism: 1, flashAttention: true,
            trainedForToolUse: true, streamingVerified: true, functionToolContractVerified: true,
            usageReportingVerified: true, capabilityFingerprintSHA256: String(repeating: "a", count: 64),
            contractProbeResponseID: "integration-capability-probe")
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
        try await SourceBootstrapFixtureWire.root(request)
    }
    func preflightContinuation(_ request: LMStudioContinuationRequest) async throws -> ProviderRequestPreflight {
        try await SourceBootstrapFixtureWire.continuation(request)
    }
    func createRoot(_ request: LMStudioRootRequest) async throws -> LMStudioResponseTurn {
        _ = try await preflightRoot(request)
        roots.append(request)
        if let rootDelay { try await Task.sleep(for: rootDelay) }
        let identity = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(request.userInput.utf8)) as? [String: Any])
        let sourceID = try XCTUnwrap(identity["continuity_id"] as? String)
        let arguments = try ForgeJSONCanonicalizationV1.data(from: ["handoff_id": sourceID])
        return LMStudioResponseTurn(responseID: "integration-root-response", previousResponseID: nil,
            model: "fixture/integration-model", status: "completed", assistantText: "",
            functionCalls: [LMStudioFunctionCall(itemID: "integration-context-item", callID: "integration-context-call", name: "context_get",
                arguments: String(decoding: arguments, as: UTF8.self))],
            usage: LMStudioUsage(inputTokens: 600, outputTokens: 50, totalTokens: 650))
    }
    func continueSession(_ request: LMStudioContinuationRequest) async throws -> LMStudioResponseTurn {
        _ = try await preflightContinuation(request)
        followups.append(request)
        let tool = try XCTUnwrap(request.tools.first)
        let definition = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(tool)) as? [String: Any])
        let parameters = try XCTUnwrap(definition["parameters"] as? [String: Any])
        let properties = try XCTUnwrap(parameters["properties"] as? [String: [String: Any]])
        var values = [String: Any]()
        for (key, property) in properties { values[key] = try XCTUnwrap(property["const"]) }
        if mode == .wrongAcknowledgement { values["nonce"] = UUID().uuidString.lowercased() }
        let arguments = try ForgeJSONCanonicalizationV1.data(from: values)
        return LMStudioResponseTurn(responseID: "integration-ack-response", previousResponseID: request.previousResponseID,
            model: "fixture/integration-model", status: "completed", assistantText: "",
            functionCalls: [LMStudioFunctionCall(itemID: "integration-ack-item", callID: "integration-ack-call", name: "forge_continuity_ack",
                arguments: String(decoding: arguments, as: UTF8.self))],
            usage: LMStudioUsage(inputTokens: 1_200, outputTokens: 80, totalTokens: 1_280))
    }
    func receipt(forIdempotencyKey key: String) async -> LMStudioResponseTurn? { nil }
    func cancel(operationID: String) async { cancellations += 1 }
    func cancellationCount() -> Int { cancellations }
    func snapshot() -> (roots: [LMStudioRootRequest], followups: [LMStudioContinuationRequest]) { (roots, followups) }
}

private enum ManagedSourceSQLite {
    static func integer(_ url: URL, _ sql: String) throws -> Int {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close_v2(db) }
            throw ContinuityIngressError.integrityFailure("integration fixture open")
        }
        defer { sqlite3_close_v2(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ContinuityIngressError.integrityFailure("integration fixture prepare")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw ContinuityIngressError.integrityFailure("integration fixture row") }
        return Int(sqlite3_column_int64(statement, 0))
    }
}
