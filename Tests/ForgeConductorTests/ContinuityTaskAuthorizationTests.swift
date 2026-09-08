// ContinuityTaskAuthorizationTests.swift
// Verifies task authority independently of a shared transport and source data.

import XCTest
import SQLite3
@testable import ForgeConductorCore

final class ContinuityTaskAuthorizationTests: XCTestCase {
    func testSharedTransportRequiresDistinctNativeTaskCorrelations() async throws {
        try await withFixture { fixture in
            let first = try await fixture.authorize(assignment: "assignment-a")
            let second = try await fixture.authorize(assignment: "assignment-b")
            XCTAssertNotEqual(first.record.authorization.taskID, second.record.authorization.taskID)
            XCTAssertNotEqual(first.record.authorization.sourceBindingID, second.record.authorization.sourceBindingID)
            XCTAssertEqual(first.correlation.callerBindingID, second.correlation.callerBindingID)
            let firstTask = try await fixture.repository.withAuthorizedContinuityTask(
                taskID: first.record.authorization.taskID, correlation: first.correlation,
                context: fixture.context, owner: fixture.owner) { $0.taskID }
            XCTAssertEqual(firstTask, first.record.authorization.taskID)
            await expectTaskError(.taskCorrelationRequired) {
                _ = try await fixture.repository.withAuthorizedContinuityTask(
                    taskID: firstTask, correlation: nil, context: fixture.context, owner: fixture.owner) { _ in
                        XCTFail("A shared MCP process minted task authority")
                        return false
                    }
            }
            await expectTaskError(.authorityMismatch) {
                _ = try await fixture.repository.withAuthorizedContinuityTask(
                    taskID: second.record.authorization.taskID, correlation: first.correlation,
                    context: fixture.context, owner: fixture.owner) { _ in
                        XCTFail("Task A's correlation accessed task B")
                        return false
                    }
            }
            let secondTask = try await fixture.repository.withAuthorizedContinuityTask(
                taskID: second.record.authorization.taskID, correlation: second.correlation,
                context: fixture.context, owner: fixture.owner) { $0.taskID }
            XCTAssertEqual(secondTask, second.record.authorization.taskID)
        }
    }

    func testApprovedAssignmentBindsExecutionInputsAndSurvivesRestart() async throws {
        try await withFixture { fixture in
            let approved = try fixture.assignment()
            let setup = try await fixture.authorize(approved: approved)
            for variant in [
                try fixture.assignment(mission: "A different execution mission"),
                try fixture.assignment(provider: "different-provider"),
                try fixture.assignment(gates: ["different-completion-gate"]),
            ] {
                XCTAssertEqual(variant.assignmentBytes, approved.assignmentBytes)
                XCTAssertEqual(variant.documentSHA256, approved.documentSHA256)
                XCTAssertNotEqual(variant.assignmentSHA256, approved.assignmentSHA256)
                await expectTaskError(.assignmentConflict) {
                    _ = try await fixture.authorize(taskID: setup.record.authorization.taskID, approved: variant)
                }
            }
            let stored = try approved.storedJSON()
            var changed = try XCTUnwrap(JSONSerialization.jsonObject(with: stored) as? [String: Any])
            changed["mission"] = "Changed while retaining the approved digest"
            XCTAssertThrowsError(try ContinuityTaskAssignment.storedSnapshot(from: ForgeJSONCanonicalizationV1.data(from: changed)))
            await fixture.repository.close()
            let reopened = try ProjectControlPlaneRepository(databaseURL: fixture.database)
            do {
                let restored = try await reopened.validateContinuityIngressAuthorization(setup.record.authorization)
                XCTAssertEqual(restored, setup.record)
                XCTAssertEqual(restored.assignment.authorizationScope.writableRoots, [])
                XCTAssertEqual(restored.assignment.assignmentBytes, approved.assignmentBytes)
                XCTAssertNil(restored.runID, "Task setup must not start or invent a managed provider run")
            } catch {
                await reopened.close()
                throw error
            }
            await reopened.close()
        }
    }

    func testPermanentRevocationSurvivesGenericBindingReactivationAndRestart() async throws {
        try await withFixture { fixture in
            let first = try await fixture.authorize(assignment: "revoked-task")
            let other = try await fixture.authorize(assignment: "unrelated-task")
            let authority = first.record.authorization
            let revoked = try await fixture.repository.revokeContinuityTask(taskID: authority.taskID,
                projectID: fixture.projectID, expectedGeneration: .initial)
            XCTAssertEqual(revoked.state, .revoked)
            XCTAssertEqual(revoked.revision, 2)
            let repeated = try await fixture.repository.revokeContinuityTask(taskID: authority.taskID,
                projectID: fixture.projectID, expectedGeneration: .initial)
            XCTAssertEqual(repeated, revoked)
            // The legacy generic binding API reuses an inactive row's UUID.
            // Its reactivation must not revive the separate task grant.
            let reactivated = try await fixture.repository.bind(
                owner: .init(kind: .agentSession, id: authority.taskID.uuidString.lowercased()),
                projectID: fixture.projectID, generation: .initial,
                authorizationScope: authority.authorizationScope)
            XCTAssertEqual(reactivated.bindingID, authority.sourceBindingID)
            await expectTaskError(.revoked) {
                _ = try await fixture.repository.validateContinuityIngressAuthorization(authority)
            }
            await expectTaskError(.revoked) {
                _ = try await fixture.authorize(taskID: authority.taskID, approved: first.record.assignment)
            }
            let otherTask = try await fixture.repository.withAuthorizedContinuityTask(
                taskID: other.record.authorization.taskID, correlation: other.correlation,
                context: fixture.context, owner: fixture.owner) { $0.taskID }
            XCTAssertEqual(otherTask, other.record.authorization.taskID)
            await fixture.repository.close()
            let reopened = try ProjectControlPlaneRepository(databaseURL: fixture.database)
            await expectTaskError(.revoked) {
                _ = try await reopened.validateContinuityIngressAuthorization(authority)
            }
            await reopened.close()
        }
    }

    func testTamperedSourceAuthorityAndStoredAssignmentCannotBecomeAuthoritative() async throws {
        try await withFixture { fixture in
            let setup = try await fixture.authorize()
            let original = setup.record.authorization
            let forged = [
                try ContinuityIngressAuthorization(projectID: original.projectID, projectGeneration: original.projectGeneration,
                    sourceBindingID: UUID(), taskID: original.taskID, assignmentID: original.assignmentID,
                    assignmentSHA256: original.assignmentSHA256, authorizationScope: original.authorizationScope),
                try ContinuityIngressAuthorization(projectID: original.projectID, projectGeneration: original.projectGeneration,
                    sourceBindingID: original.sourceBindingID, taskID: original.taskID, assignmentID: original.assignmentID,
                    assignmentSHA256: String(repeating: "0", count: 64), authorizationScope: original.authorizationScope),
                try ContinuityIngressAuthorization(projectID: original.projectID, projectGeneration: .init(2),
                    sourceBindingID: original.sourceBindingID, taskID: original.taskID, assignmentID: original.assignmentID,
                    assignmentSHA256: original.assignmentSHA256, authorizationScope: original.authorizationScope),
                try ContinuityIngressAuthorization(projectID: original.projectID, projectGeneration: original.projectGeneration,
                    sourceBindingID: original.sourceBindingID, taskID: original.taskID, assignmentID: original.assignmentID,
                    assignmentSHA256: original.assignmentSHA256,
                    authorizationScope: ToolAuthorizationScope(canonicalRoots: [fixture.projectRoot],
                        allowedTools: ["fs_write"], networkAllowed: false, maximumInlineOutputBytes: 65_536)),
            ]
            for snapshot in forged {
                await expectTaskError(.authorityMismatch) {
                    _ = try await fixture.repository.validateContinuityIngressAuthorization(snapshot)
                }
            }
            try TaskAuthorizationFixtureSQLite.execute(at: fixture.database,
                sql: "UPDATE continuity_task_authorizations SET assignment_json=replace(assignment_json,'Approved fixture mission','Unapproved changed mission') WHERE task_id=?",
                values: [original.taskID.uuidString.lowercased()])
            do {
                _ = try await fixture.repository.validateContinuityIngressAuthorization(original)
                XCTFail("A corrupted stored assignment gained authority")
            } catch let error as ContinuityTaskAuthorizationError {
                guard case .integrityFailure = error else { return XCTFail("Unexpected error: \(error)") }
            }
            // Keep the approved canonical prefix and all original digest fields.
            // A C-string reader would discard the NUL and suffix, then approve it.
            let canonical = String(decoding: try setup.record.assignment.storedJSON(), as: UTF8.self)
            try TaskAuthorizationFixtureSQLite.execute(at: fixture.database,
                sql: "UPDATE continuity_task_authorizations SET assignment_json=? || char(0) || 'unvalidated-suffix' WHERE task_id=?",
                values: [canonical, original.taskID.uuidString.lowercased()])
            do {
                _ = try await fixture.repository.validateContinuityIngressAuthorization(original)
                XCTFail("A stored NUL silently truncated the approved snapshot")
            } catch let error as ProjectContextError {
                XCTAssertEqual(error, .integrityFailure("invalid SQLite text bytes at column 6"))
            }
        }
    }

    func testSourceOutboxCommitHoldsWriterFenceAgainstConcurrentReset() async throws {
        try await withFixture { fixture in
            let setup = try await fixture.authorize()
            let source = try SQLiteStore(path: fixture.root.appendingPathComponent("source.sqlite3"))
            defer { source.close() }
            let contender = try ProjectControlPlaneRepository(databaseURL: fixture.database)
            let entered = expectation(description: "Authorized source mutation holds the task writer fence")
            let contended = expectation(description: "Reset attempts the same SQLite writer fence")
            let release = DispatchSemaphore(value: 0)
            await contender.configureOperationObservers(busyRetry: { contended.fulfill() })
            let packet = HandoffPacket(resumeReady: true, clientID: fixture.context.clientID.rawValue,
                goal: "Model text remains handoff data", nextActions: ["Continue the approved assignment"])
            let committing = Task {
                try await fixture.repository.withAuthorizedContinuityTask(
                    taskID: setup.record.authorization.taskID, correlation: setup.correlation,
                    context: fixture.context, owner: fixture.owner) { authority in
                        entered.fulfill()
                        guard release.wait(timeout: .now() + 5) == .success else {
                            throw ContinuityTaskAuthorizationError.integrityFailure("source fence fixture deadline")
                        }
                        return try source.handoffCommit(packet, authorization: authority, automaticHandoffEnabled: true)
                    }
            }
            await fulfillment(of: [entered], timeout: 2)
            let resetting = Task {
                try await contender.beginReset(projectID: fixture.projectID, expectedGeneration: .initial)
            }
            await fulfillment(of: [contended], timeout: 2)
            release.signal()
            do {
                let committed = try await committing.value
                let reset = try await resetting.value
                XCTAssertEqual(reset.lifecycleState, .resetting)
                let operation = try XCTUnwrap(committed.delivery?.operationID)
                let persisted = try XCTUnwrap(source.continuityDelivery(operationID: operation))
                XCTAssertEqual(persisted.handoff, committed.revision)
                XCTAssertEqual(persisted.handoff.authorization, setup.record.authorization)
                // The source committed first. Reset revokes the control-plane
                // authority before delivery can accept or disclose this operation.
                await expectTaskError(.revoked) {
                    _ = try await contender.validateContinuityIngressAuthorization(persisted.handoff.authorization)
                }
                _ = try await contender.completeReset(projectID: fixture.projectID, expectedGeneration: .initial)
                do {
                    _ = try await fixture.repository.withAuthorizedContinuityTask(
                        taskID: setup.record.authorization.taskID, correlation: setup.correlation,
                        context: fixture.context, owner: fixture.owner) { _ in
                            XCTFail("A stale source callback executed after reset")
                            return false
                        }
                    XCTFail("Expected stale generation rejection")
                } catch let error as ProjectContextError {
                    XCTAssertEqual(error.code, "stale_project_generation")
                }
            } catch {
                await contender.close()
                throw error
            }
            await contender.close()
        }
    }

    func testResetCancellationDoesNotReviveTaskAuthority() async throws {
        try await withFixture { fixture in
            let setup = try await fixture.authorize()
            _ = try await fixture.repository.beginReset(projectID: fixture.projectID, expectedGeneration: .initial)
            try await fixture.repository.cancelReset(projectID: fixture.projectID, expectedGeneration: .initial)
            await expectTaskError(.revoked) {
                _ = try await fixture.repository.validateContinuityIngressAuthorization(setup.record.authorization)
            }
        }
    }

    private func expectTaskError(_ expected: ContinuityTaskAuthorizationError,
                                 file: StaticString = #filePath, line: UInt = #line,
                                 _ operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("Expected task authorization error: \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ContinuityTaskAuthorizationError, expected, file: file, line: line)
        }
    }

    private func withFixture(_ operation: (TaskAuthorizationFixture) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("continuity-task-\(UUID().uuidString)")
            .resolvingSymlinksInPath().standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = root.appendingPathComponent("control-plane.sqlite3")
        let repository = try ProjectControlPlaneRepository(databaseURL: database)
        do {
            let projectRoot = root.appendingPathComponent("project")
            try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
            let projectID = ProjectID()
            _ = try await repository.registerProjectUnchecked(projectID: projectID, displayName: "Task fixture", canonicalRoot: projectRoot)
            let client = ClientID("shared-transport-" + UUID().uuidString.lowercased())
            let owner = ProjectBindingOwner(kind: .mcpClient, id: client.rawValue)
            let binding = try await repository.bind(owner: owner, projectID: projectID, generation: .initial,
                authorizationScope: ToolAuthorizationScope(canonicalRoots: [projectRoot], writableRoots: [],
                    allowedTools: ["context_get", "fs_read"], networkAllowed: false, maximumInlineOutputBytes: 65_536))
            let fixture = TaskAuthorizationFixture(root: root, database: database, repository: repository,
                projectID: projectID, projectRoot: projectRoot, owner: owner, context: binding.invocationContext(clientID: client))
            try await operation(fixture)
        } catch {
            await repository.close()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        await repository.close()
        try? FileManager.default.removeItem(at: root)
    }
}

private struct TaskAuthorizationFixture: Sendable {
    let root: URL
    let database: URL
    let repository: ProjectControlPlaneRepository
    let projectID: ProjectID
    let projectRoot: URL
    let owner: ProjectBindingOwner
    let context: ToolInvocationContext

    func assignment(id: String = "approved-assignment", mission: String = "Approved fixture mission",
                    provider: String = "lmstudio", gates: [String] = ["fixture-completion"]) throws -> ContinuityTaskAssignment {
        try ContinuityTaskAssignment(assignmentID: id, assignmentBytes: Data("Approved fixture instructions".utf8),
            mission: mission, providerID: provider, adapterID: "forge.native-session-host", modelKey: "fixture/model",
            specification: AutonomousRunSpecification(allowedTools: ["context_get", "fs_read"], completionGates: gates),
            authorizationScope: context.authorizationScope)
    }

    func authorize(taskID: UUID = UUID(), assignment: String = "approved-assignment",
                   approved: ContinuityTaskAssignment? = nil) async throws -> AuthorizedContinuityTaskSetup {
        let value = try approved ?? self.assignment(id: assignment)
        return try await repository.authorizeContinuityTask(taskID: taskID, projectID: projectID,
            expectedGeneration: .initial, approvedAssignment: value, callerContext: context, callerOwner: owner)
    }
}

private enum TaskAuthorizationFixtureSQLite {
    static func execute(at path: URL, sql: String, values: [String]) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(path.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else { throw ContinuityTaskAuthorizationError.integrityFailure("fixture open") }
        defer { sqlite3_close_v2(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ContinuityTaskAuthorizationError.integrityFailure("fixture prepare")
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            let result = value.withCString {
                sqlite3_bind_text(statement, Int32(index + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            guard result == SQLITE_OK else { throw ContinuityTaskAuthorizationError.integrityFailure("fixture bind") }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw ContinuityTaskAuthorizationError.integrityFailure("fixture mutation") }
    }
}
