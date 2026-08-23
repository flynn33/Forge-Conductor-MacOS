// ContinuityCoordinatorTests.swift
// Verifies durable rollover recovery, exact acknowledgment, compact handoffs, and MCP control.

import XCTest
@testable import ForgeConductorCore

private actor RecordingHostAdapter: SessionHostAdapter {
    nonisolated let identifier = "recording-host"
    nonisolated let version = "1.0"

    private var sessions: [String: HostSession] = [:]
    private var createCalls = 0
    private var bootstrapCalls = 0
    private var bootstrapEffects: Set<String> = []

    func capabilities() async throws -> HostCapabilities {
        HostCapabilities(
            create: true, bootstrap: true, usageReporting: true,
            resume: true, idempotency: true, queryByIdempotencyKey: true
        )
    }

    func createSession(_ request: SessionCreationRequest) async throws -> HostSession {
        if let existing = sessions[request.idempotencyKey] { return existing }
        createCalls += 1
        let session = HostSession(id: "successor-\(request.operationID)")
        sessions[request.idempotencyKey] = session
        return session
    }

    func session(forIdempotencyKey key: String) async throws -> HostSession? {
        sessions[key]
    }

    func bootstrap(_ session: HostSession, handoff: ContinuityHandoff) async throws {
        guard session.id == "successor-\(handoff.operationID)" else {
            throw ProjectMemoryError.integrityFailure("bootstrap session does not match operation")
        }
        bootstrapCalls += 1
        bootstrapEffects.insert(handoff.handoffID)
    }

    func awaitAcknowledgement(
        session: HostSession,
        handoffID: String,
        timeout: Duration
    ) async throws -> HandoffAcknowledgement {
        HandoffAcknowledgement(
            handoffID: handoffID, successorSessionID: session.id, adapterID: identifier
        )
    }

    func cancel(operationID: String) async {}

    func counts() -> (creates: Int, bootstrapCalls: Int, bootstrapEffects: Int) {
        (createCalls, bootstrapCalls, bootstrapEffects.count)
    }
}

final class ContinuityCoordinatorTests: XCTestCase {
    func testLegacyAgentSnapshotAndMergeCollectionsStayBounded() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-continuity-snapshot-bound-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try ForgeApp.bootstrap(home: root.appendingPathComponent("home", isDirectory: true))
        defer { app.shutdown() }
        let client = ClientID("snapshot-bound")
        for _ in 0..<(ContextContinuityService.maximumAgentSnapshots + 16) {
            _ = try app.store.sessionStart(agentID: "debug", clientID: client)
        }

        let handoff = try app.continuity.handoff(
            arguments: ["goal": "Bound agent snapshots"], clientID: client
        )
        let firstPacket = try XCTUnwrap(handoff["packet"] as? [String: Any])
        let firstAgents = try XCTUnwrap(firstPacket["agents"] as? [[String: Any]])
        XCTAssertEqual(firstAgents.count, ContextContinuityService.maximumAgentSnapshots)

        let checkpoint = try app.continuity.checkpoint(
            arguments: ["handoff_id": try XCTUnwrap(handoff["handoff_id"] as? String)],
            clientID: client
        )
        let mergedPacket = try XCTUnwrap(checkpoint["packet"] as? [String: Any])
        let mergedAgents = try XCTUnwrap(mergedPacket["agents"] as? [[String: Any]])
        XCTAssertEqual(mergedAgents.count, ContextContinuityService.maximumAgentSnapshots)
    }

    func testEveryTransitionCrashPointRecoversWithoutDuplicateSuccessor() async throws {
        for crashPoint in ContinuityCrashPoint.allCases {
            let fixture = try makeFixture(label: crashPoint.rawValue)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let adapter = RecordingHostAdapter()
            var memory: ProjectMemoryService? = fixture.memory
            let handoff = try makeHandoff(projectID: fixture.projectID)
            let coordinator = ContinuityCoordinator(engine: ContinuityStateEngine(memory: memory!))

            do {
                _ = try await coordinator.requestRollover(
                    handoff: handoff, predecessorSessionID: "predecessor",
                    adapter: adapter, idempotencyKey: "rollover-\(crashPoint.rawValue)",
                    crashAfter: crashPoint
                )
                XCTFail("Expected crash at \(crashPoint.rawValue)")
            } catch ContinuityRunError.injectedCrash(let observed) {
                XCTAssertEqual(observed, crashPoint)
            }

            memory?.closeAll()
            memory = nil
            let restartedMemory = ProjectMemoryService(paths: AppPaths(home: fixture.home))
            defer { restartedMemory.closeAll() }
            let restarted = ContinuityCoordinator(engine: ContinuityStateEngine(memory: restartedMemory))
            let recovered = try await restarted.recover(projectID: fixture.projectID, adapter: adapter)
            if crashPoint == .predecessorSealed {
                XCTAssertNil(recovered)
            } else {
                XCTAssertEqual(recovered?.state, .predecessorSealed, crashPoint.rawValue)
            }

            let durable = try XCTUnwrap(
                restarted.engine.operation(projectID: fixture.projectID, operationID: handoff.operationID)
            )
            XCTAssertEqual(durable.state, .predecessorSealed, crashPoint.rawValue)
            XCTAssertEqual(durable.acknowledgedSessionID, "successor-\(handoff.operationID)")
            let repository = try restartedMemory.repositoryForProject(fixture.projectID)
            XCTAssertEqual(try repository.continuityActiveSessionID(), durable.successorSessionID)
            XCTAssertEqual(try repository.continuityTransitionCount(operationID: handoff.operationID), 8)

            let counts = await adapter.counts()
            XCTAssertEqual(counts.creates, 1, crashPoint.rawValue)
            XCTAssertEqual(counts.bootstrapEffects, 1, crashPoint.rawValue)
            XCTAssertGreaterThanOrEqual(counts.bootstrapCalls, 1, crashPoint.rawValue)
        }
    }

    func testIdempotentReplayAndExactAcknowledgement() async throws {
        let fixture = try makeFixture(label: "idempotency")
        defer {
            fixture.memory.closeAll()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let adapter = RecordingHostAdapter()
        let handoff = try makeHandoff(projectID: fixture.projectID)
        let coordinator = ContinuityCoordinator(engine: ContinuityStateEngine(memory: fixture.memory))
        let first = try await coordinator.requestRollover(
            handoff: handoff, predecessorSessionID: "predecessor",
            adapter: adapter, idempotencyKey: "one-successor"
        )
        let replay = try await coordinator.requestRollover(
            handoff: handoff, predecessorSessionID: "predecessor",
            adapter: adapter, idempotencyKey: "one-successor"
        )
        XCTAssertEqual(first, replay)
        let replayCounts = await adapter.counts()
        XCTAssertEqual(replayCounts.creates, 1)

        let sameAck = HandoffAcknowledgement(
            handoffID: handoff.handoffID,
            successorSessionID: try XCTUnwrap(first.successorSessionID),
            adapterID: adapter.identifier
        )
        XCTAssertEqual(
            try coordinator.engine.acknowledge(
                projectID: fixture.projectID, operationID: handoff.operationID,
                acknowledgement: sameAck
            ).state,
            .predecessorSealed
        )
        XCTAssertThrowsError(
            try coordinator.engine.acknowledge(
                projectID: fixture.projectID, operationID: handoff.operationID,
                acknowledgement: HandoffAcknowledgement(
                    handoffID: handoff.handoffID, successorSessionID: "different-successor",
                    adapterID: adapter.identifier
                )
            )
        )
    }

    func testBudgetSourcesAndHandoffSizeBound() throws {
        let monitor = ContextBudgetMonitor()
        XCTAssertEqual(try monitor.exact(capacity: 1000, used: 100, reserved: 100).action, .normal)
        XCTAssertEqual(try monitor.exact(capacity: 1000, used: 750, reserved: 100).action, .checkpoint)
        XCTAssertEqual(try monitor.estimated(capacity: 1000, serializedBytes: 3_200, reserved: 50).action, .rollover)
        XCTAssertEqual(try monitor.overflow(capacity: 1000, reserved: 100).action, .emergency)

        let fixture = try makeFixture(label: "bounds")
        defer {
            fixture.memory.closeAll()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let compact = try makeHandoff(projectID: fixture.projectID)
        XCTAssertLessThan(try JSONSupport.data(from: compact.asDictionary()).count, ContinuityHandoff.maximumEncodedBytes)
        var oversized = compact
        oversized.mission = String(repeating: "x", count: ContinuityHandoff.maximumEncodedBytes)
        XCTAssertThrowsError(try oversized.validated()) { error in
            XCTAssertEqual((error as? ProjectMemoryError)?.code, "payload_too_large")
        }
    }

    func testExternalMCPControlLifecycleAndSchemas() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-continuity-mcp-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let initialized = try call(app, "project_memory.initialize", ["project_path": project.path])
        let projectID = try XCTUnwrap(initialized["project_id"] as? String)

        XCTAssertTrue(Set(ContinuityLifecycleToolPack.names).isSubset(of: Set(app.tools.toolNames)))
        for name in ContinuityLifecycleToolPack.names {
            XCTAssertEqual(ContinuityLifecycleToolPack.schema(for: name)?["type"] as? String, "object")
        }

        let prepared = try call(app, "continuity.request_rollover", [
            "project_id": projectID, "predecessor_session_id": "external-predecessor",
            "mission": "Continue the repair", "phase_id": "P08", "work_item_id": "P08-06",
            "next_actions": ["Validate recovery", "Advance to host adapter"],
        ])
        XCTAssertEqual(prepared["disposition"] as? String, "memory_only_handoff_ready")
        let operation = try XCTUnwrap(prepared["operation"] as? [String: Any])
        let handoff = try XCTUnwrap(prepared["handoff"] as? [String: Any])
        let operationID = try XCTUnwrap(operation["operation_id"] as? String)
        let handoffID = try XCTUnwrap(handoff["handoff_id"] as? String)
        XCTAssertEqual(operation["state"] as? String, ContinuityState.checkpointPersisted.rawValue)

        let pending = try call(app, "continuity.get_pending_handoff", ["project_id": projectID])
        XCTAssertEqual(pending["found"] as? Bool, true)
        let rejected = try app.tools.call(
            name: "continuity.acknowledge_handoff",
            arguments: [
                "project_id": projectID, "operation_id": operationID, "handoff_id": handoffID,
                "successor_session_id": "wrong-successor", "adapter_id": "wrong-adapter",
            ], clientID: ClientID("continuity-mcp-test")
        )
        XCTAssertFalse(rejected.ok)
        XCTAssertEqual(rejected.payload["code"] as? String, "conflict")

        let acknowledged = try call(app, "continuity.acknowledge_handoff", [
            "project_id": projectID, "operation_id": operationID, "handoff_id": handoffID,
            "successor_session_id": "external-successor", "adapter_id": "external-mcp",
        ])
        XCTAssertEqual((acknowledged["operation"] as? [String: Any])?["state"] as? String, ContinuityState.successorAcknowledged.rawValue)
        let repeated = try call(app, "continuity.acknowledge_handoff", [
            "project_id": projectID, "operation_id": operationID, "handoff_id": handoffID,
            "successor_session_id": "external-successor", "adapter_id": "external-mcp",
        ])
        XCTAssertEqual((repeated["operation"] as? [String: Any])?["state"] as? String, ContinuityState.successorAcknowledged.rawValue)

        let resumed = try call(app, "continuity.resume", ["project_id": projectID, "operation_id": operationID])
        XCTAssertEqual((resumed["operation"] as? [String: Any])?["state"] as? String, ContinuityState.predecessorSealed.rawValue)
        let status = try call(app, "continuity.status", ["project_id": projectID])
        XCTAssertEqual(status["active_session_id"] as? String, "external-successor")
    }

    private func makeFixture(label: String) throws -> (
        root: URL, home: URL, projectID: String, memory: ProjectMemoryService
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-continuity-\(label)-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let paths = AppPaths(home: home)
        try paths.ensureLayout()
        let memory = ProjectMemoryService(paths: paths)
        let initialized = try memory.initialize(path: project.path)
        let projectID = try XCTUnwrap(initialized["project_id"] as? String)
        return (root, home, projectID, memory)
    }

    private func makeHandoff(projectID: String) throws -> ContinuityHandoff {
        try ContinuityHandoff(
            operationID: UUID().uuidString.lowercased(),
            project: [
                "project_id": projectID, "display_name": "Fixture", "repository_root": "/fixture",
                "branch": "repair/runtime", "commit": "1234567", "dirty_summary": [] as [String],
            ],
            predecessorSession: [
                "session_id": "predecessor", "provider_session_id": NSNull(), "model": NSNull(),
            ],
            mission: "Continue deterministic project repair",
            constraints: ["Preserve current work"],
            currentWork: [
                "phase_id": "P08", "work_item_id": "P08-06", "summary": "Validate rollover",
                "active_files": [] as [String],
            ],
            validation: [
                "passed_gates": ["G07"], "open_gates": ["G08"], "commands": [] as [[String: Any]],
            ],
            nextActions: [[
                "order": 1, "action": "Recover the rollover", "command": "swift test",
                "success_condition": "The successor is acknowledged exactly once",
            ]],
            hostState: [
                "adapter_id": "recording-host", "continuity_state": ContinuityState.checkpointPreparing.rawValue,
                "context_budget_source": "provider_exact", "retry": [:] as [String: Any],
            ]
        ).validated()
    }

    private func call(_ app: ForgeApp, _ name: String, _ arguments: [String: Any]) throws -> [String: Any] {
        let result = try app.tools.call(
            name: name, arguments: arguments, clientID: ClientID("continuity-mcp-test")
        )
        XCTAssertTrue(result.ok, "\(name): \(result.payload)")
        return result.payload
    }
}
