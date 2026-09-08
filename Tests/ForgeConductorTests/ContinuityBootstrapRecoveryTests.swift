// Durable held-operation scheduling, independent corruption handling and verified upgrades.

import XCTest
import SQLite3
@testable import ForgeConductorCore

final class ContinuityBootstrapRecoveryTests: XCTestCase {
    func testMetadataCursorQuarantinesMalformedRowAndAdvancesToIndependentPeer() async throws {
        try await withFixture(count: 2) { fixture in
            try RecoverySQLite.execute(fixture.database,
                "UPDATE continuity_ingress_acceptances SET receipt_sha256=? WHERE operation_id=?",
                [String(repeating: "a", count: 64) + "\0suffix", fixture.receipts[0].operationID.uuidString.lowercased()])
            let first = try await fixture.repository.pendingContinuityBootstrapRecoveries(limit: 1)
            XCTAssertTrue(first.references.isEmpty)
            XCTAssertEqual(first.diagnostics, [.init(rowID: fixture.references[0].rowID, failure: .integrityFailure)])
            XCTAssertEqual(first.nextRowID, fixture.references[0].rowID)
            let next = try await fixture.repository.pendingContinuityBootstrapRecoveries(afterRowID: first.nextRowID, limit: 1)
            XCTAssertEqual(next.references, [fixture.references[1]])
            let end = try await fixture.repository.pendingContinuityBootstrapRecoveries(afterRowID: next.nextRowID, limit: 1)
            XCTAssertNil(end.nextRowID)
            XCTAssertEqual(try RecoverySQLite.integer(fixture.database,
                "SELECT COUNT(*) FROM continuity_ingress_holds WHERE recovery_quarantined=1"), 1)
            XCTAssertEqual(try RecoverySQLite.integer(fixture.database, "SELECT SUM(recovery_attempts) FROM continuity_ingress_holds"), 0)
        }
    }

    func testLiveAuthorityAndLeasePrecedeReceiptDisclosureAndCorruptReceiptIsQuarantined() async throws {
        try await withFixture(count: 2) { fixture in
            for receipt in fixture.receipts {
                try RecoverySQLite.execute(fixture.database,
                    "UPDATE continuity_ingress_acceptances SET receipt_json='corrupt' WHERE operation_id=?",
                    [receipt.operationID.uuidString.lowercased()])
            }
            let first = fixture.references[0], second = fixture.references[1]
            _ = try await fixture.repository.revokeContinuityTask(taskID: first.taskID, projectID: first.projectID,
                expectedGeneration: first.projectGeneration)
            let firstLease = try await fixture.repository.acquireRunLease(runID: first.runID, ownerID: "revoked-fixture")
            do {
                _ = try await fixture.repository.claimContinuityBootstrapRecovery(reference: first, lease: firstLease,
                    policy: fixture.receipts[0].policySelection)
                XCTFail("Revoked task disclosed an acceptance")
            } catch { XCTAssertEqual(error as? ContinuityTaskAuthorizationError, .revoked) }
            XCTAssertEqual(try RecoverySQLite.integer(fixture.database,
                "SELECT SUM(recovery_quarantined) FROM continuity_ingress_holds"), 0)
            let secondLease = try await fixture.repository.acquireRunLease(runID: second.runID, ownerID: "authorized-fixture")
            do {
                _ = try await fixture.repository.claimContinuityBootstrapRecovery(reference: second, lease: secondLease,
                    policy: fixture.receipts[1].policySelection)
                XCTFail("Corrupt receipt was disclosed")
            } catch { XCTAssertEqual(error as? ContinuityBootstrapRecoveryError, .quarantined) }
            XCTAssertEqual(try RecoverySQLite.integer(fixture.database,
                "SELECT SUM(recovery_quarantined) FROM continuity_ingress_holds"), 1)
            XCTAssertEqual(try RecoverySQLite.integer(fixture.database, "SELECT SUM(recovery_attempts) FROM continuity_ingress_holds"), 0)
        }
    }

    func testPolicyDeferralAndCancellationPreserveHoldWithoutSpendingUnsubmittedAttempts() async throws {
        try await withFixture { fixture in
            let reference = fixture.references[0], receipt = fixture.receipts[0]
            let disabled = try BudgetPolicyState(globalPolicy: BudgetPolicy(automaticHandoffEnabled: false)).resolve(receipt.policySelection.scope)
            let admitted = try await fixture.repository.validateContinuityBootstrapRecovery(reference: reference, policy: disabled)
            XCTAssertFalse(admitted)
            let lease = try await fixture.repository.acquireRunLease(runID: reference.runID, ownerID: "policy-owner")
            do {
                _ = try await fixture.repository.claimContinuityBootstrapRecovery(reference: reference, lease: lease, policy: disabled)
                XCTFail("Disabled policy claimed work")
            } catch { XCTAssertEqual(error as? ContinuityBootstrapRecoveryError, .policyDeferred) }
            let cancellation = ToolCallCancellation(); cancellation.cancel()
            do {
                _ = try await fixture.repository.claimContinuityBootstrapRecovery(reference: reference, lease: lease,
                    policy: receipt.policySelection, cancellation: cancellation)
                XCTFail("Cancelled admission committed")
            } catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(try RecoverySQLite.integer(fixture.database, "SELECT recovery_attempts FROM continuity_ingress_holds"), 0)
            let claim = try await fixture.repository.claimContinuityBootstrapRecovery(reference: reference, lease: lease, policy: receipt.policySelection)
            try await fixture.repository.finishContinuityBootstrapRecovery(claim: claim, lease: lease, outcome: .deferredPolicy)
            XCTAssertEqual(try RecoverySQLite.integer(fixture.database, "SELECT recovery_attempts FROM continuity_ingress_holds"), 0)
            XCTAssertEqual(try RecoverySQLite.integer(fixture.database, "SELECT COUNT(recovery_deadline) FROM continuity_ingress_holds"), 0)
            fixture.clock.advance(30)
            let renewed = try await fixture.repository.acquireRunLease(runID: reference.runID, ownerID: "policy-owner")
            let second = try await fixture.repository.claimContinuityBootstrapRecovery(reference: reference, lease: renewed, policy: receipt.policySelection)
            try await fixture.repository.finishContinuityBootstrapRecovery(claim: second, lease: renewed, outcome: .cancelled)
            XCTAssertEqual(try RecoverySQLite.text(fixture.database, "SELECT recovery_retry_at FROM continuity_ingress_holds"),
                ISO8601.string(from: fixture.clock.now().addingTimeInterval(660)))
            let run = try await fixture.repository.autonomousRun(reference.runID)
            XCTAssertEqual(run?.state, .awaitingBootstrap)
            await reject { _ = try await fixture.repository.validateAutonomousRunExecutionAdmission(reference.runID) }
        }
    }

    func testTwoConnectionsAndRestartRetainClaimFenceAndExactAcceptance() async throws {
        try await withFixture { fixture in
            let reference = fixture.references[0], receipt = fixture.receipts[0]
            let lease = try await fixture.repository.acquireRunLease(runID: reference.runID, ownerID: "first-owner")
            let claim = try await fixture.repository.claimContinuityBootstrapRecovery(reference: reference, lease: lease,
                policy: receipt.policySelection)
            XCTAssertEqual(claim.acceptance, receipt)
            let second = try ProjectControlPlaneRepository(databaseURL: fixture.database, clock: fixture.clock)
            do {
                await reject { _ = try await second.acquireRunLease(runID: reference.runID, ownerID: "second-owner") }
                let hidden = try await second.pendingContinuityBootstrapRecoveries()
                XCTAssertTrue(hidden.references.isEmpty)
                await fixture.repository.close()
                fixture.clock.advance(659)
                let early = try await second.pendingContinuityBootstrapRecoveries()
                XCTAssertTrue(early.references.isEmpty, "An abandoned claim retains the provider unknown-outcome fence")
                fixture.clock.advance(1)
                let due = try await second.pendingContinuityBootstrapRecoveries()
                XCTAssertEqual(due.references, [reference])
                let nextLease = try await second.acquireRunLease(runID: reference.runID, ownerID: "second-owner")
                let next = try await second.claimContinuityBootstrapRecovery(reference: reference, lease: nextLease,
                    policy: receipt.policySelection)
                XCTAssertEqual(next.acceptance, receipt)
                XCTAssertEqual(next.attempt, 2)
                XCTAssertEqual(next.retryDeadline, claim.retryDeadline)
                XCTAssertNotEqual(next.claimID, claim.claimID)
                await reject { try await second.finishContinuityBootstrapRecovery(claim: claim, lease: lease, outcome: .deferredPolicy) }
                await second.close()
            } catch { await second.close(); throw error }
        }
    }

    func testRetryLimitsHonorKnownUnknownOutcomeDelayAndDoNotShortenRequiredFence() async throws {
        try await withFixture { fixture in
            let reference = fixture.references[0], receipt = fixture.receipts[0]
            for attempt in 1...ContinuityBootstrapRecoveryLimits.maximumAttempts {
                let lease = try await fixture.repository.acquireRunLease(runID: reference.runID, ownerID: "retry-owner")
                let claim = try await fixture.repository.claimContinuityBootstrapRecovery(reference: reference, lease: lease,
                    policy: receipt.policySelection)
                XCTAssertEqual(claim.attempt, attempt)
                try await fixture.repository.finishContinuityBootstrapRecovery(claim: claim, lease: lease,
                    outcome: .failed(.providerOutcomeUnknown, retryAfter: 660))
                _ = try await fixture.repository.releaseRunLease(lease)
                fixture.clock.advance(659)
                let early = try await fixture.repository.pendingContinuityBootstrapRecoveries()
                XCTAssertTrue(early.references.isEmpty)
                fixture.clock.advance(1)
            }
            let stopped = try await fixture.repository.pendingContinuityBootstrapRecoveries()
            XCTAssertTrue(stopped.references.isEmpty)
            let lease = try await fixture.repository.acquireRunLease(runID: reference.runID, ownerID: "retry-owner")
            do {
                _ = try await fixture.repository.claimContinuityBootstrapRecovery(reference: reference, lease: lease,
                    policy: receipt.policySelection)
                XCTFail("Retry bound was reset")
            } catch { XCTAssertEqual(error as? ContinuityBootstrapRecoveryError, .exhausted) }
        }
        try await withFixture { fixture in
            let reference = fixture.references[0], receipt = fixture.receipts[0]
            let lease = try await fixture.repository.acquireRunLease(runID: reference.runID, ownerID: "long-fence")
            let claim = try await fixture.repository.claimContinuityBootstrapRecovery(reference: reference, lease: lease,
                policy: receipt.policySelection)
            try await fixture.repository.finishContinuityBootstrapRecovery(claim: claim, lease: lease,
                outcome: .failed(.providerOutcomeUnknown, retryAfter: 3_601))
            XCTAssertEqual(try RecoverySQLite.text(fixture.database, "SELECT recovery_error_code FROM continuity_ingress_holds"),
                ContinuityBootstrapRecoveryFailure.retryWindowExceeded.rawValue)
            XCTAssertEqual(try RecoverySQLite.integer(fixture.database, "SELECT recovery_attempts FROM continuity_ingress_holds"), 8)
        }
    }

    func testPayloadOnlyAcknowledgementCannotSuppressHeldRecovery() async throws {
        try await withFixture { fixture in
            let reference = fixture.references[0], receipt = fixture.receipts[0]
            let lease = try await fixture.repository.acquireRunLease(runID: reference.runID, ownerID: "marker-owner")
            let claim = try await fixture.repository.claimContinuityBootstrapRecovery(reference: reference, lease: lease, policy: receipt.policySelection)
            let envelope = try ContinuitySourceBootstrapEnvelope(acceptance: receipt, bootstrapNonce: UUID())
            let timestamp = ISO8601.string(from: fixture.clock.now()), candidate = UUID(), sha = String(repeating: "a", count: 64)
            let checksum = try ContinuitySourceBootstrapOperation.checksum(envelope: envelope, state: .successorAcknowledged,
                attempt: 1, createdAt: timestamp, updatedAt: timestamp, successorSessionID: candidate,
                successorProviderResponseID: "fabricated-response", retrievalProofSHA256: sha, acknowledgementProofSHA256: sha)
            let injected = ContinuitySourceBootstrapOperation(envelope: envelope, state: .successorAcknowledged, attempt: 1,
                createdAt: timestamp, updatedAt: timestamp, stateChecksum: checksum, successorSessionID: candidate,
                successorProviderResponseID: "fabricated-response", retrievalProofSHA256: sha, acknowledgementProofSHA256: sha)
            await reject { try await fixture.repository.markContinuityBootstrapAcknowledged(claim: claim, lease: lease) { injected } }
            XCTAssertEqual(try RecoverySQLite.integer(fixture.database, "SELECT COUNT(recovery_ack_sha256) FROM continuity_ingress_holds"), 0)
            XCTAssertEqual(try RecoverySQLite.integer(fixture.database, "SELECT COUNT(*) FROM provider_sessions"), 0)
            await reject { _ = try await fixture.repository.validateAutonomousRunExecutionAdmission(reference.runID) }
        }
    }

    func testCapabilityThreeUpgradePreservesReceiptHistoryAndVerifiedBackupAndRejectsExtensions() async throws {
        for extended in [false, true] {
            try await withFixture { fixture in
                let receipt = fixture.receipts[0]
                await fixture.repository.close()
                try RecoverySQLite.installCapabilityThree(fixture.database, extended: extended)
                if extended {
                    do {
                        let unexpected = try ProjectControlPlaneRepository(databaseURL: fixture.database, clock: fixture.clock)
                        await unexpected.close(); XCTFail("Extended hold schema silently changed")
                    } catch { }
                    XCTAssertEqual(try RecoverySQLite.integer(fixture.database,
                        "SELECT COUNT(*) FROM pragma_table_info('continuity_ingress_holds') WHERE name='recovery_attempts'"), 0)
                    XCTAssertEqual(try RecoverySQLite.integer(fixture.database,
                        "SELECT COUNT(*) FROM pragma_table_info('continuity_ingress_holds') WHERE name='private_extension'"), 1)
                    return
                }
                let upgraded = try ProjectControlPlaneRepository(databaseURL: fixture.database, clock: fixture.clock)
                do {
                    let duplicate = try await upgraded.acceptContinuityIngress(source: receipt.source,
                        operationID: receipt.operationID, policySelection: receipt.policySelection)
                    XCTAssertEqual(duplicate, receipt)
                    let page = try await upgraded.pendingContinuityBootstrapRecoveries()
                    XCTAssertEqual(page.references, fixture.references)
                    let url = VerifiedMigrationBackup.activeManifestURL(for: fixture.database, scope: .continuityIngress)
                    let manifest = try JSONDecoder().decode(VerifiedMigrationBackupManifest.self, from: Data(contentsOf: url))
                    XCTAssertEqual(manifest.sourceVersion, 6); XCTAssertEqual(manifest.targetVersion, 7)
                    XCTAssertEqual(manifest.state, .completed)
                    let backup = fixture.database.deletingLastPathComponent().appendingPathComponent(manifest.backupFilename)
                    XCTAssertEqual(JSONSupport.sha256Hex(try Data(contentsOf: backup)), manifest.backupSHA256)
                    XCTAssertEqual(try RecoverySQLite.integer(backup,
                        "SELECT COUNT(*) FROM pragma_table_info('continuity_ingress_holds') WHERE name='finalization_attempts'"), 1)
                    XCTAssertEqual(try RecoverySQLite.integer(backup,
                        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='native_task_capabilities'"), 0)
                    let beforeCancellation = fixture.database.deletingPathExtension().appendingPathExtension("pre-ingress-capability-v5.sqlite3")
                    XCTAssertEqual(try RecoverySQLite.integer(beforeCancellation,
                        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='continuity_operation_cancellations'"), 0)
                    let beforeActivation = fixture.database.deletingPathExtension().appendingPathExtension("pre-ingress-capability-v4.sqlite3")
                    XCTAssertEqual(try RecoverySQLite.integer(beforeActivation,
                        "SELECT COUNT(*) FROM pragma_table_info('continuity_ingress_holds') WHERE name='finalization_attempts'"), 0)
                    let original = fixture.database.deletingPathExtension().appendingPathExtension("pre-ingress-capability-v3.sqlite3")
                    XCTAssertEqual(try RecoverySQLite.integer(original,
                        "SELECT COUNT(*) FROM pragma_table_info('continuity_ingress_holds') WHERE name='recovery_attempts'"), 0)
                    XCTAssertEqual(try RecoverySQLite.text(backup, "SELECT receipt_json FROM continuity_ingress_acceptances"),
                        String(decoding: receipt.canonicalReceiptJSON, as: UTF8.self))
                    XCTAssertEqual(try RecoverySQLite.integer(fixture.database, "SELECT COUNT(*) FROM pragma_foreign_key_check"), 0)
                    await upgraded.close()
                    let reopened = try ProjectControlPlaneRepository(databaseURL: fixture.database, clock: fixture.clock)
                    XCTAssertEqual(try RecoverySQLite.integer(fixture.database, "SELECT COUNT(*) FROM forge_migration_receipts"), 4)
                    await reopened.close()
                } catch { await upgraded.close(); throw error }
            }
        }
    }

    private func reject(_ body: () async throws -> Void) async {
        do { try await body(); XCTFail("Expected fenced recovery rejection") } catch { }
    }

    private func withFixture(count: Int = 1, _ body: (RecoveryFixture) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bootstrap-recovery-\(UUID().uuidString)")
            .resolvingSymlinksInPath().standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = root.appendingPathComponent("control.sqlite3"), clock = RecoveryClock()
        let repository = try ProjectControlPlaneRepository(databaseURL: database, clock: clock)
        let source = try SQLiteStore(path: root.appendingPathComponent("source.sqlite3"))
        do {
            let projectRoot = root.appendingPathComponent("project")
            try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
            let projectID = ProjectID()
            _ = try await repository.registerProjectUnchecked(projectID: projectID, displayName: "Recovery fixture", canonicalRoot: projectRoot)
            let client = ClientID("fixture-transport"), owner = ProjectBindingOwner(kind: .mcpClient, id: "fixture-transport")
            let scope = ToolAuthorizationScope(canonicalRoots: [projectRoot], writableRoots: [], allowedTools: ["context_get"],
                networkAllowed: false, maximumInlineOutputBytes: 65_536)
            let binding = try await repository.bind(owner: owner, projectID: projectID, generation: .initial, authorizationScope: scope)
            var receipts: [ContinuityIngressAcceptanceReceipt] = []
            for index in 0..<count {
                let assignment = try ContinuityTaskAssignment(assignmentID: "approved-\(index)", assignmentBytes: Data("Approved scope".utf8),
                    mission: "Continue assigned work", providerID: "lmstudio", adapterID: "forge.native-session-host", modelKey: "fixture/model",
                    specification: AutonomousRunSpecification(allowedTools: ["context_get"], completionGates: ["fixture"]), authorizationScope: scope)
                let setup = try await repository.authorizeContinuityTask(projectID: projectID, expectedGeneration: .initial,
                    approvedAssignment: assignment, callerContext: binding.invocationContext(clientID: client), callerOwner: owner)
                let commit = try source.handoffCommit(HandoffPacket(resumeReady: true, goal: "Actual source progress"),
                    authorization: setup.record.authorization, automaticHandoffEnabled: true)
                let policy = try BudgetPolicyState(globalPolicy: BudgetPolicy(automaticHandoffEnabled: true)).resolve(
                    BudgetPolicyScope(kind: .projectOverride, projectID: projectID.description, projectGeneration: 1))
                receipts.append(try await repository.acceptContinuityIngress(source: commit.revision,
                    operationID: XCTUnwrap(commit.delivery?.operationID), policySelection: policy))
            }
            let page = try await repository.pendingContinuityBootstrapRecoveries()
            XCTAssertEqual(page.references.count, count)
            try await body(.init(database: database, repository: repository, receipts: receipts, references: page.references, clock: clock))
        } catch {
            await repository.close(); source.close(); try? FileManager.default.removeItem(at: root); throw error
        }
        await repository.close(); source.close(); try? FileManager.default.removeItem(at: root)
    }
}

private struct RecoveryFixture: Sendable {
    let database: URL
    let repository: ProjectControlPlaneRepository
    let receipts: [ContinuityIngressAcceptanceReceipt]
    let references: [ContinuityBootstrapRecoveryReference]
    let clock: RecoveryClock
}

private final class RecoveryClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); value.addTimeInterval(seconds); lock.unlock() }
}

private enum RecoverySQLite {
    static func database<T>(_ url: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close_v2(db) }; throw ContinuityIngressError.integrityFailure("fixture open")
        }
        defer { sqlite3_close_v2(db) }
        return try body(db)
    }
    static func execute(_ url: URL, _ sql: String, _ values: [String] = []) throws {
        try database(url) { db in
            if values.isEmpty {
                guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                    throw ContinuityIngressError.integrityFailure(String(cString: sqlite3_errmsg(db)))
                }
                return
            }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw ContinuityIngressError.integrityFailure("fixture prepare")
            }
            defer { sqlite3_finalize(statement) }
            for (index, value) in values.enumerated() {
                value.withCString { pointer in
                    _ = sqlite3_bind_text(statement, Int32(index + 1), pointer, Int32(value.utf8.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            }
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw ContinuityIngressError.integrityFailure(String(cString: sqlite3_errmsg(db)))
            }
        }
    }
    static func text(_ url: URL, _ sql: String) throws -> String? {
        try database(url) { db in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw ContinuityIngressError.integrityFailure("fixture prepare")
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw ContinuityIngressError.integrityFailure("fixture row") }
            return sqlite3_column_text(statement, 0).map { String(cString: $0) }
        }
    }
    static func integer(_ url: URL, _ sql: String) throws -> Int { Int(try text(url, sql) ?? "") ?? 0 }
    static func installCapabilityThree(_ url: URL, extended: Bool) throws {
        try execute(url, """
            BEGIN IMMEDIATE;
            DROP TRIGGER IF EXISTS trg_continuity_source_origin_binding_update;
            DROP TRIGGER IF EXISTS trg_continuity_source_origin_binding_delete;
            DROP TABLE IF EXISTS native_source_run_offsets;
            DROP TABLE IF EXISTS native_source_requests;
            DROP TABLE IF EXISTS native_task_commands;
            DROP TABLE IF EXISTS native_task_capabilities;
            DROP TABLE IF EXISTS continuity_operation_cancellations;
            DROP TABLE IF EXISTS continuity_source_dispatch_origins;
            DROP TABLE IF EXISTS continuity_source_task_fences;
            DROP TABLE IF EXISTS continuity_explicit_start_requests;
            DROP TABLE IF EXISTS continuity_explicit_start_permits;
            DROP TABLE IF EXISTS continuity_source_activations;
            DROP INDEX idx_continuity_ingress_active_hold;
            ALTER TABLE continuity_ingress_holds RENAME TO fixture_holds;
            CREATE TABLE continuity_ingress_holds (
                operation_id TEXT PRIMARY KEY NOT NULL CHECK (length(operation_id)=36),
                run_id TEXT NOT NULL CHECK (length(run_id)=36),
                state TEXT NOT NULL CHECK (state IN ('awaiting_bootstrap','cancelled','activated')),
                created_at TEXT NOT NULL, updated_at TEXT NOT NULL
            );
            CREATE UNIQUE INDEX idx_continuity_ingress_active_hold ON continuity_ingress_holds(run_id) WHERE state='awaiting_bootstrap';
            INSERT INTO continuity_ingress_holds(rowid,operation_id,run_id,state,created_at,updated_at)
                SELECT rowid,operation_id,run_id,state,created_at,updated_at FROM fixture_holds;
            DROP TABLE fixture_holds;
            COMMIT;
            """)
        if extended { try execute(url, "ALTER TABLE continuity_ingress_holds ADD COLUMN private_extension TEXT;") }
    }
}
