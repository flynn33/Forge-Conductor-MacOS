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

    private func makeMemoryFixture(label: String) throws -> (
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
        let memory = ProjectMemoryService(paths: paths)
        let initialized = try memory.initialize(path: project.path)
        return (
            root,
            home,
            try XCTUnwrap(initialized["project_id"] as? String),
            memory
        )
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

    private func makeLegacyHandoff(projectID: String) throws -> ContinuityHandoff {
        try ContinuityHandoff(
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
            mission: "Preserve legacy diagnostics",
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

private func jsonFileCount(in directory: URL) throws -> Int {
    try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ).filter { url in
        url.pathExtension == "json"
            && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }.count
}
