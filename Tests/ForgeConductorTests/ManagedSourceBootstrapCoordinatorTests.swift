// Exercises supervisor coordinator ownership against the real control plane.

import XCTest
import SQLite3
#if SWIFT_PACKAGE
import ForgeNativeSessionHostPlugin
#endif
@testable import ForgeConductorCore

final class ManagedSourceBootstrapCoordinatorTests: XCTestCase {
    func testStoppedCoordinatorNeverAcquiresLeaseOrDispatches() async throws {
        try await withFixture { fixture in
            let probe = SourceCoordinatorProbe()
            let coordinator = try makeCoordinator(fixture, probe: probe)
            await coordinator.stop()
            do { _ = try await coordinator.runActivation(); XCTFail("Stopped coordinator activated") }
            catch { XCTAssertEqual(error as? AutonomyError, .shutdown) }
            let started = await probe.started
            let cancellations = await probe.cancelled
            let lease = try await fixture.repository.runLease(fixture.reference.runID)
            XCTAssertFalse(started)
            XCTAssertTrue(cancellations.isEmpty)
            XCTAssertNil(lease)
            XCTAssertEqual(try fixture.holdValue("recovery_attempts"), "0")
        }
    }

    func testDisabledAutomaticPolicyCannotClaimOrDispatch() async throws {
        try await withFixture { fixture in
            let probe = SourceCoordinatorProbe()
            let disabled = try BudgetPolicyState(globalPolicy: BudgetPolicy(automaticHandoffEnabled: false)).resolve(fixture.policy.scope)
            let coordinator = try makeCoordinator(fixture, probe: probe, policy: disabled)
            do { _ = try await coordinator.runActivation(); XCTFail("Disabled policy activated") }
            catch { XCTAssertEqual(error as? ContinuityBootstrapRecoveryError, .policyDeferred) }
            let started = await probe.started
            let lease = try await fixture.repository.runLease(fixture.reference.runID)
            XCTAssertFalse(started)
            XCTAssertNil(lease)
            XCTAssertEqual(try fixture.holdValue("recovery_attempts"), "0")
        }
    }

    func testExplicitPermitAllowsBootstrapWhileAutomaticPolicyRemainsDisabled() async throws {
        try await withFixture(explicit: true) { fixture in
            let probe = SourceCoordinatorProbe(failUnknown: true)
            let disabled = try BudgetPolicyState(globalPolicy: BudgetPolicy(automaticHandoffEnabled: false)).resolve(fixture.policy.scope)
            let coordinator = try makeCoordinator(fixture, probe: probe, policy: disabled)
            do { _ = try await coordinator.runActivation(); XCTFail("Expected fixture provider outcome") }
            catch { XCTAssertTrue(error is SourceCoordinatorUnknownProviderOutcome) }
            let started = await probe.started
            XCTAssertTrue(started)
            XCTAssertFalse(disabled.policy.automaticHandoffEnabled)
            XCTAssertEqual(try fixture.holdValue("recovery_attempts"), "1")
            XCTAssertEqual(try fixture.holdValue("recovery_error_code"), "provider_outcome_unknown")
            let lease = try await fixture.repository.runLease(fixture.reference.runID)
            XCTAssertNil(lease)
        }
    }

    func testRenewalFencesSecondOwnerAndStopCancelsOnlyOwnedOperation() async throws {
        try await withFixture { fixture in
            let sleeper = SourceCoordinatorSleeper()
            let probe = SourceCoordinatorProbe()
            let coordinator = try makeCoordinator(fixture, probe: probe, sleeper: sleeper)
            let task = Task { try await coordinator.runActivation() }
            do {
                try await eventually {
                    let started = await probe.started
                    let requests = await sleeper.requests
                    return started && requests > 0
                }
                let initial = try await fixture.repository.runLease(fixture.reference.runID)
                fixture.clock.advance(25)
                await sleeper.resumeOne()
                try await eventually { await sleeper.requests >= 2 }
                let renewed = try await fixture.repository.runLease(fixture.reference.runID)
                XCTAssertEqual(renewed?.epoch, initial?.epoch)
                XCTAssertGreaterThan(try XCTUnwrap(renewed?.expirationDate), try XCTUnwrap(initial?.expirationDate))
                do {
                    _ = try await fixture.repository.acquireRunLease(runID: fixture.reference.runID, ownerID: "other-manager")
                    XCTFail("Second manager acquired renewed lease")
                } catch let error as AutonomyError {
                    guard case .leaseConflict = error else { throw error }
                }
                await coordinator.stop()
                _ = try? await task.value
                let cancelled = await probe.cancelled
                XCTAssertEqual(cancelled, [fixture.reference.operationID])
                let lease = try await fixture.repository.runLease(fixture.reference.runID)
                XCTAssertNil(lease)
                XCTAssertEqual(try fixture.holdValue("recovery_error_code"), "interrupted")
                let retry = try XCTUnwrap(ISO8601.date(from: fixture.holdValue("recovery_retry_at")))
                XCTAssertEqual(retry.timeIntervalSince(fixture.clock.now()), 660, accuracy: 0.1)
                let run = try await fixture.repository.autonomousRun(fixture.reference.runID)
                XCTAssertEqual(run?.state, .awaitingBootstrap)
                XCTAssertNil(run?.activeSessionID)
            } catch {
                await coordinator.stop()
                _ = try? await task.value
                throw error
            }
        }
    }

    func testDefaultThreeHundredSecondMaximumCancelsAndCannotReleaseReplacementEpoch() async throws {
        try await withFixture { fixture in
            let sleeper = SourceCoordinatorSleeper()
            let probe = SourceCoordinatorProbe(blockCancellation: true)
            let coordinator = try makeCoordinator(fixture, probe: probe, sleeper: sleeper)
            let task = Task { try await coordinator.runActivation() }
            do {
                try await eventually {
                    let started = await probe.started
                    let requests = await sleeper.requests
                    return started && requests > 0
                }
                let initialValue = try await fixture.repository.runLease(fixture.reference.runID)
                let initial = try XCTUnwrap(initialValue)
                for request in 1...11 {
                    fixture.clock.advance(25)
                    await sleeper.resumeOne()
                    try await eventually { await sleeper.requests >= request + 1 }
                }
                let lastValue = try await fixture.repository.runLease(fixture.reference.runID)
                let last = try XCTUnwrap(lastValue)
                XCTAssertEqual(try XCTUnwrap(last.expirationDate).timeIntervalSince(try XCTUnwrap(ISO8601.date(from: initial.acquiredAt))), 300, accuracy: 0.1)
                fixture.clock.advance(25)
                await sleeper.resumeOne()
                try await eventually { await !probe.cancelled.isEmpty }
                // Reusing the manager name still requires a new lease epoch.
                let replacement = try await fixture.repository.acquireRunLease(runID: fixture.reference.runID, ownerID: "source-coordinator-manager")
                XCTAssertEqual(replacement.epoch, initial.epoch + 1)
                await probe.releaseCancellation()
                do { _ = try await task.value; XCTFail("Activation outlived maximum lease duration") } catch {}
                let retained = try await fixture.repository.runLease(fixture.reference.runID)
                XCTAssertEqual(retained, replacement)
                _ = try await fixture.repository.releaseRunLease(replacement)
            } catch {
                await probe.releaseCancellation()
                await coordinator.stop()
                _ = try? await task.value
                throw error
            }
        }
    }

    func testUnknownProviderOutcomeHonorsFenceWithoutBurningImmediateAttempts() async throws {
        try await withFixture { fixture in
            let probe = SourceCoordinatorProbe(failUnknown: true)
            let coordinator = try makeCoordinator(fixture, probe: probe)
            do { _ = try await coordinator.runActivation(); XCTFail("Unknown provider outcome succeeded") } catch {}
            XCTAssertEqual(try fixture.holdValue("recovery_error_code"), "provider_outcome_unknown")
            XCTAssertEqual(try fixture.holdValue("recovery_attempts"), "1")
            let retry = try XCTUnwrap(ISO8601.date(from: fixture.holdValue("recovery_retry_at")))
            XCTAssertEqual(retry.timeIntervalSince(fixture.clock.now()), 660, accuracy: 0.1)
            let before = try await fixture.repository.pendingContinuityBootstrapRecoveries()
            XCTAssertTrue(before.references.isEmpty)
            fixture.clock.advance(660)
            let due = try await fixture.repository.pendingContinuityBootstrapRecoveries()
            XCTAssertEqual(due.references, [fixture.reference])
            XCTAssertEqual(try fixture.holdValue("recovery_attempts"), "1")
        }
    }

    func testActualWorkerAckSchedulesOnlyActivationWithoutRepeatingBootstrap() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("source-coordinator-native-\(UUID().uuidString)")
            .resolvingSymlinksInPath().standardizedFileURL
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let app = try ForgeApp.bootstrap(home: root.appendingPathComponent("home"))
        defer { _ = app.shutdown(); try? FileManager.default.removeItem(at: root) }
        let prior = try app.config.budgetPolicySelection(scope: .globalDefault)
        _ = try app.config.updateBudgetPolicy(.init(scope: .globalDefault, expectedRevision: prior.revision,
            expectedGlobalRevision: prior.globalRevision, operation: .set, policy: BudgetPolicy(automaticHandoffEnabled: true)))
        let initialized = try app.projectMemory.initializeUnchecked(path: project.path)
        let projectID = ProjectID(try XCTUnwrap((initialized["project_id"] as? String).flatMap(UUID.init(uuidString:))))
        let reference = try await enroll(repository: app.projectContexts.repository, source: app.store,
            project: project, projectID: projectID)
        let transport = SourceCoordinatorTransport()
        let adapter = try LMStudioManagedSessionHostAdapterV2(storageDirectory: root.appendingPathComponent("provider"), transport: transport)
        let worker = ManagedContinuityWorker(repository: app.projectContexts.repository, memory: app.projectMemory,
            adapterResolver: { _ in adapter })
        let broker = try ToolInvocationBroker(repository: app.projectContexts.repository, executor: app.tools,
            classifier: ProductionToolReplayCatalog.classifier(productionToolNames: app.tools.toolNames))
        let policyResolver: PersistedManagedRunBudgetEvaluator.PolicyResolver = { try app.config.budgetPolicySelection(scope: $0) }
        let coordinator = try ManagedSourceBootstrapCoordinator(reference: reference, repository: app.projectContexts.repository,
            managerID: "native-source-coordinator", policyResolver: policyResolver,
            bootstrap: { acceptance, lease in
                try await worker.executeSourceBootstrap(acceptance: acceptance, lease: lease,
                    broker: broker, continuity: app.continuity, policyResolver: policyResolver)
            }, cancelBootstrap: { operationID in await worker.cancelSourceBootstrap(operationID: operationID) },
            readCanonical: { acceptance in
                guard let operation = try ContinuityStateEngine(memory: app.projectMemory).sourceBootstrap(
                    operationID: acceptance.operationID, authorization: acceptance.authorization) else {
                    throw ContinuityIngressError.notFound
                }
                return operation
            })
        let result = try await coordinator.runActivation()
        XCTAssertEqual(result.stepsExecuted, 1)
        XCTAssertEqual(result.finalState, .awaitingBootstrap)
        let page = try await app.projectContexts.repository.pendingContinuityBootstrapRecoveries()
        let activationReference = try XCTUnwrap(page.references.first)
        XCTAssertEqual(page.references.count, 1)
        XCTAssertEqual(activationReference.operationID, reference.operationID)
        XCTAssertEqual(activationReference.phase, .activation)
        let run = try await app.projectContexts.repository.autonomousRun(reference.runID)
        XCTAssertEqual(run?.state, .awaitingBootstrap)
        XCTAssertNil(run?.activeSessionID)
        let lease = try await app.projectContexts.repository.runLease(reference.runID)
        XCTAssertNil(lease)
        let calls = await transport.counts()
        XCTAssertEqual(calls, [1, 1])
        do { _ = try await app.projectContexts.repository.validateAutonomousRunExecutionAdmission(reference.runID); XCTFail("ACK released hold") }
        catch { XCTAssertEqual(error as? AutonomyError, .bootstrapRequired(reference.runID)) }
        let phaseProbe = SourceCoordinatorActivationProbe()
        let activation = try ManagedSourceBootstrapCoordinator(reference: activationReference,
            repository: app.projectContexts.repository, managerID: "source-activation-coordinator",
            policyResolver: policyResolver,
            bootstrap: { _, _ in XCTFail("Activation repeated bootstrap"); throw SourceCoordinatorFixtureError.timeout },
            cancelBootstrap: { _ in XCTFail("Activation cancelled unrelated bootstrap provider work") },
            readCanonical: { _ in throw SourceCoordinatorFixtureError.timeout },
            activateSource: { acceptance, lease in
                XCTAssertEqual(acceptance.operationID, reference.operationID)
                XCTAssertEqual(lease.runID, reference.runID)
                await phaseProbe.record()
                throw SourceCoordinatorFixtureError.activationSentinel
            })
        do { _ = try await activation.runActivation(); XCTFail("Expected activation fixture seam") }
        catch { XCTAssertEqual(error as? SourceCoordinatorFixtureError, .activationSentinel) }
        let activationCalls = await phaseProbe.calls
        XCTAssertEqual(activationCalls, 1)
        XCTAssertEqual(try SourceCoordinatorFixture.holdValue(database: app.paths.controlPlaneSQLite,
            column: "recovery_attempts"), "1")
        XCTAssertEqual(try SourceCoordinatorFixture.holdValue(database: app.paths.controlPlaneSQLite,
            column: "finalization_attempts"), "1")
        let afterCalls = await transport.counts()
        XCTAssertEqual(afterCalls, [1, 1])
        let retainedRun = try await app.projectContexts.repository.autonomousRun(reference.runID)
        XCTAssertEqual(retainedRun?.state, .awaitingBootstrap)
        XCTAssertNil(retainedRun?.activeSessionID)
        let releasedLease = try await app.projectContexts.repository.runLease(reference.runID)
        XCTAssertNil(releasedLease)
    }

    private func makeCoordinator(_ fixture: SourceCoordinatorFixture, probe: SourceCoordinatorProbe,
        sleeper: any AutonomySleeping = SystemAutonomySleeper(), policy: BudgetPolicySelection? = nil) throws -> ManagedSourceBootstrapCoordinator {
        let selection = policy ?? fixture.policy
        return try ManagedSourceBootstrapCoordinator(reference: fixture.reference, repository: fixture.repository,
            managerID: "source-coordinator-manager", clock: fixture.clock, sleeper: sleeper,
            policyResolver: { _ in selection }, bootstrap: { _, _ in try await probe.execute() },
            cancelBootstrap: { await probe.cancel($0) }, readCanonical: { _ in throw ContinuityIngressError.notFound })
    }

    private func eventually(_ condition: @escaping @Sendable () async throws -> Bool) async throws {
        for _ in 0..<2_000 {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for the bounded coordinator fixture")
        throw SourceCoordinatorFixtureError.timeout
    }

    private func withFixture(explicit: Bool = false, _ body: (SourceCoordinatorFixture) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("source-coordinator-\(UUID().uuidString)")
            .resolvingSymlinksInPath().standardizedFileURL
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let clock = SourceCoordinatorClock()
        let database = root.appendingPathComponent("control.sqlite3")
        let repository = try ProjectControlPlaneRepository(databaseURL: database, clock: clock)
        let source = try SQLiteStore(path: root.appendingPathComponent("source.sqlite3"))
        do {
            let reference = try await enroll(repository: repository, source: source, project: project, explicit: explicit)
            let policy = try BudgetPolicyState(globalPolicy: BudgetPolicy(automaticHandoffEnabled: true)).resolve(
                BudgetPolicyScope(kind: .projectOverride, projectID: reference.projectID.description, projectGeneration: 1))
            try await body(.init(repository: repository, reference: reference, clock: clock, policy: policy, database: database))
            source.close(); await repository.close(); try FileManager.default.removeItem(at: root)
        } catch {
            source.close(); await repository.close(); try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private func enroll(repository: ProjectControlPlaneRepository, source: SQLiteStore, project: URL,
        projectID: ProjectID = ProjectID(), explicit: Bool = false) async throws -> ContinuityBootstrapRecoveryReference {
        _ = try await repository.registerProjectUnchecked(projectID: projectID, displayName: "Coordinator fixture", canonicalRoot: project)
        let scope = ToolAuthorizationScope(canonicalRoots: [project], writableRoots: [], allowedTools: ["context_get"],
            networkAllowed: false, maximumInlineOutputBytes: 65_536)
        let client = ClientID("source-coordinator-fixture"), owner = ProjectBindingOwner(kind: .mcpClient, id: "source-coordinator-fixture")
        let binding = try await repository.bind(owner: owner, projectID: projectID, generation: .initial, authorizationScope: scope)
        let assignment = try ContinuityTaskAssignment(assignmentID: "coordinator-approved", assignmentBytes: Data("Approved fixture".utf8),
            mission: "Read the exact authorized source", providerID: "lmstudio", adapterID: "forge.native-session-host",
            modelKey: "fixture/coordinator-model", specification: .init(allowedTools: ["context_get"], completionGates: ["fixture"]),
            authorizationScope: scope)
        let setup = try await repository.authorizeContinuityTask(projectID: projectID, expectedGeneration: .initial,
            approvedAssignment: assignment, callerContext: binding.invocationContext(clientID: client), callerOwner: owner)
        let commit = try source.handoffCommit(HandoffPacket(id: "coordinator-source", createdAt: "2026-09-08T10:00:00Z",
            updatedAt: "2026-09-08T10:00:00Z", source: .model, resumeReady: true, goal: "Exact fixture progress"),
            authorization: setup.record.authorization, automaticHandoffEnabled: true)
        let policy = try BudgetPolicyState(globalPolicy: BudgetPolicy(automaticHandoffEnabled: true)).resolve(
            BudgetPolicyScope(kind: .projectOverride, projectID: projectID.description, projectGeneration: 1))
        _ = try await repository.acceptContinuityIngress(source: commit.revision,
            operationID: XCTUnwrap(commit.delivery?.operationID), policySelection: policy)
        if explicit {
            _ = try await repository.submitExplicitContinuityIngress(taskID: setup.record.authorization.taskID,
                correlation: setup.correlation, context: binding.invocationContext(clientID: client), owner: owner,
                requestID: UUID(), continuityID: commit.revision.identity.continuityID, policySelection: policy) { _ in
                    commit.revision
                }
        }
        let page = try await repository.pendingContinuityBootstrapRecoveries()
        return try XCTUnwrap(page.references.first)
    }
}

private enum SourceCoordinatorFixtureError: Error, Equatable { case timeout, activationSentinel }

private actor SourceCoordinatorActivationProbe {
    var calls = 0
    func record() { calls += 1 }
}

private struct SourceCoordinatorFixture: Sendable {
    let repository: ProjectControlPlaneRepository
    let reference: ContinuityBootstrapRecoveryReference
    let clock: SourceCoordinatorClock
    let policy: BudgetPolicySelection
    let database: URL

    func holdValue(_ column: String) throws -> String {
        try Self.holdValue(database: database, column: column)
    }

    static func holdValue(database: URL, column: String) throws -> String {
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close_v2(db) }; throw SourceCoordinatorFixtureError.timeout
        }
        defer { sqlite3_close_v2(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT \(column) FROM continuity_ingress_holds", -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SourceCoordinatorFixtureError.timeout
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return "" }
        return String(cString: text)
    }
}

private final class SourceCoordinatorClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); value = value.addingTimeInterval(seconds); lock.unlock() }
}

private actor SourceCoordinatorSleeper: AutonomySleeping {
    private var permits = 0
    var requests = 0
    func sleep(for duration: Duration) async throws {
        requests += 1
        while permits == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        permits -= 1
    }
    func resumeOne() { permits += 1 }
}

private actor SourceCoordinatorProbe {
    private let failUnknown: Bool
    private let blockCancellation: Bool
    private var cancellationWaiter: CheckedContinuation<Void, Never>?
    var started = false
    var cancelled: [UUID] = []
    init(failUnknown: Bool = false, blockCancellation: Bool = false) {
        self.failUnknown = failUnknown; self.blockCancellation = blockCancellation
    }
    func execute() async throws -> SourceBootstrapReceipt {
        started = true
        if failUnknown { throw SourceCoordinatorUnknownProviderOutcome() }
        try await Task.sleep(for: .seconds(30))
        throw SourceCoordinatorFixtureError.timeout
    }
    func cancel(_ operationID: UUID) async {
        cancelled.append(operationID)
        if blockCancellation { await withCheckedContinuation { cancellationWaiter = $0 } }
    }
    func releaseCancellation() { cancellationWaiter?.resume(); cancellationWaiter = nil }
}

private struct SourceCoordinatorUnknownProviderOutcome: ManagedProviderFailure {
    let managedProviderFailureDisposition = ManagedProviderFailureDisposition.waitingProvider
    let managedProviderFailureCode = "lmstudio_conflict"
    let managedProviderRetryDelay: TimeInterval? = nil
}

private actor SourceCoordinatorTransport: LMStudioManagedTransportObservedDispatching {
    private var roots = 0, followups = 0
    func probe() async throws -> LMStudioProviderCapabilities {
        LMStudioProviderCapabilities(modelKey: "fixture/coordinator-model", loadedInstanceID: "fixture/coordinator-model@32768",
            contextLength: 32_768, maximumContextLength: 131_072, parallelism: 1, flashAttention: true,
            trainedForToolUse: true, streamingVerified: true, functionToolContractVerified: true, usageReportingVerified: true,
            capabilityFingerprintSHA256: String(repeating: "a", count: 64), contractProbeResponseID: "coordinator-probe")
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
        roots += 1
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(request.userInput.utf8)) as? [String: Any])
        let source = try XCTUnwrap(object["continuity_id"] as? String)
        let args = try ForgeJSONCanonicalizationV1.data(from: ["handoff_id": source])
        return LMStudioResponseTurn(responseID: "coordinator-root", previousResponseID: nil, model: "fixture/coordinator-model",
            status: "completed", assistantText: "", functionCalls: [.init(itemID: "coordinator-context-item", callID: "coordinator-context", name: "context_get",
                arguments: String(decoding: args, as: UTF8.self))], usage: .init(inputTokens: 600, outputTokens: 50, totalTokens: 650))
    }
    func continueSession(_ request: LMStudioContinuationRequest) async throws -> LMStudioResponseTurn {
        _ = try await preflightContinuation(request)
        followups += 1
        let tool = try XCTUnwrap(request.tools.first)
        let definition = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(tool)) as? [String: Any])
        let parameters = try XCTUnwrap(definition["parameters"] as? [String: Any])
        let properties = try XCTUnwrap(parameters["properties"] as? [String: [String: Any]])
        var values: [String: Any] = [:]
        for (key, value) in properties { values[key] = try XCTUnwrap(value["const"]) }
        let args = try ForgeJSONCanonicalizationV1.data(from: values)
        return LMStudioResponseTurn(responseID: "coordinator-ack", previousResponseID: request.previousResponseID,
            model: "fixture/coordinator-model", status: "completed", assistantText: "",
            functionCalls: [.init(itemID: "coordinator-ack-item", callID: "coordinator-ack-call", name: "forge_continuity_ack", arguments: String(decoding: args, as: UTF8.self))],
            usage: .init(inputTokens: 1_200, outputTokens: 80, totalTokens: 1_280))
    }
    func receipt(forIdempotencyKey key: String) async -> LMStudioResponseTurn? { nil }
    func cancel(operationID: String) async {}
    func counts() -> [Int] { [roots, followups] }
}
