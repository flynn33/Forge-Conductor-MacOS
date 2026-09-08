import XCTest
import SQLite3
#if SWIFT_PACKAGE
import ForgeNativeSessionHostPlugin
#endif
@testable import ForgeConductorCore

final class ContinuityOperationCancellationRuntimeTests: XCTestCase {
    func testRunningNativeRootIsPhysicallyStoppedAndUnknownOutcomeRemainsFenced() async throws {
        try await withFixture { fixture in
            let source = fixture.acceptance.source
            _ = try await fixture.app.continuity.submitAuthorizedHandoff(
                ContinuityExplicitHandoffRequest(arguments: ["continuity_id": source.identity.continuityID,
                    "idempotency_key": "physical-cancellation"]), taskID: fixture.setup.record.authorization.taskID,
                correlation: fixture.setup.correlation, context: fixture.context, owner: fixture.owner,
                repository: fixture.repository, config: fixture.app.config)
            let transport = SourceCancellationBlockedTransport()
            let registry = HostAdapterRegistry()
            registry.register(manifest: ForgeNativeSessionHostPlugin.manifest,
                managedProviderFactory: { try LMStudioManagedModelProvider(storageDirectory: $0, transport: transport) },
                factory: { try LMStudioManagedSessionHostAdapter(storageDirectory: $0, transport: transport) })
            let runtime = try ManagedAutonomyRuntime(app: fixture.app, registry: registry, maximumConcurrentRuns: 1)
            do {
                _ = try await runtime.start()
                var started = false
                for _ in 0..<400 {
                    if await transport.snapshot().roots == 1 { started = true; break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                XCTAssertTrue(started, "The registered native adapter must reach its actual root transport before cancellation")
                let runningLease = try await fixture.repository.runLease(fixture.acceptance.runID)
                let ownedLease = try XCTUnwrap(runningLease)
                XCTAssertGreaterThan(try XCTUnwrap(ownedLease.expirationDate), fixture.clock.now())
                _ = try await fixture.request()
                // Discovery must expose the exact cancellation to its current
                // owner before lease expiry, so the watchdog can physically
                // quiesce its running native request before claiming cleanup.
                let requested = try await fixture.repository.pendingContinuityOperationCancellations()
                XCTAssertEqual(requested.references.map(\.operationID), [fixture.acceptance.operationID])
                let beforeQuiesce = try await fixture.repository.runLease(fixture.acceptance.runID)
                XCTAssertEqual(beforeQuiesce, ownedLease)
                try await runtime.tick()
                let observed = await transport.snapshot()
                XCTAssertEqual(observed.roots, 1)
                XCTAssertEqual(observed.followups, 0)
                XCTAssertEqual(observed.cancelledTasks, 1)
                XCTAssertFalse(observed.cancelledRequests.isEmpty)
                let status = try await fixture.status()
                XCTAssertEqual(status.state, .cancelRequested)
                XCTAssertEqual(status.recoveryState, .uncertain)
                XCTAssertNil(status.terminalReceipt)
                let lease = try await fixture.repository.runLease(fixture.acceptance.runID)
                XCTAssertNil(lease)
                let beforeFence = try await fixture.repository.pendingContinuityOperationCancellations()
                XCTAssertTrue(beforeFence.references.isEmpty)
                fixture.clock.advance(659)
                try await runtime.tick()
                let stillWaiting = try await fixture.repository.pendingContinuityOperationCancellations()
                XCTAssertTrue(stillWaiting.references.isEmpty)
                fixture.clock.advance(2)
                try await runtime.tick()
                let afterFence = try await fixture.status()
                XCTAssertEqual(afterFence.state, .cancelRequested)
                XCTAssertEqual(afterFence.recoveryState, .uncertain)
                XCTAssertNil(afterFence.terminalReceipt, "Elapsed time cannot manufacture remote cancellation proof")
                let noReplay = await transport.snapshot()
                XCTAssertEqual(noReplay.roots, 1)
                XCTAssertEqual(noReplay.followups, 0)
                XCTAssertEqual(noReplay.cancelledRequests, observed.cancelledRequests)
                let peer = try fixture.app.store.continuityHandoffRevision(identity: fixture.peer.sourceIdentity,
                    authorization: fixture.peer.authorization)
                XCTAssertEqual(peer, fixture.peer.source)
                await runtime.shutdown()
            } catch {
                await runtime.shutdown()
                throw error
            }
        }
    }

    func testStartupCancelsOnlyExactSourceAndCannotReviveItsUnpreparedOperation() async throws {
        try await withFixture { fixture in
            let result = try await fixture.request()
            XCTAssertEqual(result.disposition, .requested)
            let runtime = try ManagedAutonomyRuntime(app: fixture.app, registry: HostAdapterRegistry())
            do {
                _ = try await runtime.start()
                let status = try await fixture.status()
                XCTAssertEqual(status.state, .cancelled)
                XCTAssertEqual(status.terminalReceipt?.outcome, .cancelled)
                let run = try await fixture.repository.autonomousRun(fixture.acceptance.runID)
                XCTAssertEqual(run?.state, .cancelled)
                let sessions = try await fixture.repository.providerSessions(operationID: fixture.acceptance.operationID)
                XCTAssertTrue(sessions.isEmpty)
                let peer = try await fixture.repository.autonomousRun(fixture.peer.runID)
                XCTAssertEqual(peer?.state, .awaitingBootstrap)
                let peerSource = try fixture.app.store.continuityHandoffRevision(identity: fixture.peer.sourceIdentity,
                    authorization: fixture.peer.authorization)
                XCTAssertEqual(peerSource, fixture.peer.source)
                let engine = ContinuityStateEngine(memory: fixture.app.projectMemory)
                do {
                    _ = try engine.prepareSourceBootstrap(acceptance: fixture.acceptance,
                        authorization: fixture.acceptance.authorization, bootstrapNonce: UUID())
                    XCTFail("An exact cancelled source was recreated after its pre-prepare journal tombstone")
                } catch { XCTAssertEqual(error as? ContinuityIngressError, .invalidated) }
                let repeated = try await fixture.request()
                XCTAssertEqual(repeated.disposition, .alreadyTerminal)
                XCTAssertEqual(repeated.snapshot.terminalReceipt, status.terminalReceipt)
                await runtime.shutdown()
            } catch {
                await runtime.shutdown()
                throw error
            }
        }
    }

    func testSourceStoreFailureRetainsCanonicalMarkerAndRestartCompletesExactCleanup() async throws {
        try await withFixture { fixture in
            let engine = ContinuityStateEngine(memory: fixture.app.projectMemory)
            let lease = try await fixture.repository.acquireRunLease(runID: fixture.acceptance.runID, ownerID: "prepare-cancel-fixture")
            let acceptance = fixture.acceptance
            let prepared = try await fixture.repository.withContinuityIngressAcceptance(acceptance: acceptance, lease: lease) {
                try engine.prepareSourceBootstrap(acceptance: acceptance, authorization: acceptance.authorization, bootstrapNonce: UUID())
            }
            _ = try await fixture.repository.releaseRunLease(lease)
            let claim = try XCTUnwrap(fixture.app.store.claimContinuityHandoff(operationID: acceptance.operationID,
                owner: "accepted-source-fixture"))
            let acknowledged = try fixture.app.store.acknowledgeContinuityHandoff(claim: claim,
                acceptanceReceiptSHA256: acceptance.receiptSHA256)
            _ = try await fixture.request()
            // Only this isolated fixture connection becomes unavailable. The
            // control-plane request and project-local journal remain writable.
            fixture.app.store.close()
            let runtime = try ManagedAutonomyRuntime(app: fixture.app, registry: HostAdapterRegistry())
            _ = try await runtime.start()
            let pending = try await fixture.status()
            XCTAssertEqual(pending.state, .cancelRequested)
            XCTAssertNil(pending.terminalReceipt)
            let memory = try fixture.app.projectMemory.repositoryForProject(acceptance.authorization.projectID.description)
            XCTAssertEqual(try scalar(memory.databaseURL, sql: "SELECT quarantine_state FROM rollover_operations WHERE operation_id=?",
                operationID: acceptance.operationID), "source_cancelled")
            XCTAssertEqual(try scalar(memory.databaseURL, sql: "SELECT state_checksum FROM rollover_operations WHERE operation_id=?",
                operationID: acceptance.operationID), prepared.stateChecksum)
            let marker = try scalar(memory.databaseURL,
                sql: "SELECT state_checksum FROM rollover_transitions WHERE operation_id=? AND to_state='cancelled'",
                operationID: acceptance.operationID)
            await runtime.shutdown()
            XCTAssertTrue(fixture.app.shutdown().completed)
            fixture.clock.advance(10)

            let reopened = try ForgeApp.bootstrap(home: fixture.home, clock: fixture.clock)
            defer { _ = reopened.shutdown() }
            let resumedRuntime = try ManagedAutonomyRuntime(app: reopened, registry: HostAdapterRegistry())
            do {
                _ = try await resumedRuntime.start()
                let finished = try await fixture.status(app: reopened)
                XCTAssertEqual(finished.state, .cancelled)
                XCTAssertNotNil(finished.terminalReceipt)
                let retained = try XCTUnwrap(reopened.store.continuityDelivery(operationID: acceptance.operationID))
                XCTAssertEqual(retained.state, .acknowledged)
                XCTAssertEqual(retained.acceptanceReceiptSHA256, acknowledged.acceptanceReceiptSHA256)
                XCTAssertEqual(retained.acknowledgedAt, acknowledged.acknowledgedAt)
                XCTAssertEqual(retained.leaseOwner, acknowledged.leaseOwner)
                XCTAssertEqual(retained.leaseToken, acknowledged.leaseToken)
                XCTAssertEqual(retained.handoff, acknowledged.handoff)
                let reopenedMemory = try reopened.projectMemory.repositoryForProject(acceptance.authorization.projectID.description)
                XCTAssertEqual(try scalar(reopenedMemory.databaseURL,
                    sql: "SELECT state_checksum FROM rollover_transitions WHERE operation_id=? AND to_state='cancelled'",
                    operationID: acceptance.operationID), marker)
                XCTAssertEqual(try scalar(reopenedMemory.databaseURL,
                    sql: "SELECT state_checksum FROM rollover_operations WHERE operation_id=?",
                    operationID: acceptance.operationID), prepared.stateChecksum)
                let peer = try reopened.store.continuityHandoffRevision(identity: fixture.peer.sourceIdentity,
                    authorization: fixture.peer.authorization)
                XCTAssertEqual(peer, fixture.peer.source)
                await resumedRuntime.shutdown()
            } catch {
                await resumedRuntime.shutdown()
                throw error
            }
        }
    }

    func testCancellingOneWorkerOperationDoesNotDisableItsIndependentSource() async throws {
        try await withFixture { fixture in
            let worker = ManagedContinuityWorker(repository: fixture.repository, memory: fixture.app.projectMemory,
                adapterResolver: { _ in throw SourceCancellationFixtureError.adapterResolved })
            await worker.cancelSourceBootstrap(operationID: fixture.acceptance.operationID)
            let lease = try await fixture.repository.acquireRunLease(runID: fixture.peer.runID, ownerID: "independent-source-worker")
            let classifier = try ProductionToolReplayCatalog.classifier(productionToolNames: fixture.app.tools.toolNames)
            let broker = ToolInvocationBroker(repository: fixture.repository, executor: fixture.app.tools,
                classifier: classifier, reconciler: ProductionToolInvocationReconciler(controlPlane: fixture.repository,
                    runtimeJobs: fixture.app.runtimeJobs.repository, memory: fixture.app.projectMemory))
            do {
                _ = try await worker.executeSourceBootstrap(acceptance: fixture.peer, lease: lease, broker: broker,
                    continuity: fixture.app.continuity, policyResolver: { _ in fixture.peer.policySelection })
                XCTFail("The fixture must stop at adapter resolution")
            } catch { XCTAssertEqual(error as? SourceCancellationFixtureError, .adapterResolved) }
            let operation = try ContinuityStateEngine(memory: fixture.app.projectMemory).sourceBootstrap(
                operationID: fixture.peer.operationID, authorization: fixture.peer.authorization)
            XCTAssertEqual(operation?.state, .successorRequested)
            _ = try await fixture.repository.releaseRunLease(lease)
        }
    }

    private func scalar(_ database: URL, sql: String, operationID: UUID) throws -> String? {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            throw SourceCancellationFixtureError.database
        }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SourceCancellationFixtureError.database
        }
        defer { sqlite3_finalize(statement) }
        let identifier = operationID.uuidString.lowercased()
        return try identifier.withCString { bytes in
            guard sqlite3_bind_text(statement, 1, bytes, -1, nil) == SQLITE_OK else { throw SourceCancellationFixtureError.database }
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return sqlite3_column_text(statement, 0).map { String(cString: $0) }
        }
    }

    private func withFixture(_ body: (SourceCancellationRuntimeFixture) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("source-cancellation-runtime-\(UUID().uuidString)")
            .resolvingSymlinksInPath().standardizedFileURL
        let project = root.appendingPathComponent("project"), home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let clock = SourceCancellationRuntimeClock()
        let app = try ForgeApp.bootstrap(home: home, clock: clock)
        defer { _ = app.shutdown(); try? FileManager.default.removeItem(at: root) }
        let initialized = try app.projectMemory.initializeUnchecked(path: project.path)
        let projectID = ProjectID(try XCTUnwrap((initialized["project_id"] as? String).flatMap(UUID.init(uuidString:))))
        let repository = app.projectContexts.repository
        _ = try await repository.registerProjectUnchecked(projectID: projectID, displayName: "Source cancellation", canonicalRoot: project)
        let owner = ProjectBindingOwner(kind: .mcpClient, id: "shared-cancellation-fixture")
        let scope = ToolAuthorizationScope(canonicalRoots: [project], writableRoots: [], allowedTools: ["context_get"],
            networkAllowed: false, maximumInlineOutputBytes: 65_536)
        let binding = try await repository.bind(owner: owner, projectID: projectID, generation: .initial, authorizationScope: scope)
        let context = binding.invocationContext(clientID: ClientID("shared-cancellation-fixture"))
        let policy = try BudgetPolicyState(globalPolicy: BudgetPolicy(automaticHandoffEnabled: true)).resolve(
            .init(kind: .projectOverride, projectID: projectID.description, projectGeneration: 1))
        func enroll(_ name: String) async throws -> (AuthorizedContinuityTaskSetup, ContinuityIngressAcceptanceReceipt) {
            let assignment = try ContinuityTaskAssignment(assignmentID: "cancel-\(name)", assignmentBytes: Data("Read approved \(name)".utf8),
                mission: "Read approved source \(name)", providerID: "lmstudio", adapterID: "forge.native-session-host",
                modelKey: "fixture/cancellation-model", specification: .init(allowedTools: ["context_get"], completionGates: ["fixture"]),
                authorizationScope: scope)
            let setup = try await repository.authorizeContinuityTask(projectID: projectID, expectedGeneration: .initial,
                approvedAssignment: assignment, callerContext: context, callerOwner: owner)
            let source = try app.store.handoffCommit(HandoffPacket(id: "cancellation-\(name)", source: .model,
                resumeReady: true, goal: "Exact \(name) source"), authorization: setup.record.authorization,
                automaticHandoffEnabled: true)
            let acceptance = try await repository.acceptContinuityIngress(source: source.revision,
                operationID: XCTUnwrap(source.delivery?.operationID), policySelection: policy)
            return (setup, acceptance)
        }
        let (setup, acceptance) = try await enroll("first")
        let (_, peer) = try await enroll("peer")
        let prior = try app.config.budgetPolicySelection(scope: .globalDefault)
        _ = try app.config.updateBudgetPolicy(.init(scope: .globalDefault, expectedRevision: prior.revision,
            expectedGlobalRevision: prior.globalRevision, operation: .set,
            policy: BudgetPolicy(automaticHandoffEnabled: false)))
        try await body(.init(app: app, home: home, clock: clock, setup: setup, context: context, owner: owner,
            acceptance: acceptance, peer: peer))
    }
}

private enum SourceCancellationFixtureError: Error, Equatable { case adapterResolved, database }

private actor SourceCancellationBlockedTransport: LMStudioManagedTransporting {
    private var roots = 0, followups = 0, cancelledTasks = 0
    private var cancelledRequests: [String] = []
    func probe() async throws -> LMStudioProviderCapabilities {
        LMStudioProviderCapabilities(modelKey: "fixture/cancellation-model", loadedInstanceID: "fixture/cancellation-model@32768",
            contextLength: 32_768, maximumContextLength: 131_072, parallelism: 1, flashAttention: true,
            trainedForToolUse: true, streamingVerified: true, functionToolContractVerified: true, usageReportingVerified: true,
            capabilityFingerprintSHA256: String(repeating: "a", count: 64), contractProbeResponseID: "cancellation-probe")
    }
    func createRoot(_ request: LMStudioRootRequest) async throws -> LMStudioResponseTurn {
        roots += 1
        do { try await Task.sleep(for: .seconds(20)) }
        catch { cancelledTasks += 1; throw error }
        throw SourceCancellationFixtureError.adapterResolved
    }
    func continueSession(_ request: LMStudioContinuationRequest) async throws -> LMStudioResponseTurn {
        followups += 1
        throw SourceCancellationFixtureError.adapterResolved
    }
    func receipt(forIdempotencyKey key: String) async -> LMStudioResponseTurn? { nil }
    func cancel(operationID: String) async {
        if cancelledRequests.count < 8 { cancelledRequests.append(operationID) }
    }
    func snapshot() -> (roots: Int, followups: Int, cancelledTasks: Int, cancelledRequests: [String]) {
        (roots, followups, cancelledTasks, cancelledRequests)
    }
}

private struct SourceCancellationRuntimeFixture: Sendable {
    let app: ForgeApp
    let home: URL
    let clock: SourceCancellationRuntimeClock
    let setup: AuthorizedContinuityTaskSetup
    let context: ToolInvocationContext
    let owner: ProjectBindingOwner
    let acceptance: ContinuityIngressAcceptanceReceipt
    let peer: ContinuityIngressAcceptanceReceipt
    var repository: ProjectControlPlaneRepository { app.projectContexts.repository }
    func request() async throws -> ContinuityOperationCancellationResult {
        try await repository.requestContinuityOperationCancellation(operationID: acceptance.operationID,
            taskID: setup.record.authorization.taskID, correlation: setup.correlation, context: context, owner: owner)
    }
    func status(app reopened: ForgeApp? = nil) async throws -> ContinuityOperationStatus {
        try await (reopened ?? app).projectContexts.repository.continuityOperationStatus(operationID: acceptance.operationID,
            taskID: setup.record.authorization.taskID, correlation: setup.correlation, context: context, owner: owner)
    }
}

private final class SourceCancellationRuntimeClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var instant = Date(timeIntervalSince1970: 1_788_866_400)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return instant }
    func advance(_ seconds: TimeInterval) { lock.lock(); instant.addTimeInterval(seconds); lock.unlock() }
}
