import XCTest
import SQLite3
@testable import ForgeConductorCore

final class ContinuityNativeTaskSessionTests: XCTestCase {
    func testPreCancelledNativeCheckpointDoesNotCommitSource() async throws {
        try await withFixture { fixture in
            let before = try self.sourceRowCounts(fixture.app)
            let session = fixture.session
            let result = try await Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await session.call(name: "session_checkpoint", arguments: [
                    "goal": "Cancelled native checkpoint",
                ])
            }.value
            XCTAssertFalse(result.ok)
            XCTAssertEqual(result.payload["code"] as? String, "cancelled", "\(result.payload)")
            XCTAssertNil(result.payload["continuity_id"])
            XCTAssertEqual(try self.sourceRowCounts(fixture.app), before)

            let subsequent = try await session.call(name: "session_checkpoint", arguments: [
                "goal": "Subsequent authorized checkpoint",
            ])
            XCTAssertTrue(subsequent.ok, "\(subsequent.payload)")
            XCTAssertNotNil(subsequent.payload["continuity_id"] as? String)
            XCTAssertEqual(try self.sourceRowCounts(fixture.app), [before[0] + 1, before[1]])
        }
    }

    func testPreCancelledNativeStartDoesNotSubmitReadySource() async throws {
        try await withFixture { fixture in
            let ready = try await fixture.session.call(name: "session_handoff", arguments: [
                "goal": "Ready native source",
            ])
            XCTAssertTrue(ready.ok, "\(ready.payload)")
            let id = try XCTUnwrap(ready.payload["continuity_id"] as? String)
            let before = try self.sourceRowCounts(fixture.app)
            XCTAssertEqual(before[1], 0)
            let session = fixture.session
            let result = try await Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await session.call(name: "clu_start_handoff", arguments: [
                    "continuity_id": id, "idempotency_key": "cancelled-native-start",
                ])
            }.value
            XCTAssertFalse(result.ok)
            XCTAssertEqual(result.payload["code"] as? String, "cancelled", "\(result.payload)")
            XCTAssertNil(result.payload["operation_id"])
            XCTAssertEqual(try self.sourceRowCounts(fixture.app), before)
            XCTAssertTrue(try fixture.app.store.pendingContinuityHandoffs().isEmpty)

            let subsequent = try await session.call(name: "clu_start_handoff", arguments: [
                "continuity_id": id, "idempotency_key": "cancelled-native-start",
            ])
            XCTAssertTrue(subsequent.ok, "\(subsequent.payload)")
            XCTAssertNotNil(subsequent.payload["operation_id"] as? String)
            XCTAssertEqual(try self.sourceRowCounts(fixture.app), [before[0], before[1] + 1])
        }
    }

    func testNativeCarrierCommitsExactSourceAndExplicitStartWithoutChangingPolicy() async throws {
        try await withFixture { fixture in
            let checkpoint = try await fixture.session.call(name: "session_checkpoint", arguments: [
                "goal": "Approved task progress", "narrative": "Soft checkpoint",
            ])
            XCTAssertTrue(checkpoint.ok, "\(checkpoint.payload)")
            let id = try XCTUnwrap(checkpoint.payload["continuity_id"] as? String)
            XCTAssertTrue(try fixture.app.store.pendingContinuityHandoffs().isEmpty)
            let premature = try await fixture.session.call(name: "clu_start_handoff", arguments: ["continuity_id": id])
            XCTAssertEqual(premature.payload["code"] as? String, "source_not_ready")
            let finalized = try await fixture.session.call(name: "session_handoff", arguments: [
                "handoff_id": id, "narrative": "Exact native progress ready",
            ])
            XCTAssertTrue(finalized.ok, "\(finalized.payload)")
            XCTAssertEqual(finalized.payload["projection_excluded"] as? Bool, true)
            XCTAssertEqual((finalized.payload["paths"] as? [String: Any])?.count, 0)
            XCTAssertEqual(finalized.payload["projection_ok"] as? Bool, false)
            XCTAssertTrue(try fixture.app.store.pendingContinuityHandoffs().isEmpty)
            let started = try await fixture.session.call(name: "clu_start_handoff", arguments: [
                "continuity_id": id, "idempotency_key": "native-start",
            ])
            XCTAssertTrue(started.ok, "\(started.payload)")
            let repeated = try await fixture.session.call(name: "clu_start_handoff", arguments: [
                "continuity_id": id, "idempotency_key": "native-start",
            ])
            XCTAssertEqual(try JSONSupport.data(from: started.payload), try JSONSupport.data(from: repeated.payload))
            XCTAssertEqual((started.payload["source"] as? [String: Any])?["continuity_id"] as? String, id)
            XCTAssertFalse(try fixture.app.config.budgetPolicySelection(scope: .globalDefault).policy.automaticHandoffEnabled)
        }
    }

    func testExactStatusAndCancellationCannotControlSameClientPeer() async throws {
        try await withFixture { fixture in
            let final = try await fixture.session.call(name: "session_handoff", arguments: ["goal": "Own source"])
            let id = try XCTUnwrap(final.payload["continuity_id"] as? String)
            let start = try await fixture.session.call(name: "clu_start_handoff", arguments: ["continuity_id": id])
            let operation = try XCTUnwrap(start.payload["operation_id"] as? String)
            let peer = try await ContinuityNativeTaskSession.enroll(app: fixture.app,
                approvedAssignment: fixture.assignment, callerContext: fixture.context, callerOwner: fixture.owner)
            for name in ["clu_status", "clu_cancel"] {
                let denied = try await peer.call(name: name, arguments: ["operation_id": operation])
                XCTAssertEqual(denied.payload["code"] as? String, "not_found", "\(denied.payload)")
            }
            let status = try await fixture.session.call(name: "clu_status", arguments: ["operation_id": operation])
            XCTAssertTrue(status.ok, "\(status.payload)")
            XCTAssertEqual((status.payload["operation"] as? [String: Any])?["operation_id"] as? String, operation)
            let cancelled = try await fixture.session.call(name: "clu_cancel", arguments: ["operation_id": operation])
            XCTAssertTrue(cancelled.ok, "\(cancelled.payload)")
            XCTAssertEqual(cancelled.payload["disposition"] as? String, "requested")
            let pending = try XCTUnwrap(cancelled.payload["operation"] as? [String: Any])
            XCTAssertEqual(pending["state"] as? String, "cancel_requested")
            XCTAssertTrue(pending["terminal_receipt"] is NSNull)
            let repeated = try await fixture.session.call(name: "clu_cancel", arguments: ["operation_id": operation])
            XCTAssertEqual(repeated.payload["disposition"] as? String, "already_requested")
        }
    }

    func testRestartReattachesExactNativeOwnerWithoutRestoringSourceMutationAuthority() async throws {
        try await withFixture { fixture in
            let peerTaskID = UUID()
            _ = try await ContinuityNativeTaskSession.enroll(app: fixture.app, taskID: peerTaskID,
                approvedAssignment: fixture.assignment, callerContext: fixture.context, callerOwner: fixture.owner)
            let handoff = try await fixture.session.call(name: "session_handoff", arguments: [
                "goal": "Original native source before restart",
            ])
            XCTAssertTrue(handoff.ok, "\(handoff.payload)")
            let id = try XCTUnwrap(handoff.payload["continuity_id"] as? String)
            let started = try await fixture.session.call(name: "clu_start_handoff", arguments: ["continuity_id": id])
            XCTAssertTrue(started.ok, "\(started.payload)")
            let operationID = try XCTUnwrap(started.payload["operation_id"] as? String)
            let before = try await fixture.session.call(name: "clu_status", arguments: ["operation_id": operationID])
            XCTAssertTrue(before.ok, "\(before.payload)")
            let sourceCounts = try self.sourceRowCounts(fixture.app)
            let home = fixture.app.paths.home
            XCTAssertTrue(fixture.app.shutdown().completed)

            let reopened = try ForgeApp.bootstrap(home: home)
            defer { _ = reopened.shutdown() }
            let restored = try await ContinuityNativeTaskSession.reattach(app: reopened, taskID: fixture.taskID,
                callerContext: fixture.context, callerOwner: fixture.owner)
            let after = try await restored.call(name: "clu_status", arguments: ["operation_id": operationID])
            XCTAssertTrue(after.ok, "\(after.payload)")
            XCTAssertEqual(try JSONSupport.data(from: after.payload), try JSONSupport.data(from: before.payload))

            let peer = try await ContinuityNativeTaskSession.reattach(app: reopened, taskID: peerTaskID,
                callerContext: fixture.context, callerOwner: fixture.owner)
            for name in ["clu_status", "clu_cancel"] {
                let denied = try await peer.call(name: name, arguments: ["operation_id": operationID])
                XCTAssertFalse(denied.ok)
                XCTAssertEqual(denied.payload["code"] as? String, "not_found", "\(denied.payload)")
            }
            let foreignOwner = ProjectBindingOwner(kind: .mcpClient, id: "different-native-carrier-client")
            let foreignBinding = try await reopened.projectContexts.repository.bind(owner: foreignOwner,
                projectID: fixture.context.projectID, generation: fixture.context.projectGeneration,
                authorizationScope: fixture.assignment.authorizationScope)
            do {
                _ = try await ContinuityNativeTaskSession.reattach(app: reopened, taskID: fixture.taskID,
                    callerContext: foreignBinding.invocationContext(clientID: ClientID(foreignOwner.id)),
                    callerOwner: foreignOwner)
                XCTFail("A different live native caller acquired the original task carrier")
            } catch {
                XCTAssertEqual(ContinuityControlToolFailure.mapping(error).code, .taskIdentityUnavailable)
            }

            let checkpoint = try await restored.call(name: "session_checkpoint", arguments: [
                "handoff_id": id, "narrative": "Attempt to rewrite the transferred source",
            ])
            XCTAssertFalse(checkpoint.ok)
            XCTAssertEqual(checkpoint.payload["code"] as? String, "source_fenced", "\(checkpoint.payload)")
            XCTAssertEqual(try self.sourceRowCounts(reopened), sourceCounts)
            let cancelled = try await restored.call(name: "clu_cancel", arguments: ["operation_id": operationID])
            XCTAssertTrue(cancelled.ok, "\(cancelled.payload)")
            XCTAssertEqual(cancelled.payload["disposition"] as? String, "requested")
            XCTAssertEqual((cancelled.payload["operation"] as? [String: Any])?["operation_id"] as? String, operationID)
            let pending = try await restored.call(name: "clu_status", arguments: ["operation_id": operationID])
            XCTAssertTrue(pending.ok, "\(pending.payload)")
            XCTAssertEqual((pending.payload["operation"] as? [String: Any])?["state"] as? String, "cancel_requested")
        }
    }

    func testSharedServerCannotBorrowNativeCarrierOrItsSameClientBinding() async throws {
        try await withFixture { fixture in
            let native = MCPServer(nativeTaskSession: fixture.session)
            let shared = MCPServer(app: fixture.app, clientID: fixture.context.clientID)
            let nativeCapabilities = try await self.toolReply(native, name: "clu_capabilities", arguments: [:])
            XCTAssertEqual(nativeCapabilities["task_identity"] as? String, "verified_native_task")
            XCTAssertEqual(nativeCapabilities["ready"] as? Bool, false)
            let sharedCapabilities = try await self.toolReply(shared, name: "clu_capabilities", arguments: [:])
            XCTAssertEqual(sharedCapabilities["task_identity"] as? String, "unavailable")
            let denied = try await self.toolReply(shared, name: "clu_start_handoff", arguments: ["continuity_id": "exact"])
            XCTAssertEqual(denied["code"] as? String, "task_identity_unavailable")
            let checkpoint = try await self.toolReply(native, name: "session_checkpoint", arguments: ["goal": "Native MCP checkpoint"])
            XCTAssertNotNil(checkpoint["continuity_id"] as? String)
            XCTAssertEqual(checkpoint["projection_excluded"] as? Bool, true)
        }
    }

    func testNativeCapabilitiesRevalidateCallerBinding() async throws {
        try await withFixture { fixture in
            _ = try await fixture.app.projectContexts.repository.beginReset(projectID: fixture.context.projectID, expectedGeneration: fixture.context.projectGeneration)
            let result = try await fixture.session.call(name: "clu_capabilities", arguments: [:])
            XCTAssertFalse(result.ok)
            XCTAssertNil(result.payload["task_identity"])
        }
    }

    private func toolReply(_ server: MCPServer, name: String, arguments: [String: Any]) async throws -> [String: Any] {
        let serialized = try SerializedToolArguments(arguments)
        let data = try await Task.detached {
            let response = try XCTUnwrap(server.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": ["name": name, "arguments": try serialized.decoded()]]))
            return try JSONSupport.data(from: response)
        }.value
        let response = try JSONSupport.object(from: data)
        let result = try XCTUnwrap(response["result"] as? [String: Any], "\(response)")
        return try XCTUnwrap(result["structuredContent"] as? [String: Any], "\(response)")
    }

    private func sourceRowCounts(_ app: ForgeApp) throws -> [Int] {
        var database: OpaquePointer?
        let opened = sqlite3_open_v2(app.paths.storeSQLite.path, &database, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(database) }
        XCTAssertEqual(opened, SQLITE_OK)
        let connection = try XCTUnwrap(database)
        var statement: OpaquePointer?
        let query = "SELECT (SELECT COUNT(*) FROM continuity_ingress_revisions), (SELECT COUNT(*) FROM continuity_ingress_outbox)"
        XCTAssertEqual(sqlite3_prepare_v2(connection, query, -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        let prepared = try XCTUnwrap(statement)
        XCTAssertEqual(sqlite3_step(prepared), SQLITE_ROW)
        return [Int(sqlite3_column_int64(prepared, 0)), Int(sqlite3_column_int64(prepared, 1))]
    }

    private func withFixture(_ body: (NativeTaskFixture) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-task-controls-\(UUID())")
            .resolvingSymlinksInPath().standardizedFileURL
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let app = try ForgeApp.bootstrap(home: root.appendingPathComponent("home"))
        defer { _ = app.shutdown(); try? FileManager.default.removeItem(at: root) }
        let policy = try app.config.budgetPolicySelection(scope: .globalDefault)
        _ = try app.config.updateBudgetPolicy(.init(scope: .globalDefault, expectedRevision: policy.revision,
            expectedGlobalRevision: policy.globalRevision, operation: .set, policy: BudgetPolicy(automaticHandoffEnabled: false)))
        let initialized = try app.projectMemory.initializeUnchecked(path: project.path)
        let projectID = ProjectID(try XCTUnwrap((initialized["project_id"] as? String).flatMap(UUID.init(uuidString:))))
        _ = try await app.projectContexts.repository.registerProjectUnchecked(projectID: projectID,
            displayName: "Native task controls", canonicalRoot: project)
        let owner = ProjectBindingOwner(kind: .mcpClient, id: "shared-native-carrier-client")
        let scope = ToolAuthorizationScope(canonicalRoots: [project], writableRoots: [], allowedTools: ["fs_read"],
            networkAllowed: false, maximumInlineOutputBytes: 65_536)
        let binding = try await app.projectContexts.repository.bind(owner: owner, projectID: projectID,
            generation: .initial, authorizationScope: scope)
        let context = binding.invocationContext(clientID: ClientID(owner.id))
        let assignment = try ContinuityTaskAssignment(assignmentID: "native-control-fixture",
            assignmentBytes: Data("Read approved native project".utf8), mission: "Read approved native project",
            providerID: "lmstudio", adapterID: "forge.native-session-host", modelKey: "fixture/native-control-model",
            specification: .init(allowedTools: ["fs_read"], completionGates: ["G04"]), authorizationScope: scope)
        let taskID = UUID()
        let session = try await ContinuityNativeTaskSession.enroll(app: app, taskID: taskID, approvedAssignment: assignment,
            callerContext: context, callerOwner: owner)
        try await body(.init(app: app, taskID: taskID, context: context, owner: owner, assignment: assignment, session: session))
    }
}

private struct NativeTaskFixture {
    let app: ForgeApp
    let taskID: UUID
    let context: ToolInvocationContext
    let owner: ProjectBindingOwner
    let assignment: ContinuityTaskAssignment
    let session: ContinuityNativeTaskSession
}
