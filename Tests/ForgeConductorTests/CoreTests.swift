// CoreTests.swift
// Exercises the Core composition root, persistence, tools, sessions, and local services.
// A fresh temporary home isolates every test from the operator's installed configuration.

import XCTest
@testable import ForgeConductorCore

final class CoreTests: XCTestCase {
    private var tempHome: URL!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempHome)
    }

    @discardableResult
    private func bindProjectContext(
        app: ForgeApp,
        clientID: ClientID,
        projectRoot: URL? = nil
    ) throws -> ToolResult {
        try trustProjectRoot(projectRoot ?? tempHome, app: app)
        let result = try app.tools.call(
            name: "project_memory.initialize",
            arguments: ["project_path": (projectRoot ?? tempHome).path],
            clientID: clientID
        )
        XCTAssertTrue(result.ok)
        return result
    }

    @discardableResult
    private func startAgentRun(
        app: ForgeApp,
        clientID: ClientID,
        agentID: String,
        goal: String,
        projectRoot: URL? = nil
    ) throws -> ToolResult {
        try trustProjectRoot(projectRoot ?? tempHome, app: app)
        let result = try app.tools.call(
            name: "agent_run_start",
            arguments: [
                "agent_id": agentID,
                "goal": goal,
                "cwd": (projectRoot ?? tempHome).path,
            ],
            clientID: clientID
        )
        XCTAssertTrue(result.ok, "\(result.payload)")
        return result
    }

    private func trustProjectRoot(_ projectRoot: URL, app: ForgeApp) throws {
        var roots = app.config.model.allowedRoots
        let path = projectRoot.resolvingSymlinksInPath().standardizedFileURL.path
        if !roots.contains(path) { roots.append(path) }
        _ = try app.config.update(["allowed_roots": roots], save: false)
    }

    // MARK: - Bootstrap / paths

    func testBootstrapCreatesLayout() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.paths.home.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.paths.storeSQLite.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.paths.configJSON.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.paths.agentsDir.path))
        XCTAssertEqual(app.paths.home.standardizedFileURL, tempHome.standardizedFileURL)
    }

    func testDoctorPasses() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        let doc = try app.doctor()
        XCTAssertEqual(doc["ok"] as? Bool, true)
        let checks = doc["checks"] as? [[String: Any]] ?? []
        XCTAssertFalse(checks.isEmpty)
    }

    func testCatalogHasBuiltins() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        let ids = Set(app.catalog.all().map(\.id))
        for need in [
            "explore", "implement", "docs", "debug", "precommit-audit",
            "plan", "review", "test", "security", "research",
        ] {
            XCTAssertTrue(ids.contains(need), "missing agent \(need)")
        }
        XCTAssertNotNil(app.catalog.get("docs")?.tools.contains("pdf_write"))
        XCTAssertEqual(app.catalog.get("docs")?.tools.contains("pdf_write"), true)
    }

    func testAgentPlaybooksAreRobust() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        let agents = app.catalog.all()
        XCTAssertGreaterThanOrEqual(agents.count, 10)
        for spec in agents {
            XCTAssertFalse(spec.description.isEmpty, "\(spec.id) missing description")
            XCTAssertFalse(spec.tools.isEmpty, "\(spec.id) needs tools")
            XCTAssertFalse(spec.firstMoves.isEmpty, "\(spec.id) needs first_moves")
            XCTAssertFalse(spec.doneDefinition.isEmpty, "\(spec.id) needs done_definition")
            XCTAssertFalse(spec.outputSchema.isEmpty, "\(spec.id) needs output_schema")
            XCTAssertTrue(
                spec.body.contains("agent_run_complete") || spec.doneDefinition.contains(where: { $0.contains("agent_run_complete") }),
                "\(spec.id) must require agent_run_complete"
            )
            // Playbook body should be more than a one-liner when loaded from markdown
            XCTAssertGreaterThan(spec.body.count, 40, "\(spec.id) playbook body too thin")
        }
        // Recommend routes for specialized tasks
        XCTAssertEqual(app.catalog.recommend(task: "security audit secrets auth").id, "security")
        XCTAssertEqual(app.catalog.recommend(task: "research how the MCP server works").id, "research")
    }

    func testRecommendDocs() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        let spec = app.catalog.recommend(task: "Write a PDF manual for the operator")
        XCTAssertEqual(spec.id, "docs")
    }

    // MARK: - Sessions

    func testSessionLifecycleComplete() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        let client = ClientID("test-client")
        let start = try app.sessions.start(
            agentID: "explore",
            goal: "Map the test tree",
            clientID: client
        )
        XCTAssertEqual(start["ok"] as? Bool, true)
        let sid = start["session_id"] as! String
        XCTAssertFalse(sid.isEmpty)

        let status = try app.sessions.status(sessionID: SessionID(sid), clientID: client)
        XCTAssertEqual(status["must_complete"] as? Bool, true)

        let report: [String: Any] = [
            "layout": "root with Sources",
            "entry_points": "main.swift",
            "build_test_run": "swift test",
            "dependencies_config": "SPM only",
            "risks": "none",
            "next_agent": "plan",
        ]
        let done = try app.sessions.complete(
            sessionID: SessionID(sid),
            report: report,
            clientID: client
        )
        XCTAssertEqual(done["ok"] as? Bool, true)
        XCTAssertEqual(done["schema_complete"] as? Bool, true)

        let sess = try app.store.sessionGet(id: SessionID(sid))
        XCTAssertEqual(sess?.status, .closed)
    }

    func testSessionIncompleteSchemaWarns() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        let client = ClientID("c2")
        let start = try app.sessions.start(agentID: "docs", goal: "Write README", clientID: client)
        let sid = start["session_id"] as! String
        let done = try app.sessions.complete(
            sessionID: SessionID(sid),
            report: ["summary": "only summary"],
            clientID: client
        )
        XCTAssertEqual(done["ok"] as? Bool, true)
        XCTAssertEqual(done["schema_complete"] as? Bool, false)
        let missing = done["missing_schema_keys"] as? [String] ?? []
        XCTAssertTrue(missing.contains("files_touched"))
    }

    func testSupersedeClosesPriorOpen() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        let client = ClientID("c3")
        let a = try app.sessions.start(agentID: "explore", goal: "first", clientID: client)
        let sid1 = a["session_id"] as! String
        let b = try app.sessions.start(agentID: "debug", goal: "second", clientID: client)
        let sid2 = b["session_id"] as! String
        XCTAssertNotEqual(sid1, sid2)
        let s1 = try app.store.sessionGet(id: SessionID(sid1))
        XCTAssertEqual(s1?.status, .closed)
        let s2 = try app.store.sessionGet(id: SessionID(sid2))
        XCTAssertEqual(s2?.status, .open)
    }

    func testBindingRehydrateFromMemory() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        let client = ClientID("c4")
        let start = try app.sessions.start(agentID: "plan", goal: "design feature X", clientID: client)
        let sid = start["session_id"] as! String
        // Simulate process restart: new service stack, same store
        let app2 = try ForgeApp.bootstrap(home: tempHome)
        let binding = try app2.sessions.rehydrate(clientID: client)
        XCTAssertNotNil(binding)
        XCTAssertEqual(binding?.sessionID.rawValue, sid)
        XCTAssertEqual(binding?.agentID, "plan")
    }

    func testPruneStaleClosesIdle() throws {
        let clock = FixedClock(Date())
        let app = try ForgeApp.bootstrap(home: tempHome, clock: clock)
        // Use short TTL by constructing service directly is hard; instead manipulate updated_at via store end/start and clock jump
        // Direct store session + advance clock past idleTTL (default 14400)
        let client = ClientID("c5")
        let s = try app.store.sessionStart(agentID: "explore", clientID: client)
        // Jump clock far past idle TTL
        clock.date = clock.date.addingTimeInterval(20_000)
        try app.sessions.pruneStale()
        let after = try app.store.sessionGet(id: s.id)
        XCTAssertEqual(after?.status, .closed)
        XCTAssertTrue(after?.summary?.contains("auto_closed") == true || after?.summary?.contains("abandoned") == true)
    }

    // MARK: - Tools

    func testForgeStatusTool() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        let result = try app.tools.call(name: "forge_status", arguments: [:], clientID: ClientID("t1"))
        XCTAssertTrue(result.ok, "\(result.payload)")
        XCTAssertEqual(result.payload["runtime"] as? String, "swift")
        XCTAssertEqual(result.payload["version"] as? String, ForgeApp.version)
    }

    func testFSWriteRead() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        let client = ClientID("t2")
        try bindProjectContext(app: app, clientID: client)
        let path = tempHome.appendingPathComponent("note.txt").path
        let w = try app.tools.call(
            name: "fs_write",
            arguments: ["path": path, "content": "hello forge"],
            clientID: client
        )
        XCTAssertTrue(w.ok)
        let r = try app.tools.call(name: "fs_read", arguments: ["path": path], clientID: client)
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.payload["content"] as? String, "hello forge")
        XCTAssertEqual(r.payload["total_lines"] as? Int, 1)
        XCTAssertEqual(r.payload["has_more"] as? Bool, false)
    }

    func testFSReadHonorsLineOffsetAndLength() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let path = tempHome.appendingPathComponent("windowed.txt").path
        let body = (1...10).map { "line-\($0)" }.joined(separator: "\n")
        let windowClient = ClientID("fs-window")
        let eofClient = ClientID("fs-window-eof")
        try bindProjectContext(app: app, clientID: windowClient)
        try bindProjectContext(app: app, clientID: eofClient)
        let w = try app.tools.call(
            name: "fs_write",
            arguments: ["path": path, "content": body],
            clientID: windowClient
        )
        XCTAssertTrue(w.ok)

        let r = try app.tools.call(
            name: "fs_read",
            arguments: ["path": path, "offset": 3, "length": 2],
            clientID: windowClient
        )
        XCTAssertTrue(r.ok, "\(r.payload)")
        XCTAssertEqual(r.payload["content"] as? String, "line-3\nline-4")
        XCTAssertEqual(r.payload["total_lines"] as? Int, 10)
        XCTAssertEqual(r.payload["start_line"] as? Int, 3)
        XCTAssertEqual(r.payload["end_line"] as? Int, 4)
        XCTAssertEqual(r.payload["has_more"] as? Bool, true)
        XCTAssertEqual(r.payload["next_offset"] as? Int, 5)

        let pastEOF = try app.tools.call(
            name: "fs_read",
            arguments: ["path": path, "offset": 50, "length": 10],
            clientID: eofClient
        )
        XCTAssertTrue(pastEOF.ok, "\(pastEOF.payload)")
        XCTAssertEqual(pastEOF.payload["content"] as? String, "")
        XCTAssertEqual(pastEOF.payload["has_more"] as? Bool, false)
    }

    func testFSReadHandlesEmptyFileAndMaximumLength() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }

        let emptyPath = tempHome.appendingPathComponent("empty.txt").path
        let emptyWriteClient = ClientID("fs-empty-write")
        let emptyReadClient = ClientID("fs-empty-read")
        try bindProjectContext(app: app, clientID: emptyWriteClient)
        try bindProjectContext(app: app, clientID: emptyReadClient)
        _ = try app.tools.call(
            name: "fs_write",
            arguments: ["path": emptyPath, "content": ""],
            clientID: emptyWriteClient
        )
        let empty = try app.tools.call(
            name: "fs_read",
            arguments: ["path": emptyPath],
            clientID: emptyReadClient
        )
        XCTAssertTrue(empty.ok, "\(empty.payload)")
        XCTAssertEqual(empty.payload["content"] as? String, "")
        XCTAssertEqual(empty.payload["total_lines"] as? Int, 0)
        XCTAssertEqual(empty.payload["line_count"] as? Int, 0)
        XCTAssertEqual(empty.payload["note"] as? String, "File is empty.")

        let boundedPath = tempHome.appendingPathComponent("bounded.txt").path
        let boundedWriteClient = ClientID("fs-bounded-write")
        let boundedReadClient = ClientID("fs-bounded-read")
        try bindProjectContext(app: app, clientID: boundedWriteClient)
        try bindProjectContext(app: app, clientID: boundedReadClient)
        _ = try app.tools.call(
            name: "fs_write",
            arguments: ["path": boundedPath, "content": "one\ntwo\nthree"],
            clientID: boundedWriteClient
        )
        let maximum = try app.tools.call(
            name: "fs_read",
            arguments: ["path": boundedPath, "offset": 1, "length": Int.max],
            clientID: boundedReadClient
        )
        XCTAssertTrue(maximum.ok, "\(maximum.payload)")
        XCTAssertEqual(maximum.payload["content"] as? String, "one\ntwo\nthree")
        XCTAssertEqual(maximum.payload["end_line"] as? Int, 3)
        XCTAssertEqual(maximum.payload["has_more"] as? Bool, false)
    }

    func testFSEditAppliesUniqueMatchAndReportsNoMatch() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let path = tempHome.appendingPathComponent("edit-me.txt").path
        let writeClient = ClientID("fs-edit-write")
        let editClient = ClientID("fs-edit-apply")
        let verifyClient = ClientID("fs-edit-verify")
        try bindProjectContext(app: app, clientID: writeClient)
        try bindProjectContext(app: app, clientID: editClient)
        try bindProjectContext(app: app, clientID: verifyClient)
        _ = try app.tools.call(
            name: "fs_write",
            arguments: ["path": path, "content": "alpha target-marker beta\ntarget-marker gamma"],
            clientID: writeClient
        )

        // Exact, uniquely matched edit: the old string occurs once.
        let applied = try app.tools.call(
            name: "fs_edit",
            arguments: [
                "path": path,
                "old": "alpha target-marker beta",
                "new": "alpha replaced-marker beta",
            ],
            clientID: editClient
        )
        XCTAssertTrue(applied.ok, "\(applied.payload)")
        XCTAssertEqual(applied.payload["path"] as? String, path)
        XCTAssertEqual(applied.payload["replacements"] as? Int, 1)

        let reread = try app.tools.call(
            name: "fs_read",
            arguments: ["path": path],
            clientID: verifyClient
        )
        XCTAssertTrue(reread.ok, "\(reread.payload)")
        XCTAssertEqual(
            reread.payload["content"] as? String,
            "alpha replaced-marker beta\ntarget-marker gamma"
        )

        // Existing edit contract: a non-unique old replaces every occurrence
        // and reports the count; a targeted edit must supply a unique match.
        let multiPath = tempHome.appendingPathComponent("edit-dup.txt").path
        _ = try app.tools.call(
            name: "fs_write",
            arguments: ["path": multiPath, "content": "dup one\ndup two"],
            clientID: writeClient
        )
        let multi = try app.tools.call(
            name: "fs_edit",
            arguments: ["path": multiPath, "old": "dup", "new": "single"],
            clientID: editClient
        )
        XCTAssertTrue(multi.ok, "\(multi.payload)")
        XCTAssertEqual(multi.payload["replacements"] as? Int, 2)

        // A non-matching old fails with a distinct no_match code.
        let miss = try app.tools.call(
            name: "fs_edit",
            arguments: ["path": path, "old": "absent-marker", "new": "nope"],
            clientID: editClient
        )
        XCTAssertFalse(miss.ok)
        XCTAssertEqual(miss.payload["code"] as? String, "no_match")
    }

    func testIdenticalToolCallLoopSoftHandoffThenHardBlock() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let path = tempHome.appendingPathComponent("loop.txt").path
        let setupClient = ClientID("loop-setup")
        let client = ClientID("loop-client")
        try bindProjectContext(app: app, clientID: setupClient)
        try bindProjectContext(app: app, clientID: client)
        _ = try app.tools.call(
            name: "fs_write",
            arguments: ["path": path, "content": "stable"],
            clientID: setupClient
        )
        let args: [String: Any] = ["path": path, "offset": 1, "length": 1]
        var softHandoffID: String?
        for i in 1...8 {
            let r = try app.tools.call(name: "fs_read", arguments: args, clientID: client)
            XCTAssertTrue(r.ok, "call \(i) should succeed: \(r.payload)")
            if i == 4 {
                XCTAssertEqual(r.payload["handoff_required"] as? Bool, true)
                softHandoffID = r.payload["handoff_id"] as? String
                XCTAssertNotNil(softHandoffID)
            } else {
                XCTAssertNil(r.payload["handoff_required"], "call \(i)")
            }
        }
        let blocked = try app.tools.call(name: "fs_read", arguments: args, clientID: client)
        XCTAssertFalse(blocked.ok)
        XCTAssertEqual(blocked.payload["code"] as? String, "identical_call_loop")
        XCTAssertEqual(blocked.payload["handoff_required"] as? Bool, true)
        XCTAssertEqual(blocked.payload["handoff_id"] as? String, softHandoffID)
    }

    func testPDFWrite() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        let client = ClientID("t3")
        try bindProjectContext(app: app, clientID: client)
        let path = tempHome.appendingPathComponent("manual.pdf").path
        let r = try app.tools.call(
            name: "pdf_write",
            arguments: [
                "path": path,
                "content": "# Title\n\nHello PDF export from Forge.\n\n## Section\nBody text.",
                "title": "Test Manual",
            ],
            clientID: client
        )
        XCTAssertTrue(r.ok, "\(r.payload)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let size = attrs[.size] as? NSNumber
        XCTAssertGreaterThan(size?.intValue ?? 0, 100)
    }

    func testFilesystemToolWritesOutsideSelectedProjectRoot() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let outside = tempHome.deletingLastPathComponent()
            .appendingPathComponent("forge-outside-\(UUID().uuidString).txt")
        let client = ClientID("path-denied")
        try bindProjectContext(app: app, clientID: client)

        let result = try app.tools.call(
            name: "fs_write",
            arguments: ["path": outside.path, "content": "native-access"],
            clientID: client
        )

        XCTAssertTrue(result.ok, "\(result.payload)")
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "native-access")
        try? FileManager.default.removeItem(at: outside)
    }

    func testBoundNativeFilesystemAndSearchToolsCanReadOutsideProjectRoot() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let providerState = app.paths.managedProvidersDir.appendingPathComponent("provider-state.json")
        try Data("provider-secret-sentinel".utf8).write(to: providerState, options: .atomic)
        try Data("manager-secret-sentinel".utf8).write(
            to: app.paths.managerControlCredential,
            options: .atomic
        )
        let clientID = ClientID("unbound-control-state")
        try bindProjectContext(app: app, clientID: clientID)
        let read = try app.tools.call(
            name: "fs_read",
            arguments: ["path": providerState.path],
            clientID: clientID
        )
        XCTAssertTrue(read.ok, "\(read.payload)")
        XCTAssertEqual(read.payload["content"] as? String, "provider-secret-sentinel")
        let search = try app.tools.call(
            name: "search_text",
            arguments: ["path": app.paths.managedProvidersDir.path, "pattern": "provider-secret-sentinel"],
            clientID: clientID
        )
        XCTAssertTrue(search.ok, "\(search.payload)")
        XCTAssertEqual(search.payload["count"] as? Int, 1)
    }

    func testConfiguredWorkspaceRootAllowsFilesystemTool() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let workspace = tempHome.deletingLastPathComponent()
            .appendingPathComponent("forge-workspace-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        _ = try app.config.update(["allowed_roots": [workspace.path]], save: false)
        let output = workspace.appendingPathComponent("allowed.txt")
        let client = ClientID("path-allowed")
        try startAgentRun(
            app: app,
            clientID: client,
            agentID: "implement",
            goal: "write inside the configured workspace",
            projectRoot: workspace
        )

        let result = try app.tools.call(
            name: "fs_write",
            arguments: ["path": output.path, "content": "allowed"],
            clientID: client
        )

        XCTAssertTrue(result.ok, "\(result.payload)")
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "allowed")
    }

    func testFilesystemToolFollowsNativeSymlinkOutsideProjectRoot() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let outside = tempHome.deletingLastPathComponent()
            .appendingPathComponent("forge-symlink-target-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = tempHome.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let client = ClientID("symlink-denied")
        try bindProjectContext(app: app, clientID: client)

        let result = try app.tools.call(
            name: "fs_write",
            arguments: ["path": link.appendingPathComponent("secret.txt").path, "content": "native"],
            clientID: client
        )

        XCTAssertTrue(result.ok, "\(result.payload)")
        XCTAssertEqual(
            try String(contentsOf: outside.appendingPathComponent("secret.txt"), encoding: .utf8),
            "native"
        )
    }

    func testNativeToolMatrixWorksOutsideSelectedProjectRoot() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("native-host-access-matrix")
        try bindProjectContext(app: app, clientID: client)
        let external = tempHome.deletingLastPathComponent()
            .appendingPathComponent("forge-native-matrix-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: external) }

        func call(_ name: String, _ arguments: [String: Any]) throws -> ToolResult {
            let result = try app.tools.call(name: name, arguments: arguments, clientID: client)
            XCTAssertTrue(result.ok, "\(name): \(result.payload)")
            return result
        }

        _ = try call("fs_mkdir", ["path": external.path])
        let text = external.appendingPathComponent("notes.txt")
        _ = try call("fs_write", ["path": text.path, "content": "alpha native marker"])
        _ = try call("fs_edit", ["path": text.path, "old": "alpha", "new": "beta"])
        let read = try call("fs_read", ["path": text.path])
        XCTAssertEqual(read.payload["content"] as? String, "beta native marker")
        let list = try call("fs_list", ["path": external.path])
        XCTAssertTrue((list.payload["entries"] as? [String])?.contains("notes.txt") == true)
        let glob = try call("fs_glob", ["path": external.path, "pattern": "*.txt"])
        XCTAssertTrue("\(glob.payload)".contains("notes.txt"))
        let search = try call(
            "search_text",
            ["path": external.path, "pattern": "native marker"]
        )
        XCTAssertEqual(search.payload["count"] as? Int, 1)

        let writtenPDF = external.appendingPathComponent("written.pdf")
        _ = try call(
            "pdf_write",
            ["path": writtenPDF.path, "content": "# Native PDF", "title": "Native PDF"]
        )
        let convertedPDF = external.appendingPathComponent("converted.pdf")
        _ = try call(
            "pdf_from_file",
            ["source_path": text.path, "dest_path": convertedPDF.path]
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: writtenPDF.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: convertedPDF.path))

        let repository = external.appendingPathComponent("repository", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        let initialized = try ProcessRunner().run(
            executable: "/usr/bin/git",
            arguments: ["init", "-q"],
            currentDirectory: repository.path,
            timeoutSec: 5
        )
        XCTAssertEqual(initialized.exitCode, 0, initialized.stderr)
        let tracked = repository.appendingPathComponent("tracked.txt")
        _ = try call("fs_write", ["path": tracked.path, "content": "tracked"])
        let hookMarker = external.appendingPathComponent("git-hook-ps.txt")
        let hook = repository.appendingPathComponent(".git/hooks/pre-commit")
        try "#!/bin/sh\n/bin/ps -p $$ -o pid= > '\(hookMarker.path)'\n"
            .write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: hook.path
        )
        _ = try call("git_status", ["cwd": repository.path])
        _ = try call("git_diff", ["cwd": repository.path])
        _ = try call("git_add", ["cwd": repository.path, "path": "tracked.txt"])
        _ = try call("git_commit", ["cwd": repository.path, "message": "test: native access"])
        _ = try call("git_log", ["cwd": repository.path])
        XCTAssertFalse((try String(contentsOf: hookMarker, encoding: .utf8))
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        let shell = try call(
            "shell_exec",
            ["command": "/bin/ps -p $$ -o pid= >/dev/null && /bin/pwd", "cwd": external.path]
        )
        XCTAssertEqual(
            (shell.payload["stdout"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            RuntimePathCanonicalizer.canonicalExistingURL(external).path
        )

        let moved = external.appendingPathComponent("moved.txt")
        let move = try call("fs_move", ["path": text.path, "dest": moved.path])
        XCTAssertEqual(move.payload["protection_mode"] as? String, "local_bounded")
        let delete = try call("fs_delete", ["path": moved.path])
        XCTAssertEqual(delete.payload["protection_mode"] as? String, "local_bounded")
        XCTAssertFalse(FileManager.default.fileExists(atPath: moved.path))
    }

    func testNativeDeletionProtectsHomeVolumeAndWorkspaceRoots() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("native-destructive-root-guard")
        try bindProjectContext(app: app, clientID: client)

        var protectedTargets = [
            FileManager.default.homeDirectoryForCurrentUser,
            FileManager.default.homeDirectoryForCurrentUser.deletingLastPathComponent(),
            tempHome!,
            tempHome.deletingLastPathComponent(),
        ]
        if let mounted = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: []
        )?.first(where: { $0.path != "/" }) {
            protectedTargets.append(mounted)
        }

        for (index, target) in protectedTargets.enumerated() {
            let result = try app.tools.call(
                name: "fs_delete",
                arguments: ["path": target.path],
                clientID: client
            )
            XCTAssertFalse(result.ok, "target[\(index)]=\(target.path)")
            XCTAssertEqual(
                result.payload["code"] as? String,
                "workspace_root_protected",
                "target[\(index)]=\(target.path)"
            )
        }
    }

    func testNativeDeletionProtectsCaseAliasOfWorkspaceRoot() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let workspace = tempHome.appendingPathComponent(
            "CaseAliasWorkspace-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let client = ClientID("native-case-alias-root-guard")
        try bindProjectContext(app: app, clientID: client, projectRoot: workspace)

        let aliasedWorkspace = workspace.deletingLastPathComponent().appendingPathComponent(
            workspace.lastPathComponent.lowercased(),
            isDirectory: true
        )
        guard aliasedWorkspace.path != workspace.path,
              FileManager.default.fileExists(atPath: aliasedWorkspace.path) else {
            throw XCTSkip("The test volume is case-sensitive and has no case alias")
        }

        for (tool, arguments) in [
            ("fs_delete", ["path": aliasedWorkspace.path]),
            (
                "fs_move",
                [
                    "path": aliasedWorkspace.path,
                    "dest": workspace.deletingLastPathComponent()
                        .appendingPathComponent("moved-workspace").path,
                ]
            ),
        ] {
            let result = try app.tools.call(
                name: tool,
                arguments: arguments,
                clientID: client
            )
            XCTAssertFalse(result.ok, tool)
            XCTAssertEqual(result.payload["code"] as? String, "workspace_root_protected", tool)
            XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.path), tool)
        }
    }

    func testActiveAgentForbiddenToolsAreEnforcedAtRouter() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("explore-policy")
        try startAgentRun(
            app: app,
            clientID: client,
            agentID: "explore",
            goal: "read only",
            projectRoot: tempHome
        )

        let result = try app.tools.call(
            name: "fs_write",
            arguments: ["path": tempHome.appendingPathComponent("blocked.txt").path, "content": "blocked"],
            clientID: client
        )

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.payload["code"] as? String, "tool_forbidden")
    }

    func testShellRequiresExplicitProjectContext() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("no-session-shell")

        let unboundResult = try app.tools.call(
            name: "shell_exec",
            arguments: ["command": "pwd"],
            clientID: client
        )

        XCTAssertFalse(unboundResult.ok)
        XCTAssertEqual(unboundResult.payload["code"] as? String, "project_context_required")
    }

    func testAgentRunStartCannotCreateAuthorizationRoot() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let outside = tempHome.deletingLastPathComponent()

        let result = try app.tools.call(
            name: "agent_run_start",
            arguments: ["agent_id": "implement", "goal": "escape", "cwd": outside.path],
            clientID: ClientID("untrusted-session-root")
        )

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.payload["code"] as? String, "path_outside_allowed_roots")
        XCTAssertNil(app.sessions.binding(for: ClientID("untrusted-session-root")))
    }

    func testProjectMemoryInitializeRejectsFilesystemRootEvenWhenConfigured() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        _ = try app.config.update(["allowed_roots": ["/"]], save: false)

        let result = try app.tools.call(
            name: "project_memory.initialize",
            arguments: ["project_path": "/"],
            clientID: ClientID("bootstrap-filesystem-root")
        )

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.payload["code"] as? String, "project_bootstrap_root_forbidden")

        let child = try app.tools.call(
            name: "project_memory.initialize",
            arguments: ["project_path": tempHome.deletingLastPathComponent().path],
            clientID: ClientID("bootstrap-filesystem-root-child")
        )
        XCTAssertFalse(child.ok)
        XCTAssertEqual(child.payload["code"] as? String, "path_outside_allowed_roots")
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.paths.projectRegistry.path))
    }

    func testProjectMemoryInitializeRejectsImplicitApplicationHomeAndChildren() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let child = tempHome.appendingPathComponent("untrusted-bootstrap", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)

        for (index, candidate) in [tempHome!, child].enumerated() {
            let result = try app.tools.call(
                name: "project_memory.initialize",
                arguments: ["project_path": candidate.path],
                clientID: ClientID("implicit-app-home-\(index)")
            )
            XCTAssertFalse(result.ok)
            XCTAssertEqual(result.payload["code"] as? String, "path_outside_allowed_roots")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.paths.projectRegistry.path))
    }

    func testProjectMemoryInitializeRejectsOutsideConfiguredBootstrapRootAndLegacyAlias() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let trusted = tempHome.deletingLastPathComponent()
            .appendingPathComponent("forge-bootstrap-trusted-\(UUID().uuidString)", isDirectory: true)
        let outside = tempHome.deletingLastPathComponent()
            .appendingPathComponent("forge-bootstrap-outside-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: trusted)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: trusted, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let escape = trusted.appendingPathComponent("escape", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: outside)
        _ = try app.config.update(["allowed_roots": [trusted.path]], save: false)

        for (index, arguments) in [
            ["project_path": outside.path],
            ["path": outside.path],
            ["project_path": escape.path],
        ].enumerated() {
            let result = try app.tools.call(
                name: "project_memory.initialize",
                arguments: arguments,
                clientID: ClientID("bootstrap-outside-\(index)")
            )
            XCTAssertFalse(result.ok)
            XCTAssertEqual(result.payload["code"] as? String, "path_outside_allowed_roots")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.paths.projectRegistry.path))
    }

    func testProjectMemoryInitializeAllowsProjectInsideConfiguredBootstrapRoot() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let trusted = tempHome.deletingLastPathComponent()
            .appendingPathComponent("forge-bootstrap-allowed-\(UUID().uuidString)", isDirectory: true)
        let project = trusted.appendingPathComponent("project", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: trusted) }
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        _ = try app.config.update(["allowed_roots": [trusted.path]], save: false)
        let clientID = ClientID("bootstrap-allowed")

        let result = try app.tools.call(
            name: "project_memory.initialize",
            arguments: ["project_path": project.path],
            clientID: clientID
        )

        XCTAssertTrue(result.ok, "\(result.payload)")
        XCTAssertEqual(result.payload["project_context_attached"] as? Bool, true)
        let returnedContext = try XCTUnwrap(result.payload["project_context"] as? [String: Any])
        XCTAssertEqual(
            returnedContext["authorization_roots_role"] as? String,
            "project_identity_and_default_working_directory_only"
        )
        XCTAssertEqual(
            returnedContext["filesystem_access_scope"] as? String,
            "host_native_inherited_unconfined_by_forge"
        )
        XCTAssertEqual(returnedContext["filesystem_sandbox_mode"] as? String, "none")
        XCTAssertEqual(returnedContext["filesystem_path_confinement"] as? Bool, false)
        let context = try app.projectContexts.invocationContext(for: clientID)
        XCTAssertEqual(
            context.authorizationScope.canonicalRoots,
            [project.resolvingSymlinksInPath().standardizedFileURL]
        )
        XCTAssertEqual(
            context.authorizationScope.writableRoots,
            [project.resolvingSymlinksInPath().standardizedFileURL]
        )
    }

    func testShellExecutesByDefaultInsideAuthorizedProjectWorkspace() throws {
        let projectRoot = tempHome.appendingPathComponent("shell-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("default-shell")
        try startAgentRun(
            app: app,
            clientID: client,
            agentID: "implement",
            goal: "probe",
            projectRoot: projectRoot
        )

        let result = try app.tools.call(
            name: "shell_exec",
            arguments: ["command": "printf shell-ready", "cwd": projectRoot.path],
            clientID: client
        )

        XCTAssertTrue(result.ok, "\(result.payload)")
        XCTAssertEqual(result.payload["exit_code"] as? Int32, 0)
        XCTAssertEqual(result.payload["stdout"] as? String, "shell-ready")
    }

    func testMigratedLegacyConfigExecutesAuthorizedShellByDefault() throws {
        let projectRoot = tempHome.appendingPathComponent("legacy-shell-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let legacy: [String: Any] = [
            "allowed_roots": [projectRoot.path],
            "shell": [
                "enabled": false,
                "default_timeout_sec": 30,
            ] as [String: Any],
        ]
        try JSONSupport.data(from: legacy).write(
            to: tempHome.appendingPathComponent("config.json"),
            options: .atomic
        )
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("migrated-shell")
        try startAgentRun(
            app: app,
            clientID: client,
            agentID: "implement",
            goal: "migration probe",
            projectRoot: projectRoot
        )

        let result = try app.tools.call(
            name: "shell_exec",
            arguments: ["command": "printf migrated-ready", "cwd": projectRoot.path],
            clientID: client
        )

        XCTAssertTrue(result.ok, "\(result.payload)")
        XCTAssertEqual(result.payload["stdout"] as? String, "migrated-ready")
        XCTAssertEqual(app.config.model.shell.policyOrigin, "legacy_disabled_default_migrated")
        XCTAssertTrue(app.config.shellMigrationStatus.receiptValid)
    }

    func testExplicitShellDisableUsesDistinctAuthorizationReason() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        _ = try app.config.update(ManagerSettingsPatch(shellEnabled: false), save: true)
        let client = ClientID("user-disabled-shell")
        try startAgentRun(
            app: app,
            clientID: client,
            agentID: "implement",
            goal: "probe"
        )

        let result = try app.tools.call(
            name: "shell_exec",
            arguments: ["command": "true", "cwd": tempHome.path],
            clientID: client
        )

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.payload["code"] as? String, "shell_disabled_by_user")

        let listed = try XCTUnwrap(MCPServer(
            app: app,
            clientID: ClientID("user-disabled-shell-tools-list")
        ).handle([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/list",
        ]))
        let listResult = try XCTUnwrap(listed["result"] as? [String: Any])
        let descriptors = try XCTUnwrap(listResult["tools"] as? [[String: Any]])
        XCTAssertEqual(descriptors.filter { $0["name"] as? String == "shell_exec" }.count, 1)
    }

    func testShellPolicyAndCompatibilitySurviveManagerAndAppRestart() throws {
        let port = Int.random(in: 29_000...39_000)
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("shell-restart-project-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectRoot) }

        var firstApp: ForgeApp? = try ForgeApp.bootstrap(home: tempHome)
        var firstManager: ManagerNode? = ManagerNode(app: try XCTUnwrap(firstApp))
        _ = try firstApp?.config.update([
            "dashboard": ["port": port] as [String: Any],
            "allowed_roots": [projectRoot.path],
        ], save: true)
        _ = try firstManager?.startService()
        _ = try firstManager?.updateSettings(
            ManagerSettingsPatch(shellEnabled: false),
            apply: true
        )
        _ = try firstManager?.restartService()
        XCTAssertFalse((try XCTUnwrap(firstManager)).settingsModel().shellEnabled)
        XCTAssertTrue((try XCTUnwrap(firstManager)).settingsModel().shellUserDisabled)
        let firstClient = ClientID("shell-restart-disabled")
        try startAgentRun(
            app: try XCTUnwrap(firstApp),
            clientID: firstClient,
            agentID: "implement",
            goal: "verify persisted shell opt-out",
            projectRoot: projectRoot
        )
        let disabled = try (XCTUnwrap(firstApp)).tools.call(
            name: "shell_exec",
            arguments: ["command": "true", "cwd": projectRoot.path],
            clientID: firstClient
        )
        XCTAssertFalse(disabled.ok)
        XCTAssertEqual(disabled.payload["code"] as? String, "shell_disabled_by_user")
        XCTAssertTrue((try XCTUnwrap(firstApp)).tools.toolNames.contains("shell_exec"))
        (try XCTUnwrap(firstApp)).shutdown()
        firstManager = nil
        firstApp = nil

        var secondApp: ForgeApp? = try ForgeApp.bootstrap(home: tempHome)
        var secondManager: ManagerNode? = ManagerNode(app: try XCTUnwrap(secondApp))
        _ = try secondManager?.startService()
        XCTAssertFalse((try XCTUnwrap(secondManager)).settingsModel().shellEnabled)
        XCTAssertTrue((try XCTUnwrap(secondManager)).settingsModel().shellUserDisabled)
        _ = try secondManager?.updateSettings(
            ManagerSettingsPatch(shellEnabled: true),
            apply: true
        )
        _ = try secondManager?.restartService()
        XCTAssertTrue((try XCTUnwrap(secondManager)).settingsModel().shellEnabled)
        XCTAssertFalse((try XCTUnwrap(secondManager)).settingsModel().shellUserDisabled)
        (try XCTUnwrap(secondApp)).shutdown()
        secondManager = nil
        secondApp = nil

        let thirdApp = try ForgeApp.bootstrap(home: tempHome)
        defer { thirdApp.shutdown() }
        XCTAssertTrue(thirdApp.config.model.shell.enabled)
        XCTAssertFalse(thirdApp.config.model.shell.userDisabled)
        let thirdClient = ClientID("shell-restart-enabled")
        try startAgentRun(
            app: thirdApp,
            clientID: thirdClient,
            agentID: "implement",
            goal: "verify shell access after restart",
            projectRoot: projectRoot
        )
        let executed = try thirdApp.tools.call(
            name: "shell_exec",
            arguments: [
                "command": "shopt -q login_shell || exit 97; printf restart-ready",
                "cwd": projectRoot.path,
                "timeout_sec": 999,
            ],
            clientID: thirdClient
        )
        XCTAssertTrue(executed.ok, "\(executed.payload)")
        XCTAssertEqual((executed.payload["exit_code"] as? NSNumber)?.int32Value, 0)
        XCTAssertEqual(executed.payload["stdout"] as? String, "restart-ready")
        XCTAssertEqual(executed.payload["timed_out"] as? Bool, false)
        for key in [
            "ok", "exit_code", "stdout", "stderr", "timed_out",
            "stdout_truncated", "stderr_truncated", "command", "cwd",
        ] {
            XCTAssertNotNil(executed.payload[key], "missing shell_exec response key \(key)")
        }

        let listed = try XCTUnwrap(MCPServer(
            app: thirdApp,
            clientID: ClientID("shell-restart-tools-list")
        ).handle([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/list",
        ]))
        let listResult = try XCTUnwrap(listed["result"] as? [String: Any])
        let descriptors = try XCTUnwrap(listResult["tools"] as? [[String: Any]])
        XCTAssertEqual(descriptors.filter { $0["name"] as? String == "shell_exec" }.count, 1)
    }

    func testShellExecPreservesLoginBashAndResponseContract() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let result = try XCTUnwrap(ShellToolPack().handle(
            name: "shell_exec",
            arguments: [
                "command": "shopt -q login_shell || exit 97; printf '%s' \"$0\"",
                "cwd": tempHome.path,
                "timeout_sec": ShellToolPack.maximumTimeoutSec + 300,
            ],
            clientID: ClientID("shell-contract"),
            app: app
        ))

        XCTAssertTrue(result.ok, "\(result.payload)")
        XCTAssertTrue((result.payload["stdout"] as? String)?.contains("/bin/bash") == true)
        for key in [
            "ok", "exit_code", "stdout", "stderr", "timed_out",
            "stdout_truncated", "stderr_truncated", "command", "cwd",
        ] {
            XCTAssertNotNil(result.payload[key], "missing shell_exec response key \(key)")
        }
        XCTAssertEqual(ShellToolPack.maximumTimeoutSec, 120)
    }

    func testShellRejectsNonFiniteTimeoutWhenEnabled() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        _ = try app.config.update(["shell": ["enabled": true]], save: false)
        let client = ClientID("bounded-shell-timeout")
        _ = try app.sessions.start(agentID: "implement", goal: "probe", clientID: client, cwd: tempHome.path)

        let result = try XCTUnwrap(ShellToolPack().handle(
            name: "shell_exec",
            arguments: ["command": "true", "cwd": tempHome.path, "timeout_sec": Double.infinity],
            clientID: client,
            app: app
        ))

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.payload["code"] as? String, "invalid_timeout")
    }

    func testToolAuditRedactsFileContents() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let secret = "sensitive-content-\(UUID().uuidString)"
        _ = try app.tools.call(
            name: "fs_write",
            arguments: ["path": tempHome.appendingPathComponent("redacted.txt").path, "content": secret],
            clientID: ClientID("audit-redaction")
        )

        let event = try XCTUnwrap(app.audit.recent(limit: 5).first(where: { $0.tool == "fs_write" }))
        XCTAssertFalse(event.argsJSON?.contains(secret) == true)
        XCTAssertTrue(event.argsJSON?.contains("redacted") == true)
    }

    func testToolAuditRecursivelyRedactsBatchContents() throws {
        let sensitiveValue = "nested-sensitive-content-\(UUID().uuidString)"
        let sanitized = ToolAuditSanitizer.sanitize([
            "items": [[
                "title": "safe title",
                "body": sensitiveValue,
                "summary": sensitiveValue,
            ]],
        ])
        let encoded = try JSONSupport.string(from: sanitized)

        XCTAssertFalse(encoded.contains(sensitiveValue), encoded)
        XCTAssertTrue(encoded.contains("safe title"), encoded)
        XCTAssertTrue(encoded.contains("redacted"), encoded)
    }

    func testAgentListTool() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        let r = try app.tools.call(name: "agent_list", arguments: [:], clientID: ClientID("t4"))
        XCTAssertTrue(r.ok)
        let agents = r.payload["agents"] as? [[String: Any]] ?? []
        XCTAssertGreaterThanOrEqual(agents.count, 8)
    }

    // MARK: - MCP

    func testMCPInitializeAndToolsList() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        let mcp = MCPServer(app: app, clientID: ClientID("mcp-test"))
        let initResp = mcp.handle([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": ["protocolVersion": "2024-11-05"] as [String: Any],
        ])
        XCTAssertNotNil(initResp)
        XCTAssertNotNil(initResp?["result"])

        let list = mcp.handle([
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list",
        ])
        let result = list?["result"] as? [String: Any]
        let tools = result?["tools"] as? [[String: Any]] ?? []
        XCTAssertGreaterThanOrEqual(tools.count, 10)
        let names = tools.compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains("forge_status"))
        XCTAssertTrue(names.contains("get_forge_status"))
        XCTAssertTrue(names.contains("agent_run_start"))
        XCTAssertTrue(names.contains("pdf_write"))
    }

    func testMCPToolCall() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        let mcp = MCPServer(app: app, clientID: ClientID("mcp-call"))
        let resp = mcp.handle([
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": [
                "name": "forge_status",
                "arguments": [:] as [String: Any],
            ] as [String: Any],
        ])
        let result = resp?["result"] as? [String: Any]
        XCTAssertEqual(result?["isError"] as? Bool, false)
        let content = result?["content"] as? [[String: Any]]
        XCTAssertNotNil(content?.first?["text"] as? String)
    }

    func testGetForgeStatusAcceptsResumeBootstrapArgument() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let result = try app.tools.call(
            name: "get_forge_status",
            arguments: ["resume": true],
            clientID: ClientID("status-resume")
        )
        XCTAssertTrue(result.ok)
        XCTAssertNotNil(result.payload["continuity"])
        let resume = result.payload["resume"] as? [String: Any]
        XCTAssertEqual(resume?["found"] as? Bool, false)
    }

    func testGetForgeStatusWritesExactNonceBoundInteractiveResumeAcknowledgement() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let handoffID = UUID().uuidString.lowercased()
        let nonce = UUID().uuidString.lowercased()
        try app.store.handoffUpsert(HandoffPacket(
            id: handoffID,
            resumeReady: true,
            goal: "Resume in the visible LM Studio successor",
            status: "ready"
        ))

        let result = try app.tools.call(
            name: "get_forge_status",
            arguments: [
                "resume": true,
                "handoff_id": handoffID,
                "rollover_nonce": nonce,
            ],
            clientID: ClientID("lmstudio-gui-successor")
        )

        XCTAssertTrue(result.ok, "\(result.payload)")
        let acknowledgement = try XCTUnwrap(
            result.payload["interactive_resume_acknowledgement"] as? [String: Any]
        )
        XCTAssertEqual(acknowledgement["handoff_id"] as? String, handoffID)
        XCTAssertEqual(acknowledgement["rollover_nonce"] as? String, nonce)
        XCTAssertEqual(acknowledgement["tool"] as? String, "get_forge_status")
        XCTAssertEqual(acknowledgement["resume"] as? Bool, true)
        XCTAssertEqual(acknowledgement["client_id"] as? String, "lmstudio-gui-successor")
        let receiptURL = app.paths.interactiveResumeAcknowledgementsDir
            .appendingPathComponent("\(handoffID).json")
        let persisted = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: OwnerOnlyAtomicFile.read(from: receiptURL, maximumBytes: 8_192)
            ) as? [String: Any]
        )
        XCTAssertEqual(persisted["rollover_nonce"] as? String, nonce)
    }

    func testGetForgeStatusReturnsRegisteredProjectAndQueryLocationsWithoutRun() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let root = tempHome.appendingPathComponent("ordinary-lmstudio-project", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let projectID = UUID()
        _ = try app.projectContexts.registerProjectUnchecked(
            descriptor: ProjectMemoryDescriptor(
                id: projectID.uuidString.lowercased(),
                displayName: "Ordinary LM Studio Project",
                repositoryIdentity: nil,
                aliases: []
            ),
            canonicalRoot: root
        )

        let result = try app.tools.call(
            name: "get_forge_status",
            arguments: ["project_id": projectID.uuidString.lowercased()],
            clientID: ClientID("ordinary-lmstudio-status")
        )

        XCTAssertTrue(result.ok)
        let projects = try XCTUnwrap(result.payload["projects"] as? [[String: Any]])
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects[0]["project_id"] as? String, projectID.uuidString.lowercased())
        let project = try XCTUnwrap(result.payload["project"] as? [String: Any])
        XCTAssertEqual(project["canonical_root"] as? String, root.path)
        let locations = try XCTUnwrap(result.payload["locations"] as? [String: String])
        XCTAssertEqual(locations["project_files"], root.path)
        XCTAssertEqual(locations["instruction_store"], app.paths.instructionPackageStoreDir.path)
        XCTAssertTrue(locations["continuity_store"]?.contains(projectID.uuidString.lowercased()) == true)
        let tools = try XCTUnwrap(result.payload["query_tools"] as? [String: [String]])
        XCTAssertEqual(tools["instructions"], ["instruction_catalog", "instruction_read"])
        XCTAssertTrue(tools["project_files"]?.contains("fs_read") == true)
        XCTAssertTrue(tools["continuity"]?.contains("context_get") == true)
    }

    // MARK: - JSON / domain

    func testISO8601RoundTrip() {
        let d = Date(timeIntervalSince1970: 1_700_000_000)
        let s = ISO8601.string(from: d)
        let back = ISO8601.date(from: s)
        XCTAssertNotNil(back)
        XCTAssertEqual(Int(back!.timeIntervalSince1970), 1_700_000_000)
    }

    func testAgentMarkdownParser() throws {
        let md = """
        ---
        id: custom-agent
        display_name: Custom
        description: A custom playbook
        tools: [fs_read, fs_list]
        tools_forbidden: [git_push]
        output_schema:
          - summary
          - next
        ---
        You are custom.
        """
        let spec = try AgentMarkdownParser.parse(text: md, source: "custom")
        XCTAssertEqual(spec.id, "custom-agent")
        XCTAssertEqual(spec.tools, ["fs_read", "fs_list"])
        XCTAssertEqual(spec.toolsForbidden, ["git_push"])
        XCTAssertEqual(spec.outputSchema, ["summary", "next"])
        XCTAssertTrue(spec.body.contains("custom"))
    }

    func testCustomAgentOverridesBuiltin() throws {
        let md = """
        ---
        id: explore
        display_name: Explore Custom
        description: overridden
        tools: [fs_list]
        ---
        Custom explore body.
        """
        let agentsDir = tempHome.appendingPathComponent("agents", isDirectory: true)
        try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        try md.write(to: agentsDir.appendingPathComponent("explore.md"), atomically: true, encoding: .utf8)
        let app = try ForgeApp.bootstrap(home: tempHome)
        let spec = app.catalog.get("explore")
        XCTAssertEqual(spec?.source, "custom")
        XCTAssertEqual(spec?.displayName, "Explore Custom")
    }

    // MARK: - Audit

    func testAuditDualWrite() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        try app.audit.append(
            tool: "test_tool",
            status: "ok",
            clientID: "c",
            args: ["x": 1],
            durationMs: 5,
            mutating: true
        )
        let rows = try app.audit.recent(limit: 5)
        XCTAssertTrue(rows.contains(where: { $0.tool == "test_tool" }))
        let jsonl = try String(contentsOf: app.paths.auditJSONL, encoding: .utf8)
        XCTAssertTrue(jsonl.contains("test_tool"))
    }
}
