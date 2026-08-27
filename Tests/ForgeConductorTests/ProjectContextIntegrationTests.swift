// ProjectContextIntegrationTests.swift
// Verifies production tool routing through exact durable project bindings.

import XCTest
@testable import ForgeConductorCore

final class ProjectContextIntegrationTests: XCTestCase {
    func testProjectMemoryInitializationBindsClientAndRejectsUnboundOrCrossProjectCalls() throws {
        try withApplication { app, root in
            let clientA = ClientID("context-client-a")
            let clientB = ClientID("context-client-b")
            let unbound = try app.tools.call(
                name: "project_memory.status",
                arguments: ["project_id": UUID().uuidString.lowercased()],
                clientID: clientA
            )
            XCTAssertFalse(unbound.ok)
            XCTAssertEqual(unbound.payload["code"] as? String, "project_context_required")

            let projectA = try makeProject(root: root, name: "project-a")
            let projectB = try makeProject(root: root, name: "project-b")
            let initializedA = try initialize(app: app, project: projectA, clientID: clientA)
            let initializedB = try initialize(app: app, project: projectB, clientID: clientB)
            let projectIDA = try XCTUnwrap(initializedA.payload["project_id"] as? String)
            let projectIDB = try XCTUnwrap(initializedB.payload["project_id"] as? String)
            XCTAssertNotEqual(projectIDA, projectIDB)
            XCTAssertEqual(initializedA.payload["project_generation"] as? UInt64, 1)

            let remembered = try app.tools.call(
                name: "project_memory.remember",
                arguments: [
                    "project_id": projectIDA,
                    "kind": "fact",
                    "title": "Project A",
                    "summary": "Bound only to project A",
                ],
                clientID: clientA
            )
            XCTAssertTrue(remembered.ok, "\(remembered.payload)")

            let contextB = try app.projectContexts.invocationContext(for: clientB)
            let crossed = try app.tools.call(
                name: "project_memory.search",
                arguments: ["project_id": projectIDA, "query": "Project A"],
                context: contextB
            )
            XCTAssertFalse(crossed.ok)
            XCTAssertEqual(crossed.payload["code"] as? String, "project_scope_mismatch")

            let crossedWrite = try app.tools.call(
                name: "project_memory.remember",
                arguments: [
                    "project_id": projectIDA,
                    "kind": "fact",
                    "title": "Crossed write",
                    "summary": "Must remain outside project A",
                ],
                context: contextB
            )
            XCTAssertFalse(crossedWrite.ok)
            XCTAssertEqual(crossedWrite.payload["code"] as? String, "project_scope_mismatch")

            let contextA = try app.projectContexts.invocationContext(for: clientA)
            let crossedRead = try app.tools.call(
                name: "fs_read",
                arguments: ["path": projectB.appendingPathComponent("private.txt").path],
                context: contextA
            )
            XCTAssertFalse(crossedRead.ok)
            XCTAssertEqual(crossedRead.payload["code"] as? String, "path_outside_allowed_roots")

            let crossedShell = try app.tools.call(
                name: "shell_exec",
                arguments: ["command": "pwd", "cwd": projectB.path],
                context: contextA
            )
            XCTAssertFalse(crossedShell.ok)
            XCTAssertEqual(crossedShell.payload["code"] as? String, "path_outside_allowed_roots")

            let isolated = try app.tools.call(
                name: "project_memory.search",
                arguments: ["project_id": projectIDB, "query": "Project A"],
                clientID: clientB
            )
            XCTAssertTrue(isolated.ok)
            XCTAssertEqual(isolated.payload["count"] as? Int, 0)
        }
    }

    func testGenerationResetRejectsExplicitStaleContextAndInvalidatesCompatibilityBinding() throws {
        try withApplication { app, root in
            let client = ClientID("generation-client")
            let project = try makeProject(root: root, name: "reset-project")
            let initialized = try initialize(app: app, project: project, clientID: client)
            let projectIDString = try XCTUnwrap(initialized.payload["project_id"] as? String)
            let projectUUID = try XCTUnwrap(UUID(uuidString: projectIDString))
            let stale = try app.projectContexts.invocationContext(for: client)

            _ = try app.projectContexts.beginReset(
                projectID: ProjectID(projectUUID),
                expectedGeneration: .initial
            )
            let receipt = try app.projectContexts.completeReset(
                projectID: ProjectID(projectUUID),
                expectedGeneration: .initial
            )
            XCTAssertEqual(receipt.newGeneration, ProjectGeneration(2))

            let explicit = try app.tools.call(
                name: "project_memory.remember",
                arguments: [
                    "project_id": projectIDString,
                    "kind": "fact",
                    "title": "Stale",
                    "summary": "Must not be committed",
                ],
                context: stale
            )
            XCTAssertFalse(explicit.ok)
            XCTAssertEqual(explicit.payload["code"] as? String, "stale_project_generation")

            let compatibility = try app.tools.call(
                name: "project_memory.status",
                arguments: ["project_id": projectIDString],
                clientID: client
            )
            XCTAssertFalse(compatibility.ok)
            XCTAssertEqual(compatibility.payload["code"] as? String, "project_context_required")

            let rebound = try initialize(app: app, project: project, clientID: client)
            XCTAssertEqual(rebound.payload["project_generation"] as? UInt64, 2)
        }
    }

    func testAgentWorkspaceBootstrapCreatesContextAndDefaultShellUsesItsRoot() throws {
        try withApplication { app, root in
            let project = try makeProject(root: root, name: "shell-project")
            _ = try app.config.update(["allowed_roots": [project.path]])
            let client = ClientID("shell-context-client")
            let started = try app.tools.call(
                name: "agent_run_start",
                arguments: [
                    "agent_id": "implement",
                    "goal": "Verify project context shell",
                    "cwd": project.path,
                ],
                clientID: client
            )
            XCTAssertTrue(started.ok, "\(started.payload)")
            XCTAssertEqual(started.payload["project_generation"] as? UInt64, 1)
            let context = try app.projectContexts.invocationContext(for: client)
            let boundRoot = try XCTUnwrap(context.authorizationScope.canonicalRoots.first)

            let shell = try app.tools.call(
                name: "shell_exec",
                arguments: ["command": "pwd"],
                clientID: client
            )
            XCTAssertTrue(shell.ok, "\(shell.payload)")
            let shellPath = try XCTUnwrap(
                (shell.payload["stdout"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            let boundIdentifier = try XCTUnwrap(
                boundRoot.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
                    as? AnyHashable
            )
            let shellIdentifier = try XCTUnwrap(
                URL(fileURLWithPath: shellPath)
                    .resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
                    as? AnyHashable
            )
            XCTAssertEqual(shellIdentifier, boundIdentifier)
        }
    }

    func testManagerCommandsRegisterBindAndFenceProjectGeneration() throws {
        try withApplication { app, root in
            let project = try makeProject(root: root, name: "manager-project")
            let manager = ManagerNode(app: app)
            let registered = try manager.registerProject(
                path: project.path,
                displayName: "Manager Project"
            )
            let projectIDString = try XCTUnwrap(registered["project_id"] as? String)
            let projectUUID = try XCTUnwrap(UUID(uuidString: projectIDString))
            XCTAssertEqual(registered["project_generation"] as? UInt64, 1)

            let client = ClientID("manager-bound-client")
            let binding = try manager.bindProject(
                projectID: ProjectID(projectUUID),
                expectedGeneration: .initial,
                owner: ProjectBindingOwner(kind: .mcpClient, id: client.rawValue)
            )
            XCTAssertEqual(binding["owner_id"] as? String, client.rawValue)

            let beforeReset = try app.tools.call(
                name: "project_memory.status",
                arguments: ["project_id": projectIDString],
                clientID: client
            )
            XCTAssertTrue(beforeReset.ok, "\(beforeReset.payload)")

            let receipt = try manager.resetProjectGeneration(
                projectID: ProjectID(projectUUID),
                expectedGeneration: .initial
            )
            XCTAssertEqual(receipt["new_generation"] as? UInt64, 2)
            XCTAssertEqual(receipt["invalidated_binding_count"] as? Int, 1)

            let fenced = try app.tools.call(
                name: "project_memory.status",
                arguments: ["project_id": projectIDString],
                clientID: client
            )
            XCTAssertFalse(fenced.ok)
            XCTAssertEqual(fenced.payload["code"] as? String, "project_context_required")
            let status = try manager.projectStatus(projectID: ProjectID(projectUUID))
            XCTAssertEqual(status["project_generation"] as? UInt64, 2)
        }
    }

    private func withApplication(
        _ body: (ForgeApp, URL) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-context-integration-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let app = try ForgeApp.bootstrap(home: home)
        do {
            try body(app, root)
        } catch {
            app.shutdown()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        app.shutdown()
        try? FileManager.default.removeItem(at: root)
    }

    private func makeProject(root: URL, name: String) throws -> URL {
        let project = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        return project
    }

    private func initialize(
        app: ForgeApp,
        project: URL,
        clientID: ClientID
    ) throws -> ToolResult {
        let result = try app.tools.call(
            name: "project_memory.initialize",
            arguments: ["project_path": project.path],
            clientID: clientID
        )
        XCTAssertTrue(result.ok, "\(result.payload)")
        return result
    }
}
