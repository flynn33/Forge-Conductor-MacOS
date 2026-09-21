import XCTest
import SQLite3
@testable import ForgeConductorCore

final class ProjectContentClearTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var projectA: URL!
    private var projectB: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-project-clear-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        projectA = root.appendingPathComponent("project-a", isDirectory: true)
        projectB = root.appendingPathComponent("project-b", isDirectory: true)
        for directory in [home!, projectA!, projectB!] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testManagerCombinedClearIsProjectScopedAdvancesOnceAndReplays() async throws {
        let app = try configuredApp()
        defer { app.shutdown() }
        let manager = ManagerNode(app: app)
        let idA = try register(projectA, named: "Project A", using: manager)
        let idB = try register(projectB, named: "Project B", using: manager)
        let configurationBefore = app.config.model

        let memoryA = try app.projectMemory.repositoryForProject(idA.description).remember(
            ProjectMemoryWrite(kind: "fact", title: "A memory", summary: "clear me")
        ).0
        let memoryB = try app.projectMemory.repositoryForProject(idB.description).remember(
            ProjectMemoryWrite(kind: "fact", title: "B memory", summary: "preserve me")
        ).0
        let continuityA = UUID().uuidString.lowercased()
        let continuityB = UUID().uuidString.lowercased()
        _ = try app.projectMemory.repositoryForProject(idA.description).continuityCreateOperation(
            operationID: continuityA,
            predecessorSessionID: "a-session",
            handoffID: UUID().uuidString.lowercased(),
            adapterID: "fixture-adapter",
            idempotencyKey: "a-continuity"
        )
        _ = try app.projectMemory.repositoryForProject(idB.description).continuityCreateOperation(
            operationID: continuityB,
            predecessorSessionID: "b-session",
            handoffID: UUID().uuidString.lowercased(),
            adapterID: "fixture-adapter",
            idempotencyKey: "b-continuity"
        )

        let request = ProjectContentClearRequest(
            operationID: UUID(),
            projectID: idA,
            expectedGeneration: .initial,
            mode: .memoryAndContinuity
        )
        let receipt = try manager.clearProjectContent(request)
        XCTAssertFalse(receipt.replayed)
        XCTAssertEqual(receipt.projectID, idA)
        XCTAssertEqual(receipt.mode, .memoryAndContinuity)
        XCTAssertEqual(receipt.priorGeneration, .initial)
        XCTAssertEqual(receipt.newGeneration, ProjectGeneration(2))
        XCTAssertEqual(receipt.memoryRecordCount, 1)
        XCTAssertGreaterThanOrEqual(receipt.continuityRecordCount, 2)

        let reopenedA = try app.projectMemory.repositoryForProject(idA.description)
        XCTAssertNil(try reopenedA.get(id: memoryA.id))
        XCTAssertNil(try reopenedA.continuityOperation(id: continuityA))
        let untouchedB = try app.projectMemory.repositoryForProject(idB.description)
        XCTAssertNotNil(try untouchedB.get(id: memoryB.id))
        XCTAssertNotNil(try untouchedB.continuityOperation(id: continuityB))
        XCTAssertEqual(app.config.model, configurationBefore)

        let replay = try manager.clearProjectContent(request)
        XCTAssertTrue(replay.replayed)
        XCTAssertEqual(replay.operationID, receipt.operationID)
        XCTAssertEqual(replay.completedAt, receipt.completedAt)
        let updatedProjectA = try await app.projectContexts.repository.project(idA)
        XCTAssertEqual(updatedProjectA?.generation, ProjectGeneration(2))
        XCTAssertThrowsError(try manager.clearProjectContent(
            ProjectContentClearRequest(
                operationID: UUID(),
                projectID: idA,
                expectedGeneration: .initial,
                mode: .memory
            )
        )) { error in
            XCTAssertEqual(
                error as? ProjectContextError,
                .staleProjectGeneration(expected: .initial, actual: ProjectGeneration(2))
            )
        }
    }

    func testManagerClearRecoversOriginalOperationAfterProjectStoreCommitAndRestart() async throws {
        var app: ForgeApp? = try configuredApp()
        var manager: ManagerNode? = ManagerNode(app: try XCTUnwrap(app))
        let projectID = try register(projectA, named: "Interrupted Clear", using: try XCTUnwrap(manager))
        let memory = try XCTUnwrap(app).projectMemory.repositoryForProject(projectID.description)
            .remember(ProjectMemoryWrite(
                kind: "decision",
                title: "Interrupted clear fixture",
                summary: "must not resurrect"
            )).0
        let request = ProjectContentClearRequest(
            operationID: UUID(),
            projectID: projectID,
            expectedGeneration: .initial,
            mode: .memory
        )
        manager = ManagerNode(
            app: try XCTUnwrap(app),
            projectContentClearCheckpoint: { checkpoint in
                if case .projectMemoryCommitted = checkpoint {
                    throw ManagerProjectContentClearInterruption.simulatedProcessExit(checkpoint)
                }
            }
        )

        XCTAssertThrowsError(try XCTUnwrap(manager).clearProjectContent(request)) { error in
            guard case ManagerProjectContentClearInterruption.simulatedProcessExit(
                .projectMemoryCommitted
            ) = error else {
                return XCTFail("Expected interruption after the project store commit, received \(error)")
            }
        }
        XCTAssertNil(
            try XCTUnwrap(app).projectMemory.repositoryForProject(projectID.description)
                .get(id: memory.id)
        )
        let currentApp = try XCTUnwrap(app)
        let preparedValue = try await currentApp.projectContexts.repository
            .projectContentClearOperation(operationID: request.operationID)
        let prepared = try XCTUnwrap(preparedValue)
        XCTAssertEqual(prepared.state, .prepared)
        XCTAssertNil(prepared.receipt)

        manager = nil
        app?.shutdown()
        app = nil
        app = try configuredApp()
        defer { app?.shutdown() }
        manager = ManagerNode(app: try XCTUnwrap(app))

        let recovered = try XCTUnwrap(manager).clearProjectContent(request)
        XCTAssertFalse(recovered.replayed)
        XCTAssertEqual(recovered.operationID, request.operationID)
        XCTAssertEqual(recovered.newGeneration, ProjectGeneration(2))
        XCTAssertNil(
            try XCTUnwrap(app).projectMemory.repositoryForProject(projectID.description)
                .get(id: memory.id)
        )
        let lostResponseReplay = try XCTUnwrap(manager).clearProjectContent(request)
        XCTAssertTrue(lostResponseReplay.replayed)
        XCTAssertEqual(lostResponseReplay.completedAt, recovered.completedAt)
    }

    func testManagerClearRefusesNonterminalRunWithoutDeletingContent() async throws {
        let app = try configuredApp()
        defer { app.shutdown() }
        let manager = ManagerNode(app: app)
        let projectID = try register(projectA, named: "Busy Project", using: manager)
        let memory = try app.projectMemory.repositoryForProject(projectID.description).remember(
            ProjectMemoryWrite(kind: "fact", title: "Busy fixture", summary: "preserve")
        ).0
        let run = try await app.projectContexts.repository.createAutonomousRun(
            AutonomousRunRequest(
                projectID: projectID,
                projectGeneration: .initial,
                mission: "Remain nonterminal",
                providerID: "lmstudio",
                adapterID: "forge.native-session-host",
                modelKey: "fixture-model",
                specification: AutonomousRunSpecification(
                    allowedTools: ["project_memory.search"],
                    completionGates: ["fixture-gate"]
                ),
                authorizationScope: ToolAuthorizationScope(
                    canonicalRoots: [projectA],
                    allowedTools: ["project_memory.search"],
                    networkAllowed: false,
                    maximumInlineOutputBytes: 1_024
                )
            )
        )
        let request = ProjectContentClearRequest(
            operationID: UUID(),
            projectID: projectID,
            expectedGeneration: .initial,
            mode: .memory
        )

        XCTAssertThrowsError(try manager.clearProjectContent(request)) { error in
            XCTAssertEqual(error as? ProjectContextError, .projectTransitionConflict(projectID))
        }
        XCTAssertNotNil(
            try app.projectMemory.repositoryForProject(projectID.description).get(id: memory.id)
        )
        let preservedRun = try await app.projectContexts.repository.autonomousRun(run.runID)
        XCTAssertEqual(preservedRun?.state, .created)
        let preservedProject = try await app.projectContexts.repository.project(projectID)
        XCTAssertEqual(preservedProject?.generation, .initial)
        let absentOperation = try await app.projectContexts.repository
            .projectContentClearOperation(operationID: request.operationID)
        XCTAssertNil(absentOperation)
    }

    func testRunHistoryClearRemovesOnlyTerminalRunsAndPreservesProjectContent() async throws {
        let app = try configuredApp()
        defer { app.shutdown() }
        let manager = ManagerNode(app: app)
        let projectID = try register(projectA, named: "History Project", using: manager)
        let memory = try app.projectMemory.repositoryForProject(projectID.description).remember(
            ProjectMemoryWrite(kind: "fact", title: "Preserved memory", summary: "not history")
        ).0
        let continuityID = UUID().uuidString.lowercased()
        _ = try app.projectMemory.repositoryForProject(projectID.description)
            .continuityCreateOperation(
                operationID: continuityID,
                predecessorSessionID: "history-session",
                handoffID: UUID().uuidString.lowercased(),
                adapterID: "fixture-adapter",
                idempotencyKey: "history-continuity"
            )
        let run = try await app.projectContexts.repository.createAutonomousRun(
            runRequest(projectID: projectID, mission: "Terminal history fixture")
        )
        let lease = try await app.projectContexts.repository.acquireRunLease(
            runID: run.runID,
            ownerID: "history-clear-fixture"
        )
        _ = try await app.projectContexts.repository.transitionAutonomousRun(
            runID: run.runID,
            lease: lease,
            transition: AutonomousRunTransition(
                expectedState: .created,
                expectedRevision: run.revision,
                nextState: .failedTerminal,
                eventType: "fixture_run_terminal",
                eventSummary: "Fixture run reached a terminal state",
                errorCode: "fixture_terminal",
                errorSummary: "Intentional terminal history fixture"
            )
        )

        let receipt = try manager.clearProjectContent(ProjectContentClearRequest(
            operationID: UUID(),
            projectID: projectID,
            expectedGeneration: .initial,
            mode: .runHistory
        ))
        XCTAssertEqual(receipt.runHistoryCount, 1)
        XCTAssertEqual(receipt.memoryRecordCount, 0)
        XCTAssertEqual(receipt.continuityRecordCount, 0)
        let removedRun = try await app.projectContexts.repository.autonomousRun(run.runID)
        XCTAssertNil(removedRun)
        let reopened = try app.projectMemory.repositoryForProject(projectID.description)
        XCTAssertNotNil(try reopened.get(id: memory.id))
        XCTAssertNotNil(try reopened.continuityOperation(id: continuityID))
    }

    func testContinuityClearRemovesControlPlanePayloadCopiesAndRetainsOnlyReplayAuthority() async throws {
        let app = try configuredApp()
        defer { app.shutdown() }
        let manager = ManagerNode(app: app)
        let projectID = try register(projectA, named: "Continuity Payload Project", using: manager)
        let memory = try app.projectMemory.repositoryForProject(projectID.description).remember(
            ProjectMemoryWrite(kind: "fact", title: "Preserved user memory", summary: "not continuity")
        ).0
        let scope = ToolAuthorizationScope(
            canonicalRoots: [projectA],
            allowedTools: ["context_get", "fs_read"],
            networkAllowed: false,
            maximumInlineOutputBytes: 65_536
        )
        let client = ClientID("clear-fixture-" + UUID().uuidString.lowercased())
        let owner = ProjectBindingOwner(kind: .mcpClient, id: client.rawValue)
        let binding = try await app.projectContexts.repository.bind(
            owner: owner,
            projectID: projectID,
            generation: .initial,
            authorizationScope: scope
        )
        let taskID = UUID()
        let assignment = try ContinuityTaskAssignment(
            assignmentID: "clear-payload-fixture",
            assignmentBytes: Data("checkpoint payload fixture".utf8),
            mission: "Prove payload copies are cleared",
            providerID: "lmstudio",
            adapterID: "forge.native-session-host",
            modelKey: "fixture/model",
            specification: AutonomousRunSpecification(
                allowedTools: ["context_get", "fs_read"],
                completionGates: ["payload-cleared"]
            ),
            authorizationScope: scope
        )
        _ = try await app.projectContexts.repository.authorizeContinuityTask(
            taskID: taskID,
            projectID: projectID,
            expectedGeneration: .initial,
            approvedAssignment: assignment,
            callerContext: binding.invocationContext(clientID: client),
            callerOwner: owner
        )

        let operationID = UUID().uuidString.lowercased()
        let runID = UUID().uuidString.lowercased()
        let candidateID = UUID().uuidString.lowercased()
        let grantID = UUID().uuidString.lowercased()
        let payloadMarker = "clear-control-plane-payload-marker"
        let controlPlaneDatabase = await app.projectContexts.repository.databaseURL
        try ProjectContentClearSQLite.execute(
            at: controlPlaneDatabase,
            sql: """
            INSERT INTO continuity_ingress_acceptances(
                operation_id,key_sha256,run_id,task_id,project_id,project_generation,
                receipt_json,receipt_sha256,accepted_at
            ) VALUES(?,?,?,?,?,1,?,?,?)
            """,
            values: [operationID, String(repeating: "1", count: 64), runID,
                     taskID.uuidString.lowercased(), projectID.description,
                     "{\"payload\":\"\(payloadMarker)\"}", String(repeating: "2", count: 64),
                     "2026-09-14T12:00:00Z"]
        )
        try ProjectContentClearSQLite.execute(
            at: controlPlaneDatabase,
            sql: """
            INSERT INTO continuity_source_activations(
                operation_id,run_id,project_id,project_generation,task_id,candidate_id,
                envelope_json,envelope_sha256,receipt_json,receipt_sha256
            ) VALUES(?,?,?,1,?,?,?,?,?,?)
            """,
            values: [operationID, runID, projectID.description,
                     taskID.uuidString.lowercased(), candidateID,
                     "{\"payload\":\"\(payloadMarker)\"}", String(repeating: "3", count: 64),
                     "{\"receipt\":\"\(payloadMarker)\"}", String(repeating: "4", count: 64)]
        )
        try ProjectContentClearSQLite.execute(
            at: controlPlaneDatabase,
            sql: """
            INSERT INTO continuity_bootstrap_grants(
                grant_id,candidate_id,operation_id,run_id,grant_json,grant_sha256
            ) VALUES(?,?,?,?,?,?)
            """,
            values: [grantID, candidateID, operationID, runID,
                     "{\"grant\":\"\(payloadMarker)\"}", String(repeating: "5", count: 64)]
        )

        let receipt = try manager.clearProjectContent(ProjectContentClearRequest(
            operationID: UUID(),
            projectID: projectID,
            expectedGeneration: .initial,
            mode: .continuity
        ))
        XCTAssertGreaterThanOrEqual(receipt.continuityRecordCount, 4)
        XCTAssertNotNil(
            try app.projectMemory.repositoryForProject(projectID.description).get(id: memory.id)
        )
        XCTAssertEqual(
            try ProjectContentClearSQLite.count(
                at: controlPlaneDatabase,
                sql: "SELECT COUNT(*) FROM continuity_task_authorizations WHERE project_id=?",
                value: projectID.description
            ),
            0
        )
        XCTAssertEqual(
            try ProjectContentClearSQLite.count(
                at: controlPlaneDatabase,
                sql: "SELECT COUNT(*) FROM continuity_source_activations WHERE project_id=?",
                value: projectID.description
            ),
            0
        )
        XCTAssertEqual(
            try ProjectContentClearSQLite.count(
                at: controlPlaneDatabase,
                sql: "SELECT COUNT(*) FROM continuity_authority_tombstones WHERE project_id=?",
                value: projectID.description
            ),
            3
        )

        let rebound = try await app.projectContexts.repository.bind(
            owner: owner,
            projectID: projectID,
            generation: ProjectGeneration(2),
            authorizationScope: scope
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await app.projectContexts.repository.authorizeContinuityTask(
                taskID: taskID,
                projectID: projectID,
                expectedGeneration: ProjectGeneration(2),
                approvedAssignment: assignment,
                callerContext: rebound.invocationContext(clientID: client),
                callerOwner: owner
            )
        } verify: { error in
            XCTAssertEqual(error as? ContinuityTaskAuthorizationError, .revoked)
        }
    }

    func testSingleTaskDeletionRemovesOnlyExactTerminalRunAndRejectsActiveRun() async throws {
        let app = try configuredApp()
        defer { app.shutdown() }
        let manager = ManagerNode(app: app)
        let projectID = try register(projectA, named: "Task Deletion Project", using: manager)
        let terminal = try await app.projectContexts.repository.createAutonomousRun(
            runRequest(projectID: projectID, mission: "Delete this settled task")
        )
        let active = try await app.projectContexts.repository.createAutonomousRun(
            runRequest(projectID: projectID, mission: "Preserve this active task")
        )
        let lease = try await app.projectContexts.repository.acquireRunLease(
            runID: terminal.runID,
            ownerID: "task-deletion-fixture"
        )
        _ = try await app.projectContexts.repository.transitionAutonomousRun(
            runID: terminal.runID,
            lease: lease,
            transition: AutonomousRunTransition(
                expectedState: .created,
                expectedRevision: terminal.revision,
                nextState: .failedTerminal,
                eventType: "fixture_run_terminal",
                eventSummary: "Fixture run is safe to delete",
                errorCode: "fixture_terminal",
                errorSummary: "Intentional terminal deletion fixture"
            )
        )

        let receipt = try manager.deleteAutonomousRun(
            runID: terminal.runID,
            projectID: projectID,
            expectedGeneration: .initial
        )
        XCTAssertEqual(receipt.runID, terminal.runID)
        XCTAssertEqual(receipt.projectID, projectID)
        XCTAssertEqual(receipt.projectGeneration, .initial)
        XCTAssertEqual(receipt.priorState, .failedTerminal)
        XCTAssertNotNil(ISO8601.date(from: receipt.deletedAt))
        let removedRun = try await app.projectContexts.repository.autonomousRun(terminal.runID)
        let preservedActiveRun = try await app.projectContexts.repository.autonomousRun(active.runID)
        XCTAssertNil(removedRun)
        XCTAssertNotNil(preservedActiveRun)

        await XCTAssertThrowsErrorAsync {
            _ = try await app.projectContexts.repository.deleteTerminalAutonomousRun(
                runID: active.runID,
                projectID: projectID,
                expectedGeneration: .initial
            )
        } verify: { error in
            guard case .invalidRequest = error as? AutonomyError else {
                return XCTFail("Expected nonterminal deletion to fail closed, got \(error)")
            }
        }
        let activeRunAfterRejection = try await app.projectContexts.repository.autonomousRun(active.runID)
        XCTAssertNotNil(activeRunAfterRejection)
    }

    private func configuredApp() throws -> ForgeApp {
        let app = try ForgeApp.bootstrap(home: home)
        _ = try app.config.update(["allowed_roots": [root.path]], save: true)
        return app
    }

    private func register(
        _ root: URL,
        named displayName: String,
        using manager: ManagerNode
    ) throws -> ProjectID {
        let result = try manager.registerProject(path: root.path, displayName: displayName)
        return ProjectID(try XCTUnwrap(
            (result["project_id"] as? String).flatMap(UUID.init(uuidString:))
        ))
    }

    private func runRequest(projectID: ProjectID, mission: String) -> AutonomousRunRequest {
        AutonomousRunRequest(
            projectID: projectID,
            projectGeneration: .initial,
            mission: mission,
            providerID: "lmstudio",
            adapterID: "forge.native-session-host",
            modelKey: "fixture-model",
            specification: AutonomousRunSpecification(
                allowedTools: ["project_memory.search"],
                completionGates: ["fixture-gate"]
            ),
            authorizationScope: ToolAuthorizationScope(
                canonicalRoots: [projectA],
                allowedTools: ["project_memory.search"],
                networkAllowed: false,
                maximumInlineOutputBytes: 1_024
            )
        )
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    verify: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {
        verify(error)
    }
}

private enum ProjectContentClearSQLite {
    static func execute(at path: URL, sql: String, values: [String]) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            path.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            throw ProjectContextError.databaseFailure("clear fixture open failed")
        }
        defer { sqlite3_close_v2(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw ProjectContextError.databaseFailure("clear fixture prepare failed")
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            let result = value.withCString {
                sqlite3_bind_text(
                    statement,
                    Int32(index + 1),
                    $0,
                    -1,
                    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                )
            }
            guard result == SQLITE_OK else {
                throw ProjectContextError.databaseFailure("clear fixture bind failed")
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ProjectContextError.databaseFailure(
                String(cString: sqlite3_errmsg(database))
            )
        }
    }

    static func count(at path: URL, sql: String, value: String) throws -> Int {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            path.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            throw ProjectContextError.databaseFailure("clear fixture read open failed")
        }
        defer { sqlite3_close_v2(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw ProjectContextError.databaseFailure("clear fixture read prepare failed")
        }
        defer { sqlite3_finalize(statement) }
        let bound = value.withCString {
            sqlite3_bind_text(
                statement,
                1,
                $0,
                -1,
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            )
        }
        guard bound == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW else {
            throw ProjectContextError.databaseFailure("clear fixture read failed")
        }
        return Int(sqlite3_column_int64(statement, 0))
    }
}
