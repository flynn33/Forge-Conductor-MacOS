import XCTest
@testable import ForgeConductorCore

final class ContinuityIngressDeliveryTests: XCTestCase {
    private var home: URL!
    private var app: ForgeApp!
    private var clock: FixedClock!

    override func setUpWithError() throws {
        if let childHome = ProcessInfo.processInfo.environment["FORGE_INGRESS_PROCESS_HOME"] {
            home = URL(fileURLWithPath: childHome)
        } else {
            home = FileManager.default.temporaryDirectory.appendingPathComponent("continuity-delivery-\(UUID())")
        }
        clock = FixedClock(Date(timeIntervalSince1970: 1_800_000_000))
        app = try ForgeApp.bootstrap(home: home, clock: clock)
        try setAutomaticDelivery(true)
    }

    override func tearDownWithError() throws {
        app?.shutdown()
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
        let projectRoot = home.appendingPathComponent(projectID.description, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        _ = try await repository.registerProjectUnchecked(projectID: projectID,
            displayName: "Delivery fixture", canonicalRoot: projectRoot)
        let owner = ProjectBindingOwner(kind: .mcpClient, id: "source-\(UUID())")
        let scope = ToolAuthorizationScope(canonicalRoots: [projectRoot], writableRoots: [],
            allowedTools: ["fs_read"], networkAllowed: false, maximumInlineOutputBytes: 4_096)
        let binding = try await repository.bind(owner: owner, projectID: projectID,
            generation: .initial, authorizationScope: scope)
        let context = binding.invocationContext(clientID: ClientID(owner.id))
        XCTAssertEqual(scope, binding.authorizationScope, "Approval must use the exact issued directory scope")
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

    func testSourceAndManagerIngressBoundariesSurviveSIGKILLWithoutDuplicateAcceptance() async throws {
        let environment = ProcessInfo.processInfo.environment
        if let boundary = environment["FORGE_INGRESS_PROCESS_BOUNDARY"] {
            let marker = URL(fileURLWithPath: try XCTUnwrap(environment["FORGE_INGRESS_PROCESS_READY"]))
            let fixture = try await commitTask()
            let operationID = try XCTUnwrap(fixture.commit.delivery).operationID
            let receipt = try JSONSerialization.data(withJSONObject: [
                "operation_id": operationID.uuidString,
                "handoff_id": fixture.commit.revision.identity.continuityID,
                "packet_sha256": fixture.commit.revision.identity.packetSHA256,
                "boundary": boundary,
            ], options: [.sortedKeys])
            if boundary == "sourceCommitted" {
                try await Self.awaitForcedTermination(marker: marker, receipt: receipt)
            } else {
                let delivery = try service { point in
                    let name: String
                    switch point {
                    case .sourceClaimed: name = "sourceClaimed"
                    case .acceptanceCommitted: name = "acceptanceCommitted"
                    }
                    if name == boundary {
                        try await Self.awaitForcedTermination(marker: marker, receipt: receipt)
                    }
                }
                _ = try await delivery.drainOnce()
                if boundary == "sourceAcknowledged" {
                    try await Self.awaitForcedTermination(marker: marker, receipt: receipt)
                }
            }
            XCTFail("Child passed its requested termination boundary")
            return
        }

        XCTAssertTrue(app.shutdown().completed)
        app = nil
        let reflectedName = NSStringFromClass(type(of: self))
        let methodName = String(#function.prefix { $0 != "(" })
        for boundary in ["sourceCommitted", "sourceClaimed", "acceptanceCommitted", "sourceAcknowledged"] {
            let fixtureHome = home.appendingPathComponent(boundary)
            let marker = home.appendingPathComponent("\(boundary)-ready.json")
            let child = try launchMigrationXCTestFixture(
                testIdentifier: "\(reflectedName)/\(methodName)", environment: [
                    "FORGE_INGRESS_PROCESS_HOME": fixtureHome.path,
                    "FORGE_INGRESS_PROCESS_BOUNDARY": boundary,
                    "FORGE_INGRESS_PROCESS_READY": marker.path,
                ])
            defer { child.close() }
            try waitForMigrationMarker(marker, child: child, timeout: 10)
            let terminated = try forceKillMigrationXCTestFixture(child, timeout: 2)
            XCTAssertEqual(terminated.reason, .uncaughtSignal, boundary)
            XCTAssertEqual(terminated.status, SIGKILL, boundary)
            let receipt = try JSONSupport.object(from: OwnerOnlyAtomicFile.read(from: marker, maximumBytes: 4_096))
            let rawOperation = try XCTUnwrap(receipt["operation_id"] as? String)
            let operationID = try XCTUnwrap(UUID(uuidString: rawOperation))
            // Only claimed deliveries need their persisted lease to expire.
            // The clock is injected; process death and database recovery are real.
            clock.date = Date(timeIntervalSince1970: 1_800_000_000)
            if boundary == "sourceClaimed" || boundary == "acceptanceCommitted" {
                clock.date = clock.date.addingTimeInterval(31)
            }
            app = try ForgeApp.bootstrap(home: fixtureHome, clock: clock)
            let source = try XCTUnwrap(app.store.continuityDelivery(operationID: operationID))
            XCTAssertEqual(source.handoff.identity.continuityID, receipt["handoff_id"] as? String)
            XCTAssertEqual(source.handoff.identity.packetSHA256, receipt["packet_sha256"] as? String)
            XCTAssertEqual(JSONSupport.sha256Hex(source.handoff.canonicalPacketJSON), source.handoff.identity.packetSHA256)
            let before = try await app.projectContexts.repository.nonterminalAutonomousRuns()
            XCTAssertEqual(before.count,
                boundary == "acceptanceCommitted" || boundary == "sourceAcknowledged" ? 1 : 0, boundary)
            XCTAssertEqual(source.state, boundary == "sourceCommitted" ? .pending
                : boundary == "sourceAcknowledged" ? .acknowledged : .claimed, boundary)
            let manager = ManagerNode(app: app)
            _ = try manager.recoverManagedAutonomy()
            let delivered = try await manager.drainContinuityIngressOnce()
            XCTAssertEqual(delivered.accepted, boundary == "sourceAcknowledged" ? 0 : 1, boundary)
            let recovered = try await app.projectContexts.repository.nonterminalAutonomousRuns()
            XCTAssertEqual(recovered.count, 1, boundary)
            let run = try XCTUnwrap(recovered.first)
            if let prior = before.first { XCTAssertEqual(run.runID, prior.runID, boundary) }
            XCTAssertEqual(run.state, .awaitingBootstrap)
            XCTAssertNil(run.activeSessionID)
            let sessions = try await app.projectContexts.repository.providerSessions(operationID: operationID)
            XCTAssertTrue(sessions.isEmpty, boundary)
            let accepted = try XCTUnwrap(app.store.continuityDelivery(operationID: operationID))
            XCTAssertEqual(accepted.state, .acknowledged)
            XCTAssertEqual(accepted.handoff, source.handoff)
            XCTAssertNotNil(accepted.acceptanceReceiptSHA256)
            let repeated = try await manager.drainContinuityIngressOnce()
            XCTAssertEqual(repeated.accepted, 0)
            let repeatedRuns = try await app.projectContexts.repository.nonterminalAutonomousRuns()
            XCTAssertEqual(repeatedRuns.map(\.runID), [run.runID])
            let evidence = try JSONSerialization.data(withJSONObject: [
                "boundary": boundary, "child_pid": child.process.processIdentifier,
                "termination_signal": terminated.status, "operation_id": rawOperation,
                "run_id": run.runID.description, "source_packet_sha256": source.handoff.identity.packetSHA256,
                "runs_before_recovery": before.count, "runs_after_recovery": recovered.count,
                "accepted_by_recovery": delivered.accepted, "accepted_by_repeated_drain": repeated.accepted,
                "provider_sessions": sessions.count, "source_state": accepted.state.rawValue,
                "source_payload_unchanged": accepted.handoff == source.handoff,
                "lease_clock_advance_seconds": boundary == "sourceClaimed" || boundary == "acceptanceCommitted" ? 31 : 0,
                "gate_approval": false,
            ], options: [.sortedKeys])
            #if !SWIFT_PACKAGE
            let attachment = XCTAttachment(data: evidence, uniformTypeIdentifier: "public.json")
            attachment.name = "ingress-\(boundary)-effects.json"
            attachment.lifetime = .keepAlways
            add(attachment)
            #else
            XCTAssertLessThan(evidence.count, 4_096)
            #endif
            print("Ingress SIGKILL proof: boundary=\(boundary) child=\(child.process.processIdentifier) signal=\(terminated.status) operation=\(rawOperation) run=\(run.runID) source_sha256=\(source.handoff.identity.packetSHA256) accepted_runs=1 provider_sessions=0")
            XCTAssertTrue(manager.shutdownManagedAutonomy())
            XCTAssertTrue(app.shutdown().completed)
            app = nil
        }
    }

    private static func awaitForcedTermination(marker: URL, receipt: Data) async throws {
        try OwnerOnlyAtomicFile.write(receipt, to: marker)
        try await Task.sleep(nanoseconds: 20_000_000_000)
        XCTFail("Parent did not terminate the child within the bounded wait")
        throw ContinuityIngressDeliveryInterruption.simulatedExit
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
