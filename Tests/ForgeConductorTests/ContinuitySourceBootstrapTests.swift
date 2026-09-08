import XCTest
import SQLite3
@testable import ForgeConductorCore

final class ContinuitySourceBootstrapTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("source-bootstrap-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func fixture() throws -> (ProjectMemoryRepository, SQLiteStore, ContinuityIngressAcceptanceReceipt) {
        let project = ProjectID()
        let authority = try ContinuityIngressAuthorization(projectID: project, projectGeneration: .initial,
            sourceBindingID: UUID(), taskID: UUID(), assignmentID: "approved-task",
            assignmentSHA256: JSONSupport.sha256Hex("approved assignment"),
            authorizationScope: ToolAuthorizationScope(canonicalRoots: [root], allowedTools: ["context_get"],
                networkAllowed: false, maximumInlineOutputBytes: 65_536))
        let source = try SQLiteStore(path: root.appendingPathComponent("source.sqlite3"))
        let packet = HandoffPacket(id: "exact-source.string-id", createdAt: "2026-09-08T10:00:00Z",
            updatedAt: "2026-09-08T10:00:00Z", source: .model, resumeReady: true,
            clientID: "shared-transport", goal: "Original source progress", nextActions: ["Read the fixture"])
        let committed = try source.handoffCommit(packet, authorization: authority, automaticHandoffEnabled: true)
        let operation = try XCTUnwrap(committed.delivery).operationID
        let selection = try BudgetPolicyState().resolve(BudgetPolicyScope(kind: .projectOverride,
            projectID: project.description, projectGeneration: 1))
        let acceptance = try ContinuityIngressAcceptanceReceipt(source: committed.revision, operationID: operation,
            runID: RunID(), policySelection: selection, acceptedAt: "2026-09-08T10:00:01Z")
        let repository = try ProjectMemoryRepository(projectID: project.description,
            directory: root.appendingPathComponent("memory"), enableFTS5: false)
        return (repository, source, acceptance)
    }

    private func prepare(_ repository: ProjectMemoryRepository, _ receipt: ContinuityIngressAcceptanceReceipt,
                         nonce: UUID = UUID()) throws -> ContinuitySourceBootstrapOperation {
        try repository.continuityPrepareSourceBootstrap(acceptance: receipt, authorization: receipt.authorization,
            bootstrapNonce: nonce)
    }

    func testFrozenPreparationReopensWithoutProviderOrLegacyProjection() throws {
        let (repository, source, receipt) = try fixture()
        defer { repository.close(); source.close() }
        let prepared = try prepare(repository, receipt)
        XCTAssertEqual(prepared.state, .checkpointPersisted)
        XCTAssertEqual(prepared.envelope.sourceIdentity.continuityID, "exact-source.string-id")
        XCTAssertEqual(prepared.envelope.acceptance.source.canonicalPacketJSON, receipt.source.canonicalPacketJSON)
        XCTAssertNil(prepared.successorSessionID)
        XCTAssertNil(prepared.successorProviderResponseID)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: prepared.envelope.canonicalEnvelopeJSON) as? [String: Any])
        XCTAssertNil(json["predecessor_session"])
        XCTAssertNil(json["context_budget"])
        XCTAssertEqual(try BootstrapSQLite.integer(repository.databaseURL,
            "SELECT COUNT(*) FROM rollover_operations WHERE predecessor_session_id IS NULL AND adapter_id IS NULL AND budget_observation_id IS NULL"), 1)
        XCTAssertEqual(try BootstrapSQLite.integer(repository.databaseURL, "SELECT COUNT(*) FROM project_active_sessions"), 0)
        XCTAssertEqual(try BootstrapSQLite.integer(repository.databaseURL, "SELECT COUNT(*) FROM continuity_projection_repairs"), 0)
        XCTAssertNil(try repository.continuityOperation(id: receipt.operationID.uuidString.lowercased()))
        XCTAssertNil(try repository.continuityActiveOperation())
        XCTAssertNil(try repository.continuityOperationV2(id: receipt.operationID.uuidString.lowercased()))
        XCTAssertNil(try repository.continuityHandoff(id: prepared.handoffID.uuidString.lowercased()))
        XCTAssertNil(try repository.continuityHandoffV2(id: prepared.handoffID.uuidString.lowercased()))
        var overwritten = try XCTUnwrap(source.handoffGet(id: receipt.sourceIdentity.continuityID))
        overwritten.goal = "A later mutable compatibility write"
        try source.handoffUpsert(overwritten)
        let directory = repository.directory
        repository.close()
        let reopened = try ProjectMemoryRepository(projectID: receipt.authorization.projectID.description,
            directory: directory, enableFTS5: false)
        defer { reopened.close() }
        XCTAssertEqual(try prepare(reopened, receipt), prepared, "The original nonce and frozen bytes win")
        XCTAssertEqual(try reopened.continuitySourceBootstrap(operationID: receipt.operationID, authorization: receipt.authorization), prepared)
        XCTAssertEqual(try reopened.continuityTransitionCount(operationID: receipt.operationID.uuidString.lowercased()), 3)
    }

    func testAuthorizationPrecedesCorruptEnvelopeReadAndLegacyProjectExclusion() throws {
        let (repository, source, receipt) = try fixture()
        defer { repository.close(); source.close() }
        _ = try prepare(repository, receipt)
        let auth = receipt.authorization
        let other = try ContinuityIngressAuthorization(projectID: auth.projectID, projectGeneration: auth.projectGeneration,
            sourceBindingID: UUID(), taskID: UUID(), assignmentID: auth.assignmentID,
            assignmentSHA256: auth.assignmentSHA256, authorizationScope: auth.authorizationScope)
        try BootstrapSQLite.execute(repository.databaseURL, "UPDATE continuity_handoffs SET payload_json='corrupt' WHERE schema_version='3.0'")
        XCTAssertThrowsError(try repository.continuitySourceBootstrap(operationID: receipt.operationID, authorization: other)) {
            XCTAssertEqual($0 as? ContinuityIngressError, .authorityMismatch)
        }
        XCTAssertThrowsError(try repository.continuitySourceBootstrap(operationID: receipt.operationID, authorization: auth))
        XCTAssertThrowsError(try repository.continuityCreateOperation(operationID: UUID().uuidString,
            predecessorSessionID: "legacy-predecessor", handoffID: UUID().uuidString,
            adapterID: "legacy-adapter", idempotencyKey: "other-operation"))
        XCTAssertEqual(try BootstrapSQLite.integer(repository.databaseURL, "SELECT COUNT(*) FROM rollover_operations"), 1)
    }

    func testPreparationRollbackLeavesNoEnvelopeOperationOrTransitions() throws {
        let (repository, source, receipt) = try fixture()
        defer { repository.close(); source.close() }
        try BootstrapSQLite.execute(repository.databaseURL, """
            CREATE TRIGGER fail_source_transition BEFORE INSERT ON rollover_transitions WHEN NEW.schema_version=3
            BEGIN SELECT RAISE(ABORT,'injected source transition failure'); END;
            """)
        XCTAssertThrowsError(try prepare(repository, receipt))
        for table in ["continuity_handoffs", "rollover_operations", "rollover_transitions"] {
            XCTAssertEqual(try BootstrapSQLite.integer(repository.databaseURL, "SELECT COUNT(*) FROM \(table)"), 0)
        }
        try BootstrapSQLite.execute(repository.databaseURL, "DROP TRIGGER fail_source_transition")
        XCTAssertEqual(try prepare(repository, receipt).state, .checkpointPersisted)
    }

    func testTransitionRequiresExactCandidateResponseAndProofsAndCannotActivate() throws {
        let (repository, source, receipt) = try fixture()
        defer { repository.close(); source.close() }
        let prepared = try prepare(repository, receipt)
        let candidate = UUID()
        func advance(_ current: ContinuitySourceBootstrapOperation, _ state: ContinuityState,
                     response: String? = nil, retrieval: String? = nil, ack: String? = nil,
                     candidateID: UUID? = nil) throws -> ContinuitySourceBootstrapOperation {
            try repository.continuityTransitionSourceBootstrap(operationID: receipt.operationID,
                authorization: receipt.authorization, expectedState: current.state, expectedChecksum: current.stateChecksum,
                to: state, candidateID: candidateID ?? candidate, providerResponseID: response,
                retrievalProofSHA256: retrieval, acknowledgementProofSHA256: ack)
        }
        let requested = try advance(prepared, .successorRequested)
        XCTAssertEqual(requested.successorSessionID, candidate)
        XCTAssertNil(requested.successorProviderResponseID)
        XCTAssertEqual(try advance(prepared, .successorRequested), requested)
        XCTAssertThrowsError(try advance(prepared, .successorRequested, candidateID: UUID()))
        XCTAssertThrowsError(try advance(requested, .successorCreated))
        let created = try advance(requested, .successorCreated, response: "response-real-root")
        let bootstrapping = try advance(created, .successorBootstrapping)
        XCTAssertThrowsError(try advance(bootstrapping, .successorAcknowledged, response: "response-real-ack"))
        let retrieval = JSONSupport.sha256Hex("verified context_get invocation and result")
        let ack = JSONSupport.sha256Hex("typed correlated acknowledgement")
        let acknowledged = try advance(bootstrapping, .successorAcknowledged,
            response: "response-real-ack", retrieval: retrieval, ack: ack)
        XCTAssertEqual(acknowledged.retrievalProofSHA256, retrieval)
        XCTAssertEqual(acknowledged.acknowledgementProofSHA256, ack)
        XCTAssertEqual(acknowledged.successorProviderResponseID, "response-real-ack")
        XCTAssertEqual(try advance(bootstrapping, .successorAcknowledged,
            response: "response-real-ack", retrieval: retrieval, ack: ack), acknowledged)
        XCTAssertThrowsError(try advance(acknowledged, .predecessorSealed))
        XCTAssertEqual(try BootstrapSQLite.integer(repository.databaseURL, "SELECT COUNT(*) FROM project_active_sessions"), 0)
        XCTAssertEqual(try repository.continuityTransitionCount(operationID: receipt.operationID.uuidString.lowercased()), 7)
        repository.close()
        let reopened = try ProjectMemoryRepository(projectID: receipt.authorization.projectID.description,
            directory: repository.directory, enableFTS5: false)
        defer { reopened.close() }
        XCTAssertEqual(try reopened.continuitySourceBootstrap(operationID: receipt.operationID,
            authorization: receipt.authorization), acknowledged)
    }

    func testIndependentConnectionsConvergeOnOnePreparedNonce() throws {
        let (repository, source, receipt) = try fixture()
        defer { repository.close(); source.close() }
        let other = try ProjectMemoryRepository(projectID: repository.projectID, directory: repository.directory, enableFTS5: false)
        defer { other.close() }
        let results = BootstrapResults()
        let repositories = [repository, other]
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            results.append(Result { try repositories[index].continuityPrepareSourceBootstrap(acceptance: receipt,
                authorization: receipt.authorization, bootstrapNonce: UUID()) })
        }
        let values = try results.values.map { try $0.get() }
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(values[0], values[1])
        XCTAssertEqual(try BootstrapSQLite.integer(repository.databaseURL, "SELECT COUNT(*) FROM rollover_operations"), 1)
    }

    // These fixtures isolate canonical storage. Control-plane integration tests
    // separately prove issuance from actual durable provider and broker records.
    private func completionFixture() throws -> (ProjectMemoryRepository, SQLiteStore,
        ContinuitySourceBootstrapOperation, ContinuitySourceActivationReceipt, ContinuitySourceResumptionReceipt) {
        let (repository, source, receipt) = try fixture()
        var current = try prepare(repository, receipt)
        let candidate = UUID()
        for state in [ContinuityState.successorRequested, .successorCreated, .successorBootstrapping, .successorAcknowledged] {
            current = try repository.continuityTransitionSourceBootstrap(operationID: receipt.operationID,
                authorization: receipt.authorization, expectedState: current.state, expectedChecksum: current.stateChecksum,
                to: state, candidateID: candidate,
                providerResponseID: state == .successorCreated ? "fixture-root" : (state == .successorAcknowledged ? "fixture-ack" : nil),
                retrievalProofSHA256: state == .successorAcknowledged ? JSONSupport.sha256Hex("fixture retrieval") : nil,
                acknowledgementProofSHA256: state == .successorAcknowledged ? JSONSupport.sha256Hex("fixture ACK") : nil)
        }
        let activation = try ContinuitySourceActivationReceipt(envelope: current.envelope,
            acknowledgedStateChecksum: current.stateChecksum, candidateID: candidate, predecessorProviderSessionID: nil,
            retrievalProofSHA256: XCTUnwrap(current.retrievalProofSHA256),
            acknowledgementProofSHA256: XCTUnwrap(current.acknowledgementProofSHA256),
            acknowledgementProviderTurnID: UUID(), acknowledgementProviderResponseID: "fixture-ack",
            continuationTurnID: UUID(), canonicalContinuationInput: Data("Continue the authorized fixture".utf8),
            continuationIdempotencyKey: "source-fixture-continuation", acceptedAt: "2026-09-08T10:00:02Z")
        let resumption = try ContinuitySourceResumptionReceipt(activationReceipt: activation,
            providerResponseID: "fixture-continuation-response", toolContinuationTurnID: UUID(),
            toolContinuationProviderResponseID: "fixture-consumed-tool-output",
            toolOutputsInputSHA256: JSONSupport.sha256Hex("fixture tool output continuation"), toolInvocationID: UUID(), toolName: "fs_read",
            canonicalToolResultJSON: ForgeJSONCanonicalizationV1.data(from: ["ok": true, "is_error": false,
                "payload": ["content": "Authorized fixture contents"]]), recordedAt: "2026-09-08T10:00:03Z")
        return (repository, source, current, activation, resumption)
    }

    func testSourceSealAndObservedResumePreserveEnvelopeAndReplayAfterReopen() throws {
        let (repository, source, acknowledged, activation, resumption) = try completionFixture()
        defer { repository.close(); source.close() }
        let authorization = acknowledged.envelope.authorization
        let sealed = try repository.continuitySealSourceBootstrap(operationID: acknowledged.operationID,
            authorization: authorization, expectedChecksum: acknowledged.stateChecksum, acceptanceReceipt: activation)
        XCTAssertEqual(sealed.state, .predecessorSealed)
        XCTAssertEqual(sealed.activationReceiptSHA256, activation.receiptSHA256)
        XCTAssertEqual(sealed.sealedStateChecksum, sealed.stateChecksum)
        XCTAssertFalse(sealed.isResumed)
        XCTAssertFalse(sealed.continuationIssued)
        XCTAssertNil(sealed.resumedReceiptSHA256)
        XCTAssertEqual(sealed.envelope.canonicalEnvelopeJSON, acknowledged.envelope.canonicalEnvelopeJSON)
        XCTAssertEqual(sealed.successorProviderResponseID, "fixture-ack")
        XCTAssertEqual(try BootstrapSQLite.integer(repository.databaseURL, "SELECT COUNT(*) FROM project_active_sessions"), 0)
        let directory = repository.directory
        repository.close()
        let reopened = try ProjectMemoryRepository(projectID: authorization.projectID.description, directory: directory, enableFTS5: false)
        defer { reopened.close() }
        XCTAssertEqual(try reopened.continuitySourceBootstrap(operationID: acknowledged.operationID, authorization: authorization), sealed)
        XCTAssertEqual(try reopened.continuitySealSourceBootstrap(operationID: acknowledged.operationID,
            authorization: authorization, expectedChecksum: acknowledged.stateChecksum, acceptanceReceipt: activation), sealed)
        let resumed = try reopened.continuityMarkSourceBootstrapResumed(operationID: acknowledged.operationID,
            authorization: authorization, expectedChecksum: sealed.stateChecksum, continuationReceipt: resumption)
        XCTAssertTrue(resumed.isResumed)
        XCTAssertEqual(resumed.state, .predecessorSealed)
        XCTAssertEqual(resumed.sealedStateChecksum, sealed.stateChecksum)
        XCTAssertEqual(resumed.resumedReceiptSHA256, resumption.receiptSHA256)
        XCTAssertNotEqual(resumed.stateChecksum, sealed.stateChecksum)
        XCTAssertEqual(resumed.envelope, acknowledged.envelope)
        XCTAssertEqual(try reopened.continuityMarkSourceBootstrapResumed(operationID: acknowledged.operationID,
            authorization: authorization, expectedChecksum: sealed.stateChecksum, continuationReceipt: resumption), resumed)
        XCTAssertEqual(try reopened.continuitySealSourceBootstrap(operationID: acknowledged.operationID,
            authorization: authorization, expectedChecksum: acknowledged.stateChecksum, acceptanceReceipt: activation), resumed)
        XCTAssertEqual(try reopened.continuityTransitionCount(operationID: acknowledged.operationID.uuidString.lowercased()), 9)
        XCTAssertEqual(try BootstrapSQLite.integer(reopened.databaseURL,
            "SELECT COUNT(*) FROM rollover_operations WHERE predecessor_session_id IS NULL AND predecessor_provider_response_id IS NULL AND adapter_id IS NULL"), 1)
        reopened.close()
        let final = try ProjectMemoryRepository(projectID: authorization.projectID.description, directory: directory, enableFTS5: false)
        defer { final.close() }
        XCTAssertEqual(try final.continuitySourceBootstrap(operationID: acknowledged.operationID, authorization: authorization), resumed)
    }

    func testSealedSourceExcludesIndependentNextOperationUntilObservedResume() throws {
        let (repository, source, acknowledged, activation, resumption) = try completionFixture()
        defer { repository.close(); source.close() }
        let peer = try ProjectMemoryRepository(projectID: repository.projectID, directory: repository.directory, enableFTS5: false)
        defer { peer.close() }
        let sealed = try repository.continuitySealSourceBootstrap(operationID: acknowledged.operationID,
            authorization: acknowledged.envelope.authorization, expectedChecksum: acknowledged.stateChecksum, acceptanceReceipt: activation)
        let commit = try source.handoffCommit(HandoffPacket(resumeReady: true, goal: "Later source progress"),
            authorization: acknowledged.envelope.authorization, automaticHandoffEnabled: true)
        let next = try ContinuityIngressAcceptanceReceipt(source: commit.revision,
            operationID: XCTUnwrap(commit.delivery).operationID, runID: acknowledged.runID,
            policySelection: acknowledged.envelope.acceptance.policySelection, acceptedAt: "2026-09-08T10:00:04Z")
        XCTAssertThrowsError(try prepare(peer, next))
        XCTAssertThrowsError(try peer.continuityCreateOperation(operationID: UUID().uuidString,
            predecessorSessionID: "legacy-provider", handoffID: UUID().uuidString, adapterID: "fixture", idempotencyKey: "next-legacy"))
        _ = try repository.continuityMarkSourceBootstrapResumed(operationID: acknowledged.operationID,
            authorization: acknowledged.envelope.authorization, expectedChecksum: sealed.stateChecksum, continuationReceipt: resumption)
        XCTAssertEqual(try prepare(peer, next).state, .checkpointPersisted)
        XCTAssertEqual(try BootstrapSQLite.integer(repository.databaseURL, "SELECT COUNT(*) FROM rollover_operations"), 2)
    }

    func testSourceCompletionRejectsWrongReceiptPrematureResumeAndChangedReplay() throws {
        let (repository, source, acknowledged, activation, resumption) = try completionFixture()
        defer { repository.close(); source.close() }
        let authorization = acknowledged.envelope.authorization
        XCTAssertThrowsError(try repository.continuityMarkSourceBootstrapResumed(operationID: acknowledged.operationID,
            authorization: authorization, expectedChecksum: acknowledged.stateChecksum, continuationReceipt: resumption))
        XCTAssertThrowsError(try repository.continuitySealSourceBootstrap(operationID: acknowledged.operationID,
            authorization: authorization, expectedChecksum: String(repeating: "a", count: 64), acceptanceReceipt: activation))
        let changed = try ContinuitySourceActivationReceipt(envelope: activation.envelope,
            acknowledgedStateChecksum: activation.acknowledgedStateChecksum, candidateID: UUID(), predecessorProviderSessionID: nil,
            retrievalProofSHA256: activation.retrievalProofSHA256, acknowledgementProofSHA256: activation.acknowledgementProofSHA256,
            acknowledgementProviderTurnID: activation.acknowledgementProviderTurnID,
            acknowledgementProviderResponseID: activation.acknowledgementProviderResponseID, continuationTurnID: activation.continuationTurnID,
            canonicalContinuationInput: activation.canonicalContinuationInput, continuationIdempotencyKey: activation.continuationIdempotencyKey,
            acceptedAt: activation.acceptedAt)
        XCTAssertThrowsError(try repository.continuitySealSourceBootstrap(operationID: acknowledged.operationID,
            authorization: authorization, expectedChecksum: acknowledged.stateChecksum, acceptanceReceipt: changed))
        let sealed = try repository.continuitySealSourceBootstrap(operationID: acknowledged.operationID,
            authorization: authorization, expectedChecksum: acknowledged.stateChecksum, acceptanceReceipt: activation)
        _ = try repository.continuityMarkSourceBootstrapResumed(operationID: acknowledged.operationID,
            authorization: authorization, expectedChecksum: sealed.stateChecksum, continuationReceipt: resumption)
        let changedEffect = try ContinuitySourceResumptionReceipt(activationReceipt: activation,
            providerResponseID: resumption.providerResponseID, toolContinuationTurnID: resumption.toolContinuationTurnID,
            toolContinuationProviderResponseID: resumption.toolContinuationProviderResponseID,
            toolOutputsInputSHA256: resumption.toolOutputsInputSHA256, toolInvocationID: UUID(), toolName: resumption.toolName,
            canonicalToolResultJSON: resumption.canonicalToolResultJSON, recordedAt: resumption.recordedAt)
        XCTAssertThrowsError(try repository.continuityMarkSourceBootstrapResumed(operationID: acknowledged.operationID,
            authorization: authorization, expectedChecksum: sealed.stateChecksum, continuationReceipt: changedEffect))
        XCTAssertEqual(try repository.continuityTransitionCount(operationID: acknowledged.operationID.uuidString.lowercased()), 9)
    }

    func testCompletionJournalFailureRollsBackSealAndResumeAndRetainsReplay() throws {
        let (repository, source, acknowledged, activation, resumption) = try completionFixture()
        defer { repository.close(); source.close() }
        func inject() throws {
            try BootstrapSQLite.execute(repository.databaseURL, """
                CREATE TRIGGER fail_completion BEFORE INSERT ON rollover_transitions WHEN NEW.to_state='predecessorSealed'
                BEGIN SELECT RAISE(ABORT,'source completion fixture failure'); END;
                """)
        }
        try inject()
        XCTAssertThrowsError(try repository.continuitySealSourceBootstrap(operationID: acknowledged.operationID,
            authorization: acknowledged.envelope.authorization, expectedChecksum: acknowledged.stateChecksum, acceptanceReceipt: activation))
        XCTAssertEqual(try repository.continuitySourceBootstrap(operationID: acknowledged.operationID,
            authorization: acknowledged.envelope.authorization), acknowledged)
        try BootstrapSQLite.execute(repository.databaseURL, "DROP TRIGGER fail_completion")
        let sealed = try repository.continuitySealSourceBootstrap(operationID: acknowledged.operationID,
            authorization: acknowledged.envelope.authorization, expectedChecksum: acknowledged.stateChecksum, acceptanceReceipt: activation)
        try inject()
        XCTAssertThrowsError(try repository.continuityMarkSourceBootstrapResumed(operationID: acknowledged.operationID,
            authorization: acknowledged.envelope.authorization, expectedChecksum: sealed.stateChecksum, continuationReceipt: resumption))
        XCTAssertEqual(try repository.continuitySourceBootstrap(operationID: acknowledged.operationID,
            authorization: acknowledged.envelope.authorization), sealed)
        XCTAssertEqual(try BootstrapSQLite.integer(repository.databaseURL, "SELECT SUM(continuation_issued) FROM continuity_handoffs"), 0)
        try BootstrapSQLite.execute(repository.databaseURL, "DROP TRIGGER fail_completion")
        XCTAssertTrue(try repository.continuityMarkSourceBootstrapResumed(operationID: acknowledged.operationID,
            authorization: acknowledged.envelope.authorization, expectedChecksum: sealed.stateChecksum, continuationReceipt: resumption).isResumed)
    }

    func testCompletionProofCorruptionCannotBecomeResumeOrDiscloseAcrossAuthority() throws {
        let (repository, source, acknowledged, activation, _) = try completionFixture()
        defer { repository.close(); source.close() }
        _ = try repository.continuitySealSourceBootstrap(operationID: acknowledged.operationID,
            authorization: acknowledged.envelope.authorization, expectedChecksum: acknowledged.stateChecksum, acceptanceReceipt: activation)
        try BootstrapSQLite.execute(repository.databaseURL,
            "UPDATE rollover_transitions SET evidence='corrupt' WHERE to_state='predecessorSealed'")
        let auth = acknowledged.envelope.authorization
        let other = try ContinuityIngressAuthorization(projectID: auth.projectID, projectGeneration: auth.projectGeneration,
            sourceBindingID: UUID(), taskID: UUID(), assignmentID: auth.assignmentID,
            assignmentSHA256: auth.assignmentSHA256, authorizationScope: auth.authorizationScope)
        XCTAssertThrowsError(try repository.continuitySourceBootstrap(operationID: acknowledged.operationID, authorization: other)) {
            XCTAssertEqual($0 as? ContinuityIngressError, .authorityMismatch)
        }
        XCTAssertThrowsError(try repository.continuitySourceBootstrap(operationID: acknowledged.operationID, authorization: auth))
    }

    func testIndependentCompletionWritersConvergeWithoutDuplicateJournalRecords() throws {
        let (repository, source, acknowledged, activation, resumption) = try completionFixture()
        defer { repository.close(); source.close() }
        let peer = try ProjectMemoryRepository(projectID: repository.projectID, directory: repository.directory, enableFTS5: false)
        defer { peer.close() }
        let repositories = [repository, peer], sealedResults = BootstrapResults()
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            sealedResults.append(Result { try repositories[index].continuitySealSourceBootstrap(operationID: acknowledged.operationID,
                authorization: acknowledged.envelope.authorization, expectedChecksum: acknowledged.stateChecksum, acceptanceReceipt: activation) })
        }
        let sealed = try sealedResults.values.map { try $0.get() }
        XCTAssertEqual(sealed.count, 2)
        XCTAssertEqual(sealed[0], sealed[1])
        let resumedResults = BootstrapResults()
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            resumedResults.append(Result { try repositories[index].continuityMarkSourceBootstrapResumed(operationID: acknowledged.operationID,
                authorization: acknowledged.envelope.authorization, expectedChecksum: sealed[0].stateChecksum, continuationReceipt: resumption) })
        }
        let resumed = try resumedResults.values.map { try $0.get() }
        XCTAssertEqual(resumed.count, 2)
        XCTAssertEqual(resumed[0], resumed[1])
        XCTAssertTrue(resumed[0].isResumed)
        XCTAssertEqual(try repository.continuityTransitionCount(operationID: acknowledged.operationID.uuidString.lowercased()), 9)
    }

    func testPrecompletionChecksumRetainsOriginalSchemaThreeContract() throws {
        let (repository, source, acknowledged, _, _) = try completionFixture()
        defer { repository.close(); source.close() }
        let original: [String: Any] = [
            "schema_version": 3, "operation_id": acknowledged.operationID.uuidString.lowercased(),
            "project_id": acknowledged.envelope.authorization.projectID.description,
            "project_generation": acknowledged.envelope.authorization.projectGeneration.rawValue,
            "run_id": acknowledged.runID.description, "handoff_sha256": acknowledged.envelope.envelopeSHA256,
            "acceptance_receipt_sha256": acknowledged.envelope.acceptance.receiptSHA256,
            "state": "successorAcknowledged", "attempt": 6,
            "created_at": acknowledged.createdAt, "updated_at": acknowledged.updatedAt,
            "successor_session_id": try XCTUnwrap(acknowledged.successorSessionID).uuidString.lowercased(),
            "successor_provider_response_id": try XCTUnwrap(acknowledged.successorProviderResponseID),
            "retrieval_proof_sha256": try XCTUnwrap(acknowledged.retrievalProofSHA256),
            "acknowledgement_proof_sha256": try XCTUnwrap(acknowledged.acknowledgementProofSHA256),
        ]
        XCTAssertEqual(try ForgeJSONCanonicalizationV1.sha256Hex(of: original), acknowledged.stateChecksum)
        XCTAssertNil(acknowledged.activationReceiptSHA256)
        XCTAssertNil(acknowledged.resumedReceiptSHA256)
    }

    func testCancelledPreparationAndCommittedCancellationHaveDistinctOutcomes() throws {
        let (repository, source, receipt) = try fixture()
        source.close()
        let directory = repository.directory
        repository.close()
        let cancelled = ToolCallCancellation()
        cancelled.cancel()
        let normal = try ProjectMemoryRepository(projectID: receipt.authorization.projectID.description,
            directory: directory, enableFTS5: false)
        XCTAssertThrowsError(try normal.continuityPrepareSourceBootstrap(acceptance: receipt,
            authorization: receipt.authorization, bootstrapNonce: UUID(), cancellation: cancelled)) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertEqual(try BootstrapSQLite.integer(normal.databaseURL, "SELECT COUNT(*) FROM rollover_operations"), 0)
        normal.close()
        let afterCommit = ToolCallCancellation()
        let observed = try ProjectMemoryRepository(projectID: receipt.authorization.projectID.description,
            directory: directory, enableFTS5: false, didMutationCommitObserver: { afterCommit.cancel() },
            beforeMigrationCommitObserver: nil)
        defer { observed.close() }
        let committed = try observed.continuityPrepareSourceBootstrap(acceptance: receipt,
            authorization: receipt.authorization, bootstrapNonce: UUID(), cancellation: afterCommit)
        XCTAssertTrue(afterCommit.isCancelled)
        XCTAssertEqual(try prepare(observed, receipt), committed)
    }

    func testOldVersionTwoMigrationPreservesLegacyRowsAndVerifiedBackup() throws {
        let (repository, source, receipt) = try fixture()
        source.close()
        let legacy = try repository.continuityCreateOperation(operationID: UUID().uuidString.lowercased(),
            predecessorSessionID: "existing-provider", handoffID: UUID().uuidString.lowercased(),
            adapterID: "existing-adapter", idempotencyKey: "legacy-operation")
        let directory = repository.directory
        let database = repository.databaseURL
        repository.close()
        try BootstrapSQLite.installVersionTwo(database)
        let before = try BootstrapSQLite.text(database, "SELECT group_concat(state_checksum,'|') FROM rollover_transitions")
        let reopened = try ProjectMemoryRepository(projectID: receipt.authorization.projectID.description,
            directory: directory, enableFTS5: false)
        defer { reopened.close() }
        XCTAssertEqual(try reopened.continuityOperation(id: legacy.operationID), legacy)
        XCTAssertEqual(try BootstrapSQLite.text(database, "SELECT group_concat(state_checksum,'|') FROM rollover_transitions"), before)
        XCTAssertEqual(try BootstrapSQLite.integer(database, "PRAGMA user_version"), 3)
        XCTAssertEqual(try BootstrapSQLite.integer(database, "SELECT COUNT(*) FROM pragma_foreign_key_check"), 0)
        let manifest = try JSONDecoder().decode(VerifiedMigrationBackupManifest.self,
            from: Data(contentsOf: VerifiedMigrationBackup.activeManifestURL(for: database)))
        XCTAssertEqual(manifest.sourceVersion, 2)
        XCTAssertEqual(manifest.targetVersion, 3)
        XCTAssertEqual(manifest.state, .completed)
        let backup = directory.appendingPathComponent(manifest.backupFilename)
        XCTAssertEqual(JSONSupport.sha256Hex(try Data(contentsOf: backup)), manifest.backupSHA256)
        XCTAssertEqual(try BootstrapSQLite.integer(backup, "PRAGMA user_version"), 2)
        XCTAssertThrowsError(try prepare(reopened, receipt), "The legacy active operation still excludes new source work")
    }

    func testEnvelopeRejectsChangedIdentityNoncanonicalBytesAndOversize() throws {
        let (repository, source, receipt) = try fixture()
        defer { repository.close(); source.close() }
        let envelope = try ContinuitySourceBootstrapEnvelope(acceptance: receipt, bootstrapNonce: UUID())
        XCTAssertEqual(try ContinuitySourceBootstrapEnvelope.storedSnapshot(from: envelope.canonicalEnvelopeJSON), envelope)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: envelope.canonicalEnvelopeJSON) as? [String: Any])
        object["handoff_id"] = UUID().uuidString.lowercased()
        XCTAssertThrowsError(try ContinuitySourceBootstrapEnvelope.storedSnapshot(from: ForgeJSONCanonicalizationV1.data(from: object)))
        XCTAssertThrowsError(try ContinuitySourceBootstrapEnvelope.storedSnapshot(from: envelope.canonicalEnvelopeJSON + Data(" ".utf8)))
        XCTAssertThrowsError(try ContinuitySourceBootstrapEnvelope.storedSnapshot(
            from: Data(repeating: 32, count: ContinuitySourceBootstrapEnvelope.maximumEncodedBytes + 1)))
    }

    func testMigrationFailureRollsBackBothCanonicalTables() throws {
        let (repository, source, receipt) = try fixture()
        source.close()
        let database = repository.databaseURL
        let directory = repository.directory
        repository.close()
        try BootstrapSQLite.installVersionTwo(database)
        let before = try BootstrapSQLite.text(database, "SELECT sql FROM sqlite_master WHERE name='rollover_operations'")
        XCTAssertThrowsError(try ProjectMemoryRepository(projectID: receipt.authorization.projectID.description,
            directory: directory, enableFTS5: false, beforeMigrationCommitObserver: {
                throw StoreError.execFailed("injected migration rollback")
            }))
        XCTAssertEqual(try BootstrapSQLite.integer(database, "PRAGMA user_version"), 2)
        XCTAssertEqual(try BootstrapSQLite.text(database, "SELECT sql FROM sqlite_master WHERE name='rollover_operations'"), before)
        XCTAssertEqual(try BootstrapSQLite.integer(database,
            "SELECT COUNT(*) FROM pragma_table_info('rollover_transitions') WHERE name='adapter_id' AND \"notnull\"=1"), 1)
        let manifest = try JSONDecoder().decode(VerifiedMigrationBackupManifest.self,
            from: Data(contentsOf: VerifiedMigrationBackup.activeManifestURL(for: database)))
        XCTAssertEqual(manifest.state, .prepared)
        let recovered = try ProjectMemoryRepository(projectID: receipt.authorization.projectID.description,
            directory: directory, enableFTS5: false)
        defer { recovered.close() }
        XCTAssertEqual(try prepare(recovered, receipt).state, .checkpointPersisted)
    }
}

private final class BootstrapResults: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Result<ContinuitySourceBootstrapOperation, Error>] = []
    var values: [Result<ContinuitySourceBootstrapOperation, Error>] { lock.lock(); defer { lock.unlock() }; return stored }
    func append(_ value: Result<ContinuitySourceBootstrapOperation, Error>) { lock.lock(); defer { lock.unlock() }; stored.append(value) }
}

private enum BootstrapSQLite {
    static func access<T>(_ url: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let pointer else { throw StoreError.openFailed("bootstrap fixture") }
        defer { sqlite3_close(pointer) }
        return try body(pointer)
    }
    static func execute(_ url: URL, _ sql: String) throws {
        try access(url) { db in
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError.execFailed(String(cString: sqlite3_errmsg(db))) }
        }
    }
    static func text(_ url: URL, _ sql: String) throws -> String {
        try access(url) { db in
            var pointer: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &pointer, nil) == SQLITE_OK, let pointer else {
                throw StoreError.execFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(pointer) }
            guard sqlite3_step(pointer) == SQLITE_ROW, let value = sqlite3_column_text(pointer, 0) else {
                throw StoreError.execFailed("missing fixture row")
            }
            return String(cString: value)
        }
    }
    static func integer(_ url: URL, _ sql: String) throws -> Int { try XCTUnwrap(Int(text(url, sql))) }
    static func installVersionTwo(_ url: URL) throws {
        let operation = try text(url, "SELECT sql FROM sqlite_master WHERE name='rollover_operations'")
        let transition = try text(url, "SELECT sql FROM sqlite_master WHERE name='rollover_transitions'")
        let operationPrefix = try XCTUnwrap(operation.range(of: "source_authorization_sha256"))
        let transitionPrefix = try XCTUnwrap(transition.range(of: ",CHECK"))
        let oldOperation = String(operation[..<operationPrefix.lowerBound]) + "UNIQUE(project_id,idempotency_key))"
        let oldTransition = String(transition[..<transitionPrefix.lowerBound]) + ")"
        let columns = "operation_id,project_id,predecessor_session_id,successor_session_id,handoff_id,state,attempt,adapter_id,idempotency_key,acknowledged_session_id,acknowledged_handoff_id,created_at,updated_at,last_error,retry_at,state_checksum,schema_version,project_generation,run_id,predecessor_provider_response_id,successor_provider_response_id,bootstrap_nonce,acknowledgement_sha256,budget_observation_id,continuation_issued,quarantine_state,migration_source,legacy_record_id"
        let opDDL = oldOperation.replacingOccurrences(of: "\"rollover_operations\"", with: "old_operations")
            .replacingOccurrences(of: "predecessor_session_id TEXT,", with: "predecessor_session_id TEXT NOT NULL,")
            .replacingOccurrences(of: "adapter_id TEXT,", with: "adapter_id TEXT NOT NULL,")
        let transitionDDL = oldTransition.replacingOccurrences(of: "\"rollover_transitions\"", with: "old_transitions")
            .replacingOccurrences(of: "adapter_id TEXT,", with: "adapter_id TEXT NOT NULL,")
        try execute(url, """
            BEGIN IMMEDIATE;
            \(opDDL);
            INSERT INTO old_operations(\(columns)) SELECT \(columns) FROM rollover_operations;
            DROP TABLE rollover_operations;
            ALTER TABLE old_operations RENAME TO rollover_operations;
            \(transitionDDL);
            INSERT INTO old_transitions SELECT * FROM rollover_transitions;
            DROP TABLE rollover_transitions;
            ALTER TABLE old_transitions RENAME TO rollover_transitions;
            CREATE UNIQUE INDEX idx_rollover_active_project ON rollover_operations(project_id) WHERE state <> 'predecessorSealed' AND quarantine_state IS NULL;
            CREATE INDEX idx_rollover_project_updated ON rollover_operations(project_id,updated_at DESC);
            PRAGMA user_version=2;
            COMMIT;
            """)
    }
}
