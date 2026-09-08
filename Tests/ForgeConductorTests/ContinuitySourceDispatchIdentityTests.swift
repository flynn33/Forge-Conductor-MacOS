import XCTest
import SQLite3
@testable import ForgeConductorCore

final class ContinuitySourceDispatchIdentityTests: XCTestCase {
    func testForeignActivationMetadataRejectsBeforeCorruptReceiptDecode() async throws {
        try await withFixture { fixture in
            let own = try await fixture.submit(setup: fixture.setup, caller: fixture.original)
            let otherSetup = try await fixture.repository.authorizeContinuityTask(
                projectID: fixture.projectID, expectedGeneration: .initial,
                approvedAssignment: fixture.setup.record.assignment,
                callerContext: fixture.original.invocationContext(clientID: ClientID(fixture.original.owner.id)),
                callerOwner: fixture.original.owner)
            let otherSource = try fixture.source.handoffCommit(HandoffPacket(id: "foreign-activation-source",
                source: .model, resumeReady: true, goal: "Other task's private progress"),
                authorization: otherSetup.record.authorization, automaticHandoffEnabled: false)
            let otherIdentity = try ContinuityIngressOperationIdentity(revision: otherSource.revision)
            let other = try await fixture.repository.acceptContinuityIngress(source: otherSource.revision,
                operationID: otherIdentity.operationID, policySelection: fixture.policy)
            XCTAssertNotEqual(own.acceptance.runID, other.runID)
            let ownLease = try await fixture.repository.acquireRunLease(runID: own.acceptance.runID,
                ownerID: "own-activation-reader")
            let otherLease = try await fixture.repository.acquireRunLease(runID: other.runID,
                ownerID: "foreign-activation-control")
            // Metadata describes a real different authorized task and run. The
            // invalid body makes a premature payload read observably different
            // from the required caller/operation ownership rejection.
            try SourceDispatchSQLite.execute(fixture.database, """
                INSERT INTO continuity_source_activations(operation_id,run_id,project_id,project_generation,
                    task_id,candidate_id,envelope_json,envelope_sha256,receipt_json,receipt_sha256)
                VALUES(?,?,?,1,?,?,?,?,?,?)
                """, [other.operationID.uuidString.lowercased(), other.runID.description,
                    other.authorization.projectID.description, other.authorization.taskID.uuidString.lowercased(),
                    UUID().uuidString.lowercased(), "{}", String(repeating: "0", count: 64),
                    "deliberately corrupt foreign receipt", String(repeating: "0", count: 64)])
            do {
                _ = try await fixture.repository.sourceActivationReceipt(runID: own.acceptance.runID,
                    operationID: other.operationID, lease: ownLease)
                XCTFail("A caller read another run's activation")
            } catch { XCTAssertEqual(error as? ContinuitySourceActivationError, .conflict) }
            do {
                _ = try await fixture.repository.sourceActivationReceipt(runID: other.runID,
                    operationID: other.operationID, lease: otherLease)
                XCTFail("The owning run accepted its corrupted activation receipt")
            } catch { XCTAssertEqual(error as? ContinuitySourceActivationError, .proofRequired) }
            _ = try await fixture.repository.releaseRunLease(ownLease)
            _ = try await fixture.repository.releaseRunLease(otherLease)
        }
    }

    func testEligibleOriginalCallerCannotReauthorizeTaskThroughWritablePeer() async throws {
        try await withFixture { fixture in
            let peer = try await fixture.caller(id: "writable-peer", writable: true)
            await expectIdentityGap {
                _ = try await fixture.reauthorize(caller: peer)
            }
            let replay = try await fixture.reauthorize(caller: fixture.original)
            XCTAssertEqual(replay.correlation.callerBindingID, fixture.setup.correlation.callerBindingID)
            let started = try await fixture.submit(setup: replay, caller: fixture.original)
            XCTAssertEqual(started.acceptance.authorization, fixture.setup.record.authorization)
            let retainedPeer = try await fixture.repository.binding(for: peer.owner)
            XCTAssertEqual(retainedPeer?.authorizationScope, fixture.writableScope)
            XCTAssertEqual(retainedPeer?.active, true)
        }
    }

    func testWritableOriginalCallerCannotAcquireEligibleOriginByReauthorizingThroughPeer() async throws {
        try await withFixture(originalWritable: true) { fixture in
            XCTAssertEqual(fixture.setup.record.authorization.authorizationScope, fixture.readOnlyScope,
                "A narrower approved assignment does not narrow the original transport's authority")
            let peer = try await fixture.caller(id: "eligible-peer", writable: false)
            await expectIdentityGap { _ = try await fixture.reauthorize(caller: peer) }
            await expectIdentityGap { _ = try await fixture.submit(setup: fixture.setup, caller: fixture.original) }
            XCTAssertEqual(try SourceDispatchSQLite.integer(fixture.database,
                "SELECT COUNT(*) FROM autonomous_runs"), 0)
            XCTAssertEqual(try SourceDispatchSQLite.integer(fixture.database,
                "SELECT COUNT(*) FROM continuity_source_dispatch_origins"), 1)
            XCTAssertEqual(try SourceDispatchSQLite.text(fixture.database,
                "SELECT caller_binding_id FROM continuity_source_dispatch_origins"),
                fixture.original.bindingID.uuidString.lowercased())
        }
    }

    func testExactEligibleCallerReauthorizationAndKeyedReplayRemainStable() async throws {
        try await withFixture { fixture in
            let repeated = try await fixture.reauthorize(caller: fixture.original)
            XCTAssertEqual(repeated.record, fixture.setup.record)
            XCTAssertEqual(repeated.correlation.callerBindingID, fixture.original.bindingID)
            let requestID = UUID()
            let first = try await fixture.submit(setup: repeated, caller: fixture.original, requestID: requestID)
            let again = try await fixture.submit(setup: fixture.setup, caller: fixture.original, requestID: requestID)
            XCTAssertEqual(first, again)
            XCTAssertEqual(try SourceDispatchSQLite.integer(fixture.database,
                "SELECT invalidated FROM continuity_source_dispatch_origins"), 0)
            XCTAssertEqual(try SourceDispatchSQLite.integer(fixture.database,
                "SELECT COUNT(*) FROM continuity_explicit_start_permits"), 1)
            XCTAssertEqual(try SourceDispatchSQLite.integer(fixture.database,
                "SELECT COUNT(*) FROM provider_sessions"), 0)
        }
    }

    func testCallerScopeChangeCannotRestoreOriginEligibilityByRestoringOldBytes() async throws {
        try await withFixture { fixture in
            let started = try await fixture.submit(setup: fixture.setup, caller: fixture.original)
            let originalScope = try SourceDispatchSQLite.text(fixture.database,
                "SELECT authorization_scope_json FROM project_bindings WHERE binding_id=?",
                [fixture.original.bindingID.uuidString.lowercased()])
            let writable = try await fixture.caller(id: "writable-scope-fixture", writable: true)
            let widenedScope = try SourceDispatchSQLite.text(fixture.database,
                "SELECT authorization_scope_json FROM project_bindings WHERE binding_id=?",
                [writable.bindingID.uuidString.lowercased()])
            // Exercise the storage trigger, including changes from another
            // connection. Public bind already rejects widening an active row.
            try SourceDispatchSQLite.execute(fixture.database,
                "UPDATE project_bindings SET authorization_scope_json=? WHERE binding_id=?",
                [widenedScope, fixture.original.bindingID.uuidString.lowercased()])
            await expectIdentityGap {
                _ = try await fixture.repository.validateContinuitySourceStartAuthority(
                    acceptance: started.acceptance, policySelection: fixture.policy)
            }
            try SourceDispatchSQLite.execute(fixture.database,
                "UPDATE project_bindings SET authorization_scope_json=? WHERE binding_id=?",
                [originalScope, fixture.original.bindingID.uuidString.lowercased()])
            XCTAssertEqual(try SourceDispatchSQLite.integer(fixture.database,
                "SELECT invalidated FROM continuity_source_dispatch_origins"), 1)
            await expectIdentityGap {
                _ = try await fixture.repository.validateContinuitySourceStartAuthority(
                    acceptance: started.acceptance, policySelection: fixture.policy)
            }
            await expectIdentityGap {
                _ = try await fixture.submit(setup: fixture.setup, caller: fixture.original)
            }
        }
    }

    func testCapabilityFourUpgradeDoesNotInventMissingOriginalCallerProof() async throws {
        try await withFixture { fixture in
            await fixture.repository.close()
            try SourceDispatchSQLite.restoreCapabilityFour(fixture.database)
            XCTAssertEqual(try SourceDispatchSQLite.integer(fixture.database,
                "SELECT COUNT(*) FROM sqlite_master WHERE name='continuity_source_dispatch_origins'"), 0)
            XCTAssertEqual(try SourceDispatchSQLite.integer(fixture.database,
                "SELECT COUNT(*) FROM pragma_table_info('continuity_ingress_holds') WHERE name='recovery_attempts'"), 1)
            XCTAssertEqual(try SourceDispatchSQLite.integer(fixture.database,
                "SELECT COUNT(*) FROM pragma_table_info('continuity_ingress_holds') WHERE name='finalization_attempts'"), 0)
            let reopened = try ProjectControlPlaneRepository(databaseURL: fixture.database)
            do {
                let backup = fixture.database.deletingPathExtension().appendingPathExtension("pre-ingress-capability-v4.sqlite3")
                XCTAssertEqual(try SourceDispatchSQLite.integer(backup,
                    "SELECT COUNT(*) FROM continuity_task_authorizations"), 1)
                XCTAssertEqual(try SourceDispatchSQLite.integer(backup,
                    "SELECT COUNT(*) FROM sqlite_master WHERE name='continuity_source_dispatch_origins'"), 0)
                let preserved = try await reopened.validateContinuityIngressAuthorization(fixture.setup.record.authorization)
                XCTAssertEqual(preserved, fixture.setup.record)
                let old = fixture.replacing(repository: reopened)
                await expectIdentityGap { _ = try await old.reauthorize(caller: old.original) }
                await expectIdentityGap { _ = try await old.submit(setup: old.setup, caller: old.original) }
                XCTAssertEqual(try SourceDispatchSQLite.integer(fixture.database,
                    "SELECT COUNT(*) FROM continuity_source_dispatch_origins"), 0)
                XCTAssertEqual(try SourceDispatchSQLite.integer(fixture.database,
                    "SELECT COUNT(*) FROM autonomous_runs"), 0)
                await reopened.close()
            } catch { await reopened.close(); throw error }
        }
    }

    private func expectIdentityGap(_ operation: () async throws -> Void,
                                  file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Unproven source origin gained dispatch authority", file: file, line: line) }
        catch { XCTAssertEqual(error as? ContinuitySourceActivationError, .taskIdentityUnavailable, file: file, line: line) }
    }

    private func withFixture(originalWritable: Bool = false,
                             _ body: (SourceDispatchFixture) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("source-dispatch-\(UUID().uuidString)")
            .resolvingSymlinksInPath().standardizedFileURL
        let projectRoot = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let database = root.appendingPathComponent("control.sqlite3")
        let repository = try ProjectControlPlaneRepository(databaseURL: database)
        let source = try SQLiteStore(path: root.appendingPathComponent("source.sqlite3"))
        do {
            let projectID = ProjectID()
            _ = try await repository.registerProjectUnchecked(projectID: projectID,
                displayName: "Source dispatch identity fixture", canonicalRoot: projectRoot)
            let readOnly = ToolAuthorizationScope(canonicalRoots: [projectRoot], writableRoots: [],
                allowedTools: ["fs_read"], networkAllowed: false, maximumInlineOutputBytes: 65_536)
            let writable = ToolAuthorizationScope(canonicalRoots: [projectRoot], writableRoots: [projectRoot],
                allowedTools: ["fs_read", "fs_write"], networkAllowed: false, maximumInlineOutputBytes: 65_536)
            let original = try await repository.bind(owner: .init(kind: .mcpClient, id: "original-caller"),
                projectID: projectID, generation: .initial, authorizationScope: originalWritable ? writable : readOnly)
            let assignment = try ContinuityTaskAssignment(assignmentID: "dispatch-approved-assignment",
                assignmentBytes: Data("Read approved source task".utf8), mission: "Read approved source task",
                providerID: "lmstudio", adapterID: "forge.native-session-host", modelKey: "fixture/source-dispatch",
                specification: .init(allowedTools: ["fs_read"], completionGates: ["G04"]), authorizationScope: readOnly)
            let setup = try await repository.authorizeContinuityTask(projectID: projectID, expectedGeneration: .initial,
                approvedAssignment: assignment,
                callerContext: original.invocationContext(clientID: ClientID(original.owner.id)), callerOwner: original.owner)
            let committed = try source.handoffCommit(HandoffPacket(id: "dispatch-origin-source", source: .model,
                resumeReady: true, goal: "Read approved source task"), authorization: setup.record.authorization,
                automaticHandoffEnabled: false)
            let policy = try BudgetPolicyState(globalPolicy: BudgetPolicy(automaticHandoffEnabled: false)).resolve(
                .init(kind: .projectOverride, projectID: projectID.description, projectGeneration: 1))
            try await body(.init(repository: repository, database: database, projectID: projectID, source: source,
                readOnlyScope: readOnly, writableScope: writable, original: original, setup: setup,
                revision: committed.revision, policy: policy))
            source.close(); await repository.close(); try FileManager.default.removeItem(at: root)
        } catch { source.close(); await repository.close(); try? FileManager.default.removeItem(at: root); throw error }
    }
}

private struct SourceDispatchFixture: Sendable {
    let repository: ProjectControlPlaneRepository
    let database: URL
    let projectID: ProjectID
    let source: SQLiteStore
    let readOnlyScope: ToolAuthorizationScope
    let writableScope: ToolAuthorizationScope
    let original: ProjectContextBinding
    let setup: AuthorizedContinuityTaskSetup
    let revision: ContinuityHandoffRevision
    let policy: BudgetPolicySelection

    func caller(id: String, writable: Bool) async throws -> ProjectContextBinding {
        try await repository.bind(owner: .init(kind: .mcpClient, id: id), projectID: projectID,
            generation: .initial, authorizationScope: writable ? writableScope : readOnlyScope)
    }

    func reauthorize(caller: ProjectContextBinding) async throws -> AuthorizedContinuityTaskSetup {
        try await repository.authorizeContinuityTask(taskID: setup.record.authorization.taskID,
            projectID: projectID, expectedGeneration: .initial, approvedAssignment: setup.record.assignment,
            callerContext: caller.invocationContext(clientID: ClientID(caller.owner.id)), callerOwner: caller.owner)
    }

    func submit(setup: AuthorizedContinuityTaskSetup, caller: ProjectContextBinding,
                requestID: UUID = UUID()) async throws -> ContinuityExplicitStartReceipt {
        try await repository.submitExplicitContinuityIngress(taskID: setup.record.authorization.taskID,
            correlation: setup.correlation, context: caller.invocationContext(clientID: ClientID(caller.owner.id)), owner: caller.owner,
            requestID: requestID, continuityID: revision.identity.continuityID, policySelection: policy) { authorization in
                try source.continuityHandoffRevision(identity: revision.identity, authorization: authorization)
            }
    }

    func replacing(repository: ProjectControlPlaneRepository) -> Self {
        .init(repository: repository, database: database, projectID: projectID, source: source,
            readOnlyScope: readOnlyScope, writableScope: writableScope, original: original,
            setup: setup, revision: revision, policy: policy)
    }
}

private enum SourceDispatchSQLite {
    static func integer(_ url: URL, _ sql: String) throws -> Int {
        guard let value = Int(try text(url, sql)) else { throw Failure.sqlite }
        return value
    }

    static func text(_ url: URL, _ sql: String, _ values: [String] = []) throws -> String {
        try connection(url, writable: false) { database in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw Failure.sqlite }
            defer { sqlite3_finalize(statement) }
            try bind(values, to: statement)
            guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { throw Failure.sqlite }
            return String(cString: text)
        }
    }

    static func execute(_ url: URL, _ sql: String, _ values: [String] = []) throws {
        try connection(url, writable: true) { database in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw Failure.sqlite }
            defer { sqlite3_finalize(statement) }
            try bind(values, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure.sqlite }
        }
    }

    static func restoreCapabilityFour(_ url: URL) throws {
        try connection(url, writable: true) { database in
            let sql = """
            BEGIN IMMEDIATE;
            DROP TRIGGER trg_continuity_source_origin_binding_update;
            DROP TRIGGER trg_continuity_source_origin_binding_delete;
            ALTER TABLE provider_turns DROP COLUMN source_preflight_sha256;
            ALTER TABLE provider_turns DROP COLUMN source_preflight_json;
            DROP TABLE IF EXISTS native_source_provider_run_offsets;
            DROP TABLE IF EXISTS native_source_provider_calls;
            DROP TABLE IF EXISTS native_source_capability_checks;
            DROP TABLE IF EXISTS native_source_provider_turns;
            DROP TABLE IF EXISTS native_source_conversations;
            DROP TABLE IF EXISTS native_source_run_offsets;
            DROP TABLE IF EXISTS native_source_requests;
            DROP TABLE IF EXISTS native_task_commands;
            DROP TABLE IF EXISTS native_task_capabilities;
            DROP TABLE continuity_operation_cancellations;
            DROP TABLE continuity_source_dispatch_origins;
            DROP TABLE continuity_source_task_fences;
            DROP TABLE continuity_explicit_start_permits;
            DROP TABLE continuity_explicit_start_requests;
            DROP TABLE continuity_source_activations;
            DROP TABLE continuity_ingress_holds;
            CREATE TABLE continuity_ingress_holds (
                operation_id TEXT PRIMARY KEY NOT NULL CHECK (length(operation_id)=36),
                run_id TEXT NOT NULL CHECK (length(run_id)=36),
                state TEXT NOT NULL CHECK (state IN ('awaiting_bootstrap','cancelled','activated')),
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                recovery_attempts INTEGER NOT NULL DEFAULT 0 CHECK (recovery_attempts BETWEEN 0 AND 8),
                recovery_started_at TEXT CHECK (length(CAST(recovery_started_at AS BLOB))<=128),
                recovery_deadline TEXT CHECK (length(CAST(recovery_deadline AS BLOB))<=128),
                recovery_retry_at TEXT CHECK (length(CAST(recovery_retry_at AS BLOB))<=128),
                recovery_claim_id TEXT CHECK (length(recovery_claim_id)=36),
                recovery_lease_owner TEXT CHECK (length(CAST(recovery_lease_owner AS BLOB)) BETWEEN 1 AND 512),
                recovery_lease_epoch INTEGER CHECK (recovery_lease_epoch>=1),
                recovery_error_code TEXT CHECK (length(CAST(recovery_error_code AS BLOB))<=64),
                recovery_quarantined INTEGER NOT NULL DEFAULT 0 CHECK (recovery_quarantined IN (0,1)),
                recovery_ack_sha256 TEXT CHECK (length(recovery_ack_sha256)=64)
            );
            CREATE UNIQUE INDEX idx_continuity_ingress_active_hold ON continuity_ingress_holds(run_id) WHERE state='awaiting_bootstrap';
            COMMIT;
            """
            guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
                _ = sqlite3_exec(database, "ROLLBACK;", nil, nil, nil)
                throw Failure.sqlite
            }
        }
    }

    private static func bind(_ values: [String], to statement: OpaquePointer) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            guard sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) == SQLITE_OK else { throw Failure.sqlite }
        }
    }

    private static func connection<T>(_ url: URL, writable: Bool, _ body: (OpaquePointer) throws -> T) throws -> T {
        var database: OpaquePointer?
        let flags = (writable ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY) | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK, let database else {
            if let database { sqlite3_close_v2(database) }
            throw Failure.sqlite
        }
        defer { sqlite3_close_v2(database) }
        sqlite3_busy_timeout(database, 2_000)
        return try body(database)
    }

    private enum Failure: Error { case sqlite }
}
