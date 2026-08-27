// AutonomySupervisorTests.swift
// Verifies durable run transitions, lease fencing, tool replay, completion, and startup recovery.

import XCTest
@testable import ForgeConductorCore

final class AutonomySupervisorTests: XCTestCase {
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
            let initialized = try memory.initialize(path: projectRoot.path)
            let projectID = ProjectID(try XCTUnwrap(UUID(
                uuidString: try XCTUnwrap(initialized["project_id"] as? String)
            )))
            _ = try await repository.registerProject(
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
        allowedTools: [String] = ["fixture.read"]
    ) async throws -> RunFixture {
        let projectID = ProjectID()
        let projectRoot = root.appendingPathComponent("project", isDirectory: true)
        _ = try await repository.registerProject(
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
                completionGates: ["tests"]
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
