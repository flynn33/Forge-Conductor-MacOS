// MemoryToolTests.swift
// Verifies durable SQLite-backed memory MCP tools against an isolated temp home.
// Does not touch the operator's live ~/.forge-conductor install.

import XCTest
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
        let names = Set(app.tools.toolNames)
        for need in ["memory_set", "memory_get", "memory_list", "memory_delete", "memory_search"] {
            XCTAssertTrue(names.contains(need), "missing tool \(need)")
        }
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

    func testSystemAgentKeysHiddenFromDefaultList() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
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

        let listAll = try app.tools.call(
            name: "memory_list",
            arguments: ["include_system": true],
            clientID: client
        )
        let allNotes = listAll.payload["notes"] as? [[String: Any]] ?? []
        let allKeys = allNotes.compactMap { $0["key"] as? String }
        XCTAssertTrue(allKeys.contains(where: { $0.hasPrefix("agent_run/") }))
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
}
