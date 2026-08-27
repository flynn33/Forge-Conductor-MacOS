// ProjectMemoryTests.swift
// Verifies project isolation, durability, conformance, migration safety, and bounds.

import XCTest
import SQLite3
import Darwin
@testable import ForgeConductorCore

final class ProjectMemoryTests: XCTestCase {
    private actor InitializationGate {
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

    private var home: URL!
    private var projectA: URL!
    private var projectB: URL!

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-project-memory-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        projectA = root.appendingPathComponent("project-a", isDirectory: true)
        projectB = root.appendingPathComponent("project-b", isDirectory: true)
        for directory in [home!, projectA!, projectB!] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    func testToolConformanceIsAdditiveAndInitializeAdvertisesCapabilities() throws {
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let names = Set(app.tools.toolNames)
        XCTAssertTrue(Set(ProjectMemoryToolPack.names).isSubset(of: names))
        XCTAssertTrue(Set(["memory_set", "memory_get", "memory_list", "memory_delete", "memory_search"]).isSubset(of: names))

        let server = MCPServer(app: app, clientID: ClientID("project-memory-conformance"))
        let initialize = try XCTUnwrap(server.handle([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-11-25"],
        ]))
        let result = try XCTUnwrap(initialize["result"] as? [String: Any])
        let capabilities = try XCTUnwrap(result["capabilities"] as? [String: Any])
        let memory = try XCTUnwrap(capabilities["projectMemory"] as? [String: Any])
        XCTAssertEqual(memory["schemaVersion"] as? Int, ProjectMemoryRepository.schemaVersion)

        let tools = try XCTUnwrap(server.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/list"]))
        let toolResult = try XCTUnwrap(tools["result"] as? [String: Any])
        let descriptors = toolResult["tools"] as? [[String: Any]] ?? []
        let projectDescriptors = descriptors.filter { ($0["name"] as? String)?.hasPrefix("project_memory.") == true }
        XCTAssertEqual(projectDescriptors.count, ProjectMemoryToolPack.names.count)
        XCTAssertTrue(projectDescriptors.allSatisfy { ($0["inputSchema"] as? [String: Any])?["type"] as? String == "object" })

        let call = try XCTUnwrap(server.handle([
            "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": ["name": "project_memory.initialize", "arguments": ["project_path": projectA.path]],
        ]))
        let callResult = try XCTUnwrap(call["result"] as? [String: Any])
        XCTAssertEqual(callResult["isError"] as? Bool, false)
        let structured = try XCTUnwrap(callResult["structuredContent"] as? [String: Any])
        XCTAssertNotNil(structured["project_id"] as? String)
    }

    func testProjectIsolationRedactionDeduplicationAndRestartDurability() throws {
        var app: ForgeApp? = try ForgeApp.bootstrap(home: home)
        let idA = try initialize(app!, project: projectA)
        let clientB = ClientID("project-memory-test-b")
        let idB = try initialize(app!, project: projectB, clientID: clientB)
        XCTAssertNotEqual(idA, idB)

        let write: [String: Any] = [
            "project_id": idA, "kind": "decision", "title": "Release path",
            "summary": "Ship from branch with api_key=super-secret-value",
            "body": "Authorization: Bearer abcdefghijklmnopqrstuvwxyz", // Example credential fixture.
            "tags": ["Release", "release"], "idempotency_key": "decision-release-v1",
        ]
        let first = try call(app!, "project_memory.remember", write)
        XCTAssertEqual(first["disposition"] as? String, "inserted")
        let duplicate = try call(app!, "project_memory.remember", write)
        XCTAssertEqual(duplicate["disposition"] as? String, "deduplicated")
        let recordID = try XCTUnwrap(first["record_id"] as? String)

        let inA = try call(app!, "project_memory.get", ["project_id": idA, "id": recordID, "include_body": true])
        let recordA = try XCTUnwrap((inA["records"] as? [[String: Any]])?.first)
        XCTAssertTrue((recordA["summary"] as? String)?.contains("<redacted>") == true)
        XCTAssertTrue((recordA["body"] as? String)?.contains("<redacted>") == true)
        XCTAssertFalse((recordA["summary"] as? String)?.contains("super-secret-value") == true)

        let inB = try call(
            app!,
            "project_memory.search",
            ["project_id": idB, "query": "Release"],
            clientID: clientB
        )
        XCTAssertEqual(inB["count"] as? Int, 0)

        app?.shutdown()
        app = nil
        app = try ForgeApp.bootstrap(home: home)
        defer { app?.shutdown() }
        let reopenedA = try initialize(app!, project: projectA)
        XCTAssertEqual(reopenedA, idA)
        let durable = try call(app!, "project_memory.get", ["project_id": idA, "id": recordID, "include_body": true])
        XCTAssertEqual(durable["count"] as? Int, 1)
    }

    func testBatchPaginationUpdateConflictLinkAndTombstone() throws {
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let projectID = try initialize(app, project: projectA)
        let items: [[String: Any]] = (0..<6).map { index in
            [
                "kind": index == 0 ? "decision" : "fact",
                "title": "Memory \(index)", "summary": "bounded search payload item \(index)",
                "tags": [index.isMultiple(of: 2) ? "even" : "odd"],
                "importance": Double(index) / 10,
            ]
        }
        let batch = try call(app, "project_memory.remember_batch", ["project_id": projectID, "items": items])
        XCTAssertEqual(batch["count"] as? Int, 6)
        let results = batch["results"] as? [[String: Any]] ?? []
        let firstID = try XCTUnwrap(results.first?["record_id"] as? String)
        let secondID = try XCTUnwrap(results.dropFirst().first?["record_id"] as? String)

        let page1 = try call(app, "project_memory.search", [
            "project_id": projectID, "query": "bounded", "limit": 2,
            "maximum_response_bytes": 4096,
        ])
        XCTAssertEqual(page1["count"] as? Int, 2)
        XCTAssertEqual(page1["truncated"] as? Bool, true)
        let cursor = try XCTUnwrap(page1["next_cursor"] as? String)
        let page2 = try call(app, "project_memory.search", [
            "project_id": projectID, "query": "bounded", "limit": 2, "cursor": cursor,
        ])
        XCTAssertEqual(page2["count"] as? Int, 2)
        XCTAssertNotEqual(
            (page1["records"] as? [[String: Any]])?.first?["id"] as? String,
            (page2["records"] as? [[String: Any]])?.first?["id"] as? String
        )

        let updated = try call(app, "project_memory.update", [
            "project_id": projectID, "id": firstID, "expected_version": 1,
            "summary": "revised bounded summary",
        ])
        XCTAssertEqual(((updated["record"] as? [String: Any])?["version"] as? Int), 2)
        let conflict = try app.tools.call(
            name: "project_memory.update",
            arguments: ["project_id": projectID, "id": firstID, "expected_version": 1, "title": "stale"],
            clientID: ClientID("project-memory-test")
        )
        XCTAssertFalse(conflict.ok)
        XCTAssertEqual(conflict.payload["code"] as? String, "conflict")

        let linked = try call(app, "project_memory.link", [
            "project_id": projectID, "source_id": firstID, "target_id": secondID, "relation": "supersedes",
        ])
        XCTAssertEqual(linked["disposition"] as? String, "inserted")
        let linkedAgain = try call(app, "project_memory.link", [
            "project_id": projectID, "source_id": firstID, "target_id": secondID, "relation": "supersedes",
        ])
        XCTAssertEqual(linkedAgain["disposition"] as? String, "deduplicated")

        let forgotten = try call(app, "project_memory.forget", ["project_id": projectID, "id": secondID])
        XCTAssertEqual(forgotten["disposition"] as? String, "tombstoned")
        let missing = try call(app, "project_memory.get", ["project_id": projectID, "id": secondID])
        XCTAssertEqual(missing["count"] as? Int, 0)
    }

    func testPrivateKeyRejectedPayloadBoundsAndCacheBound() throws {
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let projectID = try initialize(app, project: projectA)
        let rejected = try app.tools.call(
            name: "project_memory.remember",
            arguments: [
                "project_id": projectID, "kind": "fact", "title": "key", "summary": "contains key",
                "body": "-----BEGIN PRIVATE KEY-----\nnot accepted", // Example private-key fixture.
            ], clientID: ClientID("project-memory-test")
        )
        XCTAssertFalse(rejected.ok)
        XCTAssertEqual(rejected.payload["code"] as? String, "redaction_rejected")

        let oversized = try app.tools.call(
            name: "project_memory.remember",
            arguments: [
                "project_id": projectID, "kind": "fact", "title": String(repeating: "x", count: 513),
                "summary": "too large",
            ], clientID: ClientID("project-memory-test")
        )
        XCTAssertFalse(oversized.ok)
        XCTAssertEqual(oversized.payload["code"] as? String, "payload_too_large")

        for index in 0..<12 {
            let directory = home.deletingLastPathComponent().appendingPathComponent("cache-project-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            _ = try initialize(
                app,
                project: directory,
                clientID: ClientID("project-memory-cache-\(index)")
            )
        }
        XCTAssertLessThanOrEqual(app.projectMemory.openRepositoryCount, app.projectMemory.limits.maximumOpenProjects)
    }

    func testIntegrityVersionFailurePreservesDatabaseAndExportChecksumIsVerified() throws {
        var app: ForgeApp? = try ForgeApp.bootstrap(home: home)
        let projectID = try initialize(app!, project: projectA)
        _ = try call(app!, "project_memory.remember", [
            "project_id": projectID, "kind": "constraint", "title": "Preserve", "summary": "Never delete on migration failure",
        ])
        let exported = try call(app!, "project_memory.export", ["project_id": projectID])
        let artifactPath = try XCTUnwrap(exported["artifact"] as? String)
        let preview = try call(app!, "project_memory.import", ["project_id": projectID, "artifact": artifactPath, "preview": true])
        XCTAssertEqual(preview["preview"] as? Bool, true)

        var payload = try JSONSupport.object(from: Data(contentsOf: URL(fileURLWithPath: artifactPath)))
        payload["checksum"] = String(repeating: "0", count: 64)
        try JSONSupport.data(from: payload).write(to: URL(fileURLWithPath: artifactPath), options: .atomic)
        let tampered = try app!.tools.call(
            name: "project_memory.import",
            arguments: ["project_id": projectID, "artifact": artifactPath, "preview": true],
            clientID: ClientID("project-memory-test")
        )
        XCTAssertFalse(tampered.ok)
        XCTAssertEqual(tampered.payload["code"] as? String, "integrity_failure")

        app?.shutdown(); app = nil
        let database = home.appendingPathComponent("Projects/\(projectID)/memory.sqlite3")
        let before = try Data(contentsOf: database)
        try setUserVersion(database, version: 99)
        let modified = try Data(contentsOf: database)
        app = try ForgeApp.bootstrap(home: home)
        let failed = try app!.tools.call(
            name: "project_memory.initialize",
            arguments: ["project_path": projectA.path],
            clientID: ClientID("project-memory-version")
        )
        XCTAssertFalse(failed.ok)
        XCTAssertEqual(failed.payload["code"] as? String, "unsupported_version")
        XCTAssertEqual(try Data(contentsOf: database), modified)
        XCTAssertNotEqual(before, modified)
        app?.shutdown()
    }

    func testImportRejectsSpecialFileWithoutBlockingPastDeadline() throws {
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let projectID = try initialize(app, project: projectA)
        let exports = home.appendingPathComponent(
            "Projects/\(projectID)/exports",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        let fifo = exports.appendingPathComponent("blocked-import.fifo")
        XCTAssertEqual(mkfifo(fifo.path, S_IRUSR | S_IWUSR), 0)

        let startedAt = Date()
        let result = try app.tools.call(
            name: "project_memory.import",
            arguments: [
                "project_id": projectID,
                "artifact": fifo.path,
                "preview": true,
                "deadline_ms": 100,
            ],
            clientID: ClientID("project-memory-test")
        )

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.payload["code"] as? String, "invalid_request")
    }

    func testNonemptyUnversionedDatabaseFailsClosedWithoutMutatingDatabase() throws {
        let projectID = UUID().uuidString.lowercased()
        let directory = home.appendingPathComponent("project-memory-unversioned", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("memory.sqlite3")
        try createUnversionedProjectMemoryFixture(at: databaseURL)
        let originalBytes = try Data(contentsOf: databaseURL)

        XCTAssertThrowsError(
            try ProjectMemoryRepository(
                projectID: projectID,
                directory: directory,
                enableFTS5: false
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("unversioned SQLite database is not empty"),
                "unexpected error: \(error)"
            )
        }
        XCTAssertEqual(try Data(contentsOf: databaseURL), originalBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path + "-shm"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path + "-journal"))
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .contains { $0.hasPrefix("memory.corrupt-") }
        )

        let freshDirectory = home.appendingPathComponent("project-memory-fresh", isDirectory: true)
        let fresh = try ProjectMemoryRepository(
            projectID: UUID().uuidString.lowercased(),
            directory: freshDirectory,
            enableFTS5: false
        )
        XCTAssertEqual(
            try fresh.status()["schema_version"] as? Int,
            ProjectMemoryRepository.schemaVersion
        )
        fresh.close()
    }

    func testVersionOneDatabaseMigratesPopulatedDataReopensAndRerunsIdempotently() throws {
        let projectID = UUID().uuidString.lowercased()
        let recordID = UUID().uuidString.lowercased()
        let handoffID = UUID().uuidString.lowercased()
        let operationID = UUID().uuidString.lowercased()
        let timestamp = "2026-01-03T04:05:06Z"
        let directory = home.appendingPathComponent("project-memory-v1", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("memory.sqlite3")
        let legacyHandoff = try ContinuityHandoff(
            handoffID: handoffID,
            operationID: operationID,
            createdAt: timestamp,
            project: [
                "project_id": projectID,
                "display_name": "Version One Fixture",
                "repository_root": "/legacy/project",
                "branch": "legacy-branch",
                "commit": "legacy-commit",
                "dirty_summary": [],
            ],
            predecessorSession: [
                "session_id": "legacy-provider-session",
                "provider_session_id": NSNull(),
                "model": NSNull(),
            ],
            mission: "Preserve populated project memory",
            currentWork: [
                "phase_id": "P10",
                "work_item_id": "project-memory-v1",
                "summary": "Migrate legacy project memory",
                "active_files": ["memory.sqlite3"],
            ],
            nextActions: [[
                "order": 1,
                "action": "Reopen migrated memory",
                "command": "",
                "success_condition": "Legacy semantics remain available",
            ]],
            hostState: [
                "adapter_id": "legacy-adapter",
                "continuity_state": ContinuityState.active.rawValue,
                "context_budget_source": "legacy-fixture",
                "retry": ["attempt": 0],
            ]
        ).validated()
        try createVersionOneProjectMemoryFixture(
            at: databaseURL,
            projectID: projectID,
            recordID: recordID,
            handoff: legacyHandoff,
            timestamp: timestamp
        )

        func assertMigratedSemantics(in repository: ProjectMemoryRepository) throws {
            XCTAssertTrue(try repository.quickCheck())
            let record = try XCTUnwrap(repository.get(id: recordID))
            XCTAssertEqual(record.projectID, projectID)
            XCTAssertEqual(record.kind, "decision")
            XCTAssertEqual(record.title, "Legacy migration decision")
            XCTAssertEqual(record.summary, "Preserve populated v1 semantics")
            XCTAssertEqual(record.body, "legacy body")
            XCTAssertEqual(record.tags, ["legacy", "migration"])
            XCTAssertEqual(record.sourceKind, "operator")
            XCTAssertEqual(record.sourceReference, "fixture://project-memory-v1")
            XCTAssertEqual(record.sessionID, "legacy-session")
            XCTAssertEqual(record.schemaVersion, 1)

            let matches = try repository.search(
                query: "populated v1",
                kinds: ["decision"],
                tags: ["migration"],
                sessionID: "legacy-session",
                limit: 10,
                offset: 0
            )
            XCTAssertEqual(matches.map(\.0.id), [recordID])

            let handoff = try XCTUnwrap(repository.continuityHandoff(id: handoffID))
            XCTAssertEqual(handoff.operationID, operationID)
            XCTAssertEqual(handoff.mission, "Preserve populated project memory")
            let operation = try XCTUnwrap(repository.continuityOperation(id: operationID))
            XCTAssertEqual(operation.predecessorSessionID, "legacy-provider-session")
            XCTAssertEqual(operation.handoffID, handoffID)
            XCTAssertEqual(operation.state, .active)
            XCTAssertNil(try repository.continuityActiveOperation())
            XCTAssertEqual(try repository.continuityActiveSessionID(), "legacy-provider-session")
            XCTAssertEqual(try repository.continuityTransitionCount(operationID: operationID), 1)

            let status = try repository.status()
            XCTAssertEqual(status["schema_version"] as? Int, ProjectMemoryRepository.schemaVersion)
            XCTAssertEqual(status["integrity"] as? String, "ok")
        }

        let first = try ProjectMemoryRepository(
            projectID: projectID,
            directory: directory,
            enableFTS5: false
        )
        try assertMigratedSemantics(in: first)
        XCTAssertEqual(try projectMemoryFixtureInt(at: databaseURL, sql: "PRAGMA user_version;"), 2)
        XCTAssertEqual(
            try projectMemoryFixtureInt(
                at: databaseURL,
                sql: "SELECT COUNT(*) FROM continuity_migration_receipts WHERE receipt_id='continuity-schema-v2' AND source_version='1' AND target_version='2' AND integrity_result='ok';"
            ),
            1
        )
        XCTAssertEqual(
            try projectMemoryFixtureInt(
                at: databaseURL,
                sql: "SELECT COUNT(*) FROM continuity_handoffs WHERE handoff_id='\(handoffID)' AND quarantine_state='legacy_read_only' AND migration_source='project_memory_v1';"
            ),
            1
        )
        XCTAssertEqual(
            try projectMemoryFixtureInt(
                at: databaseURL,
                sql: "SELECT COUNT(*) FROM rollover_operations WHERE operation_id='\(operationID)' AND quarantine_state='legacy_read_only' AND migration_source='project_memory_v1';"
            ),
            1
        )
        let currentRecord = try first.remember(ProjectMemoryWrite(
            kind: "fact",
            title: "Current schema write",
            summary: "Write after version one migration",
            tags: ["migration"],
            idempotencyKey: "post-v1-migration"
        )).0
        XCTAssertEqual(currentRecord.schemaVersion, ProjectMemoryRepository.schemaVersion)
        first.close()

        let backupURL = directory.appendingPathComponent("memory.pre-migration-v1.sqlite3")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
        XCTAssertEqual(try projectMemoryFixtureInt(at: backupURL, sql: "PRAGMA user_version;"), 1)
        XCTAssertEqual(try projectMemoryFixtureText(at: backupURL, sql: "PRAGMA quick_check;"), "ok")
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: backupURL.path)[.posixPermissions]
                as? NSNumber)?.intValue,
            0o600
        )
        let migrationManifest = try JSONDecoder().decode(
            VerifiedMigrationBackupManifest.self,
            from: Data(
                contentsOf: VerifiedMigrationBackup.activeManifestURL(for: databaseURL)
            )
        )
        XCTAssertEqual(migrationManifest.state, .completed)
        XCTAssertEqual(migrationManifest.storageKind, .sqlite)
        XCTAssertEqual(migrationManifest.sourceVersion, 1)
        XCTAssertEqual(migrationManifest.targetVersion, ProjectMemoryRepository.schemaVersion)
        XCTAssertEqual(
            migrationManifest.backupSHA256,
            JSONSupport.sha256Hex(try Data(contentsOf: backupURL))
        )
        XCTAssertNotNil(migrationManifest.targetSHA256)
        XCTAssertEqual(
            try projectMemoryFixtureInt(
                at: databaseURL,
                sql: "SELECT COUNT(*) FROM forge_migration_receipts WHERE migration_id='\(migrationManifest.migrationID)';"
            ),
            1
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: VerifiedMigrationBackup.archivedManifestURL(
                    for: backupURL,
                    targetVersion: ProjectMemoryRepository.schemaVersion
                ).path
            )
        )
        XCTAssertEqual(
            try projectMemoryFixtureInt(
                at: backupURL,
                sql: "SELECT COUNT(*) FROM memory_records WHERE id='\(recordID)' AND project_id='\(projectID)';"
            ),
            1
        )
        let firstBackupData = try Data(contentsOf: backupURL)

        let reopened = try ProjectMemoryRepository(
            projectID: projectID,
            directory: directory,
            enableFTS5: false
        )
        try assertMigratedSemantics(in: reopened)
        XCTAssertEqual(try reopened.get(id: currentRecord.id)?.schemaVersion, ProjectMemoryRepository.schemaVersion)
        XCTAssertEqual(try reopened.status()["record_count"] as? Int, 2)
        reopened.close()

        let rerun = try ProjectMemoryRepository(
            projectID: projectID,
            directory: directory,
            enableFTS5: false
        )
        try assertMigratedSemantics(in: rerun)
        XCTAssertEqual(try rerun.get(id: currentRecord.id)?.title, "Current schema write")
        XCTAssertEqual(
            try projectMemoryFixtureInt(
                at: databaseURL,
                sql: "SELECT COUNT(*) FROM continuity_migration_receipts WHERE receipt_id='continuity-schema-v2';"
            ),
            1
        )
        XCTAssertEqual(try Data(contentsOf: backupURL), firstBackupData)
        rerun.close()

        try firstBackupData.write(to: databaseURL, options: .atomic)
        for suffix in ["-wal", "-shm", "-journal"] {
            let sidecar = URL(fileURLWithPath: databaseURL.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) {
                try FileManager.default.removeItem(at: sidecar)
            }
        }
        let restored = try ProjectMemoryRepository(
            projectID: projectID,
            directory: directory,
            enableFTS5: false
        )
        try assertMigratedSemantics(in: restored)
        XCTAssertNil(try restored.get(id: currentRecord.id))
        restored.close()
        XCTAssertEqual(
            try JSONDecoder().decode(
                VerifiedMigrationBackupManifest.self,
                from: Data(
                    contentsOf: VerifiedMigrationBackup.activeManifestURL(for: databaseURL)
                )
            ),
            migrationManifest
        )
    }

    func testVersionOneMigrationRejectsStablePathReplacementBeforeCommit() throws {
        let projectID = UUID().uuidString.lowercased()
        let originalRecordID = UUID().uuidString.lowercased()
        let replacementRecordID = UUID().uuidString.lowercased()
        let directory = home.appendingPathComponent(
            "project-memory-v1-path-replacement",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let databaseURL = directory.appendingPathComponent("memory.sqlite3")
        let backupURL = directory.appendingPathComponent("memory.pre-migration-v1.sqlite3")
        let replacementURL = directory.appendingPathComponent("replacement.sqlite3")
        let displacedURL = directory.appendingPathComponent("displaced.sqlite3")
        let timestamp = "2026-01-03T04:05:06Z"
        let handoff = try ContinuityHandoff(
            handoffID: UUID().uuidString.lowercased(),
            operationID: UUID().uuidString.lowercased(),
            createdAt: timestamp,
            project: [
                "project_id": projectID,
                "display_name": "Path Replacement Fixture",
                "repository_root": "/legacy/path-replacement",
                "branch": "legacy-branch",
                "commit": "legacy-commit",
                "dirty_summary": [],
            ],
            predecessorSession: [
                "session_id": "legacy-provider-session",
                "provider_session_id": NSNull(),
                "model": NSNull(),
            ],
            mission: "Reject a replaced migration pathname",
            currentWork: [
                "phase_id": "P10",
                "work_item_id": "project-memory-v1-path-replacement",
                "summary": "Keep the migration connection on one main file",
                "active_files": ["memory.sqlite3"],
            ],
            nextActions: [[
                "order": 1,
                "action": "Reject the replaced pathname",
                "command": "",
                "success_condition": "No migration transaction commits",
            ]],
            hostState: [
                "adapter_id": "legacy-adapter",
                "continuity_state": ContinuityState.active.rawValue,
                "context_budget_source": "legacy-fixture",
                "retry": ["attempt": 0],
            ]
        ).validated()
        try createVersionOneProjectMemoryFixture(
            at: databaseURL,
            projectID: projectID,
            recordID: originalRecordID,
            handoff: handoff,
            timestamp: timestamp
        )
        try createVersionOneProjectMemoryFixture(
            at: replacementURL,
            projectID: projectID,
            recordID: replacementRecordID,
            handoff: handoff,
            timestamp: timestamp
        )

        XCTAssertThrowsError(
            try ProjectMemoryRepository(
                projectID: projectID,
                directory: directory,
                enableFTS5: false,
                beforeMigrationCommitObserver: {
                    try FileManager.default.moveItem(
                        at: databaseURL,
                        to: displacedURL
                    )
                    try FileManager.default.moveItem(
                        at: replacementURL,
                        to: databaseURL
                    )
                }
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("moved")
                    || error.localizedDescription.contains("replaced")
                    || error.localizedDescription.contains("movement check"),
                "\(error)"
            )
        }

        try FileManager.default.moveItem(at: databaseURL, to: replacementURL)
        try FileManager.default.moveItem(at: displacedURL, to: databaseURL)
        XCTAssertEqual(
            try projectMemoryFixtureInt(at: databaseURL, sql: "PRAGMA user_version;"),
            1
        )
        XCTAssertEqual(
            try projectMemoryFixtureInt(at: replacementURL, sql: "PRAGMA user_version;"),
            1
        )
        XCTAssertEqual(
            try projectMemoryFixtureInt(
                at: databaseURL,
                sql: "SELECT COUNT(*) FROM memory_records WHERE id='\(originalRecordID)';"
            ),
            1
        )
        XCTAssertEqual(
            try projectMemoryFixtureInt(
                at: databaseURL,
                sql: "SELECT COUNT(*) FROM memory_records WHERE id='\(replacementRecordID)';"
            ),
            0
        )
        XCTAssertEqual(
            try projectMemoryFixtureInt(
                at: replacementURL,
                sql: "SELECT COUNT(*) FROM memory_records WHERE id='\(replacementRecordID)';"
            ),
            1
        )
        XCTAssertEqual(
            try projectMemoryFixtureInt(
                at: replacementURL,
                sql: "SELECT COUNT(*) FROM memory_records WHERE id='\(originalRecordID)';"
            ),
            0
        )
        XCTAssertEqual(
            try projectMemoryFixtureInt(
                at: databaseURL,
                sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='continuity_migration_receipts';"
            ),
            0
        )
        XCTAssertEqual(
            try projectMemoryFixtureInt(
                at: replacementURL,
                sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='continuity_migration_receipts';"
            ),
            0
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
        XCTAssertEqual(
            try projectMemoryFixtureInt(at: backupURL, sql: "PRAGMA user_version;"),
            1
        )
        XCTAssertEqual(
            try projectMemoryFixtureText(at: backupURL, sql: "PRAGMA quick_check;"),
            "ok"
        )
        XCTAssertEqual(
            try projectMemoryFixtureInt(
                at: backupURL,
                sql: "SELECT COUNT(*) FROM memory_records WHERE id='\(originalRecordID)';"
            ),
            1
        )
        XCTAssertEqual(
            try projectMemoryFixtureInt(
                at: backupURL,
                sql: "SELECT COUNT(*) FROM memory_records WHERE id='\(replacementRecordID)';"
            ),
            0
        )
        let activeManifest = try JSONDecoder().decode(
            VerifiedMigrationBackupManifest.self,
            from: Data(
                contentsOf: VerifiedMigrationBackup.activeManifestURL(for: databaseURL)
            )
        )
        XCTAssertEqual(activeManifest.state, .prepared)
        XCTAssertEqual(activeManifest.backupFilename, backupURL.lastPathComponent)
        XCTAssertEqual(
            activeManifest.backupSHA256,
            JSONSupport.sha256Hex(try Data(contentsOf: backupURL))
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: VerifiedMigrationBackup.archivedManifestURL(
                    for: backupURL,
                    targetVersion: ProjectMemoryRepository.schemaVersion
                ).path
            )
        )
    }

    func testConcurrentInitializersSerializeVersionOneMigration() async throws {
        let participantCount = 8
        let projectID = UUID().uuidString.lowercased()
        let recordID = UUID().uuidString.lowercased()
        let timestamp = "2026-01-03T04:05:06Z"
        let directory = home.appendingPathComponent(
            "project-memory-v1-concurrent",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("memory.sqlite3")
        let handoff = try ContinuityHandoff(
            handoffID: UUID().uuidString.lowercased(),
            operationID: UUID().uuidString.lowercased(),
            createdAt: timestamp,
            project: [
                "project_id": projectID,
                "display_name": "Concurrent Version One Fixture",
                "repository_root": "/legacy/concurrent-project",
                "branch": "legacy-branch",
                "commit": "legacy-commit",
                "dirty_summary": [],
            ],
            predecessorSession: [
                "session_id": "legacy-provider-session",
                "provider_session_id": NSNull(),
                "model": NSNull(),
            ],
            mission: "Serialize project memory migration",
            currentWork: [
                "phase_id": "P10",
                "work_item_id": "project-memory-v1-concurrent",
                "summary": "Open one legacy database concurrently",
                "active_files": ["memory.sqlite3"],
            ],
            nextActions: [[
                "order": 1,
                "action": "Verify serialized migration",
                "command": "",
                "success_condition": "Every initializer opens schema version two",
            ]],
            hostState: [
                "adapter_id": "legacy-adapter",
                "continuity_state": ContinuityState.active.rawValue,
                "context_budget_source": "legacy-fixture",
                "retry": ["attempt": 0],
            ]
        ).validated()
        try createVersionOneProjectMemoryFixture(
            at: databaseURL,
            projectID: projectID,
            recordID: recordID,
            handoff: handoff,
            timestamp: timestamp
        )

        let gate = InitializationGate(participantCount: participantCount)
        let repositories = try await withThrowingTaskGroup(
            of: ProjectMemoryRepository.self,
            returning: [ProjectMemoryRepository].self
        ) { group in
            for _ in 0..<participantCount {
                group.addTask {
                    await gate.wait()
                    return try ProjectMemoryRepository(
                        projectID: projectID,
                        directory: directory,
                        enableFTS5: false
                    )
                }
            }
            var opened: [ProjectMemoryRepository] = []
            opened.reserveCapacity(participantCount)
            for try await repository in group { opened.append(repository) }
            return opened
        }

        XCTAssertEqual(repositories.count, participantCount)
        for repository in repositories {
            XCTAssertTrue(try repository.quickCheck())
            XCTAssertEqual(
                try repository.status()["schema_version"] as? Int,
                ProjectMemoryRepository.schemaVersion
            )
            XCTAssertEqual(try repository.get(id: recordID)?.title, "Legacy migration decision")
        }
        for repository in repositories { repository.close() }

        XCTAssertEqual(
            try projectMemoryFixtureInt(at: databaseURL, sql: "PRAGMA user_version;"),
            ProjectMemoryRepository.schemaVersion
        )
        XCTAssertEqual(
            try projectMemoryFixtureInt(
                at: databaseURL,
                sql: "SELECT COUNT(*) FROM continuity_migration_receipts WHERE receipt_id='continuity-schema-v2';"
            ),
            1
        )
        let backupURL = directory.appendingPathComponent("memory.pre-migration-v1.sqlite3")
        XCTAssertEqual(try projectMemoryFixtureInt(at: backupURL, sql: "PRAGMA user_version;"), 1)
        XCTAssertEqual(
            try projectMemoryFixtureInt(
                at: backupURL,
                sql: "SELECT COUNT(*) FROM memory_records WHERE id='\(recordID)';"
            ),
            1
        )
        XCTAssertEqual(try projectMemoryFixtureText(at: backupURL, sql: "PRAGMA quick_check;"), "ok")
    }

    func testFallbackSearchAndCorruptDatabaseRecoveryArtifact() throws {
        let fallbackDirectory = home.appendingPathComponent("fallback", isDirectory: true)
        let fallbackID = UUID().uuidString.lowercased()
        let fallback = try ProjectMemoryRepository(
            projectID: fallbackID, directory: fallbackDirectory, enableFTS5: false
        )
        defer { fallback.close() }
        XCTAssertFalse(fallback.supportsFTS5)
        _ = try fallback.remember(ProjectMemoryWrite(
            kind: "fact", title: "Lexical fallback", summary: "bounded SQL matching"
        ))
        XCTAssertEqual(try fallback.search(
            query: "matching", kinds: [], tags: [], sessionID: nil, limit: 10, offset: 0
        ).count, 1)

        var app: ForgeApp? = try ForgeApp.bootstrap(home: home)
        let projectID = try initialize(app!, project: projectA)
        _ = try call(app!, "project_memory.remember", [
            "project_id": projectID, "kind": "fact", "title": "Before corruption", "summary": "preserve the artifact",
        ])
        app?.shutdown(); app = nil
        let projectDirectory = home.appendingPathComponent("Projects/\(projectID)", isDirectory: true)
        let database = projectDirectory.appendingPathComponent("memory.sqlite3")
        let corrupt = Data("not a sqlite database".utf8)
        try corrupt.write(to: database, options: .atomic)
        let sourceWriteAheadLog = URL(fileURLWithPath: database.path + "-wal")
        let writeAheadLogBytes = FileManager.default.fileExists(atPath: sourceWriteAheadLog.path)
            ? try Data(contentsOf: sourceWriteAheadLog)
            : nil

        app = try ForgeApp.bootstrap(home: home)
        let failed = try app!.tools.call(
            name: "project_memory.initialize", arguments: ["project_path": projectA.path],
            clientID: ClientID("project-memory-corruption")
        )
        XCTAssertFalse(failed.ok)
        XCTAssertEqual(failed.payload["code"] as? String, "integrity_failure")
        XCTAssertEqual(try Data(contentsOf: database), corrupt)
        if let writeAheadLogBytes {
            XCTAssertEqual(try Data(contentsOf: sourceWriteAheadLog), writeAheadLogBytes)
        }
        let recoveryFamily = try FileManager.default.contentsOfDirectory(
            at: projectDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("memory.corrupt-") }
        let preservedDatabases = recoveryFamily.filter { $0.lastPathComponent.hasSuffix(".sqlite3") }
        XCTAssertEqual(preservedDatabases.count, 1)
        let preservedDatabase = try XCTUnwrap(preservedDatabases.first)
        XCTAssertEqual(try Data(contentsOf: preservedDatabase), corrupt)
        let permissions = try FileManager.default.attributesOfItem(atPath: preservedDatabase.path)[.posixPermissions]
            as? NSNumber
        XCTAssertEqual((permissions?.intValue ?? 0) & 0o777, 0o600)
        let preservedWriteAheadLogs = recoveryFamily.filter {
            $0.lastPathComponent.hasSuffix(".sqlite3-wal")
        }
        XCTAssertEqual(preservedWriteAheadLogs.count, writeAheadLogBytes == nil ? 0 : 1)
        if let writeAheadLogBytes, let preservedWriteAheadLog = preservedWriteAheadLogs.first {
            XCTAssertEqual(try Data(contentsOf: preservedWriteAheadLog), writeAheadLogBytes)
        }
        app?.shutdown(); app = nil

        app = try ForgeApp.bootstrap(home: home)
        let repeated = try app!.tools.call(
            name: "project_memory.initialize", arguments: ["project_path": projectA.path],
            clientID: ClientID("project-memory-corruption-repeat")
        )
        XCTAssertFalse(repeated.ok)
        XCTAssertEqual(repeated.payload["code"] as? String, "integrity_failure")
        let repeatedRecoveryFamily = try FileManager.default.contentsOfDirectory(
            at: projectDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("memory.corrupt-") }
        XCTAssertEqual(
            repeatedRecoveryFamily.filter { $0.lastPathComponent.hasSuffix(".sqlite3") }.count,
            1
        )
        XCTAssertEqual(
            repeatedRecoveryFamily.filter { $0.lastPathComponent.hasSuffix(".sqlite3-wal") }.count,
            writeAheadLogBytes == nil ? 0 : 1
        )
        app?.shutdown()
    }

    func testDatabaseLockReturnsTypedBusyWithoutPartialWrite() throws {
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let projectID = try initialize(app, project: projectA)
        let databaseURL = home.appendingPathComponent("Projects/\(projectID)/memory.sqlite3")
        var locker: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &locker), SQLITE_OK)
        let opened = try XCTUnwrap(locker)
        defer { sqlite3_exec(opened, "ROLLBACK;", nil, nil, nil); sqlite3_close(opened) }
        XCTAssertEqual(sqlite3_exec(opened, "BEGIN IMMEDIATE;", nil, nil, nil), SQLITE_OK)

        let result = try app.tools.call(
            name: "project_memory.remember",
            arguments: [
                "project_id": projectID, "kind": "fact", "title": "Locked", "summary": "must roll back",
            ], clientID: ClientID("project-memory-test")
        )
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.payload["code"] as? String, "database_busy")
        sqlite3_exec(opened, "ROLLBACK;", nil, nil, nil)
        let status = try call(app, "project_memory.status", ["project_id": projectID])
        XCTAssertEqual(status["record_count"] as? Int, 0)
    }

    func testDeadlinePreemptsDatabaseLockWithoutPartialWrite() throws {
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let projectID = try initialize(app, project: projectA)
        let databaseURL = home.appendingPathComponent("Projects/\(projectID)/memory.sqlite3")
        var locker: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &locker), SQLITE_OK)
        let opened = try XCTUnwrap(locker)
        defer { sqlite3_exec(opened, "ROLLBACK;", nil, nil, nil); sqlite3_close(opened) }
        XCTAssertEqual(sqlite3_exec(opened, "BEGIN IMMEDIATE;", nil, nil, nil), SQLITE_OK)

        let startedAt = Date()
        let result = try app.tools.call(
            name: "project_memory.remember",
            arguments: [
                "project_id": projectID,
                "kind": "fact",
                "title": "Deadline locked",
                "summary": "must not commit",
                "deadline_ms": 100,
            ],
            clientID: ClientID("project-memory-test")
        )
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.payload["code"] as? String, "deadline_exceeded")
        XCTAssertLessThan(elapsed, 1)
        sqlite3_exec(opened, "ROLLBACK;", nil, nil, nil)
        let status = try call(app, "project_memory.status", ["project_id": projectID])
        XCTAssertEqual(status["record_count"] as? Int, 0)
    }

    func testCancellationPreemptsActiveDatabaseLockWithoutPartialWrite() async throws {
        let projectID = UUID().uuidString.lowercased()
        let directory = home.appendingPathComponent("project-memory-cancel-lock", isDirectory: true)
        let busyReached = DispatchSemaphore(value: 0)
        let repository = try ProjectMemoryRepository(
            projectID: projectID,
            directory: directory,
            enableFTS5: false,
            busyRetryObserver: {
                busyReached.signal()
            },
            beforeMigrationCommitObserver: nil
        )
        defer { repository.close() }

        var locker: OpaquePointer?
        XCTAssertEqual(sqlite3_open(repository.databaseURL.path, &locker), SQLITE_OK)
        let opened = try XCTUnwrap(locker)
        defer { sqlite3_exec(opened, "ROLLBACK;", nil, nil, nil); sqlite3_close(opened) }
        XCTAssertEqual(sqlite3_exec(opened, "BEGIN IMMEDIATE;", nil, nil, nil), SQLITE_OK)

        let cancellation = ToolCallCancellation(timeoutSeconds: 5)
        let write = ProjectMemoryWrite(
            kind: "fact",
            title: "Cancellation locked",
            summary: "must not commit"
        )
        let operation = Task.detached {
            try repository.remember(write, cancellation: cancellation)
        }

        XCTAssertEqual(busyReached.wait(timeout: .now() + 1), .success)
        let cancelledAt = Date()
        cancellation.cancel()
        do {
            _ = try await operation.value
            XCTFail("cancelled SQLite operation returned a result")
        } catch is CancellationError {
            // Expected: active cancellation interrupts the bounded busy handler.
        } catch {
            XCTFail("unexpected cancellation error: \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 1)

        sqlite3_exec(opened, "ROLLBACK;", nil, nil, nil)
        let status = try repository.status()
        XCTAssertEqual(status["record_count"] as? Int, 0)
    }

    func testCancellationAfterCommitReturnsCommittedResult() throws {
        let projectID = UUID().uuidString.lowercased()
        let directory = home.appendingPathComponent("project-memory-committed-result", isDirectory: true)
        let cancellation = ToolCallCancellation(timeoutSeconds: 5)
        let repository = try ProjectMemoryRepository(
            projectID: projectID,
            directory: directory,
            enableFTS5: false,
            didMutationCommitObserver: {
                cancellation.cancel()
            },
            beforeMigrationCommitObserver: nil
        )
        defer { repository.close() }

        let (record, disposition) = try repository.remember(
            ProjectMemoryWrite(
                kind: "fact",
                title: "Committed result",
                summary: "the committed mutation remains authoritative"
            ),
            cancellation: cancellation
        )

        XCTAssertEqual(disposition, "inserted")
        XCTAssertEqual(record.title, "Committed result")
        XCTAssertTrue(cancellation.isCancelled)
        let status = try repository.status()
        XCTAssertEqual(status["record_count"] as? Int, 1)
    }

    func testExportCancellationBeforeAtomicPublicationLeavesNoArtifact() throws {
        let paths = AppPaths(home: home)
        try paths.ensureLayout()
        let cancellation = ToolCallCancellation(timeoutSeconds: 5)
        let memory = ProjectMemoryService(
            paths: paths,
            clock: SystemClock(),
            limits: .current,
            afterIdentityMetadataWriteObserver: nil,
            didIdentityRegistryCommitObserver: nil,
            beforeContinuityProjectionWriteObserver: nil,
            beforeExportCommitObserver: {
                cancellation.cancel()
            }
        )
        defer { memory.closeAll() }
        let descriptor = try memory.initialize(path: projectA.path)
        let projectID = try XCTUnwrap(descriptor["project_id"] as? String)
        _ = try memory.remember(
            projectID: projectID,
            write: ProjectMemoryWrite(
                kind: "fact",
                title: "Cancelled export",
                summary: "must not publish after authority is revoked"
            )
        )

        XCTAssertThrowsError(
            try memory.export(projectID: projectID, cancellation: cancellation)
        ) { error in
            XCTAssertTrue(error is CancellationError, "unexpected error: \(error)")
        }

        let exports = paths.projectsDir
            .appendingPathComponent(projectID, isDirectory: true)
            .appendingPathComponent("exports", isDirectory: true)
        let artifacts = (try? FileManager.default.contentsOfDirectory(
            at: exports,
            includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertTrue(artifacts.filter { $0.pathExtension == "json" }.isEmpty)

        memory.closeAll()
        let reopened = ProjectMemoryService(paths: paths)
        defer { reopened.closeAll() }
        let committedCancellation = ToolCallCancellation(timeoutSeconds: 5)
        let exported = try reopened.export(
            projectID: projectID,
            cancellation: committedCancellation
        )
        let receipt = try XCTUnwrap(
            committedCancellation.committedResult(as: ToolResult.self)
        )
        XCTAssertTrue(receipt.ok)
        XCTAssertEqual(
            receipt.payload["artifact"] as? String,
            exported["artifact"] as? String
        )
        XCTAssertEqual(
            receipt.payload["checksum"] as? String,
            exported["checksum"] as? String
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: try XCTUnwrap(exported["artifact"] as? String)
        ))
    }

    func testReadStepFailuresNeverAppearAsEmptyOrPartialResults() throws {
        let projectID = UUID().uuidString.lowercased()
        let directory = home.appendingPathComponent("project-memory-row-step-errors", isDirectory: true)
        let fault = ProjectMemoryRowStepFault()
        let repository = try ProjectMemoryRepository(
            projectID: projectID,
            directory: directory,
            enableFTS5: false,
            beforeMigrationCommitObserver: nil,
            rowStepObserver: { try fault.observe() }
        )
        defer { repository.close() }

        var recordIDs: [String] = []
        for index in 0..<2 {
            let (record, _) = try repository.remember(ProjectMemoryWrite(
                kind: "fact",
                title: "Checked row \(index)",
                summary: "checked SQLite row semantics \(index)"
            ))
            recordIDs.append(record.id)
        }

        fault.arm(afterSuccessfulSteps: 0)
        assertDatabaseBusy(try repository.get(id: recordIDs[0]))

        fault.arm(afterSuccessfulSteps: 1)
        assertDatabaseBusy(try repository.recent(
            kinds: [], sessionID: nil, limit: 10, offset: 0
        ))

        fault.arm(afterSuccessfulSteps: 1)
        assertDatabaseBusy(try repository.search(
            query: "Checked", kinds: [], tags: [], sessionID: nil, limit: 10, offset: 0
        ))

        fault.arm(afterSuccessfulSteps: 0)
        assertDatabaseBusy(try repository.status())
    }

    private func assertDatabaseBusy<T>(
        _ operation: @autoclosure () throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(error as? ProjectMemoryError, .databaseBusy, file: file, line: line)
        }
    }

    private func initialize(
        _ app: ForgeApp,
        project: URL,
        clientID: ClientID = ClientID("project-memory-test")
    ) throws -> String {
        let payload = try call(
            app,
            "project_memory.initialize",
            ["project_path": project.path],
            clientID: clientID
        )
        return try XCTUnwrap(payload["project_id"] as? String)
    }

    private func call(
        _ app: ForgeApp,
        _ name: String,
        _ arguments: [String: Any],
        clientID: ClientID = ClientID("project-memory-test")
    ) throws -> [String: Any] {
        let result = try app.tools.call(name: name, arguments: arguments, clientID: clientID)
        XCTAssertTrue(result.ok, "\(name): \(result.payload)")
        return result.payload
    }

    private func setUserVersion(_ databaseURL: URL, version: Int) throws {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
            throw ProjectMemoryError.integrityFailure("cannot open fixture")
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, "PRAGMA user_version=\(version);", nil, nil, nil) == SQLITE_OK else {
            throw ProjectMemoryError.integrityFailure("cannot set fixture version")
        }
    }

    private func createUnversionedProjectMemoryFixture(at databaseURL: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw ProjectMemoryError.integrityFailure("cannot create unversioned fixture")
        }
        defer { sqlite3_close(database) }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(
            database,
            """
            PRAGMA journal_mode=DELETE;
            CREATE TABLE foreign_records(id INTEGER PRIMARY KEY, payload TEXT NOT NULL);
            INSERT INTO foreign_records(id,payload) VALUES(1,'must remain byte-for-byte intact');
            """,
            nil,
            nil,
            &errorMessage
        )
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw ProjectMemoryError.integrityFailure(message)
        }
    }

    private func createVersionOneProjectMemoryFixture(
        at databaseURL: URL,
        projectID: String,
        recordID: String,
        handoff: ContinuityHandoff,
        timestamp: String
    ) throws {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
            throw ProjectMemoryError.integrityFailure("cannot open version one fixture")
        }
        defer { sqlite3_close(database) }
        let payload = try JSONSupport.string(from: handoff.asDictionary())
            .replacingOccurrences(of: "'", with: "''")
        let contentHash = String(repeating: "a", count: 64)
        let stateChecksum = String(repeating: "b", count: 64)
        let sql = """
        CREATE TABLE memory_records(
            id TEXT PRIMARY KEY, project_id TEXT NOT NULL, version INTEGER NOT NULL,
            kind TEXT NOT NULL, title TEXT NOT NULL, summary TEXT NOT NULL, body TEXT,
            importance REAL NOT NULL, confidence REAL NOT NULL, source_kind TEXT NOT NULL,
            source_reference TEXT, session_id TEXT, created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL, last_accessed_at TEXT NOT NULL, expires_at TEXT,
            content_hash TEXT NOT NULL, is_tombstone INTEGER NOT NULL DEFAULT 0,
            schema_version INTEGER NOT NULL, idempotency_key TEXT,
            UNIQUE(project_id,kind,content_hash), UNIQUE(project_id,idempotency_key)
        );
        CREATE TABLE memory_tags(id INTEGER PRIMARY KEY AUTOINCREMENT,name TEXT UNIQUE NOT NULL);
        CREATE TABLE memory_record_tags(record_id TEXT NOT NULL REFERENCES memory_records(id) ON DELETE CASCADE,tag_id INTEGER NOT NULL REFERENCES memory_tags(id),PRIMARY KEY(record_id,tag_id));
        CREATE TABLE memory_links(project_id TEXT NOT NULL,source_id TEXT NOT NULL REFERENCES memory_records(id),target_id TEXT NOT NULL REFERENCES memory_records(id),relation TEXT NOT NULL,created_at TEXT NOT NULL,PRIMARY KEY(source_id,target_id,relation));
        CREATE TABLE sessions(id TEXT PRIMARY KEY,project_id TEXT NOT NULL,created_at TEXT NOT NULL,updated_at TEXT NOT NULL,state TEXT NOT NULL);
        CREATE TABLE handoffs(id TEXT PRIMARY KEY,project_id TEXT NOT NULL,record_id TEXT,created_at TEXT NOT NULL,acknowledged_at TEXT);
        CREATE TABLE artifacts(id TEXT PRIMARY KEY,project_id TEXT NOT NULL,path TEXT NOT NULL,checksum TEXT NOT NULL,created_at TEXT NOT NULL);
        CREATE TABLE project_aliases(project_id TEXT NOT NULL,alias TEXT NOT NULL,created_at TEXT NOT NULL,PRIMARY KEY(project_id,alias));
        CREATE TABLE maintenance_state(project_id TEXT PRIMARY KEY,last_run_at TEXT,state_json TEXT NOT NULL);
        CREATE TABLE event_journal(id INTEGER PRIMARY KEY AUTOINCREMENT,project_id TEXT NOT NULL,record_id TEXT,action TEXT NOT NULL,detail TEXT,created_at TEXT NOT NULL);
        CREATE TABLE continuity_handoffs(
          handoff_id TEXT PRIMARY KEY,project_id TEXT NOT NULL,operation_id TEXT NOT NULL UNIQUE,
          payload_json TEXT NOT NULL,content_sha256 TEXT NOT NULL,created_at TEXT NOT NULL,
          acknowledged_session_id TEXT,acknowledged_at TEXT
        );
        CREATE TABLE rollover_operations(
          operation_id TEXT PRIMARY KEY,project_id TEXT NOT NULL,predecessor_session_id TEXT NOT NULL,
          successor_session_id TEXT,handoff_id TEXT NOT NULL,state TEXT NOT NULL,attempt INTEGER NOT NULL,
          adapter_id TEXT NOT NULL,idempotency_key TEXT NOT NULL,acknowledged_session_id TEXT,
          acknowledged_handoff_id TEXT,created_at TEXT NOT NULL,updated_at TEXT NOT NULL,
          last_error TEXT,retry_at TEXT,state_checksum TEXT NOT NULL,
          UNIQUE(project_id,idempotency_key)
        );
        CREATE TABLE rollover_transitions(
          id INTEGER PRIMARY KEY AUTOINCREMENT,operation_id TEXT NOT NULL,project_id TEXT NOT NULL,
          from_state TEXT,to_state TEXT NOT NULL,attempt INTEGER NOT NULL,created_at TEXT NOT NULL,
          adapter_id TEXT NOT NULL,evidence TEXT,state_checksum TEXT NOT NULL
        );
        CREATE TABLE project_active_sessions(
          project_id TEXT PRIMARY KEY,session_id TEXT NOT NULL,updated_at TEXT NOT NULL
        );
        CREATE UNIQUE INDEX idx_rollover_active_project
          ON rollover_operations(project_id) WHERE state <> 'predecessorSealed';
        CREATE INDEX idx_rollover_project_updated ON rollover_operations(project_id,updated_at DESC);
        CREATE INDEX idx_memory_project_recent ON memory_records(project_id,is_tombstone,updated_at DESC);
        CREATE INDEX idx_memory_project_kind ON memory_records(project_id,kind,is_tombstone);
        CREATE INDEX idx_memory_project_session ON memory_records(project_id,session_id,is_tombstone);
        INSERT INTO memory_records(
          id,project_id,version,kind,title,summary,body,importance,confidence,source_kind,
          source_reference,session_id,created_at,updated_at,last_accessed_at,expires_at,
          content_hash,is_tombstone,schema_version,idempotency_key
        ) VALUES(
          '\(recordID)','\(projectID)',1,'decision','Legacy migration decision',
          'Preserve populated v1 semantics','legacy body',0.8,0.9,'operator',
          'fixture://project-memory-v1','legacy-session','\(timestamp)','\(timestamp)','\(timestamp)',NULL,
          '\(contentHash)',0,1,'legacy-record-key'
        );
        INSERT INTO memory_tags(id,name) VALUES(1,'legacy'),(2,'migration');
        INSERT INTO memory_record_tags(record_id,tag_id) VALUES('\(recordID)',1),('\(recordID)',2);
        INSERT INTO continuity_handoffs(
          handoff_id,project_id,operation_id,payload_json,content_sha256,created_at,
          acknowledged_session_id,acknowledged_at
        ) VALUES(
          '\(handoff.handoffID)','\(projectID)','\(handoff.operationID)','\(payload)',
          '\(handoff.contentSHA256)','\(timestamp)',NULL,NULL
        );
        INSERT INTO rollover_operations(
          operation_id,project_id,predecessor_session_id,successor_session_id,handoff_id,
          state,attempt,adapter_id,idempotency_key,acknowledged_session_id,
          acknowledged_handoff_id,created_at,updated_at,last_error,retry_at,state_checksum
        ) VALUES(
          '\(handoff.operationID)','\(projectID)','legacy-provider-session',NULL,'\(handoff.handoffID)',
          'active',0,'legacy-adapter','legacy-operation-key',NULL,NULL,
          '\(timestamp)','\(timestamp)',NULL,NULL,'\(stateChecksum)'
        );
        INSERT INTO rollover_transitions(
          operation_id,project_id,from_state,to_state,attempt,created_at,adapter_id,evidence,state_checksum
        ) VALUES(
          '\(handoff.operationID)','\(projectID)',NULL,'active',0,'\(timestamp)',
          'legacy-adapter','legacy operation created','\(stateChecksum)'
        );
        INSERT INTO project_active_sessions(project_id,session_id,updated_at)
          VALUES('\(projectID)','legacy-provider-session','\(timestamp)');
        PRAGMA user_version=1;
        """
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw ProjectMemoryError.integrityFailure(message)
        }
    }

    private func projectMemoryFixtureInt(at databaseURL: URL, sql: String) throws -> Int {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
            throw ProjectMemoryError.integrityFailure("cannot open project memory fixture")
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw ProjectMemoryError.integrityFailure(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw ProjectMemoryError.integrityFailure(String(cString: sqlite3_errmsg(database)))
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func projectMemoryFixtureText(at databaseURL: URL, sql: String) throws -> String? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw ProjectMemoryError.integrityFailure("cannot open project memory fixture")
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw ProjectMemoryError.integrityFailure(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw ProjectMemoryError.integrityFailure(String(cString: sqlite3_errmsg(database)))
        }
        return sqlite3_column_text(statement, 0).map { String(cString: $0) }
    }
}

private final class ProjectMemoryRowStepFault: @unchecked Sendable {
    private let lock = NSLock()
    private var remainingSuccessfulSteps: Int?

    func arm(afterSuccessfulSteps count: Int) {
        lock.lock()
        remainingSuccessfulSteps = max(0, count)
        lock.unlock()
    }

    func observe() throws {
        lock.lock()
        defer { lock.unlock() }
        guard let remainingSuccessfulSteps else { return }
        guard remainingSuccessfulSteps > 0 else {
            throw ProjectMemoryError.databaseBusy
        }
        self.remainingSuccessfulSteps = remainingSuccessfulSteps - 1
    }
}
