import XCTest
import SQLite3
@testable import ForgeConductorCore

final class ContinuityOperationControlTests: XCTestCase {
    func testStatusUsesNativeOwnerBeforeUnknownOrCorruptForeignOperation() async throws {
        try await withFixture { fixture in
            let other = try await fixture.makeTask(id: "independent")
            try ControlSQLite.execute(fixture.database, "UPDATE continuity_ingress_acceptances SET receipt_json='corrupt foreign body' WHERE operation_id=?",
                [other.acceptance.operationID.uuidString.lowercased()])
            for id in [UUID(), other.acceptance.operationID] {
                do { _ = try await fixture.status(operation: id); XCTFail("Foreign operation was disclosed") }
                catch { XCTAssertEqual(error as? ContinuityOperationControlError, .notFound) }
                do { _ = try await fixture.cancel(operation: id); XCTFail("Foreign operation was cancelled") }
                catch { XCTAssertEqual(error as? ContinuityOperationControlError, .notFound) }
            }
            do {
                _ = try await fixture.repository.continuityOperationStatus(operationID: other.acceptance.operationID,
                    taskID: fixture.task.setup.record.authorization.taskID, correlation: nil,
                    context: fixture.context, owner: fixture.caller.owner)
                XCTFail("An uncorrelated caller reached operation lookup")
            } catch { XCTAssertEqual(error as? ContinuityTaskAuthorizationError, .taskCorrelationRequired) }
            XCTAssertEqual(try ControlSQLite.text(fixture.database, "SELECT COUNT(*) FROM continuity_operation_cancellations"), "0")
        }
    }

    func testStatusDoesNotLeaseOrSpendAttemptsAndReportsActualPreparedProgress() async throws {
        try await withFixture { fixture in
            let prepared = try fixture.memory.continuityPrepareSourceBootstrap(acceptance: fixture.task.acceptance,
                authorization: fixture.task.acceptance.authorization, bootstrapNonce: UUID())
            let before = try ControlSQLite.text(fixture.database,
                "SELECT revision || ':' || updated_at FROM autonomous_runs WHERE run_id=?", [fixture.task.acceptance.runID.description])
            let status = try await fixture.repository.continuityOperationStatus(operationID: fixture.task.acceptance.operationID,
                taskID: fixture.task.setup.record.authorization.taskID, correlation: fixture.task.setup.correlation,
                context: fixture.context, owner: fixture.caller.owner) { acceptance in
                    .init(source: try fixture.source.continuityHandoffRevision(identity: acceptance.sourceIdentity, authorization: acceptance.authorization),
                        delivery: try fixture.source.continuityDelivery(operationID: acceptance.operationID), canonical: prepared)
                }
            XCTAssertEqual(status.state, .handoffCommitted)
            XCTAssertEqual(status.deliveryState, .pending)
            XCTAssertNil(status.terminalReceipt)
            let unchanged = try await fixture.status()
            XCTAssertNil(unchanged.deliveryState)
            XCTAssertEqual(unchanged.recoveryState, .uncertain)
            XCTAssertEqual(try ControlSQLite.text(fixture.database, "SELECT COUNT(*) FROM run_leases"), "0")
            XCTAssertEqual(try ControlSQLite.text(fixture.database, "SELECT SUM(recovery_attempts) FROM continuity_ingress_holds"), "0")
            XCTAssertEqual(try ControlSQLite.text(fixture.database,
                "SELECT revision || ':' || updated_at FROM autonomous_runs WHERE run_id=?", [fixture.task.acceptance.runID.description]), before)
        }
    }

    func testCancellationCommitsBeforeSourceAccessAndReopensIdempotently() async throws {
        try await withFixture { fixture in
            let requested = try await fixture.cancel()
            XCTAssertEqual(requested.disposition, .requested)
            XCTAssertEqual(requested.snapshot.state, .cancelRequested)
            XCTAssertNil(requested.snapshot.terminalReceipt)
            XCTAssertEqual(try ControlSQLite.text(fixture.database, "SELECT state FROM autonomous_runs"), "awaiting_bootstrap")
            XCTAssertEqual(try ControlSQLite.text(fixture.database, "SELECT COUNT(*) FROM provider_sessions"), "0")
            let reopened = try ProjectControlPlaneRepository(databaseURL: fixture.database)
            let copy = fixture.replacing(repository: reopened)
            let duplicate = try await copy.cancel()
            XCTAssertEqual(duplicate.disposition, .alreadyRequested)
            XCTAssertEqual(duplicate.request, requested.request)
            let status = try await reopened.continuityOperationStatus(operationID: fixture.task.acceptance.operationID,
                taskID: fixture.task.setup.record.authorization.taskID, correlation: fixture.task.setup.correlation,
                context: fixture.context, owner: fixture.caller.owner) { _ in
                    throw ContinuityOperationControlError.integrityFailure
                }
            XCTAssertEqual(status.state, .cancelRequested, "Cancellation status does not reopen tombstoned or unavailable stores")
            do {
                _ = try await reopened.acceptContinuityIngress(source: fixture.task.acceptance.source,
                    operationID: fixture.task.acceptance.operationID, policySelection: fixture.policy)
                XCTFail("A redelivery bypassed cancellation")
            } catch { XCTAssertEqual(error as? ContinuityOperationControlError, .cancellationRequested) }
            let held = try await reopened.pendingContinuityBootstrapRecoveries()
            XCTAssertTrue(held.references.isEmpty)
            let ordinary = try await reopened.nonterminalAutonomousRuns()
            XCTAssertTrue(ordinary.isEmpty)
            await reopened.close()
        }
    }

    func testRealStoreTombstonesBindTerminalReceiptAndIndependentTaskSurvives() async throws {
        try await withFixture { fixture in
            let peer = try await fixture.makeTask(id: "peer")
            _ = try await fixture.cancel()
            let page = try await fixture.repository.pendingContinuityOperationCancellations()
            let reference = try XCTUnwrap(page.references.first)
            let peerLease = try await fixture.repository.acquireRunLease(runID: peer.acceptance.runID, ownerID: "peer-owner")
            do {
                _ = try await fixture.repository.claimContinuityOperationCancellation(reference: reference, lease: peerLease)
                XCTFail("Another run's valid lease claimed the cancellation")
            } catch { XCTAssertEqual(error as? AutonomyError, .staleLease) }
            _ = try await fixture.repository.releaseRunLease(peerLease)
            let lease = try await fixture.repository.acquireContinuityOperationCancellationLease(reference: reference, ownerID: "cleanup-owner")
            let claim = try await fixture.repository.claimContinuityOperationCancellation(reference: reference, lease: lease)
            let receipt = try await fixture.complete(claim: claim, lease: lease)
            XCTAssertEqual(receipt.evidence.source.store, .sourceOutbox)
            XCTAssertEqual(receipt.evidence.canonical.store, .canonicalSource)
            let replay = try await fixture.complete(claim: claim, lease: lease)
            XCTAssertEqual(replay, receipt)
            let result = try await fixture.cancel()
            XCTAssertEqual(result.disposition, .alreadyTerminal)
            XCTAssertEqual(result.snapshot.terminalReceipt?.receiptSHA256, receipt.receiptSHA256)
            XCTAssertEqual(result.snapshot.state, .cancelled)
            XCTAssertEqual(try ControlSQLite.text(fixture.database, "SELECT attempts FROM continuity_operation_cancellations"), "1")
            XCTAssertEqual(try fixture.source.continuityHandoffRevision(identity: peer.acceptance.sourceIdentity,
                authorization: peer.acceptance.authorization), peer.acceptance.source)
            do {
                _ = try fixture.memory.continuityPrepareSourceBootstrap(acceptance: fixture.task.acceptance,
                    authorization: fixture.task.acceptance.authorization, bootstrapNonce: UUID())
                XCTFail("A pre-prepare cancellation tombstone was revived")
            } catch { XCTAssertEqual(error as? ContinuityIngressError, .invalidated) }
            _ = try await fixture.repository.releaseRunLease(lease)
            let reopened = try ProjectControlPlaneRepository(databaseURL: fixture.database)
            let retained = try await fixture.replacing(repository: reopened).cancel()
            XCTAssertEqual(retained.snapshot.terminalReceipt, result.snapshot.terminalReceipt)
            await reopened.close()
        }
    }

    func testUnknownOutcomeRetainsFenceAndAtLeast660SecondRetry() async throws {
        try await withFixture { fixture in
            _ = try await fixture.cancel()
            let page = try await fixture.repository.pendingContinuityOperationCancellations()
            let reference = try XCTUnwrap(page.references.first)
            let lease = try await fixture.repository.acquireContinuityOperationCancellationLease(reference: reference, ownerID: "uncertain-cleanup")
            _ = try await fixture.repository.claimContinuityOperationCancellation(reference: reference, lease: lease)
            let before = Date()
            try await fixture.repository.recordContinuityOperationCancellationFailure(reference: reference, lease: lease,
                failure: .providerOutcomeUnknown, retryAfter: 1)
            let status = try await fixture.status()
            XCTAssertEqual(status.state, .cancelRequested)
            XCTAssertEqual(status.recoveryState, .uncertain)
            XCTAssertNil(status.terminalReceipt)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(status.retryAt.flatMap(ISO8601.date(from:))).timeIntervalSince(before), 659)
            let deferred = try await fixture.repository.pendingContinuityOperationCancellations()
            XCTAssertTrue(deferred.references.isEmpty)
            XCTAssertEqual(try ControlSQLite.text(fixture.database, "SELECT attempts FROM continuity_operation_cancellations"), "1")
            XCTAssertEqual(try ControlSQLite.text(fixture.database, "SELECT state FROM autonomous_runs"), "awaiting_bootstrap")
            _ = try await fixture.repository.releaseRunLease(lease)
        }
    }

    func testCapabilityFiveMigrationRetainsAcceptanceAndVerifiedLineage() async throws {
        try await withFixture { fixture in
            await fixture.repository.close()
            try ControlSQLite.execute(fixture.database, "DROP TABLE continuity_operation_cancellations")
            let upgraded = try ProjectControlPlaneRepository(databaseURL: fixture.database)
            let status = try await fixture.replacing(repository: upgraded).status()
            XCTAssertEqual(status.acceptance, fixture.task.acceptance)
            XCTAssertEqual(try ControlSQLite.text(fixture.database, "SELECT state FROM continuity_ingress_holds"), "awaiting_bootstrap")
            let manifestURL = VerifiedMigrationBackup.activeManifestURL(for: fixture.database, scope: .continuityIngress)
            let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
            XCTAssertEqual(manifest?["source_version"] as? Int, 5)
            XCTAssertEqual(manifest?["target_version"] as? Int, 6)
            XCTAssertEqual(try ControlSQLite.text(fixture.database, "SELECT COUNT(*) FROM continuity_operation_cancellations"), "0")
            await upgraded.close()
            let reopened = try ProjectControlPlaneRepository(databaseURL: fixture.database)
            let replay = try await fixture.replacing(repository: reopened).status()
            XCTAssertEqual(replay.acceptance, fixture.task.acceptance)
            await reopened.close()
        }
    }

    private func withFixture(_ body: (ControlFixture) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("continuity-controls-\(UUID().uuidString)")
            .resolvingSymlinksInPath().standardizedFileURL
        let projectRoot = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let database = root.appendingPathComponent("control.sqlite3")
        let repository = try ProjectControlPlaneRepository(databaseURL: database)
        let source = try SQLiteStore(path: root.appendingPathComponent("source.sqlite3"))
        let projectID = ProjectID()
        let memory = try ProjectMemoryRepository(projectID: projectID.description, directory: root.appendingPathComponent("memory"), enableFTS5: false)
        do {
            _ = try await repository.registerProjectUnchecked(projectID: projectID, displayName: "Control fixture", canonicalRoot: projectRoot)
            let scope = ToolAuthorizationScope(canonicalRoots: [projectRoot], writableRoots: [], allowedTools: ["fs_read"],
                networkAllowed: false, maximumInlineOutputBytes: 65_536)
            let caller = try await repository.bind(owner: .init(kind: .mcpClient, id: "native-control-owner"),
                projectID: projectID, generation: .initial, authorizationScope: scope)
            let assignment = try ContinuityTaskAssignment(assignmentID: "approved-controls", assignmentBytes: Data("Read the fixture".utf8),
                mission: "Read the fixture", providerID: "lmstudio", adapterID: "forge.native-session-host", modelKey: "fixture/controls",
                specification: .init(allowedTools: ["fs_read"], completionGates: ["G04"]), authorizationScope: scope)
            let policy = try BudgetPolicyState(globalPolicy: BudgetPolicy(automaticHandoffEnabled: true)).resolve(
                .init(kind: .projectOverride, projectID: projectID.description, projectGeneration: 1))
            let task = try await ControlFixture.makeTask(repository: repository, source: source, caller: caller,
                projectID: projectID, assignment: assignment, policy: policy, id: "owned")
            try await body(.init(database: database, repository: repository, source: source, memory: memory,
                caller: caller, projectID: projectID, assignment: assignment, policy: policy, task: task))
            memory.close(); source.close(); await repository.close(); try FileManager.default.removeItem(at: root)
        } catch { memory.close(); source.close(); await repository.close(); try? FileManager.default.removeItem(at: root); throw error }
    }
}

private struct ControlTask: Sendable {
    let setup: AuthorizedContinuityTaskSetup
    let acceptance: ContinuityIngressAcceptanceReceipt
}
private struct ControlFixture: Sendable {
    let database: URL
    let repository: ProjectControlPlaneRepository
    let source: SQLiteStore
    let memory: ProjectMemoryRepository
    let caller: ProjectContextBinding
    let projectID: ProjectID
    let assignment: ContinuityTaskAssignment
    let policy: BudgetPolicySelection
    let task: ControlTask
    var context: ToolInvocationContext { caller.invocationContext(clientID: ClientID(caller.owner.id)) }
    func status(operation: UUID? = nil) async throws -> ContinuityOperationStatus {
        try await repository.continuityOperationStatus(operationID: operation ?? task.acceptance.operationID,
            taskID: task.setup.record.authorization.taskID, correlation: task.setup.correlation, context: context, owner: caller.owner)
    }
    func cancel(operation: UUID? = nil) async throws -> ContinuityOperationCancellationResult {
        try await repository.requestContinuityOperationCancellation(operationID: operation ?? task.acceptance.operationID,
            taskID: task.setup.record.authorization.taskID, correlation: task.setup.correlation, context: context, owner: caller.owner)
    }
    func complete(claim: ContinuityOperationCancellationClaim, lease: RunLease) async throws -> ContinuityOperationCancellationReceipt {
        try await repository.completeContinuityOperationCancellation(claim: claim, lease: lease) { request, acceptance in
            try .init(canonical: memory.continuityCancelSourceBootstrap(request: request, acceptance: acceptance),
                source: source.cancelContinuitySourceDelivery(request: request, acceptance: acceptance))
        }
    }
    func makeTask(id: String) async throws -> ControlTask {
        try await Self.makeTask(repository: repository, source: source, caller: caller, projectID: projectID,
            assignment: assignment, policy: policy, id: id)
    }
    static func makeTask(repository: ProjectControlPlaneRepository, source: SQLiteStore, caller: ProjectContextBinding,
        projectID: ProjectID, assignment: ContinuityTaskAssignment, policy: BudgetPolicySelection, id: String) async throws -> ControlTask {
        let setup = try await repository.authorizeContinuityTask(projectID: projectID, expectedGeneration: .initial,
            approvedAssignment: assignment, callerContext: caller.invocationContext(clientID: ClientID(caller.owner.id)), callerOwner: caller.owner)
        let handoff = try source.handoffCommit(HandoffPacket(id: id, source: .model, resumeReady: true, goal: "Read the fixture"),
            authorization: setup.record.authorization, automaticHandoffEnabled: true)
        let operation = try ContinuityIngressOperationIdentity(revision: handoff.revision)
        let acceptance = try await repository.acceptContinuityIngress(source: handoff.revision, operationID: operation.operationID, policySelection: policy)
        return .init(setup: setup, acceptance: acceptance)
    }
    func replacing(repository: ProjectControlPlaneRepository) -> Self {
        .init(database: database, repository: repository, source: source, memory: memory, caller: caller,
            projectID: projectID, assignment: assignment, policy: policy, task: task)
    }
}

private enum ControlSQLite {
    static func text(_ url: URL, _ sql: String, _ values: [String] = []) throws -> String {
        try query(url, sql, values, reading: true)
    }
    static func execute(_ url: URL, _ sql: String, _ values: [String] = []) throws {
        _ = try query(url, sql, values, reading: false)
    }
    private static func query(_ url: URL, _ sql: String, _ values: [String], reading: Bool) throws -> String {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let database else {
            throw ContinuityOperationControlError.integrityFailure
        }
        defer { sqlite3_close_v2(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw ContinuityOperationControlError.integrityFailure }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            guard sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) == SQLITE_OK else { throw ContinuityOperationControlError.integrityFailure }
        }
        let result = sqlite3_step(statement)
        guard result == (reading ? SQLITE_ROW : SQLITE_DONE) else { throw ContinuityOperationControlError.integrityFailure }
        return reading ? sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "" : ""
    }
}
