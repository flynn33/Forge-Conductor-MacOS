import XCTest
import SQLite3
@testable import ForgeConductorCore

final class LegacyContinuityCancellationTests: XCTestCase {
    private var tempHome: URL!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-test-legacy-cancellation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempHome)
    }

    func testLegacyReadPathsHonorExpiredDeadlines() throws {
        let store = try SQLiteStore(path: databaseURL("legacy-read-deadlines"))
        defer { store.close() }
        let packet = HandoffPacket(id: "read-deadline-handoff", goal: "Preserve legacy reads")
        try store.handoffUpsert(packet)
        let session = try store.sessionStart(
            agentID: "debug",
            clientID: ClientID("read-deadline-client")
        )
        try store.presenceUpsert(
            clientID: "read-deadline-client",
            hostKind: "test",
            pid: 0,
            cwd: tempHome.path
        )

        let operations: [(ToolCallCancellation) throws -> Void] = [
            { control in _ = try store.handoffGet(id: packet.id, cancellation: control) },
            { control in _ = try store.handoffLatest(cancellation: control) },
            { control in _ = try store.handoffList(cancellation: control) },
            { control in _ = try store.handoffListAll(cancellation: control) },
            { control in _ = try store.sessionGet(id: session.id, cancellation: control) },
            { control in _ = try store.sessionList(cancellation: control) },
            { control in _ = try store.presenceRecords(cancellation: control) },
            { control in _ = try store.presenceList(cancellation: control) },
        ]

        for operation in operations {
            let expired = ToolCallCancellation(timeoutSeconds: 0)
            XCTAssertThrowsError(try operation(expired)) { error in
                XCTAssertTrue(error is ToolCallDeadlineExceeded, "unexpected error: \(error)")
            }
        }
    }

    func testSessionWriteCancellationPreemptsSQLiteContentionWithoutPartialWrite() async throws {
        let storeURL = databaseURL("session-active-cancellation")
        let busyReached = DispatchSemaphore(value: 0)
        let store = try SQLiteStore(
            path: storeURL,
            postMigrationCommitObserver: nil,
            sqliteBusyRetryObserver: {
                busyReached.signal()
            }
        )
        defer { store.close() }
        let locker = try openWriteLock(storeURL)
        defer { closeWriteLock(locker) }

        let control = ToolCallCancellation(timeoutSeconds: 5)
        let operation = Task.detached {
            try store.sessionStart(
                agentID: "debug",
                clientID: ClientID("active-cancel-client"),
                cancellation: control
            )
        }
        XCTAssertEqual(busyReached.wait(timeout: .now() + 1), .success)
        let cancelledAt = Date()
        control.cancel()
        do {
            _ = try await operation.value
            XCTFail("cancelled session write returned success")
        } catch is CancellationError {
            // Expected: the SQLite busy handler observed active cancellation.
        } catch {
            XCTFail("unexpected cancellation error: \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 1)

        rollbackWriteLock(locker)
        XCTAssertTrue(try store.sessionList().isEmpty)
    }

    func testLegacyToolPacksHonorDeadlinesDuringSQLiteContention() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let locker = try openWriteLock(app.store.path)
        defer { closeWriteLock(locker) }

        expectDeadlineWithinOneSecond {
            _ = try AgentToolPack().handle(
                name: "agent_run_start",
                arguments: [
                    "agent_id": "debug",
                    "goal": "Deadline-bound session",
                    "cwd": self.tempHome.path,
                ],
                context: nil,
                clientID: ClientID("agent-pack-deadline"),
                app: app,
                cancellation: ToolCallCancellation(timeoutSeconds: 0.1)
            )
        }
        expectDeadlineWithinOneSecond {
            _ = try ContinuityToolPack().handle(
                name: "session_checkpoint",
                arguments: ["goal": "Deadline-bound checkpoint"],
                context: nil,
                clientID: ClientID("continuity-pack-deadline"),
                app: app,
                cancellation: ToolCallCancellation(timeoutSeconds: 0.1)
            )
        }

        rollbackWriteLock(locker)
        XCTAssertTrue(try app.store.sessionList().isEmpty)
        XCTAssertTrue(try app.store.handoffList().isEmpty)
        XCTAssertNil(try app.store.memoryGet(key: "continuity/latest"))
        XCTAssertNil(try app.store.memoryGet(key: "agent_active/agent-pack-deadline"))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: app.paths.memoryHandoffsDir.appendingPathComponent("LATEST").path
            )
        )
    }

    func testSessionCloseCancellationBeforeCommitRollsBackEveryRow() throws {
        let trigger = MutationTrigger(target: .session)
        let control = ToolCallCancellation(timeoutSeconds: 5)
        let store = try SQLiteStore(
            path: databaseURL("session-precommit"),
            postMigrationCommitObserver: nil,
            beforeMutationCommitObserver: { kind in
                if trigger.observe(kind) { control.cancel() }
            }
        )
        defer { store.close() }
        let clientID = ClientID("session-precommit-client")
        _ = try store.sessionStart(agentID: "debug", clientID: clientID)
        trigger.arm()

        XCTAssertThrowsError(
            try store.sessionCloseOpen(
                for: clientID,
                summary: "must roll back",
                cancellation: control
            )
        ) { error in
            XCTAssertTrue(error is CancellationError, "unexpected error: \(error)")
        }

        let sessions = try store.sessionList()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertTrue(sessions.allSatisfy(\.status.isOpen))
    }

    func testAgentSessionStartReturnsCommittedResultAfterCommitCancellation() throws {
        let trigger = MutationTrigger(target: .session)
        let control = ToolCallCancellation(timeoutSeconds: 5)
        let paths = AppPaths(home: tempHome.appendingPathComponent("session-service", isDirectory: true))
        try paths.ensureLayout()
        let store = try SQLiteStore(
            path: paths.storeSQLite,
            postMigrationCommitObserver: nil,
            didMutationCommitObserver: { kind in
                if trigger.observe(kind) { control.cancel() }
            }
        )
        defer { store.close() }
        let service = makeSessionService(paths: paths, store: store)
        trigger.arm()

        let result = try service.start(
            agentID: "debug",
            goal: "Return the durable session",
            clientID: ClientID("session-postcommit-client"),
            cwd: tempHome.path,
            cancellation: control
        )

        let sessionID = try XCTUnwrap(result["session_id"] as? String)
        XCTAssertTrue(control.isCancelled)
        XCTAssertNotNil(try store.sessionGet(id: SessionID(sessionID)))
        XCTAssertNotNil(try store.memoryGet(key: "agent_active/session-postcommit-client"))
        XCTAssertNotNil(try store.memoryGet(key: "agent_run/\(sessionID)"))
    }

    func testConcurrentAgentStartsLeaveExactlyOneOpenSessionAndMatchingBinding() throws {
        let database = databaseURL("concurrent-agent-start")
        let count = 4
        var stores: [SQLiteStore] = []
        var services: [AgentSessionService] = []
        for index in 0..<count {
            let paths = AppPaths(
                home: tempHome.appendingPathComponent("concurrent-service-\(index)", isDirectory: true)
            )
            try paths.ensureLayout()
            let store = try SQLiteStore(path: database)
            stores.append(store)
            services.append(makeSessionService(paths: paths, store: store))
        }
        defer { stores.forEach { $0.close() } }

        let outcomes = LifecycleStartOutcomes()
        let clientID = ClientID("concurrent-start-client")
        let concurrentServices = services
        let workingDirectory = tempHome.path
        DispatchQueue.concurrentPerform(iterations: count) { index in
            do {
                let result = try concurrentServices[index].start(
                    agentID: "debug",
                    goal: "Concurrent goal \(index)",
                    clientID: clientID,
                    cwd: workingDirectory
                )
                outcomes.appendSuccess(try XCTUnwrap(result["session_id"] as? String))
            } catch {
                outcomes.appendFailure("\(error)")
            }
        }

        XCTAssertEqual(outcomes.failures, [])
        XCTAssertEqual(outcomes.sessionIDs.count, count)
        let sessions = try stores[0].sessionList().filter {
            $0.clientID == clientID && $0.status.isOpen
        }
        let openSession = try XCTUnwrap(sessions.only)
        let bindingBody = try XCTUnwrap(
            stores[0].memoryGet(key: "agent_active/\(clientID.rawValue)")
        )
        let binding = try JSONSupport.object(from: Data(bindingBody.utf8))
        XCTAssertEqual(binding["session_id"] as? String, openSession.id.rawValue)
        for sessionID in outcomes.sessionIDs {
            XCTAssertNotNil(try stores[0].memoryGet(key: "agent_run/\(sessionID)"))
        }
    }

    func testVersionFiveMigrationClosesDuplicateOpenSessionsBeforeUniqueIndex() throws {
        let database = databaseURL("agent-session-v5")
        try executeSQLite(
            """
            CREATE TABLE schema_version(version INTEGER NOT NULL);
            INSERT INTO schema_version(version) VALUES(5);
            CREATE TABLE agent_sessions(
                id TEXT PRIMARY KEY,
                agent_id TEXT NOT NULL,
                client_id TEXT,
                status TEXT NOT NULL,
                summary TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            INSERT INTO agent_sessions VALUES(
                'older','debug','duplicate-client','open',NULL,
                '2026-01-01T00:00:00Z','2026-01-01T00:00:00Z'
            );
            INSERT INTO agent_sessions VALUES(
                'newer','review','duplicate-client','running',NULL,
                '2026-01-01T00:00:01Z','2026-01-01T00:00:01Z'
            );
            INSERT INTO agent_sessions VALUES(
                'mismatch-older','debug','mismatch-client','open',NULL,
                '2026-01-01T00:00:00Z','2026-01-01T00:00:00Z'
            );
            INSERT INTO agent_sessions VALUES(
                'mismatch-newer','review','mismatch-client','open',NULL,
                '2026-01-01T00:00:01Z','2026-01-01T00:00:01Z'
            );
            CREATE TABLE memory_notes(
                key TEXT PRIMARY KEY,
                body TEXT NOT NULL,
                tags_json TEXT NOT NULL DEFAULT '[]',
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            INSERT INTO memory_notes VALUES(
                'agent_active/duplicate-client',
                '{"session_id":"older","agent_id":"debug"}',
                '["agent_active"]','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z'
            );
            INSERT INTO memory_notes VALUES(
                'agent_active/mismatch-client',
                '{"session_id":"missing-session","agent_id":"debug"}',
                '["agent_active"]','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z'
            );
            INSERT INTO memory_notes VALUES(
                'agent_active/orphan-client',
                '{"session_id":"orphan-session","agent_id":"debug"}',
                '["agent_active"]','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z'
            );
            INSERT INTO memory_notes VALUES(
                'agentXactive/nonmatching-sentinel',
                'must remain untouched',
                '[]','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z'
            );
            """,
            at: database
        )

        let store = try SQLiteStore(path: database)
        defer { store.close() }
        let sessions = try store.sessionList().filter { $0.clientID?.rawValue == "duplicate-client" }
        XCTAssertEqual(sessions.filter(\.status.isOpen).map(\.id.rawValue), ["older"])
        XCTAssertEqual(sessions.first { $0.id.rawValue == "newer" }?.status, .closed)
        XCTAssertTrue(
            try XCTUnwrap(store.memoryGet(key: "agent_active/duplicate-client"))
                .contains("\"session_id\":\"older\"")
        )
        let mismatchSessions = try store.sessionList().filter {
            $0.clientID?.rawValue == "mismatch-client"
        }
        XCTAssertEqual(
            mismatchSessions.filter(\.status.isOpen).map(\.id.rawValue),
            ["mismatch-newer"]
        )
        XCTAssertTrue(
            try XCTUnwrap(store.memoryGet(key: "agent_active/mismatch-client"))
                .contains("\"session_id\":\"mismatch-newer\"")
        )
        XCTAssertNil(try store.memoryGet(key: "agent_active/orphan-client"))
        XCTAssertEqual(
            try store.memoryGet(key: "agentXactive/nonmatching-sentinel"),
            "must remain untouched"
        )
        XCTAssertEqual(
            try sqliteInteger(database, "SELECT version FROM schema_version LIMIT 1;"),
            SQLiteStore.schemaVersion
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: tempHome.appendingPathComponent(
                    "agent-session-v5.pre-migration-v5.sqlite3"
                ).path
            )
        )
        XCTAssertThrowsError(
            try store.sessionStart(
                agentID: "explore",
                clientID: ClientID("duplicate-client")
            )
        )
    }

    func testAgentStartRollsBackSessionWhenBindingProjectionFails() throws {
        let paths = AppPaths(home: tempHome.appendingPathComponent("start-binding-failure"))
        try paths.ensureLayout()
        let store = try SQLiteStore(path: paths.storeSQLite)
        defer { store.close() }
        try executeSQLite(
            """
            CREATE TRIGGER reject_agent_binding
            BEFORE INSERT ON memory_notes
            WHEN NEW.key LIKE 'agent_active/%'
            BEGIN SELECT RAISE(ABORT, 'injected binding failure'); END;
            """,
            at: paths.storeSQLite
        )
        let service = makeSessionService(paths: paths, store: store)

        XCTAssertThrowsError(
            try service.start(
                agentID: "debug",
                goal: "Must be atomic",
                clientID: ClientID("binding-failure-client")
            )
        )
        XCTAssertTrue(try store.sessionList().isEmpty)
        XCTAssertNil(try store.memoryGet(key: "agent_active/binding-failure-client"))
        XCTAssertTrue(try store.memoryList(includeSystem: true).isEmpty)
    }

    func testAgentCompleteRollsBackCloseWhenBindingClearFails() throws {
        let paths = AppPaths(home: tempHome.appendingPathComponent("complete-binding-failure"))
        try paths.ensureLayout()
        let store = try SQLiteStore(path: paths.storeSQLite)
        defer { store.close() }
        let audit = AuditService(store: store, paths: paths)
        let service = AgentSessionService(
            store: store,
            catalog: AgentCatalog(paths: paths),
            audit: audit,
            diagnostics: DiagnosticLog(paths: paths)
        )
        let clientID = ClientID("complete-binding-client")
        let started = try service.start(
            agentID: "debug",
            goal: "Keep completion atomic",
            clientID: clientID
        )
        let sessionID = SessionID(try XCTUnwrap(started["session_id"] as? String))
        XCTAssertTrue(audit.flushAttempts(timeout: 3))
        try executeSQLite(
            """
            CREATE TRIGGER reject_agent_binding_delete
            BEFORE DELETE ON memory_notes
            WHEN OLD.key LIKE 'agent_active/%'
            BEGIN SELECT RAISE(ABORT, 'injected binding clear failure'); END;
            """,
            at: paths.storeSQLite
        )

        XCTAssertThrowsError(
            try service.complete(sessionID: sessionID, report: [:], clientID: clientID)
        )
        XCTAssertEqual(try store.sessionGet(id: sessionID)?.status, .open)
        XCTAssertNotNil(try store.memoryGet(key: "agent_active/\(clientID.rawValue)"))
    }

    func testAgentCompleteClearsCurrentOwnerAfterConcurrentReattach() throws {
        let database = databaseURL("complete-current-owner")
        let completingPaths = AppPaths(
            home: tempHome.appendingPathComponent("complete-current-owner-a")
        )
        let reattachingPaths = AppPaths(
            home: tempHome.appendingPathComponent("complete-current-owner-b")
        )
        try completingPaths.ensureLayout()
        try reattachingPaths.ensureLayout()
        let completingStore = try SQLiteStore(path: database)
        let reattachingStore = try SQLiteStore(path: database)
        defer {
            completingStore.close()
            reattachingStore.close()
        }

        let gate = SessionCompletionTransactionGate()
        let audit = AuditService(store: completingStore, paths: completingPaths)
        let completingService = AgentSessionService(
            store: completingStore,
            catalog: AgentCatalog(paths: completingPaths),
            audit: audit,
            diagnostics: DiagnosticLog(paths: completingPaths),
            beforeSessionCompletionCommitObserver: { _ in gate.pause() }
        )
        let reattachingService = makeSessionService(
            paths: reattachingPaths,
            store: reattachingStore
        )
        let originalClientID = ClientID("complete-owner-a")
        let currentClientID = ClientID("complete-owner-b")
        let started = try completingService.start(
            agentID: "debug",
            goal: "Close the transaction's current owner",
            clientID: originalClientID
        )
        let sessionID = SessionID(try XCTUnwrap(started["session_id"] as? String))
        XCTAssertTrue(audit.flushAttempts(timeout: 3))

        let completion = LifecycleStartOutcomes()
        let completionFinished = DispatchGroup()
        completionFinished.enter()
        DispatchQueue.global().async {
            defer { completionFinished.leave() }
            do {
                let result = try completingService.complete(
                    sessionID: sessionID,
                    report: [:],
                    clientID: originalClientID
                )
                if result["ok"] as? Bool == true {
                    completion.appendSuccess(sessionID.rawValue)
                } else {
                    completion.appendFailure("completion returned a non-success result")
                }
            } catch {
                completion.appendFailure("\(error)")
            }
        }
        XCTAssertEqual(gate.completionReached.wait(timeout: .now() + 2), .success)
        defer {
            gate.releaseCompletion.signal()
            _ = completionFinished.wait(timeout: .now() + 6)
        }

        XCTAssertTrue(
            try reattachingService.attach(
                sessionID: sessionID,
                clientID: currentClientID
            )
        )
        XCTAssertEqual(reattachingService.binding(for: currentClientID)?.sessionID, sessionID)
        XCTAssertNotNil(
            try reattachingStore.memoryGet(
                key: "agent_active/\(currentClientID.rawValue)"
            )
        )

        gate.releaseCompletion.signal()
        XCTAssertEqual(completionFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(completion.failures, [])
        XCTAssertEqual(completion.sessionIDs, [sessionID.rawValue])

        let closed = try XCTUnwrap(completingStore.sessionGet(id: sessionID))
        XCTAssertEqual(closed.status, .closed)
        XCTAssertEqual(closed.clientID, currentClientID)
        XCTAssertNil(
            try completingStore.memoryGet(
                key: "agent_active/\(originalClientID.rawValue)"
            )
        )
        XCTAssertNil(
            try completingStore.memoryGet(
                key: "agent_active/\(currentClientID.rawValue)"
            )
        )
        XCTAssertNil(completingService.binding(for: originalClientID))
        XCTAssertNil(reattachingService.binding(for: currentClientID))
        XCTAssertTrue(audit.flushAttempts(timeout: 3))
    }

    func testAgentLifecycleReturnsCommittedStateWhenAuditInsertFails() throws {
        let paths = AppPaths(home: tempHome.appendingPathComponent("audit-insert-failure"))
        try paths.ensureLayout()
        let store = try SQLiteStore(path: paths.storeSQLite)
        defer { store.close() }
        try executeSQLite(
            """
            CREATE TRIGGER reject_agent_audit
            BEFORE INSERT ON audit_events
            BEGIN SELECT RAISE(ABORT, 'injected audit failure'); END;
            """,
            at: paths.storeSQLite
        )
        let audit = AuditService(store: store, paths: paths)
        let service = AgentSessionService(
            store: store,
            catalog: AgentCatalog(paths: paths),
            audit: audit,
            diagnostics: DiagnosticLog(paths: paths)
        )
        let clientID = ClientID("audit-failure-client")

        let started = try service.start(
            agentID: "debug",
            goal: "Return committed start",
            clientID: clientID
        )
        let sessionID = SessionID(try XCTUnwrap(started["session_id"] as? String))
        XCTAssertEqual(try store.sessionGet(id: sessionID)?.status, .open)
        let completed = try service.complete(
            sessionID: sessionID,
            report: [:],
            clientID: clientID
        )
        XCTAssertEqual(completed["ok"] as? Bool, true)
        XCTAssertEqual(try store.sessionGet(id: sessionID)?.status, .closed)
        XCTAssertNil(try store.memoryGet(key: "agent_active/\(clientID.rawValue)"))
        XCTAssertTrue(audit.flushAttempts(timeout: 3))
        XCTAssertTrue(try audit.recent(limit: 10).isEmpty)
    }

    func testAuditMirrorFailureDoesNotConcealCommittedSQLiteEvent() throws {
        let paths = AppPaths(home: tempHome.appendingPathComponent("audit-mirror-failure"))
        try paths.ensureLayout()
        let store = try SQLiteStore(path: paths.storeSQLite)
        defer { store.close() }
        try FileManager.default.createDirectory(
            at: paths.auditJSONL,
            withIntermediateDirectories: false
        )
        let audit = AuditService(store: store, paths: paths)

        XCTAssertNoThrow(
            try audit.append(
                tool: "mirror_failure_fixture",
                status: "ok",
                clientID: "mirror-client",
                mutating: true
            )
        )
        XCTAssertEqual(try audit.recent(limit: 1).first?.tool, "mirror_failure_fixture")
    }

    func testStartDoesNotRunStaleMaintenanceAndReturnsCommittedSessionAfterCancellation() throws {
        let trigger = MutationTrigger(target: .session)
        let control = ToolCallCancellation(timeoutSeconds: 5)
        let clock = FixedClock(Date(timeIntervalSince1970: 1_700_000_000))
        let paths = AppPaths(home: tempHome.appendingPathComponent("stale-cancellation"))
        try paths.ensureLayout()
        let store = try SQLiteStore(
            path: paths.storeSQLite,
            clock: clock,
            postMigrationCommitObserver: nil,
            didMutationCommitObserver: { kind in
                if trigger.observe(kind) { control.cancel() }
            }
        )
        defer { store.close() }
        let stale = try store.sessionStart(
            agentID: "explore",
            clientID: ClientID("unrelated-stale-client")
        )
        clock.date = clock.date.addingTimeInterval(60)
        let service = AgentSessionService(
            store: store,
            catalog: AgentCatalog(paths: paths),
            audit: AuditService(store: store, paths: paths),
            diagnostics: DiagnosticLog(paths: paths),
            clock: clock,
            idleTTL: 1
        )
        trigger.arm()

        let started = try service.start(
            agentID: "debug",
            goal: "Return the requested committed session",
            clientID: ClientID("requested-client"),
            cancellation: control
        )
        let requestedID = SessionID(try XCTUnwrap(started["session_id"] as? String))
        XCTAssertTrue(control.isCancelled)
        XCTAssertEqual(try store.sessionGet(id: stale.id)?.status, .open)
        XCTAssertEqual(try store.sessionGet(id: requestedID)?.status, .open)
        XCTAssertNotNil(try store.memoryGet(key: "agent_active/requested-client"))
    }

    func testStalePruneUsesTransactionalCutoffAndClearsOnlyMatchingBindings() throws {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_700_000_000))
        let paths = AppPaths(home: tempHome.appendingPathComponent("stale-prune-atomic"))
        try paths.ensureLayout()
        let store = try SQLiteStore(path: paths.storeSQLite, clock: clock)
        defer { store.close() }
        let service = AgentSessionService(
            store: store,
            catalog: AgentCatalog(paths: paths),
            audit: AuditService(store: store, paths: paths),
            diagnostics: DiagnosticLog(paths: paths),
            clock: clock,
            idleTTL: 1
        )
        let matchedClient = ClientID("stale-matched-client")
        let mismatchedClient = ClientID("stale-mismatched-client")
        let matched = try service.start(
            agentID: "debug",
            goal: "Matched stale binding",
            clientID: matchedClient
        )
        let mismatched = try service.start(
            agentID: "review",
            goal: "Mismatched stale binding",
            clientID: mismatchedClient
        )
        let matchedID = SessionID(try XCTUnwrap(matched["session_id"] as? String))
        let mismatchedID = SessionID(try XCTUnwrap(mismatched["session_id"] as? String))
        XCTAssertEqual(service.memoryBindingCount, 2)

        clock.date = clock.date.addingTimeInterval(60)
        let freshClient = ClientID("fresh-client")
        let fresh = try store.sessionStart(agentID: "explore", clientID: freshClient)
        let mismatchedBody = try JSONSupport.string(from: [
            "session_id": fresh.id.rawValue,
            "agent_id": fresh.agentID,
        ])
        try store.memorySet(
            key: "agent_active/\(mismatchedClient.rawValue)",
            body: mismatchedBody,
            tags: ["agent_active", fresh.agentID]
        )

        XCTAssertTrue(try service.pruneStale(cancellation: nil))
        XCTAssertEqual(try store.sessionGet(id: matchedID)?.status, .closed)
        XCTAssertEqual(try store.sessionGet(id: mismatchedID)?.status, .closed)
        XCTAssertEqual(try store.sessionGet(id: fresh.id)?.status, .open)
        XCTAssertNil(try store.memoryGet(key: "agent_active/\(matchedClient.rawValue)"))
        XCTAssertEqual(
            try store.memoryGet(key: "agent_active/\(mismatchedClient.rawValue)"),
            mismatchedBody
        )
        XCTAssertEqual(service.memoryBindingCount, 0)
    }

    func testStalePruneReturnsCommittedResultAfterCommitCancellation() throws {
        let trigger = MutationTrigger(target: .session)
        let control = ToolCallCancellation(timeoutSeconds: 5)
        let clock = FixedClock(Date(timeIntervalSince1970: 1_700_000_000))
        let paths = AppPaths(home: tempHome.appendingPathComponent("stale-prune-postcommit"))
        try paths.ensureLayout()
        let store = try SQLiteStore(
            path: paths.storeSQLite,
            clock: clock,
            postMigrationCommitObserver: nil,
            didMutationCommitObserver: { kind in
                if trigger.observe(kind) { control.cancel() }
            }
        )
        defer { store.close() }
        let service = AgentSessionService(
            store: store,
            catalog: AgentCatalog(paths: paths),
            audit: AuditService(store: store, paths: paths),
            diagnostics: DiagnosticLog(paths: paths),
            clock: clock,
            idleTTL: 1
        )
        let clientID = ClientID("stale-postcommit-client")
        let started = try service.start(
            agentID: "debug",
            goal: "Prune atomically",
            clientID: clientID
        )
        let sessionID = SessionID(try XCTUnwrap(started["session_id"] as? String))
        clock.date = clock.date.addingTimeInterval(60)
        trigger.arm()

        XCTAssertTrue(try service.pruneStale(cancellation: control))
        XCTAssertTrue(control.isCancelled)
        XCTAssertEqual(try store.sessionGet(id: sessionID)?.status, .closed)
        XCTAssertNil(try store.memoryGet(key: "agent_active/\(clientID.rawValue)"))
        XCTAssertEqual(service.memoryBindingCount, 0)
    }

    func testLifecycleAuditAttemptDoesNotBlockCommittedStart() throws {
        let lifecyclePaths = AppPaths(home: tempHome.appendingPathComponent("nonblocking-lifecycle"))
        let auditPaths = AppPaths(home: tempHome.appendingPathComponent("blocked-audit"))
        try lifecyclePaths.ensureLayout()
        try auditPaths.ensureLayout()
        let lifecycleStore = try SQLiteStore(path: lifecyclePaths.storeSQLite)
        let auditStore = try SQLiteStore(path: auditPaths.storeSQLite)
        let audit = AuditService(store: auditStore, paths: auditPaths)
        defer {
            _ = audit.shutdownAttempts(timeout: 3)
            lifecycleStore.close()
            auditStore.close()
        }
        let locker = try openWriteLock(auditPaths.storeSQLite)
        let service = AgentSessionService(
            store: lifecycleStore,
            catalog: AgentCatalog(paths: lifecyclePaths),
            audit: audit,
            diagnostics: DiagnosticLog(paths: lifecyclePaths)
        )

        let startedAt = Date()
        let result = try service.start(
            agentID: "debug",
            goal: "Return without waiting for audit storage",
            clientID: ClientID("nonblocking-audit-client")
        )
        let elapsed = Date().timeIntervalSince(startedAt)
        XCTAssertNotNil(result["session_id"] as? String)
        XCTAssertLessThan(elapsed, 0.75)

        closeWriteLock(locker)
        XCTAssertTrue(audit.flushAttempts(timeout: 3))
        XCTAssertEqual(try audit.recent(limit: 1).first?.tool, "agent_run_start")
    }

    func testRehydrateDoesNotDeleteNewerBindingFromAnotherStore() throws {
        let database = databaseURL("rehydrate-newer-binding")
        let firstPaths = AppPaths(home: tempHome.appendingPathComponent("rehydrate-first"))
        let secondPaths = AppPaths(home: tempHome.appendingPathComponent("rehydrate-second"))
        try firstPaths.ensureLayout()
        try secondPaths.ensureLayout()
        let firstStore = try SQLiteStore(path: database)
        let secondStore = try SQLiteStore(path: database)
        defer {
            firstStore.close()
            secondStore.close()
        }
        let firstService = makeSessionService(paths: firstPaths, store: firstStore)
        let secondService = makeSessionService(paths: secondPaths, store: secondStore)
        let clientID = ClientID("rehydrate-race-client")
        let first = try firstService.start(
            agentID: "debug",
            goal: "Older binding",
            clientID: clientID
        )
        let firstID = try XCTUnwrap(first["session_id"] as? String)
        let second = try secondService.start(
            agentID: "review",
            goal: "Newer binding",
            clientID: clientID
        )
        let secondID = try XCTUnwrap(second["session_id"] as? String)

        let rehydrated = try XCTUnwrap(firstService.binding(for: clientID))
        XCTAssertEqual(rehydrated.sessionID.rawValue, secondID)
        XCTAssertEqual(try firstStore.sessionGet(id: SessionID(firstID))?.status, .closed)
        XCTAssertTrue(
            try XCTUnwrap(firstStore.memoryGet(key: "agent_active/\(clientID.rawValue)"))
                .contains(secondID)
        )
    }

    func testFallbackBindingInstallCannotOverwriteConcurrentReplacement() throws {
        let database = databaseURL("fallback-binding-cas")
        let firstStore = try SQLiteStore(path: database)
        let secondStore = try SQLiteStore(path: database)
        defer {
            firstStore.close()
            secondStore.close()
        }
        let clientID = ClientID("fallback-cas-client")
        let selected = try firstStore.sessionStart(agentID: "debug", clientID: clientID)
        let secondPaths = AppPaths(home: tempHome.appendingPathComponent("fallback-cas-second"))
        try secondPaths.ensureLayout()
        let secondService = makeSessionService(paths: secondPaths, store: secondStore)
        let replacement = try secondService.start(
            agentID: "review",
            goal: "Concurrent replacement",
            clientID: clientID
        )
        let replacementID = try XCTUnwrap(replacement["session_id"] as? String)
        let staleBody = try JSONSupport.string(from: [
            "session_id": selected.id.rawValue,
            "agent_id": selected.agentID,
        ])

        XCTAssertFalse(
            try firstStore.sessionInstallBindingIfUnchanged(
                sessionID: selected.id,
                clientID: clientID,
                expectedCurrentSessionID: nil,
                bindingBody: staleBody,
                agentID: selected.agentID
            )
        )
        XCTAssertTrue(
            try XCTUnwrap(firstStore.memoryGet(key: "agent_active/\(clientID.rawValue)"))
                .contains(replacementID)
        )
    }

    func testRehydrateConditionallyReplacesMalformedBinding() throws {
        let paths = AppPaths(home: tempHome.appendingPathComponent("rehydrate-malformed"))
        try paths.ensureLayout()
        let store = try SQLiteStore(path: paths.storeSQLite)
        defer { store.close() }
        let clientID = ClientID("malformed-binding-client")
        let session = try store.sessionStart(agentID: "debug", clientID: clientID)
        try store.memorySet(
            key: "agent_active/\(clientID.rawValue)",
            body: "{malformed",
            tags: ["agent_active"]
        )
        let service = makeSessionService(paths: paths, store: store)

        let binding = try XCTUnwrap(service.rehydrate(clientID: clientID))
        XCTAssertEqual(binding.sessionID, session.id)
        XCTAssertTrue(
            try XCTUnwrap(store.memoryGet(key: "agent_active/\(clientID.rawValue)"))
                .contains(session.id.rawValue)
        )
    }

    func testConcurrentStartCacheInstallCannotInvertCommitOrder() throws {
        let paths = AppPaths(home: tempHome.appendingPathComponent("cache-install-order"))
        try paths.ensureLayout()
        let store = try SQLiteStore(path: paths.storeSQLite)
        defer { store.close() }
        let gate = FirstCacheInstallGate()
        let service = AgentSessionService(
            store: store,
            catalog: AgentCatalog(paths: paths),
            audit: AuditService(store: store, paths: paths),
            diagnostics: DiagnosticLog(paths: paths),
            beforeBindingCacheInstallObserver: { _ in gate.observe() }
        )
        let clientID = ClientID("cache-order-client")
        let firstOutcome = LifecycleStartOutcomes()
        let firstFinished = DispatchGroup()
        firstFinished.enter()
        DispatchQueue.global().async {
            defer { firstFinished.leave() }
            do {
                let result = try service.start(
                    agentID: "debug",
                    goal: "First committed session",
                    clientID: clientID
                )
                firstOutcome.appendSuccess(
                    try XCTUnwrap(result["session_id"] as? String)
                )
            } catch {
                firstOutcome.appendFailure("\(error)")
            }
        }
        XCTAssertEqual(gate.firstInstallReached.wait(timeout: .now() + 2), .success)

        let second = try service.start(
            agentID: "review",
            goal: "Second committed session",
            clientID: clientID
        )
        let secondID = try XCTUnwrap(second["session_id"] as? String)
        gate.releaseFirstInstall.signal()
        XCTAssertEqual(firstFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(firstOutcome.failures, [])

        let binding = try XCTUnwrap(service.binding(for: clientID))
        XCTAssertEqual(binding.sessionID.rawValue, secondID)
        XCTAssertTrue(
            try XCTUnwrap(store.memoryGet(key: "agent_active/\(clientID.rawValue)"))
                .contains(secondID)
        )
    }

    func testHandoffCancellationBeforeCommitRollsBackPacketAndPointers() throws {
        let trigger = MutationTrigger(target: .handoff)
        let control = ToolCallCancellation(timeoutSeconds: 5)
        let store = try SQLiteStore(
            path: databaseURL("handoff-precommit"),
            postMigrationCommitObserver: nil,
            beforeMutationCommitObserver: { kind in
                if trigger.observe(kind) { control.cancel() }
            }
        )
        defer { store.close() }
        let packet = HandoffPacket(
            id: "handoff-precommit-id",
            resumeReady: true,
            clientID: "handoff-precommit-client",
            goal: "Rollback the packet and both pointers"
        )
        trigger.arm()

        XCTAssertThrowsError(try store.handoffUpsert(packet, cancellation: control)) { error in
            XCTAssertTrue(error is CancellationError, "unexpected error: \(error)")
        }

        XCTAssertNil(try store.handoffGet(id: packet.id))
        XCTAssertNil(try store.memoryGet(key: "continuity/latest"))
        XCTAssertNil(try store.memoryGet(key: "continuity/resume_ready"))
    }

    func testContinuityCheckpointReturnsCommittedResultAfterCommitCancellation() throws {
        let trigger = MutationTrigger(target: .handoff)
        let control = ToolCallCancellation(timeoutSeconds: 5)
        let paths = AppPaths(home: tempHome.appendingPathComponent("continuity-service", isDirectory: true))
        try paths.ensureLayout()
        let store = try SQLiteStore(
            path: paths.storeSQLite,
            postMigrationCommitObserver: nil,
            didMutationCommitObserver: { kind in
                if trigger.observe(kind) { control.cancel() }
            }
        )
        defer { store.close() }
        let diagnostics = DiagnosticLog(paths: paths)
        let sessions = makeSessionService(paths: paths, store: store, diagnostics: diagnostics)
        let continuity = ContextContinuityService(
            paths: paths,
            store: store,
            sessions: sessions,
            diagnostics: diagnostics
        )
        trigger.arm()

        let result = try continuity.checkpoint(
            arguments: ["goal": "Return the durable handoff"],
            clientID: ClientID("handoff-postcommit-client"),
            cancellation: control
        )

        let handoffID = try XCTUnwrap(result["handoff_id"] as? String)
        XCTAssertTrue(control.isCancelled)
        XCTAssertNotNil(try store.handoffGet(id: handoffID))
        XCTAssertEqual(try store.memoryGet(key: "continuity/latest"), handoffID)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: paths.memoryHandoffsDir.appendingPathComponent("\(handoffID).json").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: paths.memoryHandoffsDir.appendingPathComponent("LATEST").path
            )
        )
    }

    func testContinuityServiceMutexHonorsDeadlineWithoutSecondWrite() async throws {
        let trigger = MutationTrigger(target: .handoff)
        let mutationReached = DispatchSemaphore(value: 0)
        let releaseMutation = DispatchSemaphore(value: 0)
        let paths = AppPaths(home: tempHome.appendingPathComponent("continuity-lock", isDirectory: true))
        try paths.ensureLayout()
        let store = try SQLiteStore(
            path: paths.storeSQLite,
            postMigrationCommitObserver: nil,
            beforeMutationCommitObserver: { kind in
                guard trigger.observe(kind) else { return }
                mutationReached.signal()
                guard releaseMutation.wait(timeout: .now() + 2) == .success else {
                    throw StoreError.execFailed("timed out waiting to release continuity test mutation")
                }
            }
        )
        defer { store.close() }
        let diagnostics = DiagnosticLog(paths: paths)
        let continuity = ContextContinuityService(
            paths: paths,
            store: store,
            sessions: makeSessionService(paths: paths, store: store, diagnostics: diagnostics),
            diagnostics: diagnostics
        )
        trigger.arm()

        let first = Task.detached {
            let result = try continuity.checkpoint(
                arguments: ["goal": "First serialized checkpoint"],
                clientID: ClientID("continuity-lock-first")
            )
            return result["handoff_id"] as? String
        }
        XCTAssertEqual(mutationReached.wait(timeout: .now() + 1), .success)

        expectDeadlineWithinOneSecond {
            _ = try continuity.checkpoint(
                arguments: ["goal": "Must not be written"],
                clientID: ClientID("continuity-lock-second"),
                cancellation: ToolCallCancellation(timeoutSeconds: 0.1)
            )
        }
        releaseMutation.signal()
        let firstHandoffID = try await first.value

        XCTAssertNotNil(firstHandoffID)
        let packets = try store.handoffList()
        XCTAssertEqual(packets.count, 1)
        XCTAssertEqual(packets.first?.goal, "First serialized checkpoint")
    }

    func testPresenceCancellationBoundariesPreserveAtomicity() throws {
        let precommitTrigger = MutationTrigger(target: .presence)
        let precommitControl = ToolCallCancellation(timeoutSeconds: 5)
        let precommitStore = try SQLiteStore(
            path: databaseURL("presence-precommit"),
            postMigrationCommitObserver: nil,
            beforeMutationCommitObserver: { kind in
                if precommitTrigger.observe(kind) { precommitControl.cancel() }
            }
        )
        defer { precommitStore.close() }
        try precommitStore.presenceUpsert(
            clientID: "presence-one",
            hostKind: "test",
            pid: 0,
            cwd: tempHome.path
        )
        try precommitStore.presenceUpsert(
            clientID: "presence-two",
            hostKind: "test",
            pid: 0,
            cwd: tempHome.path
        )
        precommitTrigger.arm()

        XCTAssertThrowsError(
            try precommitStore.presencePrune(
                maxAgeSec: -1,
                cancellation: precommitControl
            )
        ) { error in
            XCTAssertTrue(error is CancellationError, "unexpected error: \(error)")
        }
        XCTAssertEqual(try precommitStore.presenceRecords().count, 2)

        let postcommitTrigger = MutationTrigger(target: .presence)
        let postcommitControl = ToolCallCancellation(timeoutSeconds: 5)
        let postcommitStore = try SQLiteStore(
            path: databaseURL("presence-postcommit"),
            postMigrationCommitObserver: nil,
            didMutationCommitObserver: { kind in
                if postcommitTrigger.observe(kind) { postcommitControl.cancel() }
            }
        )
        defer { postcommitStore.close() }
        postcommitTrigger.arm()

        try postcommitStore.presenceUpsert(
            clientID: "presence-committed",
            hostKind: "test",
            pid: 0,
            cwd: tempHome.path,
            cancellation: postcommitControl
        )

        XCTAssertTrue(postcommitControl.isCancelled)
        XCTAssertEqual(try postcommitStore.presenceRecords().map(\.clientID), ["presence-committed"])
    }

    private func databaseURL(_ name: String) -> URL {
        tempHome.appendingPathComponent("\(name).sqlite3")
    }

    private func makeSessionService(
        paths: AppPaths,
        store: SQLiteStore,
        diagnostics: DiagnosticLog? = nil
    ) -> AgentSessionService {
        AgentSessionService(
            store: store,
            catalog: AgentCatalog(paths: paths),
            audit: AuditService(store: store, paths: paths),
            diagnostics: diagnostics ?? DiagnosticLog(paths: paths)
        )
    }

    private func openWriteLock(_ databaseURL: URL) throws -> OpaquePointer {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        let opened = try XCTUnwrap(database)
        XCTAssertEqual(sqlite3_exec(opened, "BEGIN IMMEDIATE;", nil, nil, nil), SQLITE_OK)
        return opened
    }

    private func rollbackWriteLock(_ database: OpaquePointer) {
        _ = sqlite3_exec(database, "ROLLBACK;", nil, nil, nil)
    }

    private func closeWriteLock(_ database: OpaquePointer) {
        rollbackWriteLock(database)
        sqlite3_close(database)
    }

    private func executeSQLite(_ sql: String, at databaseURL: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
            throw StoreError.openFailed("could not open lifecycle test database")
        }
        defer { sqlite3_close(database) }
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        defer { if let message { sqlite3_free(message) } }
        guard result == SQLITE_OK else {
            throw StoreError.execFailed(
                message.map { String(cString: $0) } ?? "lifecycle test SQL failed"
            )
        }
    }

    private func sqliteInteger(_ databaseURL: URL, _ sql: String) throws -> Int {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
            throw StoreError.openFailed("could not open lifecycle test database")
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw StoreError.execFailed("could not prepare lifecycle test query")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw StoreError.execFailed("lifecycle test query returned no row")
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func expectDeadlineWithinOneSecond(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () throws -> Void
    ) {
        let startedAt = Date()
        do {
            try operation()
            XCTFail("deadline-bound operation returned success", file: file, line: line)
        } catch is ToolCallDeadlineExceeded {
            // Expected.
        } catch {
            XCTFail("unexpected deadline error: \(error)", file: file, line: line)
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1, file: file, line: line)
    }
}

private final class LifecycleStartOutcomes: @unchecked Sendable {
    private let lock = NSLock()
    private var storedSessionIDs: [String] = []
    private var storedFailures: [String] = []

    func appendSuccess(_ sessionID: String) {
        lock.lock()
        storedSessionIDs.append(sessionID)
        lock.unlock()
    }

    func appendFailure(_ failure: String) {
        lock.lock()
        storedFailures.append(failure)
        lock.unlock()
    }

    var sessionIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedSessionIDs
    }

    var failures: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedFailures
    }
}

private final class FirstCacheInstallGate: @unchecked Sendable {
    let firstInstallReached = DispatchSemaphore(value: 0)
    let releaseFirstInstall = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var blockedFirst = false

    func observe() {
        lock.lock()
        guard !blockedFirst else {
            lock.unlock()
            return
        }
        blockedFirst = true
        lock.unlock()
        firstInstallReached.signal()
        _ = releaseFirstInstall.wait(timeout: .now() + 5)
    }
}

private final class SessionCompletionTransactionGate: @unchecked Sendable {
    let completionReached = DispatchSemaphore(value: 0)
    let releaseCompletion = DispatchSemaphore(value: 0)

    func pause() {
        completionReached.signal()
        _ = releaseCompletion.wait(timeout: .now() + 5)
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}

private final class MutationTrigger: @unchecked Sendable {
    private let lock = NSLock()
    private let target: SQLiteStoreMutationKind
    private var remainingMatches = 0

    init(target: SQLiteStoreMutationKind) {
        self.target = target
    }

    func arm(onMatch match: Int = 1) {
        lock.lock()
        remainingMatches = max(match, 1)
        lock.unlock()
    }

    func observe(_ kind: SQLiteStoreMutationKind) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard kind == target, remainingMatches > 0 else { return false }
        remainingMatches -= 1
        return remainingMatches == 0
    }
}
