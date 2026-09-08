import XCTest
import SQLite3
@testable import ForgeConductorCore

final class ContinuityTaskReattachmentTests: XCTestCase {
    func testRestartReissuesOnlyExactTaskCorrelationWithoutChangingAnyRows() async throws {
        try await withFixture { fixture in
            let peer = try await fixture.enroll()
            let before = try ReattachmentSQLite.snapshot(fixture.database)
            await fixture.repository.close()
            let reopened = try ProjectControlPlaneRepository(databaseURL: fixture.database)
            do {
                let own = try await fixture.reattach(repository: reopened)
                let other = try await fixture.reattach(taskID: peer.record.authorization.taskID, repository: reopened)
                XCTAssertEqual(own.record, fixture.setup.record)
                XCTAssertEqual(other.record, peer.record)
                XCTAssertEqual(own.correlation.callerBindingID, fixture.caller.bindingID)
                XCTAssertEqual(own.correlation.authorizationSHA256, fixture.setup.correlation.authorizationSHA256)
                XCTAssertEqual(own.correlation.sourceBindingID, fixture.setup.correlation.sourceBindingID)
                XCTAssertNotEqual(own.correlation.taskID, other.correlation.taskID)
                XCTAssertNotEqual(own.correlation.sourceBindingID, other.correlation.sourceBindingID)
                XCTAssertNil(own.record.runID)
                XCTAssertNil(other.record.runID)
                do {
                    _ = try await fixture.reattach(taskID: UUID(), repository: reopened)
                    XCTFail("An unknown task was replaced with an available task")
                } catch { XCTAssertEqual(error as? ContinuityTaskAuthorizationError, .authorityMismatch) }
                do {
                    _ = try await reopened.withAuthorizedContinuityTask(taskID: other.correlation.taskID,
                        correlation: own.correlation, context: fixture.context, owner: fixture.caller.owner) { _ in
                            XCTFail("One task's correlation reached its peer's source mutation")
                            return false
                        }
                    XCTFail("A same-transport peer correlation was accepted")
                } catch { XCTAssertEqual(error as? ContinuityTaskAuthorizationError, .authorityMismatch) }
                XCTAssertEqual(try ReattachmentSQLite.snapshot(fixture.database), before)
                await reopened.close()
            } catch { await reopened.close(); throw error }
        }
    }

    func testForeignOriginRejectsBeforeDecodingCorruptOwnedAssignment() async throws {
        try await withFixture { fixture in
            let foreign = try await fixture.repository.bind(owner: .init(kind: .mcpClient, id: "foreign-attachment"),
                projectID: fixture.projectID, generation: .initial, authorizationScope: fixture.caller.authorizationScope)
            await expectIdentityUnavailable { _ = try await fixture.reattach(caller: foreign) }
            try ReattachmentSQLite.execute(fixture.database,
                "UPDATE continuity_task_authorizations SET assignment_json='corrupt retained assignment' WHERE task_id=?",
                [fixture.setup.record.authorization.taskID.uuidString.lowercased()])
            let before = try ReattachmentSQLite.snapshot(fixture.database)
            await expectIdentityUnavailable { _ = try await fixture.reattach(caller: foreign) }
            do {
                _ = try await fixture.reattach()
                XCTFail("The actual owner accepted its corrupted assignment")
            } catch {
                guard let taskError = error as? ContinuityTaskAuthorizationError,
                      case .integrityFailure = taskError else {
                    return XCTFail("Expected retained assignment integrity failure, got \(error)")
                }
            }
            XCTAssertEqual(try ReattachmentSQLite.snapshot(fixture.database), before)
        }
    }

    func testRevokedTaskStaleGenerationAndRunBoundContextCannotReattach() async throws {
        try await withFixture { fixture in
            let peer = try await fixture.enroll()
            let changed = ToolInvocationContext(projectID: fixture.projectID, projectGeneration: .initial,
                clientID: fixture.context.clientID, runID: RunID(), authorizationScope: fixture.caller.authorizationScope)
            do {
                _ = try await fixture.repository.reattachContinuityTask(taskID: fixture.setup.record.authorization.taskID,
                    projectID: fixture.projectID, expectedGeneration: .initial, callerContext: changed, callerOwner: fixture.caller.owner)
                XCTFail("A run-bound context substituted for the original native caller")
            } catch { XCTAssertEqual(error as? ContinuityTaskAuthorizationError, .authorityMismatch) }
            _ = try await fixture.repository.revokeContinuityTask(taskID: fixture.setup.record.authorization.taskID,
                projectID: fixture.projectID, expectedGeneration: .initial)
            let revoked = try ReattachmentSQLite.snapshot(fixture.database)
            do { _ = try await fixture.reattach(); XCTFail("Revoked task was reissued") }
            catch { XCTAssertEqual(error as? ContinuityTaskAuthorizationError, .revoked) }
            let independent = try await fixture.reattach(taskID: peer.record.authorization.taskID)
            XCTAssertEqual(independent.record, peer.record)
            XCTAssertEqual(try ReattachmentSQLite.snapshot(fixture.database), revoked)
            _ = try await fixture.repository.beginReset(projectID: fixture.projectID, expectedGeneration: .initial)
            _ = try await fixture.repository.completeReset(projectID: fixture.projectID, expectedGeneration: .initial)
            let reset = try ReattachmentSQLite.snapshot(fixture.database)
            do { _ = try await fixture.reattach(taskID: peer.record.authorization.taskID); XCTFail("A stale project reattached") }
            catch { XCTAssertEqual((error as? ProjectContextError)?.code, "stale_project_generation") }
            XCTAssertEqual(try ReattachmentSQLite.snapshot(fixture.database), reset)
        }
    }

    func testMissingAndIrreversiblyInvalidatedOriginsCannotBeRepairedByReattachment() async throws {
        for mutation in ["missing", "scope-restored", "reactivated", "replaced"] {
            try await withFixture { fixture in
                let bindingID = fixture.caller.bindingID.uuidString.lowercased()
                var caller = fixture.caller
                switch mutation {
                case "missing":
                    try ReattachmentSQLite.execute(fixture.database, "DELETE FROM continuity_source_dispatch_origins")
                case "scope-restored":
                    // Both writes use another connection; the original scope is
                    // restored but the durable origin invalidation must remain.
                    let original = try ReattachmentSQLite.text(fixture.database,
                        "SELECT authorization_scope_json FROM project_bindings WHERE binding_id=?", [bindingID])
                    try ReattachmentSQLite.execute(fixture.database,
                        "UPDATE project_bindings SET authorization_scope_json=replace(authorization_scope_json,'fs_read','fs_write') WHERE binding_id=?", [bindingID])
                    try ReattachmentSQLite.execute(fixture.database,
                        "UPDATE project_bindings SET authorization_scope_json=? WHERE binding_id=?", [original, bindingID])
                case "reactivated":
                    try ReattachmentSQLite.execute(fixture.database, "UPDATE project_bindings SET active=0 WHERE binding_id=?", [bindingID])
                    try ReattachmentSQLite.execute(fixture.database, "UPDATE project_bindings SET active=1 WHERE binding_id=?", [bindingID])
                default:
                    try ReattachmentSQLite.execute(fixture.database, "DELETE FROM project_bindings WHERE binding_id=?", [bindingID])
                    caller = try await fixture.repository.bind(owner: fixture.caller.owner, projectID: fixture.projectID,
                        generation: .initial, authorizationScope: fixture.caller.authorizationScope)
                    XCTAssertNotEqual(caller.bindingID, fixture.caller.bindingID)
                }
                let before = try ReattachmentSQLite.snapshot(fixture.database)
                await expectIdentityUnavailable { _ = try await fixture.reattach(caller: caller) }
                XCTAssertEqual(try ReattachmentSQLite.snapshot(fixture.database), before, mutation)
            }
        }
    }

    func testCancellationBeforeReadAndAtCommitReturnsNoCorrelationOrMutation() async throws {
        try await withFixture { fixture in
            let before = try ReattachmentSQLite.snapshot(fixture.database)
            let alreadyCancelled = ToolCallCancellation()
            alreadyCancelled.cancel()
            do { _ = try await fixture.reattach(cancellation: alreadyCancelled); XCTFail("Cancelled attachment returned authority") }
            catch { XCTAssertTrue(error is CancellationError) }
            let atCommit = ToolCallCancellation()
            await fixture.repository.configureOperationObservers(beforeCommit: { atCommit.cancel() })
            do { _ = try await fixture.reattach(cancellation: atCommit); XCTFail("Cancellation at the issuer boundary returned authority") }
            catch { XCTAssertTrue(error is CancellationError) }
            await fixture.repository.configureOperationObservers()
            XCTAssertEqual(try ReattachmentSQLite.snapshot(fixture.database), before)
            let retry = try await fixture.reattach()
            XCTAssertEqual(retry.record, fixture.setup.record)
            XCTAssertEqual(try ReattachmentSQLite.snapshot(fixture.database), before)
        }
    }

    func testTerminalRunReattachmentRetainsCompletedCancellationAndSourceFence() async throws {
        try await withFixture { fixture in
            let handoff = try fixture.source.handoffCommit(HandoffPacket(id: "terminal-attachment", source: .model,
                resumeReady: true, goal: "Read fixture"), authorization: fixture.setup.record.authorization, automaticHandoffEnabled: true)
            let identity = try ContinuityIngressOperationIdentity(revision: handoff.revision)
            let policy = try BudgetPolicyState(globalPolicy: BudgetPolicy(automaticHandoffEnabled: true)).resolve(
                .init(kind: .projectOverride, projectID: fixture.projectID.description, projectGeneration: 1))
            let acceptance = try await fixture.repository.acceptContinuityIngress(source: handoff.revision,
                operationID: identity.operationID, policySelection: policy)
            _ = try await fixture.repository.requestContinuityOperationCancellation(operationID: acceptance.operationID,
                taskID: fixture.setup.correlation.taskID, correlation: fixture.setup.correlation,
                context: fixture.context, owner: fixture.caller.owner)
            let page = try await fixture.repository.pendingContinuityOperationCancellations()
            let reference = try XCTUnwrap(page.references.first)
            let lease = try await fixture.repository.acquireContinuityOperationCancellationLease(reference: reference, ownerID: "attachment-cleanup")
            let claim = try await fixture.repository.claimContinuityOperationCancellation(reference: reference, lease: lease)
            let receipt = try await fixture.repository.completeContinuityOperationCancellation(claim: claim, lease: lease) { request, accepted in
                try .init(canonical: fixture.memory.continuityCancelSourceBootstrap(request: request, acceptance: accepted),
                    source: fixture.source.cancelContinuitySourceDelivery(request: request, acceptance: accepted))
            }
            _ = try await fixture.repository.releaseRunLease(lease)
            let before = try ReattachmentSQLite.snapshot(fixture.database)
            await fixture.repository.close()
            let reopened = try ProjectControlPlaneRepository(databaseURL: fixture.database)
            do {
                let restored = try await fixture.reattach(repository: reopened)
                XCTAssertEqual(restored.record.runID, acceptance.runID)
                XCTAssertEqual(restored.record.authorization, fixture.setup.record.authorization)
                let status = try await reopened.continuityOperationStatus(operationID: acceptance.operationID,
                    taskID: restored.correlation.taskID, correlation: restored.correlation, context: fixture.context, owner: fixture.caller.owner)
                XCTAssertEqual(status.state, .cancelled)
                XCTAssertEqual(status.terminalReceipt?.receiptSHA256, receipt.receiptSHA256)
                XCTAssertEqual(try ReattachmentSQLite.text(fixture.database, "SELECT state FROM autonomous_runs"), "cancelled")
                XCTAssertEqual(try ReattachmentSQLite.text(fixture.database, "SELECT COUNT(*) FROM continuity_source_task_fences"), "1")
                XCTAssertEqual(try ReattachmentSQLite.snapshot(fixture.database), before)
                await reopened.close()
            } catch { await reopened.close(); throw error }
        }
    }

    private func expectIdentityUnavailable(_ body: () async throws -> Void,
        file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("An unproven original caller reattached", file: file, line: line) }
        catch { XCTAssertEqual(error as? ContinuitySourceActivationError, .taskIdentityUnavailable, file: file, line: line) }
    }

    private func withFixture(_ body: (ReattachmentFixture) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("continuity-reattachment-\(UUID().uuidString)")
            .resolvingSymlinksInPath().standardizedFileURL
        let projectRoot = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let database = root.appendingPathComponent("control.sqlite3")
        let repository = try ProjectControlPlaneRepository(databaseURL: database)
        let source = try SQLiteStore(path: root.appendingPathComponent("source.sqlite3"))
        let projectID = ProjectID()
        let memory = try ProjectMemoryRepository(projectID: projectID.description, directory: root.appendingPathComponent("memory"), enableFTS5: false)
        do {
            _ = try await repository.registerProjectUnchecked(projectID: projectID, displayName: "Reattachment fixture", canonicalRoot: projectRoot)
            let scope = ToolAuthorizationScope(canonicalRoots: [projectRoot], writableRoots: [], allowedTools: ["fs_read"],
                networkAllowed: false, maximumInlineOutputBytes: 65_536)
            let caller = try await repository.bind(owner: .init(kind: .mcpClient, id: "native-attachment-owner"),
                projectID: projectID, generation: .initial, authorizationScope: scope)
            let assignment = try ContinuityTaskAssignment(assignmentID: "approved-attachment", assignmentBytes: Data("Read fixture".utf8),
                mission: "Read fixture", providerID: "lmstudio", adapterID: "forge.native-session-host", modelKey: "fixture/attachment",
                specification: .init(allowedTools: ["fs_read"], completionGates: ["G04"]), authorizationScope: scope)
            let setup = try await repository.authorizeContinuityTask(projectID: projectID, expectedGeneration: .initial,
                approvedAssignment: assignment, callerContext: caller.invocationContext(clientID: ClientID(caller.owner.id)), callerOwner: caller.owner)
            try await body(.init(database: database, repository: repository, source: source, memory: memory,
                projectID: projectID, caller: caller, setup: setup))
            memory.close(); source.close(); await repository.close(); try FileManager.default.removeItem(at: root)
        } catch { memory.close(); source.close(); await repository.close(); try? FileManager.default.removeItem(at: root); throw error }
    }
}

private struct ReattachmentFixture: Sendable {
    let database: URL
    let repository: ProjectControlPlaneRepository
    let source: SQLiteStore
    let memory: ProjectMemoryRepository
    let projectID: ProjectID
    let caller: ProjectContextBinding
    let setup: AuthorizedContinuityTaskSetup
    var context: ToolInvocationContext { caller.invocationContext(clientID: ClientID(caller.owner.id)) }

    func enroll() async throws -> AuthorizedContinuityTaskSetup {
        try await repository.authorizeContinuityTask(projectID: projectID, expectedGeneration: .initial,
            approvedAssignment: setup.record.assignment, callerContext: context, callerOwner: caller.owner)
    }

    func reattach(taskID: UUID? = nil, repository replacement: ProjectControlPlaneRepository? = nil,
        caller selectedCaller: ProjectContextBinding? = nil, cancellation: ToolCallCancellation? = nil) async throws -> AuthorizedContinuityTaskSetup {
        let selected = selectedCaller ?? caller
        return try await (replacement ?? repository).reattachContinuityTask(taskID: taskID ?? setup.record.authorization.taskID,
            projectID: projectID, expectedGeneration: .initial,
            callerContext: selected.invocationContext(clientID: ClientID(selected.owner.id)), callerOwner: selected.owner, cancellation: cancellation)
    }
}

private enum ReattachmentSQLite {
    static func execute(_ url: URL, _ sql: String, _ values: [String] = []) throws {
        try connection(url) { database in
            try statement(database, sql, values) { row in
                guard sqlite3_step(row) == SQLITE_DONE else { throw Failure.sqlite }
            }
        }
    }

    static func text(_ url: URL, _ sql: String, _ values: [String] = []) throws -> String {
        try connection(url) { database in
            try statement(database, sql, values) { row in
                guard sqlite3_step(row) == SQLITE_ROW, let text = sqlite3_column_text(row, 0) else { throw Failure.sqlite }
                return String(cString: text)
            }
        }
    }

    // Exact logical cell bytes, including every table's empty/nonempty state.
    // WAL/header housekeeping is intentionally not treated as a row mutation.
    static func snapshot(_ url: URL) throws -> [String: [String]] {
        try connection(url) { database in
            var result: [String: [String]] = [:]
            var bytes = 0
            try statement(database, "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name", []) { tables in
                var tableStatus = sqlite3_step(tables)
                while tableStatus == SQLITE_ROW {
                    guard result.count < 128, let name = sqlite3_column_text(tables, 0) else { throw Failure.bound }
                    let table = String(cString: name)
                    let escaped = table.replacingOccurrences(of: "\"", with: "\"\"")
                    var rows: [String] = []
                    try statement(database, "SELECT * FROM \"\(escaped)\"", []) { statement in
                        var status = sqlite3_step(statement)
                        while status == SQLITE_ROW {
                            guard rows.count < 512 else { throw Failure.bound }
                            var cells: [String] = []
                            for index in 0..<sqlite3_column_count(statement) {
                                let type = sqlite3_column_type(statement, index)
                                let count = Int(sqlite3_column_bytes(statement, index))
                                bytes += count
                                guard count <= 1_048_576, bytes <= 16_777_216 else { throw Failure.bound }
                                let data = sqlite3_column_blob(statement, index).map { Data(bytes: $0, count: count) } ?? Data()
                                cells.append("\(type):\(data.base64EncodedString())")
                            }
                            rows.append(cells.joined(separator: "|"))
                            status = sqlite3_step(statement)
                        }
                        guard status == SQLITE_DONE else { throw Failure.sqlite }
                    }
                    result[table] = rows.sorted()
                    tableStatus = sqlite3_step(tables)
                }
                guard tableStatus == SQLITE_DONE else { throw Failure.sqlite }
            }
            return result
        }
    }

    private static func connection<Value>(_ url: URL, _ body: (OpaquePointer) throws -> Value) throws -> Value {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let handle else {
            throw Failure.sqlite
        }
        defer { sqlite3_close_v2(handle) }
        return try body(handle)
    }

    private static func statement<Value>(_ database: OpaquePointer, _ sql: String, _ values: [String],
        _ body: (OpaquePointer) throws -> Value) throws -> Value {
        var handle: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &handle, nil) == SQLITE_OK, let handle else { throw Failure.sqlite }
        defer { sqlite3_finalize(handle) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            guard sqlite3_bind_text(handle, Int32(index + 1), value, -1, transient) == SQLITE_OK else { throw Failure.sqlite }
        }
        return try body(handle)
    }

    private enum Failure: Error { case sqlite, bound }
}
