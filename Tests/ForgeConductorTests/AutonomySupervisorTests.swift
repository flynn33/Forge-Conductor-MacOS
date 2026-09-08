// AutonomySupervisorTests.swift
// Verifies durable run transitions, lease fencing, tool replay, completion, and startup recovery.

import XCTest
@testable import ForgeConductorCore

final class AutonomySupervisorTests: XCTestCase {
    func testSourceRecoveryAlternatesWithOrdinaryWorkInTheSameCapacity() async throws {
        try await withRepository { repository, root in
            let ordinary = try await makeRun(repository: repository, root: root)
            let held = try await makeBootstrapHeldApplicationRun(repository: repository, root: root)
            let nextHeld = try await makeBootstrapHeldApplicationRun(repository: repository, root: root)
            let first = sourceReference(held.run, rowID: 1)
            let second = sourceReference(nextHeld.run, rowID: 2)
            let discovery = SourceSchedulingFixture(references: [first, second])
            let ordinaryCoordinator = DelayedStopCoordinator(runID: ordinary.run.runID)
            let firstCoordinator = DelayedStopCoordinator(runID: first.runID)
            let secondCoordinator = DelayedStopCoordinator(runID: second.runID)
            let supervisor = try AutonomySupervisor(repository: repository, maximumConcurrentRuns: 1,
                sourceBootstrap: SourceBootstrapScheduling(discover: { try await discovery.discover($0, limit: $1) },
                    admit: { try await discovery.admit($0) }, makeCoordinator: {
                        $0 == first ? firstCoordinator : secondCoordinator
                    })) { _ in ordinaryCoordinator }
            do {
                let report = try await supervisor.recoverOnManagerStart()
                XCTAssertEqual(report.activatedRuns, [first.runID])
                XCTAssertEqual(Set(report.deferredRuns), [ordinary.run.runID, second.runID])
                await assertAutonomyError(code: "autonomous_run_bootstrap_required") {
                    try await supervisor.activate(runID: first.runID)
                }
                try await supervisor.quiesce(runID: first.runID)
                var snapshot = await supervisor.snapshot()
                XCTAssertEqual(snapshot.activeRunIDs, [ordinary.run.runID])
                XCTAssertEqual(snapshot.deferredRunIDs, [second.runID])
                try await supervisor.quiesce(runID: ordinary.run.runID)
                snapshot = await supervisor.snapshot()
                XCTAssertEqual(snapshot.activeRunIDs, [second.runID])
                XCTAssertTrue(snapshot.deferredRunIDs.isEmpty)
                let firstAdmissions = await discovery.admissionCount(first.rowID)
                XCTAssertEqual(firstAdmissions, 2, "Discovery and dispatch require separate live admission")
                let retained = try await repository.autonomousRun(first.runID)
                XCTAssertEqual(retained?.state, .awaitingBootstrap)
                XCTAssertNil(retained?.activeSessionID)
            } catch { await supervisor.shutdown(); throw error }
            await supervisor.shutdown()
            let cleaned = await secondCoordinator.hasFinishedCleanup()
            XCTAssertTrue(cleaned)
        }
    }

    func testSourceCursorAdvancesPastMalformedAndDisabledReferences() async throws {
        try await withRepository { repository, root in
            let held = try await makeBootstrapHeldApplicationRun(repository: repository, root: root)
            let valid = sourceReference(held.run, rowID: 17)
            let invalid = (1...16).map { sourceReference(held.run, rowID: Int64($0), runID: RunID()) }
            let discovery = SourceSchedulingFixture(references: invalid + [valid],
                failedRows: Set(1...8), disabledRows: Set(9...16))
            let coordinator = DelayedStopCoordinator(runID: held.run.runID)
            let supervisor = try AutonomySupervisor(repository: repository, maximumConcurrentRuns: 1,
                sourceBootstrap: SourceBootstrapScheduling(discover: { try await discovery.discover($0, limit: $1) },
                    admit: { try await discovery.admit($0) }, makeCoordinator: { reference in
                        XCTAssertEqual(reference, valid)
                        return coordinator
                    })) { _ in XCTFail("Held source reached ordinary factory"); return coordinator }
            do {
                let report = try await supervisor.recoverOnManagerStart()
                XCTAssertTrue(report.activatedRuns.isEmpty)
                try await supervisor.tick()
                let snapshot = await supervisor.snapshot()
                XCTAssertEqual(snapshot.activeRunIDs, [valid.runID])
                let cursors = await discovery.scannedCursors()
                XCTAssertEqual(cursors, [nil, 16])
                try await supervisor.tick()
                let wrapped = await discovery.scannedCursors()
                XCTAssertEqual(wrapped, [nil, 16, nil])
            } catch { await supervisor.shutdown(); throw error }
            await supervisor.shutdown()
        }
    }

    func testSourceAdmissionIsRevalidatedBeforeFactoryAndRejectedPeerDoesNotBlock() async throws {
        try await withRepository { repository, root in
            let held = try await makeBootstrapHeldApplicationRun(repository: repository, root: root)
            let revoked = sourceReference(held.run, rowID: 1, runID: RunID())
            let unavailable = sourceReference(held.run, rowID: 2, runID: RunID())
            let valid = sourceReference(held.run, rowID: 3)
            let discovery = SourceSchedulingFixture(references: [revoked, unavailable, valid], revokeAfterDiscovery: [1])
            let coordinator = DelayedStopCoordinator(runID: valid.runID)
            let supervisor = try AutonomySupervisor(repository: repository, maximumConcurrentRuns: 1,
                sourceBootstrap: SourceBootstrapScheduling(discover: { try await discovery.discover($0, limit: $1) },
                    admit: { try await discovery.admit($0) }, makeCoordinator: { reference in
                        if reference == unavailable { throw ContinuityRunError.hostCapabilityUnavailable }
                        XCTAssertEqual(reference, valid)
                        return coordinator
                    })) { _ in XCTFail("Held source reached ordinary factory"); return coordinator }
            do {
                let report = try await supervisor.recoverOnManagerStart()
                XCTAssertEqual(report.activatedRuns, [valid.runID])
                XCTAssertTrue(report.deferredRuns.isEmpty)
                let rejectedAdmissions = await discovery.admissionCount(1)
                XCTAssertEqual(rejectedAdmissions, 2)
            } catch { await supervisor.shutdown(); throw error }
            await supervisor.shutdown()
        }
    }

    func testQuiesceInvalidatesSuspendedSourceAdmissionWithoutConstructingCoordinator() async throws {
        try await withRepository { repository, root in
            let held = try await makeBootstrapHeldApplicationRun(repository: repository, root: root)
            let reference = sourceReference(held.run, rowID: 1)
            let barrier = SourceAdmissionBarrier()
            let coordinator = DelayedStopCoordinator(runID: reference.runID)
            let supervisor = try AutonomySupervisor(repository: repository, maximumConcurrentRuns: 1,
                sourceBootstrap: SourceBootstrapScheduling(discover: { _, _ in
                    ContinuityBootstrapRecoveryPage(references: [reference], diagnostics: [], nextRowID: nil)
                }, admit: { _ in await barrier.admit() }, makeCoordinator: { _ in
                    XCTFail("Quiesced source reached coordinator construction")
                    return coordinator
                })) { _ in XCTFail("Held source reached ordinary factory"); return coordinator }
            let recovery = Task { try await supervisor.recoverOnManagerStart() }
            for _ in 0..<2_000 {
                if await barrier.isWaiting() { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            let waiting = await barrier.isWaiting()
            XCTAssertTrue(waiting)
            try await supervisor.quiesce(runID: reference.runID)
            await barrier.release()
            let report = try await recovery.value
            XCTAssertTrue(report.activatedRuns.isEmpty)
            let snapshot = await supervisor.snapshot()
            XCTAssertTrue(snapshot.activeRunIDs.isEmpty)
            XCTAssertTrue(snapshot.deferredRunIDs.isEmpty)
            await supervisor.shutdown()
        }
    }

    func testSourceDiscoveryUsesOneBoundedDeferredQueueAndShutdownClearsIt() async throws {
        try await withRepository { repository, root in
            let ordinary = try await makeRun(repository: repository, root: root)
            let references = (1...1_100).map { sourceReference(ordinary.run, rowID: Int64($0), runID: RunID()) }
            let discovery = SourceSchedulingFixture(references: references, enabled: false)
            let coordinator = DelayedStopCoordinator(runID: ordinary.run.runID)
            let supervisor = try AutonomySupervisor(repository: repository, maximumConcurrentRuns: 1,
                sourceBootstrap: SourceBootstrapScheduling(discover: { try await discovery.discover($0, limit: $1) },
                    admit: { try await discovery.admit($0) }, makeCoordinator: { _ in
                        XCTFail("Source coordinator exceeded shared capacity")
                        return coordinator
                    })) { _ in coordinator }
            do {
                _ = try await supervisor.recoverOnManagerStart()
                await discovery.enable()
                for _ in 0..<70 { try await supervisor.tick() }
                let snapshot = await supervisor.snapshot()
                XCTAssertEqual(snapshot.activeRunIDs, [ordinary.run.runID])
                XCTAssertEqual(snapshot.deferredRunIDs.count, AutonomySupervisor.maximumRecoveredRuns)
                XCTAssertEqual(Set(snapshot.deferredRunIDs).count, snapshot.deferredRunIDs.count)
                let limits = await discovery.requestedLimits()
                XCTAssertTrue(limits.allSatisfy { $0 == AutonomySupervisor.sourceDiscoveryLimit })
            } catch { await supervisor.shutdown(); throw error }
            await supervisor.shutdown()
            let stopped = await supervisor.snapshot()
            XCTAssertTrue(stopped.activeRunIDs.isEmpty)
            XCTAssertTrue(stopped.deferredRunIDs.isEmpty)
        }
    }

    func testShutdownInvalidatesSuspendedSourceAdmissionAndStartupReceipt() async throws {
        try await withRepository { repository, root in
            let held = try await makeBootstrapHeldApplicationRun(repository: repository, root: root)
            let reference = sourceReference(held.run, rowID: 1)
            let barrier = SourceAdmissionBarrier()
            let coordinator = DelayedStopCoordinator(runID: reference.runID)
            let supervisor = try AutonomySupervisor(repository: repository, maximumConcurrentRuns: 1,
                sourceBootstrap: SourceBootstrapScheduling(discover: { _, _ in
                    ContinuityBootstrapRecoveryPage(references: [reference], diagnostics: [], nextRowID: nil)
                }, admit: { _ in await barrier.admit() }, makeCoordinator: { _ in
                    XCTFail("Stopped source reached coordinator construction")
                    return coordinator
                })) { _ in XCTFail("Held source reached ordinary factory"); return coordinator }
            let recovery = Task { try await supervisor.recoverOnManagerStart() }
            for _ in 0..<2_000 {
                if await barrier.isWaiting() { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            let waiting = await barrier.isWaiting()
            XCTAssertTrue(waiting)
            await supervisor.shutdown()
            await barrier.release()
            do { _ = try await recovery.value; XCTFail("Startup returned success after shutdown") }
            catch { XCTAssertEqual(error as? AutonomyError, .shutdown) }
            let snapshot = await supervisor.snapshot()
            XCTAssertFalse(snapshot.acceptingRuns)
            XCTAssertTrue(snapshot.activeRunIDs.isEmpty)
            XCTAssertTrue(snapshot.deferredRunIDs.isEmpty)
        }
    }

    private func sourceReference(_ run: AutonomousRunRecord, rowID: Int64, runID: RunID? = nil) -> ContinuityBootstrapRecoveryReference {
        ContinuityBootstrapRecoveryReference(rowID: rowID, operationID: run.activeOperationID ?? UUID(),
            runID: runID ?? run.runID, projectID: run.projectID, projectGeneration: run.projectGeneration,
            taskID: UUID(), receiptSHA256: JSONSupport.sha256Hex("scheduler fixture \(rowID)"))
    }

    func testHeldIngressNeverEntersDeferredQueueWhileOrdinaryRunUsesCapacity() async throws {
        try await withRepository { repository, root in
            let ordinary = try await makeRun(repository: repository, root: root)
            let coordinator = DelayedStopCoordinator(runID: ordinary.run.runID)
            let supervisor = try AutonomySupervisor(repository: repository, maximumConcurrentRuns: 1) { runID in
                XCTAssertEqual(runID, ordinary.run.runID)
                return coordinator
            }
            do {
                let startup = try await supervisor.recoverOnManagerStart()
                XCTAssertEqual(startup.activatedRuns, [ordinary.run.runID])
                let held = try await makeBootstrapHeldApplicationRun(repository: repository, root: root)
                await assertAutonomyError(code: "autonomous_run_bootstrap_required") {
                    try await supervisor.activate(runID: held.run.runID)
                }
                try await supervisor.tick()
                let busy = await supervisor.snapshot()
                XCTAssertEqual(busy.activeRunIDs, [ordinary.run.runID])
                XCTAssertTrue(busy.deferredRunIDs.isEmpty)
                try await supervisor.quiesce(runID: ordinary.run.runID)
                let afterCapacityReleased = await supervisor.snapshot()
                XCTAssertTrue(afterCapacityReleased.activeRunIDs.isEmpty)
                XCTAssertTrue(afterCapacityReleased.deferredRunIDs.isEmpty)
                let retained = try await repository.autonomousRun(held.run.runID)
                XCTAssertEqual(retained?.state, .awaitingBootstrap)
                XCTAssertNil(retained?.activeSessionID)
            } catch {
                await supervisor.shutdown()
                throw error
            }
            await supervisor.shutdown()
        }
    }

    func testHeldIngressIsExcludedFromRecoveryTickAndExplicitActivation() async throws {
        try await withRepository { repository, root in
            let fixture = try await makeBootstrapHeldApplicationRun(repository: repository, root: root)
            let coordinator = DelayedStopCoordinator(runID: fixture.run.runID)
            let supervisor = try AutonomySupervisor(repository: repository, maximumConcurrentRuns: 1) { _ in
                XCTFail("Bootstrap-held run reached ordinary coordinator construction")
                return coordinator
            }
            do {
                for _ in 0..<2 {
                    let report = try await supervisor.recoverOnManagerStart()
                    XCTAssertEqual(report.discoveredRuns, 1)
                    XCTAssertTrue(report.activatedRuns.isEmpty)
                    XCTAssertTrue(report.deferredRuns.isEmpty)
                    try await supervisor.tick()
                    await assertAutonomyError(code: "autonomous_run_bootstrap_required") {
                        try await supervisor.activate(runID: fixture.run.runID)
                    }
                    let snapshot = await supervisor.snapshot()
                    XCTAssertTrue(snapshot.activeRunIDs.isEmpty)
                    XCTAssertTrue(snapshot.deferredRunIDs.isEmpty)
                    await supervisor.shutdown()
                }
                let started = await coordinator.hasStarted()
                XCTAssertFalse(started)
                let retained = try await repository.autonomousRun(fixture.run.runID)
                XCTAssertEqual(retained?.state, .awaitingBootstrap)
                XCTAssertNil(retained?.activeSessionID)
            } catch {
                await supervisor.shutdown()
                throw error
            }
        }
    }

    func testLeaseFencesDuplicateOwnerAndStaleEpochAfterRecovery() async throws {
        let clock = MutableAutonomyClock(Date(timeIntervalSince1970: 1_000))
        try await withRepository(clock: clock) { repository, root in
            let fixture = try await makeRun(repository: repository, root: root)
            let first = try await repository.acquireRunLease(
                runID: fixture.run.runID,
                ownerID: "manager-a",
                policy: fixture.leasePolicy
            )
            await assertAutonomyError(code: "autonomous_run_lease_conflict") {
                _ = try await repository.acquireRunLease(
                    runID: fixture.run.runID,
                    ownerID: "manager-b",
                    policy: fixture.leasePolicy
                )
            }
            let storedRun = try await repository.autonomousRun(fixture.run.runID)
            var run = try XCTUnwrap(storedRun)
            run = try await repository.transitionAutonomousRun(
                runID: run.runID,
                lease: first,
                transition: transition(run, to: .validating)
            )
            XCTAssertEqual(run.state, .validating)

            clock.advance(by: 31)
            let second = try await repository.acquireRunLease(
                runID: run.runID,
                ownerID: "manager-b",
                policy: fixture.leasePolicy
            )
            XCTAssertEqual(second.epoch, first.epoch + 1)
            await assertAutonomyError(code: "autonomous_run_lease_stale") {
                _ = try await repository.transitionAutonomousRun(
                    runID: run.runID,
                    lease: first,
                    transition: self.transition(run, to: .ready)
                )
            }
            let renewed = try await repository.renewRunLease(second, policy: fixture.leasePolicy)
            XCTAssertEqual(renewed.epoch, second.epoch)
            run = try await repository.transitionAutonomousRun(
                runID: run.runID,
                lease: renewed,
                transition: transition(run, to: .ready)
            )
            XCTAssertEqual(run.revision, 2)
            let events = try await repository.autonomyEvents(runID: run.runID)
            XCTAssertTrue(events.contains { $0.eventType == "run_lease_acquired" })
            XCTAssertTrue(events.contains { $0.eventType == "test_transition" })
        }
    }

    func testToolBrokerAcceptsWildcardAndReusesCompletedIdempotentResult() async throws {
        try await withRepository { repository, root in
            let fixture = try await makeRun(repository: repository, root: root, allowedTools: ["*"])
            let lease = try await repository.acquireRunLease(
                runID: fixture.run.runID,
                ownerID: "manager-tools",
                policy: fixture.leasePolicy
            )
            let sessionID = "session-tools"
            try await repository.reserveProviderSession(
                ProviderSessionIntent(
                    sessionID: sessionID,
                    runID: fixture.run.runID,
                    projectID: fixture.run.projectID,
                    projectGeneration: fixture.run.projectGeneration,
                    providerID: "lmstudio",
                    adapterID: "lmstudio-rest",
                    modelKey: "fixture-model",
                    providerResponseID: "resp-root",
                    idempotencyKey: "session-tools-key"
                ),
                lease: lease
            )
            let turn = ProviderTurnIntent(
                runID: fixture.run.runID,
                sessionID: sessionID,
                projectID: fixture.run.projectID,
                projectGeneration: fixture.run.projectGeneration,
                kind: .normalContinuation,
                idempotencyKey: "turn-tools-key",
                previousResponseID: "resp-root",
                inputSHA256: String(repeating: "a", count: 64)
            )
            _ = try await repository.persistProviderTurnIntent(turn, lease: lease)
            let context = try await repository.invocationContext(
                for: ProjectBindingOwner(kind: .providerSession, id: sessionID),
                clientID: ClientID("provider-tools")
            )
            let executor = CountingToolExecutor()
            let broker = ToolInvocationBroker(
                repository: repository,
                executor: executor,
                classifier: StaticToolReplayClassifier(classifications: [
                    "fixture.upsert": .idempotent,
                ])
            )
            let call = BrokeredToolCall(
                providerCallID: "call-1",
                toolName: "fixture.upsert",
                arguments: ["value": "same"],
                idempotencyKey: "upsert-key"
            )
            let first = try await broker.invoke(call, turnID: turn.turnID, context: context, lease: lease)
            let second = try await broker.invoke(call, turnID: turn.turnID, context: context, lease: lease)
            XCTAssertTrue(first.ok)
            XCTAssertEqual(second.payload["value"] as? String, "same")
            XCTAssertEqual(executor.callCount, 1)
            let storedValue = try await repository.toolInvocation(
                sessionID: sessionID,
                providerCallID: "call-1"
            )
            let stored = try XCTUnwrap(storedValue)
            XCTAssertEqual(stored.state, .completed)
            XCTAssertEqual(stored.replayClass, .idempotent)

            let missing = BrokeredToolCall(
                providerCallID: "call-2",
                toolName: "fixture.unclassified",
                arguments: [:]
            )
            await assertAutonomyError(code: "tool_replay_classification_required") {
                _ = try await broker.invoke(
                    missing,
                    turnID: turn.turnID,
                    context: context,
                    lease: lease
                )
            }
        }
    }

    func testProductionClassifierRequiresExactRegisteredToolCoverage() throws {
        XCTAssertNoThrow(try StaticToolReplayClassifier(
            productionToolNames: ["read", "write"],
            classifications: ["read": .readOnly, "write": .idempotent]
        ))
        XCTAssertThrowsError(try StaticToolReplayClassifier(
            productionToolNames: ["read", "write"],
            classifications: ["read": .readOnly]
        ))
        XCTAssertThrowsError(try StaticToolReplayClassifier(
            productionToolNames: ["read"],
            classifications: ["read": .readOnly, "retired": .nonReplayable]
        ))
    }

    func testDeleteGrantAdmitsAdditiveRecoveryThroughBroker() async throws {
        try await withRepository { repository, root in
            let fixture = try await makeRun(
                repository: repository,
                root: root,
                allowedTools: ["fs_delete"]
            )
            let lease = try await repository.acquireRunLease(
                runID: fixture.run.runID,
                ownerID: "manager-delete-recovery-admission",
                policy: fixture.leasePolicy
            )
            let toolFixture = try await makeProviderToolContext(
                repository: repository,
                run: fixture.run,
                lease: lease,
                sessionID: "session-delete-recovery-admission"
            )
            let executor = RecoveryToolExecutor(interruptAfterDispatch: false)
            let broker = ToolInvocationBroker(
                repository: repository,
                executor: executor,
                classifier: StaticToolReplayClassifier(classifications: [
                    "fs_delete_recovery": .reconciled,
                ])
            )

            let result = try await broker.invoke(
                BrokeredToolCall(
                    providerCallID: "call-delete-recovery-admission",
                    toolName: "fs_delete_recovery",
                    arguments: [
                        "transaction_id": UUID().uuidString.lowercased(),
                        "action": "query",
                    ]
                ),
                turnID: toolFixture.turn.turnID,
                context: toolFixture.context,
                lease: lease
            )

            XCTAssertTrue(result.ok)
            XCTAssertEqual(result.payload["action"] as? String, "query")
            XCTAssertEqual(executor.callCount, 1)
        }
    }

    func testInterruptedRecoveryActionsRemainAmbiguousAndNeverReplayUnresolved() async throws {
        try await withRepository { repository, root in
            let fixture = try await makeRun(
                repository: repository,
                root: root,
                allowedTools: ["fs_delete"]
            )
            let lease = try await repository.acquireRunLease(
                runID: fixture.run.runID,
                ownerID: "manager-delete-recovery-replay",
                policy: fixture.leasePolicy
            )
            let toolFixture = try await makeProviderToolContext(
                repository: repository,
                run: fixture.run,
                lease: lease,
                sessionID: "session-delete-recovery-replay"
            )
            let executor = RecoveryToolExecutor(interruptAfterDispatch: true)
            let broker = ToolInvocationBroker(
                repository: repository,
                executor: executor,
                classifier: StaticToolReplayClassifier(classifications: [
                    "fs_delete_recovery": .reconciled,
                ])
            )

            for action in ["query", "resume", "acknowledge"] {
                let call = BrokeredToolCall(
                    providerCallID: "call-delete-recovery-\(action)",
                    toolName: "fs_delete_recovery",
                    arguments: [
                        "transaction_id": UUID().uuidString.lowercased(),
                        "action": action,
                    ]
                )
                do {
                    _ = try await broker.invoke(
                        call,
                        turnID: toolFixture.turn.turnID,
                        context: toolFixture.context,
                        lease: lease
                    )
                    XCTFail("Expected the injected recovery interruption for \(action)")
                } catch RecoveryToolExecutor.Interruption.afterDispatch {
                    // The durable invocation is now ambiguous and cannot be replayed.
                }

                let afterFirstDispatch = executor.callCount
                await assertAutonomyError(code: "tool_replay_blocked") {
                    _ = try await broker.invoke(
                        call,
                        turnID: toolFixture.turn.turnID,
                        context: toolFixture.context,
                        lease: lease
                    )
                }
                XCTAssertEqual(executor.callCount, afterFirstDispatch, action)

                let storedValue = try await repository.toolInvocation(
                    sessionID: toolFixture.context.providerSessionID ?? "",
                    providerCallID: call.providerCallID
                )
                XCTAssertEqual(try XCTUnwrap(storedValue).state, .ambiguous, action)
            }
            XCTAssertEqual(executor.callCount, 3)
        }
    }

    func testInterruptedProtectedDeleteNeverReconcilesFromPathnameAbsence() async throws {
        try await withRepository { repository, root in
            let fixture = try await makeRun(
                repository: repository,
                root: root,
                allowedTools: ["fs_delete"]
            )
            let projectRoot = root.appendingPathComponent("project", isDirectory: true)
            try FileManager.default.createDirectory(
                at: projectRoot,
                withIntermediateDirectories: true
            )
            let target = projectRoot.appendingPathComponent("protected-delete.txt")
            try Data("protected\n".utf8).write(to: target)
            let lease = try await repository.acquireRunLease(
                runID: fixture.run.runID,
                ownerID: "manager-protected-delete-reconcile",
                policy: fixture.leasePolicy
            )
            let toolFixture = try await makeProviderToolContext(
                repository: repository,
                run: fixture.run,
                lease: lease,
                sessionID: "session-protected-delete-reconcile"
            )
            let paths = AppPaths(home: root.appendingPathComponent("memory-home"))
            try paths.ensureLayout()
            let memory = ProjectMemoryService(paths: paths)
            defer { memory.closeAll() }
            let runtimeJobs = try RuntimeJobRepository(
                databaseURL: root.appendingPathComponent("runtime-jobs.sqlite3")
            )
            let executor = InterruptingFilesystemDeleteExecutor()
            let reconciler = ProductionToolInvocationReconciler(
                controlPlane: repository,
                runtimeJobs: runtimeJobs,
                memory: memory
            )
            let classifier = StaticToolReplayClassifier(classifications: [
                "fs_delete": .reconciled,
            ])
            let call = BrokeredToolCall(
                providerCallID: "call-protected-delete-reconcile",
                toolName: "fs_delete",
                arguments: ["path": target.path]
            )
            let broker = ToolInvocationBroker(
                repository: repository,
                executor: executor,
                classifier: classifier,
                reconciler: reconciler
            )

            do {
                _ = try await broker.invoke(
                    call,
                    turnID: toolFixture.turn.turnID,
                    context: toolFixture.context,
                    lease: lease
                )
                XCTFail("Expected the injected delete interruption")
            } catch InterruptingFilesystemDeleteExecutor.Interruption.afterEffect {
                // The protected path disappeared, but no durable broker result exists.
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
            XCTAssertEqual(executor.callCount, 1)

            let replayBroker = ToolInvocationBroker(
                repository: repository,
                executor: executor,
                classifier: classifier,
                reconciler: reconciler
            )
            await assertAutonomyError(code: "tool_replay_blocked") {
                _ = try await replayBroker.invoke(
                    call,
                    turnID: toolFixture.turn.turnID,
                    context: toolFixture.context,
                    lease: lease
                )
            }
            XCTAssertEqual(executor.callCount, 1)
            let stored = try await repository.toolInvocation(
                sessionID: toolFixture.context.providerSessionID ?? "",
                providerCallID: call.providerCallID
            )
            XCTAssertEqual(try XCTUnwrap(stored).state, .ambiguous)
            await runtimeJobs.close()
        }
    }

    func testProductionReconcilerCompletesInterruptedFilesystemEditWithoutRepeatingIt() async throws {
        try await withRepository { repository, root in
            let fixture = try await makeRun(
                repository: repository,
                root: root,
                allowedTools: ["fs_edit"]
            )
            let projectRoot = root.appendingPathComponent("project", isDirectory: true)
            try FileManager.default.createDirectory(
                at: projectRoot,
                withIntermediateDirectories: true
            )
            let lease = try await repository.acquireRunLease(
                runID: fixture.run.runID,
                ownerID: "manager-filesystem-reconcile",
                policy: fixture.leasePolicy
            )
            let toolFixture = try await makeProviderToolContext(
                repository: repository,
                run: fixture.run,
                lease: lease,
                sessionID: "session-filesystem-reconcile"
            )
            let target = projectRoot.appendingPathComponent("reconciled.txt")
            try "before value\n".write(to: target, atomically: true, encoding: .utf8)

            let paths = AppPaths(home: root.appendingPathComponent("memory-home"))
            try paths.ensureLayout()
            let memory = ProjectMemoryService(paths: paths)
            defer { memory.closeAll() }
            let runtimeJobs = try RuntimeJobRepository(
                databaseURL: root.appendingPathComponent("control-plane.sqlite3")
            )
            let executor = InterruptingFilesystemEditExecutor()
            let broker = ToolInvocationBroker(
                repository: repository,
                executor: executor,
                classifier: StaticToolReplayClassifier(classifications: [
                    "fs_edit": .reconciled,
                ]),
                reconciler: ProductionToolInvocationReconciler(
                    controlPlane: repository,
                    runtimeJobs: runtimeJobs,
                    memory: memory
                )
            )
            let call = BrokeredToolCall(
                providerCallID: "call-filesystem-reconcile",
                toolName: "fs_edit",
                arguments: [
                    "path": target.path,
                    "old": "before",
                    "new": "after",
                ]
            )

            do {
                _ = try await broker.invoke(
                    call,
                    turnID: toolFixture.turn.turnID,
                    context: toolFixture.context,
                    lease: lease
                )
                XCTFail("Expected the injected interruption")
            } catch InterruptingFilesystemEditExecutor.Interruption.afterEffect {
                // The write completed, but the executor returned no durable result.
            }
            XCTAssertEqual(
                try String(contentsOf: target, encoding: .utf8),
                "after value\n"
            )
            let ambiguousValue = try await repository.toolInvocation(
                sessionID: toolFixture.context.providerSessionID ?? "",
                providerCallID: call.providerCallID
            )
            let ambiguous = try XCTUnwrap(ambiguousValue)
            XCTAssertEqual(ambiguous.state, .ambiguous)
            XCTAssertNotNil(ambiguous.reconciliationDescriptor)

            let replayBroker = ToolInvocationBroker(
                repository: repository,
                executor: executor,
                classifier: StaticToolReplayClassifier(classifications: [
                    "fs_edit": .reconciled,
                ]),
                reconciler: ProductionToolInvocationReconciler(
                    controlPlane: repository,
                    runtimeJobs: runtimeJobs,
                    memory: memory
                )
            )
            let reconciled = try await replayBroker.invoke(
                call,
                turnID: toolFixture.turn.turnID,
                context: toolFixture.context,
                lease: lease
            )
            XCTAssertTrue(reconciled.ok)
            XCTAssertEqual(reconciled.payload["path"] as? String, target.path)
            XCTAssertEqual(executor.callCount, 1)
            let completedValue = try await repository.toolInvocation(
                sessionID: toolFixture.context.providerSessionID ?? "",
                providerCallID: call.providerCallID
            )
            XCTAssertEqual(try XCTUnwrap(completedValue).state, .completed)
            await runtimeJobs.close()
        }
    }

    func testProductionReconcilerUsesRuntimeIdempotencyReceiptWithoutResubmission() async throws {
        try await withRepository { repository, root in
            let fixture = try await makeRun(
                repository: repository,
                root: root,
                allowedTools: ["shell.run"]
            )
            let projectRoot = root.appendingPathComponent("project", isDirectory: true)
            try FileManager.default.createDirectory(
                at: projectRoot,
                withIntermediateDirectories: true
            )
            let lease = try await repository.acquireRunLease(
                runID: fixture.run.runID,
                ownerID: "manager-runtime-reconcile",
                policy: fixture.leasePolicy
            )
            let toolFixture = try await makeProviderToolContext(
                repository: repository,
                run: fixture.run,
                lease: lease,
                sessionID: "session-runtime-reconcile"
            )
            let runtimeJobs = try RuntimeJobRepository(
                databaseURL: root.appendingPathComponent("control-plane.sqlite3")
            )
            let jobKey = "runtime-reconcile-job"
            let jobID = UUID()
            _ = try await runtimeJobs.createJob(
                jobID: jobID,
                request: RuntimeJobRequest(
                    kind: .shell,
                    profile: .zshNoProfile,
                    context: toolFixture.context,
                    script: "exit 0",
                    canonicalWorkingDirectory: projectRoot,
                    timeout: .seconds(5),
                    replayClass: .reconciled,
                    idempotencyKey: jobKey
                ),
                commandSummary: "zsh -f fixture",
                timeoutSeconds: 5,
                requestArtifactRelativePath: nil
            )
            let providerArguments: [String: Any] = [
                "script": "exit 0",
                "cwd": projectRoot.path,
            ]
            var durableArguments = providerArguments
            durableArguments["idempotency_key"] = jobKey
            let seeded = try await repository.persistToolInvocationIntent(
                ToolInvocationIntent(
                    turnID: toolFixture.turn.turnID,
                    runID: fixture.run.runID,
                    sessionID: toolFixture.context.providerSessionID ?? "",
                    projectID: fixture.run.projectID,
                    projectGeneration: fixture.run.projectGeneration,
                    providerCallID: "call-runtime-reconcile",
                    toolName: "shell.run",
                    replayClass: .reconciled,
                    idempotencyKey: jobKey,
                    argumentsSHA256: JSONSupport.sha256Hex(
                        try JSONSupport.canonicalJSON(durableArguments)
                    )
                ),
                lease: lease
            )
            _ = try await repository.transitionToolInvocation(
                invocationID: seeded.invocationID,
                expected: .intent,
                to: .executing,
                lease: lease
            )
            _ = try await repository.transitionToolInvocation(
                invocationID: seeded.invocationID,
                expected: .executing,
                to: .ambiguous,
                lease: lease
            )

            let paths = AppPaths(home: root.appendingPathComponent("memory-home"))
            try paths.ensureLayout()
            let memory = ProjectMemoryService(paths: paths)
            defer { memory.closeAll() }
            let executor = CountingToolExecutor()
            let broker = ToolInvocationBroker(
                repository: repository,
                executor: executor,
                classifier: StaticToolReplayClassifier(classifications: [
                    "shell.run": .reconciled,
                ]),
                reconciler: ProductionToolInvocationReconciler(
                    controlPlane: repository,
                    runtimeJobs: runtimeJobs,
                    memory: memory
                )
            )
            let result = try await broker.invoke(
                BrokeredToolCall(
                    providerCallID: "call-runtime-reconcile",
                    toolName: "shell.run",
                    arguments: providerArguments,
                    idempotencyKey: jobKey
                ),
                turnID: toolFixture.turn.turnID,
                context: toolFixture.context,
                lease: lease
            )
            XCTAssertEqual(result.payload["job_id"] as? String, jobID.uuidString.lowercased())
            XCTAssertEqual(result.payload["state"] as? String, RuntimeJobState.queued.rawValue)
            XCTAssertEqual(executor.callCount, 0)
            let completedValue = try await repository.toolInvocation(
                sessionID: toolFixture.context.providerSessionID ?? "",
                providerCallID: "call-runtime-reconcile"
            )
            XCTAssertEqual(try XCTUnwrap(completedValue).state, .completed)
            await runtimeJobs.close()
        }
    }

    func testProjectMemoryReconcilerRejectsDifferentCASWinner() async throws {
        try await withRepository { repository, root in
            let projectRoot = root.appendingPathComponent("project", isDirectory: true)
            try FileManager.default.createDirectory(
                at: projectRoot,
                withIntermediateDirectories: true
            )
            let paths = AppPaths(home: root.appendingPathComponent("memory-home"))
            try paths.ensureLayout()
            let memory = ProjectMemoryService(paths: paths)
            defer { memory.closeAll() }
            let initialized = try memory.initializeUnchecked(path: projectRoot.path)
            let projectID = ProjectID(try XCTUnwrap(UUID(
                uuidString: try XCTUnwrap(initialized["project_id"] as? String)
            )))
            _ = try await repository.registerProjectUnchecked(
                projectID: projectID,
                displayName: "Memory Reconciliation Fixture",
                canonicalRoot: projectRoot
            )
            let remembered = try memory.remember(
                projectID: projectID.description,
                write: ProjectMemoryWrite(
                    kind: "fact",
                    title: "Original title",
                    summary: "Original summary",
                    body: "Original body",
                    tags: ["fixture"],
                    idempotencyKey: "memory-reconcile-record"
                )
            )
            let recordID = try XCTUnwrap(remembered["record_id"] as? String)
            let expectedVersion = try XCTUnwrap(remembered["record_version"] as? Int)
            let runID = RunID()
            let context = ToolInvocationContext(
                projectID: projectID,
                projectGeneration: .initial,
                clientID: ClientID("memory-reconciler"),
                runID: runID,
                providerSessionID: "memory-reconciler-session",
                authorizationScope: ToolAuthorizationScope(
                    canonicalRoots: [projectRoot],
                    allowedTools: ["project_memory.update"],
                    networkAllowed: false,
                    maximumInlineOutputBytes: 64 * 1_024
                )
            )
            let runtimeJobs = try RuntimeJobRepository(
                databaseURL: root.appendingPathComponent("control-plane.sqlite3")
            )
            let reconciler = ProductionToolInvocationReconciler(
                controlPlane: repository,
                runtimeJobs: runtimeJobs,
                memory: memory
            )
            let call = BrokeredToolCall(
                providerCallID: "call-memory-reconcile",
                toolName: "project_memory.update",
                arguments: [
                    "project_id": projectID.description,
                    "id": recordID,
                    "expected_version": expectedVersion,
                    "title": "Requested title",
                ]
            )
            let descriptor = try await reconciler.prepare(call: call, context: context)
            XCTAssertNotNil(descriptor)
            _ = try memory.update(
                projectID: projectID.description,
                id: recordID,
                expectedVersion: expectedVersion,
                title: nil,
                summary: "Different winner",
                body: nil,
                tags: nil
            )
            let timestamp = ISO8601.string(from: Date())
            let invocation = ToolInvocationRecord(
                invocationID: UUID(),
                turnID: UUID(),
                runID: runID,
                sessionID: "memory-reconciler-session",
                projectID: projectID,
                projectGeneration: .initial,
                providerCallID: call.providerCallID,
                toolName: call.toolName,
                replayClass: .reconciled,
                idempotencyKey: nil,
                argumentsSHA256: JSONSupport.sha256Hex(
                    try JSONSupport.canonicalJSON(call.arguments)
                ),
                reconciliationDescriptor: descriptor,
                state: .ambiguous,
                resultSHA256: nil,
                resultSummary: nil,
                lastErrorCode: "manager_interrupted",
                lastErrorSummary: "Fixture interruption",
                createdAt: timestamp,
                updatedAt: timestamp
            )
            switch try await reconciler.reconcile(
                invocation: invocation,
                call: call,
                context: context
            ) {
            case .unresolved:
                break
            case .completed, .safeToExecute:
                XCTFail("A different compare-and-swap winner must not be claimed")
            }
            await runtimeJobs.close()
        }
    }

    func testProductionReconcilerVerifiesExactGitCommitPostcondition() async throws {
        try await withRepository { repository, root in
            let fixture = try await makeRun(
                repository: repository,
                root: root,
                allowedTools: ["git_commit"]
            )
            let projectRoot = root.appendingPathComponent("project", isDirectory: true)
            try FileManager.default.createDirectory(
                at: projectRoot,
                withIntermediateDirectories: true
            )
            for arguments in [
                ["init"],
                ["config", "user.name", "Fixture Author"],
                ["config", "user.email", "fixture@example.invalid"],
            ] {
                XCTAssertEqual(try runGit(arguments, in: projectRoot).exitCode, 0)
            }
            let tracked = projectRoot.appendingPathComponent("tracked.txt")
            try "base\n".write(to: tracked, atomically: true, encoding: .utf8)
            XCTAssertEqual(try runGit(["add", "tracked.txt"], in: projectRoot).exitCode, 0)
            XCTAssertEqual(
                try runGit(["commit", "-m", "baseline fixture"], in: projectRoot).exitCode,
                0
            )
            try "updated\n".write(to: tracked, atomically: true, encoding: .utf8)
            XCTAssertEqual(try runGit(["add", "tracked.txt"], in: projectRoot).exitCode, 0)

            let context = try await repository.invocationContext(
                for: ProjectBindingOwner(
                    kind: .autonomousRun,
                    id: fixture.run.runID.description
                )
            )
            let paths = AppPaths(home: root.appendingPathComponent("memory-home"))
            try paths.ensureLayout()
            let memory = ProjectMemoryService(paths: paths)
            defer { memory.closeAll() }
            let runtimeJobs = try RuntimeJobRepository(
                databaseURL: root.appendingPathComponent("control-plane.sqlite3")
            )
            let reconciler = ProductionToolInvocationReconciler(
                controlPlane: repository,
                runtimeJobs: runtimeJobs,
                memory: memory
            )
            let call = BrokeredToolCall(
                providerCallID: "call-git-commit",
                toolName: "git_commit",
                arguments: [
                    "cwd": projectRoot.path,
                    "message": "durable fixture commit",
                ]
            )
            let descriptor = try await reconciler.prepare(call: call, context: context)
            XCTAssertNotNil(descriptor)
            let invocation = try makeReconciledInvocationRecord(
                run: fixture.run,
                call: call,
                descriptor: descriptor
            )
            XCTAssertEqual(
                try runGit(["commit", "-m", "durable fixture commit"], in: projectRoot).exitCode,
                0
            )

            switch try await reconciler.reconcile(
                invocation: invocation,
                call: call,
                context: context
            ) {
            case .completed(let result):
                XCTAssertTrue(result.ok)
                XCTAssertEqual(result.payload["cwd"] as? String, projectRoot.path)
            case .safeToExecute, .unresolved:
                XCTFail("Expected the exact committed tree, parent, and message to reconcile")
            }
            await runtimeJobs.close()
        }
    }

    func testNonReplayableInterruptedToolIsPersistedAmbiguousAndNotRepeated() async throws {
        try await withRepository { repository, root in
            let fixture = try await makeRun(repository: repository, root: root, allowedTools: ["external.send"])
            let lease = try await repository.acquireRunLease(
                runID: fixture.run.runID,
                ownerID: "manager-nonreplay",
                policy: fixture.leasePolicy
            )
            let sessionID = "session-nonreplay"
            try await repository.reserveProviderSession(
                ProviderSessionIntent(
                    sessionID: sessionID,
                    runID: fixture.run.runID,
                    projectID: fixture.run.projectID,
                    projectGeneration: fixture.run.projectGeneration,
                    providerID: "lmstudio",
                    adapterID: "lmstudio-rest",
                    modelKey: "fixture-model",
                    idempotencyKey: "session-nonreplay-key"
                ),
                lease: lease
            )
            let turn = ProviderTurnIntent(
                runID: fixture.run.runID,
                sessionID: sessionID,
                projectID: fixture.run.projectID,
                projectGeneration: fixture.run.projectGeneration,
                kind: .normalContinuation,
                idempotencyKey: "turn-nonreplay-key",
                inputSHA256: String(repeating: "b", count: 64)
            )
            _ = try await repository.persistProviderTurnIntent(turn, lease: lease)
            let intent = ToolInvocationIntent(
                turnID: turn.turnID,
                runID: fixture.run.runID,
                sessionID: sessionID,
                projectID: fixture.run.projectID,
                projectGeneration: fixture.run.projectGeneration,
                providerCallID: "call-send",
                toolName: "external.send",
                replayClass: .nonReplayable,
                idempotencyKey: nil,
                argumentsSHA256: JSONSupport.sha256Hex(try JSONSupport.canonicalJSON(["message": "once"]))
            )
            let stored = try await repository.persistToolInvocationIntent(intent, lease: lease)
            _ = try await repository.transitionToolInvocation(
                invocationID: stored.invocationID,
                expected: .intent,
                to: .executing,
                lease: lease
            )
            let executor = CountingToolExecutor()
            let broker = ToolInvocationBroker(
                repository: repository,
                executor: executor,
                classifier: StaticToolReplayClassifier(classifications: [
                    "external.send": .nonReplayable,
                ])
            )
            let context = try await repository.invocationContext(
                for: ProjectBindingOwner(kind: .providerSession, id: sessionID)
            )
            await assertAutonomyError(code: "tool_replay_blocked") {
                _ = try await broker.invoke(
                    BrokeredToolCall(
                        providerCallID: "call-send",
                        toolName: "external.send",
                        arguments: ["message": "once"]
                    ),
                    turnID: turn.turnID,
                    context: context,
                    lease: lease
                )
            }
            XCTAssertEqual(executor.callCount, 0)
            let ambiguousValue = try await repository.toolInvocation(
                sessionID: sessionID,
                providerCallID: "call-send"
            )
            let ambiguous = try XCTUnwrap(ambiguousValue)
            XCTAssertEqual(ambiguous.state, .ambiguous)
        }
    }

    func testNativeResultSemanticsRequireCasesWithoutFailuresOrSkips() throws {
        let caseID = "RequiredTests/testEffect()"
        let summary: [String: Any] = [
            "startTime": 100.0, "finishTime": 101.0, "environmentDescription": "macOS fixture",
            "result": "Passed", "totalTestCount": 1, "passedTests": 1,
            "failedTests": 0, "skippedTests": 0, "expectedFailures": 0, "testFailures": [],
        ]
        let testCase: [String: Any] = [
            "nodeType": "Test Case", "name": "testEffect()", "nodeIdentifier": caseID, "result": "Passed",
        ]
        let tests: [String: Any] = [
            "devices": [["deviceId": "fixture", "architecture": "arm64", "osVersion": "26.6.2"]],
            "testPlanConfigurations": [["configurationId": "1"]], "testNodes": [testCase],
        ]
        func check(_ overview: [String: Any], _ tree: [String: Any]) throws -> Bool {
            try XCTestResultAdjudicator.adjudicate(
                summary: JSONSerialization.data(withJSONObject: overview),
                tests: JSONSerialization.data(withJSONObject: tree),
                requiredCases: [caseID], minimumCaseCount: 1
            ).passed
        }
        XCTAssertTrue(try check(summary, tests))
        for status in ["Failed", "Skipped", "Expected Failure", "unknown"] {
            var changedCase = testCase
            changedCase["result"] = status
            var changed = tests
            changed["testNodes"] = [changedCase]
            XCTAssertFalse(try check(summary, changed), status)
        }
        var missing = tests
        missing["testNodes"] = []
        XCTAssertFalse(try check(summary, missing))
        var wrongCase = testCase
        wrongCase["nodeIdentifier"] = "Unrelated/testStatus()"
        missing["testNodes"] = [wrongCase]
        XCTAssertFalse(try check(summary, missing))
        missing["testNodes"] = [testCase, testCase]
        XCTAssertThrowsError(try check(summary, missing))
        for field in ["failedTests", "skippedTests", "expectedFailures", "totalTestCount"] {
            var changed = summary
            changed[field] = 2
            XCTAssertFalse(try check(changed, tests), field)
        }
        var crashed = summary
        crashed["testFailures"] = [["failureText": "Test process crashed"]]
        XCTAssertFalse(try check(crashed, tests))
        XCTAssertThrowsError(try XCTestResultAdjudicator.adjudicate(
            summary: Data("{\"passed\":true}".utf8), tests: Data("{".utf8),
            requiredCases: [caseID], minimumCaseCount: 1
        ))
    }

    func testCompletionInvocationRejectsCrossIdentityAndStaleReceiptReplay() async throws {
        try await withRepository { repository, root in
            let fixture = try await makeRun(repository: repository, root: root)
            let lease = try await repository.acquireRunLease(
                runID: fixture.run.runID, ownerID: "receipt-replay", policy: fixture.leasePolicy
            )
            var run = fixture.run
            for state in [AutonomousRunState.validating, .ready, .starting, .running, .validatingCompletion] {
                run = try await repository.transitionAutonomousRun(
                    runID: run.runID, lease: lease, transition: transition(run, to: state)
                )
            }
            let registry = try GateValidatorRegistry(validators: [CompletionGateValidator(gate: "tests") { _ in
                CompletionGateResult(gate: "tests", passed: true, summary: "Native fixture assertion passed")
            }])
            let receipt = try await registry.validate(run)
            let result = try XCTUnwrap(receipt.results.first)
            let original = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as! [String: Any]
            let mismatches: [(String, Any)] = [
                ("run_id", try JSONSerialization.jsonObject(with: JSONEncoder().encode(RunID()))),
                ("project_id", try JSONSerialization.jsonObject(with: JSONEncoder().encode(ProjectID()))),
                ("project_generation", try JSONSerialization.jsonObject(with: JSONEncoder().encode(ProjectGeneration(2)))),
                ("expected_revision", run.revision + 1),
                ("specification_sha256", String(repeating: "0", count: 64)),
            ]
            for (field, value) in mismatches {
                var object = original
                var invocation = try XCTUnwrap(object["invocation"] as? [String: Any])
                invocation[field] = value
                object["invocation"] = invocation
                let altered = try JSONDecoder().decode(
                    CompletionGateResult.self, from: JSONSerialization.data(withJSONObject: object)
                )
                let replay = try CompletionValidationReceipt.make(
                    runID: run.runID, expectedRevision: run.revision, results: [altered], validatedAt: receipt.validatedAt
                )
                XCTAssertTrue(replay.hasValidProof(), "A valid hash cannot authorize an identity mismatch")
                await assertAutonomyError(code: "completion_validation_failed") {
                    try await repository.recordTrustedCompletionValidation(replay, for: run, lease: lease)
                }
            }
            try await repository.recordTrustedCompletionValidation(receipt, for: run, lease: lease)
            run = try await repository.transitionAutonomousRun(
                runID: run.runID, lease: lease, transition: transition(run, to: .running)
            )
            run = try await repository.transitionAutonomousRun(
                runID: run.runID, lease: lease, transition: transition(run, to: .validatingCompletion)
            )
            await assertAutonomyError(code: "autonomous_run_transition_conflict") {
                _ = try await repository.completeAutonomousRun(runID: run.runID, lease: lease, receipt: receipt)
            }
            let fresh = try await registry.validate(run)
            XCTAssertNotEqual(fresh.results.first?.invocation?.jobID, receipt.results.first?.invocation?.jobID)
            try await repository.recordTrustedCompletionValidation(fresh, for: run, lease: lease)
            let completed = try await repository.completeAutonomousRun(runID: run.runID, lease: lease, receipt: fresh)
            XCTAssertEqual(completed.state, .completed)
            await assertAutonomyError(code: "completion_validation_failed") {
                _ = try await repository.completeAutonomousRun(runID: run.runID, lease: lease, receipt: fresh)
            }
        }
    }

    func testNativeGateHandlerRequiresCurrentJobInputsAndSemanticResults() async throws {
        try await withRepository { repository, root in
            let fixture = try await makeRun(repository: repository, root: root)
            let lease = try await repository.acquireRunLease(
                runID: fixture.run.runID, ownerID: "native-job-fixture", policy: fixture.leasePolicy
            )
            var run = fixture.run
            for state in [AutonomousRunState.validating, .ready, .starting, .running, .validatingCompletion] {
                run = try await repository.transitionAutonomousRun(
                    runID: run.runID, lease: lease, transition: transition(run, to: state)
                )
            }
            for scenario in ["pass", "job", "nonce", "handler", "exit", "signal", "timeout", "truncated",
                             "source", "observed-inputs", "policy", "environment", "old-result", "failed-case", "skipped-case"] {
                let capture = NativeGateInputFixture(changesSource: scenario == "source")
                let handler = try NativeXCTestGateHandler(
                    gate: "tests", version: 3, handler: "installed.xctest.fixture.v1",
                    policyRevision: scenario == "policy" ? "different" : "policy-v1",
                    environmentIdentity: scenario == "environment" ? "different" : "macOS-fixture",
                    requiredCases: ["Required/testEffect()"], minimumCaseCount: 1,
                    captureInputs: { _ in try await capture.next() },
                    execute: { job, inputs in
                        let timestamp = scenario == "old-result" ? 1 : Date().timeIntervalSince1970
                        let status = scenario == "failed-case" ? "Failed" : scenario == "skipped-case" ? "Skipped" : "Passed"
                        let summary: [String: Any] = [
                            "startTime": timestamp, "finishTime": timestamp, "environmentDescription": "native executor fixture",
                            "result": status, "totalTestCount": 1, "passedTests": status == "Passed" ? 1 : 0,
                            "failedTests": status == "Failed" ? 1 : 0, "skippedTests": status == "Skipped" ? 1 : 0,
                            "expectedFailures": 0, "testFailures": [],
                        ]
                        let tests: [String: Any] = [
                            "devices": [["deviceId": "fixture", "architecture": "arm64", "osVersion": "26.6.2"]],
                            "testPlanConfigurations": [["configurationId": "1"]],
                            "testNodes": [["nodeType": "Test Case", "name": "testEffect()",
                                           "nodeIdentifier": "Required/testEffect()", "result": status]],
                        ]
                        let observedInputs = scenario == "observed-inputs" ? try NativeGateInputs(
                            sourceManifestSHA256: String(repeating: "c", count: 64), buildIdentity: "build",
                            policyRevision: "policy-v1", environmentIdentity: "macOS-fixture"
                        ) : inputs
                        return ObservedNativeGateExecution(
                            jobID: scenario == "job" ? UUID() : job.jobID,
                            nonce: scenario == "nonce" ? UUID() : job.nonce,
                            inputs: observedInputs,
                            handler: scenario == "handler" ? "unrelated.status" : "installed.xctest.fixture.v1",
                            artifactPath: root.appendingPathComponent("fixture.xcresult").path,
                            artifactSHA256: String(repeating: "b", count: 64),
                            exitCode: scenario == "exit" ? 65 : 0,
                            terminationSignal: scenario == "signal" ? 9 : nil,
                            timedOut: scenario == "timeout", outputTruncated: scenario == "truncated",
                            summary: try JSONSerialization.data(withJSONObject: summary),
                            tests: try JSONSerialization.data(withJSONObject: tests)
                        )
                    }
                )
                let receipt = try await GateValidatorRegistry(validators: [handler.validator]).validate(run)
                XCTAssertEqual(receipt.passed, scenario == "pass", scenario)
                if receipt.passed {
                    XCTAssertEqual(receipt.results.first?.invocation?.gateVersion, 3)
                    XCTAssertEqual(receipt.results.first?.nativeEvidence?.testReport.cases.count, 1)
                } else {
                    await assertAutonomyError(code: "completion_validation_failed") {
                        try await repository.recordTrustedCompletionValidation(receipt, for: run, lease: lease)
                    }
                }
            }
        }
    }

    func testInstalledNativePolicyRejectsUntrustedAndStaleDefinitions() async throws {
        for scenario in ["missing", "malformed", "oversized", "public-mode", "hard-link", "parent-link",
                         "wrong-run", "wrong-generation", "wrong-source", "old-policy", "duplicate-gate", "path-traversal",
                         "unknown-gate", "missing-correction-case"] {
            try await withRepository { repository, root in
                let gate = scenario == "missing-correction-case" ? "G01" : "tests"
                let fixture = try await makeRun(repository: repository, root: root, completionGates: [gate])
                let project = root.appendingPathComponent("project")
                try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
                try Data("qualification input".utf8).write(to: project.appendingPathComponent("source.txt"))
                let lease = try await repository.acquireRunLease(runID: fixture.run.runID, ownerID: "policy-regression", policy: fixture.leasePolicy)
                var run = fixture.run
                for state in [AutonomousRunState.validating, .ready, .starting, .running, .validatingCompletion] {
                    run = try await repository.transitionAutonomousRun(runID: run.runID, lease: lease, transition: transition(run, to: state))
                }
                let definition = InstalledNativeGatePolicy.Gate(
                    id: scenario == "unknown-gate" ? "other" : gate, version: 2, packageID: UUID(),
                    packageInputs: ["plan.xctestrun", "product"], packageSHA256: String(repeating: "a", count: 64),
                    signedProducts: ["product"], testRunPath: scenario == "path-traversal" ? "../plan.xctestrun" : "plan.xctestrun",
                    testIdentifiers: ["ForgeConductorTests/Effect/testWork"], requiredCases: ["Effect/testWork()"],
                    minimumCaseCount: 1, timeoutSeconds: 1
                )
                let candidateSource = try await QualificationInputSnapshotter(root: project, inputs: ["source.txt"]).capture()
                let policy = InstalledNativeGatePolicy(
                    schemaVersion: 1,
                    policyRevision: scenario == "old-policy" ? "old" : CompletionGateAcceptancePolicy.correction001Revision,
                    runID: scenario == "wrong-run" ? RunID() : run.runID, projectID: run.projectID,
                    projectGeneration: scenario == "wrong-generation" ? ProjectGeneration(2) : run.projectGeneration,
                    sourceInputs: ["source.txt"], candidateSourceSHA256: scenario == "wrong-source" ? String(repeating: "0", count: 64) : candidateSource.sha256,
                    buildIdentity: "policy-fixture", xcodeVersion: "Xcode fixture", architecture: "arm64",
                    correctionCaseBindings: [:], gates: scenario == "duplicate-gate" ? [definition, definition] : [definition]
                )
                let paths = AppPaths(home: root.appendingPathComponent("manager"))
                let policyFile = paths.nativeValidationDir.appendingPathComponent("policies/\(run.runID.description).json")
                if scenario != "missing" {
                    let data = scenario == "malformed" ? Data("not JSON".utf8)
                        : scenario == "oversized" ? Data(repeating: 32, count: 256 * 1_024 + 1) : try JSONEncoder().encode(policy)
                    try OwnerOnlyAtomicFile.write(data, to: policyFile)
                    if scenario == "public-mode" {
                        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: policyFile.path)
                    }
                    if scenario == "hard-link" {
                        try FileManager.default.linkItem(at: policyFile, to: root.appendingPathComponent("aliased-policy"))
                    }
                    if scenario == "parent-link" {
                        let parent = policyFile.deletingLastPathComponent()
                        let moved = root.appendingPathComponent("external-policies")
                        try FileManager.default.moveItem(at: parent, to: moved)
                        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: moved)
                    }
                }
                let registry = InstalledNativeGateRegistry(repository: repository, paths: paths)
                let receipt = try await registry.validate(run)
                XCTAssertFalse(receipt.passed, scenario)
                XCTAssertEqual(receipt.results.count, 1)
                XCTAssertNotNil(receipt.results.first?.blocker, scenario)
                if ["unknown-gate", "missing-correction-case"].contains(scenario) {
                    XCTAssertEqual(receipt.results.first?.blocker, .unregisteredValidator, scenario)
                }
                XCTAssertFalse(FileManager.default.fileExists(atPath: paths.nativeValidationDir.appendingPathComponent("results").path), scenario)
                await registry.shutdown()
            }
        }
    }

    func testNativeJobFailurePreventsCompletionUntilActualEffectIsCorrected() async throws {
        try await qualifyNativeGateEffect(useInstalledPolicy: false)
    }

    func testInstalledNativeJobFailurePreventsCompletionUntilActualEffectIsCorrected() async throws {
        try await qualifyNativeGateEffect(useInstalledPolicy: true)
    }

    private func qualifyNativeGateEffect(useInstalledPolicy: Bool) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let packagePath = environment["FORGE_NATIVE_GATE_TEST_PACKAGE"],
              let planName = environment["FORGE_NATIVE_GATE_TEST_PLAN"],
              let evidencePath = environment["FORGE_NATIVE_GATE_EVIDENCE_ROOT"] else {
            throw XCTSkip("Native job qualification requires an explicitly prepared test package and evidence directory")
        }
        let originalPackageRoot = URL(fileURLWithPath: packagePath, isDirectory: true)
        let evidenceRoot = URL(fileURLWithPath: evidencePath, isDirectory: true)
        let installedPaths = AppPaths(home: evidenceRoot.appendingPathComponent("manager"))
        let installedPackageID = UUID()
        let packageRoot = useInstalledPolicy
            ? installedPaths.nativeValidationDir.appendingPathComponent("packages/\(installedPackageID.uuidString.lowercased())")
            : originalPackageRoot
        if useInstalledPolicy {
            try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: originalPackageRoot.appendingPathComponent("Debug"), to: packageRoot.appendingPathComponent("Debug"))
        }
        let developer = URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer", isDirectory: true)
        let version = try ProcessRunner().run(executable: developer.appendingPathComponent("usr/bin/xcodebuild").path,
                                              arguments: ["-version"], timeoutSec: 10)
        XCTAssertEqual(version.exitCode, 0)
        let xcodeVersion = version.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        try await withRepository { repository, root in
            let fixture = try await makeRun(repository: repository, root: root)
            let projectRoot = root.appendingPathComponent("project", isDirectory: true)
            try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
            let workProduct = projectRoot.appendingPathComponent("work-product.txt")
            let sourceMarker = projectRoot.appendingPathComponent("qualification-state.txt")
            let fixturePlanName = "native-gate-\(UUID().uuidString.lowercased()).xctestrun"
            let fixturePlan = packageRoot.appendingPathComponent(fixturePlanName)
            var plan = try XCTUnwrap(PropertyListSerialization.propertyList(
                from: OwnerOnlyAtomicFile.read(from: originalPackageRoot.appendingPathComponent(planName), maximumBytes: 4 * 1_048_576),
                format: nil
            ) as? [String: Any])
            var configurations = try XCTUnwrap(plan["TestConfigurations"] as? [[String: Any]])
            for index in configurations.indices {
                var targets = try XCTUnwrap(configurations[index]["TestTargets"] as? [[String: Any]])
                for target in targets.indices {
                    var variables = targets[target]["EnvironmentVariables"] as? [String: String] ?? [:]
                    variables["FORGE_NATIVE_GATE_FIXTURE_FILE"] = workProduct.path
                    targets[target]["EnvironmentVariables"] = variables
                }
                configurations[index]["TestTargets"] = targets
            }
            plan["TestConfigurations"] = configurations
            let planData = try PropertyListSerialization.data(fromPropertyList: plan, format: .xml, options: 0)
            try OwnerOnlyAtomicFile.write(planData, to: fixturePlan)
            defer { if !useInstalledPolicy { try? FileManager.default.removeItem(at: fixturePlan) } }
            try OwnerOnlyAtomicFile.write(planData, to: evidenceRoot.appendingPathComponent(fixturePlanName))
            let testContents = "Debug/ForgeConductorTests.xctest/Contents/"
            let packageInputs = [fixturePlanName, testContents + "Info.plist", testContents + "MacOS",
                                 testContents + "_CodeSignature", testContents + "Resources",
                                 testContents + "Frameworks/ForgeConductorCore.framework/Versions/A",
                                 "Debug/ForgeConductorCore.framework/Versions/A", "Debug/forge-conductor",
                                 "Debug/forge-filesystem-daemon", "Debug/forge-runtime-launcher"]
            let packageSnapshot = try await QualificationInputSnapshotter(
                root: packageRoot, inputs: packageInputs, maximumFileBytes: 128 * 1_048_576
            ).capture()
            let source = try QualificationInputSnapshotter(root: projectRoot, inputs: ["work-product.txt", "qualification-state.txt"])
            let artifactRoot = useInstalledPolicy
                ? installedPaths.nativeValidationDir.appendingPathComponent("results/\(fixture.run.runID.description)/tests")
                : evidenceRoot.appendingPathComponent("native-jobs-\(UUID().uuidString.lowercased())", isDirectory: true)
            let requiredCase = "ProcessRunnerTests/testNativeGateEffectFixture()"
            let buildIdentity = packageSnapshot.sha256
            let inputCapture: NativeXCTestGateHandler.InputCapture = { _ in
                let snapshot = try await source.capture()
                return try NativeGateInputs(sourceManifestSHA256: snapshot.sha256, buildIdentity: buildIdentity,
                                            policyRevision: "native-job-fixture-v1", environmentIdentity: xcodeVersion)
            }
            let signedProducts = ["Debug/ForgeConductorTests.xctest", "Debug/ForgeConductorCore.framework",
                                  "Debug/forge-conductor", "Debug/forge-filesystem-daemon", "Debug/forge-runtime-launcher"]
            let installedRegistry = InstalledNativeGateRegistry(repository: repository, paths: installedPaths)
            if useInstalledPolicy {
                let definition = InstalledNativeGatePolicy.Gate(
                    id: "tests", version: 2, packageID: installedPackageID, packageInputs: packageInputs,
                    packageSHA256: packageSnapshot.sha256, signedProducts: signedProducts, testRunPath: fixturePlanName,
                    testIdentifiers: ["ForgeConductorTests/ProcessRunnerTests/testNativeGateEffectFixture"],
                    requiredCases: [requiredCase], minimumCaseCount: 1, timeoutSeconds: 60
                )
                let policy = InstalledNativeGatePolicy(
                    schemaVersion: 1, policyRevision: CompletionGateAcceptancePolicy.correction001Revision,
                    runID: fixture.run.runID, projectID: fixture.run.projectID, projectGeneration: fixture.run.projectGeneration,
                    sourceInputs: ["work-product.txt", "qualification-state.txt"], candidateSourceSHA256: nil, buildIdentity: buildIdentity, xcodeVersion: xcodeVersion,
                    architecture: architecture, correctionCaseBindings: [:], gates: [definition]
                )
                try OwnerOnlyAtomicFile.write(try JSONEncoder().encode(policy),
                    to: installedPaths.nativeValidationDir.appendingPathComponent("policies/\(fixture.run.runID.description).json"))
            }
            let stages = useInstalledPolicy ? ["failed", "stale", "corrected"] : ["failed", "corrected"]
            for stage in stages {
                let corrected = stage == "corrected"
                try OwnerOnlyAtomicFile.write(Data((stage == "failed" ? "incorrect effect\n" : "required native effect\n").utf8), to: workProduct)
                try OwnerOnlyAtomicFile.write(Data("before-\(stage)".utf8), to: sourceMarker)
                let inputs = try await inputCapture(fixture.run)
                let jobPolicy = try NativeXCTestJobPolicy(
                    packageRoot: packageRoot, packageInputs: packageInputs, packageSHA256: packageSnapshot.sha256,
                    signedProducts: signedProducts,
                    testRunPath: fixturePlanName, artifactRoot: artifactRoot, developerDirectory: developer,
                    xcodeVersion: xcodeVersion,
                    testIdentifiers: ["ForgeConductorTests/ProcessRunnerTests/testNativeGateEffectFixture"],
                    inputs: inputs, architecture: architecture, timeoutSeconds: 60
                )
                let executor = NativeXCTestJobExecutor(repository: repository, policy: jobPolicy)
                let handler = try NativeXCTestGateHandler(
                    gate: "tests", version: 2, handler: NativeXCTestJobExecutor.handlerIdentity,
                    policyRevision: "native-job-fixture-v1", environmentIdentity: xcodeVersion,
                    requiredCases: [requiredCase], minimumCaseCount: 1, captureInputs: inputCapture,
                    execute: { job, captured in try await executor.execute(job, inputs: captured) }
                )
                let validator: any RunCompletionValidating = useInstalledPolicy
                    ? installedRegistry : try GateValidatorRegistry(validators: [handler.validator])
                let coordinator = try ProjectRunCoordinator(
                    runID: fixture.run.runID, repository: repository, managerID: "native-job-proof",
                    leasePolicy: fixture.leasePolicy, stepExecutor: CompletionRequestStepper(),
                    completionValidator: validator, maximumSteps: 8
                )
                let existingJobs = Set((try? FileManager.default.contentsOfDirectory(atPath: artifactRoot.path)) ?? [])
                let sourceMutation: Task<Bool, Error>? = stage == "stale" ? Task {
                    let deadline = ContinuousClock.now + .seconds(15)
                    while ContinuousClock.now < deadline {
                        try Task.checkCancellation()
                        let jobs = (try? FileManager.default.contentsOfDirectory(at: artifactRoot, includingPropertiesForKeys: nil)) ?? []
                        if let job = jobs.first(where: { !existingJobs.contains($0.lastPathComponent)
                            && FileManager.default.fileExists(atPath: $0.appendingPathComponent("result.xcresult").path) }) {
                            guard !FileManager.default.fileExists(atPath: job.appendingPathComponent("process.json").path) else { return false }
                            try OwnerOnlyAtomicFile.write(Data("changed during native execution".utf8), to: sourceMarker)
                            let change: [String: String] = ["job": job.lastPathComponent, "changedAt": ISO8601.string(from: Date()),
                                                            "condition": "result bundle exists; native process receipt not yet committed"]
                            try OwnerOnlyAtomicFile.write(try JSONEncoder().encode(change), to: evidenceRoot.appendingPathComponent("source-change.json"))
                            return true
                        }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    return false
                } : nil
                defer { sourceMutation?.cancel() }
                let outcome = try await coordinator.runActivation()
                if let sourceMutation {
                    let changedDuringExecution = try await sourceMutation.value
                    XCTAssertTrue(changedDuringExecution, "source mutation must occur while the native validation process is active")
                }
                let storedValue = try await repository.autonomousRun(fixture.run.runID)
                let stored = try XCTUnwrap(storedValue)
                XCTAssertEqual(outcome.finalState, corrected ? .completed : .running, stored.lastErrorSummary ?? "")
                try OwnerOnlyAtomicFile.write(try JSONEncoder().encode(stored),
                                              to: evidenceRoot.appendingPathComponent(corrected ? "corrected-run.json" : stage == "stale" ? "stale-run.json" : "rejected-run.json"))
                if corrected {
                    let receipt = try JSONDecoder().decode(CompletionValidationReceipt.self,
                        from: Data(try XCTUnwrap(stored.completionRequestJSON).utf8))
                    XCTAssertTrue(receipt.passed)
                    XCTAssertEqual(receipt.results.first?.nativeEvidence?.testReport.cases.map(\.identifier), [requiredCase])
                } else {
                    XCTAssertEqual(stored.lastErrorCode, "completion_validation_failed")
                }
                await executor.shutdown()
            }
            await installedRegistry.shutdown()
            let results = try FileManager.default.contentsOfDirectory(at: artifactRoot, includingPropertiesForKeys: nil)
            XCTAssertEqual(results.count, stages.count, "One native job per attempted completion")
            let exitCodes = try results.map { directory -> Int in
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: OwnerOnlyAtomicFile.read(
                    from: directory.appendingPathComponent("process.json"), maximumBytes: 16 * 1_024
                )) as? [String: Any])
                return try XCTUnwrap(object["exitCode"] as? Int)
            }.sorted()
            XCTAssertEqual(exitCodes, useInstalledPolicy ? [0, 0, 65] : [0, 65], "Native failures, stale passes, and fresh passes retain actual process outcomes")
        }
    }

    func testCorrectionRequirementsRejectMissingAndUnrelatedEvidence() async throws {
        let requiredCase = "AutonomySupervisorTests/testCorrectionRequirementsRejectMissingAndUnrelatedEvidence()"
        let policy = try CompletionGateAcceptancePolicy.correction001(caseBindings: ["CLU-C01-23": requiredCase])
        XCTAssertEqual(Set(CompletionGateAcceptancePolicy.correction001Cases.values.flatMap { $0 }).count, 24)
        XCTAssertThrowsError(try CompletionGateAcceptancePolicy.correction001(caseBindings: ["unrelated": requiredCase]))
        XCTAssertThrowsError(try CompletionGateAcceptancePolicy.correction001(caseBindings: [
            "CLU-C01-23": requiredCase, "CLU-C01-22": requiredCase,
        ]))
        XCTAssertFalse(try CompletionGateAcceptancePolicy.correction001(caseBindings: [:]).isConfigured(for: "G01"))
        XCTAssertFalse(policy.isConfigured(for: "G13"), "API evidence cannot configure the desktop scope gate")
        try await withRepository { repository, root in
            let fixture = try await makeRun(repository: repository, root: root, completionGates: ["G01"])
            let lease = try await repository.acquireRunLease(
                runID: fixture.run.runID, ownerID: "correction-gate-fixture", policy: fixture.leasePolicy
            )
            var run = fixture.run
            for state in [AutonomousRunState.validating, .ready, .starting, .running, .validatingCompletion] {
                run = try await repository.transitionAutonomousRun(
                    runID: run.runID, lease: lease, transition: transition(run, to: state)
                )
            }
            for scenario in ["missing", "old-policy", "old-version", "unrelated", "skipped", "failed", "truncated", "fixture-pass"] {
                let inputs = try NativeGateInputs(
                    sourceManifestSHA256: String(repeating: "a", count: 64), buildIdentity: "fixture-build",
                    policyRevision: scenario == "old-policy" ? "original-package" : CompletionGateAcceptancePolicy.correction001Revision,
                    environmentIdentity: "fixture-only"
                )
                let report = XCTestResultAdjudicator.Report(
                    passed: scenario != "failed", cases: [.init(
                        identifier: scenario == "unrelated" ? "Unrelated/testStatus()" : requiredCase,
                        result: scenario == "skipped" ? "Skipped" : "Passed"
                    )], failures: [], startedAt: Date(), finishedAt: Date()
                )
                let evidence = NativeGateEvidence(
                    inputs: inputs, handler: "native-fixture", artifactPath: root.appendingPathComponent("fixture.xcresult").path,
                    artifactSHA256: String(repeating: "b", count: 64), summarySHA256: String(repeating: "c", count: 64),
                    testsSHA256: String(repeating: "d", count: 64), exitCode: 0, terminationSignal: nil,
                    timedOut: false, outputTruncated: scenario == "truncated", testReport: report
                )
                let validator = CompletionGateValidator(gate: "G01", version: scenario == "old-version" ? 1 : 2, operation: { _ in
                    CompletionGateResult(
                        gate: "G01", passed: true, summary: "Synthetic evaluator input; no product qualification claim",
                        evidenceReferences: [String(repeating: "e", count: 64)],
                        nativeEvidence: scenario == "missing" ? nil : evidence
                    )
                })
                let receipt = try await GateValidatorRegistry(validators: [validator], acceptancePolicy: policy).validate(run)
                XCTAssertEqual(receipt.passed, scenario == "fixture-pass", scenario)
                if !receipt.passed {
                    await assertAutonomyError(code: "completion_validation_failed") {
                        try await repository.recordTrustedCompletionValidation(receipt, for: run, lease: lease)
                    }
                }
            }
            let unconfigured = try GateValidatorRegistry(
                validators: [CompletionGateValidator(gate: "G01", version: 2, operation: { _ in
                    XCTFail("Unbound acceptance requirements must stop before job execution")
                    return CompletionGateResult(gate: "G01", passed: true, summary: "unreachable")
                })], acceptancePolicy: .correction001(caseBindings: [:])
            )
            let blocked = try await unconfigured.validate(run)
            XCTAssertFalse(blocked.passed)
            XCTAssertEqual(blocked.results.first?.blocker, .unregisteredValidator)
        }
    }

    func testQualificationSnapshotTracksInputsAndRejectsFilesystemAliases() async throws {
        try await withRepository { _, root in
            let project = root.appendingPathComponent("snapshot-inputs", isDirectory: true)
            let sources = project.appendingPathComponent("Sources", isDirectory: true)
            try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
            let source = sources.appendingPathComponent("Subject.swift")
            try Data("original source".utf8).write(to: source)
            let snapshotter = try QualificationInputSnapshotter(root: project, inputs: ["Sources", "Tests"])
            let original = try await snapshotter.capture()
            XCTAssertEqual(original.files.count, 1)
            XCTAssertEqual(original.absentInputs, ["Tests"])
            try Data("new evidence".utf8).write(to: project.appendingPathComponent("evidence.json"))
            let afterEvidence = try await snapshotter.capture()
            XCTAssertEqual(original.sha256, afterEvidence.sha256, "Evidence must not become a self-referential qualification input")
            try Data("changed source".utf8).write(to: source)
            let changed = try await snapshotter.capture()
            XCTAssertNotEqual(original.sha256, changed.sha256)
            let alias = sources.appendingPathComponent("Alias.swift")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
            do {
                _ = try await snapshotter.capture()
                XCTFail("A linked input must not be followed")
            } catch let error as AutonomyError {
                XCTAssertTrue(error.localizedDescription.contains("without following links"))
            }
            try FileManager.default.removeItem(at: alias)
            try FileManager.default.linkItem(at: source, to: alias)
            do {
                _ = try await snapshotter.capture()
                XCTFail("Hard-linked input aliases must be rejected")
            } catch let error as AutonomyError {
                XCTAssertTrue(error.localizedDescription.contains("hard links"))
            }
            try FileManager.default.removeItem(at: alias)
            let bounded = try QualificationInputSnapshotter(root: project, inputs: ["Sources"], maximumBytes: 1)
            do {
                _ = try await bounded.capture()
                XCTFail("Qualification reads must enforce their byte budget")
            } catch let error as AutonomyError {
                XCTAssertTrue(error.localizedDescription.contains("byte budget"))
            }
        }
    }

    func testRecordedPayloadHashDoesNotApproveCompletion() async throws {
        for payload in ["failed command exit 1", "unrelated successful status query", "{\"passed\":true}"] {
            try await withRepository { repository, root in
                let fixture = try await makeRun(repository: repository, root: root)
                let lease = try await repository.acquireRunLease(
                    runID: fixture.run.runID, ownerID: "hash-rejection", policy: fixture.leasePolicy
                )
                var run = fixture.run
                for state in [AutonomousRunState.validating, .ready, .starting, .running, .validatingCompletion] {
                    var work = run.specification.work
                    let hash = JSONSupport.sha256Hex(payload)
                    work.evidenceReferences = [hash]
                    work.metadata["completion_gate.tests.proof_sha256"] = hash
                    run = try await repository.transitionAutonomousRun(
                        runID: run.runID, lease: lease,
                        transition: AutonomousRunTransition(
                            expectedState: run.state, expectedRevision: run.revision, nextState: state,
                            eventType: "hash_rejection_fixture", eventSummary: "Exercise untrusted result provenance",
                            work: work
                        )
                    )
                }
                let receipt = try await EvidenceBoundCompletionValidator().validate(run)
                XCTAssertFalse(receipt.passed, "Recorded payload is provenance only: \(payload)")
            }
        }
    }

    func testCompletionTransactionRejectsWrongAndDuplicateGateSets() async throws {
        for gates in [["tests"], ["unrelated"], ["tests", "tests"], ["tests", "unrelated"]] {
            try await withRepository { repository, root in
                let fixture = try await makeRun(repository: repository, root: root)
                let lease = try await repository.acquireRunLease(
                    runID: fixture.run.runID, ownerID: "gate-set-rejection", policy: fixture.leasePolicy
                )
                var run = fixture.run
                for state in [AutonomousRunState.validating, .ready, .starting, .running, .validatingCompletion] {
                    run = try await repository.transitionAutonomousRun(
                        runID: run.runID, lease: lease, transition: transition(run, to: state)
                    )
                }
                let receipt = try CompletionValidationReceipt.make(
                    runID: run.runID, expectedRevision: run.revision,
                    results: gates.map { CompletionGateResult(gate: $0, passed: true, summary: "fabricated") },
                    validatedAt: ISO8601.string(from: Date())
                )
                await assertAutonomyError(code: "completion_validation_failed") {
                    _ = try await repository.completeAutonomousRun(runID: run.runID, lease: lease, receipt: receipt)
                }
                let current = try await repository.autonomousRun(run.runID)
                XCTAssertEqual(current?.state, .validatingCompletion)
            }
        }
    }

    func testCoordinatorPersistsIntentAndOnlyValidatorCanCompleteRun() async throws {
        try await withRepository { repository, root in
            let fixture = try await makeRun(repository: repository, root: root)
            let lease = try await repository.acquireRunLease(
                runID: fixture.run.runID,
                ownerID: "direct-transition",
                policy: fixture.leasePolicy
            )
            var direct = fixture.run
            for state in [AutonomousRunState.validating, .ready, .starting, .running] {
                direct = try await repository.transitionAutonomousRun(
                    runID: direct.runID,
                    lease: lease,
                    transition: transition(direct, to: state)
                )
            }
            await assertAutonomyError(code: "completion_validation_required") {
                _ = try await repository.transitionAutonomousRun(
                    runID: direct.runID,
                    lease: lease,
                    transition: self.transition(direct, to: .completed)
                )
            }
            _ = try await repository.releaseRunLease(lease)

            let stepper = CompletionRequestStepper()
            let validator = try DeterministicCompletionValidator(validators: [
                CompletionGateValidator(gate: "tests") { _ in
                    CompletionGateResult(
                        gate: "tests",
                        passed: true,
                        summary: "Focused tests passed",
                        evidenceReferences: ["fixture:test"]
                    )
                },
            ])
            let coordinator = try ProjectRunCoordinator(
                runID: fixture.run.runID,
                repository: repository,
                managerID: "manager-completion",
                leasePolicy: fixture.leasePolicy,
                stepExecutor: stepper,
                completionValidator: validator,
                maximumSteps: 8
            )
            let result = try await coordinator.runActivation()
            XCTAssertEqual(result.finalState, .completed)
            let observedPersistedIntent = await stepper.observedPersistedIntent
            XCTAssertTrue(observedPersistedIntent)
            let completedValue = try await repository.autonomousRun(fixture.run.runID)
            let completed = try XCTUnwrap(completedValue)
            XCTAssertEqual(completed.state, .completed)
            XCTAssertNotNil(completed.completionRequestJSON)
        }
    }

    func testCoordinatorReloadsRunRevisionAfterExecutorReservesProviderSession() async throws {
        try await withRepository { repository, root in
            let fixture = try await makeRun(repository: repository, root: root)
            let stepper = RevisionAdvancingStepper(repository: repository)
            let validator = try DeterministicCompletionValidator(validators: [
                CompletionGateValidator(gate: "tests") { _ in
                    CompletionGateResult(gate: "tests", passed: true, summary: "passed")
                },
            ])
            let coordinator = try ProjectRunCoordinator(
                runID: fixture.run.runID,
                repository: repository,
                managerID: "manager-revision-refresh",
                leasePolicy: fixture.leasePolicy,
                stepExecutor: stepper,
                completionValidator: validator,
                maximumSteps: 8
            )

            let result = try await coordinator.runActivation()
            XCTAssertEqual(result.finalState, .paused)
            let storedValue = try await repository.autonomousRun(fixture.run.runID)
            let stored = try XCTUnwrap(storedValue)
            XCTAssertEqual(stored.state, .paused)
            XCTAssertEqual(stored.activeSessionID, "session-revision-refresh")
        }
    }

    func testManagerStartupReleasesExpiredLeaseAndActivatesWithoutGUIOwner() async throws {
        let clock = MutableAutonomyClock(Date(timeIntervalSince1970: 2_000))
        try await withRepository(clock: clock) { repository, root in
            let fixture = try await makeRun(repository: repository, root: root)
            _ = try await repository.acquireRunLease(
                runID: fixture.run.runID,
                ownerID: "crashed-manager",
                policy: fixture.leasePolicy
            )
            clock.advance(by: 31)
            let validator = try DeterministicCompletionValidator(validators: [
                CompletionGateValidator(gate: "tests") { _ in
                    CompletionGateResult(gate: "tests", passed: true, summary: "passed")
                },
            ], clock: clock)
            let stepper = IdleRunStepper()
            let supervisor = try AutonomySupervisor(
                repository: repository,
                maximumConcurrentRuns: 1,
                clock: clock
            ) { runID in
                try ProjectRunCoordinator(
                    runID: runID,
                    repository: repository,
                    managerID: "restarted-manager",
                    leasePolicy: fixture.leasePolicy,
                    stepExecutor: stepper,
                    completionValidator: validator,
                    clock: clock,
                    maximumSteps: 8
                )
            }
            let report = try await supervisor.recoverOnManagerStart()
            XCTAssertEqual(report.releasedExpiredLeases, 1)
            XCTAssertEqual(report.activatedRuns, [fixture.run.runID])
            for _ in 0..<2_000 {
                let snapshot = await supervisor.snapshot()
                if snapshot.activeRunIDs.isEmpty, !snapshot.recentResults.isEmpty { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            let snapshot = await supervisor.snapshot()
            XCTAssertTrue(snapshot.activeRunIDs.isEmpty)
            XCTAssertEqual(snapshot.recentResults.last?.finalState, .running)
            let recoveredValue = try await repository.autonomousRun(fixture.run.runID)
            let recovered = try XCTUnwrap(recoveredValue)
            XCTAssertEqual(recovered.state, .running)
            await supervisor.shutdown()
        }
    }

    func testSupervisorShutdownWaitsForCoordinatorCancellationCleanup() async throws {
        try await withRepository { repository, root in
            let fixture = try await makeRun(repository: repository, root: root)
            let coordinator = DelayedStopCoordinator(runID: fixture.run.runID)
            let supervisor = try AutonomySupervisor(
                repository: repository,
                maximumConcurrentRuns: 1
            ) { _ in coordinator }

            _ = try await supervisor.recoverOnManagerStart()
            for _ in 0..<2_000 {
                if await coordinator.hasStarted() { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            let didStart = await coordinator.hasStarted()
            XCTAssertTrue(didStart)

            await supervisor.shutdown()

            let didStop = await coordinator.hasStopped()
            let didFinishCleanup = await coordinator.hasFinishedCleanup()
            XCTAssertTrue(didStop)
            XCTAssertTrue(didFinishCleanup)
            let snapshot = await supervisor.snapshot()
            XCTAssertFalse(snapshot.acceptingRuns)
            XCTAssertTrue(snapshot.activeRunIDs.isEmpty)
        }
    }

    func testLongExternalStepRenewsLeaseAndPreventsDuplicateOwner() async throws {
        let clock = MutableAutonomyClock(Date(timeIntervalSince1970: 3_000))
        try await withRepository(clock: clock) { repository, root in
            let fixture = try await makeRun(repository: repository, root: root)
            let sleeper = ControlledAutonomySleeper()
            let stepper = BlockingRunStepper()
            let validator = try DeterministicCompletionValidator(validators: [
                CompletionGateValidator(gate: "tests") { _ in
                    CompletionGateResult(gate: "tests", passed: true, summary: "passed")
                },
            ], clock: clock)
            let coordinator = try ProjectRunCoordinator(
                runID: fixture.run.runID,
                repository: repository,
                managerID: "manager-long-step",
                leasePolicy: fixture.leasePolicy,
                stepExecutor: stepper,
                completionValidator: validator,
                clock: clock,
                sleeper: sleeper,
                maximumSteps: 8
            )
            let activation = Task { try await coordinator.runActivation() }
            for _ in 0..<2_000 {
                let started = await stepper.hasStartedValue()
                let requests = await sleeper.currentRequestCount()
                if started, requests > 0 { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            let didStart = await stepper.hasStartedValue()
            let requestCount = await sleeper.currentRequestCount()
            XCTAssertTrue(didStart)
            XCTAssertGreaterThan(requestCount, 0)

            clock.advance(by: 20)
            await sleeper.resumeOne()
            for _ in 0..<2_000 {
                let lease = try await repository.runLease(fixture.run.runID)
                if lease?.renewedAt == ISO8601.string(from: clock.now()) { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            let renewedValue = try await repository.runLease(fixture.run.runID)
            let renewed = try XCTUnwrap(renewedValue)
            XCTAssertEqual(renewed.renewedAt, ISO8601.string(from: clock.now()))

            clock.advance(by: 20)
            await assertAutonomyError(code: "autonomous_run_lease_conflict") {
                _ = try await repository.acquireRunLease(
                    runID: fixture.run.runID,
                    ownerID: "duplicate-manager",
                    policy: fixture.leasePolicy
                )
            }
            await stepper.finish()
            let result = try await activation.value
            XCTAssertEqual(result.finalState, .paused)
        }
    }

    func testRetryJitterSeedIsStableAcrossProcessHashRandomization() throws {
        let runID = RunID(UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!)
        let seed = AutonomyRetryPolicy.deterministicSeed(runID: runID, attempt: 3)
        XCTAssertEqual(String(seed, radix: 16), "4f82c472d15be8ba")
        let policy = AutonomyRetryPolicy()
        XCTAssertEqual(
            try policy.delay(attempt: 3, deterministicSeed: seed),
            try policy.delay(attempt: 3, deterministicSeed: seed)
        )
    }

    private func makeProviderToolContext(
        repository: ProjectControlPlaneRepository,
        run: AutonomousRunRecord,
        lease: RunLease,
        sessionID: String
    ) async throws -> (turn: ProviderTurnIntent, context: ToolInvocationContext) {
        try await repository.reserveProviderSession(
            ProviderSessionIntent(
                sessionID: sessionID,
                runID: run.runID,
                projectID: run.projectID,
                projectGeneration: run.projectGeneration,
                providerID: "lmstudio",
                adapterID: "lmstudio-rest",
                modelKey: "fixture-model",
                providerResponseID: "response-root",
                idempotencyKey: "\(sessionID)-key"
            ),
            lease: lease
        )
        let turn = ProviderTurnIntent(
            runID: run.runID,
            sessionID: sessionID,
            projectID: run.projectID,
            projectGeneration: run.projectGeneration,
            kind: .normalContinuation,
            idempotencyKey: "\(sessionID)-turn",
            previousResponseID: "response-root",
            inputSHA256: String(repeating: "c", count: 64)
        )
        _ = try await repository.persistProviderTurnIntent(turn, lease: lease)
        return (
            turn,
            try await repository.invocationContext(
                for: ProjectBindingOwner(kind: .providerSession, id: sessionID),
                clientID: ClientID("\(sessionID)-client")
            )
        )
    }

    private func makeReconciledInvocationRecord(
        run: AutonomousRunRecord,
        call: BrokeredToolCall,
        descriptor: String?
    ) throws -> ToolInvocationRecord {
        let timestamp = ISO8601.string(from: Date())
        return ToolInvocationRecord(
            invocationID: UUID(),
            turnID: UUID(),
            runID: run.runID,
            sessionID: "reconciliation-fixture",
            projectID: run.projectID,
            projectGeneration: run.projectGeneration,
            providerCallID: call.providerCallID,
            toolName: call.toolName,
            replayClass: .reconciled,
            idempotencyKey: call.idempotencyKey,
            argumentsSHA256: JSONSupport.sha256Hex(
                try JSONSupport.canonicalJSON(call.arguments)
            ),
            reconciliationDescriptor: descriptor,
            state: .ambiguous,
            resultSHA256: nil,
            resultSummary: nil,
            lastErrorCode: "manager_interrupted",
            lastErrorSummary: "Fixture interruption",
            createdAt: timestamp,
            updatedAt: timestamp
        )
    }

    private func runGit(_ arguments: [String], in directory: URL) throws -> ProcessResult {
        try ProcessRunner().run(
            executable: "/usr/bin/git",
            arguments: arguments,
            currentDirectory: directory.path,
            timeoutSec: 5,
            maximumOutputBytes: 64 * 1_024
        )
    }

    private func makeRun(
        repository: ProjectControlPlaneRepository,
        root: URL,
        allowedTools: [String] = ["fixture.read"],
        completionGates: [String] = ["tests"]
    ) async throws -> RunFixture {
        let projectID = ProjectID()
        let projectRoot = root.appendingPathComponent("project", isDirectory: true)
        _ = try await repository.registerProjectUnchecked(
            projectID: projectID,
            displayName: "Autonomy Fixture",
            canonicalRoot: projectRoot
        )
        let request = AutonomousRunRequest(
            projectID: projectID,
            projectGeneration: .initial,
            mission: "Complete the deterministic fixture",
            providerID: "lmstudio",
            modelKey: "fixture-model",
            specification: AutonomousRunSpecification(
                allowedTools: allowedTools,
                completionGates: completionGates
            ),
            authorizationScope: ToolAuthorizationScope(
                canonicalRoots: [projectRoot],
                allowedTools: Set(allowedTools),
                networkAllowed: false,
                maximumInlineOutputBytes: 64 * 1_024
            )
        )
        let run = try await repository.createAutonomousRun(request)
        return RunFixture(run: run, leasePolicy: RunLeasePolicy(
            duration: 30,
            renewalInterval: 5,
            maximumDuration: 300
        ))
    }

    private func transition(
        _ run: AutonomousRunRecord,
        to state: AutonomousRunState
    ) -> AutonomousRunTransition {
        AutonomousRunTransition(
            expectedState: run.state,
            expectedRevision: run.revision,
            nextState: state,
            eventType: "test_transition",
            eventSummary: "Fixture transition"
        )
    }

    private func withRepository(
        clock: any Clock = SystemClock(),
        _ body: (ProjectControlPlaneRepository, URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-autonomy-\(UUID().uuidString)", isDirectory: true)
        let repository = try ProjectControlPlaneRepository(
            databaseURL: root.appendingPathComponent("control-plane.sqlite3"),
            clock: clock
        )
        do {
            try await body(repository, root)
        } catch {
            await repository.close()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        await repository.close()
        try? FileManager.default.removeItem(at: root)
    }

    private func assertAutonomyError(
        code: String,
        operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected autonomy error \(code)", file: file, line: line)
        } catch let error as AutonomyError {
            XCTAssertEqual(error.code, code, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}

private actor SourceSchedulingFixture {
    let references: [ContinuityBootstrapRecoveryReference]
    let failedRows: Set<Int64>
    let disabledRows: Set<Int64>
    let revokeAfterDiscovery: Set<Int64>
    private var enabled: Bool
    private var admissions: [Int64: Int] = [:]
    private var cursors: [Int64?] = []
    private var limits: [Int] = []

    init(references: [ContinuityBootstrapRecoveryReference], failedRows: Set<Int64> = [],
         disabledRows: Set<Int64> = [], revokeAfterDiscovery: Set<Int64> = [], enabled: Bool = true) {
        self.references = references
        self.failedRows = failedRows
        self.disabledRows = disabledRows
        self.revokeAfterDiscovery = revokeAfterDiscovery
        self.enabled = enabled
    }

    func enable() { enabled = true }
    func admissionCount(_ row: Int64) -> Int { admissions[row, default: 0] }
    func scannedCursors() -> [Int64?] { cursors }
    func requestedLimits() -> [Int] { limits }
    func discover(_ cursor: Int64?, limit: Int) throws -> ContinuityBootstrapRecoveryPage {
        cursors.append(cursor)
        limits.append(limit)
        guard enabled else { return ContinuityBootstrapRecoveryPage(references: [], diagnostics: [], nextRowID: nil) }
        let page = Array(references.filter { $0.rowID > (cursor ?? 0) }.prefix(limit))
        return ContinuityBootstrapRecoveryPage(references: page, diagnostics: [],
            nextRowID: page.count == limit ? page.last?.rowID : nil)
    }
    func admit(_ reference: ContinuityBootstrapRecoveryReference) throws -> Bool {
        admissions[reference.rowID, default: 0] += 1
        if failedRows.contains(reference.rowID) { throw ContinuityIngressError.integrityFailure("malformed scheduler fixture") }
        return !disabledRows.contains(reference.rowID)
            && !(revokeAfterDiscovery.contains(reference.rowID) && admissions[reference.rowID, default: 0] > 1)
    }
}

private actor SourceAdmissionBarrier {
    private var count = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func isWaiting() -> Bool { continuation != nil }
    func admit() async -> Bool {
        count += 1
        if count > 1 && !released {
            await withCheckedContinuation { continuation = $0 }
        }
        return true
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor NativeGateInputFixture {
    private let changesSource: Bool
    private var calls = 0

    init(changesSource: Bool) { self.changesSource = changesSource }

    func next() throws -> NativeGateInputs {
        calls += 1
        return try NativeGateInputs(
            sourceManifestSHA256: String(repeating: changesSource && calls > 1 ? "f" : "a", count: 64),
            buildIdentity: "build", policyRevision: "policy-v1", environmentIdentity: "macOS-fixture"
        )
    }
}

private struct RunFixture {
    let run: AutonomousRunRecord
    let leasePolicy: RunLeasePolicy
}

private final class MutableAutonomyClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(interval)
        lock.unlock()
    }
}

private final class CountingToolExecutor: ToolExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var toolNames: [String] { ["fixture.upsert", "external.send"] }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func call(name: String, arguments: [String: Any], clientID: ClientID) throws -> ToolResult {
        execute(arguments)
    }

    func call(name: String, arguments: [String: Any], context: ToolInvocationContext) throws -> ToolResult {
        execute(arguments)
    }

    private func execute(_ arguments: [String: Any]) -> ToolResult {
        lock.lock()
        count += 1
        lock.unlock()
        return .success(arguments)
    }
}

private final class RecoveryToolExecutor: ToolExecuting, @unchecked Sendable {
    enum Interruption: Error {
        case afterDispatch
    }

    private let lock = NSLock()
    private let interruptAfterDispatch: Bool
    private var count = 0

    init(interruptAfterDispatch: Bool) {
        self.interruptAfterDispatch = interruptAfterDispatch
    }

    var toolNames: [String] { ["fs_delete_recovery"] }

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
        try execute(name: name, arguments: arguments)
    }

    func call(
        name: String,
        arguments: [String: Any],
        context: ToolInvocationContext
    ) throws -> ToolResult {
        try execute(name: name, arguments: arguments)
    }

    private func execute(
        name: String,
        arguments: [String: Any]
    ) throws -> ToolResult {
        guard name == "fs_delete_recovery",
              let action = arguments["action"] as? String else {
            throw AutonomyError.invalidRequest("invalid recovery fixture call")
        }
        lock.lock()
        count += 1
        lock.unlock()
        if interruptAfterDispatch {
            throw Interruption.afterDispatch
        }
        return .success(["action": action])
    }
}

private final class InterruptingFilesystemEditExecutor: ToolExecuting, @unchecked Sendable {
    enum Interruption: Error {
        case afterEffect
    }

    private let lock = NSLock()
    private var count = 0

    var toolNames: [String] { ["fs_edit"] }

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
        try execute(name: name, arguments: arguments)
    }

    func call(
        name: String,
        arguments: [String: Any],
        context: ToolInvocationContext
    ) throws -> ToolResult {
        try execute(name: name, arguments: arguments)
    }

    private func execute(
        name: String,
        arguments: [String: Any]
    ) throws -> ToolResult {
        guard name == "fs_edit",
              let path = arguments["path"] as? String,
              let old = arguments["old"] as? String,
              let new = arguments["new"] as? String else {
            throw AutonomyError.invalidRequest("invalid filesystem fixture call")
        }
        lock.lock()
        count += 1
        lock.unlock()
        let url = URL(fileURLWithPath: path)
        let source = try String(contentsOf: url, encoding: .utf8)
        guard source.contains(old) else {
            throw AutonomyError.invalidRequest("filesystem fixture precondition changed")
        }
        try source.replacingOccurrences(of: old, with: new)
            .write(to: url, atomically: true, encoding: .utf8)
        throw Interruption.afterEffect
    }
}

private final class InterruptingFilesystemDeleteExecutor: ToolExecuting, @unchecked Sendable {
    enum Interruption: Error {
        case afterEffect
    }

    private let lock = NSLock()
    private var count = 0

    var toolNames: [String] { ["fs_delete"] }

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
        try execute(name: name, arguments: arguments)
    }

    func call(
        name: String,
        arguments: [String: Any],
        context: ToolInvocationContext
    ) throws -> ToolResult {
        try execute(name: name, arguments: arguments)
    }

    private func execute(
        name: String,
        arguments: [String: Any]
    ) throws -> ToolResult {
        guard name == "fs_delete",
              let path = arguments["path"] as? String else {
            throw AutonomyError.invalidRequest("invalid protected delete fixture call")
        }
        lock.lock()
        count += 1
        lock.unlock()
        try FileManager.default.removeItem(atPath: path)
        throw Interruption.afterEffect
    }
}

private actor CompletionRequestStepper: ProjectRunStepExecuting {
    private var issued = false
    private(set) var observedPersistedIntent = false

    func prepareNextStep(for run: AutonomousRunRecord) async throws -> RunSideEffectIntent? {
        guard !issued else { return nil }
        issued = true
        return RunSideEffectIntent(
            kind: .completionValidation,
            idempotencyKey: "completion-request",
            payloadSHA256: String(repeating: "c", count: 64),
            summary: "Request deterministic completion"
        )
    }

    func execute(
        _ intent: RunSideEffectIntent,
        run: AutonomousRunRecord,
        context: ToolInvocationContext,
        lease: RunLease
    ) async throws -> ProjectRunStepOutcome {
        observedPersistedIntent = run.specification.work.pendingIntent == intent
        return .completionRequested("Validate the declared gates")
    }

    func cancel(runID: RunID) async {}
}

private actor IdleRunStepper: ProjectRunStepExecuting {
    func prepareNextStep(for run: AutonomousRunRecord) async throws -> RunSideEffectIntent? { nil }

    func execute(
        _ intent: RunSideEffectIntent,
        run: AutonomousRunRecord,
        context: ToolInvocationContext,
        lease: RunLease
    ) async throws -> ProjectRunStepOutcome {
        .continued(run.specification.work)
    }

    func cancel(runID: RunID) async {}
}

private actor RevisionAdvancingStepper: ProjectRunStepExecuting {
    private let repository: ProjectControlPlaneRepository
    private var issued = false

    init(repository: ProjectControlPlaneRepository) {
        self.repository = repository
    }

    func prepareNextStep(for run: AutonomousRunRecord) async throws -> RunSideEffectIntent? {
        guard !issued else { return nil }
        issued = true
        return RunSideEffectIntent(
            kind: .providerTurn,
            idempotencyKey: "revision-refresh-provider-turn",
            payloadSHA256: String(repeating: "e", count: 64),
            summary: "Reserve a provider session during execution"
        )
    }

    func execute(
        _ intent: RunSideEffectIntent,
        run: AutonomousRunRecord,
        context: ToolInvocationContext,
        lease: RunLease
    ) async throws -> ProjectRunStepOutcome {
        try await repository.reserveProviderSession(
            ProviderSessionIntent(
                sessionID: "session-revision-refresh",
                runID: run.runID,
                projectID: run.projectID,
                projectGeneration: run.projectGeneration,
                providerID: "lmstudio",
                adapterID: "lmstudio-rest",
                modelKey: "fixture-model",
                idempotencyKey: "session-revision-refresh-key"
            ),
            lease: lease
        )
        return .paused("Provider session reservation advanced the durable revision")
    }

    func cancel(runID: RunID) async {}
}

private actor ControlledAutonomySleeper: AutonomySleeping {
    private var requests = 0
    private var permits = 0

    func currentRequestCount() -> Int { requests }

    func sleep(for duration: Duration) async throws {
        requests += 1
        while permits == 0 {
            try Task.checkCancellation()
            await Task.yield()
        }
        permits -= 1
    }

    func resumeOne() { permits += 1 }
}

private actor BlockingRunStepper: ProjectRunStepExecuting {
    private var started = false
    private var released = false
    private var issued = false

    func hasStartedValue() -> Bool { started }

    func prepareNextStep(for run: AutonomousRunRecord) async throws -> RunSideEffectIntent? {
        guard !issued else { return nil }
        issued = true
        return RunSideEffectIntent(
            kind: .providerTurn,
            idempotencyKey: "long-provider-turn",
            payloadSHA256: String(repeating: "d", count: 64),
            summary: "Execute a controlled long provider turn"
        )
    }

    func execute(
        _ intent: RunSideEffectIntent,
        run: AutonomousRunRecord,
        context: ToolInvocationContext,
        lease: RunLease
    ) async throws -> ProjectRunStepOutcome {
        started = true
        while !released {
            try Task.checkCancellation()
            await Task.yield()
        }
        return .paused("Long-step fixture completed")
    }

    func finish() { released = true }
    func cancel(runID: RunID) async { released = true }
}

private actor DelayedStopCoordinator: ProjectRunCoordinating {
    nonisolated let runID: RunID
    private var started = false
    private var stopped = false
    private var finishedCleanup = false

    init(runID: RunID) {
        self.runID = runID
    }

    func hasStarted() -> Bool { started }
    func hasStopped() -> Bool { stopped }
    func hasFinishedCleanup() -> Bool { finishedCleanup }

    func runActivation() async throws -> ProjectRunActivationResult {
        started = true
        while !stopped { await Task.yield() }
        for _ in 0..<250 { await Task.yield() }
        finishedCleanup = true
        return ProjectRunActivationResult(
            runID: runID,
            finalState: .running,
            stepsExecuted: 0,
            yielded: true
        )
    }

    func stop() async {
        stopped = true
    }
}
