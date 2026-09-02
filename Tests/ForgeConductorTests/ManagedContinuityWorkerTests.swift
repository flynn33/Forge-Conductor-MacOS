import XCTest
@testable import ForgeConductorCore

final class ManagedContinuityWorkerTests: XCTestCase {
    func testCreateBootstrapCrashRestartsWithOneSuccessorAndOneAutomaticDispatch() async throws {
        let fixture = try await makeFixture(label: "restart")
        defer { fixture.destroy() }
        let adapter = ContinuityWorkerAdapter()
        let intent = continuityIntent(fixture.run)
        let persisted = try await fixture.repository.persistRunSideEffectIntent(
            runID: fixture.run.runID,
            lease: fixture.lease,
            expectedRevision: fixture.run.revision,
            intent: intent
        )
        let runContext = try await fixture.repository.invocationContext(
            for: ProjectBindingOwner(
                kind: .autonomousRun,
                id: persisted.runID.description
            )
        )
        let crashing = ManagedContinuityWorker(
            repository: fixture.repository,
            memory: fixture.memory,
            adapterResolver: { _ in adapter },
            crashAfter: .providerRootSideEffect
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await crashing.executeContinuityStep(
                intent: intent,
                run: persisted,
                context: runContext,
                lease: fixture.lease
            )
        }
        XCTAssertEqual(adapter.createCount, 1)
        let interruptedStoredRun = try await fixture.repository.autonomousRun(persisted.runID)
        let interruptedRun = try XCTUnwrap(interruptedStoredRun)
        let interruptedOperationID = try XCTUnwrap(interruptedRun.activeOperationID)
        let projectMemory = try fixture.memory.repositoryForProject(
            persisted.projectID.description
        )
        let interruptedOperation = try XCTUnwrap(
            try projectMemory.continuityOperationV2(
                id: interruptedOperationID.uuidString.lowercased()
            )
        )
        let interruptedHandoff = try XCTUnwrap(
            try projectMemory.continuityHandoffV2(id: interruptedOperation.handoffID)
        )
        let duplicateSessionID = "duplicate-\(UUID().uuidString.lowercased())"
        try await fixture.repository.reserveProviderSession(
            ProviderSessionIntent(
                sessionID: duplicateSessionID,
                runID: persisted.runID,
                projectID: persisted.projectID,
                projectGeneration: persisted.projectGeneration,
                providerID: "fixture-provider",
                adapterID: "fixture-v2-adapter",
                modelKey: "fixture/model",
                providerResponseID: "duplicate-response",
                predecessorSessionID: fixture.predecessorSessionID,
                handoffID: UUID(uuidString: interruptedHandoff.handoffID),
                operationID: interruptedOperationID,
                idempotencyKey: interruptedOperation.idempotencyKey,
                bootstrapNonceSHA256: JSONSupport.sha256Hex(
                    try XCTUnwrap(interruptedHandoff.bootstrapNonce)
                ),
                handoffSHA256: interruptedHandoff.contentSHA256,
                status: .candidate,
                accepted: false,
                contextCapacity: 65_536
            ),
            lease: fixture.lease
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.repository.invocationContext(
                for: ProjectBindingOwner(
                    kind: .providerSession,
                    id: fixture.predecessorSessionID
                )
            )
        }
        _ = try await fixture.repository.releaseRunLease(fixture.lease)
        await fixture.repository.close()
        fixture.memory.closeAll()

        let restartedRepository = try ProjectControlPlaneRepository(
            databaseURL: fixture.databaseURL
        )
        let restartedMemory = ProjectMemoryService(paths: fixture.paths)
        let worker = ManagedContinuityWorker(
            repository: restartedRepository,
            memory: restartedMemory,
            adapterResolver: { _ in adapter }
        )
        let executor = ContinuityOnlyStepExecutor(worker: worker)
        let coordinator = try ProjectRunCoordinator(
            runID: persisted.runID,
            repository: restartedRepository,
            managerID: "continuity-restart-manager",
            stepExecutor: executor,
            completionValidator: UnusedCompletionValidator(),
            maximumSteps: 1
        )
        let activation = try await coordinator.runActivation()
        XCTAssertEqual(activation.finalState, .running)
        XCTAssertEqual(adapter.createCount, 1)

        let resumedRun = try await restartedRepository.autonomousRun(persisted.runID)
        let operationString = try XCTUnwrap(
            resumedRun?.specification.work.metadata["continuity_operation_id"]
        )
        let operationID = try XCTUnwrap(UUID(uuidString: operationString))
        let candidates = try await restartedRepository.providerSessions(
            operationID: operationID
        )
        XCTAssertEqual(candidates.filter { $0.accepted && $0.status == .active }.count, 1)
        XCTAssertEqual(
            candidates.filter { $0.status == .quarantinedDuplicate }.map(\.sessionID),
            [duplicateSessionID]
        )
        let successor = try XCTUnwrap(candidates.first { $0.accepted })
        XCTAssertNotEqual(successor.sessionID, fixture.predecessorSessionID)
        let sealedPredecessor = try await restartedRepository.providerSession(
            fixture.predecessorSessionID
        )
        XCTAssertEqual(sealedPredecessor?.status, .sealed)
        _ = try await restartedRepository.invocationContext(
            for: ProjectBindingOwner(kind: .providerSession, id: successor.sessionID)
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await restartedRepository.invocationContext(
                for: ProjectBindingOwner(
                    kind: .providerSession,
                    id: fixture.predecessorSessionID
                )
            )
        }

        let lease = try await restartedRepository.acquireRunLease(
            runID: persisted.runID,
            ownerID: "automatic-continuation-dispatcher"
        )
        let pendingAutomatic = try await restartedRepository.pendingAutomaticContinuation(
            runID: persisted.runID
        )
        let automatic = try XCTUnwrap(pendingAutomatic)
        let exactInput = try ManagedContinuityWorker.automaticContinuationInput()
        XCTAssertEqual(automatic.intent.inputSHA256, JSONSupport.sha256Hex(exactInput))
        let provider = AutomaticContinuationFixtureProvider()
        let toolExecutor = ContinuityNoopToolExecutor()
        let broker = ToolInvocationBroker(
            repository: restartedRepository,
            executor: toolExecutor,
            classifier: try StaticToolReplayClassifier(
                productionToolNames: toolExecutor.toolNames,
                classifications: ["fixture.read": .readOnly]
            )
        )
        let managedStepper = try ManagedProjectRunStepExecutor(
            repository: restartedRepository,
            providerResolver: { adapterID in
                XCTAssertEqual(adapterID, "fixture-v2-adapter")
                return provider
            },
            toolDefinitionResolver: { _ in [] },
            broker: broker
        )
        let resumed = try XCTUnwrap(resumedRun)
        let preparedProviderIntent = try await managedStepper.prepareNextStep(for: resumed)
        let providerIntent = try XCTUnwrap(preparedProviderIntent)
        let providerRun = try await restartedRepository.persistRunSideEffectIntent(
            runID: persisted.runID,
            lease: lease,
            expectedRevision: resumed.revision,
            intent: providerIntent
        )
        let providerContext = try await restartedRepository.invocationContext(
            for: ProjectBindingOwner(kind: .providerSession, id: successor.sessionID)
        )
        let firstOutcome = try await managedStepper.execute(
            providerIntent,
            run: providerRun,
            context: providerContext,
            lease: lease
        )
        guard case .continued(let firstWork) = firstOutcome else {
            return XCTFail("Expected automatic continuation to complete one managed step")
        }
        XCTAssertEqual(
            firstWork.metadata["provider_response_id"],
            "automatic-response-\(automatic.intent.idempotencyKey)"
        )
        // Model a process death after the provider-turn transaction committed but
        // before the coordinator copied the response into run work. Re-executing the
        // same durable top-level intent must reconcile, never dispatch again.
        _ = try await managedStepper.execute(
            providerIntent,
            run: providerRun,
            context: providerContext,
            lease: lease
        )
        let automaticSnapshot = await provider.snapshot()
        XCTAssertEqual(automaticSnapshot.continuationCalls, 1)
        XCTAssertEqual(automaticSnapshot.previousResponseID, automatic.intent.previousResponseID)
        XCTAssertEqual(automaticSnapshot.input, exactInput)
        let noPendingAutomatic = try await restartedRepository.pendingAutomaticContinuation(
            runID: persisted.runID
        )
        XCTAssertNil(noPendingAutomatic)
        let completedRun = try await restartedRepository.autonomousRun(persisted.runID)
        XCTAssertEqual(completedRun?.continuationPending, false)
        let completedCommand = try await restartedRepository.continuityCommand(
            operationID: operationID
        )
        XCTAssertEqual(completedCommand?.state, .completed)
        let fulfilledBudget = try await restartedRepository.contextBudgetActionRequest(
            runID: persisted.runID,
            continuityOperationID: operationID
        )
        XCTAssertEqual(fulfilledBudget?.requestedAction, .emergency)
        XCTAssertEqual(fulfilledBudget?.fulfilledAction, .emergency)
        let memoryRepository = try restartedMemory.repositoryForProject(
            persisted.projectID.description
        )
        let operation = try XCTUnwrap(
            try memoryRepository.continuityOperationV2(id: operationID.uuidString.lowercased())
        )
        XCTAssertEqual(operation.state, .predecessorSealed)
        XCTAssertTrue(operation.continuationIssued)
        restartedMemory.closeAll()
        await restartedRepository.close()
    }

    func testMismatchedBootstrapNonceNeverAcceptsCandidate() async throws {
        let fixture = try await makeFixture(label: "bad-receipt")
        defer { fixture.destroy() }
        let adapter = ContinuityWorkerAdapter(mismatchedNonce: true)
        let intent = continuityIntent(fixture.run)
        let persisted = try await fixture.repository.persistRunSideEffectIntent(
            runID: fixture.run.runID,
            lease: fixture.lease,
            expectedRevision: fixture.run.revision,
            intent: intent
        )
        let context = try await fixture.repository.invocationContext(
            for: ProjectBindingOwner(kind: .autonomousRun, id: persisted.runID.description)
        )
        let worker = ManagedContinuityWorker(
            repository: fixture.repository,
            memory: fixture.memory,
            adapterResolver: { _ in adapter }
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await worker.executeContinuityStep(
                intent: intent,
                run: persisted,
                context: context,
                lease: fixture.lease
            )
        }
        XCTAssertEqual(adapter.createCount, 1)
        let storedCurrent = try await fixture.repository.autonomousRun(persisted.runID)
        let current = try XCTUnwrap(storedCurrent)
        let operationID = try XCTUnwrap(current.activeOperationID)
        let candidates = try await fixture.repository.providerSessions(operationID: operationID)
        XCTAssertTrue(candidates.isEmpty)
        let automatic = try await fixture.repository.automaticContinuation(operationID: operationID)
        XCTAssertNil(automatic)
        let predecessor = try await fixture.repository.providerSession(
            fixture.predecessorSessionID
        )
        XCTAssertEqual(predecessor?.status, .fencing)
    }

    func testEveryManagedCrashBoundaryRecoversOneSuccessorAndOneContinuation() async throws {
        for point in ManagedContinuityCrashPoint.allCases {
            if point == .continuationSideEffect {
                try await assertContinuationSideEffectCrashRecovers(point)
            } else {
                try await assertWorkerCrashRecovers(point)
            }
        }
    }

    private func assertWorkerCrashRecovers(
        _ point: ManagedContinuityCrashPoint
    ) async throws {
        let fixture = try await makeFixture(label: "matrix-\(point.rawValue)")
        defer { fixture.destroy() }
        let adapter = ContinuityWorkerAdapter()
        let intent = continuityIntent(fixture.run)
        let persisted = try await fixture.repository.persistRunSideEffectIntent(
            runID: fixture.run.runID,
            lease: fixture.lease,
            expectedRevision: fixture.run.revision,
            intent: intent
        )
        let context = try await fixture.repository.invocationContext(
            for: ProjectBindingOwner(kind: .autonomousRun, id: persisted.runID.description)
        )
        let crashing = ManagedContinuityWorker(
            repository: fixture.repository,
            memory: fixture.memory,
            adapterResolver: { _ in adapter },
            crashAfter: point
        )
        do {
            _ = try await crashing.executeContinuityStep(
                intent: intent,
                run: persisted,
                context: context,
                lease: fixture.lease
            )
            XCTFail("Expected managed crash at \(point.rawValue)")
        } catch ManagedContinuityWorkerError.injectedCrash(let observed) {
            XCTAssertEqual(observed, point)
        } catch {
            XCTFail("Unexpected crash error at \(point.rawValue): \(error)")
        }

        _ = try await fixture.repository.releaseRunLease(fixture.lease)
        await fixture.repository.close()
        fixture.memory.closeAll()
        let restartedRepository = try ProjectControlPlaneRepository(
            databaseURL: fixture.databaseURL
        )
        let restartedMemory = ProjectMemoryService(paths: fixture.paths)
        defer {
            restartedMemory.closeAll()
            Task { await restartedRepository.close() }
        }
        let worker = ManagedContinuityWorker(
            repository: restartedRepository,
            memory: restartedMemory,
            adapterResolver: { _ in adapter }
        )
        let coordinator = try ProjectRunCoordinator(
            runID: persisted.runID,
            repository: restartedRepository,
            managerID: "managed-crash-matrix-\(point.rawValue)",
            stepExecutor: ContinuityOnlyStepExecutor(worker: worker),
            completionValidator: UnusedCompletionValidator(),
            maximumSteps: 1
        )
        let activation = try await coordinator.runActivation()
        XCTAssertEqual(activation.finalState, .running, point.rawValue)
        XCTAssertEqual(adapter.createCount, 1, point.rawValue)

        let recoveredValue = try await restartedRepository.autonomousRun(persisted.runID)
        let recovered = try XCTUnwrap(recoveredValue)
        let operationString = try XCTUnwrap(
            recovered.specification.work.metadata["continuity_operation_id"]
        )
        let operationID = try XCTUnwrap(UUID(uuidString: operationString))
        let projectMemory = try restartedMemory.repositoryForProject(
            recovered.projectID.description
        )
        let operation = try XCTUnwrap(try projectMemory.continuityOperationV2(
            id: operationID.uuidString.lowercased()
        ))
        let handoff = try XCTUnwrap(
            try projectMemory.continuityHandoffV2(id: operation.handoffID)
        )
        _ = try handoff.validated()
        XCTAssertEqual(operation.state, .predecessorSealed, point.rawValue)
        XCTAssertEqual(operation.projectID, recovered.projectID.description, point.rawValue)
        XCTAssertEqual(operation.projectGeneration, recovered.projectGeneration.rawValue, point.rawValue)
        XCTAssertEqual(operation.runID, recovered.runID.description, point.rawValue)
        XCTAssertNotNil(operation.acknowledgementSHA256, point.rawValue)
        XCTAssertEqual(operation.acknowledgedHandoffID, handoff.handoffID, point.rawValue)
        XCTAssertTrue(operation.continuationIssued, point.rawValue)

        let candidates = try await restartedRepository.providerSessions(
            operationID: operationID
        )
        let accepted = candidates.filter { $0.accepted && $0.status == .active }
        XCTAssertEqual(accepted.count, 1, point.rawValue)
        let successor = try XCTUnwrap(accepted.first)
        XCTAssertEqual(recovered.activeSessionID, successor.sessionID, point.rawValue)
        let predecessor = try await restartedRepository.providerSession(
            operation.predecessorSessionID
        )
        XCTAssertEqual(predecessor?.status, .sealed, point.rawValue)
        await assertProviderAuthorityRejected(
            repository: restartedRepository,
            sessionID: operation.predecessorSessionID,
            point: point
        )
        _ = try await restartedRepository.invocationContext(
            for: ProjectBindingOwner(kind: .providerSession, id: successor.sessionID)
        )

        let provider = AutomaticContinuationFixtureProvider()
        try await dispatchAutomaticContinuation(
            repository: restartedRepository,
            run: recovered,
            successorSessionID: successor.sessionID,
            provider: provider
        )
        let providerSnapshot = await provider.snapshot()
        XCTAssertEqual(providerSnapshot.continuationCalls, 1, point.rawValue)
        let pending = try await restartedRepository.pendingAutomaticContinuation(
            runID: recovered.runID
        )
        XCTAssertNil(pending, point.rawValue)
    }

    private func assertContinuationSideEffectCrashRecovers(
        _ point: ManagedContinuityCrashPoint
    ) async throws {
        let fixture = try await makeFixture(label: "matrix-\(point.rawValue)")
        defer { fixture.destroy() }
        let adapter = ContinuityWorkerAdapter()
        let intent = continuityIntent(fixture.run)
        let persisted = try await fixture.repository.persistRunSideEffectIntent(
            runID: fixture.run.runID,
            lease: fixture.lease,
            expectedRevision: fixture.run.revision,
            intent: intent
        )
        _ = try await fixture.repository.releaseRunLease(fixture.lease)
        let coordinator = try ProjectRunCoordinator(
            runID: persisted.runID,
            repository: fixture.repository,
            managerID: "managed-crash-matrix-continuation",
            stepExecutor: ContinuityOnlyStepExecutor(worker: ManagedContinuityWorker(
                repository: fixture.repository,
                memory: fixture.memory,
                adapterResolver: { _ in adapter }
            )),
            completionValidator: UnusedCompletionValidator(),
            maximumSteps: 1
        )
        let activation = try await coordinator.runActivation()
        XCTAssertEqual(activation.finalState, .running)
        let rolledOverValue = try await fixture.repository.autonomousRun(persisted.runID)
        let rolledOver = try XCTUnwrap(rolledOverValue)
        let successorSessionID = try XCTUnwrap(rolledOver.activeSessionID)
        let provider = AutomaticContinuationFixtureProvider(
            crashAfterSideEffect: point
        )
        let providerIntent = try await preparedAutomaticProviderIntent(
            repository: fixture.repository,
            run: rolledOver,
            successorSessionID: successorSessionID,
            provider: provider
        )
        do {
            _ = try await providerIntent.stepper.execute(
                providerIntent.intent,
                run: providerIntent.run,
                context: providerIntent.context,
                lease: providerIntent.lease
            )
            XCTFail("Expected continuation side-effect crash")
        } catch ManagedContinuityWorkerError.injectedCrash(let observed) {
            XCTAssertEqual(observed, point)
        } catch {
            XCTFail("Unexpected continuation crash error: \(error)")
        }
        _ = try await fixture.repository.releaseRunLease(providerIntent.lease)
        await fixture.repository.close()
        fixture.memory.closeAll()

        let restartedRepository = try ProjectControlPlaneRepository(
            databaseURL: fixture.databaseURL
        )
        let restartedMemory = ProjectMemoryService(paths: fixture.paths)
        defer {
            restartedMemory.closeAll()
            Task { await restartedRepository.close() }
        }
        let recoveredValue = try await restartedRepository.autonomousRun(persisted.runID)
        let recovered = try XCTUnwrap(recoveredValue)
        let lease = try await restartedRepository.acquireRunLease(
            runID: recovered.runID,
            ownerID: "continuation-side-effect-recovery"
        )
        let broker = try automaticContinuationBroker(repository: restartedRepository)
        let stepper = try ManagedProjectRunStepExecutor(
            repository: restartedRepository,
            providerResolver: { _ in provider },
            toolDefinitionResolver: { _ in [] },
            broker: broker
        )
        let context = try await restartedRepository.invocationContext(
            for: ProjectBindingOwner(kind: .providerSession, id: successorSessionID)
        )
        let outcome = try await stepper.execute(
            providerIntent.intent,
            run: recovered,
            context: context,
            lease: lease
        )
        guard case .continued = outcome else {
            return XCTFail("Expected recovered automatic continuation")
        }
        let providerSnapshot = await provider.snapshot()
        XCTAssertEqual(providerSnapshot.continuationCalls, 1)
        let pending = try await restartedRepository.pendingAutomaticContinuation(
            runID: recovered.runID
        )
        XCTAssertNil(pending)
        let operationString = try XCTUnwrap(
            recovered.specification.work.metadata["continuity_operation_id"]
        )
        let operationID = try XCTUnwrap(UUID(uuidString: operationString))
        let candidates = try await restartedRepository.providerSessions(operationID: operationID)
        XCTAssertEqual(candidates.filter { $0.accepted && $0.status == .active }.count, 1)
        let projectMemory = try restartedMemory.repositoryForProject(recovered.projectID.description)
        let operation = try XCTUnwrap(try projectMemory.continuityOperationV2(
            id: operationID.uuidString.lowercased()
        ))
        let handoff = try XCTUnwrap(
            try projectMemory.continuityHandoffV2(id: operation.handoffID)
        )
        _ = try handoff.validated()
        XCTAssertEqual(operation.state, .predecessorSealed)
        XCTAssertEqual(operation.projectID, recovered.projectID.description)
        XCTAssertEqual(operation.projectGeneration, recovered.projectGeneration.rawValue)
        XCTAssertEqual(operation.runID, recovered.runID.description)
        XCTAssertNotNil(operation.acknowledgementSHA256)
        XCTAssertEqual(operation.acknowledgedHandoffID, handoff.handoffID)
        XCTAssertTrue(operation.continuationIssued)
        XCTAssertEqual(recovered.activeSessionID, candidates.first(where: \.accepted)?.sessionID)
        XCTAssertEqual(adapter.createCount, 1)
        let predecessor = try await restartedRepository.providerSession(
            operation.predecessorSessionID
        )
        XCTAssertEqual(predecessor?.status, .sealed)
        await assertProviderAuthorityRejected(
            repository: restartedRepository,
            sessionID: operation.predecessorSessionID,
            point: point
        )
        _ = try await restartedRepository.releaseRunLease(lease)
    }

    private struct PreparedAutomaticProviderIntent {
        let stepper: ManagedProjectRunStepExecutor
        let intent: RunSideEffectIntent
        let run: AutonomousRunRecord
        let context: ToolInvocationContext
        let lease: RunLease
    }

    private func preparedAutomaticProviderIntent(
        repository: ProjectControlPlaneRepository,
        run: AutonomousRunRecord,
        successorSessionID: String,
        provider: AutomaticContinuationFixtureProvider
    ) async throws -> PreparedAutomaticProviderIntent {
        let lease = try await repository.acquireRunLease(
            runID: run.runID,
            ownerID: "automatic-continuation-crash"
        )
        let stepper = try ManagedProjectRunStepExecutor(
            repository: repository,
            providerResolver: { _ in provider },
            toolDefinitionResolver: { _ in [] },
            broker: try automaticContinuationBroker(repository: repository)
        )
        let prepared = try await stepper.prepareNextStep(for: run)
        let intent = try XCTUnwrap(prepared)
        let persisted = try await repository.persistRunSideEffectIntent(
            runID: run.runID,
            lease: lease,
            expectedRevision: run.revision,
            intent: intent
        )
        let context = try await repository.invocationContext(
            for: ProjectBindingOwner(kind: .providerSession, id: successorSessionID)
        )
        return PreparedAutomaticProviderIntent(
            stepper: stepper,
            intent: intent,
            run: persisted,
            context: context,
            lease: lease
        )
    }

    private func dispatchAutomaticContinuation(
        repository: ProjectControlPlaneRepository,
        run: AutonomousRunRecord,
        successorSessionID: String,
        provider: AutomaticContinuationFixtureProvider
    ) async throws {
        let prepared = try await preparedAutomaticProviderIntent(
            repository: repository,
            run: run,
            successorSessionID: successorSessionID,
            provider: provider
        )
        let first = try await prepared.stepper.execute(
            prepared.intent,
            run: prepared.run,
            context: prepared.context,
            lease: prepared.lease
        )
        guard case .continued = first else {
            return XCTFail("Expected automatic continuation to advance")
        }
        _ = try await prepared.stepper.execute(
            prepared.intent,
            run: prepared.run,
            context: prepared.context,
            lease: prepared.lease
        )
        _ = try await repository.releaseRunLease(prepared.lease)
    }

    private func automaticContinuationBroker(
        repository: ProjectControlPlaneRepository
    ) throws -> ToolInvocationBroker {
        let executor = ContinuityNoopToolExecutor()
        return ToolInvocationBroker(
            repository: repository,
            executor: executor,
            classifier: try StaticToolReplayClassifier(
                productionToolNames: executor.toolNames,
                classifications: ["fixture.read": .readOnly]
            )
        )
    }

    private func assertProviderAuthorityRejected(
        repository: ProjectControlPlaneRepository,
        sessionID: String,
        point: ManagedContinuityCrashPoint
    ) async {
        do {
            _ = try await repository.invocationContext(
                for: ProjectBindingOwner(kind: .providerSession, id: sessionID)
            )
            XCTFail("Predecessor retained authority at \(point.rawValue)")
        } catch {}
    }

    private func makeFixture(label: String) async throws -> WorkerFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "forge-managed-continuity-\(label)-\(UUID().uuidString)",
            isDirectory: true
        )
        let home = root.appendingPathComponent("home", isDirectory: true)
        let projectRoot = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let paths = AppPaths(home: home)
        try paths.ensureLayout()
        let memory = ProjectMemoryService(paths: paths)
        let initialized = try memory.initializeUnchecked(path: projectRoot.path)
        let projectString = try XCTUnwrap(initialized["project_id"] as? String)
        let projectID = ProjectID(try XCTUnwrap(UUID(uuidString: projectString)))
        let databaseURL = root.appendingPathComponent("control-plane.sqlite3")
        let repository = try ProjectControlPlaneRepository(databaseURL: databaseURL)
        _ = try await repository.registerProjectUnchecked(
            projectID: projectID,
            displayName: "Managed Continuity Fixture",
            canonicalRoot: projectRoot
        )
        var run = try await repository.createAutonomousRun(
            AutonomousRunRequest(
                projectID: projectID,
                projectGeneration: .initial,
                assignmentID: "FC-ROLL-001",
                mission: "Resume automatically across a fresh-root rollover",
                providerID: "fixture-provider",
                adapterID: "fixture-v2-adapter",
                modelKey: "fixture/model",
                specification: AutonomousRunSpecification(
                    allowedTools: ["fixture.read"],
                    completionGates: ["fixture-gate"],
                    work: AutonomousRunWork(
                        currentPhase: "FC-ROLL-001",
                        workItem: "restart-recovery",
                        nextAction: "Continue after bootstrap"
                    )
                ),
                authorizationScope: ToolAuthorizationScope(
                    canonicalRoots: [projectRoot],
                    allowedTools: ["fixture.read"],
                    networkAllowed: false,
                    maximumInlineOutputBytes: 64 * 1_024
                )
            )
        )
        var lease = try await repository.acquireRunLease(
            runID: run.runID,
            ownerID: "continuity-fixture",
            policy: RunLeasePolicy(duration: 120, renewalInterval: 30, maximumDuration: 600)
        )
        let predecessor = "predecessor-\(UUID().uuidString.lowercased())"
        try await repository.reserveProviderSession(
            ProviderSessionIntent(
                sessionID: predecessor,
                runID: run.runID,
                projectID: projectID,
                projectGeneration: .initial,
                providerID: "fixture-provider",
                adapterID: "fixture-v2-adapter",
                modelKey: "fixture/model",
                providerResponseID: "response-predecessor",
                idempotencyKey: "initial-session:\(run.runID.description)",
                contextCapacity: 65_536
            ),
            lease: lease
        )
        let reservedRun = try await repository.autonomousRun(run.runID)
        run = try XCTUnwrap(reservedRun)
        for state in [
            AutonomousRunState.validating,
            .ready,
            .starting,
            .running,
        ] {
            run = try await repository.transitionAutonomousRun(
                runID: run.runID,
                lease: lease,
                transition: AutonomousRunTransition(
                    expectedState: run.state,
                    expectedRevision: run.revision,
                    nextState: state,
                    eventType: "fixture_\(state.rawValue)",
                    eventSummary: "Fixture entered \(state.rawValue)"
                )
            )
        }
        let identity = ContextBudgetIdentity(
            runID: run.runID,
            projectID: projectID,
            projectGeneration: .initial,
            sessionID: predecessor
        )
        let supervisor = try await ContextBudgetSupervisor.open(
            repository: repository,
            identity: identity,
            configuration: ContextBudgetConfiguration(
                capacity: ContextCapacityResolution(
                    providerID: "fixture-provider",
                    providerVersionFingerprint: "fixture-v1",
                    modelKey: "fixture/model",
                    activeInstanceID: "fixture-instance",
                    capacity: 65_536,
                    maximumContextLength: 65_536,
                    requiresModelLoad: false
                ),
                reserves: ContextBudgetReserves(
                    outputTokens: 1_024,
                    schemaTokens: 512,
                    handoffTokens: 1_024,
                    recoveryTokens: 512
                ),
                policy: ContextBudgetPolicy(initialProjectedNextTurnTokens: 512)
            )
        )
        _ = try await supervisor.evaluate(
            ContextBudgetEvaluationRequest(
                triggerPoint: .providerOverflow,
                providerResponseID: "response-predecessor",
                measurement: .providerOverflow(lastKnownUsedTokens: 64_000)
            )
        )
        let observedRun = try await repository.autonomousRun(run.runID)
        run = try XCTUnwrap(observedRun)
        run = try await repository.transitionAutonomousRun(
            runID: run.runID,
            lease: lease,
            transition: AutonomousRunTransition(
                expectedState: .running,
                expectedRevision: run.revision,
                nextState: .rollingOver,
                eventType: "fixture_rollover_required",
                eventSummary: "Fixture requested emergency rollover"
            )
        )
        lease = try await repository.renewRunLease(
            lease,
            policy: RunLeasePolicy(duration: 120, renewalInterval: 30, maximumDuration: 600)
        )
        return WorkerFixture(
            root: root,
            paths: paths,
            databaseURL: databaseURL,
            repository: repository,
            memory: memory,
            run: run,
            lease: lease,
            predecessorSessionID: predecessor
        )
    }

    private func continuityIntent(_ run: AutonomousRunRecord) -> RunSideEffectIntent {
        let key = "continuity-test:\(run.runID.description):\(run.revision)"
        return RunSideEffectIntent(
            kind: .continuity,
            idempotencyKey: key,
            payloadSHA256: JSONSupport.sha256Hex(key),
            summary: "Advance managed continuity test"
        )
    }
}

private struct WorkerFixture {
    let root: URL
    let paths: AppPaths
    let databaseURL: URL
    let repository: ProjectControlPlaneRepository
    let memory: ProjectMemoryService
    let run: AutonomousRunRecord
    let lease: RunLease
    let predecessorSessionID: String

    func destroy() {
        memory.closeAll()
        try? FileManager.default.removeItem(at: root)
    }
}

private actor ContinuityOnlyStepExecutor: ProjectRunStepExecuting {
    let worker: ManagedContinuityWorker

    init(worker: ManagedContinuityWorker) { self.worker = worker }

    func prepareNextStep(for run: AutonomousRunRecord) async throws -> RunSideEffectIntent? {
        run.specification.work.pendingIntent
    }

    func execute(
        _ intent: RunSideEffectIntent,
        run: AutonomousRunRecord,
        context: ToolInvocationContext,
        lease: RunLease
    ) async throws -> ProjectRunStepOutcome {
        try await worker.executeContinuityStep(
            intent: intent,
            run: run,
            context: context,
            lease: lease
        )
    }

    func cancel(runID: RunID) async {}
}

private struct UnusedCompletionValidator: RunCompletionValidating {
    func validate(_ run: AutonomousRunRecord) async throws -> CompletionValidationReceipt {
        throw AutonomyError.completionValidationRequired
    }
}

private actor AutomaticContinuationFixtureProvider: ManagedModelProvider {
    struct Snapshot: Sendable {
        let continuationCalls: Int
        let previousResponseID: String?
        let input: Data?
    }

    nonisolated let providerID = "fixture-provider"
    private let crashAfterSideEffect: ManagedContinuityCrashPoint?
    private var continuationCalls = 0
    private var injectedCrash = false
    private var previousResponseID: String?
    private var input: Data?
    private var receipts: [String: ProviderTurn] = [:]

    init(crashAfterSideEffect: ManagedContinuityCrashPoint? = nil) {
        self.crashAfterSideEffect = crashAfterSideEffect
    }

    func probe() async throws -> ProviderCapabilities {
        try ProviderCapabilities(
            providerID: providerID,
            providerVersion: "fixture-1",
            modelKey: "fixture/model",
            providerInstanceID: "fixture-instance",
            contextLength: 65_536,
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
        throw AutonomyError.invalidRequest("automatic continuation cannot create a root")
    }

    func continueSession(_ request: ProviderContinuationRequest) async throws -> ProviderTurn {
        if let existing = receipts[request.idempotencyKey] { return existing }
        guard request.input == (try ManagedContinuityWorker.automaticContinuationInput()) else {
            throw AutonomyError.intentConflict
        }
        continuationCalls += 1
        previousResponseID = request.previousResponseID
        input = request.input
        let turn = try ProviderTurn(
            requestID: "automatic-request-\(request.idempotencyKey)",
            responseID: "automatic-response-\(request.idempotencyKey)",
            previousResponseID: request.previousResponseID,
            providerID: providerID,
            providerVersion: "fixture-1",
            modelKey: request.modelKey,
            providerInstanceID: "fixture-instance",
            messages: ["Automatic continuation accepted"],
            toolCalls: [],
            usage: try ProviderUsage(
                capacity: 65_536,
                inputTokens: 1_024,
                outputTokens: 32,
                source: .providerExact,
                confidence: 1
            ),
            completed: true,
            finishReason: .stop
        )
        receipts[request.idempotencyKey] = turn
        if let crashAfterSideEffect, !injectedCrash {
            injectedCrash = true
            throw ManagedContinuityWorkerError.injectedCrash(crashAfterSideEffect)
        }
        return turn
    }

    func lookup(idempotencyKey: String) async throws -> ProviderTurn? {
        receipts[idempotencyKey]
    }

    func cancel(requestID: String) async {}

    func snapshot() -> Snapshot {
        Snapshot(
            continuationCalls: continuationCalls,
            previousResponseID: previousResponseID,
            input: input
        )
    }
}

private final class ContinuityNoopToolExecutor: ToolExecuting, @unchecked Sendable {
    let toolNames = ["fixture.read"]

    func call(
        name: String,
        arguments: [String: Any],
        clientID: ClientID
    ) throws -> ToolResult {
        .failure(code: "unexpected_tool_call", message: "No tool call expected")
    }

    func call(
        name: String,
        arguments: [String: Any],
        context: ToolInvocationContext
    ) throws -> ToolResult {
        .failure(code: "unexpected_tool_call", message: "No tool call expected")
    }
}

private final class ContinuityWorkerAdapter: SessionHostAdapterV2, @unchecked Sendable {
    nonisolated let identifier = "fixture-v2-adapter"
    nonisolated let version = "1.0"

    private let lock = NSLock()
    private let mismatchedNonce: Bool
    private var receipts: [String: BootstrapReceipt] = [:]
    private var creates = 0

    init(mismatchedNonce: Bool = false) {
        self.mismatchedNonce = mismatchedNonce
    }

    var createCount: Int {
        lock.withLock { creates }
    }

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
        if let existing = lock.withLock({ receipts[request.idempotencyKey] }) {
            return existing
        }
        guard let object = try JSONSerialization.jsonObject(with: handoffJSON) as? [String: Any],
              let handoff = ContinuityHandoffV2.fromDictionary(object),
              let handoffID = UUID(uuidString: handoff.handoffID) else {
            throw ProjectMemoryError.invalidRequest("fixture received an invalid V2 handoff")
        }
        let nonce = mismatchedNonce
            ? "mismatch-0123456789abcdef0123456789abcdef"
            : challenge.nonce
        let receipt = BootstrapReceipt(
            acknowledgement: BootstrapAcknowledgementV2(
                projectID: request.projectID,
                projectGeneration: request.projectGeneration,
                runID: request.runID,
                operationID: request.operationID,
                handoffID: handoffID,
                handoffSHA256: handoff.contentSHA256,
                nonce: nonce
            ),
            internalSessionID: "successor-\(request.operationID.uuidString.lowercased())",
            providerResponseID: "response-successor-\(request.operationID.uuidString.lowercased())",
            modelKey: request.modelKey,
            adapterID: identifier,
            usage: ContextBudgetStatus(
                capacity: 65_536,
                used: 1_024,
                reserved: 3_072,
                remaining: 61_440,
                source: "provider_exact",
                confidence: 1,
                action: .normal
            )
        )
        lock.withLock {
            creates += 1
            receipts[request.idempotencyKey] = receipt
        }
        return receipt
    }

    func receipt(forIdempotencyKey key: String) async throws -> BootstrapReceipt? {
        lock.withLock { receipts[key] }
    }

    func cancel(operationID: UUID) async {}

}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {}
}
