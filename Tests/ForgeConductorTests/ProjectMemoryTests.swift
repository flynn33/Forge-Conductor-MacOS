// ProjectMemoryTests.swift
// Verifies project isolation, durability, conformance, migration safety, and bounds.

import XCTest
import SQLite3
@testable import ForgeConductorCore

final class ProjectMemoryTests: XCTestCase {
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

        app = try ForgeApp.bootstrap(home: home)
        let failed = try app!.tools.call(
            name: "project_memory.initialize", arguments: ["project_path": projectA.path],
            clientID: ClientID("project-memory-corruption")
        )
        XCTAssertFalse(failed.ok)
        XCTAssertEqual(failed.payload["code"] as? String, "integrity_failure")
        XCTAssertEqual(try Data(contentsOf: database), corrupt)
        let preserved = try FileManager.default.contentsOfDirectory(at: projectDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("memory.corrupt-") }
        XCTAssertEqual(preserved.count, 1)
        XCTAssertEqual(try Data(contentsOf: preserved[0]), corrupt)
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
}
