// MemoryToolTests.swift
// Verifies durable SQLite-backed memory MCP tools against an isolated temp home.
// Does not touch the operator's live ~/.forge-conductor install.

import XCTest
import SQLite3
@testable import ForgeConductorCore

final class MemoryToolTests: XCTestCase {
    private var tempHome: URL!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-memory-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempHome)
    }

    func testMemoryToolsAreRegistered() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let names = Set(app.tools.toolNames)
        for need in ["memory_set", "memory_get", "memory_list", "memory_delete", "memory_search"] {
            XCTAssertTrue(names.contains(need), "missing tool \(need)")
        }

        let server = MCPServer(app: app, clientID: ClientID("memory-continuity-schema"))
        let response = server.handle([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/list",
        ])
        let result = response?["result"] as? [String: Any]
        let descriptors = result?["tools"] as? [[String: Any]] ?? []
        let byName = Dictionary(uniqueKeysWithValues: descriptors.compactMap { descriptor in
            (descriptor["name"] as? String).map { ($0, descriptor) }
        })
        XCTAssertTrue(MCPServeVerifier.requiredProductTools.isSubset(of: Set(byName.keys)))
        for name in MCPServeVerifier.requiredProductTools {
            XCTAssertFalse((byName[name]?["description"] as? String ?? "").isEmpty, name)
            let schema = byName[name]?["inputSchema"] as? [String: Any]
            XCTAssertEqual(schema?["type"] as? String, "object", name)
        }
        let memorySetSchema = byName["memory_set"]?["inputSchema"] as? [String: Any]
        let memorySetProperties = memorySetSchema?["properties"] as? [String: Any]
        XCTAssertNotNil(memorySetProperties?["body"])
        XCTAssertNotNil(memorySetProperties?["content"])
        let checkpointSchema = byName["session_checkpoint"]?["inputSchema"] as? [String: Any]
        let checkpointProperties = checkpointSchema?["properties"] as? [String: Any]
        XCTAssertNotNil(checkpointProperties?["summary"])
    }

    func testMemorySetGetListSearchDeleteRoundTrip() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        let client = ClientID("memory-client")

        let set = try app.tools.call(
            name: "memory_set",
            arguments: [
                "key": "project/forsetti",
                "body": "Resume Jamf policy work; next: package postinstall.",
                "tags": ["project", "jamf"],
            ],
            clientID: client
        )
        XCTAssertTrue(set.ok, "\(set.payload)")
        XCTAssertEqual(set.payload["stored"] as? Bool, true)

        let get = try app.tools.call(
            name: "memory_get",
            arguments: ["key": "project/forsetti"],
            clientID: client
        )
        XCTAssertTrue(get.ok)
        XCTAssertEqual(get.payload["found"] as? Bool, true)
        XCTAssertEqual(get.payload["body"] as? String, "Resume Jamf policy work; next: package postinstall.")
        let tags = get.payload["tags"] as? [String] ?? []
        XCTAssertTrue(tags.contains("jamf"))

        let list = try app.tools.call(
            name: "memory_list",
            arguments: ["prefix": "project/"],
            clientID: client
        )
        XCTAssertTrue(list.ok)
        XCTAssertEqual(list.payload["count"] as? Int, 1)

        let search = try app.tools.call(
            name: "memory_search",
            arguments: ["query": "postinstall"],
            clientID: client
        )
        XCTAssertTrue(search.ok)
        XCTAssertEqual(search.payload["count"] as? Int, 1)

        let del = try app.tools.call(
            name: "memory_delete",
            arguments: ["key": "project/forsetti"],
            clientID: client
        )
        XCTAssertTrue(del.ok)
        XCTAssertEqual(del.payload["deleted"] as? Bool, true)

        let missing = try app.tools.call(
            name: "memory_get",
            arguments: ["key": "project/forsetti"],
            clientID: client
        )
        XCTAssertTrue(missing.ok)
        XCTAssertEqual(missing.payload["found"] as? Bool, false)
    }

    func testMemoryPersistsAcrossAppBootstrap() throws {
        let client = ClientID("persist-client")
        do {
            let app = try ForgeApp.bootstrap(home: tempHome)
            let set = try app.tools.call(
                name: "memory_set",
                arguments: ["key": "task/current", "body": "Ship durable memory MCP"],
                clientID: client
            )
            XCTAssertTrue(set.ok)
        }
        // New process/composition root, same home → note still present.
        let app2 = try ForgeApp.bootstrap(home: tempHome)
        let get = try app2.tools.call(
            name: "memory_get",
            arguments: ["key": "task/current"],
            clientID: client
        )
        XCTAssertTrue(get.ok)
        XCTAssertEqual(get.payload["found"] as? Bool, true)
        XCTAssertEqual(get.payload["body"] as? String, "Ship durable memory MCP")
    }

    func testAgentAndContinuitySystemKeysHiddenFromDefaultMemoryQueries() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("sys-client")

        // Agent session writes agent_run/* system keys.
        let start = try app.sessions.start(
            agentID: "explore",
            goal: "map",
            clientID: client,
            cwd: tempHome.path
        )
        XCTAssertEqual(start["ok"] as? Bool, true)

        _ = try app.tools.call(
            name: "memory_set",
            arguments: ["key": "user/note", "body": "visible"],
            clientID: client
        )
        let handoff = try app.tools.call(
            name: "session_handoff",
            arguments: ["goal": "Verify memory and continuity coexistence"],
            clientID: client
        )
        XCTAssertTrue(handoff.ok, "\(handoff.payload)")
        let handoffID = try XCTUnwrap(handoff.payload["handoff_id"] as? String)

        let listDefault = try app.tools.call(
            name: "memory_list",
            arguments: [:],
            clientID: client
        )
        XCTAssertTrue(listDefault.ok)
        let notes = listDefault.payload["notes"] as? [[String: Any]] ?? []
        let keys = notes.compactMap { $0["key"] as? String }
        XCTAssertTrue(keys.contains("user/note"))
        XCTAssertFalse(keys.contains(where: { $0.hasPrefix("agent_run/") }))
        XCTAssertFalse(keys.contains(where: { $0.hasPrefix("continuity/") }))
        XCTAssertEqual(listDefault.payload["total"] as? Int, 1)

        let searchDefault = try app.tools.call(
            name: "memory_search",
            arguments: ["query": handoffID],
            clientID: client
        )
        XCTAssertTrue(searchDefault.ok)
        XCTAssertEqual(searchDefault.payload["count"] as? Int, 0)

        let status = try app.tools.call(name: "forge_status", arguments: [:], clientID: client)
        XCTAssertTrue(status.ok)
        XCTAssertEqual(status.payload["memory_note_count"] as? Int, 1)

        let listAll = try app.tools.call(
            name: "memory_list",
            arguments: ["include_system": true],
            clientID: client
        )
        let allNotes = listAll.payload["notes"] as? [[String: Any]] ?? []
        let allKeys = allNotes.compactMap { $0["key"] as? String }
        XCTAssertTrue(allKeys.contains(where: { $0.hasPrefix("agent_run/") }))
        XCTAssertTrue(allKeys.contains("continuity/latest"))
        XCTAssertTrue(allKeys.contains("continuity/resume_ready"))

        let searchAll = try app.tools.call(
            name: "memory_search",
            arguments: ["query": handoffID, "include_system": true],
            clientID: client
        )
        XCTAssertTrue(searchAll.ok)
        let matchingKeys = (searchAll.payload["notes"] as? [[String: Any]] ?? [])
            .compactMap { $0["key"] as? String }
        XCTAssertTrue(matchingKeys.contains("continuity/latest"))
        XCTAssertTrue(matchingKeys.contains("continuity/resume_ready"))
    }

    func testTelemetrySeparatesMemoryAndContinuityToolPacks() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let snapshot = ForgeCollector(
            paths: app.paths,
            store: app.store,
            catalog: app.catalog,
            toolNames: { app.tools.toolNames }
        ).collect()
        let packs = Set(snapshot.mcpPacks.map(\.pack))
        XCTAssertTrue(packs.contains("memory"), "\(snapshot.mcpPacks)")
        XCTAssertTrue(packs.contains("continuity"), "\(snapshot.mcpPacks)")
        XCTAssertEqual(snapshot.mcpTools.first(where: { $0.name == "memory_set" })?.pack, "memory")
        XCTAssertEqual(snapshot.mcpTools.first(where: { $0.name == "context_get" })?.pack, "continuity")
    }

    func testMemoryAvailableWithoutAgentSession() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        let client = ClientID("no-session")
        let result = try app.tools.call(
            name: "memory_set",
            arguments: ["key": "prefs/style", "body": "prefer small diffs"],
            clientID: client
        )
        XCTAssertTrue(result.ok, "memory tools must work without agent_run_start: \(result.payload)")
    }

    func testMemoryAvailableDuringAgentSessionEvenIfNotInToolsPrimary() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        let client = ClientID("during-session")
        // implement tools_primary does not include memory_*, but lifecycle tools must still allow it.
        let start = try app.sessions.start(
            agentID: "implement",
            goal: "edit code",
            clientID: client,
            cwd: tempHome.path
        )
        XCTAssertEqual(start["ok"] as? Bool, true)

        let set = try app.tools.call(
            name: "memory_set",
            arguments: ["key": "task/current", "body": "still writing memory mid-session"],
            clientID: client
        )
        XCTAssertTrue(set.ok, "memory must remain available during agent sessions: \(set.payload)")
    }

    func testInvalidKeyRejected() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        let client = ClientID("bad-key")
        let empty = try app.tools.call(
            name: "memory_set",
            arguments: ["key": "   ", "body": "x"],
            clientID: client
        )
        XCTAssertFalse(empty.ok)
        XCTAssertEqual(empty.payload["code"] as? String, "invalid_key")
    }

    func testForgeStatusIncludesMemoryCount() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        let client = ClientID("status-client")
        _ = try app.tools.call(
            name: "memory_set",
            arguments: ["key": "a", "body": "1"],
            clientID: client
        )
        let status = try app.tools.call(name: "forge_status", arguments: [:], clientID: client)
        XCTAssertTrue(status.ok)
        XCTAssertEqual(status.payload["memory_note_count"] as? Int, 1)
    }

    func testTagFilterAndContentAlias() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        let client = ClientID("tag-client")
        let set = try app.tools.call(
            name: "memory_set",
            arguments: [
                "key": "project/alpha",
                "content": "alias body works",
                "tags": "project, alpha",
            ],
            clientID: client
        )
        XCTAssertTrue(set.ok, "\(set.payload)")

        let byTag = try app.tools.call(
            name: "memory_list",
            arguments: ["tag": "alpha", "include_body": true],
            clientID: client
        )
        XCTAssertTrue(byTag.ok)
        XCTAssertEqual(byTag.payload["count"] as? Int, 1)
        let notes = byTag.payload["notes"] as? [[String: Any]] ?? []
        XCTAssertEqual(notes.first?["body"] as? String, "alias body works")
    }

    func testMemoryReadPathsHonorExpiredDeadline() throws {
        let store = try SQLiteStore(path: tempHome.appendingPathComponent("memory-read-deadline.sqlite3"))
        defer { store.close() }
        try store.memorySet(key: "deadline/read", body: "seed", tags: ["deadline"])

        let operations: [(ToolCallCancellation) throws -> Void] = [
            { control in _ = try store.memoryGet(key: "deadline/read", cancellation: control) },
            { control in _ = try store.memoryGetNote(key: "deadline/read", cancellation: control) },
            { control in _ = try store.memoryList(cancellation: control) },
            { control in _ = try store.memorySearch(query: "seed", cancellation: control) },
            { control in _ = try store.memoryCount(cancellation: control) },
        ]

        for operation in operations {
            let expired = ToolCallCancellation(timeoutSeconds: 0)
            XCTAssertThrowsError(try operation(expired)) { error in
                XCTAssertTrue(error is ToolCallDeadlineExceeded, "unexpected error: \(error)")
            }
        }
    }

    func testMemoryToolPackDeadlinePreemptsDatabaseLockWithoutPartialWrite() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let databaseURL = app.store.path
        var locker: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &locker), SQLITE_OK)
        let opened = try XCTUnwrap(locker)
        defer {
            sqlite3_exec(opened, "ROLLBACK;", nil, nil, nil)
            sqlite3_close(opened)
        }
        XCTAssertEqual(sqlite3_exec(opened, "BEGIN IMMEDIATE;", nil, nil, nil), SQLITE_OK)

        let control = ToolCallCancellation(timeoutSeconds: 0.1)
        let startedAt = Date()
        XCTAssertThrowsError(
            try MemoryToolPack().handle(
                name: "memory_set",
                arguments: [
                    "key": "deadline/locked",
                    "body": "must not commit",
                ],
                context: nil,
                clientID: ClientID("memory-deadline-lock"),
                app: app,
                cancellation: control
            )
        ) { error in
            XCTAssertTrue(error is ToolCallDeadlineExceeded, "unexpected error: \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)

        sqlite3_exec(opened, "ROLLBACK;", nil, nil, nil)
        XCTAssertNil(try app.store.memoryGet(key: "deadline/locked"))
    }

    func testMemoryCancellationPreemptsActiveDatabaseLockWithoutPartialWrite() async throws {
        let databaseURL = tempHome.appendingPathComponent("memory-cancel-lock.sqlite3")
        let busyReached = DispatchSemaphore(value: 0)
        let store = try SQLiteStore(
            path: databaseURL,
            postMigrationCommitObserver: nil,
            sqliteBusyRetryObserver: {
                busyReached.signal()
            }
        )
        defer { store.close() }
        var locker: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &locker), SQLITE_OK)
        let opened = try XCTUnwrap(locker)
        defer {
            sqlite3_exec(opened, "ROLLBACK;", nil, nil, nil)
            sqlite3_close(opened)
        }
        XCTAssertEqual(sqlite3_exec(opened, "BEGIN IMMEDIATE;", nil, nil, nil), SQLITE_OK)

        let control = ToolCallCancellation(timeoutSeconds: 5)
        let operation = Task.detached {
            try store.memorySet(
                key: "cancel/locked",
                body: "must not commit",
                cancellation: control
            )
        }
        XCTAssertEqual(busyReached.wait(timeout: .now() + 1), .success)
        let cancelledAt = Date()
        control.cancel()
        do {
            try await operation.value
            XCTFail("cancelled memory write returned success")
        } catch is CancellationError {
            // Expected: the active SQLite busy handler observed cancellation.
        } catch {
            XCTFail("unexpected cancellation error: \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 1)

        sqlite3_exec(opened, "ROLLBACK;", nil, nil, nil)
        XCTAssertNil(try store.memoryGet(key: "cancel/locked"))
    }

    func testMemoryCancellationAtPreCommitRollsBackWrite() throws {
        let control = ToolCallCancellation(timeoutSeconds: 5)
        let store = try SQLiteStore(
            path: tempHome.appendingPathComponent("memory-precommit.sqlite3"),
            postMigrationCommitObserver: nil,
            beforeMutationCommitObserver: { kind in
                if kind == .memory { control.cancel() }
            }
        )
        defer { store.close() }

        XCTAssertThrowsError(
            try store.memorySet(
                key: "cancel/precommit",
                body: "must roll back",
                cancellation: control
            )
        ) { error in
            XCTAssertTrue(error is CancellationError, "unexpected error: \(error)")
        }
        XCTAssertNil(try store.memoryGet(key: "cancel/precommit"))
    }

    func testMemoryCancellationAfterCommitReturnsCommittedResult() throws {
        let control = ToolCallCancellation(timeoutSeconds: 5)
        let store = try SQLiteStore(
            path: tempHome.appendingPathComponent("memory-postcommit.sqlite3"),
            postMigrationCommitObserver: nil,
            didMutationCommitObserver: { kind in
                if kind == .memory { control.cancel() }
            }
        )
        defer { store.close() }

        try store.memorySet(
            key: "cancel/postcommit",
            body: "committed result is authoritative",
            cancellation: control
        )

        XCTAssertTrue(control.isCancelled)
        XCTAssertEqual(
            try store.memoryGet(key: "cancel/postcommit"),
            "committed result is authoritative"
        )
    }
}
