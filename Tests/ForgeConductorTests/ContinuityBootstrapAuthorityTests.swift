// Bounded bootstrap authority, immutable retrieval proof and migration recovery.

import XCTest
import SQLite3
@testable import ForgeConductorCore

final class ContinuityBootstrapAuthorityTests: XCTestCase {
    func testGrantIsRecoveryOnlyAndBindsCandidateNonceAndCurrentLease() async throws {
        try await withFixture { fixture in
            let grant = try await fixture.issue()
            XCTAssertEqual(grant.envelope, fixture.envelope)
            XCTAssertEqual(try BootstrapSQLite.integer(fixture.database, "SELECT COUNT(*) FROM provider_sessions"), 0)
            XCTAssertEqual(try BootstrapSQLite.integer(fixture.database, "SELECT COUNT(*) FROM provider_turns"), 0)
            await fails { _ = try await fixture.repository.validateAutonomousRunExecutionAdmission(fixture.receipt.runID) }
            await fails { try await fixture.repository.reserveProviderSession(fixture.session(grant), lease: fixture.lease) }
            let changed = try ContinuitySourceBootstrapEnvelope(acceptance: fixture.receipt, bootstrapNonce: UUID())
            await fails { _ = try await fixture.repository.issueContinuityBootstrapGrant(envelope: changed,
                candidateID: grant.candidateID, lease: fixture.lease) }
            let second = try ProjectControlPlaneRepository(databaseURL: fixture.database)
            do {
                await fails { _ = try await second.acquireRunLease(runID: fixture.receipt.runID, ownerID: "another-owner") }
                let same = try await second.issueContinuityBootstrapGrant(envelope: fixture.envelope,
                    candidateID: grant.candidateID, lease: fixture.lease)
                XCTAssertEqual(same, grant)
                await second.close()
            } catch { await second.close(); throw error }
        }
    }

    func testSuccessfulActualSourceReadCommitsProofAndInvocationTogetherAndReplaysAfterRestart() async throws {
        try await withFixture { fixture in
            let grant = try await fixture.issue()
            let prepared = try await fixture.prepareRetrieval(grant)
            let reads = BootstrapReadCounter()
            let proof = try await fixture.repository.executeContinuityBootstrapRetrieval(grant: grant,
                invocationID: prepared.invocationID, lease: fixture.lease) { expected in
                    reads.increment()
                    return try fixture.readActual(expected)
                }
            XCTAssertEqual(reads.value, 1)
            XCTAssertEqual(proof.sourceIdentity, fixture.receipt.sourceIdentity)
            XCTAssertEqual(proof.providerResponseID, prepared.result.responseID)
            XCTAssertEqual(proof.toolResultSHA256, JSONSupport.sha256Hex(proof.canonicalToolResultJSON))
            XCTAssertEqual(proof.payloadOutputSHA256, JSONSupport.sha256Hex(proof.canonicalPayloadJSON))
            XCTAssertNotEqual(proof.toolResultSHA256, proof.payloadOutputSHA256)
            let invocation = try await fixture.repository.toolInvocation(prepared.invocationID)
            XCTAssertEqual(invocation?.state, .completed)
            XCTAssertEqual(invocation?.resultSHA256, proof.toolResultSHA256)
            await fixture.repository.close()
            let reopened = try ProjectControlPlaneRepository(databaseURL: fixture.database)
            do {
                let same = try await reopened.executeContinuityBootstrapRetrieval(grant: grant,
                    invocationID: prepared.invocationID, lease: fixture.lease) { _ in
                        XCTFail("Completed durable proof must not execute a second source read")
                        throw ContinuityIngressError.invalidRequest("unexpected replay")
                    }
                XCTAssertEqual(same, proof)
                let result = try await reopened.continuityBootstrapProviderResult(grant: grant,
                    turnID: prepared.turn.turnID, lease: fixture.lease)
                XCTAssertEqual(result, prepared.result)
                await fails { _ = try await reopened.validateAutonomousRunExecutionAdmission(fixture.receipt.runID) }
                await reopened.close()
            } catch { await reopened.close(); throw error }
        }
    }

    func testPayloadInjectionFailedOutputWrongProviderAndCancellationDoNotProduceProof() async throws {
        try await withFixture { fixture in
            let grant = try await fixture.issue()
            await fails { _ = try await fixture.repository.executeContinuityBootstrapRetrieval(grant: grant,
                invocationID: UUID(), lease: fixture.lease) { try fixture.readActual($0) } }
            let prepared = try await fixture.prepareRetrieval(grant)
            let wrong = try ProviderTurn(requestID: prepared.result.requestID, responseID: prepared.result.responseID,
                providerID: "other-provider", providerVersion: "fixture", modelKey: "fixture/model", messages: [],
                toolCalls: prepared.result.toolCalls, usage: nil, completed: true, finishReason: .toolCalls)
            await fails { try await fixture.repository.recordContinuityBootstrapProviderResult(grant: grant,
                turnID: prepared.turn.turnID, result: wrong, lease: fixture.lease) }
            let failed = try ContinuityBootstrapReadResult(canonicalToolResultJSON:
                ForgeJSONCanonicalizationV1.data(from: ["ok": false, "is_error": true, "payload": ["found": false]]))
            await fails { _ = try await fixture.repository.executeContinuityBootstrapRetrieval(grant: grant,
                invocationID: prepared.invocationID, lease: fixture.lease) { _ in failed } }
            let cancellation = ToolCallCancellation()
            do {
                _ = try await fixture.repository.executeContinuityBootstrapRetrieval(grant: grant,
                    invocationID: prepared.invocationID, lease: fixture.lease, cancellation: cancellation) { expected in
                        let actual = try fixture.readActual(expected)
                        cancellation.cancel()
                        return actual
                    }
                XCTFail("Cancelled read must not commit a proof")
            } catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(try BootstrapSQLite.integer(fixture.database, "SELECT COUNT(*) FROM continuity_bootstrap_retrieval_proofs"), 0)
            let invocation = try await fixture.repository.toolInvocation(prepared.invocationID)
            XCTAssertEqual(invocation?.state, .executing)
            await fails { _ = try await fixture.repository.transitionToolInvocation(invocationID: prepared.invocationID,
                expected: .executing, to: .completed, lease: fixture.lease, bootstrapGrant: grant) }
        }
    }

    func testLeaseRecoveryPreservesCandidateAndProofWhileOldGrantAndRevokedTaskFail() async throws {
        try await withFixture { fixture in
            let grant = try await fixture.issue()
            let prepared = try await fixture.prepareRetrieval(grant)
            let proof = try await fixture.repository.executeContinuityBootstrapRetrieval(grant: grant,
                invocationID: prepared.invocationID, lease: fixture.lease) { try fixture.readActual($0) }
            _ = try await fixture.repository.releaseRunLease(fixture.lease)
            let newLease = try await fixture.repository.acquireRunLease(runID: fixture.receipt.runID, ownerID: "recovered-manager")
            await fails { _ = try await fixture.repository.continuityBootstrapProviderResult(grant: grant,
                turnID: prepared.turn.turnID, lease: newLease) }
            let renewed = try await fixture.repository.issueContinuityBootstrapGrant(envelope: fixture.envelope,
                candidateID: grant.candidateID, lease: newLease)
            XCTAssertEqual(renewed.grantID, grant.grantID)
            XCTAssertEqual(renewed.candidateID, grant.candidateID)
            XCTAssertNotEqual(renewed.leaseOwnerID, grant.leaseOwnerID)
            let same = try await fixture.repository.executeContinuityBootstrapRetrieval(grant: renewed,
                invocationID: prepared.invocationID, lease: newLease) { _ in
                    XCTFail("Lease transfer preserves the already read result")
                    throw ContinuityIngressError.invalidRequest("unexpected read")
                }
            XCTAssertEqual(same, proof)
            _ = try await fixture.repository.revokeContinuityTask(taskID: fixture.receipt.authorization.taskID,
                projectID: fixture.receipt.authorization.projectID, expectedGeneration: .initial)
            await fails { _ = try await fixture.repository.executeContinuityBootstrapRetrieval(grant: renewed,
                invocationID: prepared.invocationID, lease: newLease) { try fixture.readActual($0) } }
            XCTAssertEqual(try BootstrapSQLite.integer(fixture.database, "SELECT COUNT(*) FROM provider_sessions"), 1)
            XCTAssertEqual(try BootstrapSQLite.integer(fixture.database, "SELECT COUNT(*) FROM provider_turns"), 1)
        }
    }

    func testRecoveryReservationCountsRetainedRunAndOperationCallsAcrossCandidates() async throws {
        try await withFixture { fixture in
            let grant = try await fixture.issue()
            let first = try await fixture.prepareRetrieval(grant)
            _ = try await fixture.repository.executeContinuityBootstrapRetrieval(grant: grant,
                invocationID: first.invocationID, lease: fixture.lease) { try fixture.readActual($0) }
            let limited = try BudgetPolicyState(globalPolicy: BudgetPolicy(tools: BudgetToolPolicy(
                callsPerTurn: 1, callsPerSession: 1, callsPerRun: 1, maxInFlight: 1),
                automaticHandoffEnabled: true)).resolve(fixture.receipt.policySelection.scope)
            let secondGrant = try await fixture.issue()
            await fails { _ = try await fixture.prepareRetrieval(secondGrant, policy: limited) }
            XCTAssertEqual(try BootstrapSQLite.integer(fixture.database, "SELECT COUNT(*) FROM tool_invocations"), 1)
            XCTAssertEqual(try BootstrapSQLite.integer(fixture.database, "SELECT COUNT(*) FROM continuity_bootstrap_retrieval_proofs"), 1)
        }
    }

    func testRetainedResultTokenCapRejectsExactRestoreWithoutTruncationOrReservation() async throws {
        try await withFixture { fixture in
            let grant = try await fixture.issue()
            let bounded = try BudgetPolicyState(globalPolicy: BudgetPolicy(tools: BudgetToolPolicy(
                maxResultBytes: 65_536, maxRetainedResultTokens: 1), automaticHandoffEnabled: true))
                .resolve(fixture.receipt.policySelection.scope)
            let exact = try fixture.readActual(fixture.receipt.source)
            XCTAssertLessThan(exact.canonicalToolResultJSON.count, bounded.policy.tools.maxResultBytes)
            XCTAssertGreaterThan(try ContextBudgetMath.estimateTokens(serializedBytes: exact.canonicalToolResultJSON.count,
                policy: ContextBudgetPolicy()), bounded.policy.tools.maxRetainedResultTokens)
            do {
                _ = try await fixture.prepareRetrieval(grant, policy: bounded)
                XCTFail("Exact restore exceeded the retained-result token cap")
            } catch {
                XCTAssertEqual(error as? ContinuityIngressError,
                    .capacityExceeded("current bootstrap retained-result token budget"))
            }
            XCTAssertEqual(try BootstrapSQLite.integer(fixture.database, "SELECT COUNT(*) FROM tool_invocations"), 0)
            XCTAssertEqual(try BootstrapSQLite.integer(fixture.database, "SELECT COUNT(*) FROM continuity_bootstrap_retrieval_proofs"), 0)
            XCTAssertEqual(try fixture.readActual(fixture.receipt.source), exact)
        }
    }

    func testReservedReadRestartDoesNotDoubleChargeButRechecksReducedOutputBounds() async throws {
        try await withFixture { fixture in
            let grant = try await fixture.issue()
            let prepared = try await fixture.prepareRetrieval(grant)
            let recordValue = try await fixture.repository.toolInvocation(prepared.invocationID)
            let record = try XCTUnwrap(recordValue)
            let intent = ToolInvocationIntent(invocationID: record.invocationID, turnID: record.turnID,
                runID: record.runID, sessionID: record.sessionID, projectID: record.projectID,
                projectGeneration: record.projectGeneration, providerCallID: record.providerCallID,
                toolName: record.toolName, replayClass: record.replayClass, idempotencyKey: record.idempotencyKey,
                argumentsSHA256: record.argumentsSHA256, reconciliationDescriptor: record.reconciliationDescriptor)
            await fixture.repository.close()
            let reopened = try ProjectControlPlaneRepository(databaseURL: fixture.database)
            do {
                let oneCall = try BudgetPolicyState(globalPolicy: BudgetPolicy(tools: BudgetToolPolicy(
                    callsPerTurn: 1, callsPerSession: 1, callsPerRun: 1, maxInFlight: 1), automaticHandoffEnabled: true))
                    .resolve(fixture.receipt.policySelection.scope)
                for completed in [false, true] {
                    if completed {
                        _ = try await reopened.executeContinuityBootstrapRetrieval(grant: grant,
                            invocationID: prepared.invocationID, lease: fixture.lease) { try fixture.readActual($0) }
                    }
                    // The pending read already consumed the sole logical call.
                    // Both pending and completed recovery must reuse that row.
                    try await reopened.preflightContinuityBootstrapRetrieval(grant: grant,
                        rootTurnID: prepared.turn.turnID, lease: fixture.lease, policy: oneCall)
                    let duplicate = try await reopened.persistToolInvocationIntent(intent, lease: fixture.lease,
                        bootstrapGrant: grant, bootstrapPolicy: oneCall)
                    XCTAssertEqual(duplicate.invocationID, record.invocationID)
                    XCTAssertEqual(duplicate.state, completed ? .completed : .executing)
                    for (tools, reason) in [
                        (BudgetToolPolicy(maxResultBytes: 1), "current bootstrap result-byte budget"),
                        (BudgetToolPolicy(maxRetainedResultTokens: 1), "current bootstrap retained-result token budget"),
                    ] {
                        let reduced = try BudgetPolicyState(globalPolicy: BudgetPolicy(tools: tools,
                            automaticHandoffEnabled: true)).resolve(fixture.receipt.policySelection.scope)
                        do {
                            _ = try await reopened.persistToolInvocationIntent(intent, lease: fixture.lease,
                                bootstrapGrant: grant, bootstrapPolicy: reduced)
                            XCTFail("Existing invocation bypassed reduced output limits")
                        } catch { XCTAssertEqual(error as? ContinuityIngressError, .capacityExceeded(reason)) }
                        do {
                            try await reopened.preflightContinuityBootstrapRetrieval(grant: grant,
                                rootTurnID: prepared.turn.turnID, lease: fixture.lease, policy: reduced)
                            XCTFail("Root replay bypassed reduced output limits")
                        } catch { XCTAssertEqual(error as? ContinuityIngressError, .capacityExceeded(reason)) }
                    }
                    XCTAssertEqual(try BootstrapSQLite.integer(fixture.database, "SELECT COUNT(*) FROM tool_invocations"), 1)
                    XCTAssertEqual(try BootstrapSQLite.integer(fixture.database,
                        "SELECT COUNT(*) FROM continuity_bootstrap_retrieval_proofs"), completed ? 1 : 0)
                }
                await reopened.close()
            } catch { await reopened.close(); throw error }
        }
    }

    func testLegacyHeldSchemaMigratesWithExactAcceptanceAndRetainsVerifiedBackup() async throws {
        try await withFixture { fixture in
            await fixture.repository.close()
            try BootstrapSQLite.installLegacyHolds(fixture.database)
            let reopened = try ProjectControlPlaneRepository(databaseURL: fixture.database)
            do {
                let repeated = try await reopened.acceptContinuityIngress(source: fixture.receipt.source,
                    operationID: fixture.receipt.operationID, policySelection: fixture.receipt.policySelection)
                XCTAssertEqual(repeated, fixture.receipt)
                XCTAssertEqual(try BootstrapSQLite.integer(fixture.database,
                    "SELECT pk FROM pragma_table_info('continuity_ingress_holds') WHERE name='operation_id'"), 1)
                let manifest = try JSONDecoder().decode(VerifiedMigrationBackupManifest.self,
                    from: Data(contentsOf: VerifiedMigrationBackup.activeManifestURL(for: fixture.database, scope: .continuityIngress)))
                XCTAssertEqual(manifest.sourceVersion, 6)
                XCTAssertEqual(manifest.targetVersion, 7)
                XCTAssertEqual(manifest.state, .completed)
                let backup = fixture.database.deletingLastPathComponent().appendingPathComponent(manifest.backupFilename)
                let priorHoldBackup = fixture.database.deletingPathExtension().appendingPathExtension("pre-ingress-capability-v2.sqlite3")
                XCTAssertEqual(try BootstrapSQLite.integer(priorHoldBackup,
                    "SELECT pk FROM pragma_table_info('continuity_ingress_holds') WHERE name='run_id'"), 1)
                XCTAssertEqual(JSONSupport.sha256Hex(try Data(contentsOf: backup)), manifest.backupSHA256)
                await reopened.close()
            } catch { await reopened.close(); throw error }
        }
    }

    func testOperationHistoryDedupAndUniqueActiveHoldDoNotGrantExecution() async throws {
        try await withFixture { fixture in
            // A forged terminal row has no canonical activation receipt. Its
            // immutable dedup remains readable, but it cannot reopen source work.
            try BootstrapSQLite.execute(fixture.database, """
                UPDATE continuity_ingress_holds SET state='activated';
                UPDATE autonomous_runs SET state='paused',active_operation_id=NULL;
                """)
            await fails { _ = try await fixture.repository.validateAutonomousRunExecutionAdmission(fixture.receipt.runID) }
            let next = try fixture.source.handoffCommit(HandoffPacket(resumeReady: true, goal: "Later progress"),
                authorization: fixture.receipt.authorization, automaticHandoffEnabled: true)
            let nextID = try XCTUnwrap(next.delivery?.operationID)
            await fails { _ = try await fixture.repository.acceptContinuityIngress(source: next.revision,
                operationID: nextID, policySelection: fixture.receipt.policySelection) }
            let original = try await fixture.repository.acceptContinuityIngress(source: fixture.receipt.source,
                operationID: fixture.receipt.operationID, policySelection: fixture.receipt.policySelection)
            XCTAssertEqual(original, fixture.receipt)
            XCTAssertEqual(try BootstrapSQLite.integer(fixture.database, "SELECT COUNT(*) FROM continuity_ingress_holds"), 1)
            try BootstrapSQLite.execute(fixture.database, """
                INSERT INTO continuity_ingress_holds(operation_id,run_id,state,created_at,updated_at)
                SELECT '\(UUID().uuidString.lowercased())',run_id,'awaiting_bootstrap',created_at,updated_at FROM autonomous_runs;
                """)
            XCTAssertThrowsError(try BootstrapSQLite.execute(fixture.database, """
                INSERT INTO continuity_ingress_holds(operation_id,run_id,state,created_at,updated_at)
                SELECT '\(UUID().uuidString.lowercased())',run_id,'awaiting_bootstrap',created_at,updated_at
                FROM autonomous_runs;
                """))
            await fails { _ = try await fixture.repository.validateAutonomousRunExecutionAdmission(fixture.receipt.runID) }
        }
    }

    private func fails(_ body: () async throws -> Void) async {
        do { try await body(); XCTFail("Expected exact bootstrap authority rejection") } catch { }
    }

    private func withFixture(_ body: (BootstrapAuthorityFixture) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bootstrap-authority-\(UUID().uuidString)")
            .resolvingSymlinksInPath().standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = root.appendingPathComponent("control.sqlite3")
        let repository = try ProjectControlPlaneRepository(databaseURL: database)
        let source = try SQLiteStore(path: root.appendingPathComponent("source.sqlite3"))
        do {
            let projectRoot = root.appendingPathComponent("project")
            try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
            let projectID = ProjectID()
            _ = try await repository.registerProjectUnchecked(projectID: projectID, displayName: "Bootstrap fixture", canonicalRoot: projectRoot)
            let client = ClientID("fixture-transport")
            let owner = ProjectBindingOwner(kind: .mcpClient, id: client.rawValue)
            let scope = ToolAuthorizationScope(canonicalRoots: [projectRoot], writableRoots: [],
                allowedTools: ["context_get"], networkAllowed: false, maximumInlineOutputBytes: 65_536)
            let binding = try await repository.bind(owner: owner, projectID: projectID, generation: .initial, authorizationScope: scope)
            let assignment = try ContinuityTaskAssignment(assignmentID: "approved", assignmentBytes: Data("Approved scope".utf8),
                mission: "Continue assigned work", providerID: "lmstudio", adapterID: "forge.native-session-host", modelKey: "fixture/model",
                specification: AutonomousRunSpecification(allowedTools: ["context_get"], completionGates: ["fixture"]), authorizationScope: scope)
            let setup = try await repository.authorizeContinuityTask(projectID: projectID, expectedGeneration: .initial,
                approvedAssignment: assignment, callerContext: binding.invocationContext(clientID: client), callerOwner: owner)
            let commit = try source.handoffCommit(HandoffPacket(resumeReady: true, goal: "Actual source progress / path"),
                authorization: setup.record.authorization, automaticHandoffEnabled: true)
            let policy = try BudgetPolicyState(globalPolicy: BudgetPolicy(automaticHandoffEnabled: true)).resolve(
                BudgetPolicyScope(kind: .projectOverride, projectID: projectID.description, projectGeneration: 1))
            let receipt = try await repository.acceptContinuityIngress(source: commit.revision,
                operationID: XCTUnwrap(commit.delivery?.operationID), policySelection: policy)
            let envelope = try ContinuitySourceBootstrapEnvelope(acceptance: receipt, bootstrapNonce: UUID())
            let lease = try await repository.acquireRunLease(runID: receipt.runID, ownerID: "bootstrap-owner")
            try await body(BootstrapAuthorityFixture(database: database, repository: repository, source: source,
                receipt: receipt, envelope: envelope, lease: lease))
        } catch {
            await repository.close(); source.close(); try? FileManager.default.removeItem(at: root)
            throw error
        }
        await repository.close(); source.close(); try? FileManager.default.removeItem(at: root)
    }
}

private struct BootstrapAuthorityFixture: Sendable {
    let database: URL
    let repository: ProjectControlPlaneRepository
    let source: SQLiteStore
    let receipt: ContinuityIngressAcceptanceReceipt
    let envelope: ContinuitySourceBootstrapEnvelope
    let lease: RunLease

    func issue() async throws -> ContinuityBootstrapGrant {
        try await repository.issueContinuityBootstrapGrant(envelope: envelope, candidateID: UUID(), lease: lease)
    }
    func session(_ grant: ContinuityBootstrapGrant) -> ProviderSessionIntent {
        ProviderSessionIntent(sessionID: grant.sessionID, runID: receipt.runID, projectID: receipt.authorization.projectID,
            projectGeneration: .initial, providerID: "lmstudio", adapterID: "forge.native-session-host", modelKey: "fixture/model",
            handoffID: envelope.handoffID, operationID: envelope.operationID, idempotencyKey: "fixture-root",
            bootstrapNonceSHA256: JSONSupport.sha256Hex(envelope.bootstrapNonce.uuidString.lowercased()),
            handoffSHA256: envelope.envelopeSHA256, status: .candidate, accepted: false)
    }
    func prepareRetrieval(_ grant: ContinuityBootstrapGrant, policy: BudgetPolicySelection? = nil) async throws -> (turn: ProviderTurnIntent, result: ProviderTurn, invocationID: UUID) {
        try await repository.reserveProviderSession(session(grant), lease: lease, bootstrapGrant: grant)
        let turn = ProviderTurnIntent(runID: receipt.runID, sessionID: grant.sessionID, operationID: receipt.operationID,
            projectID: receipt.authorization.projectID, projectGeneration: .initial, kind: .bootstrap,
            idempotencyKey: "root-recovery", inputSHA256: String(repeating: "a", count: 64),
            toolSchemaSHA256: String(repeating: "b", count: 64))
        _ = try await repository.persistProviderTurnIntent(turn, lease: lease, bootstrapGrant: grant)
        _ = try await repository.transitionProviderTurn(turnID: turn.turnID, expected: .intent, to: .submitted,
            lease: lease, bootstrapGrant: grant)
        let call = try ProviderToolCall(callID: "actual-provider-call", name: "context_get",
            argumentsJSON: ForgeJSONCanonicalizationV1.data(from: ["handoff_id": receipt.sourceIdentity.continuityID]))
        let result = try ProviderTurn(requestID: "request", responseID: "response", providerID: "lmstudio",
            providerVersion: "fixture", modelKey: "fixture/model", messages: [], toolCalls: [call],
            usage: nil, completed: true, finishReason: .toolCalls)
        _ = try await repository.transitionProviderTurn(turnID: turn.turnID, expected: .submitted, to: .completed,
            lease: lease, providerRequestID: result.requestID, providerResponseID: result.responseID, bootstrapGrant: grant)
        try await repository.recordContinuityBootstrapProviderResult(grant: grant, turnID: turn.turnID, result: result, lease: lease)
        let invocation = try await repository.persistToolInvocationIntent(ToolInvocationIntent(turnID: turn.turnID,
            runID: receipt.runID, sessionID: grant.sessionID, projectID: receipt.authorization.projectID,
            projectGeneration: .initial, providerCallID: call.callID, toolName: call.name, replayClass: .readOnly,
            idempotencyKey: nil, argumentsSHA256: ForgeJSONCanonicalizationV1.sha256Hex(of:
                JSONSerialization.jsonObject(with: call.argumentsJSON))), lease: lease, bootstrapGrant: grant,
                bootstrapPolicy: policy ?? receipt.policySelection)
        _ = try await repository.transitionToolInvocation(invocationID: invocation.invocationID, expected: .intent,
            to: .executing, lease: lease, bootstrapGrant: grant)
        return (turn, result, invocation.invocationID)
    }
    func readActual(_ expected: ContinuityHandoffRevision) throws -> ContinuityBootstrapReadResult {
        let actual = try source.continuityHandoffRevision(identity: expected.identity, authorization: expected.authorization)
        let data = try ForgeJSONCanonicalizationV1.data(from: ["ok": true, "is_error": false, "payload": [
            "ok": true, "found": true, "packet": JSONSerialization.jsonObject(with: actual.canonicalPacketJSON),
            "continuity_id": actual.identity.continuityID, "revision": actual.identity.revision,
            "packet_sha256": actual.identity.packetSHA256]])
        return try ContinuityBootstrapReadResult(canonicalToolResultJSON: data)
    }
}

private enum BootstrapSQLite {
    static func execute(_ url: URL, _ sql: String) throws {
        try withDatabase(url) { db in
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw ContinuityIngressError.integrityFailure(String(cString: sqlite3_errmsg(db)))
            }
        }
    }
    static func integer(_ url: URL, _ sql: String) throws -> Int {
        try withDatabase(url) { db in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw ContinuityIngressError.integrityFailure("fixture prepare")
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw ContinuityIngressError.integrityFailure("fixture row") }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }
    static func withDatabase<T>(_ url: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw ContinuityIngressError.integrityFailure("fixture open")
        }
        defer { sqlite3_close_v2(handle) }
        return try body(handle)
    }
    static func installLegacyHolds(_ url: URL) throws {
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
            COMMIT;
            """)
    }
}

private final class BootstrapReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
