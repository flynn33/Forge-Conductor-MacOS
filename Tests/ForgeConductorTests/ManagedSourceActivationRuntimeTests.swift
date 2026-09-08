// Actual native source transfer and broker consumption with a bounded transport fixture.

import XCTest
#if SWIFT_PACKAGE
import ForgeNativeSessionHostPlugin
#endif
@testable import ForgeConductorCore

final class ManagedSourceActivationRuntimeTests: XCTestCase {
    func testCancellingResumedSourceCannotStopALaterOperationInTheSameRun() async throws {
        try await withFixture(automatic: true) { fixture in
            let repository = fixture.app.projectContexts.repository
            let lease = try await repository.acquireRunLease(runID: fixture.acceptance.runID, ownerID: "resumed-source-control")
            let (worker, broker, activated) = try await activateForOrdinaryStep(fixture, lease: lease)
            let stepper = try ordinaryStepper(fixture, worker: worker, broker: broker)
            let intent = try sourceContinuationUnwrap(try await stepper.prepareNextStep(for: activated))
            let pending = try await repository.persistRunSideEffectIntent(runID: activated.runID, lease: lease,
                expectedRevision: activated.revision, intent: intent)
            let context = try await repository.invocationContext(for: .init(kind: .providerSession,
                id: XCTUnwrap(pending.activeSessionID)))
            let outcome = try await stepper.execute(intent, run: pending, context: context, lease: lease)
            guard case .continued(let work) = outcome else { return XCTFail("Actual tool output consumption must precede cancellation") }
            XCTAssertTrue(try fixture.operation().isResumed)
            let resumed = try sourceContinuationUnwrap(try await repository.autonomousRun(pending.runID))
            let laterOperation = UUID()
            let later = try await repository.transitionAutonomousRun(runID: resumed.runID, lease: lease,
                transition: .init(expectedState: .running, expectedRevision: resumed.revision, nextState: .running,
                    eventType: "source_control_fixture", eventSummary: "Begin independent work after observed source resumption",
                    work: work, activeOperationID: laterOperation))
            let beforeCalls = await fixture.transport.snapshot()
            let cancellation = try await repository.requestContinuityOperationCancellation(
                operationID: fixture.acceptance.operationID, taskID: fixture.taskSetup.record.authorization.taskID,
                correlation: fixture.taskSetup.correlation, context: fixture.sourceContext, owner: fixture.sourceOwner)
            XCTAssertEqual(cancellation.disposition, .alreadyTerminal)
            XCTAssertEqual(cancellation.snapshot.state, .resumed)
            XCTAssertEqual(cancellation.snapshot.terminalReceipt?.outcome, .resumed)
            XCTAssertNil(cancellation.request)
            let unchanged = try await repository.autonomousRun(later.runID)
            XCTAssertEqual(unchanged, later)
            XCTAssertEqual(unchanged?.activeOperationID, laterOperation)
            let retainedLease = try await repository.runLease(later.runID)
            XCTAssertEqual(retainedLease, lease)
            let requests = try await repository.pendingContinuityOperationCancellations()
            XCTAssertTrue(requests.references.isEmpty)
            let afterCalls = await fixture.transport.snapshot()
            XCTAssertEqual(afterCalls.roots.count, beforeCalls.roots.count)
            XCTAssertEqual(afterCalls.followups.count, beforeCalls.followups.count)
            _ = try await repository.releaseRunLease(lease)
        }
    }

    func testSourceTransitionPreservesOperationUntilActualResumption() async throws {
        try await withFixture(automatic: true) { fixture in
            let repository = fixture.app.projectContexts.repository
            let lease = try await repository.acquireRunLease(runID: fixture.acceptance.runID, ownerID: "source-transition-owner")
            let (worker, broker, activated) = try await activateForOrdinaryStep(fixture, lease: lease)
            let stepper = try ordinaryStepper(fixture, worker: worker, broker: broker,
                budget: SourceContinuationBudgetFixture(action: .emergency, stopBefore: true))
            let intent = try sourceContinuationUnwrap(try await stepper.prepareNextStep(for: activated))
            let pending = try await repository.persistRunSideEffectIntent(runID: activated.runID, lease: lease,
                expectedRevision: activated.revision, intent: intent)
            let context = try await repository.invocationContext(for: .init(kind: .providerSession,
                id: XCTUnwrap(pending.activeSessionID)))
            let outcome = try await stepper.execute(intent, run: pending, context: context, lease: lease)
            guard case .waitingResource = outcome else { return XCTFail("Expected a real source budget stop before ordinary dispatch") }
            XCTAssertFalse(try fixture.operation().isResumed)

            let preserved = try await repository.transitionAutonomousRun(runID: pending.runID, lease: lease,
                transition: .init(expectedState: .running, expectedRevision: pending.revision, nextState: .running,
                    eventType: "source_transition_fixture", eventSummary: "Preserve current source operation"))
            XCTAssertEqual(preserved.activeOperationID, fixture.acceptance.operationID)
            let same = try await repository.transitionAutonomousRun(runID: pending.runID, lease: lease,
                transition: .init(expectedState: .running, expectedRevision: preserved.revision, nextState: .running,
                    eventType: "source_transition_fixture", eventSummary: "Retain exact source operation",
                    activeSessionID: activated.activeSessionID, activeOperationID: fixture.acceptance.operationID))
            XCTAssertEqual(same.activeOperationID, fixture.acceptance.operationID)
            let foreignOperation = UUID()
            do {
                _ = try await repository.transitionAutonomousRun(runID: pending.runID, lease: lease,
                    transition: .init(expectedState: .running, expectedRevision: same.revision, nextState: .running,
                        eventType: "source_transition_fixture", eventSummary: "Attempt premature operation replacement",
                        activeOperationID: foreignOperation))
                XCTFail("An unresumed source operation was replaced without actual consumption proof")
            } catch { XCTAssertEqual(error as? ContinuitySourceActivationError, .conflict) }
            let retained = try sourceContinuationUnwrap(try await repository.autonomousRun(pending.runID))
            XCTAssertEqual(retained.activeOperationID, fixture.acceptance.operationID)
            XCTAssertEqual(retained.revision, same.revision)
            XCTAssertEqual(retained.specification.work.pendingIntent, intent)
            do {
                _ = try await repository.transitionAutonomousRun(runID: pending.runID, lease: lease,
                    transition: .init(expectedState: .running, expectedRevision: retained.revision, nextState: .running,
                        eventType: "source_transition_fixture", eventSummary: "Attempt premature candidate replacement",
                        activeSessionID: UUID().uuidString.lowercased()))
                XCTFail("An unresumed source candidate was replaced without actual consumption proof")
            } catch { XCTAssertEqual(error as? ContinuitySourceActivationError, .conflict) }
            let candidateRetained = try sourceContinuationUnwrap(try await repository.autonomousRun(pending.runID))
            XCTAssertEqual(candidateRetained.activeSessionID, activated.activeSessionID)
            XCTAssertEqual(candidateRetained.revision, same.revision)
            let requests = await fixture.transport.snapshot()
            XCTAssertEqual(requests.roots.count, 1)
            XCTAssertEqual(requests.followups.count, 1)
            _ = try await repository.releaseRunLease(lease)
        }

        try await withFixture(automatic: true) { fixture in
            let repository = fixture.app.projectContexts.repository
            let lease = try await repository.acquireRunLease(runID: fixture.acceptance.runID, ownerID: "source-transition-after-resumption")
            let (worker, broker, activated) = try await activateForOrdinaryStep(fixture, lease: lease)
            let stepper = try ordinaryStepper(fixture, worker: worker, broker: broker)
            let intent = try sourceContinuationUnwrap(try await stepper.prepareNextStep(for: activated))
            let pending = try await repository.persistRunSideEffectIntent(runID: activated.runID, lease: lease,
                expectedRevision: activated.revision, intent: intent)
            let context = try await repository.invocationContext(for: .init(kind: .providerSession,
                id: XCTUnwrap(pending.activeSessionID)))
            let outcome = try await stepper.execute(intent, run: pending, context: context, lease: lease)
            guard case .continued(let completedWork) = outcome else { return XCTFail("Expected actual source work and consumed output") }
            XCTAssertTrue(try fixture.operation().isResumed)
            let resumed = try sourceContinuationUnwrap(try await repository.autonomousRun(pending.runID))
            XCTAssertNil(resumed.activeOperationID)
            let nextOperation = UUID()
            let next = try await repository.transitionAutonomousRun(runID: resumed.runID, lease: lease,
                transition: .init(expectedState: .running, expectedRevision: resumed.revision, nextState: .running,
                    eventType: "source_transition_fixture", eventSummary: "Begin independent work after actual resumption",
                    work: completedWork, activeOperationID: nextOperation))
            XCTAssertEqual(next.activeOperationID, nextOperation)
            XCTAssertTrue(try fixture.operation().isResumed)
            _ = try await repository.releaseRunLease(lease)
        }
    }

    func testSourceTransitionRejectsAnotherRunsValidLease() async throws {
        try await withFixture(automatic: true) { fixture in
            let repository = fixture.app.projectContexts.repository
            let sourceLease = try await repository.acquireRunLease(runID: fixture.acceptance.runID, ownerID: "source-owning-manager")
            let (_, _, activated) = try await activateForOrdinaryStep(fixture, lease: sourceLease)
            let ordinary = try await repository.createAutonomousRun(.init(projectID: activated.projectID,
                projectGeneration: activated.projectGeneration, assignmentID: "independent-transition-assignment",
                mission: "Independent approved work", providerID: "lmstudio", adapterID: "forge.native-session-host",
                modelKey: "fixture/source-activation-model", specification: activated.specification,
                authorizationScope: fixture.acceptance.authorization.authorizationScope))
            let otherLease = try await repository.acquireRunLease(runID: ordinary.runID, ownerID: "independent-manager")
            do {
                _ = try await repository.transitionAutonomousRun(runID: activated.runID, lease: otherLease,
                    transition: .init(expectedState: .running, expectedRevision: activated.revision, nextState: .running,
                        eventType: "source_transition_fixture", eventSummary: "Attempt cross-run lease mutation"))
                XCTFail("A different run's lease mutated the source run")
            } catch { XCTAssertEqual(error as? AutonomyError, .staleLease) }
            let unchanged = try await repository.autonomousRun(activated.runID)
            XCTAssertEqual(unchanged, activated)
            let independentOperation = UUID()
            let independent = try await repository.transitionAutonomousRun(runID: ordinary.runID, lease: otherLease,
                transition: .init(expectedState: .created, expectedRevision: ordinary.revision, nextState: .validating,
                    eventType: "source_transition_fixture", eventSummary: "Preserve ordinary run transitions",
                    activeOperationID: independentOperation))
            XCTAssertEqual(independent.activeOperationID, independentOperation)
            XCTAssertEqual(independent.state, .validating)
            _ = try await repository.releaseRunLease(otherLease)
            _ = try await repository.releaseRunLease(sourceLease)
        }
    }

    func testAutomaticSourceResumesAfterAuthorizedReadAndExactOutputConsumption() async throws {
        try await withFixture(automatic: true) { fixture in
            try await runThroughConsumption(fixture)
        }
    }

    func testExplicitSourceResumesWhileAutomaticPolicyRemainsDisabled() async throws {
        try await withFixture(automatic: false) { fixture in
            XCTAssertFalse(try fixture.policy().policy.automaticHandoffEnabled)
            try await runThroughConsumption(fixture)
            XCTAssertFalse(try fixture.policy().policy.automaticHandoffEnabled)
        }
    }

    func testMissingHostRootRejectsReadWithoutProducingResumptionProof() async throws {
        try await withFixture(automatic: true) { fixture in
            _ = try fixture.app.config.update(["allowed_roots": [] as [String]])
            let repository = fixture.app.projectContexts.repository
            let lease = try await repository.acquireRunLease(runID: fixture.acceptance.runID, ownerID: "source-host-root-denial")
            let (worker, broker, activated) = try await activateForOrdinaryStep(fixture, lease: lease)
            let stepper = try ordinaryStepper(fixture, worker: worker, broker: broker)
            let intent = try sourceContinuationUnwrap(try await stepper.prepareNextStep(for: activated))
            let pending = try await repository.persistRunSideEffectIntent(runID: activated.runID, lease: lease,
                expectedRevision: activated.revision, intent: intent)
            let context = try await repository.invocationContext(for: .init(kind: .providerSession,
                id: XCTUnwrap(pending.activeSessionID)))
            do {
                _ = try await stepper.execute(intent, run: pending, context: context, lease: lease)
                XCTFail("The fixture must refuse a denied file result")
            } catch let error as ContinuityIngressError {
                guard case .integrityFailure = error else { throw error }
            }
            let observed = await fixture.transport.snapshot()
            guard let input = observed.followups.last?.input.first,
                  case .functionCallOutput(let callID, let output) = input else {
                return XCTFail("The actual denial must be returned through the ordinary provider path")
            }
            XCTAssertEqual(callID, "source-activation-file-call")
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
            XCTAssertEqual(payload["ok"] as? Bool, false)
            XCTAssertEqual(payload["code"] as? String, "path_outside_allowed_roots")
            XCTAssertFalse(observed.consumedMarker)
            XCTAssertFalse(try fixture.operation().isResumed)
            let run = try await repository.autonomousRun(fixture.acceptance.runID)
            XCTAssertEqual(run?.activeOperationID, fixture.acceptance.operationID)
            _ = try await repository.releaseRunLease(lease)
        }
    }

    func testWinnerAndCanonicalSealInterruptionsReplayWithoutAnotherProviderExchange() async throws {
        for crash in [ManagedContinuityCrashPoint.successorAcceptance, .predecessorFence] {
            try await withFixture(automatic: true) { fixture in
                let repository = fixture.app.projectContexts.repository
                let lease = try await repository.acquireRunLease(runID: fixture.acceptance.runID, ownerID: "source-seal-owner")
                let worker = try fixture.worker(crashAfter: crash)
                let broker = try ToolInvocationBroker(repository: repository, executor: fixture.app.tools,
                    classifier: ProductionToolReplayCatalog.classifier(productionToolNames: fixture.app.tools.toolNames))
                _ = try await worker.executeSourceBootstrap(acceptance: fixture.acceptance, lease: lease,
                    broker: broker, continuity: fixture.app.continuity,
                    policyResolver: { try fixture.app.config.budgetPolicySelection(scope: $0) })
                let acknowledged = try fixture.operation()
                XCTAssertEqual(acknowledged.state, .successorAcknowledged)
                do {
                    _ = try await worker.activateSourceBootstrap(acceptance: fixture.acceptance, lease: lease,
                        policyResolver: { try fixture.app.config.budgetPolicySelection(scope: $0) })
                    XCTFail("Expected interruption at the durable source boundary")
                } catch let error as ManagedContinuityWorkerError {
                    guard case .injectedCrash(let actual) = error else { throw error }
                    XCTAssertEqual(actual, crash)
                }
                do {
                    _ = try await repository.validateAutonomousRunExecutionAdmission(fixture.acceptance.runID)
                    XCTFail("Unfinished sealing released the source hold")
                } catch { XCTAssertEqual(error as? AutonomyError, .bootstrapRequired(fixture.acceptance.runID)) }
                let candidates = try await repository.providerSessions(operationID: fixture.acceptance.operationID)
                XCTAssertEqual(candidates.filter(\.accepted).count, 1)
                let before = try await repository.autonomousRun(fixture.acceptance.runID)
                _ = try await repository.releaseRunLease(lease)
                XCTAssertTrue(fixture.app.shutdown().completed)

                let reopened = try ForgeApp.bootstrap(home: fixture.app.paths.home)
                defer { _ = reopened.shutdown() }
                let resumedFixture = fixture.reopened(reopened)
                let resumedRepository = reopened.projectContexts.repository
                let newLease = try await resumedRepository.acquireRunLease(runID: fixture.acceptance.runID,
                    ownerID: "source-seal-recovery")
                let recoveredWorker = try resumedFixture.worker()
                let activated = try await recoveredWorker.activateSourceBootstrap(acceptance: fixture.acceptance,
                    lease: newLease, policyResolver: { try reopened.config.budgetPolicySelection(scope: $0) })
                XCTAssertEqual(activated.state, .running)
                XCTAssertEqual(activated.runID, before?.runID)
                XCTAssertEqual(activated.assignmentID, before?.assignmentID)
                XCTAssertEqual(activated.specification.resourceProfile, before?.specification.resourceProfile)
                XCTAssertEqual(activated.specification.allowedTools, before?.specification.allowedTools)
                XCTAssertEqual(activated.activeSessionID, acknowledged.successorSessionID?.uuidString.lowercased())
                XCTAssertEqual(activated.specification.work.metadata["provider_response_id"], "source-activation-ack")
                XCTAssertEqual(activated.activeOperationID, fixture.acceptance.operationID)
                let sealed = try resumedFixture.operation()
                XCTAssertEqual(sealed.state, .predecessorSealed)
                XCTAssertFalse(sealed.isResumed)
                XCTAssertNotNil(sealed.activationReceiptSHA256)
                let replay = try await recoveredWorker.activateSourceBootstrap(acceptance: fixture.acceptance,
                    lease: newLease, policyResolver: { try reopened.config.budgetPolicySelection(scope: $0) })
                XCTAssertEqual(replay, activated)
                XCTAssertEqual(try resumedFixture.operation(), sealed)
                let requests = await fixture.transport.snapshot()
                XCTAssertEqual(requests.roots.count, 1)
                XCTAssertEqual(requests.followups.count, 1)
                _ = try await resumedRepository.releaseRunLease(newLease)
            }
        }
    }

    func testSourceBudgetDeferralRetainsActualToolOutputUntilBudgetPermitsConsumption() async throws {
        for action in [ContextBudgetAction.checkpoint, .rollover, .emergency] {
            try await withFixture(automatic: true) { fixture in
                let repository = fixture.app.projectContexts.repository
                let lease = try await repository.acquireRunLease(runID: fixture.acceptance.runID, ownerID: "source-budget-owner")
                let (worker, broker, activated) = try await activateForOrdinaryStep(fixture, lease: lease)
                let budget = SourceContinuationBudgetFixture(action: action, stopBefore: false)
                let stepper = try ordinaryStepper(fixture, worker: worker, broker: broker, budget: budget)
                let intent = try sourceContinuationUnwrap(try await stepper.prepareNextStep(for: activated))
                let pending = try await repository.persistRunSideEffectIntent(runID: activated.runID, lease: lease,
                    expectedRevision: activated.revision, intent: intent)
                let context = try await repository.invocationContext(for: .init(kind: .providerSession,
                    id: XCTUnwrap(pending.activeSessionID)))
                let outcome = try await stepper.execute(intent, run: pending, context: context, lease: lease)
                guard case .waitingResource(let code, _) = outcome else { return XCTFail("Source output budget must defer the same pending step") }
                XCTAssertEqual(code, "source_continuation_budget_pending")
                let deferred = try sourceContinuationUnwrap(try await repository.autonomousRun(activated.runID))
                XCTAssertEqual(deferred.specification.work.pendingIntent, intent)
                XCTAssertEqual(deferred.activeOperationID, fixture.acceptance.operationID)
                XCTAssertFalse(try fixture.operation().isResumed)
                let invocation = try await repository.toolInvocation(sessionID: XCTUnwrap(deferred.activeSessionID),
                    providerCallID: "source-activation-file-call")
                XCTAssertEqual(invocation?.state, .completed)
                let before = await fixture.transport.snapshot()
                XCTAssertEqual(before.roots.count, 1)
                XCTAssertEqual(before.followups.count, 2)
                XCTAssertFalse(before.consumedMarker)

                await budget.allowConsumption()
                let retryStepper = try ordinaryStepper(fixture, worker: worker, broker: broker, budget: budget)
                let retried = try await retryStepper.execute(intent, run: deferred, context: context, lease: lease)
                guard case .continued = retried else { return XCTFail("The preserved exact output should resume after budget recovery") }
                XCTAssertTrue(try fixture.operation().isResumed)
                let after = await fixture.transport.snapshot()
                XCTAssertEqual(after.roots.count, 1)
                XCTAssertEqual(after.followups.count, 3)
                XCTAssertTrue(after.consumedMarker)
                let sameInvocation = try await repository.toolInvocation(sessionID: XCTUnwrap(deferred.activeSessionID),
                    providerCallID: "source-activation-file-call")
                XCTAssertEqual(sameInvocation?.invocationID, invocation?.invocationID)
                _ = try await repository.releaseRunLease(lease)
            }
        }
    }

    func testSourceBudgetBeforeAutomaticTurnCreatesNoContinuationEffect() async throws {
        try await withFixture(automatic: true) { fixture in
            let repository = fixture.app.projectContexts.repository
            let lease = try await repository.acquireRunLease(runID: fixture.acceptance.runID, ownerID: "source-preflight-budget")
            let (worker, broker, activated) = try await activateForOrdinaryStep(fixture, lease: lease)
            let stepper = try ordinaryStepper(fixture, worker: worker, broker: broker,
                budget: SourceContinuationBudgetFixture(action: .emergency, stopBefore: true))
            let intent = try sourceContinuationUnwrap(try await stepper.prepareNextStep(for: activated))
            let pending = try await repository.persistRunSideEffectIntent(runID: activated.runID, lease: lease,
                expectedRevision: activated.revision, intent: intent)
            let context = try await repository.invocationContext(for: .init(kind: .providerSession,
                id: XCTUnwrap(pending.activeSessionID)))
            let outcome = try await stepper.execute(intent, run: pending, context: context, lease: lease)
            guard case .waitingResource(let code, _) = outcome else { return XCTFail("Emergency budget must prevent the automatic source request") }
            XCTAssertEqual(code, "source_continuation_budget_pending")
            let observed = await fixture.transport.snapshot()
            XCTAssertEqual(observed.roots.count, 1)
            XCTAssertEqual(observed.followups.count, 1)
            let invocation = try await repository.toolInvocation(sessionID: XCTUnwrap(pending.activeSessionID),
                providerCallID: "source-activation-file-call")
            XCTAssertNil(invocation)
            XCTAssertFalse(try fixture.operation().isResumed)
            _ = try await repository.releaseRunLease(lease)
        }
    }

    func testResumptionCommitBeforeOutcomeApplyReplaysOriginalTurnIdentityAfterRestart() async throws {
        try await withFixture(automatic: true) { fixture in
            let repository = fixture.app.projectContexts.repository
            let lease = try await repository.acquireRunLease(runID: fixture.acceptance.runID, ownerID: "source-outcome-crash")
            let (worker, broker, activated) = try await activateForOrdinaryStep(fixture, lease: lease)
            let stepper = try ordinaryStepper(fixture, worker: worker, broker: broker, crashAfterResumption: true)
            let intent = try sourceContinuationUnwrap(try await stepper.prepareNextStep(for: activated))
            let pending = try await repository.persistRunSideEffectIntent(runID: activated.runID, lease: lease,
                expectedRevision: activated.revision, intent: intent)
            let context = try await repository.invocationContext(for: .init(kind: .providerSession,
                id: XCTUnwrap(pending.activeSessionID)))
            do {
                _ = try await stepper.execute(intent, run: pending, context: context, lease: lease)
                XCTFail("Expected interruption after actual CP resumption commit")
            } catch SourceContinuationFixtureError.afterResumptionCommit { }
            let committed = try sourceContinuationUnwrap(try await repository.autonomousRun(activated.runID))
            XCTAssertNil(committed.activeOperationID)
            XCTAssertEqual(committed.specification.work.pendingIntent, intent)
            XCTAssertTrue(try fixture.operation().isResumed)
            let roundID = sourceContinuationStableUUID("turn:\(intent.idempotencyKey):round:1")
            let priorTurn = try sourceContinuationUnwrap(try await repository.providerTurn(roundID))
            XCTAssertEqual(priorTurn.intent.operationID, fixture.acceptance.operationID)
            XCTAssertEqual(priorTurn.state, .completed)
            _ = try await repository.releaseRunLease(lease)
            XCTAssertTrue(fixture.app.shutdown().completed)

            let reopened = try ForgeApp.bootstrap(home: fixture.app.paths.home)
            defer { _ = reopened.shutdown() }
            let recovered = fixture.reopened(reopened)
            let recoveredBroker = try ToolInvocationBroker(repository: reopened.projectContexts.repository, executor: reopened.tools,
                classifier: ProductionToolReplayCatalog.classifier(productionToolNames: reopened.tools.toolNames))
            let recoveredStepper = try ordinaryStepper(recovered, worker: recovered.worker(), broker: recoveredBroker)
            let coordinator = try ProjectRunCoordinator(runID: activated.runID, repository: reopened.projectContexts.repository,
                managerID: "source-outcome-recovery", stepExecutor: recoveredStepper,
                completionValidator: EvidenceBoundCompletionValidator(), maximumSteps: 1)
            let result = try await coordinator.runActivation()
            XCTAssertEqual(result.finalState, .running)
            let applied = try sourceContinuationUnwrap(try await reopened.projectContexts.repository.autonomousRun(activated.runID))
            XCTAssertNil(applied.activeOperationID)
            XCTAssertNil(applied.specification.work.pendingIntent)
            XCTAssertEqual(applied.specification.work.metadata["provider_response_id"], "source-activation-consumed")
            let replayedTurn = try await reopened.projectContexts.repository.providerTurn(roundID)
            XCTAssertEqual(replayedTurn?.intent, priorTurn.intent)
            let observed = await fixture.transport.snapshot()
            XCTAssertEqual(observed.roots.count, 1)
            XCTAssertEqual(observed.followups.count, 3)
        }
    }

    private func activateForOrdinaryStep(_ fixture: SourceActivationRuntimeFixture, lease: RunLease) async throws
        -> (ManagedContinuityWorker, ToolInvocationBroker, AutonomousRunRecord) {
        let worker = try fixture.worker()
        let broker = try ToolInvocationBroker(repository: fixture.app.projectContexts.repository, executor: fixture.app.tools,
            classifier: ProductionToolReplayCatalog.classifier(productionToolNames: fixture.app.tools.toolNames))
        _ = try await worker.executeSourceBootstrap(acceptance: fixture.acceptance, lease: lease, broker: broker,
            continuity: fixture.app.continuity, policyResolver: { try fixture.app.config.budgetPolicySelection(scope: $0) })
        let run = try await worker.activateSourceBootstrap(acceptance: fixture.acceptance, lease: lease,
            policyResolver: { try fixture.app.config.budgetPolicySelection(scope: $0) })
        return (worker, broker, run)
    }

    private func ordinaryStepper(_ fixture: SourceActivationRuntimeFixture, worker: ManagedContinuityWorker,
        broker: ToolInvocationBroker, budget: any ManagedRunBudgetEvaluating = NoManagedRunBudgetEvaluator(),
        crashAfterResumption: Bool = false) throws -> ManagedProjectRunStepExecutor {
        let provider = try LMStudioManagedModelProvider(storageDirectory: fixture.app.paths.home.appendingPathComponent("source-ordinary-provider"),
            transport: fixture.transport)
        let catalog = try ToolDefinitionCatalog.production(toolNames: fixture.app.tools.toolNames)
        return try ManagedProjectRunStepExecutor(repository: fixture.app.projectContexts.repository,
            providerResolver: { _ in provider }, toolDefinitionResolver: { try catalog.providerToolDefinitions(allowedToolNames: $0) },
            broker: broker, budget: budget, sourceResumption: { run, lease in
                let result = try await worker.reconcileSourceResumption(run: run, lease: lease,
                    policyResolver: { try fixture.app.config.budgetPolicySelection(scope: $0) })
                if crashAfterResumption { throw SourceContinuationFixtureError.afterResumptionCommit }
                return result
            })
    }

    private func runThroughConsumption(_ fixture: SourceActivationRuntimeFixture) async throws {
        let runtime = try ManagedAutonomyRuntime(app: fixture.app, registry: fixture.registry(), maximumConcurrentRuns: 1)
        do {
            _ = try await runtime.start()
            var resumed = false
            for _ in 0..<400 {
                try await runtime.tick()
                if let operation = try ContinuityStateEngine(memory: fixture.app.projectMemory).sourceBootstrap(
                    operationID: fixture.acceptance.operationID, authorization: fixture.acceptance.authorization),
                   operation.isResumed { resumed = true; break }
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTAssertTrue(resumed, "A real broker read and consuming provider turn must reach canonical resumed proof")
            await runtime.shutdown()
            let operation = try fixture.operation()
            XCTAssertTrue(operation.isResumed)
            XCTAssertNotNil(operation.resumedReceiptSHA256)
            let run = try await fixture.app.projectContexts.repository.autonomousRun(fixture.acceptance.runID)
            XCTAssertNil(run?.activeOperationID)
            XCTAssertEqual(run?.continuationPending, false)
            XCTAssertNotEqual(run?.state, .completed, "This fixture does not satisfy its installed completion gate")
            let observed = await fixture.transport.snapshot()
            XCTAssertEqual(observed.roots.count, 1)
            XCTAssertEqual(observed.followups.count, 3)
            XCTAssertEqual(observed.followups.dropFirst().first?.previousResponseID, "source-activation-ack")
            XCTAssertEqual(observed.followups.last?.previousResponseID, "source-activation-work")
            XCTAssertTrue(observed.consumedMarker)
            let candidates = try await fixture.app.projectContexts.repository.providerSessions(operationID: fixture.acceptance.operationID)
            XCTAssertEqual(candidates.filter(\.accepted).count, 1)
        } catch {
            await runtime.shutdown()
            throw error
        }
    }

    private func withFixture(automatic: Bool, _ body: (SourceActivationRuntimeFixture) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("source-activation-runtime-\(UUID().uuidString)")
            .resolvingSymlinksInPath().standardizedFileURL
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("approved-work.txt")
        let marker = "Observed authorized continuation \(UUID().uuidString.lowercased())"
        try Data(marker.utf8).write(to: file)
        let app = try ForgeApp.bootstrap(home: root.appendingPathComponent("home"))
        defer { _ = app.shutdown(); try? FileManager.default.removeItem(at: root) }
        // The real file router requires both configured host roots and the
        // narrower native task scope; enrollment alone does not widen the host.
        _ = try app.config.update(["allowed_roots": [project.path]])
        let prior = try app.config.budgetPolicySelection(scope: .globalDefault)
        _ = try app.config.updateBudgetPolicy(.init(scope: .globalDefault, expectedRevision: prior.revision,
            expectedGlobalRevision: prior.globalRevision, operation: .set,
            policy: BudgetPolicy(automaticHandoffEnabled: automatic)))
        let initialized = try app.projectMemory.initializeUnchecked(path: project.path)
        let projectID = ProjectID(try XCTUnwrap((initialized["project_id"] as? String).flatMap(UUID.init(uuidString:))))
        let repository = app.projectContexts.repository
        _ = try await repository.registerProjectUnchecked(projectID: projectID, displayName: "Source activation", canonicalRoot: project)
        let client = ClientID("source-activation-client"), owner = ProjectBindingOwner(kind: .mcpClient, id: "source-activation-client")
        let scope = ToolAuthorizationScope(canonicalRoots: [project], writableRoots: [], allowedTools: ["context_get", "fs_read"],
            networkAllowed: false, maximumInlineOutputBytes: 65_536)
        let binding = try await repository.bind(owner: owner, projectID: projectID, generation: .initial, authorizationScope: scope)
        let context = binding.invocationContext(clientID: client)
        let assignment = try ContinuityTaskAssignment(assignmentID: "source-activation-assignment",
            assignmentBytes: Data("Read the approved work file and consume its exact contents".utf8),
            mission: "Read the approved work file", providerID: "lmstudio", adapterID: "forge.native-session-host",
            modelKey: "fixture/source-activation-model",
            specification: .init(allowedTools: ["context_get", "fs_read"], completionGates: ["fixture-not-installed"]),
            authorizationScope: scope)
        let setup = try await repository.authorizeContinuityTask(projectID: projectID, expectedGeneration: .initial,
            approvedAssignment: assignment, callerContext: context, callerOwner: owner)
        let committed = try app.store.handoffCommit(HandoffPacket(id: "source-activation-exact", source: .model,
            resumeReady: true, goal: "Read the approved work file once"), authorization: setup.record.authorization,
            automaticHandoffEnabled: automatic)
        let policy = try app.config.budgetPolicySelection(scope: .init(kind: .projectOverride,
            projectID: projectID.description, projectGeneration: 1))
        let acceptance: ContinuityIngressAcceptanceReceipt
        if automatic {
            acceptance = try await repository.acceptContinuityIngress(source: committed.revision,
                operationID: XCTUnwrap(committed.delivery?.operationID), policySelection: policy)
        } else {
            let submitted = try await app.continuity.submitAuthorizedHandoff(
                ContinuityExplicitHandoffRequest(arguments: ["continuity_id": committed.revision.identity.continuityID,
                    "idempotency_key": "explicit-activation"]),
                taskID: setup.record.authorization.taskID, correlation: setup.correlation,
                context: context, owner: owner, repository: repository, config: app.config)
            acceptance = submitted.acceptance
        }
        try await body(.init(app: app, acceptance: acceptance, taskSetup: setup, sourceContext: context, sourceOwner: owner,
            transport: SourceActivationRuntimeTransport(file: file, marker: marker)))
    }
}

private enum SourceContinuationFixtureError: Error { case afterResumptionCommit }

private func sourceContinuationUnwrap<T>(_ value: T?) throws -> T { try XCTUnwrap(value) }

private func sourceContinuationStableUUID(_ value: String) -> UUID {
    let hex = String(JSONSupport.sha256Hex(value).prefix(32))
    let text = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))"
    return UUID(uuidString: text)!
}

private actor SourceContinuationBudgetFixture: ManagedRunBudgetEvaluating {
    private var action: ContextBudgetAction
    private let stopBefore: Bool
    init(action: ContextBudgetAction, stopBefore: Bool) { self.action = action; self.stopBefore = stopBefore }
    func allowConsumption() { action = .normal }
    func evaluateBeforeProviderTurn(run: AutonomousRunRecord, sessionID: String,
        capabilities: ProviderCapabilities, serializedInputBytes: Int) async throws -> ContextBudgetAction {
        stopBefore ? action : .normal
    }
    func observeProviderTurn(_ turn: ProviderTurn, run: AutonomousRunRecord, sessionID: String,
        capabilities: ProviderCapabilities) async throws -> ContextBudgetAction { .normal }
    func observeToolResult(serializedBytes: Int, providerResponseID: String, run: AutonomousRunRecord,
        sessionID: String, capabilities: ProviderCapabilities) async throws -> ContextBudgetAction { action }
    func observeProviderOverflow(run: AutonomousRunRecord, sessionID: String,
        capabilities: ProviderCapabilities) async throws -> ContextBudgetAction { .emergency }
}

private struct SourceActivationRuntimeFixture: Sendable {
    let app: ForgeApp
    let acceptance: ContinuityIngressAcceptanceReceipt
    let taskSetup: AuthorizedContinuityTaskSetup
    let sourceContext: ToolInvocationContext
    let sourceOwner: ProjectBindingOwner
    let transport: SourceActivationRuntimeTransport

    func policy() throws -> BudgetPolicySelection {
        try app.config.budgetPolicySelection(scope: .init(kind: .projectOverride,
            projectID: acceptance.authorization.projectID.description, projectGeneration: 1))
    }

    func operation() throws -> ContinuitySourceBootstrapOperation {
        try XCTUnwrap(ContinuityStateEngine(memory: app.projectMemory).sourceBootstrap(
            operationID: acceptance.operationID, authorization: acceptance.authorization))
    }

    func reopened(_ app: ForgeApp) -> Self {
        .init(app: app, acceptance: acceptance, taskSetup: taskSetup, sourceContext: sourceContext,
            sourceOwner: sourceOwner, transport: transport)
    }

    func worker(crashAfter: ManagedContinuityCrashPoint? = nil) throws -> ManagedContinuityWorker {
        let adapter = try LMStudioManagedSessionHostAdapter(storageDirectory: app.paths.home.appendingPathComponent("activation-provider"),
            transport: transport)
        return ManagedContinuityWorker(repository: app.projectContexts.repository, memory: app.projectMemory,
            adapterResolver: { _ in adapter }, crashAfter: crashAfter)
    }

    func registry() -> HostAdapterRegistry {
        let registry = HostAdapterRegistry()
        registry.register(manifest: ForgeNativeSessionHostPlugin.manifest,
            managedProviderFactory: { try LMStudioManagedModelProvider(storageDirectory: $0, transport: transport) },
            factory: { try LMStudioManagedSessionHostAdapter(storageDirectory: $0, transport: transport) })
        return registry
    }
}

private actor SourceActivationRuntimeTransport: LMStudioManagedTransportObservedDispatching {
    private let file: URL
    private let marker: String
    private var roots: [LMStudioRootRequest] = []
    private var followups: [LMStudioContinuationRequest] = []
    private var consumedMarker = false

    init(file: URL, marker: String) { self.file = file; self.marker = marker }

    func probe() async throws -> LMStudioProviderCapabilities {
        LMStudioProviderCapabilities(modelKey: "fixture/source-activation-model", loadedInstanceID: "fixture/source-activation-model@32768",
            contextLength: 32_768, maximumContextLength: 131_072, parallelism: 1, flashAttention: true,
            trainedForToolUse: true, streamingVerified: true, functionToolContractVerified: true,
            usageReportingVerified: true, capabilityFingerprintSHA256: String(repeating: "a", count: 64),
            contractProbeResponseID: "source-activation-probe")
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
        guard roots.count < 4 else { throw ContinuityIngressError.capacityExceeded("fixture root requests") }
        roots.append(request)
        let identity = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(request.userInput.utf8)) as? [String: Any])
        let sourceID = try XCTUnwrap(identity["continuity_id"] as? String)
        return try turn(responseID: "source-activation-root", previousResponseID: nil, name: "context_get",
            arguments: ["handoff_id": sourceID], callID: "source-activation-context-call")
    }

    func continueSession(_ request: LMStudioContinuationRequest) async throws -> LMStudioResponseTurn {
        _ = try await preflightContinuation(request)
        guard followups.count < 8 else { throw ContinuityIngressError.capacityExceeded("fixture continuation requests") }
        followups.append(request)
        switch request.previousResponseID {
        case "source-activation-root":
            let definition = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(XCTUnwrap(request.tools.first))) as? [String: Any])
            let parameters = try XCTUnwrap(definition["parameters"] as? [String: Any])
            let properties = try XCTUnwrap(parameters["properties"] as? [String: [String: Any]])
            var values: [String: Any] = [:]
            for (key, property) in properties { values[key] = try XCTUnwrap(property["const"]) }
            return try turn(responseID: "source-activation-ack", previousResponseID: request.previousResponseID,
                name: "forge_continuity_ack", arguments: values, callID: "source-activation-ack-call")
        case "source-activation-ack":
            return try turn(responseID: "source-activation-work", previousResponseID: request.previousResponseID,
                name: "fs_read", arguments: ["path": file.path], callID: "source-activation-file-call")
        case "source-activation-work":
            guard request.input.count == 1,
                  case .functionCallOutput(let callID, let output) = request.input[0], callID == "source-activation-file-call" else {
                throw ContinuityIngressError.integrityFailure("fixture did not consume the exact authorized output")
            }
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
            guard payload["ok"] as? Bool == true, output.contains(marker) else {
                throw ContinuityIngressError.integrityFailure("fixture read did not return the authorized marker: \(String(output.prefix(2_048)))")
            }
            consumedMarker = true
            return LMStudioResponseTurn(responseID: "source-activation-consumed", previousResponseID: request.previousResponseID,
                model: "fixture/source-activation-model", status: "completed", assistantText: "The authorized work result was consumed.",
                functionCalls: [], usage: LMStudioUsage(inputTokens: 1_800, outputTokens: 80, totalTokens: 1_880))
        default:
            throw ContinuityIngressError.integrityFailure("unexpected source continuation parent")
        }
    }

    private func turn(responseID: String, previousResponseID: String?, name: String,
                      arguments: [String: Any], callID: String) throws -> LMStudioResponseTurn {
        LMStudioResponseTurn(responseID: responseID, previousResponseID: previousResponseID,
            model: "fixture/source-activation-model", status: "completed", assistantText: "",
            functionCalls: [.init(itemID: "item-\(callID)", callID: callID, name: name,
                arguments: String(decoding: try ForgeJSONCanonicalizationV1.data(from: arguments), as: UTF8.self))],
            usage: LMStudioUsage(inputTokens: 1_200, outputTokens: 80, totalTokens: 1_280))
    }

    func receipt(forIdempotencyKey key: String) async -> LMStudioResponseTurn? { nil }
    func cancel(operationID: String) async {}
    func snapshot() -> (roots: [LMStudioRootRequest], followups: [LMStudioContinuationRequest], consumedMarker: Bool) {
        (roots, followups, consumedMarker)
    }
}
