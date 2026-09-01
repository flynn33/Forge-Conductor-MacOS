// ProjectContextIntegrationTests.swift
// Verifies production tool routing through exact durable project bindings.

import Darwin
import ForgeFilesystemProtocol
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

    func testFCProjectBootstrapAuthorityContextCannotBroadenSettingsRoots() throws {
        try withApplication { app, configuredRoot in
            let approvedProject = try makeProject(
                root: configuredRoot,
                name: "approved-context-project"
            )
            let outsideProject = configuredRoot.deletingLastPathComponent()
                .appendingPathComponent(
                    "outside-context-\(UUID().uuidString.lowercased())",
                    isDirectory: true
                )
            try FileManager.default.createDirectory(
                at: outsideProject,
                withIntermediateDirectories: true
            )
            defer { try? FileManager.default.removeItem(at: outsideProject) }
            let escapeAlias = configuredRoot.appendingPathComponent(
                "outside-context-alias",
                isDirectory: true
            )
            try FileManager.default.createSymbolicLink(
                at: escapeAlias,
                withDestinationURL: outsideProject
            )

            let authorization = ToolAuthorizationService(
                paths: app.paths,
                config: app.config
            )
            let clientID = ClientID("project-root-authority-context")
            func context(root: URL) -> ToolInvocationContext {
                ToolInvocationContext(
                    projectID: ProjectID(),
                    projectGeneration: .initial,
                    clientID: clientID,
                    authorizationScope: ToolAuthorizationScope(
                        canonicalRoots: [root],
                        allowedTools: ["fs_read", "shell_exec"],
                        networkAllowed: false,
                        maximumInlineOutputBytes: 1_024
                    )
                )
            }

            for unauthorizedRoot in [outsideProject, escapeAlias] {
                for (tool, arguments) in [
                    ("fs_read", ["path": unauthorizedRoot.appendingPathComponent("leaf").path]),
                    ("shell_exec", ["command": "pwd", "cwd": unauthorizedRoot.path]),
                ] {
                    let decision = authorization.authorize(
                        tool: tool,
                        arguments: arguments,
                        context: context(root: unauthorizedRoot),
                        clientID: clientID,
                        binding: nil
                    )
                    guard case let .denied(code, _) = decision else {
                        return XCTFail(
                            "A durable context outside Settings authority must be denied"
                        )
                    }
                    XCTAssertEqual(code, "path_outside_allowed_roots")
                }
            }

            let approved = authorization.authorize(
                tool: "shell_exec",
                arguments: ["command": "pwd", "cwd": approvedProject.path],
                context: context(root: approvedProject),
                clientID: clientID,
                binding: nil
            )
            guard case let .allowed(arguments) = approved else {
                return XCTFail("A project contained by a Settings root must remain authorized")
            }
            XCTAssertEqual(
                arguments["cwd"] as? String,
                approvedProject.resolvingSymlinksInPath().standardizedFileURL.path
            )
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

    func testReadOnlyProjectScopeRejectsEveryFilesystemMutation() throws {
        try withApplication { app, root in
            let project = try makeProject(root: root, name: "read-only-project")
            let existing = project.appendingPathComponent("existing.txt")
            try Data("preserve".utf8).write(to: existing)
            let client = ClientID("read-only-filesystem-client")
            let registered = try ManagerNode(app: app).registerProject(
                path: project.path,
                displayName: "Read Only Project"
            )
            let projectID = ProjectID(try XCTUnwrap(
                UUID(uuidString: try XCTUnwrap(registered["project_id"] as? String))
            ))
            let generation = ProjectGeneration(try XCTUnwrap(
                registered["project_generation"] as? UInt64
            ))
            let readOnlyScope = ToolAuthorizationScope(
                canonicalRoots: [project],
                writableRoots: [],
                allowedTools: ["*"],
                networkAllowed: false,
                maximumInlineOutputBytes: ProjectContextService.defaultInlineOutputLimit
            )
            _ = try app.projectContexts.bind(
                owner: ProjectBindingOwner(kind: .mcpClient, id: client.rawValue),
                projectID: projectID,
                generation: generation,
                authorizationScope: readOnlyScope
            )

            let read = try app.tools.call(
                name: "fs_read",
                arguments: ["path": existing.path],
                clientID: client
            )
            XCTAssertTrue(read.ok, "\(read.payload)")

            let mutations: [(String, [String: Any])] = [
                ("fs_write", ["path": project.appendingPathComponent("new.txt").path, "content": "blocked"]),
                ("fs_edit", ["path": existing.path, "old": "preserve", "new": "changed"]),
                ("fs_mkdir", ["path": project.appendingPathComponent("directory").path]),
                ("fs_delete", ["path": existing.path]),
                ("fs_move", ["path": existing.path, "dest": project.appendingPathComponent("moved.txt").path]),
            ]
            for (tool, arguments) in mutations {
                let result = try app.tools.call(
                    name: tool,
                    arguments: arguments,
                    clientID: client
                )
                XCTAssertFalse(result.ok, "\(tool) unexpectedly succeeded")
                XCTAssertEqual(result.payload["code"] as? String, "path_outside_writable_roots")
            }
            XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "preserve")
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: project.appendingPathComponent("new.txt").path)
            )
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

    func testGenerationResetRejectsRetainedFilesystemRecoveryAuthority() throws {
        try withApplication { app, root in
            let project = try makeProject(root: root, name: "recovery-reset-project")
            let manager = ManagerNode(app: app)
            let registered = try manager.registerProject(
                path: project.path,
                displayName: "Recovery Reset Project"
            )
            let projectID = ProjectID(try XCTUnwrap(
                UUID(uuidString: try XCTUnwrap(registered["project_id"] as? String))
            ))

            let ledger = SecureFilesystemRecoveryLedger(paths: app.paths)
            let record = Self.makeRecoveryRecord(projectID: projectID, rootPath: project.path)
            try ledger.retain(record)

            XCTAssertThrowsError(
                try manager.resetProjectGeneration(
                    projectID: projectID,
                    expectedGeneration: .initial
                )
            ) { error in
                XCTAssertEqual(
                    error as? ProjectContextError,
                    .retainedFilesystemRecovery(projectID)
                )
            }

            let status = try manager.projectStatus(projectID: projectID)
            XCTAssertEqual(status["project_generation"] as? UInt64, 1)
            XCTAssertEqual(status["lifecycle_state"] as? String, "active")
            XCTAssertTrue(try ledger.hasRetainedAuthority(
                projectID: projectID,
                generation: .initial
            ))
        }
    }

    func testGenerationResetCancelsWhenFilesystemRecoveryAppearsAfterBegin() throws {
        try withApplication { app, root in
            let project = try makeProject(root: root, name: "recovery-reset-race-project")
            let registered = try ManagerNode(app: app).registerProject(
                path: project.path,
                displayName: "Recovery Reset Race Project"
            )
            let projectID = ProjectID(try XCTUnwrap(
                UUID(uuidString: try XCTUnwrap(registered["project_id"] as? String))
            ))
            let record = Self.makeRecoveryRecord(projectID: projectID, rootPath: project.path)
            let manager = ManagerNode(app: app) { _, _ in
                try Self.writeRecoveryRecordDirectly(record, app: app)
            }

            XCTAssertThrowsError(
                try manager.resetProjectGeneration(
                    projectID: projectID,
                    expectedGeneration: .initial
                )
            ) { error in
                XCTAssertEqual(
                    error as? ProjectContextError,
                    .retainedFilesystemRecovery(projectID)
                )
            }

            let status = try manager.projectStatus(projectID: projectID)
            XCTAssertEqual(status["project_generation"] as? UInt64, 1)
            XCTAssertEqual(status["lifecycle_state"] as? String, "active")
            XCTAssertTrue(try SecureFilesystemRecoveryLedger(paths: app.paths)
                .hasRetainedAuthority(projectID: projectID, generation: .initial))
        }
    }

    func testGenerationResetSurfacesCancellationFailure() throws {
        try withApplication { app, root in
            let project = try makeProject(root: root, name: "recovery-reset-cleanup-project")
            let registered = try ManagerNode(app: app).registerProject(
                path: project.path,
                displayName: "Recovery Reset Cleanup Project"
            )
            let projectID = ProjectID(try XCTUnwrap(
                UUID(uuidString: try XCTUnwrap(registered["project_id"] as? String))
            ))
            let record = Self.makeRecoveryRecord(projectID: projectID, rootPath: project.path)
            let manager = ManagerNode(app: app) { _, _ in
                try Self.writeRecoveryRecordDirectly(record, app: app)
                app.projectContexts.close()
            }

            XCTAssertThrowsError(
                try manager.resetProjectGeneration(
                    projectID: projectID,
                    expectedGeneration: .initial
                )
            ) { error in
                XCTAssertEqual(
                    error as? ProjectContextError,
                    .resetCancellationFailed(projectID)
                )
            }
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
        _ = try app.config.update(["allowed_roots": [root.path]], save: false)
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

    private static func makeRecoveryRecord(
        projectID: ProjectID,
        rootPath: String
    ) -> SecureFilesystemRecoveryRecord {
        let request = ForgeFilesystemMutationRequest(
            requestID: UUID().uuidString.lowercased(),
            transactionID: UUID().uuidString.lowercased(),
            projectID: projectID.description,
            projectGeneration: ProjectGeneration.initial.rawValue,
            rootID: "1:2",
            rootIdentity: ForgeFilesystemIdentity(
                device: 1,
                inode: 2,
                mode: UInt32(S_IFDIR | 0o700),
                owner: UInt32(geteuid()),
                group: UInt32(getegid()),
                linkCount: 1
            ),
            relativePathComponents: ["leaf.txt"],
            access: .deleteLeaf,
            contract: .namespaceVersionExact,
            expectedLeafIdentity: ForgeFilesystemIdentity(
                device: 1,
                inode: 3,
                mode: UInt32(S_IFREG | 0o600),
                owner: UInt32(geteuid()),
                group: UInt32(getegid()),
                linkCount: 1
            )
        )
        return SecureFilesystemRecoveryRecord(
            request: request,
            originatingClientID: ClientID("reset-recovery-client"),
            rootPath: rootPath
        )
    }

    private static func writeRecoveryRecordDirectly(
        _ record: SecureFilesystemRecoveryRecord,
        app: ForgeApp
    ) throws {
        let slot = app.paths.home
            .appendingPathComponent("privileged-filesystem-recovery", isDirectory: true)
            .appendingPathComponent("slot-00.json")
        try OwnerOnlyAtomicFile.write(try JSONEncoder().encode(record), to: slot)
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
