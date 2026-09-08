import XCTest
@testable import ForgeConductorCore

final class ContinuityIngressDeliveryTests: XCTestCase {
    private var home: URL!
    private var app: ForgeApp!
    private var clock: FixedClock!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("continuity-delivery-\(UUID())")
        clock = FixedClock(Date(timeIntervalSince1970: 1_800_000_000))
        app = try ForgeApp.bootstrap(home: home, clock: clock)
        try setAutomaticDelivery(true)
    }

    override func tearDownWithError() throws {
        app.shutdown()
        app = nil
        try? FileManager.default.removeItem(at: home)
    }

    private func setAutomaticDelivery(_ enabled: Bool, scope: BudgetPolicyScope = .globalDefault) throws {
        let prior = try app.config.budgetPolicySelection(scope: scope)
        _ = try app.config.updateBudgetPolicy(.init(scope: scope, expectedRevision: prior.revision,
            expectedGlobalRevision: prior.globalRevision, operation: .set,
            policy: BudgetPolicy(automaticHandoffEnabled: enabled)))
    }

    private struct SourceFixture {
        let commit: ContinuityHandoffCommit
        let owner: ProjectBindingOwner
        let setup: AuthorizedContinuityTaskSetup
    }

    private func commitTask() async throws -> SourceFixture {
        let repository = app.projectContexts.repository
        let projectID = ProjectID()
        let projectRoot = home.appendingPathComponent(projectID.description)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        _ = try await repository.registerProjectUnchecked(projectID: projectID,
            displayName: "Delivery fixture", canonicalRoot: projectRoot)
        let owner = ProjectBindingOwner(kind: .mcpClient, id: "source-\(UUID())")
        let scope = ToolAuthorizationScope(canonicalRoots: [projectRoot], writableRoots: [],
            allowedTools: ["fs_read"], networkAllowed: false, maximumInlineOutputBytes: 4_096)
        let binding = try await repository.bind(owner: owner, projectID: projectID,
            generation: .initial, authorizationScope: scope)
        let context = binding.invocationContext(clientID: ClientID(owner.id))
        let assignment = try ContinuityTaskAssignment(assignmentID: "approved-\(UUID())",
            assignmentBytes: Data("Read the approved file".utf8), mission: "Read the approved file",
            providerID: "lmstudio", adapterID: "forge.native-session-host", modelKey: "fixture-model",
            specification: .init(allowedTools: ["fs_read"], completionGates: ["G04"]),
            authorizationScope: scope)
        let setup = try await repository.authorizeContinuityTask(projectID: projectID,
            expectedGeneration: .initial, approvedAssignment: assignment,
            callerContext: context, callerOwner: owner)
        let continuity = app.continuity
        let commit = try await repository.withAuthorizedContinuityTask(
            taskID: setup.record.authorization.taskID, correlation: setup.correlation,
            context: context, owner: owner
        ) { authorization in
            try continuity.commitAuthorizedHandoff(arguments: ["goal": "Untrusted broader mission"],
                clientID: context.clientID, source: .model, finalize: true,
                authorization: authorization, automaticHandoffEnabled: true)
        }
        return SourceFixture(commit: commit, owner: owner, setup: setup)
    }

    private func service(batchLimit: Int = 16,
                         checkpoint: @escaping @Sendable (ContinuityIngressDeliveryCheckpoint) async throws -> Void = { _ in }) throws -> ContinuityIngressDeliveryService {
        try ContinuityIngressDeliveryService(source: app.store,
            repository: app.projectContexts.repository, config: app.config,
            batchLimit: batchLimit, checkpoint: checkpoint)
    }

    func testPersistentManagerAdmitsSourceOnceAndLeavesProviderBootstrapHeld() async throws {
        let fixture = try await commitTask()
        let operationID = try XCTUnwrap(fixture.commit.delivery).operationID
        let manager = ManagerNode(app: app)
        defer { manager.shutdownManagedAutonomy() }
        do {
            _ = try await manager.drainContinuityIngressOnce()
            XCTFail("A manager without a persistent runtime drove delivery")
        } catch { XCTAssertEqual(error as? AutonomyError, .shutdown) }
        _ = try manager.recoverManagedAutonomy()
        let report = try await manager.drainContinuityIngressOnce()
        XCTAssertEqual(report.accepted, 1)
        XCTAssertEqual(try app.store.continuityDelivery(operationID: operationID)?.state, .acknowledged)
        let runs = try await app.projectContexts.repository.nonterminalAutonomousRuns()
        let run = try XCTUnwrap(runs.first)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(run.state, .awaitingBootstrap)
        XCTAssertEqual(run.mission, fixture.setup.record.assignment.mission)
        XCTAssertNil(run.activeSessionID)
        XCTAssertNil(run.specification.work.pendingIntent)
        let sessions = try await app.projectContexts.repository.providerSessions(operationID: operationID)
        XCTAssertTrue(sessions.isEmpty)
        let second = try await manager.drainContinuityIngressOnce()
        XCTAssertEqual(second.accepted, 0)
        let unchanged = try await app.projectContexts.repository.autonomousRun(run.runID)
        XCTAssertEqual(unchanged, run)
    }

    func testAcceptanceSurvivesRestartBeforeSourceAcknowledgmentWithoutNewRun() async throws {
        let fixture = try await commitTask()
        let operationID = try XCTUnwrap(fixture.commit.delivery).operationID
        let interrupted = try service { point in
            if case .acceptanceCommitted = point { throw ContinuityIngressDeliveryInterruption.simulatedExit }
        }
        do {
            _ = try await interrupted.drainOnce()
            XCTFail("The acceptance interruption did not run")
        } catch { XCTAssertTrue(error is ContinuityIngressDeliveryInterruption) }
        let initialRuns = try await app.projectContexts.repository.nonterminalAutonomousRuns()
        let initial = try XCTUnwrap(initialRuns.first)
        XCTAssertEqual(initialRuns.count, 1)
        XCTAssertEqual(initial.state, .awaitingBootstrap)
        XCTAssertEqual(try app.store.continuityDelivery(operationID: operationID)?.state, .claimed)
        await interrupted.shutdown()
        app.shutdown()
        clock.date = clock.date.addingTimeInterval(31)
        app = try ForgeApp.bootstrap(home: home, clock: clock)
        let restarted = try service()
        let recovered = try await restarted.drainOnce()
        XCTAssertEqual(recovered.accepted, 1)
        let after = try await app.projectContexts.repository.nonterminalAutonomousRuns()
        XCTAssertEqual(after, initialRuns)
        let delivered = try XCTUnwrap(app.store.continuityDelivery(operationID: operationID))
        XCTAssertEqual(delivered.state, .acknowledged)
        XCTAssertEqual(delivered.attempts, 2)
        XCTAssertNotNil(delivered.acceptanceReceiptSHA256)
        await restarted.shutdown()
    }

    func testDisabledAutomaticDeliveryPreservesAttemptsAndExplicitSubmissionConverges() async throws {
        let fixture = try await commitTask()
        let operationID = try XCTUnwrap(fixture.commit.delivery).operationID
        try setAutomaticDelivery(false)
        let delivery = try service()
        let deferred = try await delivery.drainOnce()
        XCTAssertEqual(deferred.deferredByPolicy, 1)
        XCTAssertEqual(try app.store.continuityDelivery(operationID: operationID)?.attempts, 0)
        let before = try await app.projectContexts.repository.nonterminalAutonomousRuns()
        XCTAssertTrue(before.isEmpty)
        let explicit = try app.store.enqueueContinuityHandoff(
            identity: fixture.commit.revision.identity, authorization: fixture.commit.revision.authorization)
        XCTAssertEqual(explicit.operationID, operationID)
        XCTAssertTrue(explicit.explicitlyRequested)
        let accepted = try await delivery.drainOnce()
        XCTAssertEqual(accepted.accepted, 1)
        XCTAssertEqual(try app.store.continuityDelivery(operationID: operationID)?.attempts, 1)
        await delivery.shutdown()
    }

    func testCursorAdvancesPastDisabledScopesWithoutConsumingTheirAttempts() async throws {
        let first = try await commitTask()
        let second = try await commitTask()
        let ordered = [first, second].sorted {
            $0.commit.delivery!.operationID.uuidString < $1.commit.delivery!.operationID.uuidString
        }
        try setAutomaticDelivery(false)
        let enabled = ordered[1].commit.revision.authorization
        try setAutomaticDelivery(true, scope: .init(kind: .projectOverride,
            projectID: enabled.projectID.description, projectGeneration: Int(enabled.projectGeneration.rawValue)))
        let delivery = try service(batchLimit: 1)
        let deferred = try await delivery.drainOnce()
        XCTAssertEqual(deferred.scanned, 1)
        XCTAssertEqual(deferred.deferredByPolicy, 1)
        let accepted = try await delivery.drainOnce()
        XCTAssertEqual(accepted.scanned, 1)
        XCTAssertEqual(accepted.accepted, 1)
        XCTAssertEqual(try app.store.continuityDelivery(operationID: ordered[0].commit.delivery!.operationID)?.attempts, 0)
        await delivery.shutdown()
    }

    func testAutomaticPolicyChangeAfterClaimDefersBeforeAcceptance() async throws {
        let fixture = try await commitTask()
        let operationID = fixture.commit.delivery!.operationID
        let config = app.config
        let delivery = try service { point in
            if case .sourceClaimed = point {
                let prior = try config.budgetPolicySelection(scope: .globalDefault)
                _ = try config.updateBudgetPolicy(.init(scope: .globalDefault,
                    expectedRevision: prior.revision, expectedGlobalRevision: prior.globalRevision,
                    operation: .set, policy: BudgetPolicy(automaticHandoffEnabled: false)))
            }
        }
        let report = try await delivery.drainOnce()
        XCTAssertEqual(report.deferredByPolicy, 1)
        XCTAssertEqual(report.accepted, 0)
        let stored = try XCTUnwrap(app.store.continuityDelivery(operationID: operationID))
        XCTAssertEqual(stored.state, .pending)
        XCTAssertEqual(stored.attempts, 0)
        XCTAssertNil(stored.acceptanceReceiptSHA256)
        XCTAssertNil(stored.leaseToken)
        let runs = try await app.projectContexts.repository.nonterminalAutonomousRuns()
        XCTAssertTrue(runs.isEmpty)
        await delivery.shutdown()
    }

    func testShutdownCancelsOwnedClaimAndRestartRecoversWithoutConcurrentDrain() async throws {
        let fixture = try await commitTask()
        let operationID = fixture.commit.delivery!.operationID
        let claimed = expectation(description: "Delivery owns the source claim")
        let release = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer { release.continuation.finish() }
        let delivery = try service { point in
            if case .sourceClaimed = point {
                claimed.fulfill()
                var iterator = release.stream.makeAsyncIterator()
                _ = await iterator.next()
            }
        }
        let owned = Task { try await delivery.drainOnce() }
        await fulfillment(of: [claimed], timeout: 3)
        let concurrent = try await delivery.drainOnce()
        XCTAssertTrue(concurrent.alreadyDraining)
        XCTAssertEqual(concurrent.scanned, 0)
        await delivery.shutdown()
        release.continuation.yield(())
        release.continuation.finish()
        do {
            _ = try await owned.value
            XCTFail("A shut down owner accepted its outstanding claim")
        } catch { XCTAssertTrue(error is CancellationError) }
        let heldClaim = try XCTUnwrap(app.store.continuityDelivery(operationID: operationID))
        XCTAssertEqual(heldClaim.state, .claimed)
        XCTAssertEqual(heldClaim.attempts, 1)
        XCTAssertNil(heldClaim.acceptanceReceiptSHA256)
        let unaccepted = try await app.projectContexts.repository.nonterminalAutonomousRuns()
        XCTAssertTrue(unaccepted.isEmpty)
        do {
            _ = try await delivery.drainOnce()
            XCTFail("A shut down owner restarted delivery")
        } catch { XCTAssertEqual(error as? AutonomyError, .shutdown) }
        clock.date = clock.date.addingTimeInterval(31)
        let restarted = try service()
        let recovered = try await restarted.drainOnce()
        XCTAssertEqual(recovered.accepted, 1)
        let runs = try await app.projectContexts.repository.nonterminalAutonomousRuns()
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.state, .awaitingBootstrap)
        XCTAssertEqual(try app.store.continuityDelivery(operationID: operationID)?.attempts, 2)
        await restarted.shutdown()
    }

    func testRevokedTaskIsInvalidatedWithoutBlockingIndependentDelivery() async throws {
        let revoked = try await commitTask()
        let valid = try await commitTask()
        let authority = revoked.commit.revision.authorization
        _ = try await app.projectContexts.repository.revokeContinuityTask(taskID: authority.taskID,
            projectID: authority.projectID, expectedGeneration: authority.projectGeneration)
        let delivery = try service()
        let report = try await delivery.drainOnce()
        XCTAssertEqual(report.invalidated, 1)
        XCTAssertEqual(report.accepted, 1)
        XCTAssertEqual(try app.store.continuityDelivery(operationID: revoked.commit.delivery!.operationID)?.state, .invalidated)
        XCTAssertEqual(try app.store.continuityDelivery(operationID: valid.commit.delivery!.operationID)?.state, .acknowledged)
        let runs = try await app.projectContexts.repository.nonterminalAutonomousRuns()
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.projectID, valid.commit.revision.authorization.projectID)
        await delivery.shutdown()
    }

    func testTwoDeliveryOwnersUseOneAcceptanceAndOneRun() async throws {
        let fixture = try await commitTask()
        let operationID = fixture.commit.delivery!.operationID
        let secondSource = try SQLiteStore(path: app.paths.storeSQLite, clock: clock)
        let secondRepository = try ProjectControlPlaneRepository(databaseURL: app.paths.controlPlaneSQLite, clock: clock)
        let first = try service()
        let second = try ContinuityIngressDeliveryService(source: secondSource,
            repository: secondRepository, config: ConfigStore(paths: app.paths))
        do {
            async let left = first.drainOnce()
            async let right = second.drainOnce()
            let reports = try await [left, right]
            XCTAssertEqual(reports.reduce(0) { $0 + $1.accepted }, 1)
            let runs = try await app.projectContexts.repository.nonterminalAutonomousRuns()
            XCTAssertEqual(runs.count, 1)
            XCTAssertEqual(runs.first?.state, .awaitingBootstrap)
            XCTAssertEqual(try app.store.continuityDelivery(operationID: operationID)?.state, .acknowledged)
        } catch {
            await first.shutdown()
            await second.shutdown()
            secondSource.close()
            await secondRepository.close()
            throw error
        }
        await first.shutdown()
        await second.shutdown()
        secondSource.close()
        await secondRepository.close()
    }

    func testInvalidationAfterClaimDoesNotAcceptOrBlockAnotherTask() async throws {
        let invalidated = try await commitTask()
        let independent = try await commitTask()
        let source = app.store
        let authority = invalidated.commit.revision.authorization
        let delivery = try service { point in
            if case .sourceClaimed = point {
                _ = try source.invalidateContinuityIngress(projectID: authority.projectID,
                    throughGeneration: authority.projectGeneration, taskID: authority.taskID)
            }
        }
        let report = try await delivery.drainOnce()
        XCTAssertEqual(report.accepted, 1)
        XCTAssertEqual(try app.store.continuityDelivery(operationID: invalidated.commit.delivery!.operationID)?.state, .invalidated)
        XCTAssertEqual(try app.store.continuityDelivery(operationID: independent.commit.delivery!.operationID)?.state, .acknowledged)
        let runs = try await app.projectContexts.repository.nonterminalAutonomousRuns()
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.projectID, independent.commit.revision.authorization.projectID)
        await delivery.shutdown()
    }
}
