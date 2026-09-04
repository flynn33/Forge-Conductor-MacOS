// Opt-in real-provider acceptance coverage for manager-owned autonomous continuity.

import Foundation
import XCTest
#if canImport(AppKit)
import AppKit
#endif
#if SWIFT_PACKAGE
import ForgeNativeSessionHostPlugin
@testable import ForgeConductorCore

final class LiveLMStudioManagedAutonomyTests: XCTestCase {
    private static let successorMarker = "SUCCESSOR_ONLY_TOOL_EFFECT"
    private static let missionPaddingScalarCount = 4_620

    func testToolInvocationLookupByUUIDIsExactAndBounded() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "forge-tool-invocation-lookup-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: home) }

        let app = try ForgeApp.bootstrap(home: home)
        defer { _ = app.shutdown() }
        let projectRoot = home.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let initialized = try app.projectMemory.initializeUnchecked(path: projectRoot.path)
        let projectID = try ProjectID(XCTUnwrap(UUID(
            uuidString: try XCTUnwrap(initialized["project_id"] as? String)
        )))
        let project = try await app.projectContexts.repository.registerProjectUnchecked(
            projectID: projectID,
            displayName: "Exact Tool Invocation Lookup",
            canonicalRoot: projectRoot
        )
        let request = AutonomousRunRequest(
            projectID: project.projectID,
            projectGeneration: project.generation,
            mission: "Persist one exact tool invocation lookup fixture",
            providerID: "fixture-provider",
            adapterID: "fixture-adapter",
            modelKey: "fixture-model",
            specification: AutonomousRunSpecification(
                allowedTools: ["fs_read"],
                completionGates: ["fixture"]
            ),
            authorizationScope: ToolAuthorizationScope(
                canonicalRoots: [projectRoot],
                writableRoots: [],
                allowedTools: ["fs_read"],
                networkAllowed: false,
                maximumInlineOutputBytes: 64 * 1_024
            )
        )
        let run = try await app.projectContexts.repository.createAutonomousRun(request)
        let lease = try await app.projectContexts.repository.acquireRunLease(
            runID: run.runID,
            ownerID: "exact-tool-lookup"
        )
        let sessionID = "exact-tool-lookup-session"
        _ = try await app.projectContexts.repository.reserveProviderSession(
            ProviderSessionIntent(
                sessionID: sessionID,
                runID: run.runID,
                projectID: run.projectID,
                projectGeneration: run.projectGeneration,
                providerID: "fixture-provider",
                adapterID: "fixture-adapter",
                modelKey: "fixture-model",
                idempotencyKey: "exact-tool-lookup-session"
            ),
            lease: lease
        )
        let turn = ProviderTurnIntent(
            runID: run.runID,
            sessionID: sessionID,
            projectID: run.projectID,
            projectGeneration: run.projectGeneration,
            kind: .initialRoot,
            idempotencyKey: "exact-tool-lookup-turn",
            inputSHA256: JSONSupport.sha256Hex("lookup")
        )
        _ = try await app.projectContexts.repository.persistProviderTurnIntent(turn, lease: lease)
        let stored = try await app.projectContexts.repository.persistToolInvocationIntent(
            ToolInvocationIntent(
                turnID: turn.turnID,
                runID: run.runID,
                sessionID: sessionID,
                projectID: run.projectID,
                projectGeneration: run.projectGeneration,
                providerCallID: "exact-tool-lookup-call",
                toolName: "fs_read",
                replayClass: .readOnly,
                idempotencyKey: nil,
                argumentsSHA256: JSONSupport.sha256Hex("{}")
            ),
            lease: lease
        )

        let exactLookup = try await app.projectContexts.repository.toolInvocation(
            stored.invocationID
        )
        XCTAssertEqual(exactLookup, stored)
        let unknownLookup = try await app.projectContexts.repository.toolInvocation(UUID())
        XCTAssertNil(unknownLookup)
        _ = try await app.projectContexts.repository.releaseRunLease(lease)
    }

    func testRealProviderAutomaticThresholdRolloverRecoversAfterBootstrapCrashAndContinuesViaManagerRoute() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelKey = environment["FORGE_LIVE_LMSTUDIO_MODEL"], !modelKey.isEmpty else {
            throw XCTSkip("Set FORGE_LIVE_LMSTUDIO_MODEL to run the real-provider manager test")
        }
        guard let rawExpectedContextLength = environment[
            "FORGE_LIVE_LMSTUDIO_EXPECTED_CONTEXT_LENGTH"
        ], let expectedContextLength = Int(rawExpectedContextLength), expectedContextLength > 0 else {
            throw XCTSkip(
                "Set FORGE_LIVE_LMSTUDIO_EXPECTED_CONTEXT_LENGTH to the exact loaded instance context"
            )
        }
        let baseURL = try XCTUnwrap(URL(
            string: environment["FORGE_LIVE_LMSTUDIO_BASE_URL"]
                ?? "http://127.0.0.1:1234"
        ))
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "forge-live-manager-threshold-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: home) }

        let registry = HostAdapterRegistry()
        ForgeNativeSessionHostPlugin.register(in: registry)
        let runID = RunID()
        let mission = Self.thresholdMission()
        XCTAssertLessThanOrEqual(mission.utf8.count, 16_384)
        let ports = [
            Int.random(in: 31_000...36_000),
            Int.random(in: 37_000...42_000),
            Int.random(in: 43_000...48_000),
        ]
        let interrupted = try await executeInterruptedPhase(
            home: home,
            port: ports[0],
            baseURL: baseURL,
            modelKey: modelKey,
            registry: registry,
            runID: runID,
            mission: mission,
            expectedContextLength: expectedContextLength
        )
        let recovered = try await executeRecoveryPhase(
            home: home,
            port: ports[1],
            registry: registry,
            interrupted: interrupted
        )
        let replayed = try await executeStableReplayPhase(
            home: home,
            port: ports[2],
            registry: registry,
            interrupted: interrupted,
            recovered: recovered
        )

        let evidenceURL: URL
        if let path = environment["FORGE_LIVE_MANAGER_EVIDENCE"], !path.isEmpty {
            evidenceURL = URL(fileURLWithPath: path)
        } else {
            evidenceURL = FileManager.default.temporaryDirectory.appendingPathComponent(
                "forge-live-manager-threshold-evidence-\(runID.description).json"
            )
        }
        try writeEvidence(
            to: evidenceURL,
            modelKey: modelKey,
            mission: mission,
            interrupted: interrupted,
            recovered: recovered,
            replayed: replayed
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: evidenceURL.path))
        print("FORGE_LIVE_MANAGER_EVIDENCE=\(evidenceURL.path)")
    }

    private func executeInterruptedPhase(
        home: URL,
        port: Int,
        baseURL: URL,
        modelKey: String,
        registry: HostAdapterRegistry,
        runID: RunID,
        mission: String,
        expectedContextLength: Int
    ) async throws -> InterruptedPhase {
        let guiPIDs = forgeGUIProcessIDs()
        XCTAssertTrue(guiPIDs.isEmpty, "Forge Conductor GUI must be closed")
        let loadedProvider = try loadedProviderInstance(
            baseURL: baseURL,
            modelKey: modelKey
        )
        guard loadedProvider.contextLength == expectedContextLength else {
            throw LiveQualificationError.unexpectedProviderContext(
                expected: expectedContextLength,
                actual: loadedProvider.contextLength
            )
        }
        let app = try ForgeApp.bootstrap(home: home)
        try configureDashboard(port: port, app: app)
        try writeProviderConfiguration(baseURL: baseURL, modelKey: modelKey, paths: app.paths)
        let projectRoot = home.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        // The production manager requires an explicit root grant even for this
        // disposable continuity fixture; registration does not confer authority.
        try app.config.update(["allowed_roots": [projectRoot.path]], save: true)
        try Data("\(Self.successorMarker)\n".utf8).write(
            to: projectRoot.appendingPathComponent("successor-only.txt"),
            options: .atomic
        )

        let holder = LiveManagedRuntimeHolder()
        let node = ManagerNode(app: app) { candidate in
            let runtime = try ManagedAutonomyRuntime(
                app: candidate,
                registry: registry,
                managerID: "live-threshold-manager-before-restart",
                maximumConcurrentRuns: 1,
                continuityFactory: { _ in
                    ManagedContinuityWorker(
                        repository: candidate.projectContexts.repository,
                        memory: candidate.projectMemory,
                        adapterResolver: { adapterID in
                            let storage = candidate.paths.managedProvidersDir.appendingPathComponent(
                                adapterID,
                                isDirectory: true
                            )
                            let adapter = try registry.adapter(
                                identifier: adapterID,
                                storageDirectory: storage
                            )
                            guard let value = adapter as? any SessionHostAdapterV2 else {
                                throw ContinuityRunError.hostCapabilityUnavailable
                            }
                            return value
                        },
                        crashAfter: .providerBootstrapResponse
                    )
                }
            )
            holder.store(runtime)
            return runtime
        }
        defer {
            node.shutdownManagedAutonomy()
            _ = try? node.stopService()
            _ = app.shutdown()
        }

        let registered = try node.registerProject(
            path: projectRoot.path,
            displayName: "Live Automatic Threshold Continuity"
        )
        let projectID = try ProjectID(XCTUnwrap(UUID(
            uuidString: try XCTUnwrap(registered["project_id"] as? String)
        )))
        let generation = ProjectGeneration(try unsignedInteger(
            registered["project_generation"]
        ))
        let startupReport = try XCTUnwrap(try node.recoverManagedAutonomy())
        _ = try node.startService()
        try await Task.sleep(for: .milliseconds(100))
        let bearerToken = try ManagerControlCredentialStore(paths: app.paths).bearerToken()
        let endpoint = try XCTUnwrap(URL(
            string: "http://127.0.0.1:\(port)/api/manager/runs/start"
        ))
        let started = try postJSON(
            endpoint,
            object: [
                "run_id": runID.description,
                "project_id": projectID.description,
                "project_generation": generation.rawValue,
                "mission": mission,
                "provider_id": "lmstudio",
                "adapter_id": ForgeNativeSessionHostPlugin.identifier,
                "model_key": modelKey,
                "allowed_tools": ["fs_read"],
                "completion_gates": ["live_real_provider_threshold_continuity"],
                "network_allowed": false,
                "maximum_inline_output_bytes": 64 * 1_024,
            ],
            bearerToken: bearerToken,
            timeout: 30
        )
        guard started.status == 202 else {
            throw LiveQualificationError.managerRouteRejected(status: started.status,
                code: started.object["code"] as? String ?? "unreported")
        }
        XCTAssertEqual(started.object["run_id"] as? String, runID.description)
        let runtime = try XCTUnwrap(holder.load())
        let thresholdRun = try await driveUntilExactRollover(
            runtime: runtime,
            repository: app.projectContexts.repository,
            runID: runID,
            timeout: .seconds(1_500)
        )
        let predecessorSessionID = try XCTUnwrap(thresholdRun.activeSessionID)
        let predecessorResponseID = try XCTUnwrap(
            thresholdRun.specification.work.metadata["provider_response_id"]
        )
        let pendingValue = try await app.projectContexts.repository
            .pendingContextBudgetActionRequest(runID: runID)
        let pending = try XCTUnwrap(pendingValue)
        let observationValue = try await app.projectContexts.repository
            .contextBudgetObservation(observationID: pending.observationID)
        let observation = try XCTUnwrap(observationValue)
        let budgetStateValue = try await app.projectContexts.repository.contextBudgetState(
            identity: pending.identity
        )
        let budgetState = try XCTUnwrap(budgetStateValue)
        XCTAssertEqual(pending.requestedAction, .rollover)
        XCTAssertNil(pending.fulfilledAction)
        XCTAssertEqual(pending.observationID, observation.observationID)
        XCTAssertEqual(pending.actionEpoch, observation.actionEpoch)
        XCTAssertEqual(observation.identity, pending.identity)
        XCTAssertEqual(observation.identity.sessionID, predecessorSessionID)
        XCTAssertEqual(observation.providerResponseID, predecessorResponseID)
        XCTAssertEqual(observation.source, .providerExact)
        XCTAssertEqual(observation.confidence, 1)
        XCTAssertEqual(observation.triggerPoint, .afterProviderTurn)
        XCTAssertEqual(observation.action, .rollover)
        XCTAssertEqual(observation.capacity, expectedContextLength)
        XCTAssertLessThanOrEqual(observation.remaining, observation.thresholds.rollover)
        XCTAssertGreaterThan(observation.remaining, observation.thresholds.emergency)
        XCTAssertEqual(budgetState.latestObservation, observation)
        XCTAssertEqual(budgetState.lastRequestedAction, .rollover)
        XCTAssertEqual(
            budgetState.configuration.capacity.capacity,
            expectedContextLength
        )
        XCTAssertEqual(
            budgetState.configuration.capacity.activeInstanceID,
            loadedProvider.instanceID
        )

        let eventsBeforeContinuity = try await app.projectContexts.repository.autonomyEvents(
            runID: runID,
            limit: 1_000
        )
        XCTAssertTrue(eventsBeforeContinuity.allSatisfy {
            $0.eventType != "tool_invocation_intent_persisted"
        })
        let predecessorProviderTurnIntentCount = eventsBeforeContinuity.filter {
            $0.eventType == "provider_turn_intent_persisted"
        }.count
        XCTAssertGreaterThan(predecessorProviderTurnIntentCount, 1)
        var predecessorTurns: [ProviderTurnRecord] = []
        for event in eventsBeforeContinuity
        where event.eventType == "provider_turn_intent_persisted" {
            let metadata = try JSONSupport.object(from: Data(event.metadataJSON.utf8))
            let turnID = try XCTUnwrap(UUID(
                uuidString: try XCTUnwrap(metadata["turn_id"] as? String)
            ))
            let turnValue = try await app.projectContexts.repository.providerTurn(turnID)
            let turn = try XCTUnwrap(turnValue)
            XCTAssertEqual(turn.state, .completed)
            XCTAssertNotNil(turn.providerResponseID)
            let usage = try providerUsageObject(turn)
            XCTAssertEqual(usage["source"] as? String, ContextBudgetUsageSource.providerExact.rawValue)
            XCTAssertEqual(usage["capacity"] as? Int, expectedContextLength)
            predecessorTurns.append(turn)
        }
        XCTAssertEqual(predecessorTurns.count, predecessorProviderTurnIntentCount)
        try await runtime.tick()
        let interruptedRun = try await waitForQuiescentRun(
            runtime: runtime,
            repository: app.projectContexts.repository,
            runID: runID,
            timeout: .seconds(300)
        ) { run in
            run.state == .waitingProvider
                && run.specification.work.pendingIntent?.kind == .continuity
        }
        XCTAssertEqual(interruptedRun.activeSessionID, predecessorSessionID)

        let operationID = pending.continuityOperationID
        let memoryRepository = try app.projectMemory.repositoryForProject(projectID.description)
        let operation = try XCTUnwrap(memoryRepository.continuityOperationV2(
            id: operationID.uuidString.lowercased()
        ))
        XCTAssertEqual(operation.state, .successorRequested)
        XCTAssertEqual(operation.predecessorSessionID, predecessorSessionID)
        let engine = ContinuityStateEngine(memory: app.projectMemory)
        let handoff = try XCTUnwrap(engine.handoffV2(
            projectID: projectID.description,
            handoffID: operation.handoffID
        ))
        let providerStorage = app.paths.managedProvidersDir.appendingPathComponent(
            ForgeNativeSessionHostPlugin.identifier,
            isDirectory: true
        )
        let receiptAdapter = try XCTUnwrap(
            try registry.adapter(
                identifier: ForgeNativeSessionHostPlugin.identifier,
                storageDirectory: providerStorage
            ) as? any SessionHostAdapterV2
        )
        let receiptValue = try await receiptAdapter.receipt(
            forIdempotencyKey: operation.idempotencyKey
        )
        let receipt = try XCTUnwrap(receiptValue)
        try receipt.acknowledgement.validate(handoff: handoff)
        XCTAssertEqual(receipt.acknowledgement.operationID, operationID)
        XCTAssertEqual(receipt.acknowledgement.projectID, projectID)
        XCTAssertEqual(receipt.acknowledgement.projectGeneration, generation)
        XCTAssertEqual(receipt.acknowledgement.runID, runID)
        XCTAssertNotEqual(receipt.providerResponseID, predecessorResponseID)

        let predecessorAtCrashValue = try await app.projectContexts.repository.providerSession(
            predecessorSessionID
        )
        let predecessorAtCrash = try XCTUnwrap(predecessorAtCrashValue)
        XCTAssertEqual(predecessorAtCrash.status, .fencing)
        XCTAssertFalse(predecessorAtCrash.accepted)
        let predecessorAuthority = await invocationAuthority(
            repository: app.projectContexts.repository,
            sessionID: predecessorSessionID
        )
        XCTAssertEqual(predecessorAuthority, "denied")
        let sessionsAtCrash = try await app.projectContexts.repository.providerSessions(
            operationID: operationID,
            limit: 32
        )
        XCTAssertTrue(sessionsAtCrash.isEmpty)
        let crashEvents = try await app.projectContexts.repository.autonomyEvents(
            runID: runID,
            limit: 1_000
        )
        let fenceEvent = try exactEvent("continuity_predecessor_fencing", events: crashEvents)

        node.shutdownManagedAutonomy()
        _ = try node.stopService()
        XCTAssertTrue(app.shutdown().completed)
        return InterruptedPhase(
            projectID: projectID,
            projectGeneration: generation,
            runID: runID,
            managerRouteStatus: started.status,
            managerRouteRunID: started.object["run_id"] as? String,
            startupReport: startupReport,
            guiPIDs: guiPIDs,
            managerNodeHostPID: Int(ProcessInfo.processInfo.processIdentifier),
            loadedProvider: loadedProvider,
            thresholdRun: thresholdRun,
            actionRequestAtThreshold: pending,
            observation: observation,
            budgetState: budgetState,
            predecessorSessionID: predecessorSessionID,
            predecessorResponseID: predecessorResponseID,
            predecessorAtCrash: predecessorAtCrash,
            predecessorAuthorityAtCrash: predecessorAuthority,
            operation: operation,
            handoff: handoff,
            receipt: receipt,
            persistedSuccessorCountAtCrash: sessionsAtCrash.count,
            predecessorFenceEventSequence: fenceEvent.sequence,
            predecessorProviderTurnIntentCount: predecessorProviderTurnIntentCount,
            predecessorTurns: predecessorTurns
        )
    }

    private func executeRecoveryPhase(
        home: URL,
        port: Int,
        registry: HostAdapterRegistry,
        interrupted: InterruptedPhase
    ) async throws -> RecoveredPhase {
        let guiPIDs = forgeGUIProcessIDs()
        XCTAssertTrue(guiPIDs.isEmpty, "Forge Conductor GUI must remain closed during recovery")
        let app = try ForgeApp.bootstrap(home: home)
        try configureDashboard(port: port, app: app)
        let holder = LiveManagedRuntimeHolder()
        let node = ManagerNode(app: app) { candidate in
            let runtime = try ManagedAutonomyRuntime(
                app: candidate,
                registry: registry,
                managerID: "live-threshold-manager-after-restart",
                maximumConcurrentRuns: 1
            )
            holder.store(runtime)
            return runtime
        }
        defer {
            node.shutdownManagedAutonomy()
            _ = try? node.stopService()
            _ = app.shutdown()
        }
        let startupReport = try XCTUnwrap(try node.recoverManagedAutonomy())
        _ = try node.startService()
        try await Task.sleep(for: .milliseconds(100))
        let runtime = try XCTUnwrap(holder.load())
        let operationID = interrupted.actionRequestAtThreshold.continuityOperationID
        let resumed = try await driveUntilAutomaticToolEvidence(
            runtime: runtime,
            repository: app.projectContexts.repository,
            runID: interrupted.runID,
            operationID: operationID,
            timeout: .seconds(900)
        )
        let successorSessionID = try XCTUnwrap(resumed.activeSessionID)
        XCTAssertNotEqual(successorSessionID, interrupted.predecessorSessionID)
        let predecessorValue = try await app.projectContexts.repository.providerSession(
            interrupted.predecessorSessionID
        )
        let predecessor = try XCTUnwrap(predecessorValue)
        XCTAssertEqual(predecessor.status, .sealed)
        XCTAssertFalse(predecessor.accepted)
        let successorValue = try await app.projectContexts.repository.providerSession(
            successorSessionID
        )
        let successor = try XCTUnwrap(successorValue)
        XCTAssertEqual(successor.status, .active)
        XCTAssertTrue(successor.accepted)
        XCTAssertEqual(successor.operationID, operationID)
        XCTAssertEqual(successor.providerResponseID, interrupted.receipt.providerResponseID)
        XCTAssertEqual(successor.handoffID, interrupted.receipt.acknowledgement.handoffID)
        XCTAssertEqual(
            successor.handoffSHA256,
            interrupted.receipt.acknowledgement.handoffSHA256
        )
        let sessions = try await app.projectContexts.repository.providerSessions(
            operationID: operationID,
            limit: 32
        )
        let acceptedSessions = sessions.filter { $0.status == .active && $0.accepted }
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(acceptedSessions.count, 1)
        XCTAssertEqual(acceptedSessions.first?.sessionID, successorSessionID)

        let predecessorAuthority = await invocationAuthority(
            repository: app.projectContexts.repository,
            sessionID: interrupted.predecessorSessionID
        )
        let successorAuthority = await invocationAuthority(
            repository: app.projectContexts.repository,
            sessionID: successorSessionID
        )
        XCTAssertEqual(predecessorAuthority, "denied")
        XCTAssertEqual(successorAuthority, "granted")

        let automaticValue = try await app.projectContexts.repository.automaticContinuation(
            operationID: operationID
        )
        let automatic = try XCTUnwrap(automaticValue)
        XCTAssertEqual(automatic.intent.kind, .automaticContinuation)
        XCTAssertEqual(automatic.state, .completed)
        XCTAssertEqual(automatic.intent.operationID, operationID)
        XCTAssertEqual(automatic.intent.sessionID, successorSessionID)
        XCTAssertEqual(
            automatic.intent.previousResponseID,
            interrupted.receipt.providerResponseID
        )
        XCTAssertEqual(
            automatic.intent.inputSHA256,
            JSONSupport.sha256Hex(try ManagedContinuityWorker.automaticContinuationInput())
        )
        XCTAssertNotNil(automatic.providerResponseID)
        XCTAssertFalse(resumed.continuationPending)

        let finalOperation = try XCTUnwrap(
            try app.projectMemory.repositoryForProject(interrupted.projectID.description)
                .continuityOperationV2(id: operationID.uuidString.lowercased())
        )
        XCTAssertEqual(finalOperation.state, .predecessorSealed)
        XCTAssertEqual(finalOperation.successorSessionID, successorSessionID)
        XCTAssertEqual(
            finalOperation.successorProviderResponseID,
            interrupted.receipt.providerResponseID
        )
        XCTAssertEqual(finalOperation.acknowledgedSessionID, interrupted.receipt.internalSessionID)
        XCTAssertEqual(
            finalOperation.acknowledgedHandoffID,
            interrupted.receipt.acknowledgement.handoffID.uuidString.lowercased()
        )

        let events = try await app.projectContexts.repository.autonomyEvents(
            runID: interrupted.runID,
            limit: 1_000
        )
        let fenceEvent = try exactEvent("continuity_predecessor_fencing", events: events)
        let acceptedEvent = try exactEvent("continuity_successor_accepted", events: events)
        let toolEvents = events.filter { $0.eventType == "tool_invocation_intent_persisted" }
        XCTAssertEqual(toolEvents.count, 1)
        let toolEvent = try XCTUnwrap(toolEvents.first)
        XCTAssertLessThan(fenceEvent.sequence, acceptedEvent.sequence)
        XCTAssertLessThan(acceptedEvent.sequence, toolEvent.sequence)
        XCTAssertEqual(fenceEvent.sequence, interrupted.predecessorFenceEventSequence)
        let toolMetadata = try JSONSupport.object(from: Data(toolEvent.metadataJSON.utf8))
        XCTAssertEqual(toolMetadata["tool_name"] as? String, "fs_read")
        let invocationID = try XCTUnwrap(UUID(
            uuidString: try XCTUnwrap(toolMetadata["invocation_id"] as? String)
        ))
        let toolValue = try await app.projectContexts.repository.toolInvocation(invocationID)
        let tool = try XCTUnwrap(toolValue)
        XCTAssertEqual(tool.invocationID, invocationID)
        XCTAssertEqual(tool.runID, interrupted.runID)
        XCTAssertEqual(tool.sessionID, successorSessionID)
        XCTAssertEqual(tool.turnID, automatic.intent.turnID)
        XCTAssertEqual(tool.toolName, "fs_read")
        XCTAssertEqual(tool.replayClass, .readOnly)
        XCTAssertEqual(tool.state, .completed)
        XCTAssertNotNil(tool.resultSHA256)
        XCTAssertTrue(tool.resultSummary?.contains(Self.successorMarker) == true)

        let actionRequestValue = try await app.projectContexts.repository
            .contextBudgetActionRequest(
                requestID: interrupted.actionRequestAtThreshold.requestID
            )
        let actionRequest = try XCTUnwrap(actionRequestValue)
        XCTAssertEqual(actionRequest.fulfilledAction, .rollover)

        let bearerToken = try ManagerControlCredentialStore(paths: app.paths).bearerToken()
        let controlEndpoint = try XCTUnwrap(URL(
            string: "http://127.0.0.1:\(port)/api/manager/runs/control"
        ))
        let paused = try postJSON(
            controlEndpoint,
            object: [
                "run_id": interrupted.runID.description,
                "action": ManagedAutonomyControlAction.pause.rawValue,
            ],
            bearerToken: bearerToken,
            timeout: 30
        )
        XCTAssertEqual(paused.status, 200)
        XCTAssertEqual(paused.object["state"] as? String, AutonomousRunState.paused.rawValue)
        let pausedRunValue = try await app.projectContexts.repository.autonomousRun(
            interrupted.runID
        )
        let pausedRun = try XCTUnwrap(pausedRunValue)
        XCTAssertEqual(pausedRun.state, .paused)

        node.shutdownManagedAutonomy()
        _ = try node.stopService()
        XCTAssertTrue(app.shutdown().completed)
        return RecoveredPhase(
            startupReport: startupReport,
            guiPIDs: guiPIDs,
            managerNodeHostPID: Int(ProcessInfo.processInfo.processIdentifier),
            run: pausedRun,
            operation: finalOperation,
            predecessor: predecessor,
            successor: successor,
            sessions: sessions,
            automatic: automatic,
            tool: tool,
            predecessorAuthority: predecessorAuthority,
            successorAuthority: successorAuthority,
            predecessorFenceEventSequence: fenceEvent.sequence,
            successorAcceptedEventSequence: acceptedEvent.sequence,
            toolIntentEventSequence: toolEvent.sequence,
            actionRequest: actionRequest,
            pauseRouteStatus: paused.status,
            pauseRouteState: paused.object["state"] as? String
        )
    }

    private func executeStableReplayPhase(
        home: URL,
        port: Int,
        registry: HostAdapterRegistry,
        interrupted: InterruptedPhase,
        recovered: RecoveredPhase
    ) async throws -> ReplayedPhase {
        let guiPIDs = forgeGUIProcessIDs()
        XCTAssertTrue(guiPIDs.isEmpty, "Forge Conductor GUI must remain closed during replay")
        let app = try ForgeApp.bootstrap(home: home)
        try configureDashboard(port: port, app: app)
        let holder = LiveManagedRuntimeHolder()
        let node = ManagerNode(app: app) { candidate in
            let runtime = try ManagedAutonomyRuntime(
                app: candidate,
                registry: registry,
                managerID: "live-threshold-manager-stable-replay",
                maximumConcurrentRuns: 1
            )
            holder.store(runtime)
            return runtime
        }
        defer {
            node.shutdownManagedAutonomy()
            _ = try? node.stopService()
            _ = app.shutdown()
        }
        let startupReport = try XCTUnwrap(try node.recoverManagedAutonomy())
        _ = try node.startService()
        let runtime = try XCTUnwrap(holder.load())
        try await runtime.tick()
        try await Task.sleep(for: .milliseconds(500))
        let snapshot = await runtime.snapshot()
        XCTAssertFalse(snapshot.supervisor.activeRunIDs.contains(interrupted.runID))

        let runValue = try await app.projectContexts.repository.autonomousRun(interrupted.runID)
        let run = try XCTUnwrap(runValue)
        XCTAssertEqual(run.state, .paused)
        let operationID = interrupted.actionRequestAtThreshold.continuityOperationID
        let operation = try XCTUnwrap(
            try app.projectMemory.repositoryForProject(interrupted.projectID.description)
                .continuityOperationV2(id: operationID.uuidString.lowercased())
        )
        XCTAssertEqual(operation, recovered.operation)
        let automaticValue = try await app.projectContexts.repository.automaticContinuation(
            operationID: operationID
        )
        let automatic = try XCTUnwrap(automaticValue)
        XCTAssertEqual(automatic, recovered.automatic)
        let toolValue = try await app.projectContexts.repository.toolInvocation(
            recovered.tool.invocationID
        )
        let tool = try XCTUnwrap(toolValue)
        XCTAssertEqual(tool, recovered.tool)
        let sessions = try await app.projectContexts.repository.providerSessions(
            operationID: operationID,
            limit: 32
        )
        XCTAssertEqual(sessions, recovered.sessions)
        XCTAssertEqual(sessions.filter { $0.status == .active && $0.accepted }.count, 1)
        let events = try await app.projectContexts.repository.autonomyEvents(
            runID: interrupted.runID,
            limit: 1_000
        )
        let toolEvents = events.filter { $0.eventType == "tool_invocation_intent_persisted" }
        XCTAssertEqual(toolEvents.count, 1)
        XCTAssertEqual(toolEvents.first?.sequence, recovered.toolIntentEventSequence)

        let providerStorage = app.paths.managedProvidersDir.appendingPathComponent(
            ForgeNativeSessionHostPlugin.identifier,
            isDirectory: true
        )
        let adapter = try XCTUnwrap(
            try registry.adapter(
                identifier: ForgeNativeSessionHostPlugin.identifier,
                storageDirectory: providerStorage
            ) as? any SessionHostAdapterV2
        )
        let receiptValue = try await adapter.receipt(
            forIdempotencyKey: interrupted.operation.idempotencyKey
        )
        let receipt = try XCTUnwrap(receiptValue)
        XCTAssertEqual(receipt, interrupted.receipt)

        node.shutdownManagedAutonomy()
        _ = try node.stopService()
        XCTAssertTrue(app.shutdown().completed)
        return ReplayedPhase(
            startupReport: startupReport,
            guiPIDs: guiPIDs,
            managerNodeHostPID: Int(ProcessInfo.processInfo.processIdentifier),
            run: run,
            operation: operation,
            automatic: automatic,
            tool: tool,
            sessions: sessions,
            receipt: receipt,
            toolIntentEventCount: toolEvents.count,
            activeRunCountAfterTick: snapshot.supervisor.activeRunIDs.count
        )
    }

    private func driveUntilExactRollover(
        runtime: ManagedAutonomyRuntime,
        repository: ProjectControlPlaneRepository,
        runID: RunID,
        timeout: Duration
    ) async throws -> AutonomousRunRecord {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var activations = 0
        while clock.now < deadline {
            guard let run = try await repository.autonomousRun(runID) else {
                try await Task.sleep(for: .milliseconds(50))
                continue
            }
            let events = try await repository.autonomyEvents(runID: runID, limit: 1_000)
            if let predecessorTool = events.first(where: {
                $0.eventType == "tool_invocation_intent_persisted"
            }) {
                throw LiveQualificationError.predecessorToolInvocation(
                    sequence: predecessorTool.sequence
                )
            }
            let snapshot = await runtime.snapshot()
            if !snapshot.supervisor.activeRunIDs.contains(runID) {
                switch run.state {
                case .rollingOver:
                    let pending = try await repository.pendingContextBudgetActionRequest(
                        runID: runID
                    )
                    let observation: ContextBudgetObservation? = if let pending {
                        try await repository.contextBudgetObservation(
                            observationID: pending.observationID
                        )
                    } else {
                        nil
                    }
                    guard pending?.requestedAction == .rollover,
                          observation?.source == .providerExact,
                          observation?.triggerPoint == .afterProviderTurn,
                          observation?.action == .rollover else {
                        throw LiveQualificationError.unexpectedThreshold(
                            action: observation?.action.rawValue ?? "missing",
                            source: observation?.source.rawValue ?? "missing",
                            used: observation?.used,
                            remaining: observation?.remaining
                        )
                    }
                    return run
                case .running, .checkpointing, .recovering:
                    activations += 1
                    guard activations <= 16 else {
                        throw LiveQualificationError.activationLimitExceeded
                    }
                    try await runtime.tick()
                case .waitingProvider, .waitingResource, .retryWait, .failedRecoverable,
                     .blockedConfiguration, .validatingCompletion, .completed, .cancelRequested,
                     .cancelled, .failedTerminal, .paused:
                    throw LiveQualificationError.unexpectedRunState(run.state)
                case .created, .validating, .ready, .starting:
                    break
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let final = try await repository.autonomousRun(runID)
        throw LiveQualificationError.timeout(
            "automatic threshold rollover; final state \(final?.state.rawValue ?? "missing")"
        )
    }

    private func driveUntilAutomaticToolEvidence(
        runtime: ManagedAutonomyRuntime,
        repository: ProjectControlPlaneRepository,
        runID: RunID,
        operationID: UUID,
        timeout: Duration
    ) async throws -> AutonomousRunRecord {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var activations = 0
        while clock.now < deadline {
            let run = try await repository.autonomousRun(runID)
            let automatic = try await repository.automaticContinuation(operationID: operationID)
            let events = try await repository.autonomyEvents(runID: runID, limit: 1_000)
            let toolEvents = events.filter { $0.eventType == "tool_invocation_intent_persisted" }
            let snapshot = await runtime.snapshot()
            if let run,
               automatic?.state == .completed,
               !toolEvents.isEmpty,
               !snapshot.supervisor.activeRunIDs.contains(runID) {
                return run
            }
            if let run, !snapshot.supervisor.activeRunIDs.contains(runID) {
                switch run.state {
                case .waitingProvider, .waitingResource, .retryWait, .failedRecoverable,
                     .recovering, .running, .checkpointing, .rollingOver:
                    activations += 1
                    guard activations <= 16 else {
                        throw LiveQualificationError.activationLimitExceeded
                    }
                    try await runtime.tick()
                case .created, .validating, .ready, .starting:
                    break
                case .blockedConfiguration, .validatingCompletion, .completed, .cancelRequested,
                     .cancelled, .failedTerminal, .paused:
                    throw LiveQualificationError.unexpectedRunState(run.state)
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let final = try await repository.autonomousRun(runID)
        throw LiveQualificationError.timeout(
            "automatic successor continuation; final state \(final?.state.rawValue ?? "missing")"
        )
    }

    private func waitForQuiescentRun(
        runtime: ManagedAutonomyRuntime,
        repository: ProjectControlPlaneRepository,
        runID: RunID,
        timeout: Duration,
        predicate: (AutonomousRunRecord) -> Bool
    ) async throws -> AutonomousRunRecord {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let run = try await repository.autonomousRun(runID), predicate(run) {
                let snapshot = await runtime.snapshot()
                if !snapshot.supervisor.activeRunIDs.contains(runID) { return run }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let final = try await repository.autonomousRun(runID)
        throw LiveQualificationError.timeout(
            "quiescent run predicate; final state \(final?.state.rawValue ?? "missing")"
        )
    }

    private func invocationAuthority(
        repository: ProjectControlPlaneRepository,
        sessionID: String
    ) async -> String {
        do {
            _ = try await repository.invocationContext(
                for: ProjectBindingOwner(kind: .providerSession, id: sessionID)
            )
            return "granted"
        } catch {
            return "denied"
        }
    }

    private func exactEvent(_ eventType: String, events: [AutonomyEvent]) throws -> AutonomyEvent {
        let matches = events.filter { $0.eventType == eventType }
        XCTAssertEqual(matches.count, 1, "Expected exactly one \(eventType) event")
        return try XCTUnwrap(matches.first)
    }

    private func configureDashboard(port: Int, app: ForgeApp) throws {
        try app.config.update([
            "dashboard": ["host": "127.0.0.1", "port": port] as [String: Any],
        ], save: true)
    }

    private func writeProviderConfiguration(
        baseURL: URL,
        modelKey: String,
        paths: AppPaths
    ) throws {
        let directory = paths.managedProvidersDir.appendingPathComponent(
            ForgeNativeSessionHostPlugin.identifier,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let configuration = LMStudioProviderConfiguration(
            baseURL: baseURL,
            modelKey: modelKey,
            connectTimeoutSeconds: 5,
            firstByteTimeoutSeconds: 120,
            idleTimeoutSeconds: 600,
            totalTimeoutSeconds: 600,
            maximumOutputTokens: 512
        )
        let data = try JSONEncoder().encode(configuration)
        let url = directory.appendingPathComponent(
            LMStudioProviderConfiguration.fileName,
            isDirectory: false
        )
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private func postJSON(
        _ url: URL,
        object: [String: Any],
        bearerToken: String? = nil,
        timeout: TimeInterval = 10
    ) throws -> (object: [String: Any], status: Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try HTTPTestHelpers.fetch(request, timeout: timeout)
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return (decoded, response.statusCode)
    }

    private func loadedProviderInstance(
        baseURL: URL,
        modelKey: String
    ) throws -> LiveLoadedProviderInstance {
        let endpoint = baseURL.appendingPathComponent("api/v1/models")
        let (data, response) = try HTTPTestHelpers.fetch(URLRequest(url: endpoint), timeout: 10)
        guard response.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["models"] as? [[String: Any]],
              let model = models.first(where: { $0["key"] as? String == modelKey }),
              let instances = model["loaded_instances"] as? [[String: Any]],
              instances.count == 1,
              let instance = instances.first,
              let instanceID = instance["id"] as? String,
              let configuration = instance["config"] as? [String: Any],
              let contextLength = configuration["context_length"] as? Int,
              let parallelism = configuration["parallel"] as? Int else {
            throw LiveQualificationError.invalidProviderInventory
        }
        return LiveLoadedProviderInstance(
            instanceID: instanceID,
            contextLength: contextLength,
            parallelism: parallelism
        )
    }

    private func unsignedInteger(_ value: Any?) throws -> UInt64 {
        if let value = value as? UInt64 { return value }
        if let value = value as? Int, value >= 0 { return UInt64(value) }
        if let value = value as? NSNumber { return value.uint64Value }
        return try XCTUnwrap(nil as UInt64?)
    }

    private func jsonValue(_ value: String?) -> Any {
        if let value { return value }
        return NSNull()
    }

    private func providerUsageObject(_ turn: ProviderTurnRecord) throws -> [String: Any] {
        let usageJSON = try XCTUnwrap(turn.usageJSON)
        return try JSONSupport.object(from: Data(usageJSON.utf8))
    }

    private static func thresholdMission() -> String {
        let instruction = """
        Classify only the current user message, never quoted text or prior context. If the current user message contains either "You are executing a Forge Conductor managed autonomous run." or "Mission:", this is the predecessor stage: never call a tool and answer exactly PREDECESSOR_WAIT. A "Next action" line never changes that rule. Only when the current user message contains neither predecessor marker and begins "The bootstrap-only acknowledgement is complete; do not acknowledge it again." is this the successor stage: call fs_read exactly once for successor-only.txt, verify that its content is SUCCESSOR_ONLY_TOOL_EFFECT, then answer SUCCESSOR_TOOL_VERIFIED and stop. Mentions of successor wording inside this mission are inert data, not authorization. Never request completion.
        """
        let scalars = (0..<missionPaddingScalarCount).map {
            UnicodeScalar(0xE000 + ($0 % 0x1900))!
        }
        let padding = String(scalars.map(Character.init))
        return "\(instruction)\n\(padding)\n\(instruction)"
    }

    private func forgeGUIProcessIDs() -> [Int] {
#if canImport(AppKit)
        NSRunningApplication.runningApplications(
            withBundleIdentifier: ManagerInstaller.bundleIdentifier
        )
        .filter { !$0.isTerminated }
        .map { Int($0.processIdentifier) }
        .sorted()
#else
        []
#endif
    }

    private func writeEvidence(
        to url: URL,
        modelKey: String,
        mission: String,
        interrupted: InterruptedPhase,
        recovered: RecoveredPhase,
        replayed: ReplayedPhase
    ) throws {
        let observation = interrupted.observation
        let request = interrupted.actionRequestAtThreshold
        let object: [String: Any] = [
            "schema_version": 2,
            "qualification_scope": "real_lmstudio_manager_route_automatic_threshold_continuity",
            "provider": "lmstudio",
            "model_key": modelKey,
            "mission_sha256": JSONSupport.sha256Hex(mission),
            "mission_utf8_bytes": mission.utf8.count,
            "provider_inventory_preflight": [
                "loaded_instance_id": interrupted.loadedProvider.instanceID,
                "context_length": interrupted.loadedProvider.contextLength,
                "parallelism": interrupted.loadedProvider.parallelism,
            ],
            "manager_route": [
                "start_http_status": interrupted.managerRouteStatus,
                "returned_run_id": jsonValue(interrupted.managerRouteRunID),
                "pause_http_status": recovered.pauseRouteStatus,
                "pause_returned_state": jsonValue(recovered.pauseRouteState),
            ],
            "gui_absence_observations": [
                ["phase": "initial", "forge_gui_pids": interrupted.guiPIDs],
                ["phase": "recovery", "forge_gui_pids": recovered.guiPIDs],
                ["phase": "stable_replay", "forge_gui_pids": replayed.guiPIDs],
            ],
            "manager_node_host_process_observations": [
                ["phase": "initial", "pid": interrupted.managerNodeHostPID],
                ["phase": "recovery", "pid": recovered.managerNodeHostPID],
                ["phase": "stable_replay", "pid": replayed.managerNodeHostPID],
            ],
            "predecessor_provider_turns": try interrupted.predecessorTurns.map { turn in
                [
                    "turn_id": turn.intent.turnID.uuidString.lowercased(),
                    "request_kind": turn.intent.kind.rawValue,
                    "state": turn.state.rawValue,
                    "attempt": turn.attempt,
                    "session_id": turn.intent.sessionID,
                    "previous_response_id": jsonValue(turn.intent.previousResponseID),
                    "provider_request_id": jsonValue(turn.providerRequestID),
                    "provider_response_id": jsonValue(turn.providerResponseID),
                    "input_sha256": turn.intent.inputSHA256,
                    "usage": try providerUsageObject(turn),
                ] as [String: Any]
            },
            "identity": [
                "run_id": interrupted.runID.description,
                "project_id": interrupted.projectID.description,
                "project_generation": interrupted.projectGeneration.rawValue,
                "operation_id": request.continuityOperationID.uuidString.lowercased(),
                "handoff_id": interrupted.handoff.handoffID,
                "handoff_sha256": interrupted.handoff.contentSHA256,
            ],
            "threshold_observation": [
                "observation_id": observation.observationID.uuidString.lowercased(),
                "request_id": request.requestID.uuidString.lowercased(),
                "action_epoch": observation.actionEpoch,
                "provider_response_id": jsonValue(observation.providerResponseID),
                "capacity": observation.capacity,
                "used": observation.used,
                "fixed_reserve": observation.fixedReserve,
                "remaining": observation.remaining,
                "projected_next_turn": observation.projectedNextTurn,
                "source": observation.source.rawValue,
                "confidence": observation.confidence,
                "trigger_point": observation.triggerPoint.rawValue,
                "action": observation.action.rawValue,
                "checkpoint_threshold": observation.thresholds.checkpoint,
                "rollover_threshold": observation.thresholds.rollover,
                "emergency_threshold": observation.thresholds.emergency,
                "requested_action": request.requestedAction.rawValue,
                "fulfilled_action_at_threshold": jsonValue(request.fulfilledAction?.rawValue),
                "fulfilled_action_after_recovery": jsonValue(
                    recovered.actionRequest.fulfilledAction?.rawValue
                ),
                "state_revision": interrupted.budgetState.revision,
                "observation_count": interrupted.budgetState.observationCount,
                "predecessor_provider_turn_intent_count": interrupted
                    .predecessorProviderTurnIntentCount,
                "active_instance_id": jsonValue(
                    interrupted.budgetState.configuration.capacity.activeInstanceID
                ),
            ],
            "post_provider_crash_state": [
                "injected_point": ManagedContinuityCrashPoint.providerBootstrapResponse.rawValue,
                "injection_kind": "in_process_post_commit_error",
                "operation_state": interrupted.operation.state.rawValue,
                "predecessor_session_id": interrupted.predecessorSessionID,
                "predecessor_status": interrupted.predecessorAtCrash.status.rawValue,
                "predecessor_invocation_authority": interrupted.predecessorAuthorityAtCrash,
                "persisted_successor_count": interrupted.persistedSuccessorCountAtCrash,
                "provider_receipt_response_id": interrupted.receipt.providerResponseID,
                "predecessor_fence_event_sequence": interrupted.predecessorFenceEventSequence,
            ],
            "exact_acknowledgement": [
                "contract_version": interrupted.receipt.acknowledgement
                    .acknowledgementContractVersion,
                "accepted": interrupted.receipt.acknowledgement.accepted,
                "operation_id": interrupted.receipt.acknowledgement.operationID.uuidString.lowercased(),
                "project_id": interrupted.receipt.acknowledgement.projectID.description,
                "project_generation": interrupted.receipt.acknowledgement.projectGeneration.rawValue,
                "run_id": interrupted.receipt.acknowledgement.runID.description,
                "handoff_id": interrupted.receipt.acknowledgement.handoffID.uuidString.lowercased(),
                "handoff_sha256": interrupted.receipt.acknowledgement.handoffSHA256,
                "successor_internal_session_id": interrupted.receipt.internalSessionID,
                "bootstrap_provider_response_id": interrupted.receipt.providerResponseID,
            ],
            "recovered_successor": [
                "predecessor_status": recovered.predecessor.status.rawValue,
                "predecessor_invocation_authority": recovered.predecessorAuthority,
                "successor_session_id": recovered.successor.sessionID,
                "successor_status": recovered.successor.status.rawValue,
                "successor_invocation_authority": recovered.successorAuthority,
                "operation_session_count": recovered.sessions.count,
                "accepted_active_successor_count": recovered.sessions.filter {
                    $0.status == .active && $0.accepted
                }.count,
                "operation_state": recovered.operation.state.rawValue,
                "predecessor_fence_event_sequence": recovered.predecessorFenceEventSequence,
                "successor_accept_event_sequence": recovered.successorAcceptedEventSequence,
                "tool_intent_event_sequence": recovered.toolIntentEventSequence,
            ],
            "automatic_continuation": [
                "turn_id": recovered.automatic.intent.turnID.uuidString.lowercased(),
                "kind": recovered.automatic.intent.kind.rawValue,
                "state": recovered.automatic.state.rawValue,
                "session_id": recovered.automatic.intent.sessionID,
                "previous_response_id": jsonValue(
                    recovered.automatic.intent.previousResponseID
                ),
                "provider_response_id": jsonValue(recovered.automatic.providerResponseID),
                "input_sha256": recovered.automatic.intent.inputSHA256,
                "expected_input_sha256": JSONSupport.sha256Hex(
                    try ManagedContinuityWorker.automaticContinuationInput()
                ),
            ],
            "successor_only_tool_evidence": [
                "invocation_id": recovered.tool.invocationID.uuidString.lowercased(),
                "turn_id": recovered.tool.turnID.uuidString.lowercased(),
                "session_id": recovered.tool.sessionID,
                "tool_name": recovered.tool.toolName,
                "replay_class": recovered.tool.replayClass.rawValue,
                "state": recovered.tool.state.rawValue,
                "result_sha256": jsonValue(recovered.tool.resultSHA256),
                "expected_marker_sha256": JSONSupport.sha256Hex(Self.successorMarker),
                "result_contains_expected_marker": recovered.tool.resultSummary?.contains(
                    Self.successorMarker
                ) == true,
            ],
            "initial_startup": startupReportObject(interrupted.startupReport),
            "restart_recovery": startupReportObject(recovered.startupReport),
            "stable_replay": [
                "startup_report": startupReportObject(replayed.startupReport),
                "run_state": replayed.run.state.rawValue,
                "active_run_count_after_tick": replayed.activeRunCountAfterTick,
                "operation_state": replayed.operation.state.rawValue,
                "automatic_turn_id": replayed.automatic.intent.turnID.uuidString.lowercased(),
                "automatic_provider_response_id": jsonValue(
                    replayed.automatic.providerResponseID
                ),
                "tool_invocation_id": replayed.tool.invocationID.uuidString.lowercased(),
                "tool_intent_event_count": replayed.toolIntentEventCount,
                "accepted_active_successor_count": replayed.sessions.filter {
                    $0.status == .active && $0.accepted
                }.count,
                "receipt_provider_response_id": replayed.receipt.providerResponseID,
            ],
            "inference_delivery_semantics": [
                "claim": "bounded_duplicate_inference_possible",
                "exactly_once_inference_claim": "not_made",
                "maximum_duplicate_inferences_per_retry_attempt": 1,
                "repeated_retry_attempts": "may_each_repeat_one_inference",
            ],
            "real_provider_crash_coverage": [
                "covered": [ManagedContinuityCrashPoint.providerBootstrapResponse.rawValue],
                "not_covered": ManagedContinuityCrashPoint.allCases
                    .filter { $0 != .providerBootstrapResponse }
                    .map(\.rawValue),
                "sigkill_matrix": "not_executed",
            ],
        ]
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: url, options: .atomic)
    }

    private func startupReportObject(_ report: AutonomyStartupReport) -> [String: Any] {
        [
            "released_expired_leases": report.releasedExpiredLeases,
            "discovered_runs": report.discoveredRuns,
            "activated_run_ids": report.activatedRuns.map(\.description),
            "deferred_run_ids": report.deferredRuns.map(\.description),
            "stale_generation_run_ids": report.staleGenerationRuns.map(\.description),
        ]
    }
}

private final class LiveManagedRuntimeHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var runtime: ManagedAutonomyRuntime?

    func store(_ runtime: ManagedAutonomyRuntime) {
        lock.lock()
        self.runtime = runtime
        lock.unlock()
    }

    func load() -> ManagedAutonomyRuntime? {
        lock.lock()
        defer { lock.unlock() }
        return runtime
    }
}

private struct InterruptedPhase {
    let projectID: ProjectID
    let projectGeneration: ProjectGeneration
    let runID: RunID
    let managerRouteStatus: Int
    let managerRouteRunID: String?
    let startupReport: AutonomyStartupReport
    let guiPIDs: [Int]
    let managerNodeHostPID: Int
    let loadedProvider: LiveLoadedProviderInstance
    let thresholdRun: AutonomousRunRecord
    let actionRequestAtThreshold: ContextBudgetActionRequest
    let observation: ContextBudgetObservation
    let budgetState: PersistedContextBudgetState
    let predecessorSessionID: String
    let predecessorResponseID: String
    let predecessorAtCrash: ProviderSessionRecord
    let predecessorAuthorityAtCrash: String
    let operation: ContinuityOperationV2
    let handoff: ContinuityHandoffV2
    let receipt: BootstrapReceipt
    let persistedSuccessorCountAtCrash: Int
    let predecessorFenceEventSequence: Int64
    let predecessorProviderTurnIntentCount: Int
    let predecessorTurns: [ProviderTurnRecord]
}

private struct LiveLoadedProviderInstance {
    let instanceID: String
    let contextLength: Int
    let parallelism: Int
}

private struct RecoveredPhase {
    let startupReport: AutonomyStartupReport
    let guiPIDs: [Int]
    let managerNodeHostPID: Int
    let run: AutonomousRunRecord
    let operation: ContinuityOperationV2
    let predecessor: ProviderSessionRecord
    let successor: ProviderSessionRecord
    let sessions: [ProviderSessionRecord]
    let automatic: ProviderTurnRecord
    let tool: ToolInvocationRecord
    let predecessorAuthority: String
    let successorAuthority: String
    let predecessorFenceEventSequence: Int64
    let successorAcceptedEventSequence: Int64
    let toolIntentEventSequence: Int64
    let actionRequest: ContextBudgetActionRequest
    let pauseRouteStatus: Int
    let pauseRouteState: String?
}

private struct ReplayedPhase {
    let startupReport: AutonomyStartupReport
    let guiPIDs: [Int]
    let managerNodeHostPID: Int
    let run: AutonomousRunRecord
    let operation: ContinuityOperationV2
    let automatic: ProviderTurnRecord
    let tool: ToolInvocationRecord
    let sessions: [ProviderSessionRecord]
    let receipt: BootstrapReceipt
    let toolIntentEventCount: Int
    let activeRunCountAfterTick: Int
}

private enum LiveQualificationError: Error, LocalizedError {
    case invalidProviderInventory
    case managerRouteRejected(status: Int, code: String)
    case unexpectedProviderContext(expected: Int, actual: Int)
    case predecessorToolInvocation(sequence: Int64)
    case unexpectedThreshold(action: String, source: String, used: Int?, remaining: Int?)
    case unexpectedRunState(AutonomousRunState)
    case activationLimitExceeded
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .managerRouteRejected(let status, let code):
            "Manager start route rejected the disposable fixture: HTTP \(status), code \(code)"
        case .invalidProviderInventory:
            "LM Studio did not expose exactly one valid loaded instance for the selected model"
        case .unexpectedProviderContext(let expected, let actual):
            "Expected LM Studio context length \(expected), observed \(actual)"
        case .predecessorToolInvocation(let sequence):
            "Predecessor invoked a tool before automatic threshold rollover at event \(sequence)"
        case .unexpectedThreshold(let action, let source, let used, let remaining):
            "Expected provider-exact rollover, observed action=\(action) source=\(source) used=\(used.map(String.init) ?? "nil") remaining=\(remaining.map(String.init) ?? "nil")"
        case .unexpectedRunState(let state):
            "Managed run entered unexpected state \(state.rawValue)"
        case .activationLimitExceeded:
            "Managed run exceeded the bounded activation count"
        case .timeout(let target):
            "Timed out waiting for \(target)"
        }
    }
}
#endif
