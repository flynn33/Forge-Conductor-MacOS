// ContinuityIngressAcceptanceTests.swift
// Exercises actual source commits, manager transactions, recovery and holds.

import XCTest
import SQLite3
@testable import ForgeConductorCore

final class ContinuityIngressAcceptanceTests: XCTestCase {
    func testNewAndDuplicateAcceptanceUseFullDurabilityAndRestorePriorMode() async throws {
        try await withFixture { fixture in
            let observed = AcceptanceSynchronousProbe()
            await fixture.repository.configureOperationObservers(beforeCommitSynchronous: { observed.record($0) })
            let first = try await fixture.accept()
            let repeated = try await fixture.accept()
            _ = try await fixture.repository.validateContinuityIngressAuthorization(fixture.setup.record.authorization)
            XCTAssertEqual(first, repeated)
            XCTAssertEqual(observed.values, [2, 2, 1], "FULL must cover both acceptance paths and then restore NORMAL")
            let cancelled = ToolCallCancellation()
            await fixture.repository.configureOperationObservers(beforeCommit: { cancelled.cancel() })
            do {
                _ = try await fixture.repository.acceptContinuityIngress(source: fixture.commit.revision,
                    operationID: fixture.operationID, policySelection: fixture.policy, cancellation: cancelled)
                XCTFail("Expected cancelled duplicate transaction")
            } catch { XCTAssertTrue(error is CancellationError) }
            await fixture.repository.configureOperationObservers(beforeCommitSynchronous: { observed.record($0) })
            _ = try await fixture.repository.validateContinuityIngressAuthorization(fixture.setup.record.authorization)
            XCTAssertEqual(observed.values, [2, 2, 1, 1], "Rollback must restore the prior synchronous mode too")
            await fixture.repository.configureOperationObservers()
        }
    }

    func testFullAcceptanceWriterContentionPreservesCancellationAndDeadlineErrors() async throws {
        try await withFixture { fixture in
            let writer = try AcceptanceWriteLock(fixture.database)
            defer { writer.release() }
            let busy = AcceptanceSynchronousProbe()
            let cancelled = ToolCallCancellation()
            await fixture.repository.configureOperationObservers(busyRetry: {
                busy.record(1)
                cancelled.cancel()
            })
            do {
                _ = try await fixture.repository.acceptContinuityIngress(source: fixture.commit.revision,
                    operationID: fixture.operationID, policySelection: fixture.policy, cancellation: cancelled)
                XCTFail("Expected cancellation while BEGIN waits for the writer")
            } catch { XCTAssertTrue(error is CancellationError, "Unexpected: \(error)") }
            await fixture.repository.configureOperationObservers(busyRetry: { busy.record(2) })
            let deadline = ToolCallCancellation(timeoutSeconds: 0.05)
            do {
                _ = try await fixture.repository.acceptContinuityIngress(source: fixture.commit.revision,
                    operationID: fixture.operationID, policySelection: fixture.policy, cancellation: deadline)
                XCTFail("Expected the request deadline while BEGIN waits for the writer")
            } catch { XCTAssertTrue(error is ToolCallDeadlineExceeded, "Unexpected: \(error)") }
            XCTAssertEqual(busy.values, [1, 2], "Both requests must reach actual SQLite writer contention")
            writer.release()
            for table in ["autonomous_runs", "continuity_ingress_acceptances", "continuity_ingress_holds"] {
                XCTAssertEqual(try AcceptanceSQLite.integer(fixture.database, "SELECT COUNT(*) FROM \(table)"), 0)
            }
            let synchronous = AcceptanceSynchronousProbe()
            await fixture.repository.configureOperationObservers(beforeCommitSynchronous: { synchronous.record($0) })
            _ = try await fixture.repository.validateContinuityIngressAuthorization(fixture.setup.record.authorization)
            XCTAssertEqual(synchronous.values, [1], "Failed BEGIN must restore the connection's NORMAL mode")
            await fixture.repository.configureOperationObservers()
            _ = try await fixture.accept()
        }
    }

    func testConcurrentDeliveryAndRestartReturnOneImmutableAcceptanceAndRun() async throws {
        try await withFixture { fixture in
            let other = try ProjectControlPlaneRepository(databaseURL: fixture.database)
            do {
                async let first = fixture.accept()
                async let second = other.acceptContinuityIngress(source: fixture.commit.revision,
                    operationID: fixture.operationID, policySelection: fixture.policy)
                let (a, b) = try await (first, second)
                XCTAssertEqual(a, b)
                XCTAssertEqual(a.sourceIdentity, fixture.commit.revision.identity)
                XCTAssertEqual(a.authorization, fixture.setup.record.authorization)
                XCTAssertEqual(a.receiptSHA256, JSONSupport.sha256Hex(a.canonicalReceiptJSON))
                XCTAssertEqual(try AcceptanceSQLite.integer(fixture.database, "SELECT COUNT(*) FROM autonomous_runs"), 1)
                XCTAssertEqual(try AcceptanceSQLite.integer(fixture.database, "SELECT COUNT(*) FROM continuity_ingress_acceptances"), 1)
                let runSnapshot = try await other.autonomousRun(a.runID)
                let run = try XCTUnwrap(runSnapshot)
                XCTAssertEqual(run.state, .awaitingBootstrap)
                XCTAssertFalse(run.state.isExecutable)
                XCTAssertEqual(run.mission, fixture.setup.record.assignment.mission)
                XCTAssertNotEqual(run.mission, "Untrusted handoff progress")
                XCTAssertEqual(run.adapterID, fixture.setup.record.assignment.adapterID)
                XCTAssertNil(fixture.setup.record.assignment.specification.work.metadata["adapter_id"])
                XCTAssertNil(run.activeSessionID)
                XCTAssertEqual(try AcceptanceSQLite.integer(fixture.database, "SELECT COUNT(*) FROM provider_sessions"), 0)
                XCTAssertEqual(try AcceptanceSQLite.integer(fixture.database, "SELECT COUNT(*) FROM context_budget_observations"), 0)
                // Assignment lineage survives materialization, while the exact
                // original source has already transferred its mutation authority.
                let task = try await fixture.repository.validateContinuityIngressAuthorization(a.authorization)
                XCTAssertEqual(task.authorization.taskID, a.authorization.taskID)
                do {
                    _ = try await fixture.repository.withAuthorizedContinuityTask(
                        taskID: a.authorization.taskID, correlation: fixture.setup.correlation,
                        context: fixture.context, owner: fixture.owner) { $0.taskID }
                    XCTFail("Accepted source task retained mutation authority")
                } catch {
                    XCTAssertEqual(error as? ContinuitySourceActivationError, .sourceFenced)
                }
                await other.close()
                await fixture.repository.close()
                let reopened = try ProjectControlPlaneRepository(databaseURL: fixture.database)
                let changedPolicy = try BudgetPolicyState(globalRevision: 2,
                    globalPolicy: BudgetPolicy(automaticHandoffEnabled: false)).resolve(fixture.policy.scope)
                let repeated = try await reopened.acceptContinuityIngress(source: fixture.commit.revision,
                    operationID: fixture.operationID, policySelection: changedPolicy)
                XCTAssertEqual(repeated, a, "Redelivery preserves acceptance provenance, not a new execution grant")
                await expectHeld(a.runID) { _ = try await reopened.validateAutonomousRunExecutionAdmission(a.runID) }
                await reopened.close()
            } catch {
                await other.close()
                throw error
            }
        }
    }

    func testLiveAuthorityPrecedesDuplicateDisclosureAndCorruptReceiptRead() async throws {
        try await withFixture { fixture in
            let accepted = try await fixture.accept()
            try AcceptanceSQLite.execute(fixture.database,
                "UPDATE continuity_ingress_acceptances SET receipt_json='corrupt' WHERE operation_id=?",
                [fixture.operationID.uuidString.lowercased()])
            _ = try await fixture.repository.revokeContinuityTask(taskID: accepted.authorization.taskID,
                projectID: fixture.projectID, expectedGeneration: .initial)
            do {
                _ = try await fixture.accept()
                XCTFail("Revoked caller learned the stored duplicate")
            } catch let error as ContinuityTaskAuthorizationError {
                XCTAssertEqual(error, .revoked)
            }
        }
    }

    func testPacketOperationAndStoredReceiptTamperingFailClosed() async throws {
        try await withFixture { fixture in
            let original = fixture.commit.revision
            let changed = ContinuityHandoffRevision(identity: original.identity, authorization: original.authorization,
                canonicalPacketJSON: Data("{}".utf8), resumeReady: true, committedAt: original.committedAt)
            await expectFailure {
                _ = try await fixture.repository.acceptContinuityIngress(source: changed,
                    operationID: fixture.operationID, policySelection: fixture.policy)
            }
            await expectFailure {
                _ = try await fixture.repository.acceptContinuityIngress(source: original,
                    operationID: UUID(), policySelection: fixture.policy)
            }
            XCTAssertEqual(try AcceptanceSQLite.integer(fixture.database, "SELECT COUNT(*) FROM autonomous_runs"), 0)
            let receipt = try await fixture.accept()
            try AcceptanceSQLite.execute(fixture.database,
                "UPDATE continuity_ingress_acceptances SET receipt_json=receipt_json || char(0) || 'suffix' WHERE operation_id=?",
                [fixture.operationID.uuidString.lowercased()])
            await expectFailure { _ = try await fixture.accept() }
            XCTAssertEqual(try AcceptanceSQLite.integer(fixture.database, "SELECT COUNT(*) FROM autonomous_runs"), 1)
            XCTAssertEqual(receipt.operationID, fixture.operationID)
        }
    }

    func testCancellationRollsBackAllAdmissionRowsAndPostcommitRetryIsStable() async throws {
        try await withFixture { fixture in
            let cancellation = ToolCallCancellation()
            await fixture.repository.configureOperationObservers(beforeCommit: { cancellation.cancel() })
            do {
                _ = try await fixture.repository.acceptContinuityIngress(source: fixture.commit.revision,
                    operationID: fixture.operationID, policySelection: fixture.policy, cancellation: cancellation)
                XCTFail("Expected cancellation before acceptance commit")
            } catch { XCTAssertTrue(error is CancellationError, "Unexpected: \(error)") }
            await fixture.repository.configureOperationObservers()
            for table in ["autonomous_runs", "continuity_ingress_acceptances", "continuity_ingress_holds"] {
                XCTAssertEqual(try AcceptanceSQLite.integer(fixture.database, "SELECT COUNT(*) FROM \(table)"), 0)
            }
            let restored = try await fixture.repository.validateContinuityIngressAuthorization(fixture.setup.record.authorization)
            XCTAssertNil(restored.runID)
            let afterCommit = ToolCallCancellation()
            await fixture.repository.configureOperationObservers(didCommit: { afterCommit.cancel() })
            let committed = try await fixture.repository.acceptContinuityIngress(source: fixture.commit.revision,
                operationID: fixture.operationID, policySelection: fixture.policy, cancellation: afterCommit)
            await fixture.repository.configureOperationObservers()
            XCTAssertTrue(afterCommit.isCancelled)
            let retry = try await fixture.accept()
            XCTAssertEqual(retry, committed)
        }
    }

    func testDurableHoldRejectsGenericDispatchAndResumeButCancellationRemainsIrrevocable() async throws {
        try await withFixture { fixture in
            let receipt = try await fixture.accept()
            let runID = receipt.runID
            let lease = try await fixture.repository.acquireRunLease(runID: runID, ownerID: "hold-test")
            await expectHeld(runID) { _ = try await fixture.repository.validateAutonomousRunExecutionAdmission(runID) }
            await expectHeld(runID) {
                _ = try await fixture.repository.persistRunSideEffectIntent(runID: runID, lease: lease, expectedRevision: 0,
                    intent: RunSideEffectIntent(kind: .providerTurn, idempotencyKey: "forbidden-intent",
                        payloadSHA256: String(repeating: "a", count: 64), summary: "Forbidden while held"))
            }
            await expectHeld(runID) {
                try await fixture.repository.reserveProviderSession(fixture.providerIntent(runID: runID), lease: lease)
            }
            let turn = ProviderTurnIntent(runID: runID, sessionID: "fixture-session", projectID: fixture.projectID,
                projectGeneration: .initial, kind: .initialRoot, idempotencyKey: "forbidden-turn",
                inputSHA256: String(repeating: "a", count: 64))
            await expectHeld(runID) { _ = try await fixture.repository.persistProviderTurnIntent(turn, lease: lease) }
            await expectHeld(runID) {
                _ = try await fixture.repository.persistToolInvocationIntent(ToolInvocationIntent(turnID: turn.turnID,
                    runID: runID, sessionID: "fixture-session", projectID: fixture.projectID, projectGeneration: .initial,
                    providerCallID: "forbidden-tool", toolName: "fs_read", replayClass: .readOnly,
                    idempotencyKey: nil, argumentsSHA256: String(repeating: "a", count: 64)), lease: lease)
            }
            // Simulate a stale generic control writer restoring a normally
            // resumable state. The independent hold still prevents dispatch.
            try AcceptanceSQLite.execute(fixture.database, "UPDATE autonomous_runs SET state='paused' WHERE run_id=?", [runID.description])
            let pausedSnapshot = try await fixture.repository.autonomousRun(runID)
            let paused = try XCTUnwrap(pausedSnapshot)
            await expectHeld(runID) {
                _ = try await fixture.repository.transitionAutonomousRun(runID: runID, lease: lease,
                    transition: .init(expectedState: .paused, expectedRevision: paused.revision,
                        nextState: .validating, eventType: "resume", eventSummary: "Forbidden resume"))
            }
            let stopping = try await fixture.repository.transitionAutonomousRun(runID: runID, lease: lease,
                transition: .init(expectedState: .paused, expectedRevision: paused.revision,
                    nextState: .cancelRequested, eventType: "cancel", eventSummary: "Cancel held work"))
            let cancelled = try await fixture.repository.transitionAutonomousRun(runID: runID, lease: lease,
                transition: .init(expectedState: .cancelRequested, expectedRevision: stopping.revision,
                    nextState: .cancelled, eventType: "cancelled", eventSummary: "Held work cancelled"))
            XCTAssertEqual(cancelled.state, .cancelled)
            await expectHeld(runID) { _ = try await fixture.repository.validateAutonomousRunExecutionAdmission(runID) }
            await expectFailure { _ = try await fixture.accept() }
            XCTAssertEqual(try AcceptanceSQLite.integer(fixture.database, "SELECT COUNT(*) FROM autonomous_runs"), 1)
            XCTAssertEqual(try AcceptanceSQLite.integer(fixture.database, "SELECT COUNT(*) FROM provider_sessions"), 0)
        }
    }

    func testExistingTaskRunRetainsAdvancedWorkScopeAndSpentToolRows() async throws {
        try await withFixture { fixture in
            let request = fixture.runRequest()
            var run = try await fixture.repository.createAutonomousRun(request)
            let lease = try await fixture.repository.acquireRunLease(runID: run.runID, ownerID: "existing-run")
            for state in [AutonomousRunState.validating, .ready, .starting, .running] {
                run = try await fixture.repository.transitionAutonomousRun(runID: run.runID, lease: lease,
                    transition: .init(expectedState: run.state, expectedRevision: run.revision, nextState: state,
                        eventType: "fixture_progress", eventSummary: "Advance existing task"))
            }
            try await fixture.repository.reserveProviderSession(fixture.providerIntent(runID: run.runID), lease: lease)
            let turn = try await fixture.repository.persistProviderTurnIntent(ProviderTurnIntent(runID: run.runID,
                sessionID: "fixture-session", projectID: fixture.projectID, projectGeneration: .initial,
                kind: .normalContinuation, idempotencyKey: "spent-turn", inputSHA256: String(repeating: "a", count: 64)), lease: lease)
            let spent = try await fixture.repository.persistToolInvocationIntent(ToolInvocationIntent(turnID: turn.intent.turnID,
                runID: run.runID, sessionID: "fixture-session", projectID: fixture.projectID, projectGeneration: .initial,
                providerCallID: "spent-call", toolName: "fs_read", replayClass: .readOnly,
                idempotencyKey: nil, argumentsSHA256: String(repeating: "a", count: 64)), lease: lease)
            let activeSnapshot = try await fixture.repository.autonomousRun(run.runID)
            run = try XCTUnwrap(activeSnapshot)
            var advanced = run.specification.work
            advanced.currentPhase = "later-phase"
            advanced.nextAction = "Continue from already completed work"
            advanced.evidenceReferences = ["existing-evidence"]
            run = try await fixture.repository.transitionAutonomousRun(runID: run.runID, lease: lease,
                transition: .init(expectedState: .running, expectedRevision: run.revision, nextState: .running,
                    eventType: "advanced_work", eventSummary: "Retain later work", work: advanced))
            // This fixture represents an already manager-linked native task.
            // Production admission creates this same link only once by CAS.
            try AcceptanceSQLite.execute(fixture.database,
                "UPDATE continuity_task_authorizations SET run_id=? WHERE task_id=?",
                [run.runID.description, fixture.setup.record.authorization.taskID.uuidString.lowercased()])
            try AcceptanceSQLite.execute(fixture.database, "UPDATE project_bindings SET run_id=? WHERE binding_id=?",
                [run.runID.description, fixture.setup.record.authorization.sourceBindingID.uuidString.lowercased()])
            let receipt = try await fixture.accept()
            let heldSnapshot = try await fixture.repository.autonomousRun(receipt.runID)
            let held = try XCTUnwrap(heldSnapshot)
            XCTAssertEqual(receipt.runID, run.runID)
            XCTAssertEqual(held.specification, run.specification)
            XCTAssertEqual(held.activeSessionID, run.activeSessionID)
            XCTAssertEqual(held.state, .awaitingBootstrap)
            let retained = try await fixture.repository.toolInvocation(spent.invocationID)
            XCTAssertEqual(retained, spent, "Run-wide reserved tool calls must survive ingress")
            let binding = try await fixture.repository.binding(for: .init(kind: .autonomousRun, id: run.runID.description))
            XCTAssertEqual(binding?.authorizationScope, request.authorizationScope)
        }
    }

    func testOldVersionTwoMigrationRetainsRunsBindingsAndForeignKeysWithVerifiedBackup() async throws {
        try await withFixture { fixture in
            let request = fixture.runRequest()
            let run = try await fixture.repository.createAutonomousRun(request)
            let lease = try await fixture.repository.acquireRunLease(runID: run.runID, ownerID: "migration-owner")
            await fixture.repository.close()
            try AcceptanceSQLite.installLegacyRunConstraint(fixture.database)
            let oldRunJSON = try AcceptanceSQLite.text(fixture.database, "SELECT current_work_json FROM autonomous_runs")
            let reopened = try ProjectControlPlaneRepository(databaseURL: fixture.database)
            let restored = try await reopened.autonomousRun(run.runID)
            let restoredLease = try await reopened.runLease(run.runID)
            XCTAssertEqual(restored, run)
            XCTAssertEqual(restoredLease, lease)
            XCTAssertEqual(try AcceptanceSQLite.text(fixture.database, "SELECT current_work_json FROM autonomous_runs"), oldRunJSON)
            XCTAssertEqual(try AcceptanceSQLite.integer(fixture.database, "SELECT COUNT(*) FROM pragma_foreign_key_check"), 0)
            XCTAssertEqual(try AcceptanceSQLite.integer(fixture.database, "SELECT COUNT(*) FROM forge_migration_receipts"), 5)
            let manifestURL = VerifiedMigrationBackup.activeManifestURL(for: fixture.database, scope: .continuityIngress)
            let manifest = try JSONDecoder().decode(VerifiedMigrationBackupManifest.self, from: Data(contentsOf: manifestURL))
            XCTAssertEqual(manifest.state, .completed)
            XCTAssertEqual(manifest.sourceVersion, 5)
            XCTAssertEqual(manifest.targetVersion, 6)
            let backup = fixture.database.deletingLastPathComponent().appendingPathComponent(manifest.backupFilename)
            XCTAssertEqual(JSONSupport.sha256Hex(try Data(contentsOf: backup)), manifest.backupSHA256)
            let originalBackup = fixture.database.deletingPathExtension().appendingPathExtension("pre-ingress-capability-v1.sqlite3")
            XCTAssertEqual(try AcceptanceSQLite.integer(originalBackup,
                "SELECT instr(sql,'''awaiting_bootstrap''') FROM sqlite_master WHERE name='autonomous_runs'"), 0)
            let priorHoldBackup = fixture.database.deletingPathExtension().appendingPathExtension("pre-ingress-capability-v2.sqlite3")
            XCTAssertEqual(try AcceptanceSQLite.integer(priorHoldBackup,
                "SELECT pk FROM pragma_table_info('continuity_ingress_holds') WHERE name='run_id'"), 1)
            await reopened.close()
            let again = try ProjectControlPlaneRepository(databaseURL: fixture.database)
            let againRun = try await again.autonomousRun(run.runID)
            XCTAssertEqual(againRun, run)
            await again.close()
        }
    }

    func testFullAppLegacyUpgradeAndReopenPreserveIndependentMigrationLineages() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ingress-app-migration-\(UUID().uuidString)")
            .resolvingSymlinksInPath().standardizedFileURL
        var activeApp: ForgeApp?
        defer {
            _ = activeApp?.shutdown()
            try? FileManager.default.removeItem(at: home)
        }
        let app = try ForgeApp.bootstrap(home: home)
        activeApp = app
        let database = app.paths.controlPlaneSQLite
        let projectRoot = home.appendingPathComponent("migration-project")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let repository = app.projectContexts.repository
        let projectID = ProjectID()
        _ = try await repository.registerProjectUnchecked(projectID: projectID,
            displayName: "Migration fixture", canonicalRoot: projectRoot)
        let scope = ToolAuthorizationScope(canonicalRoots: [projectRoot], writableRoots: [],
            allowedTools: ["context_get"], networkAllowed: false, maximumInlineOutputBytes: 65_536)
        let run = try await repository.createAutonomousRun(AutonomousRunRequest(projectID: projectID,
            projectGeneration: .initial, assignmentID: "migration-assignment", mission: "Preserve existing work",
            providerID: "lmstudio", adapterID: "forge.native-session-host", modelKey: "fixture/model",
            specification: AutonomousRunSpecification(allowedTools: ["context_get"], completionGates: ["fixture-gate"]),
            authorizationScope: scope))
        let lease = try await repository.acquireRunLease(runID: run.runID, ownerID: "app-migration-owner")
        let owner = ProjectBindingOwner(kind: .autonomousRun, id: run.runID.description)
        let binding = try await repository.binding(for: owner)
        XCTAssertNotNil(binding)
        XCTAssertTrue(app.shutdown().completed)
        activeApp = nil
        let standardURL = VerifiedMigrationBackup.activeManifestURL(for: database)
        let standardBytes = try Data(contentsOf: standardURL)
        let standard = try JSONDecoder().decode(VerifiedMigrationBackupManifest.self, from: standardBytes)
        XCTAssertEqual(standard.state, .completed)
        XCTAssertEqual(standard.sourceVersion, 0)
        XCTAssertEqual(standard.targetVersion, 5)
        try AcceptanceSQLite.installLegacyRunConstraint(database)

        let upgraded = try ForgeApp.bootstrap(home: home)
        activeApp = upgraded
        let restored = try await upgraded.projectContexts.repository.autonomousRun(run.runID)
        let restoredLease = try await upgraded.projectContexts.repository.runLease(run.runID)
        let restoredBinding = try await upgraded.projectContexts.repository.binding(for: owner)
        XCTAssertEqual(restored, run)
        XCTAssertEqual(restoredLease, lease)
        XCTAssertEqual(restoredBinding, binding)
        XCTAssertEqual(try AcceptanceSQLite.integer(database, "SELECT version FROM runtime_job_schema_version WHERE singleton=1"), 5)
        XCTAssertEqual(try AcceptanceSQLite.integer(database, "SELECT COUNT(*) FROM pragma_foreign_key_check"), 0)
        XCTAssertEqual(try Data(contentsOf: standardURL), standardBytes)
        let ingressURL = VerifiedMigrationBackup.activeManifestURL(for: database, scope: .continuityIngress)
        XCTAssertNotEqual(standardURL, ingressURL)
        let ingress = try JSONDecoder().decode(VerifiedMigrationBackupManifest.self, from: Data(contentsOf: ingressURL))
        XCTAssertEqual(ingress.state, .completed)
        XCTAssertEqual(ingress.sourceVersion, 5)
        XCTAssertEqual(ingress.targetVersion, 6)
        XCTAssertEqual(try AcceptanceSQLite.integer(database, "SELECT COUNT(*) FROM forge_migration_receipts"), 6)
        XCTAssertTrue(upgraded.shutdown().completed)
        activeApp = nil

        let reopened = try ForgeApp.bootstrap(home: home)
        activeApp = reopened
        let repeated = try await reopened.projectContexts.repository.autonomousRun(run.runID)
        XCTAssertEqual(repeated, run)
        XCTAssertEqual(try Data(contentsOf: standardURL), standardBytes)
        XCTAssertTrue(reopened.shutdown().completed)
        activeApp = nil
    }

    func testMigrationFailureRollsBackSchemaAndRetainsVerifiedOriginal() async throws {
        try await withFixture { fixture in
            _ = try await fixture.repository.createAutonomousRun(fixture.runRequest())
            await fixture.repository.close()
            try AcceptanceSQLite.installLegacyRunConstraint(fixture.database)
            // Force a late failure after the table copy, at durable migration receipt insertion.
            try AcceptanceSQLite.execute(fixture.database, """
                CREATE TABLE forge_migration_receipts(migration_id TEXT PRIMARY KEY,receipt_schema_version INTEGER,
                    source_filename TEXT,backup_filename TEXT,source_version INTEGER,target_version INTEGER,
                    source_sha256 TEXT,source_bytes INTEGER) WITHOUT ROWID;
                CREATE TRIGGER fail_migration_receipt BEFORE INSERT ON forge_migration_receipts
                    BEGIN SELECT RAISE(ABORT,'fixture migration failure'); END;
                """)
            XCTAssertThrowsError(try ProjectControlPlaneRepository(databaseURL: fixture.database))
            XCTAssertEqual(try AcceptanceSQLite.integer(fixture.database,
                "SELECT instr(sql,'''awaiting_bootstrap''') FROM sqlite_master WHERE name='autonomous_runs'"), 0)
            XCTAssertEqual(try AcceptanceSQLite.integer(fixture.database, "SELECT COUNT(*) FROM autonomous_runs"), 1)
            XCTAssertEqual(try AcceptanceSQLite.integer(fixture.database, "SELECT COUNT(*) FROM forge_migration_receipts"), 0)
            let manifest = try JSONDecoder().decode(VerifiedMigrationBackupManifest.self,
                from: Data(contentsOf: VerifiedMigrationBackup.activeManifestURL(for: fixture.database, scope: .continuityIngress)))
            XCTAssertEqual(manifest.state, .prepared)
            let backup = fixture.database.deletingLastPathComponent().appendingPathComponent(manifest.backupFilename)
            XCTAssertEqual(JSONSupport.sha256Hex(try Data(contentsOf: backup)), manifest.backupSHA256)
        }
    }

    func testLegacyMigrationRejectsAdditionalUniqueAndGeneratedColumnWithoutDroppingThem() async throws {
        for extensionKind in ["unique", "generated"] {
            try await withFixture { fixture in
                _ = try await fixture.repository.createAutonomousRun(fixture.runRequest())
                await fixture.repository.close()
                try AcceptanceSQLite.installLegacyRunConstraint(fixture.database, extensionKind: extensionKind)
                let before = try AcceptanceSQLite.text(fixture.database,
                    "SELECT sql FROM sqlite_master WHERE type='table' AND name='autonomous_runs'")
                XCTAssertThrowsError(try ProjectControlPlaneRepository(databaseURL: fixture.database)) { error in
                    XCTAssertEqual(error as? ProjectContextError, .integrityFailure("unsupported autonomous run schema extension"))
                }
                XCTAssertEqual(try AcceptanceSQLite.text(fixture.database,
                    "SELECT sql FROM sqlite_master WHERE type='table' AND name='autonomous_runs'"), before)
                XCTAssertEqual(try AcceptanceSQLite.integer(fixture.database, "SELECT COUNT(*) FROM autonomous_runs"), 1)
                XCTAssertEqual(try AcceptanceSQLite.integer(fixture.database, "SELECT COUNT(*) FROM pragma_foreign_key_check"), 0)
            }
        }
    }

    private func expectHeld(_ runID: RunID, _ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected durable bootstrap hold") }
        catch { XCTAssertEqual(error as? AutonomyError, .bootstrapRequired(runID)) }
    }

    private func expectFailure(_ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected rejection") } catch { }
    }

    private func withFixture(_ operation: (AcceptanceFixture) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ingress-acceptance-\(UUID().uuidString)")
            .resolvingSymlinksInPath().standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = root.appendingPathComponent("control.sqlite3")
        let repository = try ProjectControlPlaneRepository(databaseURL: database)
        let source = try SQLiteStore(path: root.appendingPathComponent("source.sqlite3"))
        do {
            let projectRoot = root.appendingPathComponent("project")
            try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
            let projectID = ProjectID()
            _ = try await repository.registerProjectUnchecked(projectID: projectID, displayName: "Ingress fixture", canonicalRoot: projectRoot)
            let client = ClientID("fixture-transport")
            let owner = ProjectBindingOwner(kind: .mcpClient, id: client.rawValue)
            let binding = try await repository.bind(owner: owner, projectID: projectID, generation: .initial,
                authorizationScope: ToolAuthorizationScope(canonicalRoots: [projectRoot], writableRoots: [],
                    allowedTools: ["context_get", "fs_read"], networkAllowed: false, maximumInlineOutputBytes: 65_536))
            let context = binding.invocationContext(clientID: client)
            let assignment = try ContinuityTaskAssignment(assignmentID: "approved-fixture", assignmentBytes: Data("Approved document".utf8),
                mission: "Approved execution mission", providerID: "lmstudio", adapterID: "forge.native-session-host", modelKey: "fixture/model",
                specification: AutonomousRunSpecification(allowedTools: ["context_get", "fs_read"], completionGates: ["fixture-gate"]),
                authorizationScope: binding.authorizationScope)
            let setup = try await repository.authorizeContinuityTask(projectID: projectID, expectedGeneration: .initial,
                approvedAssignment: assignment, callerContext: context, callerOwner: owner)
            let commit = try source.handoffCommit(HandoffPacket(resumeReady: true, goal: "Untrusted handoff progress"),
                authorization: setup.record.authorization, automaticHandoffEnabled: true)
            let policy = try BudgetPolicyState(globalPolicy: BudgetPolicy(automaticHandoffEnabled: true)).resolve(
                BudgetPolicyScope(kind: .projectOverride, projectID: projectID.description, projectGeneration: 1))
            try await operation(AcceptanceFixture(root: root, database: database, repository: repository,
                projectID: projectID, context: context, owner: owner, setup: setup, commit: commit,
                operationID: XCTUnwrap(commit.delivery?.operationID), policy: policy))
        } catch {
            await repository.close(); source.close()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        await repository.close(); source.close()
        try? FileManager.default.removeItem(at: root)
    }
}

private struct AcceptanceFixture: Sendable {
    let root: URL
    let database: URL
    let repository: ProjectControlPlaneRepository
    let projectID: ProjectID
    let context: ToolInvocationContext
    let owner: ProjectBindingOwner
    let setup: AuthorizedContinuityTaskSetup
    let commit: ContinuityHandoffCommit
    let operationID: UUID
    let policy: BudgetPolicySelection
    func accept() async throws -> ContinuityIngressAcceptanceReceipt {
        try await repository.acceptContinuityIngress(source: commit.revision, operationID: operationID, policySelection: policy)
    }
    func runRequest() -> AutonomousRunRequest {
        let a = setup.record.assignment
        return AutonomousRunRequest(projectID: projectID, projectGeneration: .initial, assignmentID: a.assignmentID,
            mission: a.mission, providerID: a.providerID, adapterID: a.adapterID, modelKey: a.modelKey,
            specification: a.specification, authorizationScope: a.authorizationScope)
    }
    func providerIntent(runID: RunID) -> ProviderSessionIntent {
        ProviderSessionIntent(sessionID: "fixture-session", runID: runID, projectID: projectID, projectGeneration: .initial,
            providerID: "lmstudio", adapterID: "forge.native-session-host", modelKey: "fixture/model", idempotencyKey: "fixture-session-key")
    }
}

private enum AcceptanceSQLite {
    static func withDatabase<T>(_ url: URL, _ operation: (OpaquePointer) throws -> T) throws -> T {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let handle else { throw ContinuityIngressError.integrityFailure("fixture open") }
        defer { sqlite3_close_v2(handle) }
        return try operation(handle)
    }
    static func execute(_ url: URL, _ sql: String, _ values: [String] = []) throws {
        try withDatabase(url) { handle in
            if values.isEmpty {
                guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
                    throw ContinuityIngressError.integrityFailure("fixture SQL: " + String(cString: sqlite3_errmsg(handle)))
                }
                return
            }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw ContinuityIngressError.integrityFailure("fixture prepare")
            }
            defer { sqlite3_finalize(statement) }
            for (i, value) in values.enumerated() {
                let code = value.withCString { sqlite3_bind_text(statement, Int32(i + 1), $0, -1,
                    unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
                guard code == SQLITE_OK else { throw ContinuityIngressError.integrityFailure("fixture bind") }
            }
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw ContinuityIngressError.integrityFailure("fixture step: " + String(cString: sqlite3_errmsg(handle)))
            }
        }
    }
    static func text(_ url: URL, _ sql: String) throws -> String {
        try withDatabase(url) { handle in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw ContinuityIngressError.integrityFailure("fixture query")
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else {
                throw ContinuityIngressError.integrityFailure("fixture query row")
            }
            return String(cString: value)
        }
    }
    static func integer(_ url: URL, _ sql: String) throws -> Int {
        guard let value = Int(try text(url, sql)) else { throw ContinuityIngressError.integrityFailure("fixture integer") }
        return value
    }
    static func installLegacyRunConstraint(_ url: URL, extensionKind: String? = nil) throws {
        let current = try text(url, "SELECT sql FROM sqlite_master WHERE type='table' AND name='autonomous_runs'")
        var legacy = current.replacingOccurrences(of: "'awaiting_bootstrap',", with: "")
            .replacingOccurrences(of: "autonomous_runs (", with: "legacy_runs (")
        if extensionKind == "unique" {
            legacy = legacy.replacingOccurrences(of: "assignment_id TEXT,", with: "assignment_id TEXT UNIQUE,")
        } else if extensionKind == "generated" {
            legacy = legacy.replacingOccurrences(of: "updated_at TEXT NOT NULL",
                with: "updated_at TEXT NOT NULL, extension_value TEXT GENERATED ALWAYS AS (mission) VIRTUAL")
        }
        guard legacy != current, legacy.contains("legacy_runs") else { throw ContinuityIngressError.integrityFailure("fixture legacy DDL") }
        try execute(url, """
            PRAGMA foreign_keys=OFF;
            BEGIN IMMEDIATE;
            DROP TRIGGER IF EXISTS trg_continuity_source_origin_binding_update;
            DROP TRIGGER IF EXISTS trg_continuity_source_origin_binding_delete;
            DROP TABLE IF EXISTS continuity_operation_cancellations;
            DROP TABLE IF EXISTS continuity_source_dispatch_origins;
            DROP TABLE IF EXISTS continuity_source_task_fences;
            DROP TABLE IF EXISTS continuity_explicit_start_requests;
            DROP TABLE IF EXISTS continuity_explicit_start_permits;
            DROP TABLE IF EXISTS continuity_source_activations;
            DROP INDEX idx_continuity_ingress_active_hold;
            ALTER TABLE continuity_ingress_holds RENAME TO fixture_current_holds;
            CREATE TABLE continuity_ingress_holds (
                run_id TEXT PRIMARY KEY NOT NULL CHECK (length(run_id)=36),
                operation_id TEXT NOT NULL UNIQUE CHECK (length(operation_id)=36),
                state TEXT NOT NULL CHECK (state IN ('awaiting_bootstrap','cancelled')),
                created_at TEXT NOT NULL, updated_at TEXT NOT NULL
            );
            INSERT INTO continuity_ingress_holds(run_id,operation_id,state,created_at,updated_at)
                SELECT run_id,operation_id,state,created_at,updated_at FROM fixture_current_holds;
            DROP TABLE fixture_current_holds;
            \(legacy);
            INSERT INTO legacy_runs SELECT * FROM autonomous_runs;
            DROP TABLE autonomous_runs;
            ALTER TABLE legacy_runs RENAME TO autonomous_runs;
            CREATE INDEX idx_autonomous_runs_state ON autonomous_runs(state,retry_at);
            CREATE INDEX idx_autonomous_runs_project ON autonomous_runs(project_id,project_generation);
            COMMIT;
            """)
    }
}

private final class AcceptanceWriteLock: @unchecked Sendable {
    private let lock = NSLock()
    private var database: OpaquePointer?

    init(_ url: URL) throws {
        var opened: OpaquePointer?
        guard sqlite3_open_v2(url.path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let opened else {
            if let opened { sqlite3_close_v2(opened) }
            throw ContinuityIngressError.integrityFailure("fixture writer open")
        }
        guard sqlite3_exec(opened, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else {
            sqlite3_close_v2(opened)
            throw ContinuityIngressError.integrityFailure("fixture writer lock")
        }
        database = opened
    }

    func release() {
        lock.lock()
        defer { lock.unlock() }
        if let database {
            sqlite3_exec(database, "ROLLBACK;", nil, nil, nil)
            sqlite3_close_v2(database)
            self.database = nil
        }
    }

    deinit { release() }
}

private final class AcceptanceSynchronousProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Int] = []
    func record(_ value: Int) { lock.lock(); recorded.append(value); lock.unlock() }
    var values: [Int] { lock.lock(); defer { lock.unlock() }; return recorded }
}
