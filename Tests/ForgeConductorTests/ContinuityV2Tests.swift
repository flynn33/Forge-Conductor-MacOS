// ContinuityV2Tests.swift
// Verifies exact V2 identity, project-local authority, command recovery, and legacy quarantine.

import SQLite3
import XCTest
@testable import ForgeConductorCore

final class ContinuityV2Tests: XCTestCase {
    func testCanonicalJSONV1SlashVectorAndBootstrapAcknowledgementWireShape() throws {
        let slashVector: [String: Any] = [
            "path": "/fixture",
            "nested": ["url": "https://example.com/a/b"],
        ]
        let canonical = try ForgeJSONCanonicalizationV1.data(from: slashVector)
        XCTAssertEqual(
            String(decoding: canonical, as: UTF8.self),
            #"{"nested":{"url":"https://example.com/a/b"},"path":"/fixture"}"#
        )
        XCTAssertEqual(
            JSONSupport.sha256Hex(canonical),
            "b3836c9e664ebdbc3e03d6eef75c5ba422a6db2e634d48f15cb851ba9e9b6a06"
        )

        let acknowledgement = BootstrapAcknowledgementV2(
            projectID: ProjectID(UUID(uuidString: "33333333-3333-4333-8333-333333333333")!),
            projectGeneration: ProjectGeneration(7),
            runID: RunID(UUID(uuidString: "44444444-4444-4444-8444-444444444444")!),
            operationID: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
            handoffID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            handoffSHA256: "0f1165a96b5054a77c478be783c4afd3c62ef6f8a8f59a0a3612364cb0000612",
            nonce: "nonce-example-0123456789abcdef0123456789abcdef"
        )
        let encoded = try JSONEncoder().encode(acknowledgement)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertEqual(object["project_id"] as? String, acknowledgement.projectID.description)
        XCTAssertEqual(object["project_generation"] as? UInt64, 7)
        XCTAssertEqual(object["run_id"] as? String, acknowledgement.runID.description)
        XCTAssertEqual(try JSONDecoder().decode(BootstrapAcknowledgementV2.self, from: encoded), acknowledgement)

        var unexpected = object
        unexpected["unexpected"] = true
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                BootstrapAcknowledgementV2.self,
                from: JSONSerialization.data(withJSONObject: unexpected)
            )
        )
    }

    func testHandoffV2CanonicalChecksumAndShapeValidation() throws {
        let handoff = try makeHandoffV2(
            projectID: UUID().uuidString.lowercased(),
            generation: 7,
            runID: UUID().uuidString.lowercased()
        )
        XCTAssertEqual(handoff.contentSHA256.count, 64)
        XCTAssertEqual(handoff.contentSHA256, handoff.calculatedSHA256())
        XCTAssertLessThanOrEqual(
            try handoff.encodedJSON().count,
            ContinuityHandoffV2.maximumEncodedBytes
        )
        let parsed = try XCTUnwrap(
            ContinuityHandoffV2.fromDictionary(handoff.asDictionary())
        )
        XCTAssertEqual(parsed.contentSHA256, handoff.contentSHA256)

        var tampered = handoff.asDictionary()
        tampered["mission"] = "Changed after hashing"
        XCTAssertNil(ContinuityHandoffV2.fromDictionary(tampered))

        var extraField = handoff.asDictionary()
        extraField["unexpected"] = true
        XCTAssertNil(ContinuityHandoffV2.fromDictionary(extraField))

        var malformedHash = handoff.asDictionary()
        var integrity = try XCTUnwrap(malformedHash["integrity"] as? [String: Any])
        integrity["content_sha256"] = String(repeating: "A", count: 64)
        malformedHash["integrity"] = integrity
        XCTAssertNil(ContinuityHandoffV2.fromDictionary(malformedHash))

        var tooManyActions = handoff
        tooManyActions.contentSHA256 = ""
        tooManyActions.nextActions = (0...ContinuityHandoffV2.maximumListItems).map { index in
            [
                "order": index,
                "action": "Required action \(index)",
                "command": "",
                "success_condition": "Required action \(index) is complete",
                "replay_class": "reconciled",
            ] as [String: Any]
        }
        XCTAssertEqual(
            tooManyActions.nextActions.count,
            ContinuityHandoffV2.maximumListItems + 1
        )
        XCTAssertThrowsError(try tooManyActions.validated()) { error in
            XCTAssertEqual((error as? ProjectMemoryError)?.code, "payload_too_large")
        }
    }

    func testProjectLocalV2HandoffAndOperationAreDurable() throws {
        let fixture = try makeMemoryFixture(label: "project-local")
        defer {
            fixture.memory.closeAll()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let runID = UUID().uuidString.lowercased()
        let handoff = try makeHandoffV2(
            projectID: fixture.projectID,
            generation: 3,
            runID: runID
        )
        let engine = ContinuityStateEngine(memory: fixture.memory)
        let operation = try engine.prepareV2(
            handoff: handoff,
            predecessorSessionID: "predecessor",
            predecessorProviderResponseID: "resp-predecessor",
            adapterID: "forge.native-session-host",
            idempotencyKey: "v2-project-local"
        )

        XCTAssertEqual(operation.state, .checkpointPersisted)
        XCTAssertEqual(operation.projectGeneration, 3)
        XCTAssertEqual(operation.runID, runID)
        XCTAssertEqual(operation.predecessorProviderResponseID, "resp-predecessor")
        XCTAssertNil(operation.quarantineState)
        let repository = try fixture.memory.repositoryForProject(fixture.projectID)
        XCTAssertEqual(
            try repository.continuityHandoffV2(id: handoff.handoffID)?.contentSHA256,
            handoff.contentSHA256
        )

        let continuity = repository.directory.appendingPathComponent(
            "continuity",
            isDirectory: true
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: continuity
                    .appendingPathComponent("handoffs/\(handoff.handoffID).json").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: continuity
                    .appendingPathComponent("operations/\(handoff.operationID).json").path
            )
        )
        XCTAssertEqual(
            try String(
                contentsOf: continuity.appendingPathComponent("LATEST"),
                encoding: .utf8
            ).trimmingCharacters(in: .whitespacesAndNewlines),
            handoff.handoffID
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: continuity.appendingPathComponent("CURRENT.json").path
            )
        )
    }

    func testV2OperationCreationAtomicallyPersistsHandoffAndResumesEarlyStates() throws {
        try assertV2PreparationRecovery(advanceToCheckpointPreparing: false)
        try assertV2PreparationRecovery(advanceToCheckpointPreparing: true)
    }

    func testProductionReconcilerCompletesContinuityFromExactDurableHandoff() async throws {
        let fixture = try makeMemoryFixture(label: "continuity-reconciler")
        defer {
            fixture.memory.closeAll()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let runID = RunID()
        let handoff = try makeHandoffV2(
            projectID: fixture.projectID,
            generation: 1,
            runID: runID.description
        )
        let idempotencyKey = "continuity-reconcile-key"
        let operation = try fixture.memory.repositoryForProject(fixture.projectID)
            .continuityCreateOperationV2(
            handoff: handoff,
            predecessorSessionID: "predecessor",
            predecessorProviderResponseID: "resp-predecessor",
            adapterID: "forge.native-session-host",
            idempotencyKey: idempotencyKey
        )
        XCTAssertEqual(operation.state, .active)

        let databaseURL = fixture.root.appendingPathComponent("control-plane.sqlite3")
        let controlPlane = try ProjectControlPlaneRepository(databaseURL: databaseURL)
        let runtimeJobs = try RuntimeJobRepository(databaseURL: databaseURL)
        let projectID = ProjectID(try XCTUnwrap(UUID(uuidString: fixture.projectID)))
        let projectRoot = fixture.root.appendingPathComponent("project", isDirectory: true)
        _ = try await controlPlane.registerProject(
            projectID: projectID,
            displayName: "Continuity Reconciler Fixture",
            canonicalRoot: projectRoot
        )
        let context = ToolInvocationContext(
            projectID: projectID,
            projectGeneration: .initial,
            clientID: ClientID("continuity-reconciler"),
            runID: runID,
            providerSessionID: "continuity-reconciler-session",
            authorizationScope: ToolAuthorizationScope(
                canonicalRoots: [projectRoot],
                allowedTools: ["continuity.checkpoint"],
                networkAllowed: false,
                maximumInlineOutputBytes: 64 * 1_024
            )
        )
        let call = BrokeredToolCall(
            providerCallID: "call-continuity-reconcile",
            toolName: "continuity.checkpoint",
            arguments: [
                "project_id": fixture.projectID,
                "operation_id": handoff.operationID,
                "handoff_id": handoff.handoffID,
                "idempotency_key": idempotencyKey,
            ],
            idempotencyKey: idempotencyKey
        )
        let timestamp = ISO8601.string(from: Date())
        let invocation = ToolInvocationRecord(
            invocationID: UUID(),
            turnID: UUID(),
            runID: runID,
            sessionID: "continuity-reconciler-session",
            projectID: projectID,
            projectGeneration: .initial,
            providerCallID: call.providerCallID,
            toolName: call.toolName,
            replayClass: .reconciled,
            idempotencyKey: idempotencyKey,
            argumentsSHA256: JSONSupport.sha256Hex(
                try JSONSupport.canonicalJSON(call.arguments)
            ),
            reconciliationDescriptor: nil,
            state: .ambiguous,
            resultSHA256: nil,
            resultSummary: nil,
            lastErrorCode: "manager_interrupted",
            lastErrorSummary: "Fixture interruption",
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let reconciler = ProductionToolInvocationReconciler(
            controlPlane: controlPlane,
            runtimeJobs: runtimeJobs,
            memory: fixture.memory
        )
        switch try await reconciler.reconcile(
            invocation: invocation,
            call: call,
            context: context
        ) {
        case .completed(let result):
            XCTAssertTrue(result.ok)
            XCTAssertEqual(result.payload["operation_id"] as? String, handoff.operationID)
            XCTAssertEqual(result.payload["checkpoint_persisted"] as? Bool, true)
        case .safeToExecute, .unresolved:
            XCTFail("Expected the exact durable handoff to complete reconciliation")
        }
        XCTAssertEqual(
            try fixture.memory.repositoryForProject(fixture.projectID)
                .continuityOperationV2(id: handoff.operationID)?.state,
            .checkpointPersisted
        )
        await runtimeJobs.close()
        await controlPlane.close()
    }

    func testControlPlaneContinuityCommandIdempotencyCASAndRestartRecovery() async throws {
        let root = temporaryRoot("command-queue")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appendingPathComponent("control-plane.sqlite3")
        let projectID = ProjectID()
        let runID = RunID()
        let operationID = UUID()
        let projectRoot = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)

        let repository = try ProjectControlPlaneRepository(
            databaseURL: databaseURL
        )
        _ = try await repository.registerProject(
            projectID: projectID,
            displayName: "Command Fixture",
            canonicalRoot: projectRoot
        )
        try await repository.reserveContinuityRun(
            runID: runID,
            projectID: projectID,
            projectGeneration: .initial,
            assignmentID: "FC-CONT-001",
            mission: "Persist and recover continuity commands",
            mode: .managedAutonomous
        )
        let request = ContinuityCommandRequest(
            operationID: operationID,
            runID: runID,
            projectID: projectID,
            projectGeneration: .initial,
            type: .rollover,
            requestedBy: "context_budget_supervisor",
            reason: "rollover threshold crossed",
            idempotencyKey: "queue-idempotency",
            payloadSHA256: String(repeating: "a", count: 64)
        )
        let first = try await repository.enqueueContinuityCommand(request)
        let replay = try await repository.enqueueContinuityCommand(request)
        XCTAssertEqual(first, replay)
        let readyBeforeClaim = try await repository.readyContinuityCommandCount()
        XCTAssertEqual(readyBeforeClaim, 1)

        let claimedValue = try await repository.claimNextContinuityCommand()
        let claimed = try XCTUnwrap(claimedValue)
        XCTAssertEqual(claimed.state, .claimed)
        XCTAssertEqual(claimed.attempt, 1)
        _ = try await repository.transitionContinuityCommand(
            commandID: claimed.commandID,
            expected: .claimed,
            to: .running
        )

        await repository.close()
        let restarted = try ProjectControlPlaneRepository(databaseURL: databaseURL)
        let recoveredCount = try await restarted.recoverInterruptedContinuityCommands()
        XCTAssertEqual(recoveredCount, 1)
        let recoveredValue = try await restarted.claimNextContinuityCommand()
        let recovered = try XCTUnwrap(recoveredValue)
        XCTAssertEqual(recovered.commandID, claimed.commandID)
        XCTAssertEqual(recovered.attempt, 2)
        _ = try await restarted.transitionContinuityCommand(
            commandID: recovered.commandID,
            expected: .claimed,
            to: .running
        )
        let completed = try await restarted.transitionContinuityCommand(
            commandID: recovered.commandID,
            expected: .running,
            to: .completed
        )
        XCTAssertEqual(completed.state, .completed)
        let persisted = try await restarted.continuityCommand(operationID: operationID)
        XCTAssertEqual(persisted, completed)
        await restarted.close()
    }

    func testManagedRequestPersistsHandoffBeforeEnqueueAndReconcilesReplay() async throws {
        let fixture = try makeMemoryFixture(label: "managed-route")
        defer {
            fixture.memory.closeAll()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let controlURL = fixture.root.appendingPathComponent("control-plane.sqlite3")
        let controlPlane = try ProjectControlPlaneRepository(databaseURL: controlURL)
        defer { Task { await controlPlane.close() } }
        let projectUUID = try XCTUnwrap(UUID(uuidString: fixture.projectID))
        let canonicalRoot = fixture.root.appendingPathComponent("project", isDirectory: true)
        _ = try await controlPlane.registerProject(
            projectID: ProjectID(projectUUID),
            displayName: "Managed Fixture",
            canonicalRoot: canonicalRoot
        )
        let handoff = try makeHandoffV2(
            projectID: fixture.projectID,
            generation: 1,
            runID: UUID().uuidString.lowercased(),
            mode: .managedAutonomous
        )
        let router = ManagedContinuityCommandRouter(
            memory: fixture.memory,
            controlPlane: controlPlane
        )
        let command = try await router.request(
            handoff: handoff,
            predecessorSessionID: "predecessor",
            predecessorProviderResponseID: "resp-predecessor",
            adapterID: "forge.native-session-host",
            idempotencyKey: "managed-route-idempotency",
            requestedBy: "manager",
            reason: "rollover threshold crossed"
        )
        XCTAssertEqual(command.operationID.uuidString.lowercased(), handoff.operationID)
        XCTAssertEqual(command.state, .queued)
        XCTAssertNotNil(
            try fixture.memory.repositoryForProject(fixture.projectID)
                .continuityHandoffV2(id: handoff.handoffID)
        )

        let replay = try await router.request(
            handoff: handoff,
            predecessorSessionID: "predecessor",
            predecessorProviderResponseID: "resp-predecessor",
            adapterID: "forge.native-session-host",
            idempotencyKey: "managed-route-idempotency",
            requestedBy: "manager",
            reason: "rollover threshold crossed"
        )
        XCTAssertEqual(replay, command)
        let readyCount = try await controlPlane.readyContinuityCommandCount()
        XCTAssertEqual(readyCount, 1)
        await controlPlane.close()
    }

    func testPrecommitCancellationAndDeadlineLeaveNoContinuityOperation() throws {
        let fixture = try makeMemoryFixture(label: "precommit-control")
        defer {
            fixture.memory.closeAll()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let engine = ContinuityStateEngine(memory: fixture.memory)
        let cancelledHandoff = try makeHandoffV2(
            projectID: fixture.projectID,
            generation: 1,
            runID: UUID().uuidString.lowercased(),
            mode: .managedAutonomous
        )
        let cancelled = ToolCallCancellation()
        cancelled.cancel()

        XCTAssertThrowsError(
            try engine.prepareV2(
                handoff: cancelledHandoff,
                predecessorSessionID: "predecessor",
                predecessorProviderResponseID: "resp-predecessor",
                adapterID: "forge.native-session-host",
                idempotencyKey: "cancel-before-commit",
                cancellation: cancelled
            )
        ) { error in
            XCTAssertTrue(error is CancellationError, "unexpected error: \(error)")
        }
        XCTAssertNil(
            try fixture.memory.repositoryForProject(fixture.projectID)
                .continuityOperationV2(id: cancelledHandoff.operationID)
        )

        let expiredHandoff = try makeHandoffV2(
            projectID: fixture.projectID,
            generation: 1,
            runID: UUID().uuidString.lowercased(),
            mode: .managedAutonomous
        )
        let expired = ToolCallCancellation(timeoutSeconds: 0)
        XCTAssertThrowsError(
            try engine.prepareV2(
                handoff: expiredHandoff,
                predecessorSessionID: "predecessor",
                predecessorProviderResponseID: "resp-predecessor",
                adapterID: "forge.native-session-host",
                idempotencyKey: "deadline-before-commit",
                cancellation: expired
            )
        ) { error in
            XCTAssertTrue(error is ToolCallDeadlineExceeded, "unexpected error: \(error)")
        }
        XCTAssertNil(
            try fixture.memory.repositoryForProject(fixture.projectID)
                .continuityOperationV2(id: expiredHandoff.operationID)
        )
    }

    func testLockedContinuityCreateHonorsCancellationAndDeadlineWithoutPartialWrite() throws {
        let fixture = try makeMemoryFixture(label: "locked-continuity-control")
        defer {
            fixture.memory.closeAll()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let repository = try fixture.memory.repositoryForProject(fixture.projectID)
        let writeLock = try SQLiteWriteLock(databaseURL: repository.databaseURL)
        defer { writeLock.release() }
        let engine = ContinuityStateEngine(memory: fixture.memory)

        let cancelledHandoff = try makeHandoffV2(
            projectID: fixture.projectID,
            generation: 1,
            runID: UUID().uuidString.lowercased(),
            mode: .managedAutonomous
        )
        let cancelled = ToolCallCancellation()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + .milliseconds(50)
        ) {
            cancelled.cancel()
        }
        let cancellationStartedAt = Date()
        XCTAssertThrowsError(
            try engine.prepareV2(
                handoff: cancelledHandoff,
                predecessorSessionID: "predecessor",
                predecessorProviderResponseID: "resp-predecessor",
                adapterID: "forge.native-session-host",
                idempotencyKey: "cancel-during-busy-lock",
                cancellation: cancelled
            )
        ) { error in
            XCTAssertTrue(error is CancellationError, "unexpected error: \(error)")
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(cancellationStartedAt),
            2,
            "continuity cancellation waited for the three-second SQLite busy fallback"
        )

        let deadlineHandoff = try makeHandoffV2(
            projectID: fixture.projectID,
            generation: 1,
            runID: UUID().uuidString.lowercased(),
            mode: .managedAutonomous
        )
        let deadline = ToolCallCancellation(timeoutSeconds: 0.05)
        let deadlineStartedAt = Date()
        XCTAssertThrowsError(
            try engine.prepareV2(
                handoff: deadlineHandoff,
                predecessorSessionID: "predecessor",
                predecessorProviderResponseID: "resp-predecessor",
                adapterID: "forge.native-session-host",
                idempotencyKey: "deadline-during-busy-lock",
                cancellation: deadline
            )
        ) { error in
            XCTAssertTrue(error is ToolCallDeadlineExceeded, "unexpected error: \(error)")
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(deadlineStartedAt),
            2,
            "continuity deadline waited for the three-second SQLite busy fallback"
        )

        writeLock.release()
        XCTAssertNil(try repository.continuityOperationV2(id: cancelledHandoff.operationID))
        XCTAssertNil(try repository.continuityHandoffV2(id: cancelledHandoff.handoffID))
        XCTAssertEqual(
            try repository.continuityTransitionCount(operationID: cancelledHandoff.operationID),
            0
        )
        XCTAssertNil(try repository.continuityOperationV2(id: deadlineHandoff.operationID))
        XCTAssertNil(try repository.continuityHandoffV2(id: deadlineHandoff.handoffID))
        XCTAssertEqual(
            try repository.continuityTransitionCount(operationID: deadlineHandoff.operationID),
            0
        )
    }

    func testContinuityCreateReturnsCommittedResultWhenCancellationRacesAfterCommit() throws {
        let root = temporaryRoot("continuity-committed-result")
        defer { try? FileManager.default.removeItem(at: root) }
        let projectID = UUID().uuidString.lowercased()
        let cancellation = ToolCallCancellation()
        let repository = try ProjectMemoryRepository(
            projectID: projectID,
            directory: root.appendingPathComponent("memory", isDirectory: true),
            enableFTS5: false,
            cancellation: nil,
            busyRetryObserver: nil,
            didMutationCommitObserver: {
                cancellation.cancel()
            },
            beforeMigrationCommitObserver: nil
        )
        defer { repository.close() }
        let handoff = try makeHandoffV2(
            projectID: projectID,
            generation: 1,
            runID: UUID().uuidString.lowercased(),
            mode: .managedAutonomous
        )

        let operation = try repository.continuityCreateOperationV2(
            handoff: handoff,
            predecessorSessionID: "predecessor",
            predecessorProviderResponseID: "resp-predecessor",
            adapterID: "forge.native-session-host",
            idempotencyKey: "cancel-after-continuity-commit",
            cancellation: cancellation
        )

        XCTAssertTrue(cancellation.isCancelled)
        XCTAssertEqual(operation.operationID, handoff.operationID)
        XCTAssertEqual(operation.state, .active)
        XCTAssertEqual(
            try repository.continuityOperationV2(id: handoff.operationID),
            operation
        )
        XCTAssertNotNil(try repository.continuityHandoffV2(id: handoff.handoffID))
        XCTAssertEqual(
            try repository.continuityTransitionCount(operationID: handoff.operationID),
            1
        )
    }

    func testProjectionRepairSerializesStaleWriterBehindNewerTransition() async throws {
        let root = temporaryRoot("continuity-projection-fence")
        defer { try? FileManager.default.removeItem(at: root) }
        let projectID = UUID().uuidString.lowercased()
        let gate = ContinuityProjectionWriteGate()
        let repository = try ProjectMemoryRepository(
            projectID: projectID,
            directory: root.appendingPathComponent("memory", isDirectory: true),
            enableFTS5: false,
            cancellation: nil,
            busyRetryObserver: nil,
            didMutationCommitObserver: nil,
            beforeMigrationCommitObserver: nil,
            beforeContinuityProjectionWriteObserver: { kind, _, _ in
                gate.observe(kind: kind)
            }
        )
        defer { repository.close() }
        let handoff = try makeHandoffV2(
            projectID: projectID,
            generation: 1,
            runID: UUID().uuidString.lowercased(),
            mode: .managedAutonomous
        )
        let operation = try repository.continuityCreateOperationV2(
            handoff: handoff,
            predecessorSessionID: "predecessor",
            predecessorProviderResponseID: "resp-predecessor",
            adapterID: "forge.native-session-host",
            idempotencyKey: "projection-fence-\(handoff.operationID)"
        )
        gate.arm()

        let olderWriter = Task.detached {
            Result {
                try repository.continuityTransitionV2(
                    operationID: operation.operationID,
                    expected: .active,
                    to: .checkpointPreparing
                )
            }
        }
        XCTAssertEqual(gate.waitUntilBlocked(timeout: 2), .success)

        let newerFinished = DispatchSemaphore(value: 0)
        let newerWriter = Task.detached {
            defer { newerFinished.signal() }
            return Result {
                try repository.continuityTransitionV2(
                    operationID: operation.operationID,
                    expected: .checkpointPreparing,
                    to: .checkpointPersisted
                )
            }
        }
        XCTAssertEqual(
            newerFinished.wait(timeout: .now() + .milliseconds(100)),
            .timedOut,
            "newer transition escaped while the older projection held its version fence"
        )

        gate.release()
        _ = try await olderWriter.value.get()
        _ = try await newerWriter.value.get()
        XCTAssertEqual(newerFinished.wait(timeout: .now()), .success)

        let currentURL = repository.directory
            .appendingPathComponent("continuity", isDirectory: true)
            .appendingPathComponent("CURRENT.json")
        let current = try JSONSupport.object(from: Data(contentsOf: currentURL))
        XCTAssertEqual(current["state"] as? String, ContinuityState.checkpointPersisted.rawValue)
        XCTAssertFalse(
            try repository.continuityProjectionRepairPending(operationID: operation.operationID)
        )
    }

    func testV2RetryMetadataLeavesRepairIntentUntilProjectionMatchesCanonicalRow() throws {
        let fixture = try makeMemoryFixture(label: "retry-projection-repair")
        defer {
            fixture.memory.closeAll()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let handoff = try makeHandoffV2(
            projectID: fixture.projectID,
            generation: 1,
            runID: UUID().uuidString.lowercased(),
            mode: .managedAutonomous
        )
        let operation = try ContinuityStateEngine(memory: fixture.memory).prepareV2(
            handoff: handoff,
            predecessorSessionID: "predecessor",
            predecessorProviderResponseID: "resp-predecessor",
            adapterID: "forge.native-session-host",
            idempotencyKey: "retry-projection-\(handoff.operationID)"
        )
        let repository = try fixture.memory.repositoryForProject(fixture.projectID)
        let operationURL = repository.directory
            .appendingPathComponent("continuity/operations", isDirectory: true)
            .appendingPathComponent("\(operation.operationID).json")
        try FileManager.default.removeItem(at: operationURL)
        try FileManager.default.createDirectory(at: operationURL, withIntermediateDirectories: false)
        let retryAt = "2030-01-01T00:00:00Z"

        try repository.continuityRecordRetry(
            operationID: operation.operationID,
            error: "retry metadata must be projected",
            retryAt: retryAt
        )

        let canonical = try XCTUnwrap(
            repository.continuityOperationV2(id: operation.operationID)
        )
        XCTAssertEqual(canonical.lastError, "retry metadata must be projected")
        XCTAssertEqual(canonical.retryAt, retryAt)
        XCTAssertTrue(
            try repository.continuityProjectionRepairPending(operationID: operation.operationID)
        )

        try FileManager.default.removeItem(at: operationURL)
        XCTAssertEqual(try repository.repairContinuityProjections(), 1)
        let projection = try JSONSupport.object(from: Data(contentsOf: operationURL))
        XCTAssertEqual(projection["last_error"] as? String, canonical.lastError)
        XCTAssertEqual(projection["retry_at"] as? String, retryAt)
        XCTAssertFalse(
            try repository.continuityProjectionRepairPending(operationID: operation.operationID)
        )
    }

    func testContinuationIssuedMutationRefreshesOperationProjection() throws {
        let fixture = try makeMemoryFixture(label: "continuation-issued-projection")
        defer {
            fixture.memory.closeAll()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let handoff = try makeHandoffV2(
            projectID: fixture.projectID,
            generation: 1,
            runID: UUID().uuidString.lowercased(),
            mode: .managedAutonomous
        )
        let engine = ContinuityStateEngine(memory: fixture.memory)
        var operation = try engine.prepareV2(
            handoff: handoff,
            predecessorSessionID: "predecessor",
            predecessorProviderResponseID: "resp-predecessor",
            adapterID: "forge.native-session-host",
            idempotencyKey: "continuation-projection-\(handoff.operationID)"
        )
        let repository = try fixture.memory.repositoryForProject(fixture.projectID)
        operation = try repository.continuityTransitionV2(
            operationID: operation.operationID,
            expected: .checkpointPersisted,
            to: .successorRequested
        )
        operation = try repository.continuityTransitionV2(
            operationID: operation.operationID,
            expected: .successorRequested,
            to: .successorCreated,
            successorSessionID: "continuation-successor",
            successorProviderResponseID: "continuation-successor-response"
        )
        operation = try repository.continuityTransitionV2(
            operationID: operation.operationID,
            expected: .successorCreated,
            to: .successorBootstrapping
        )
        let acknowledgement = BootstrapAcknowledgementV2(
            projectID: ProjectID(try XCTUnwrap(UUID(uuidString: fixture.projectID))),
            projectGeneration: ProjectGeneration(operation.projectGeneration),
            runID: RunID(try XCTUnwrap(UUID(uuidString: operation.runID))),
            operationID: try XCTUnwrap(UUID(uuidString: operation.operationID)),
            handoffID: try XCTUnwrap(UUID(uuidString: handoff.handoffID)),
            handoffSHA256: handoff.contentSHA256,
            nonce: try XCTUnwrap(handoff.bootstrapNonce)
        )
        operation = try repository.continuityAcknowledgeV2(
            operationID: operation.operationID,
            receipt: BootstrapReceipt(
                acknowledgement: acknowledgement,
                internalSessionID: "continuation-successor",
                providerResponseID: "continuation-successor-response",
                modelKey: "fixture/model",
                adapterID: "forge.native-session-host"
            )
        )
        operation = try repository.continuityTransitionV2(
            operationID: operation.operationID,
            expected: .successorAcknowledged,
            to: .predecessorSealed
        )
        let operationURL = repository.directory
            .appendingPathComponent("continuity/operations", isDirectory: true)
            .appendingPathComponent("\(operation.operationID).json")
        let before = try JSONSupport.object(from: Data(contentsOf: operationURL))
        XCTAssertEqual(before["continuation_issued"] as? Bool, false)

        XCTAssertTrue(
            try repository.continuityMarkContinuationIssuedV2(
                operationID: operation.operationID
            )
        )
        let after = try JSONSupport.object(from: Data(contentsOf: operationURL))
        XCTAssertEqual(after["continuation_issued"] as? Bool, true)
        XCTAssertFalse(
            try repository.continuityProjectionRepairPending(operationID: operation.operationID)
        )
    }

    func testManagedBridgeReturnsDurableCheckpointReceiptWithinBoundedCleanup() async throws {
        let fixture = try makeMemoryFixture(label: "bridge-committed-result")
        defer {
            fixture.memory.closeAll()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let controlPlane = try ProjectControlPlaneRepository(
            databaseURL: fixture.root.appendingPathComponent("control-plane.sqlite3"),
            busyTimeoutMilliseconds: 1_000
        )
        defer { Task { await controlPlane.close() } }
        let projectID = ProjectID(try XCTUnwrap(UUID(uuidString: fixture.projectID)))
        let projectRoot = fixture.root.appendingPathComponent("project", isDirectory: true)
        _ = try await controlPlane.registerProject(
            projectID: projectID,
            displayName: "Managed Bridge Fixture",
            canonicalRoot: projectRoot
        )
        let checkpointPersisted = DispatchSemaphore(value: 0)
        let continueToEnqueue = DispatchSemaphore(value: 0)
        let service = ContinuityControlService(
            memory: fixture.memory,
            controlPlane: controlPlane,
            waitTimeout: .milliseconds(25),
            cancellationCleanupTimeout: .milliseconds(25),
            didPrepareDurableObserver: {
                checkpointPersisted.signal()
                _ = continueToEnqueue.wait(timeout: .now() + 3)
            },
            didManagedCommandEnqueueObserver: nil
        )
        let operationID = UUID().uuidString.lowercased()
        let arguments = managedRolloverArguments(
            fixture: fixture,
            operationID: operationID
        )
        let call = ManagedContinuityCall(
            service: service,
            arguments: arguments
        )
        let completed = DispatchGroup()
        completed.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { completed.leave() }
            call.execute()
        }

        XCTAssertEqual(checkpointPersisted.wait(timeout: .now() + 2), .success)
        let repository = try fixture.memory.repositoryForProject(fixture.projectID)
        let commitDeadline = Date().addingTimeInterval(2)
        var committed = false
        while Date() < commitDeadline {
            if try repository.continuityOperationV2(id: operationID)?.state == .checkpointPersisted {
                committed = true
                break
            }
            usleep(10_000)
        }
        XCTAssertTrue(committed, "project-local checkpoint did not reach its durable boundary")
        XCTAssertEqual(
            completed.wait(timeout: .now() + .milliseconds(500)),
            .success,
            "the bridge did not return its durable checkpoint receipt within the cleanup bound"
        )
        switch try XCTUnwrap(call.result) {
        case .success(let response):
            XCTAssertEqual(response["manager_operation_enqueued"] as? Bool, false)
            XCTAssertEqual(response["enqueue_status"] as? String, "pending")
            XCTAssertEqual(response["disposition"] as? String, "manager_enqueue_recovery_pending")
            XCTAssertEqual(response["operation_id"] as? String, operationID)
        case .failure(let error):
            XCTFail("committed managed request lost its result: \(error)")
        }
        continueToEnqueue.signal()
        let enqueueDeadline = Date().addingTimeInterval(2)
        var readyCount = 0
        while Date() < enqueueDeadline {
            readyCount = try await controlPlane.readyContinuityCommandCount()
            if readyCount == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(readyCount, 1)
    }

    func testManagedBridgePublishesCheckpointReceiptBeforeBlockedProjection() async throws {
        let projectionGate = ContinuityProjectionWriteGate()
        let fixture = try makeMemoryFixture(
            label: "bridge-checkpoint-commit-receipt",
            beforeContinuityProjectionWriteObserver: { kind, _, _ in
                projectionGate.observe(kind: kind)
            }
        )
        defer {
            projectionGate.release()
            fixture.memory.closeAll()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let controlPlane = try ProjectControlPlaneRepository(
            databaseURL: fixture.root.appendingPathComponent("control-plane.sqlite3"),
            busyTimeoutMilliseconds: 1_000
        )
        defer { Task { await controlPlane.close() } }
        let projectID = ProjectID(try XCTUnwrap(UUID(uuidString: fixture.projectID)))
        _ = try await controlPlane.registerProject(
            projectID: projectID,
            displayName: "Managed Projection Receipt Fixture",
            canonicalRoot: fixture.root.appendingPathComponent("project", isDirectory: true)
        )
        let service = ContinuityControlService(
            memory: fixture.memory,
            controlPlane: controlPlane,
            waitTimeout: .milliseconds(25),
            cancellationCleanupTimeout: .milliseconds(25)
        )
        let operationID = UUID().uuidString.lowercased()
        let call = ManagedContinuityCall(
            service: service,
            arguments: managedRolloverArguments(fixture: fixture, operationID: operationID)
        )
        projectionGate.arm()
        let completed = DispatchGroup()
        completed.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { completed.leave() }
            call.execute()
        }

        XCTAssertEqual(projectionGate.waitUntilBlocked(timeout: 2), .success)
        let repository = try fixture.memory.repositoryForProject(fixture.projectID)
        XCTAssertEqual(
            try repository.continuityOperationV2(id: operationID)?.state,
            .checkpointPersisted,
            "projection began before the canonical checkpoint commit"
        )
        XCTAssertEqual(
            completed.wait(timeout: .now() + .milliseconds(500)),
            .success,
            "the bridge did not return its commit-boundary receipt while projection was blocked"
        )
        switch try XCTUnwrap(call.result) {
        case .success(let response):
            XCTAssertEqual(response["manager_operation_enqueued"] as? Bool, false)
            XCTAssertEqual(response["enqueue_status"] as? String, "pending")
            XCTAssertEqual(response["projection_repair_pending"] as? Bool, true)
            XCTAssertEqual(response["operation_id"] as? String, operationID)
        case .failure(let error):
            XCTFail("canonical checkpoint lost its pre-projection receipt: \(error)")
        }

        projectionGate.release()
        let enqueueDeadline = Date().addingTimeInterval(2)
        var readyCount = 0
        while Date() < enqueueDeadline {
            readyCount = try await controlPlane.readyContinuityCommandCount()
            if readyCount == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(readyCount, 1)
    }

    func testManagedBridgePublishesCheckpointReceiptBeforeBlockedPostCommitObserver() async throws {
        // A fresh managed preparation commits, in order: operation creation,
        // handoff replay, checkpoint intent, handoff replay, and the canonical
        // checkpoint. Blocking the fifth generic observer deterministically
        // places this test after checkpoint COMMIT but before that observer can
        // return to its caller.
        let postCommitGate = ContinuityPostCommitGate(targetCommit: 5)
        let fixture = try makeMemoryFixture(
            label: "bridge-checkpoint-post-commit-receipt",
            didMutationCommitObserver: {
                postCommitGate.observe()
            }
        )
        defer {
            postCommitGate.release()
            fixture.memory.closeAll()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let controlPlane = try ProjectControlPlaneRepository(
            databaseURL: fixture.root.appendingPathComponent("control-plane.sqlite3"),
            busyTimeoutMilliseconds: 1_000
        )
        defer { Task { await controlPlane.close() } }
        let projectID = ProjectID(try XCTUnwrap(UUID(uuidString: fixture.projectID)))
        _ = try await controlPlane.registerProject(
            projectID: projectID,
            displayName: "Managed Post-Commit Receipt Fixture",
            canonicalRoot: fixture.root.appendingPathComponent("project", isDirectory: true)
        )
        let service = ContinuityControlService(
            memory: fixture.memory,
            controlPlane: controlPlane,
            waitTimeout: .milliseconds(25),
            cancellationCleanupTimeout: .milliseconds(25)
        )
        let operationID = UUID().uuidString.lowercased()
        let call = ManagedContinuityCall(
            service: service,
            arguments: managedRolloverArguments(fixture: fixture, operationID: operationID)
        )
        postCommitGate.arm()
        let completed = DispatchGroup()
        completed.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { completed.leave() }
            call.execute()
        }

        XCTAssertEqual(postCommitGate.waitUntilBlocked(timeout: 2), .success)
        XCTAssertEqual(postCommitGate.observedCommitCount, 5)
        XCTAssertEqual(
            completed.wait(timeout: .now() + .milliseconds(500)),
            .success,
            "the bridge did not return its receipt while the generic post-commit observer was blocked"
        )
        switch try XCTUnwrap(call.result) {
        case .success(let response):
            XCTAssertEqual(response["manager_operation_enqueued"] as? Bool, false)
            XCTAssertEqual(response["enqueue_status"] as? String, "pending")
            XCTAssertEqual(response["operation_id"] as? String, operationID)
            XCTAssertEqual(
                (response["operation"] as? [String: Any])?["state"] as? String,
                ContinuityState.checkpointPersisted.rawValue
            )
        case .failure(let error):
            XCTFail("canonical checkpoint was hidden behind a generic post-commit observer: \(error)")
        }

        postCommitGate.release()
        let enqueueDeadline = Date().addingTimeInterval(2)
        var readyCount = 0
        while Date() < enqueueDeadline {
            readyCount = try await controlPlane.readyContinuityCommandCount()
            if readyCount == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(readyCount, 1)
    }

    func testManagedRunIdentityConflictDoesNotCreateProjectCheckpoint() async throws {
        let fixture = try makeMemoryFixture(label: "managed-preflight-conflict")
        defer {
            fixture.memory.closeAll()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let controlPlane = try ProjectControlPlaneRepository(
            databaseURL: fixture.root.appendingPathComponent("control-plane.sqlite3")
        )
        defer { Task { await controlPlane.close() } }
        let projectID = ProjectID(try XCTUnwrap(UUID(uuidString: fixture.projectID)))
        _ = try await controlPlane.registerProject(
            projectID: projectID,
            displayName: "Managed Preflight Fixture",
            canonicalRoot: fixture.root.appendingPathComponent("project", isDirectory: true)
        )
        let operationID = UUID().uuidString.lowercased()
        let arguments = managedRolloverArguments(
            fixture: fixture,
            operationID: operationID
        )
        let runID = RunID(try XCTUnwrap(UUID(uuidString: arguments["run_id"] as? String ?? "")))
        try await controlPlane.reserveContinuityRun(
            runID: runID,
            projectID: projectID,
            projectGeneration: .initial,
            assignmentID: arguments["assignment_id"] as? String,
            mission: "Conflicting reserved mission",
            mode: .managedAutonomous
        )
        let service = ContinuityControlService(
            memory: fixture.memory,
            controlPlane: controlPlane
        )

        XCTAssertThrowsError(try service.requestRollover(arguments: arguments))
        let repository = try fixture.memory.repositoryForProject(fixture.projectID)
        XCTAssertNil(try repository.continuityOperationV2(id: operationID))
        XCTAssertNil(
            try repository.continuityHandoffV2(
                id: arguments["handoff_id"] as? String ?? ""
            )
        )
        XCTAssertEqual(try repository.continuityTransitionCount(operationID: operationID), 0)
    }

    func testForgeAppManagedToolQueuesExactlyOneCommandAndExternalStaysHandoffOnly() async throws {
        let root = temporaryRoot("production-route")
        let home = root.appendingPathComponent("home", isDirectory: true)
        let managedProject = root.appendingPathComponent("managed-project", isDirectory: true)
        let externalProject = root.appendingPathComponent("external-project", isDirectory: true)
        try FileManager.default.createDirectory(at: managedProject, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalProject, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        _ = try app.config.update(["allowed_roots": [root.path]], save: false)
        let managedClient = ClientID("managed-continuity-client")
        let initialized = try app.tools.call(
            name: "project_memory.initialize",
            arguments: ["project_path": managedProject.path],
            clientID: managedClient
        )
        XCTAssertTrue(initialized.ok, "\(initialized.payload)")
        let projectID = try XCTUnwrap(initialized.payload["project_id"] as? String)
        let generation = try XCTUnwrap(initialized.payload["project_generation"] as? UInt64)
        let runID = UUID().uuidString.lowercased()
        let operationID = UUID().uuidString.lowercased()
        let handoffID = UUID().uuidString.lowercased()
        let nonce = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        let arguments: [String: Any] = [
            "project_id": projectID,
            "project_generation": generation,
            "run_id": runID,
            "operation_id": operationID,
            "handoff_id": handoffID,
            "continuity_mode": ContinuityMode.managedAutonomous.rawValue,
            "predecessor_session_id": "managed-predecessor",
            "provider_id": "lmstudio-local",
            "provider_response_id": "response-predecessor",
            "adapter_id": "forge.native-session-host",
            "model": "fixture/tool-model",
            "mission": "Continue through the manager queue",
            "assignment_id": "FC-CONT-001",
            "phase_id": "FC-CONT-001",
            "work_item_id": "managed-tool-route",
            "summary": "Persist handoff and enqueue rollover",
            "repository_root": managedProject.path,
            "next_actions": ["Claim and execute the queued rollover"],
            "context_capacity": 32_768,
            "context_used": 27_000,
            "context_reserved": 4_096,
            "context_remaining": 1_672,
            "context_confidence": 1.0,
            "context_action": "rollover",
            "context_trigger": "rollover threshold crossed",
            "context_budget_source": "provider_exact",
            "bootstrap_nonce": nonce,
            "idempotency_key": "managed-production-route",
            "requested_by": "continuity.request_rollover",
            "reason": "rollover threshold crossed",
        ]

        let first = try app.tools.call(
            name: "continuity.request_rollover",
            arguments: arguments,
            clientID: managedClient
        )
        XCTAssertTrue(first.ok, "\(first.payload)")
        XCTAssertEqual(first.payload["request_route"] as? String, "manager_command_queue")
        XCTAssertEqual(first.payload["manager_operation_enqueued"] as? Bool, true)
        XCTAssertEqual(first.payload["operation_id"] as? String, operationID)

        let replay = try app.tools.call(
            name: "continuity.request_rollover",
            arguments: arguments,
            clientID: managedClient
        )
        XCTAssertTrue(replay.ok, "\(replay.payload)")
        XCTAssertEqual(replay.payload["command_id"] as? String, first.payload["command_id"] as? String)
        let readyAfterReplay = try await app.projectContexts.repository
            .readyContinuityCommandCount()
        XCTAssertEqual(readyAfterReplay, 1)

        let pending = try app.tools.call(
            name: "continuity.get_pending_handoff",
            arguments: ["project_id": projectID],
            clientID: managedClient
        )
        XCTAssertTrue(pending.ok, "\(pending.payload)")
        XCTAssertEqual(pending.payload["schema_version"] as? Int, 2)
        XCTAssertEqual(
            (pending.payload["operation"] as? [String: Any])?["operation_id"] as? String,
            operationID
        )
        let status = try app.tools.call(
            name: "continuity.status",
            arguments: ["project_id": projectID],
            clientID: managedClient
        )
        XCTAssertTrue(status.ok, "\(status.payload)")
        XCTAssertEqual(status.payload["schema_version"] as? Int, 2)

        let externalClient = ClientID("external-continuity-client")
        let externalInitialized = try app.tools.call(
            name: "project_memory.initialize",
            arguments: ["project_path": externalProject.path],
            clientID: externalClient
        )
        XCTAssertTrue(externalInitialized.ok, "\(externalInitialized.payload)")
        let externalProjectID = try XCTUnwrap(
            externalInitialized.payload["project_id"] as? String
        )
        let external = try app.tools.call(
            name: "continuity.request_rollover",
            arguments: [
                "project_id": externalProjectID,
                "predecessor_session_id": "external-predecessor",
                "mission": "Prepare a handoff for an external host",
            ],
            clientID: externalClient
        )
        XCTAssertTrue(external.ok, "\(external.payload)")
        XCTAssertEqual(external.payload["request_route"] as? String, "external_handoff_only")
        XCTAssertEqual(external.payload["external_capability"] as? String, "handoff_only")
        XCTAssertEqual(external.payload["manager_operation_enqueued"] as? Bool, false)
        let readyAfterExternal = try await app.projectContexts.repository
            .readyContinuityCommandCount()
        XCTAssertEqual(readyAfterExternal, 1)
    }

    func testLegacyMigrationImportsExactProjectReadOnlyAndQuarantinesAmbiguous() throws {
        let fixture = try makeMemoryFixture(label: "legacy-migration")
        defer {
            fixture.memory.closeAll()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let repository = try fixture.memory.repositoryForProject(fixture.projectID)
        let legacyRoot = fixture.root.appendingPathComponent("legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        let exact = try makeLegacyHandoff(projectID: fixture.projectID)
        let exactURL = legacyRoot.appendingPathComponent("exact.json")
        try JSONSupport.data(from: exact.asDictionary()).write(to: exactURL)

        let ambiguous = try makeLegacyHandoff(projectID: UUID().uuidString.lowercased())
        let ambiguousURL = legacyRoot.appendingPathComponent("ambiguous.json")
        try JSONSupport.data(from: ambiguous.asDictionary()).write(to: ambiguousURL)
        let exactSource = try Data(contentsOf: exactURL)
        let ambiguousSource = try Data(contentsOf: ambiguousURL)

        let receiptCountBeforeMigration = try repository.continuityMigrationReceiptCount()
        let receipt = try LegacyContinuityMigrator(repository: repository).migrate(
            candidateFiles: [ambiguousURL, exactURL],
            expectedProjectGeneration: 1,
            boundRunID: nil
        )
        XCTAssertEqual(receipt.importedCount, 1)
        XCTAssertEqual(receipt.skippedCount, 0)
        XCTAssertEqual(receipt.quarantinedCount, 1)
        XCTAssertEqual(try repository.continuityLegacyQuarantineCount(), 1)
        let receiptCountAfterMigration = try repository.continuityMigrationReceiptCount()
        XCTAssertEqual(receiptCountAfterMigration, receiptCountBeforeMigration + 1)
        let imported = try XCTUnwrap(repository.continuityHandoff(id: exact.handoffID))
        XCTAssertEqual(imported.contentSHA256, exact.contentSHA256)
        XCTAssertEqual(imported.mission, exact.mission)
        XCTAssertNil(try repository.continuityActiveOperationV2())
        let firstImport = try XCTUnwrap(
            legacyImportSnapshot(
                databaseURL: repository.databaseURL,
                projectID: fixture.projectID,
                handoffID: exact.handoffID
            )
        )
        XCTAssertEqual(firstImport.schemaVersion, ContinuityHandoff.schemaVersion)
        XCTAssertEqual(firstImport.contentSHA256, exact.contentSHA256)
        XCTAssertEqual(firstImport.quarantineState, "legacy_read_only")
        XCTAssertEqual(firstImport.migrationSource, "legacy_global")
        XCTAssertEqual(firstImport.legacyRecordID, exactURL.lastPathComponent)
        let quarantineDirectory = repository.directory
            .appendingPathComponent("continuity/LegacyContinuityQuarantine", isDirectory: true)
        XCTAssertEqual(try jsonFileCount(in: quarantineDirectory), 1)

        fixture.memory.closeAll()
        let restartedMemory = ProjectMemoryService(paths: AppPaths(home: fixture.home))
        defer { restartedMemory.closeAll() }
        let restartedRepository = try restartedMemory.repositoryForProject(fixture.projectID)
        let reopened = try XCTUnwrap(
            restartedRepository.continuityHandoff(id: exact.handoffID)
        )
        XCTAssertEqual(reopened.contentSHA256, exact.contentSHA256)
        XCTAssertEqual(reopened.mission, exact.mission)
        XCTAssertEqual(try restartedRepository.continuityLegacyQuarantineCount(), 1)
        XCTAssertEqual(
            try restartedRepository.continuityMigrationReceiptCount(),
            receiptCountAfterMigration
        )
        XCTAssertEqual(try jsonFileCount(in: quarantineDirectory), 1)

        let replay = try LegacyContinuityMigrator(repository: restartedRepository).migrate(
            candidateFiles: [ambiguousURL, exactURL],
            expectedProjectGeneration: 1,
            boundRunID: nil
        )
        XCTAssertEqual(replay, receipt)
        XCTAssertEqual(try restartedRepository.continuityLegacyQuarantineCount(), 1)
        XCTAssertEqual(try jsonFileCount(in: quarantineDirectory), 1)
        XCTAssertEqual(
            try restartedRepository.continuityMigrationReceiptCount(),
            receiptCountAfterMigration,
            "Replaying the same legacy source set must not append a duplicate receipt"
        )
        let replayed = try XCTUnwrap(
            restartedRepository.continuityHandoff(id: exact.handoffID)
        )
        XCTAssertEqual(replayed.contentSHA256, exact.contentSHA256)
        XCTAssertEqual(replayed.mission, exact.mission)
        XCTAssertNil(try restartedRepository.continuityActiveOperationV2())

        let subsetReceipt = try LegacyContinuityMigrator(repository: restartedRepository).migrate(
            candidateFiles: [exactURL],
            expectedProjectGeneration: 1,
            boundRunID: nil
        )
        XCTAssertNotEqual(subsetReceipt.receiptID, receipt.receiptID)
        XCTAssertEqual(subsetReceipt.importedCount, 0)
        XCTAssertEqual(subsetReceipt.skippedCount, 1)
        XCTAssertEqual(subsetReceipt.quarantinedCount, 0)
        XCTAssertEqual(
            try restartedRepository.continuityMigrationReceiptCount(),
            receiptCountAfterMigration + 1,
            "A distinct legacy source set must retain its own deterministic receipt"
        )
        let subsetReplay = try LegacyContinuityMigrator(repository: restartedRepository).migrate(
            candidateFiles: [exactURL],
            expectedProjectGeneration: 1,
            boundRunID: nil
        )
        XCTAssertEqual(subsetReplay, subsetReceipt)
        XCTAssertEqual(
            try restartedRepository.continuityMigrationReceiptCount(),
            receiptCountAfterMigration + 1
        )
        XCTAssertEqual(try Data(contentsOf: exactURL), exactSource)
        XCTAssertEqual(try Data(contentsOf: ambiguousURL), ambiguousSource)
    }

    func testLegacyMigrationReceiptFailureRollsBackSideEffectsAndReplayRepairsProjection() throws {
        let fixture = try makeMemoryFixture(label: "legacy-receipt-rollback")
        defer {
            fixture.memory.closeAll()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let repository = try fixture.memory.repositoryForProject(fixture.projectID)
        let legacyRoot = fixture.root.appendingPathComponent("legacy-atomic", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)

        let exact = try makeLegacyHandoff(projectID: fixture.projectID)
        let exactURL = legacyRoot.appendingPathComponent("01-exact.json")
        try JSONSupport.data(from: exact.asDictionary()).write(to: exactURL)
        let ambiguous = try makeLegacyHandoff(projectID: UUID().uuidString.lowercased())
        let ambiguousURL = legacyRoot.appendingPathComponent("02-ambiguous.json")
        try JSONSupport.data(from: ambiguous.asDictionary()).write(to: ambiguousURL)
        let exactSource = try Data(contentsOf: exactURL)
        let ambiguousSource = try Data(contentsOf: ambiguousURL)
        let baselineReceiptCount = try repository.continuityMigrationReceiptCount()
        let baselineQuarantineCount = try repository.continuityLegacyQuarantineCount()
        let quarantineDirectory = repository.directory
            .appendingPathComponent("continuity/LegacyContinuityQuarantine", isDirectory: true)

        let triggerName = "legacy_receipt_failure_after_staging"
        try executeLegacyMigrationSQL(
            at: repository.databaseURL,
            sql: """
            CREATE TRIGGER \(triggerName)
            BEFORE INSERT ON continuity_migration_receipts
            WHEN NEW.source_version='legacy_global'
            BEGIN
              SELECT CASE
                WHEN (
                  SELECT COUNT(*) FROM continuity_handoffs
                  WHERE project_id=NEW.project_id
                    AND handoff_id='\(exact.handoffID)'
                    AND migration_source='legacy_global'
                    AND quarantine_state='legacy_read_only'
                )=1
                AND (
                  SELECT COUNT(*) FROM legacy_continuity_quarantine
                  WHERE project_id=NEW.project_id
                )=1
                THEN RAISE(ABORT, 'injected legacy receipt failure after staged effects')
                ELSE RAISE(ABORT, 'legacy receipt reached without staged effects')
              END;
            END;
            """
        )
        var triggerInstalled = true
        defer {
            if triggerInstalled {
                try? executeLegacyMigrationSQL(
                    at: repository.databaseURL,
                    sql: "DROP TRIGGER IF EXISTS \(triggerName);"
                )
            }
        }

        XCTAssertThrowsError(
            try LegacyContinuityMigrator(repository: repository).migrate(
                candidateFiles: [ambiguousURL, exactURL],
                expectedProjectGeneration: 1,
                boundRunID: nil
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains(
                    "injected legacy receipt failure after staged effects"
                ),
                "\(error)"
            )
        }
        XCTAssertNil(
            try legacyImportSnapshot(
                databaseURL: repository.databaseURL,
                projectID: fixture.projectID,
                handoffID: exact.handoffID
            )
        )
        XCTAssertEqual(
            try repository.continuityLegacyQuarantineCount(),
            baselineQuarantineCount
        )
        XCTAssertEqual(
            try repository.continuityMigrationReceiptCount(),
            baselineReceiptCount
        )
        XCTAssertEqual(
            try legacyMigrationInt(
                at: repository.databaseURL,
                sql: """
                SELECT COUNT(*) FROM continuity_migration_receipts
                WHERE project_id=? AND source_version='legacy_global';
                """,
                bindings: [fixture.projectID]
            ),
            0
        )
        XCTAssertEqual(try legacyJSONFiles(in: quarantineDirectory).count, 0)

        try executeLegacyMigrationSQL(
            at: repository.databaseURL,
            sql: "DROP TRIGGER \(triggerName);"
        )
        triggerInstalled = false

        let receipt = try LegacyContinuityMigrator(repository: repository).migrate(
            candidateFiles: [ambiguousURL, exactURL],
            expectedProjectGeneration: 1,
            boundRunID: nil
        )
        XCTAssertEqual(receipt.importedCount, 1)
        XCTAssertEqual(receipt.skippedCount, 0)
        XCTAssertEqual(receipt.quarantinedCount, 1)
        XCTAssertNotNil(
            try legacyImportSnapshot(
                databaseURL: repository.databaseURL,
                projectID: fixture.projectID,
                handoffID: exact.handoffID
            )
        )
        XCTAssertEqual(
            try repository.continuityLegacyQuarantineCount(),
            baselineQuarantineCount + 1
        )
        XCTAssertEqual(
            try repository.continuityMigrationReceiptCount(),
            baselineReceiptCount + 1
        )
        let initialProjectionFiles = try legacyJSONFiles(in: quarantineDirectory)
        XCTAssertEqual(initialProjectionFiles.count, 1)
        let initialProjection = try XCTUnwrap(initialProjectionFiles.first)
        let initialProjectionData = try Data(contentsOf: initialProjection)
        try FileManager.default.removeItem(at: initialProjection)
        XCTAssertEqual(try legacyJSONFiles(in: quarantineDirectory).count, 0)

        let replay = try LegacyContinuityMigrator(repository: repository).migrate(
            candidateFiles: [ambiguousURL, exactURL],
            expectedProjectGeneration: 1,
            boundRunID: nil
        )
        XCTAssertEqual(replay, receipt)
        XCTAssertEqual(
            try repository.continuityLegacyQuarantineCount(),
            baselineQuarantineCount + 1
        )
        XCTAssertEqual(
            try repository.continuityMigrationReceiptCount(),
            baselineReceiptCount + 1
        )
        let repairedProjectionFiles = try legacyJSONFiles(in: quarantineDirectory)
        XCTAssertEqual(repairedProjectionFiles.count, 1)
        let repairedProjection = try XCTUnwrap(repairedProjectionFiles.first)
        XCTAssertEqual(repairedProjection.lastPathComponent, initialProjection.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: repairedProjection), initialProjectionData)
        XCTAssertEqual(try Data(contentsOf: exactURL), exactSource)
        XCTAssertEqual(try Data(contentsOf: ambiguousURL), ambiguousSource)
    }

    func testConcurrentIdenticalLegacyMigrationsCommitOneUnsplittableReceipt() async throws {
        let fixture = try makeMemoryFixture(label: "legacy-concurrent-receipt")
        defer {
            fixture.memory.closeAll()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let seededRepository = try fixture.memory.repositoryForProject(fixture.projectID)
        let directory = seededRepository.directory
        let databaseURL = seededRepository.databaseURL
        let baselineReceiptCount = try seededRepository.continuityMigrationReceiptCount()
        fixture.memory.closeAll()

        let legacyRoot = fixture.root.appendingPathComponent("legacy-concurrent", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        let exact = try makeLegacyHandoff(projectID: fixture.projectID)
        let exactURL = legacyRoot.appendingPathComponent("01-exact.json")
        try JSONSupport.data(from: exact.asDictionary()).write(to: exactURL)
        let ambiguous = try makeLegacyHandoff(projectID: UUID().uuidString.lowercased())
        let ambiguousURL = legacyRoot.appendingPathComponent("02-ambiguous.json")
        try JSONSupport.data(from: ambiguous.asDictionary()).write(to: ambiguousURL)
        let exactSHA256 = JSONSupport.sha256Hex(try Data(contentsOf: exactURL))
        let ambiguousSHA256 = JSONSupport.sha256Hex(try Data(contentsOf: ambiguousURL))

        let participantCount = 4
        let repositories = try (0..<participantCount).map { _ in
            try ProjectMemoryRepository(
                projectID: fixture.projectID,
                directory: directory,
                enableFTS5: false
            )
        }
        defer { repositories.forEach { $0.close() } }
        let gate = LegacyMigrationStartGate(participantCount: participantCount)
        let candidateFiles = [ambiguousURL, exactURL]
        let receipts = try await withThrowingTaskGroup(
            of: LegacyContinuityMigrationReceipt.self,
            returning: [LegacyContinuityMigrationReceipt].self
        ) { group in
            for repository in repositories {
                group.addTask {
                    await gate.wait()
                    return try LegacyContinuityMigrator(repository: repository).migrate(
                        candidateFiles: candidateFiles,
                        expectedProjectGeneration: 1,
                        boundRunID: nil
                    )
                }
            }
            var output: [LegacyContinuityMigrationReceipt] = []
            output.reserveCapacity(participantCount)
            for try await receipt in group { output.append(receipt) }
            return output
        }

        XCTAssertEqual(receipts.count, participantCount)
        let receipt = try XCTUnwrap(receipts.first)
        XCTAssertTrue(receipts.allSatisfy { $0 == receipt })
        XCTAssertEqual(receipt.importedCount, 1)
        XCTAssertEqual(receipt.skippedCount, 0)
        XCTAssertEqual(receipt.quarantinedCount, 1)
        XCTAssertNotNil(
            try legacyImportSnapshot(
                databaseURL: databaseURL,
                projectID: fixture.projectID,
                handoffID: exact.handoffID
            )
        )
        XCTAssertEqual(try repositories[0].continuityLegacyQuarantineCount(), 1)
        XCTAssertEqual(
            try repositories[0].continuityMigrationReceiptCount(),
            baselineReceiptCount + 1
        )
        XCTAssertEqual(
            try legacyMigrationInt(
                at: databaseURL,
                sql: """
                SELECT COUNT(*) FROM continuity_migration_receipts
                WHERE project_id=? AND source_version='legacy_global';
                """,
                bindings: [fixture.projectID]
            ),
            1
        )
        let detailsJSON = try XCTUnwrap(
            try legacyMigrationText(
                at: databaseURL,
                sql: """
                SELECT details_json FROM continuity_migration_receipts
                WHERE receipt_id=? AND project_id=? LIMIT 1;
                """,
                bindings: [receipt.receiptID, fixture.projectID]
            )
        )
        let details = try JSONSupport.object(from: Data(detailsJSON.utf8))
        XCTAssertEqual(details["imported_source_sha256"] as? [String], [exactSHA256])
        XCTAssertEqual(details["quarantined_source_sha256"] as? [String], [ambiguousSHA256])
        let quarantineDirectory = directory
            .appendingPathComponent("continuity/LegacyContinuityQuarantine", isDirectory: true)
        XCTAssertEqual(try legacyJSONFiles(in: quarantineDirectory).count, 1)
    }

    func testLegacyMigrationAliasesOnePayloadAcrossFilenamesAndReplaysAfterRestart() throws {
        let fixture = try makeMemoryFixture(label: "legacy-alias-replay")
        defer {
            fixture.memory.closeAll()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let repository = try fixture.memory.repositoryForProject(fixture.projectID)
        let legacyRoot = fixture.root.appendingPathComponent("legacy-aliases", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        let handoff = try makeLegacyHandoff(projectID: fixture.projectID)
        let source = try JSONSupport.data(from: handoff.asDictionary())
        let ownerURL = legacyRoot.appendingPathComponent("01-owner.json")
        let aliasURL = legacyRoot.appendingPathComponent("02-alias.json")
        try source.write(to: ownerURL)
        try source.write(to: aliasURL)
        let baselineReceiptCount = try repository.continuityMigrationReceiptCount()

        let receipt = try LegacyContinuityMigrator(repository: repository).migrate(
            candidateFiles: [aliasURL, ownerURL],
            expectedProjectGeneration: 1,
            boundRunID: nil
        )
        XCTAssertEqual(receipt.importedCount, 1)
        XCTAssertEqual(receipt.skippedCount, 1)
        XCTAssertEqual(receipt.quarantinedCount, 0)
        XCTAssertEqual(
            try XCTUnwrap(
                legacyImportSnapshot(
                    databaseURL: repository.databaseURL,
                    projectID: fixture.projectID,
                    handoffID: handoff.handoffID
                )
            ).legacyRecordID,
            ownerURL.lastPathComponent
        )

        fixture.memory.closeAll()
        let restartedMemory = ProjectMemoryService(paths: AppPaths(home: fixture.home))
        defer { restartedMemory.closeAll() }
        let restartedRepository = try restartedMemory.repositoryForProject(fixture.projectID)
        let replay = try LegacyContinuityMigrator(repository: restartedRepository).migrate(
            candidateFiles: [ownerURL, aliasURL],
            expectedProjectGeneration: 1,
            boundRunID: nil
        )
        XCTAssertEqual(replay, receipt)
        XCTAssertEqual(
            try restartedRepository.continuityMigrationReceiptCount(),
            baselineReceiptCount + 1
        )
        XCTAssertEqual(try Data(contentsOf: ownerURL), source)
        XCTAssertEqual(try Data(contentsOf: aliasURL), source)
    }

    func testLegacyMigrationRejectsMalformedExactRowBeforeRecordingReceipt() throws {
        let fixture = try makeMemoryFixture(label: "legacy-malformed-exact")
        defer {
            fixture.memory.closeAll()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let repository = try fixture.memory.repositoryForProject(fixture.projectID)
        let legacyRoot = fixture.root.appendingPathComponent("legacy-malformed", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        let handoff = try makeLegacyHandoff(projectID: fixture.projectID)
        let candidateURL = legacyRoot.appendingPathComponent("candidate.json")
        try JSONSupport.data(from: handoff.asDictionary()).write(to: candidateURL)
        XCTAssertTrue(
            try repository.continuityImportLegacyReadOnly(
                payload: handoff.asDictionary(),
                handoffID: handoff.handoffID,
                operationID: handoff.operationID,
                schemaVersion: ContinuityHandoff.schemaVersion,
                contentSHA256: handoff.contentSHA256,
                createdAt: handoff.createdAt,
                projectGeneration: nil,
                runID: nil,
                predecessorProviderResponseID: nil,
                bootstrapNonce: nil,
                sourceRecordID: candidateURL.lastPathComponent
            )
        )
        try executeLegacyMigrationSQL(
            at: repository.databaseURL,
            sql: """
            UPDATE continuity_handoffs
            SET quarantine_state=NULL,migration_source='compatibility_v1',legacy_record_id=NULL
            WHERE project_id='\(fixture.projectID)' AND handoff_id='\(handoff.handoffID)';
            """
        )
        let baselineReceiptCount = try repository.continuityMigrationReceiptCount()

        XCTAssertThrowsError(
            try LegacyContinuityMigrator(repository: repository).migrate(
                candidateFiles: [candidateURL],
                expectedProjectGeneration: 1,
                boundRunID: nil
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("imported side effect"),
                "\(error)"
            )
        }
        XCTAssertEqual(
            try repository.continuityMigrationReceiptCount(),
            baselineReceiptCount
        )
    }

    func testLegacyMigrationRejectsReceiptCountAndHashCategoryTampering() throws {
        let fixture = try makeMemoryFixture(label: "legacy-receipt-tamper")
        defer {
            fixture.memory.closeAll()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let repository = try fixture.memory.repositoryForProject(fixture.projectID)
        let legacyRoot = fixture.root.appendingPathComponent("legacy-tamper", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        let exact = try makeLegacyHandoff(projectID: fixture.projectID)
        let exactURL = legacyRoot.appendingPathComponent("01-exact.json")
        try JSONSupport.data(from: exact.asDictionary()).write(to: exactURL)
        let ambiguous = try makeLegacyHandoff(projectID: UUID().uuidString.lowercased())
        let ambiguousURL = legacyRoot.appendingPathComponent("02-ambiguous.json")
        try JSONSupport.data(from: ambiguous.asDictionary()).write(to: ambiguousURL)
        let candidates = [exactURL, ambiguousURL]
        let receipt = try LegacyContinuityMigrator(repository: repository).migrate(
            candidateFiles: candidates,
            expectedProjectGeneration: 1,
            boundRunID: nil
        )
        let originalDetailsJSON = try XCTUnwrap(
            try legacyMigrationText(
                at: repository.databaseURL,
                sql: "SELECT details_json FROM continuity_migration_receipts WHERE receipt_id=?;",
                bindings: [receipt.receiptID]
            )
        )
        let originalDetails = try JSONSupport.object(from: Data(originalDetailsJSON.utf8))

        try updateLegacyMigrationReceipt(
            at: repository.databaseURL,
            receiptID: receipt.receiptID,
            importedCount: 0,
            skippedCount: 0,
            quarantinedCount: 2,
            detailsJSON: originalDetailsJSON
        )
        XCTAssertThrowsError(
            try LegacyContinuityMigrator(repository: repository).migrate(
                candidateFiles: candidates,
                expectedProjectGeneration: 1,
                boundRunID: nil
            )
        )

        var swappedDetails = originalDetails
        let importedHashes = try XCTUnwrap(swappedDetails["imported_source_sha256"] as? [String])
        let quarantinedHashes = try XCTUnwrap(
            swappedDetails["quarantined_source_sha256"] as? [String]
        )
        swappedDetails["imported_source_sha256"] = quarantinedHashes
        swappedDetails["quarantined_source_sha256"] = importedHashes
        try updateLegacyMigrationReceipt(
            at: repository.databaseURL,
            receiptID: receipt.receiptID,
            importedCount: 1,
            skippedCount: 0,
            quarantinedCount: 1,
            detailsJSON: try JSONSupport.string(from: swappedDetails)
        )
        XCTAssertThrowsError(
            try LegacyContinuityMigrator(repository: repository).migrate(
                candidateFiles: candidates,
                expectedProjectGeneration: 1,
                boundRunID: nil
            )
        )

        XCTAssertEqual(
            originalDetails["candidate_outcomes"] as? [String],
            ["imported", "quarantined"]
        )
        var outcomeTamperedDetails = originalDetails
        outcomeTamperedDetails["candidate_outcomes"] = ["quarantined", "imported"]
        try updateLegacyMigrationReceipt(
            at: repository.databaseURL,
            receiptID: receipt.receiptID,
            importedCount: 1,
            skippedCount: 0,
            quarantinedCount: 1,
            detailsJSON: try JSONSupport.string(from: outcomeTamperedDetails)
        )
        XCTAssertThrowsError(
            try LegacyContinuityMigrator(repository: repository).migrate(
                candidateFiles: candidates,
                expectedProjectGeneration: 1,
                boundRunID: nil
            )
        )

        let originalLedgerSHA256 = try XCTUnwrap(
            originalDetails["outcome_ledger_sha256"] as? String
        )
        var ledgerTamperedDetails = originalDetails
        let replacementLedgerSHA256 = String(
            repeating: originalLedgerSHA256 == String(repeating: "0", count: 64) ? "1" : "0",
            count: 64
        )
        ledgerTamperedDetails["outcome_ledger_sha256"] = replacementLedgerSHA256
        try updateLegacyMigrationReceipt(
            at: repository.databaseURL,
            receiptID: receipt.receiptID,
            importedCount: 1,
            skippedCount: 0,
            quarantinedCount: 1,
            detailsJSON: try JSONSupport.string(from: ledgerTamperedDetails)
        )
        XCTAssertThrowsError(
            try LegacyContinuityMigrator(repository: repository).migrate(
                candidateFiles: candidates,
                expectedProjectGeneration: 1,
                boundRunID: nil
            )
        )

        try updateLegacyMigrationReceipt(
            at: repository.databaseURL,
            receiptID: receipt.receiptID,
            importedCount: 1,
            skippedCount: 0,
            quarantinedCount: 1,
            detailsJSON: originalDetailsJSON
        )
        XCTAssertEqual(
            try LegacyContinuityMigrator(repository: repository).migrate(
                candidateFiles: candidates,
                expectedProjectGeneration: 1,
                boundRunID: nil
            ),
            receipt
        )
    }

    func testLegacyMigrationReconcilesVerifiedVersionOneReceiptDetails() throws {
        let fixture = try makeMemoryFixture(label: "legacy-receipt-v1-upgrade")
        defer {
            fixture.memory.closeAll()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let repository = try fixture.memory.repositoryForProject(fixture.projectID)
        let legacyRoot = fixture.root.appendingPathComponent("legacy-v1-receipt", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        let aliasOwner = try makeLegacyHandoff(projectID: fixture.projectID)
        let aliasSource = try JSONSupport.data(from: aliasOwner.asDictionary())
        let ownerURL = legacyRoot.appendingPathComponent("01-owner.json")
        let aliasURL = legacyRoot.appendingPathComponent("02-alias.json")
        try aliasSource.write(to: ownerURL)
        try aliasSource.write(to: aliasURL)

        let ambiguous = try makeLegacyHandoff(projectID: UUID().uuidString.lowercased())
        let ambiguousSource = try JSONSupport.data(from: ambiguous.asDictionary())
        let ambiguousURL = legacyRoot.appendingPathComponent("03-ambiguous.json")
        try ambiguousSource.write(to: ambiguousURL)

        let collisionHandoffID = UUID().uuidString.lowercased()
        let collisionOwner = try makeLegacyHandoff(
            projectID: fixture.projectID,
            handoffID: collisionHandoffID,
            mission: "Existing collision owner"
        )
        let collisionCandidate = try makeLegacyHandoff(
            projectID: fixture.projectID,
            handoffID: collisionHandoffID,
            mission: "Conflicting migration candidate"
        )
        XCTAssertTrue(
            try repository.continuityImportLegacyReadOnly(
                payload: collisionOwner.asDictionary(),
                handoffID: collisionOwner.handoffID,
                operationID: collisionOwner.operationID,
                schemaVersion: ContinuityHandoff.schemaVersion,
                contentSHA256: collisionOwner.contentSHA256,
                createdAt: collisionOwner.createdAt,
                projectGeneration: nil,
                runID: nil,
                predecessorProviderResponseID: nil,
                bootstrapNonce: nil,
                sourceRecordID: "preexisting-collision.json"
            )
        )
        let collisionSource = try JSONSupport.data(from: collisionCandidate.asDictionary())
        let collisionURL = legacyRoot.appendingPathComponent("04-collision.json")
        try collisionSource.write(to: collisionURL)

        let candidates = [collisionURL, ambiguousURL, aliasURL, ownerURL]
        let selectedCandidates = [ownerURL, aliasURL, ambiguousURL, collisionURL]
        let sourceHashes = [
            JSONSupport.sha256Hex(aliasSource),
            JSONSupport.sha256Hex(aliasSource),
            JSONSupport.sha256Hex(ambiguousSource),
            JSONSupport.sha256Hex(collisionSource),
        ]
        let expectedOutcomes = ["imported", "skipped", "quarantined", "quarantined"]
        let candidateIdentities: [[String: Any]] = zip(selectedCandidates, sourceHashes).map {
            candidate, sourceSHA256 in
            [
                "path_sha256": JSONSupport.sha256Hex(candidate.standardizedFileURL.path),
                "content_state": "read",
                "source_sha256": sourceSHA256,
            ]
        }
        let expectedFingerprintSHA256 = JSONSupport.sha256Hex(
            try JSONSupport.canonicalJSON([
                "schema_version": 1,
                "project_id": fixture.projectID,
                "expected_project_generation": Int64(1),
                "bound_run_id": NSNull(),
                "submitted_candidate_count": candidates.count,
                "selected_candidates": candidateIdentities,
            ] as [String: Any])
        )
        let ledgerCandidates: [[String: Any]] = zip(
            candidateIdentities,
            expectedOutcomes
        ).map { identity, outcome in
            var candidate = identity
            candidate["outcome"] = outcome
            return candidate
        }
        let expectedLedgerSHA256 = JSONSupport.sha256Hex(
            try JSONSupport.canonicalJSON([
                "schema_version": 1,
                "candidates": ledgerCandidates,
            ] as [String: Any])
        )
        let baselineReceiptCount = try repository.continuityMigrationReceiptCount()
        let baselineQuarantineCount = try repository.continuityLegacyQuarantineCount()
        let receipt = try LegacyContinuityMigrator(repository: repository).migrate(
            candidateFiles: candidates,
            expectedProjectGeneration: 1,
            boundRunID: nil
        )
        XCTAssertEqual(receipt.importedCount, 1)
        XCTAssertEqual(receipt.skippedCount, 1)
        XCTAssertEqual(receipt.quarantinedCount, 2)
        let detailsJSON = try XCTUnwrap(
            try legacyMigrationText(
                at: repository.databaseURL,
                sql: "SELECT details_json FROM continuity_migration_receipts WHERE receipt_id=?;",
                bindings: [receipt.receiptID]
            )
        )
        var legacyDetails = try JSONSupport.object(from: Data(detailsJSON.utf8))
        legacyDetails.removeValue(forKey: "receipt_details_schema_version")
        legacyDetails.removeValue(forKey: "candidate_outcomes")
        legacyDetails.removeValue(forKey: "outcome_ledger_sha256")
        legacyDetails["quarantined_source_sha256"] = [sourceHashes[2]]
        try updateLegacyMigrationReceipt(
            at: repository.databaseURL,
            receiptID: receipt.receiptID,
            importedCount: receipt.importedCount,
            skippedCount: receipt.skippedCount,
            quarantinedCount: receipt.quarantinedCount,
            detailsJSON: try JSONSupport.string(from: legacyDetails)
        )

        let replay = try LegacyContinuityMigrator(repository: repository).migrate(
            candidateFiles: candidates,
            expectedProjectGeneration: 1,
            boundRunID: nil
        )
        XCTAssertEqual(replay, receipt)
        let upgradedDetailsJSON = try XCTUnwrap(
            try legacyMigrationText(
                at: repository.databaseURL,
                sql: "SELECT details_json FROM continuity_migration_receipts WHERE receipt_id=?;",
                bindings: [receipt.receiptID]
            )
        )
        let upgradedDetails = try JSONSupport.object(from: Data(upgradedDetailsJSON.utf8))
        XCTAssertEqual(upgradedDetails["receipt_details_schema_version"] as? Int, 2)
        XCTAssertEqual(upgradedDetails["candidate_count"] as? Int, 4)
        XCTAssertEqual(upgradedDetails["candidate_outcomes"] as? [String], expectedOutcomes)
        XCTAssertEqual(upgradedDetails["imported_source_sha256"] as? [String], [sourceHashes[0]])
        XCTAssertEqual(
            upgradedDetails["quarantined_source_sha256"] as? [String],
            [sourceHashes[2], sourceHashes[3]]
        )
        XCTAssertEqual(
            upgradedDetails["migration_fingerprint_sha256"] as? String,
            expectedFingerprintSHA256
        )
        XCTAssertEqual(
            upgradedDetails["outcome_ledger_sha256"] as? String,
            expectedLedgerSHA256
        )
        XCTAssertEqual(upgradedDetails["global_latest_used_as_authority"] as? Bool, false)
        XCTAssertEqual(
            try XCTUnwrap(
                legacyImportSnapshot(
                    databaseURL: repository.databaseURL,
                    projectID: fixture.projectID,
                    handoffID: aliasOwner.handoffID
                )
            ).legacyRecordID,
            ownerURL.lastPathComponent
        )
        XCTAssertEqual(
            try repository.continuityMigrationReceiptCount(),
            baselineReceiptCount + 1
        )
        XCTAssertEqual(
            try repository.continuityLegacyQuarantineCount(),
            baselineQuarantineCount + 2
        )

        fixture.memory.closeAll()
        let restartedMemory = ProjectMemoryService(paths: AppPaths(home: fixture.home))
        defer { restartedMemory.closeAll() }
        let restartedRepository = try restartedMemory.repositoryForProject(fixture.projectID)
        XCTAssertEqual(
            try LegacyContinuityMigrator(repository: restartedRepository).migrate(
                candidateFiles: candidates,
                expectedProjectGeneration: 1,
                boundRunID: nil
            ),
            receipt
        )
        XCTAssertEqual(
            try legacyMigrationText(
                at: restartedRepository.databaseURL,
                sql: "SELECT details_json FROM continuity_migration_receipts WHERE receipt_id=?;",
                bindings: [receipt.receiptID]
            ),
            upgradedDetailsJSON
        )
        XCTAssertEqual(
            try restartedRepository.continuityMigrationReceiptCount(),
            baselineReceiptCount + 1
        )
        XCTAssertEqual(
            try restartedRepository.continuityLegacyQuarantineCount(),
            baselineQuarantineCount + 2
        )
    }

    func testLegacyLocationV2MigrationPreservesBindingAcrossRestartAndIdempotentReplay() throws {
        let fixture = try makeMemoryFixture(label: "legacy-v2-location")
        defer {
            fixture.memory.closeAll()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let repository = try fixture.memory.repositoryForProject(fixture.projectID)
        let legacyRoot = fixture.root.appendingPathComponent("legacy-v2", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        let runID = UUID().uuidString.lowercased()
        let handoff = try makeHandoffV2(
            projectID: fixture.projectID,
            generation: 7,
            runID: runID
        )
        let handoffURL = legacyRoot.appendingPathComponent("bound-v2.json")
        try JSONSupport.data(from: handoff.asDictionary()).write(to: handoffURL)
        let legacySource = try Data(contentsOf: handoffURL)

        let receiptCountBeforeMigration = try repository.continuityMigrationReceiptCount()
        let receipt = try LegacyContinuityMigrator(repository: repository).migrate(
            candidateFiles: [handoffURL],
            expectedProjectGeneration: 7,
            boundRunID: runID
        )
        XCTAssertEqual(receipt.importedCount, 1)
        XCTAssertEqual(receipt.skippedCount, 0)
        XCTAssertEqual(receipt.quarantinedCount, 0)
        XCTAssertEqual(try repository.continuityLegacyQuarantineCount(), 0)
        let receiptCountAfterMigration = try repository.continuityMigrationReceiptCount()
        XCTAssertEqual(receiptCountAfterMigration, receiptCountBeforeMigration + 1)
        XCTAssertNil(try repository.continuityHandoffV2(id: handoff.handoffID))
        XCTAssertNil(try repository.continuityActiveOperationV2())

        let firstImport = try XCTUnwrap(
            legacyImportSnapshot(
                databaseURL: repository.databaseURL,
                projectID: fixture.projectID,
                handoffID: handoff.handoffID
            )
        )
        XCTAssertEqual(firstImport.schemaVersion, ContinuityHandoffV2.schemaVersion)
        XCTAssertEqual(firstImport.projectGeneration, 7)
        XCTAssertEqual(firstImport.runID, runID)
        XCTAssertEqual(firstImport.predecessorProviderResponseID, "resp-predecessor")
        XCTAssertEqual(firstImport.bootstrapNonce, handoff.bootstrapNonce)
        XCTAssertEqual(firstImport.contentSHA256, handoff.contentSHA256)
        XCTAssertEqual(firstImport.quarantineState, "legacy_read_only")
        XCTAssertEqual(firstImport.migrationSource, "legacy_global")
        XCTAssertEqual(firstImport.legacyRecordID, handoffURL.lastPathComponent)
        let importedPayload = try JSONSupport.object(from: Data(firstImport.payloadJSON.utf8))
        let importedHandoff = try XCTUnwrap(ContinuityHandoffV2.fromDictionary(importedPayload))
        XCTAssertEqual(importedHandoff.mission, handoff.mission)
        XCTAssertEqual(importedHandoff.runID, runID)
        XCTAssertEqual(importedHandoff.projectGeneration, 7)

        fixture.memory.closeAll()
        let restartedMemory = ProjectMemoryService(paths: AppPaths(home: fixture.home))
        defer { restartedMemory.closeAll() }
        let restartedRepository = try restartedMemory.repositoryForProject(fixture.projectID)
        let reopenedImport = try XCTUnwrap(
            legacyImportSnapshot(
                databaseURL: restartedRepository.databaseURL,
                projectID: fixture.projectID,
                handoffID: handoff.handoffID
            )
        )
        XCTAssertEqual(reopenedImport.contentSHA256, handoff.contentSHA256)
        XCTAssertEqual(reopenedImport.projectGeneration, 7)
        XCTAssertEqual(reopenedImport.runID, runID)
        XCTAssertEqual(try restartedRepository.continuityLegacyQuarantineCount(), 0)
        XCTAssertEqual(
            try restartedRepository.continuityMigrationReceiptCount(),
            receiptCountAfterMigration
        )
        XCTAssertNil(try restartedRepository.continuityHandoffV2(id: handoff.handoffID))
        XCTAssertNil(try restartedRepository.continuityActiveOperationV2())

        let replay = try LegacyContinuityMigrator(repository: restartedRepository).migrate(
            candidateFiles: [handoffURL],
            expectedProjectGeneration: 7,
            boundRunID: runID
        )
        XCTAssertEqual(replay, receipt)
        XCTAssertEqual(try restartedRepository.continuityLegacyQuarantineCount(), 0)
        XCTAssertEqual(
            try restartedRepository.continuityMigrationReceiptCount(),
            receiptCountAfterMigration,
            "Replaying the same bound V2 source must not append a duplicate receipt"
        )
        let replayedImport = try XCTUnwrap(
            legacyImportSnapshot(
                databaseURL: restartedRepository.databaseURL,
                projectID: fixture.projectID,
                handoffID: handoff.handoffID
            )
        )
        XCTAssertEqual(replayedImport.contentSHA256, handoff.contentSHA256)
        XCTAssertEqual(replayedImport.projectGeneration, 7)
        XCTAssertEqual(replayedImport.runID, runID)
        XCTAssertEqual(try Data(contentsOf: handoffURL), legacySource)
    }

    func testExternalLifecycleRoutesRemainHandoffOnly() throws {
        for route in ["checkpoint", "prepare", "request"] {
            let fixture = try makeMemoryFixture(label: "external-\(route)")
            defer {
                fixture.memory.closeAll()
                try? FileManager.default.removeItem(at: fixture.root)
            }
            let service = ContinuityControlService(memory: fixture.memory)
            let arguments: [String: Any] = [
                "project_id": fixture.projectID,
                "predecessor_session_id": "external-predecessor",
                "mission": "Preserve external compatibility",
            ]
            let response: [String: Any]
            switch route {
            case "checkpoint":
                response = try service.checkpoint(arguments: arguments)
                XCTAssertEqual(response["request_route"] as? String, "checkpoint_only")
            case "prepare":
                response = try service.prepareHandoff(arguments: arguments)
                XCTAssertEqual(response["request_route"] as? String, "prepare_handoff")
            default:
                response = try service.requestRollover(arguments: arguments)
                XCTAssertEqual(response["request_route"] as? String, "external_handoff_only")
                XCTAssertEqual(response["external_capability"] as? String, "handoff_only")
                XCTAssertEqual(response["manager_operation_enqueued"] as? Bool, false)
            }
            XCTAssertEqual(response["session_creation_confirmed"] as? Bool, false)
        }
    }

    private func makeMemoryFixture(
        label: String,
        beforeContinuityProjectionWriteObserver: (@Sendable (String, String, String) -> Void)? = nil,
        didMutationCommitObserver: (@Sendable () -> Void)? = nil
    ) throws -> (
        root: URL,
        home: URL,
        projectID: String,
        memory: ProjectMemoryService
    ) {
        let root = temporaryRoot(label)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let paths = AppPaths(home: home)
        try paths.ensureLayout()
        let memory = ProjectMemoryService(
            paths: paths,
            clock: SystemClock(),
            limits: .current,
            afterIdentityMetadataWriteObserver: nil,
            didIdentityRegistryCommitObserver: nil,
            beforeContinuityProjectionWriteObserver: beforeContinuityProjectionWriteObserver,
            didMutationCommitObserver: didMutationCommitObserver
        )
        let initialized = try memory.initialize(path: project.path)
        return (
            root,
            home,
            try XCTUnwrap(initialized["project_id"] as? String),
            memory
        )
    }

    private func managedRolloverArguments(
        fixture: (root: URL, home: URL, projectID: String, memory: ProjectMemoryService),
        operationID: String
    ) -> [String: Any] {
        [
            "project_id": fixture.projectID,
            "project_generation": 1,
            "run_id": UUID().uuidString.lowercased(),
            "operation_id": operationID,
            "handoff_id": UUID().uuidString.lowercased(),
            "continuity_mode": ContinuityMode.managedAutonomous.rawValue,
            "predecessor_session_id": "managed-predecessor",
            "provider_id": "lmstudio-local",
            "provider_response_id": "response-predecessor",
            "adapter_id": "forge.native-session-host",
            "model": "fixture/tool-model",
            "mission": "Preserve the committed managed request outcome",
            "assignment_id": "FC-CONT-001",
            "phase_id": "FC-CONT-001",
            "work_item_id": "managed-bridge",
            "summary": "Persist handoff before the delayed enqueue",
            "repository_root": fixture.root.appendingPathComponent("project").path,
            "next_actions": ["Claim the queued rollover"],
            "context_capacity": 32_768,
            "context_used": 27_000,
            "context_reserved": 4_096,
            "context_remaining": 1_672,
            "context_confidence": 1.0,
            "context_action": "rollover",
            "context_trigger": "rollover threshold crossed",
            "context_budget_source": "provider_exact",
            "bootstrap_nonce": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            "idempotency_key": "managed-bridge-\(operationID)",
            "requested_by": "continuity.request_rollover",
            "reason": "bounded bridge timeout qualification",
        ]
    }

    private func assertV2PreparationRecovery(
        advanceToCheckpointPreparing: Bool
    ) throws {
        let label = advanceToCheckpointPreparing ? "checkpoint-preparing" : "active"
        let fixture = try makeMemoryFixture(label: "atomic-create-\(label)")
        defer {
            fixture.memory.closeAll()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let handoff = try makeHandoffV2(
            projectID: fixture.projectID,
            generation: 1,
            runID: UUID().uuidString.lowercased()
        )
        let repository = try fixture.memory.repositoryForProject(fixture.projectID)
        var operation = try repository.continuityCreateOperationV2(
            handoff: handoff,
            predecessorSessionID: "predecessor",
            predecessorProviderResponseID: "resp-predecessor",
            adapterID: "forge.native-session-host",
            idempotencyKey: "atomic-create-\(label)"
        )

        // This is the public commit boundary: observing the operation requires the
        // exact recovery handoff to be readable from the same SQLite transaction.
        XCTAssertEqual(operation.state, .active)
        XCTAssertEqual(
            try repository.continuityHandoffV2(id: operation.handoffID)?.contentSHA256,
            handoff.contentSHA256
        )
        if advanceToCheckpointPreparing {
            operation = try repository.continuityTransitionV2(
                operationID: operation.operationID,
                expected: .active,
                to: .checkpointPreparing,
                evidence: "crash_window_fixture"
            )
            XCTAssertEqual(operation.state, .checkpointPreparing)
        }

        fixture.memory.closeAll()
        let restartedMemory = ProjectMemoryService(paths: AppPaths(home: fixture.home))
        defer { restartedMemory.closeAll() }
        let restartedEngine = ContinuityStateEngine(memory: restartedMemory)
        let recovered = try restartedEngine.prepareV2(
            handoff: handoff,
            predecessorSessionID: "predecessor",
            predecessorProviderResponseID: "resp-predecessor",
            adapterID: "forge.native-session-host",
            idempotencyKey: "atomic-create-\(label)"
        )
        XCTAssertEqual(recovered.state, .checkpointPersisted)
        XCTAssertEqual(
            try restartedEngine.handoffV2(
                projectID: fixture.projectID,
                handoffID: handoff.handoffID
            )?.contentSHA256,
            handoff.contentSHA256
        )

        let replay = try restartedEngine.prepareV2(
            handoff: handoff,
            predecessorSessionID: "predecessor",
            predecessorProviderResponseID: "resp-predecessor",
            adapterID: "forge.native-session-host",
            idempotencyKey: "atomic-create-\(label)"
        )
        XCTAssertEqual(replay, recovered)
        XCTAssertEqual(
            try restartedMemory.repositoryForProject(fixture.projectID)
                .continuityTransitionCount(operationID: handoff.operationID),
            3
        )
    }

    private func makeHandoffV2(
        projectID: String,
        generation: Int,
        runID: String,
        mode: ContinuityMode = .externalMCPCompatibility
    ) throws -> ContinuityHandoffV2 {
        try ContinuityHandoffV2(
            operationID: UUID().uuidString.lowercased(),
            project: [
                "project_id": projectID,
                "generation": generation,
                "display_name": "Continuity Fixture",
                "repository_root": "/fixture",
                "branch": "repair/continuity",
                "commit": "1234567",
                "dirty_summary": [] as [String],
            ],
            run: [
                "run_id": runID,
                "continuity_mode": mode.rawValue,
                "assignment_id": "FC-CONT-001",
            ],
            predecessorSession: [
                "session_id": "predecessor",
                "provider_id": "lmstudio-local",
                "provider_response_id": "resp-predecessor",
                "adapter_id": "forge.native-session-host",
                "model": "fixture/tool-model",
            ],
            mission: "Continue the exact project run",
            constraints: ["Preserve verified work"],
            currentWork: [
                "phase_id": "FC-CONT-001",
                "work_item_id": "canonical-continuity",
                "summary": "Persist project-local continuity",
                "active_files": [] as [String],
            ],
            completedWork: [[
                "id": "identity",
                "summary": "Project identity was established",
                "status": "verified",
            ]],
            openWork: [[
                "id": "rollover",
                "summary": "Execute managed rollover",
                "status": "open",
            ]],
            decisions: [[
                "decision": "Global latest is not execution authority",
                "evidence": ["FC-CONT-001"],
            ]],
            validation: [
                "passed_gates": [] as [String],
                "open_gates": ["FC-CONT-001"],
                "commands": [] as [[String: Any]],
            ],
            memoryReferences: [],
            evidenceReferences: [],
            nextActions: [[
                "order": 0,
                "action": "Process the durable command",
                "command": "",
                "success_condition": "The command is claimed exactly once",
                "replay_class": "idempotent",
            ]],
            contextBudget: [
                "capacity": 32_768,
                "used": 27_000,
                "reserved": 4_096,
                "remaining": 1_672,
                "source": "provider_exact",
                "confidence": 1.0,
                "action": "rollover",
                "trigger": "rollover threshold crossed",
            ],
            bootstrap: [
                "nonce": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
                "acknowledgement_contract_version": 2,
            ]
        ).validated()
    }

    private func makeLegacyHandoff(
        projectID: String,
        handoffID: String = UUID().uuidString.lowercased(),
        mission: String = "Preserve legacy diagnostics"
    ) throws -> ContinuityHandoff {
        try ContinuityHandoff(
            handoffID: handoffID,
            operationID: UUID().uuidString.lowercased(),
            project: [
                "project_id": projectID,
                "display_name": "Legacy Fixture",
                "repository_root": "/legacy",
                "branch": "main",
                "commit": "1234567",
                "dirty_summary": [] as [String],
            ],
            predecessorSession: [
                "session_id": "legacy-predecessor",
                "provider_session_id": NSNull(),
                "model": NSNull(),
            ],
            mission: mission,
            currentWork: [
                "phase_id": "legacy",
                "work_item_id": "legacy",
                "summary": "Legacy handoff",
                "active_files": [] as [String],
            ],
            nextActions: [[
                "order": 1,
                "action": "Inspect only",
                "command": "",
                "success_condition": "No automatic bootstrap occurs",
            ]],
            hostState: [
                "adapter_id": "external-mcp",
                "continuity_state": "checkpointPersisted",
                "context_budget_source": "legacy",
                "retry": [:] as [String: Any],
            ]
        ).validated()
    }

    private func temporaryRoot(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "forge-continuity-v2-\(label)-\(UUID().uuidString)",
                isDirectory: true
            )
    }
}

private final class ManagedContinuityCall: @unchecked Sendable {
    private let lock = NSLock()
    private let service: ContinuityControlService
    private let arguments: [String: Any]
    private var storedResult: Result<[String: Any], Error>?

    init(service: ContinuityControlService, arguments: [String: Any]) {
        self.service = service
        self.arguments = arguments
    }

    var result: Result<[String: Any], Error>? {
        lock.lock()
        defer { lock.unlock() }
        return storedResult
    }

    func execute() {
        let result = Result {
            try service.requestRollover(arguments: arguments)
        }
        lock.lock()
        storedResult = result
        lock.unlock()
    }
}

private final class SQLiteWriteLock {
    private var database: OpaquePointer?
    private var isReleased = false

    init(databaseURL: URL) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK,
              let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) }
                ?? "unknown SQLite open error"
            if let database { sqlite3_close(database) }
            throw LegacyImportSnapshotError.sqlite(message)
        }
        do {
            try Self.execute(database, sql: "BEGIN IMMEDIATE;")
        } catch {
            sqlite3_close(database)
            self.database = nil
            throw error
        }
    }

    deinit {
        release()
    }

    func release() {
        guard !isReleased, let database else { return }
        _ = sqlite3_exec(database, "COMMIT;", nil, nil, nil)
        sqlite3_close(database)
        self.database = nil
        isReleased = true
    }

    private static func execute(_ database: OpaquePointer, sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw LegacyImportSnapshotError.sqlite(message)
        }
    }
}

private actor LegacyMigrationStartGate {
    private let participantCount: Int
    private var arrivalCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(participantCount: Int) {
        self.participantCount = participantCount
    }

    func wait() async {
        arrivalCount += 1
        if arrivalCount == participantCount {
            let pending = waiters
            waiters.removeAll(keepingCapacity: false)
            for waiter in pending { waiter.resume() }
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private final class ContinuityProjectionWriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private let blocked = DispatchSemaphore(value: 0)
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private var armed = false
    private var didBlock = false

    func arm() {
        lock.lock()
        armed = true
        lock.unlock()
    }

    func observe(kind: String) {
        lock.lock()
        guard armed, kind == "operation", !didBlock else {
            lock.unlock()
            return
        }
        didBlock = true
        lock.unlock()
        blocked.signal()
        _ = releaseSemaphore.wait(timeout: .now() + 3)
    }

    func waitUntilBlocked(timeout: TimeInterval) -> DispatchTimeoutResult {
        blocked.wait(timeout: .now() + timeout)
    }

    func release() {
        releaseSemaphore.signal()
    }
}

private final class ContinuityPostCommitGate: @unchecked Sendable {
    private let lock = NSLock()
    private let blocked = DispatchSemaphore(value: 0)
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private let targetCommit: Int
    private var armed = false
    private var commitCount = 0
    private var didBlock = false

    init(targetCommit: Int) {
        self.targetCommit = targetCommit
    }

    var observedCommitCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return commitCount
    }

    func arm() {
        lock.lock()
        armed = true
        commitCount = 0
        lock.unlock()
    }

    func observe() {
        lock.lock()
        guard armed, !didBlock else {
            lock.unlock()
            return
        }
        commitCount += 1
        guard commitCount == targetCommit else {
            lock.unlock()
            return
        }
        didBlock = true
        lock.unlock()
        blocked.signal()
        _ = releaseSemaphore.wait(timeout: .now() + 3)
    }

    func waitUntilBlocked(timeout: TimeInterval) -> DispatchTimeoutResult {
        blocked.wait(timeout: .now() + timeout)
    }

    func release() {
        releaseSemaphore.signal()
    }
}

private struct LegacyImportSnapshot {
    let schemaVersion: String
    let projectGeneration: Int?
    let runID: String?
    let predecessorProviderResponseID: String?
    let bootstrapNonce: String?
    let quarantineState: String?
    let migrationSource: String?
    let legacyRecordID: String?
    let contentSHA256: String
    let payloadJSON: String
}

private enum LegacyImportSnapshotError: Error {
    case sqlite(String)
}

private func executeLegacyMigrationSQL(at databaseURL: URL, sql: String) throws {
    var database: OpaquePointer?
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK,
          let database else {
        let message = database.map { String(cString: sqlite3_errmsg($0)) }
            ?? "unknown SQLite open error"
        if let database { sqlite3_close(database) }
        throw LegacyImportSnapshotError.sqlite(message)
    }
    defer { sqlite3_close(database) }
    sqlite3_busy_timeout(database, 3_000)
    var errorMessage: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
        let message = errorMessage.map { String(cString: $0) }
            ?? String(cString: sqlite3_errmsg(database))
        sqlite3_free(errorMessage)
        throw LegacyImportSnapshotError.sqlite(message)
    }
}

private func updateLegacyMigrationReceipt(
    at databaseURL: URL,
    receiptID: String,
    importedCount: Int,
    skippedCount: Int,
    quarantinedCount: Int,
    detailsJSON: String
) throws {
    var database: OpaquePointer?
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK,
          let database else {
        let message = database.map { String(cString: sqlite3_errmsg($0)) }
            ?? "unknown SQLite open error"
        if let database { sqlite3_close(database) }
        throw LegacyImportSnapshotError.sqlite(message)
    }
    defer { sqlite3_close(database) }
    sqlite3_busy_timeout(database, 3_000)
    var statement: OpaquePointer?
    let sql = """
    UPDATE continuity_migration_receipts
    SET imported_count=?,skipped_count=?,quarantined_count=?,details_json=?
    WHERE receipt_id=?;
    """
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else {
        throw LegacyImportSnapshotError.sqlite(String(cString: sqlite3_errmsg(database)))
    }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_int64(statement, 1, Int64(importedCount))
    sqlite3_bind_int64(statement, 2, Int64(skippedCount))
    sqlite3_bind_int64(statement, 3, Int64(quarantinedCount))
    bindLegacySnapshot(statement, index: 4, value: detailsJSON)
    bindLegacySnapshot(statement, index: 5, value: receiptID)
    guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(database) == 1 else {
        throw LegacyImportSnapshotError.sqlite(String(cString: sqlite3_errmsg(database)))
    }
}

private func legacyMigrationInt(
    at databaseURL: URL,
    sql: String,
    bindings: [String]
) throws -> Int {
    var database: OpaquePointer?
    let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK,
          let database else {
        let message = database.map { String(cString: sqlite3_errmsg($0)) }
            ?? "unknown SQLite open error"
        if let database { sqlite3_close(database) }
        throw LegacyImportSnapshotError.sqlite(message)
    }
    defer { sqlite3_close(database) }
    sqlite3_busy_timeout(database, 3_000)
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else {
        throw LegacyImportSnapshotError.sqlite(String(cString: sqlite3_errmsg(database)))
    }
    defer { sqlite3_finalize(statement) }
    for (offset, value) in bindings.enumerated() {
        bindLegacySnapshot(statement, index: Int32(offset + 1), value: value)
    }
    guard sqlite3_step(statement) == SQLITE_ROW else {
        throw LegacyImportSnapshotError.sqlite(String(cString: sqlite3_errmsg(database)))
    }
    return Int(sqlite3_column_int64(statement, 0))
}

private func legacyMigrationText(
    at databaseURL: URL,
    sql: String,
    bindings: [String]
) throws -> String? {
    var database: OpaquePointer?
    let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK,
          let database else {
        let message = database.map { String(cString: sqlite3_errmsg($0)) }
            ?? "unknown SQLite open error"
        if let database { sqlite3_close(database) }
        throw LegacyImportSnapshotError.sqlite(message)
    }
    defer { sqlite3_close(database) }
    sqlite3_busy_timeout(database, 3_000)
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else {
        throw LegacyImportSnapshotError.sqlite(String(cString: sqlite3_errmsg(database)))
    }
    defer { sqlite3_finalize(statement) }
    for (offset, value) in bindings.enumerated() {
        bindLegacySnapshot(statement, index: Int32(offset + 1), value: value)
    }
    guard sqlite3_step(statement) == SQLITE_ROW else {
        throw LegacyImportSnapshotError.sqlite(String(cString: sqlite3_errmsg(database)))
    }
    return legacySnapshotText(statement, index: 0)
}

private func legacyImportSnapshot(
    databaseURL: URL,
    projectID: String,
    handoffID: String
) throws -> LegacyImportSnapshot? {
    var database: OpaquePointer?
    let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK,
          let database else {
        let message = database.map { String(cString: sqlite3_errmsg($0)) }
            ?? "unknown SQLite open error"
        if let database { sqlite3_close(database) }
        throw LegacyImportSnapshotError.sqlite(message)
    }
    defer { sqlite3_close(database) }

    var statement: OpaquePointer?
    let sql = """
    SELECT schema_version,project_generation,run_id,predecessor_provider_response_id,
           bootstrap_nonce,quarantine_state,migration_source,legacy_record_id,
           content_sha256,payload_json
    FROM continuity_handoffs
    WHERE project_id=? AND handoff_id=?
    """
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else {
        throw LegacyImportSnapshotError.sqlite(String(cString: sqlite3_errmsg(database)))
    }
    defer { sqlite3_finalize(statement) }
    bindLegacySnapshot(statement, index: 1, value: projectID)
    bindLegacySnapshot(statement, index: 2, value: handoffID)
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    let generation = sqlite3_column_type(statement, 1) == SQLITE_NULL
        ? nil
        : Int(sqlite3_column_int64(statement, 1))
    return LegacyImportSnapshot(
        schemaVersion: legacySnapshotText(statement, index: 0) ?? "",
        projectGeneration: generation,
        runID: legacySnapshotText(statement, index: 2),
        predecessorProviderResponseID: legacySnapshotText(statement, index: 3),
        bootstrapNonce: legacySnapshotText(statement, index: 4),
        quarantineState: legacySnapshotText(statement, index: 5),
        migrationSource: legacySnapshotText(statement, index: 6),
        legacyRecordID: legacySnapshotText(statement, index: 7),
        contentSHA256: legacySnapshotText(statement, index: 8) ?? "",
        payloadJSON: legacySnapshotText(statement, index: 9) ?? ""
    )
}

private func bindLegacySnapshot(_ statement: OpaquePointer, index: Int32, value: String) {
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    value.withCString { pointer in
        _ = sqlite3_bind_text(statement, index, pointer, -1, transient)
    }
}

private func legacySnapshotText(_ statement: OpaquePointer, index: Int32) -> String? {
    sqlite3_column_text(statement, index).map { String(cString: $0) }
}

private func legacyJSONFiles(in directory: URL) throws -> [URL] {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
        return []
    }
    guard isDirectory.boolValue else {
        throw LegacyImportSnapshotError.sqlite("legacy quarantine projection path is not a directory")
    }
    return try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ).filter { url in
        url.pathExtension == "json"
            && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }.sorted { $0.path < $1.path }
}

private func jsonFileCount(in directory: URL) throws -> Int {
    try legacyJSONFiles(in: directory).count
}
