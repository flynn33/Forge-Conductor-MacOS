import XCTest
import SQLite3
@testable import ForgeConductorCore
#if SWIFT_PACKAGE
import ForgeNativeSessionHostPlugin
#endif

final class NativeSourceConversationJournalTests: XCTestCase {
    func testEnrollmentOwnsSourceAndExactLogicalInputSurvivesRestart() async throws {
        try await withFixture { f in
            let requestID = UUID(), first = try await f.prepare(requestID: requestID)
            guard case .root(let root) = first.request else { return XCTFail("Expected root") }
            XCTAssertTrue(root.input.contains("immutable document marker"))
            let before = try JournalSQL.value(f.database, "SELECT intent_json FROM native_source_provider_turns")
            let read = try NativeSourceReadRequest(key: .init(sessionID: UUID(), requestIDSHA256: String(repeating: "a", count: 64)),
                toolName: "fs_read", canonicalArgumentsJSON: ForgeJSONCanonicalizationV1.data(from: ["path":"fixture.txt"]), managerInstanceID: UUID())
            do {
                _ = try await f.repository.admitContinuitySourceRead(request: read, correlation: f.attachment.setup.correlation,
                    context: f.attachment.context, owner: f.attachment.owner, policySelection: f.policy)
                XCTFail("Generic HTTP source path bypassed conversation owner")
            } catch { XCTAssertEqual(error as? NativeSourceConversationError, .ownerManaged) }
            do {
                _ = try await f.repository.nativeSourceRequest(taskID: f.taskID, requestID: requestID,
                    expectedUserInput: "changed", credential: f.credential)
                XCTFail("Changed logical input replayed")
            } catch { XCTAssertEqual(error as? NativeSourceConversationError, .conflict) }
            await f.repository.close()
            let reopened = try ProjectControlPlaneRepository(databaseURL: f.database, clock: f.clock)
            do {
                let restored = try await reopened.nativeSourceRequest(taskID: f.taskID, requestID: requestID,
                    expectedUserInput: "read fixture", credential: f.credential)
                XCTAssertEqual(restored?.stageID, first.stageID)
                XCTAssertEqual(try JournalSQL.value(f.database, "SELECT intent_json FROM native_source_provider_turns"), before)
                XCTAssertEqual(try JournalSQL.value(f.database, "SELECT COUNT(*) FROM autonomous_runs"), "0")
                XCTAssertEqual(try JournalSQL.value(f.database, "SELECT COUNT(*) FROM provider_turns"), "0")
                await reopened.close()
            } catch { await reopened.close(); throw error }
        }
    }

    func testSubmittedPostNeverReissuesAfterUnknownExpiryAndLeaseTakeover() async throws {
        try await withFixture { f in
            let prepared = try await f.prepare(), approval = try await f.approval(prepared)
            guard case .dispatch(let claim) = try await f.begin(prepared, approval) else { return XCTFail("Missing dispatch") }
            guard case .inProgress = try await f.begin(prepared, approval) else { return XCTFail("Duplicate POST authorized") }
            try await f.repository.recordNativeSourceProviderOutcome(claim: claim, outcome: .unknown)
            let originalNonce = try JournalSQL.value(f.database, "SELECT dispatch_nonce FROM native_source_provider_turns")
            f.clock.advance(661)
            await f.repository.close()
            let reopened = try ProjectControlPlaneRepository(databaseURL: f.database, clock: f.clock)
            do {
                let lease = try await reopened.acquireNativeSourceConversationLease(conversationID: f.lease.conversationID,
                    credential: f.credential, managerInstanceID: UUID())
                let retained = try await reopened.nativeSourcePreparedTurn(stageID: prepared.stageID, credential: f.credential, lease: lease)
                guard case .outcomeUnknown = try await reopened.beginNativeSourceProviderPost(prepared: retained,
                    preflight: approval.preflight, capabilities: f.capabilities, budget: approval.budget,
                    credential: f.credential, lease: lease) else { return XCTFail("Unknown POST retried after 660 seconds") }
                XCTAssertEqual(try JournalSQL.value(f.database, "SELECT COUNT(*) FROM native_source_provider_turns"), "1")
                XCTAssertEqual(try JournalSQL.value(f.database, "SELECT dispatch_nonce FROM native_source_provider_turns"), originalNonce)
                let bound = try await reopened.hasNativeSourceProviderConfigurationBinding()
                XCTAssertTrue(bound)
                await reopened.close()
            } catch { await reopened.close(); throw error }
        }
    }

    func testCancellationBeforeFullPostCommitLeavesPreparedIntent() async throws {
        try await withFixture { f in
            let prepared = try await f.prepare(), approval = try await f.approval(prepared)
            let token = ToolCallCancellation()
            await f.repository.configureOperationObservers(beforeCommit: { token.cancel() })
            do {
                _ = try await f.repository.beginNativeSourceProviderPost(prepared: prepared, preflight: approval.preflight,
                    capabilities: f.capabilities, budget: approval.budget, credential: f.credential, lease: f.lease, cancellation: token)
                XCTFail("Cancelled POST authorization committed")
            } catch { XCTAssertTrue(error is CancellationError) }
            await f.repository.configureOperationObservers()
            XCTAssertEqual(try JournalSQL.value(f.database, "SELECT state FROM native_source_provider_turns"), "prepared")
            XCTAssertEqual(try JournalSQL.value(f.database, "SELECT COUNT(*) FROM native_source_provider_turns WHERE dispatch_nonce IS NOT NULL"), "0")
            guard case .dispatch = try await f.begin(prepared, approval) else { return XCTFail("Fresh caller could not authorize undispatched intent") }
        }
    }

    func testSourcePostAdmissionRechecksLeaseBeforeFullCommit() async throws {
        try await withFixture { f in
            let prepared = try await f.prepare(), approval = try await f.approval(prepared)
            let intent = try JournalSQL.value(f.database, "SELECT intent_json FROM native_source_provider_turns")
            await f.repository.configureOperationObservers(beforeCommit: { [clock = f.clock] in clock.advance(31) })
            do {
                _ = try await f.begin(prepared, approval)
                XCTFail("Expired source lease issued a provider dispatch claim at COMMIT")
            } catch { XCTAssertEqual(error as? NativeSourceConversationError, .leaseUnavailable) }
            await f.repository.configureOperationObservers()
            XCTAssertEqual(try JournalSQL.value(f.database, "SELECT state FROM native_source_provider_turns"), "prepared")
            XCTAssertEqual(try JournalSQL.value(f.database, "SELECT intent_json FROM native_source_provider_turns"), intent)
            XCTAssertEqual(try JournalSQL.value(f.database, "SELECT COUNT(*) FROM native_source_provider_turns WHERE post_json IS NOT NULL OR dispatch_nonce IS NOT NULL OR dispatch_owner IS NOT NULL OR dispatch_epoch IS NOT NULL"), "0")
            XCTAssertEqual(try JournalSQL.value(f.database, "SELECT COUNT(*) FROM native_source_conversations WHERE configuration_sha256 IS NOT NULL OR ceilings_json IS NOT NULL OR ceilings_sha256 IS NOT NULL"), "0")
            let lease = try await f.repository.acquireNativeSourceConversationLease(conversationID: prepared.conversationID,
                credential: f.credential, managerInstanceID: UUID())
            guard case .dispatch = try await f.repository.beginNativeSourceProviderPost(prepared: prepared,
                preflight: approval.preflight, capabilities: f.capabilities, budget: approval.budget,
                credential: f.credential, lease: lease) else { return XCTFail("New live owner could not admit the unchanged prepared request") }
        }
    }

    func testSourceProbeAdmissionRechecksLeaseBeforeFullCommit() async throws {
        try await withFixture { f in
            let prepared = try await f.prepare(), approval = try await f.approval(prepared)
            let count = try JournalSQL.value(f.database, "SELECT COUNT(*) FROM native_source_capability_checks")
            await f.repository.configureOperationObservers(beforeCommit: { [clock = f.clock] in clock.advance(31) })
            do {
                _ = try await f.repository.reserveNativeSourceCapabilityCheck(prepared: prepared, preflight: approval.preflight,
                    credential: f.credential, lease: f.lease)
                XCTFail("Expired source lease issued a diagnostic probe claim at COMMIT")
            } catch { XCTAssertEqual(error as? NativeSourceConversationError, .leaseUnavailable) }
            await f.repository.configureOperationObservers()
            XCTAssertEqual(try JournalSQL.value(f.database, "SELECT COUNT(*) FROM native_source_capability_checks"), count)
            XCTAssertEqual(try JournalSQL.value(f.database, "SELECT COUNT(*) FROM native_source_capability_checks WHERE state='attempted'"), "0")
            XCTAssertEqual(try JournalSQL.value(f.database, "SELECT state FROM native_source_provider_turns"), "prepared")
            XCTAssertEqual(try JournalSQL.value(f.database, "SELECT COUNT(*) FROM native_source_provider_turns WHERE post_json IS NOT NULL OR dispatch_nonce IS NOT NULL"), "0")
            let lease = try await f.repository.acquireNativeSourceConversationLease(conversationID: prepared.conversationID,
                credential: f.credential, managerInstanceID: UUID())
            _ = try await f.repository.reserveNativeSourceCapabilityCheck(prepared: prepared, preflight: approval.preflight,
                credential: f.credential, lease: lease)
            XCTAssertEqual(try JournalSQL.value(f.database, "SELECT COUNT(*) FROM native_source_capability_checks WHERE state='attempted'"), "1")
        }
    }

    func testWholeBatchRejectsLongLaterCallBeforeFirstEffectAndRetainsActualResponse() async throws {
        try await withFixture { f in
            let prepared = try await f.prepare(), approval = try await f.approval(prepared)
            guard case .dispatch(let claim) = try await f.begin(prepared, approval) else { return XCTFail("Missing dispatch") }
            let calls = [try f.call(id: "valid-first"), try f.call(id: String(repeating: "x", count: 513))]
            let turn = try f.turn(prepared, calls: calls)
            do {
                _ = try await f.repository.acceptNativeSourceProviderTurn(claim: claim, turn: turn, credential: f.credential, lease: f.lease)
                XCTFail("Invalid later call admitted")
            } catch { XCTAssertEqual(error as? NativeSourceConversationError, .invalidRequest("provider tool batch")) }
            XCTAssertEqual(try JournalSQL.value(f.database, "SELECT state FROM native_source_provider_turns"), "accepted")
            XCTAssertEqual(try JournalSQL.value(f.database, "SELECT COUNT(*) FROM native_source_provider_calls"), "0")
            XCTAssertEqual(try JournalSQL.value(f.database, "SELECT COUNT(*) FROM native_source_requests"), "0")
            let retained = try await f.repository.nativeSourceRequestResult(taskID: f.taskID,
                requestID: prepared.requestID, credential: f.credential)
            XCTAssertEqual(retained?.turn, turn); XCTAssertEqual(retained?.calls.count, 0)
        }
    }

    func testSourceReadReceiptAndCallOutputRollBackTogetherThenReplayAfterCacheExpiry() async throws {
        try await withFixture { f in
            let prepared = try await f.prepare(), approval = try await f.approval(prepared)
            guard case .dispatch(let claim) = try await f.begin(prepared, approval) else { return XCTFail("Missing dispatch") }
            let accepted = try await f.repository.acceptNativeSourceProviderTurn(claim: claim,
                turn: f.turn(prepared, calls: [f.call(id: "call/Original:ID")]), credential: f.credential, lease: f.lease)
            let reference = try XCTUnwrap(accepted.calls.first)
            let call = try await f.repository.resolveNativeSourceProviderCall(reference: reference, credential: f.credential, lease: f.lease)
            XCTAssertEqual(call.callID, "call/Original:ID")
            let outputBudget = try NativeSourceProviderOutputBudget(conversationID: reference.conversationID, stageID: reference.stageID,
                callOrdinal: reference.ordinal, configurationFingerprintSHA256: approval.preflight.configurationFingerprintSHA256,
                priorOutputsSHA256: call.priorOutputsSHA256, maximumCanonicalToolResultBytes: 65_536,
                maximumEscapedPayloadBytes: 393_216, maximumResultTokens: 4_096)
            let request = try NativeSourceReadRequest(key: call.key, toolName: call.toolName,
                canonicalArgumentsJSON: call.canonicalArgumentsJSON, managerInstanceID: f.lease.managerInstanceID)
            guard case .execute(let admission) = try await f.repository.admitContinuitySourceRead(request: request,
                correlation: f.attachment.setup.correlation, context: f.attachment.context, owner: f.attachment.owner, policySelection: f.policy,
                reference: reference, credential: f.credential, lease: f.lease, outputBudget: outputBudget) else { return XCTFail("Missing exact read") }
            try await f.repository.beginContinuitySourceRead(admission: admission, policySelection: f.policy,
                reference: reference, credential: f.credential, lease: f.lease, outputBudget: outputBudget)
            let bytes = try ForgeJSONCanonicalizationV1.data(from: ["ok":true,"is_error":false,"payload":["text":"actual fixture output"]])
            await f.repository.configureOperationObservers(beforeCommit: { throw JournalFixtureError.interrupted })
            do {
                _ = try await f.repository.completeContinuitySourceRead(admission: admission, canonicalToolResultJSON: bytes,
                    policySelection: f.policy, reference: reference, credential: f.credential, lease: f.lease, outputBudget: outputBudget)
                XCTFail("Injected receipt failure committed")
            } catch { XCTAssertTrue(error is JournalFixtureError) }
            await f.repository.configureOperationObservers()
            XCTAssertEqual(try JournalSQL.value(f.database, "SELECT state FROM native_source_requests"), "executing")
            XCTAssertEqual(try JournalSQL.value(f.database, "SELECT COUNT(*) FROM native_source_provider_calls WHERE output_json IS NOT NULL"), "0")
            _ = try await f.repository.completeContinuitySourceRead(admission: admission, canonicalToolResultJSON: bytes,
                policySelection: f.policy, reference: reference, credential: f.credential, lease: f.lease, outputBudget: outputBudget)
            try await f.repository.releaseNativeSourceConversationLease(lease: f.lease)
            f.clock.advance(3_601)
            let lease = try await f.repository.acquireNativeSourceConversationLease(conversationID: f.lease.conversationID,
                credential: f.credential, managerInstanceID: UUID())
            let output = try await f.repository.nativeSourceProviderCallOutput(reference: reference, credential: f.credential,
                lease: lease, policySelection: f.policy)
            XCTAssertEqual(output?.canonicalToolResultJSON, bytes)
            XCTAssertEqual(output?.callID, call.callID)
            XCTAssertEqual(try JournalSQL.value(f.database, "SELECT COUNT(*) FROM native_source_requests"), "1")
        }
    }

    func testExpiredProbeOwnershipIsChargedUnknownAndNewObservationDoesNotRefund() async throws {
        try await withFixture { f in
            let prepared = try await f.prepare(), preflight = try await f.preflight(prepared)
            _ = try await f.repository.reserveNativeSourceCapabilityCheck(prepared: prepared, preflight: preflight,
                credential: f.credential, lease: f.lease)
            f.clock.advance(31)
            let lease = try await f.repository.acquireNativeSourceConversationLease(conversationID: f.lease.conversationID,
                credential: f.credential, managerInstanceID: UUID())
            XCTAssertEqual(try JournalSQL.value(f.database, "SELECT state FROM native_source_capability_checks"), "unknown")
            _ = try await f.repository.reserveNativeSourceCapabilityCheck(prepared: prepared, preflight: preflight,
                credential: f.credential, lease: lease)
            XCTAssertEqual(try JournalSQL.value(f.database, "SELECT COUNT(*) FROM native_source_capability_checks"), "2")
            XCTAssertEqual(try JournalSQL.value(f.database, "SELECT COUNT(*) FROM native_source_provider_turns WHERE state='submitted'"), "0")
        }
    }

    func testCancellingCompletedOldSendCannotCancelLaterPreparedSend() async throws {
        try await withFixture { f in
            let first = try await f.prepare(), approval = try await f.approval(first)
            guard case .dispatch(let claim) = try await f.begin(first, approval) else { return XCTFail("Missing dispatch") }
            _ = try await f.repository.acceptNativeSourceProviderTurn(claim: claim, turn: f.turn(first, calls: []), credential: f.credential, lease: f.lease)
            let next = try await f.prepare(requestID: UUID())
            let cancelID = UUID()
            let receipt = try await f.repository.requestNativeSourceConversationCancellation(conversationID: f.lease.conversationID,
                requestID: first.requestID, cancelRequestID: cancelID, credential: f.credential)
            XCTAssertNil(receipt.pendingProviderOperationID)
            let repeatReceipt = try await f.repository.requestNativeSourceConversationCancellation(conversationID: f.lease.conversationID,
                requestID: first.requestID, cancelRequestID: cancelID, credential: f.credential)
            XCTAssertEqual(receipt.recordedAt, repeatReceipt.recordedAt); XCTAssertTrue(repeatReceipt.alreadyRequested)
            let status = try await f.repository.nativeSourceConversationStatus(conversationID: f.lease.conversationID, credential: f.credential)
            XCTAssertFalse(status.cancelled); XCTAssertEqual(status.activeStageID, next.stageID)
        }
    }

    func testWrongVerifierCannotDecodeConversationOrUseRetainedLease() async throws {
        try await withFixture { f in
            let prepared = try await f.prepare()
            let wrong = try NativeTaskCapabilityCredential(capabilityID: f.credential.capabilityID, epoch: 1, secret: Data(repeating: 9, count: 32))
            try JournalSQL.execute(f.database, "UPDATE native_source_conversations SET body_json='{}'")
            do {
                _ = try await f.repository.nativeSourceConversationStatus(conversationID: f.lease.conversationID, credential: wrong)
                XCTFail("Wrong verifier disclosed corrupt record")
            } catch { XCTAssertEqual(error as? NativeTaskCapabilityError, .credentialRejected) }
            do {
                _ = try await f.repository.nativeSourcePreparedTurn(stageID: prepared.stageID, credential: wrong, lease: f.lease)
                XCTFail("Wrong credential used lease")
            } catch { XCTAssertEqual(error as? NativeTaskCapabilityError, .credentialRejected) }
        }
    }

    func testRawExplicitStartCannotReadSourceWhileConversationOwnsTask() async throws {
        try await withFixture { f in
            _ = try await f.prepare()
            let observed = JournalReadObservation()
            do {
                _ = try await f.repository.submitExplicitContinuityIngress(taskID: f.taskID,
                    correlation: f.attachment.setup.correlation, context: f.attachment.context, owner: f.attachment.owner,
                    requestID: UUID(), continuityID: "prior-source", policySelection: f.policy) { _ in
                    observed.record()
                    throw JournalFixtureError.interrupted
                }
                XCTFail("Raw start entered source resolver")
            } catch { XCTAssertEqual(error as? NativeSourceConversationError, .ownerManaged) }
            XCTAssertFalse(observed.called)
            XCTAssertEqual(try JournalSQL.value(f.database, "SELECT COUNT(*) FROM continuity_ingress_acceptances"), "0")
        }
    }

    func testCapabilitySevenMigrationPreservesTaskOriginAndVerifiedBackup() async throws {
        try await withFixture { f in
            let assignment = try JournalSQL.value(f.database, "SELECT assignment_json FROM continuity_task_authorizations")
            let verifier = try JournalSQL.value(f.database, "SELECT verifier_sha256 FROM native_task_capabilities")
            await f.repository.close()
            try JournalSQL.execute(f.database, "ALTER TABLE provider_turns DROP COLUMN source_preflight_sha256; ALTER TABLE provider_turns DROP COLUMN source_preflight_json; DROP TABLE native_source_provider_run_offsets; DROP TABLE native_source_provider_calls; DROP TABLE native_source_capability_checks; DROP TABLE native_source_provider_turns; DROP TABLE native_source_conversations;")
            let reopened = try ProjectControlPlaneRepository(databaseURL: f.database, clock: f.clock)
            do {
                XCTAssertEqual(try JournalSQL.value(f.database, "SELECT assignment_json FROM continuity_task_authorizations"), assignment)
                XCTAssertEqual(try JournalSQL.value(f.database, "SELECT verifier_sha256 FROM native_task_capabilities"), verifier)
                XCTAssertEqual(try JournalSQL.value(f.database, "SELECT COUNT(*) FROM continuity_source_dispatch_origins"), "1")
                XCTAssertEqual(try JournalSQL.value(f.database, "SELECT COUNT(*) FROM native_source_conversations"), "0")
                let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: VerifiedMigrationBackup.activeManifestURL(for: f.database, scope: .continuityIngress))) as? [String: Any]
                XCTAssertEqual(manifest?["source_version"] as? Int, 8); XCTAssertEqual(manifest?["target_version"] as? Int, 9)
                XCTAssertEqual(manifest?["state"] as? String, "completed")
                let backup = f.database.deletingPathExtension().appendingPathExtension("pre-ingress-capability-v7.sqlite3")
                XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
                XCTAssertEqual(try JournalSQL.value(backup, "SELECT verifier_sha256 FROM native_task_capabilities"), verifier)
                XCTAssertEqual(try JournalSQL.value(backup, "SELECT COUNT(*) FROM sqlite_master WHERE name='native_source_conversations'"), "0")
                await reopened.close()
            } catch { await reopened.close(); throw error }
        }
    }

    func testRetainedHistoryUsesActualEscapedPostBytesForMissingUsage() async throws {
        try await withFixture { f in
            let names: Set<String> = ["fs_read","session_checkpoint","session_handoff"]
            let tools = try ToolDefinitionCatalog.production(toolNames: names.sorted()).providerToolDefinitions(allowedToolNames: names)
            let request = try NativeSourceTurnPreparationRequest(requestID: UUID(), conversationID: f.lease.conversationID,
                userInput: String(repeating: "/\u{1}", count: 4_000))
            let prepared = try await f.repository.prepareNativeSourceProviderTurn(request: request,
                credential: f.credential, lease: f.lease, tools: tools)
            let approval = try await f.approval(prepared)
            guard case .dispatch(let claim) = try await f.begin(prepared, approval) else { return XCTFail("Missing dispatch") }
            let turn = try ProviderTurn(requestID: prepared.stageID.uuidString.lowercased(), responseID: "escaped-response",
                providerID: f.capabilities.providerID, providerVersion: f.capabilities.providerVersion, modelKey: f.capabilities.modelKey,
                providerInstanceID: f.capabilities.providerInstanceID, messages: ["Accepted without usage"], toolCalls: [],
                usage: nil, completed: true, finishReason: .stop)
            _ = try await f.repository.acceptNativeSourceProviderTurn(claim: claim, turn: turn, credential: f.credential, lease: f.lease)
            let next = try await f.prepare(requestID: UUID())
            XCTAssertNil(next.priorUsage)
            XCTAssertGreaterThanOrEqual(next.priorContextSerializedBytes, approval.preflight.bodyByteCount + (try JSONEncoder().encode(turn).count))
            XCTAssertLessThan(next.priorContextSerializedBytes, approval.preflight.bodyByteCount + 16_384)
        }
    }

    func testSourceToolCarryoverCountsPriorReadsAndProviderCallsOnceAndRetainsInitialCeiling() async throws {
        try await withFixture(priorReads: 2, toolLimit: 6) { f in
            let source = try SQLiteStore(path: f.database.deletingLastPathComponent().appendingPathComponent("source.sqlite3"))
            defer { source.close() }
            let prepared = try await f.prepare(), approval = try await f.approval(prepared)
            guard case .dispatch(let claim) = try await f.begin(prepared, approval) else { return XCTFail("Missing source dispatch") }
            let calls = try ["fs_read","session_checkpoint","session_handoff"].enumerated().map { index, name in
                try ProviderToolCall(callID: "source-call-\(index)", name: name,
                    argumentsJSON: ForgeJSONCanonicalizationV1.data(from: name == "fs_read" ? ["path":"fixture.txt"] : ["goal":"carry full authority"]))
            }
            let accepted = try await f.repository.acceptNativeSourceProviderTurn(claim: claim, turn: f.turn(prepared, calls: calls),
                credential: f.credential, lease: f.lease)
            var handoff: ContinuityHandoffCommit?
            for reference in accepted.calls {
                let call = try await f.repository.resolveNativeSourceProviderCall(reference: reference, credential: f.credential, lease: f.lease)
                let budget = try NativeSourceProviderOutputBudget(conversationID: reference.conversationID, stageID: reference.stageID,
                    callOrdinal: reference.ordinal, configurationFingerprintSHA256: approval.preflight.configurationFingerprintSHA256,
                    priorOutputsSHA256: call.priorOutputsSHA256, maximumCanonicalToolResultBytes: 65_536,
                    maximumEscapedPayloadBytes: 393_216, maximumResultTokens: 4_096)
                if call.toolName == "fs_read" {
                    let request = try NativeSourceReadRequest(key: call.key, toolName: call.toolName,
                        canonicalArgumentsJSON: call.canonicalArgumentsJSON, managerInstanceID: f.lease.managerInstanceID)
                    guard case .execute(let admission) = try await f.repository.admitContinuitySourceRead(request: request,
                        correlation: f.attachment.setup.correlation, context: f.attachment.context, owner: f.attachment.owner,
                        policySelection: f.policy, reference: reference, credential: f.credential, lease: f.lease, outputBudget: budget) else {
                        return XCTFail("Missing counted provider read")
                    }
                    try await f.repository.beginContinuitySourceRead(admission: admission, policySelection: f.policy,
                        reference: reference, credential: f.credential, lease: f.lease, outputBudget: budget)
                    let bytes = try ForgeJSONCanonicalizationV1.data(from: ["ok":true,"is_error":false,"payload":["text":"source work"]])
                    _ = try await f.repository.completeContinuitySourceRead(admission: admission, canonicalToolResultJSON: bytes,
                        policySelection: f.policy, reference: reference, credential: f.credential, lease: f.lease, outputBudget: budget)
                } else {
                    let ready = call.toolName == "session_handoff"
                    let packet = HandoffPacket(id: "journal-exact-source", createdAt: ISO8601.string(from: f.clock.now()),
                        updatedAt: ISO8601.string(from: f.clock.now()), resumeReady: ready,
                        clientID: f.attachment.context.clientID.rawValue, goal: ready ? "Ready source" : "Soft source")
                    let frozen = try PreparedContinuitySourceCommit.preparing(packet)
                    let request = try NativeSourceCommitRequest(key: call.key, canonicalArgumentsJSON: call.canonicalArgumentsJSON,
                        managerInstanceID: f.lease.managerInstanceID, finalize: ready)
                    guard case .commit(let admission) = try await f.repository.prepareContinuitySourceCommit(request: request,
                        correlation: f.attachment.setup.correlation, context: f.attachment.context, owner: f.attachment.owner,
                        policySelection: f.policy, prepare: { _ in frozen }, reference: reference, credential: f.credential,
                        lease: f.lease, outputBudget: budget, validatePreparedOutput: { _ in }, encodeResult: { try Self.commitWire($0) }) else {
                        return XCTFail("Missing exact frozen source commit")
                    }
                    let actual = try await f.repository.commitContinuitySourceRequest(admission: admission,
                        commit: { value, authorization, automatic in
                            try source.handoffCommit(value.packet(), authorization: authorization, automaticHandoffEnabled: automatic)
                        }, policySelection: f.policy, reference: reference, credential: f.credential, lease: f.lease,
                        outputBudget: budget, encodeResult: { try Self.commitWire($0) })
                    if ready { handoff = actual }
                }
            }
            let sourceRevision = try XCTUnwrap(handoff).revision
            let operationID = try ContinuityIngressOperationIdentity(revision: sourceRevision).operationID
            let ingress = try await f.repository.acceptContinuityIngress(source: sourceRevision, operationID: operationID, policySelection: f.policy)
            let readOffset = try await f.repository.nativeSourceBudgetCarryover(runID: ingress.runID)
            let offset = try XCTUnwrap(readOffset)
            XCTAssertEqual(offset.priorSourceReadCallsAtEnrollment, 2); XCTAssertEqual(offset.admittedProviderCalls, 3)
            XCTAssertEqual(offset.priorSourceReadCallsAtEnrollment + offset.admittedProviderCalls, 5)
            XCTAssertEqual(try JournalSQL.value(f.database, "SELECT charged_calls FROM native_source_run_offsets"), "3", "Raw read ledger overlaps one provider read and must not be added again")
            let lease = try await f.repository.acquireRunLease(runID: ingress.runID, ownerID: "source-budget-fixture")
            let envelope = try ContinuitySourceBootstrapEnvelope(acceptance: ingress, bootstrapNonce: UUID())
            let root = try await Self.bootstrapRoot(repository: f.repository, acceptance: ingress, envelope: envelope, lease: lease)
            let enlarged = try BudgetPolicyState(globalPolicy: .init(tools: .init(callsPerTurn: 8, callsPerSession: 100, callsPerRun: 100),
                automaticHandoffEnabled: true)).resolve(.init(kind: .projectOverride, projectID: ingress.authorization.projectID.description, projectGeneration: 1))
            _ = try await f.repository.persistToolInvocationIntent(root.intent, lease: lease, bootstrapGrant: root.grant, bootstrapPolicy: enlarged)
            _ = try await f.repository.transitionToolInvocation(invocationID: root.intent.invocationID, expected: .intent, to: .executing, lease: lease, bootstrapGrant: root.grant)
            _ = try await f.repository.executeContinuityBootstrapRetrieval(grant: root.grant, invocationID: root.intent.invocationID, lease: lease) { expected in
                let actual = try source.continuityHandoffRevision(identity: expected.identity, authorization: expected.authorization)
                return try .init(canonicalToolResultJSON: ForgeJSONCanonicalizationV1.data(from: ["ok":true,"is_error":false,"payload":[
                    "ok":true,"found":true,"packet":JSONSerialization.jsonObject(with: actual.canonicalPacketJSON),
                    "continuity_id":actual.identity.continuityID,"revision":actual.identity.revision,"packet_sha256":actual.identity.packetSHA256]]))
            }
            let second = try await Self.bootstrapRoot(repository: f.repository, acceptance: ingress, envelope: envelope, lease: lease)
            do {
                _ = try await f.repository.persistToolInvocationIntent(second.intent, lease: lease, bootstrapGrant: second.grant, bootstrapPolicy: enlarged)
                XCTFail("Increased current policy lifted original six-call ceiling")
            } catch { XCTAssertTrue(error is ContinuityIngressError || error is NativeTaskCapabilityError) }
            XCTAssertEqual(try JournalSQL.value(f.database, "SELECT COUNT(*) FROM tool_invocations"), "1")
            await f.repository.close()
            let reopened = try ProjectControlPlaneRepository(databaseURL: f.database, clock: f.clock)
            do {
                _ = try await reopened.persistToolInvocationIntent(root.intent, lease: lease, bootstrapGrant: root.grant, bootstrapPolicy: enlarged)
                let readRetained = try await reopened.nativeSourceBudgetCarryover(runID: ingress.runID)
                let retained = try XCTUnwrap(readRetained)
                let currentTools = Int(try JournalSQL.value(f.database, "SELECT COUNT(*) FROM tool_invocations")) ?? -100
                XCTAssertEqual(retained.priorSourceReadCallsAtEnrollment + retained.admittedProviderCalls + currentTools, 6)
                XCTAssertEqual(retained, offset)
                await reopened.close()
            } catch { await reopened.close(); throw error }
        }
    }

    func testRuntimeMigrationRecognizesOnlyExactSourcePreflightLedgerVariant() async throws {
        for variant in ["exact", "missing_constraint", "extra_column", "partial_journal"] {
            try await withFixture { f in
                await f.repository.close()
                switch variant {
                case "missing_constraint":
                    try JournalSQL.execute(f.database, """
                        ALTER TABLE provider_turns DROP COLUMN source_preflight_sha256;
                        ALTER TABLE provider_turns DROP COLUMN source_preflight_json;
                        ALTER TABLE provider_turns ADD COLUMN source_preflight_json TEXT;
                        ALTER TABLE provider_turns ADD COLUMN source_preflight_sha256 TEXT;
                        """)
                case "extra_column":
                    try JournalSQL.execute(f.database, "ALTER TABLE provider_turns ADD COLUMN private_extension TEXT")
                case "partial_journal":
                    try JournalSQL.execute(f.database, "DROP TABLE native_source_provider_run_offsets")
                default: break
                }
                let bytes = try Data(contentsOf: f.database)
                if variant == "exact" {
                    let jobs = try RuntimeJobRepository(databaseURL: f.database)
                    XCTAssertEqual(try JournalSQL.value(f.database, "SELECT version FROM runtime_job_schema_version"), "5")
                    XCTAssertEqual(try JournalSQL.value(f.database, "SELECT COUNT(*) FROM native_source_conversations"), "1")
                    await jobs.close()
                    let manifest = try JSONDecoder().decode(VerifiedMigrationBackupManifest.self,
                        from: Data(contentsOf: VerifiedMigrationBackup.activeManifestURL(for: f.database)))
                    XCTAssertEqual(manifest.sourceVersion, 0); XCTAssertEqual(manifest.targetVersion, 5)
                    XCTAssertEqual(manifest.state, .completed)
                    let backup = f.database.deletingLastPathComponent().appendingPathComponent(manifest.backupFilename)
                    XCTAssertEqual(JSONSupport.sha256Hex(try Data(contentsOf: backup)), manifest.backupSHA256)
                    XCTAssertEqual(try JournalSQL.value(backup,
                        "SELECT COUNT(*) FROM pragma_table_info('provider_turns') WHERE name LIKE 'source_preflight_%'"), "2")
                } else {
                    do {
                        let jobs = try RuntimeJobRepository(databaseURL: f.database)
                        await jobs.close(); XCTFail("Malformed source ledger became runtime baseline: \(variant)")
                    } catch { XCTAssertTrue(error is RuntimeJobError) }
                    XCTAssertEqual(try Data(contentsOf: f.database), bytes)
                    XCTAssertEqual(try JournalSQL.value(f.database,
                        "SELECT COUNT(*) FROM sqlite_master WHERE name='runtime_job_schema_version'"), "0")
                }
            }
        }
    }

    private static func commitWire(_ commit: ContinuityHandoffCommit) throws -> Data {
        try ForgeJSONCanonicalizationV1.data(from: ["ok":true,"is_error":false,"payload":[
            "ok":true,"continuity_id":commit.revision.identity.continuityID,"revision":commit.revision.identity.revision,
            "packet_sha256":commit.revision.identity.packetSHA256]])
    }
    static func bootstrapRoot(repository: ProjectControlPlaneRepository, acceptance: ContinuityIngressAcceptanceReceipt,
        envelope: ContinuitySourceBootstrapEnvelope, lease: RunLease) async throws -> (grant: ContinuityBootstrapGrant,intent: ToolInvocationIntent) {
        let grant = try await repository.issueContinuityBootstrapGrant(envelope: envelope, candidateID: UUID(), lease: lease)
        let session = ProviderSessionIntent(sessionID: grant.sessionID, runID: acceptance.runID, projectID: acceptance.authorization.projectID,
            projectGeneration: .initial, providerID: "lmstudio", adapterID: "forge.native-session-host", modelKey: "fixture/native",
            handoffID: envelope.handoffID, operationID: acceptance.operationID, idempotencyKey: "root-" + grant.sessionID,
            bootstrapNonceSHA256: JSONSupport.sha256Hex(envelope.bootstrapNonce.uuidString.lowercased()),
            handoffSHA256: envelope.envelopeSHA256, status: .candidate, accepted: false)
        try await repository.reserveProviderSession(session, lease: lease, bootstrapGrant: grant)
        let intent = ProviderTurnIntent(runID: acceptance.runID, sessionID: grant.sessionID, operationID: acceptance.operationID,
            projectID: acceptance.authorization.projectID, projectGeneration: .initial, kind: .bootstrap,
            idempotencyKey: "bootstrap-" + grant.sessionID, inputSHA256: String(repeating: "a", count: 64), toolSchemaSHA256: String(repeating: "b", count: 64))
        _ = try await repository.persistProviderTurnIntent(intent, lease: lease, bootstrapGrant: grant)
        do {
            _ = try await repository.transitionProviderTurn(turnID: intent.turnID, expected: .intent, to: .submitted, lease: lease, bootstrapGrant: grant)
            XCTFail("Source-derived turn bypassed immutable preflight submission")
        } catch { XCTAssertTrue(error is AutonomyError) }
        let provider = LMStudioManagedModelProvider(transport: try LMStudioManagedSessionTransport(configuration:
            .init(baseURL: URL(string: "http://127.0.0.1:1")!, modelKey: "fixture/native", maximumOutputTokens: 64)))
        let request = try ProviderRootRequest(operationID: intent.turnID, idempotencyKey: intent.idempotencyKey,
            modelKey: "fixture/native", input: "Restore exact source", tools: [])
        let preflight = try await provider.preflightRoot(request)
        let caps = try ProviderCapabilities(providerID: "lmstudio", providerVersion: "fixture", modelKey: "fixture/native",
            providerInstanceID: "fixture-instance", contextLength: 262_144, maximumContextLength: 262_144,
            statefulResponses: true, streaming: false, customTools: true, mcp: false, structuredOutput: false,
            usageReporting: true, idempotencyLookup: true, capabilityFingerprintSHA256: String(repeating: "a", count: 64))
        guard case .dispatch = try await repository.beginSourceDerivedProviderTurn(intent: intent, preflight: preflight,
            capabilities: caps, lease: lease, bootstrapGrant: grant) else { throw JournalFixtureError.interrupted }
        let call = try ProviderToolCall(callID: "retrieve-" + grant.sessionID, name: "context_get",
            argumentsJSON: ForgeJSONCanonicalizationV1.data(from: ["handoff_id":acceptance.source.identity.continuityID]))
        let turn = try ProviderTurn(requestID: "request-" + grant.sessionID, responseID: "response-" + grant.sessionID,
            providerID: "lmstudio", providerVersion: "fixture", modelKey: "fixture/native", messages: [], toolCalls: [call],
            usage: nil, completed: true, finishReason: .toolCalls)
        _ = try await repository.transitionProviderTurn(turnID: intent.turnID, expected: .submitted, to: .completed,
            lease: lease, providerRequestID: turn.requestID, providerResponseID: turn.responseID, bootstrapGrant: grant)
        try await repository.recordContinuityBootstrapProviderResult(grant: grant, turnID: intent.turnID, result: turn, lease: lease)
        return (grant,.init(turnID: intent.turnID, runID: acceptance.runID, sessionID: grant.sessionID,
            projectID: acceptance.authorization.projectID, projectGeneration: .initial, providerCallID: call.callID,
            toolName: call.name, replayClass: .readOnly, idempotencyKey: nil, argumentsSHA256: JSONSupport.sha256Hex(call.argumentsJSON)))
    }

    private func withFixture(priorReads: Int = 0, toolLimit: Int = 64, _ body: (JournalFixture) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-source-journal-\(UUID())").resolvingSymlinksInPath()
        let project = root.appendingPathComponent("project"), database = root.appendingPathComponent("control.sqlite3")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let clock = JournalClock(), repository = try ProjectControlPlaneRepository(databaseURL: database, clock: clock), projectID = ProjectID()
        do {
            _ = try await repository.registerProjectUnchecked(projectID: projectID, displayName: "Source journal", canonicalRoot: project)
            let approval = try NativeContinuityTaskApproval(assignmentID: "source-journal", assignmentBytes: Data("immutable document marker".utf8),
                mission: "Read the approved source fixture", providerID: "lmstudio", adapterID: "forge.native-session-host", modelKey: "fixture/native",
                allowedTools: ["fs_read"], completionGates: ["G04"], resourceProfile: .automatic, filesystemAccess: "read_only", networkAllowed: false,
                maximumInlineOutputBytes: 65_536, sourceLimits: .init(maximumCalls: 64, maximumResultBytes: 65_536, maximumRequestSeconds: 30))
            let scope = ToolAuthorizationScope(canonicalRoots: [project], writableRoots: [], allowedTools: ["fs_read"], networkAllowed: false, maximumInlineOutputBytes: 65_536)
            let assignment = try ContinuityTaskAssignment(assignmentID: approval.assignmentID, assignmentBytes: approval.assignmentBytes,
                mission: approval.mission, providerID: approval.providerID, adapterID: approval.adapterID, modelKey: approval.modelKey,
                specification: .init(allowedTools: approval.allowedTools, completionGates: approval.completionGates), authorizationScope: scope)
            let credential = try NativeTaskCapabilityCredential(capabilityID: UUID(), epoch: 1, secret: Data(repeating: 17, count: 32)), taskID = UUID()
            let request = try NativeContinuityTaskPreparationRequest(requestID: UUID(), taskID: taskID, capabilityID: credential.capabilityID,
                projectID: projectID, projectGeneration: .initial, approval: approval, verifierSHA256: credential.verifier.sha256,
                expiresAt: ISO8601.string(from: clock.now().addingTimeInterval(86_400)))
            _ = try await repository.prepareNativeContinuityTask(request: request, approvedAssignment: assignment)
            let attachment = try await repository.authenticateNativeTaskCapability(credential: credential)
            let policy = try BudgetPolicyState(globalPolicy: .init(tools: .init(callsPerTurn: min(8,toolLimit), callsPerSession: toolLimit, callsPerRun: toolLimit), automaticHandoffEnabled: true)).resolve(.init(kind: .projectOverride, projectID: projectID.description, projectGeneration: 1))
            for index in 0..<priorReads {
                let request = try NativeSourceReadRequest(key: .init(sessionID: UUID(), requestIDSHA256: JSONSupport.sha256Hex(Data("prior-\(index)".utf8))),
                    toolName: "fs_read", canonicalArgumentsJSON: ForgeJSONCanonicalizationV1.data(from: ["path":"fixture.txt"]), managerInstanceID: UUID())
                guard case .execute(let admission) = try await repository.admitContinuitySourceRead(request: request,
                    correlation: attachment.setup.correlation, context: attachment.context, owner: attachment.owner, policySelection: policy) else {
                    throw JournalFixtureError.interrupted
                }
                try await repository.beginContinuitySourceRead(admission: admission, policySelection: policy)
                _ = try await repository.completeContinuitySourceRead(admission: admission,
                    canonicalToolResultJSON: ForgeJSONCanonicalizationV1.data(from: ["ok":true,"is_error":false,"payload":["text":"prior source read"]]), policySelection: policy)
            }
            let conversation = try await repository.enrollNativeSourceConversation(requestID: UUID(), taskID: taskID, credential: credential, policySelection: policy)
            let lease = try await repository.acquireNativeSourceConversationLease(conversationID: conversation.conversationID, credential: credential, managerInstanceID: UUID())
            let capabilities = try ProviderCapabilities(providerID: "lmstudio", providerVersion: "fixture-1", modelKey: "fixture/native",
                providerInstanceID: "fixture-instance", contextLength: 262_144, maximumContextLength: 262_144, statefulResponses: true, streaming: true,
                customTools: true, mcp: false, structuredOutput: true, usageReporting: true, idempotencyLookup: true,
                capabilityFingerprintSHA256: String(repeating: "a", count: 64))
            try await body(.init(database: database, repository: repository, clock: clock, credential: credential,
                attachment: attachment, policy: policy, taskID: taskID, lease: lease, capabilities: capabilities))
            await repository.close(); try FileManager.default.removeItem(at: root)
        } catch { await repository.close(); try? FileManager.default.removeItem(at: root); throw error }
    }
}

private enum JournalFixtureError: Error { case interrupted }
private struct JournalApproval { let preflight: ProviderRequestPreflight; let budget: NativeSourceProviderBudgetApproval }
private struct JournalFixture {
    let database: URL, repository: ProjectControlPlaneRepository, clock: JournalClock
    let credential: NativeTaskCapabilityCredential, attachment: AuthenticatedContinuityTaskAttachment, policy: BudgetPolicySelection
    let taskID: UUID, lease: NativeSourceConversationLease, capabilities: ProviderCapabilities
    func prepare(requestID: UUID = UUID()) async throws -> NativeSourcePreparedTurn {
        let names: Set<String> = ["fs_read","session_checkpoint","session_handoff"]
        let tools = try ToolDefinitionCatalog.production(toolNames: names.sorted()).providerToolDefinitions(allowedToolNames: names)
        return try await repository.prepareNativeSourceProviderTurn(request: .init(requestID: requestID,
            conversationID: lease.conversationID, userInput: "read fixture"), credential: credential, lease: lease, tools: tools)
    }
    func preflight(_ prepared: NativeSourcePreparedTurn) async throws -> ProviderRequestPreflight {
        let provider = LMStudioManagedModelProvider(transport: try LMStudioManagedSessionTransport(configuration:
            .init(baseURL: URL(string: "http://127.0.0.1:1")!, modelKey: "fixture/native", maximumOutputTokens: 64)))
        switch prepared.request {
        case .root(let request): return try await provider.preflightRoot(request)
        case .continuation(let request): return try await provider.preflightContinuation(request)
        }
    }
    func approval(_ prepared: NativeSourcePreparedTurn) async throws -> JournalApproval {
        let preflight = try await preflight(prepared)
        let check = try await repository.reserveNativeSourceCapabilityCheck(prepared: prepared, preflight: preflight, credential: credential, lease: lease)
        try await repository.finishNativeSourceCapabilityCheck(claim: check, capabilities: capabilities, outcome: .completed, credential: credential, lease: lease)
        let configuration = try PersistedManagedRunBudgetEvaluator.configuration(capabilities: capabilities, selection: policy)
        let retained = try ContextBudgetMath.estimateTokens(serializedBytes: preflight.bodyByteCount, policy: ContextBudgetPolicy())
        let reserve = try configuration.reserves.fixedTotal()
        let ceilings = NativeSourceBudgetCeilings(effectiveContextTokens: configuration.capacity.capacity,
            maximumOutputTokens: preflight.limits.maximumOutputTokens, tools: policy.policy.tools, reserves: configuration.reserves,
            checkpointRatio: policy.policy.context.checkpointRatio, rolloverRatio: policy.policy.context.rolloverRatio, emergencyRatio: policy.policy.context.emergencyRatio)
        let accounting = try ContextBudgetAccounting(version: "admitted_total_v2", cut: "retained_input_before_next_operation",
            retainedInputTokens: retained, futureReserveTokens: reserve, resolvedPolicy: configuration.resolvedPolicy)
        return try .init(preflight: preflight, budget: .init(policySelection: policy, effectiveContextTokens: configuration.capacity.capacity,
            retainedInputTokens: retained, futureReserveTokens: reserve, limits: preflight.limits, ceilings: ceilings,
            accounting: accounting, source: .serializedEstimate, confidence: 0.65, action: .normal))
    }
    func begin(_ prepared: NativeSourcePreparedTurn, _ approval: JournalApproval) async throws -> NativeSourceProviderPostAdmission {
        try await repository.beginNativeSourceProviderPost(prepared: prepared, preflight: approval.preflight, capabilities: capabilities,
            budget: approval.budget, credential: credential, lease: lease)
    }
    func call(id: String) throws -> ProviderToolCall {
        try .init(callID: id, name: "fs_read", argumentsJSON: ForgeJSONCanonicalizationV1.data(from: ["path":"fixture.txt"]))
    }
    func turn(_ prepared: NativeSourcePreparedTurn, calls: [ProviderToolCall]) throws -> ProviderTurn {
        let parent: String?
        switch prepared.request { case .root: parent = nil; case .continuation(let r): parent = r.previousResponseID }
        return try .init(requestID: prepared.stageID.uuidString.lowercased(), responseID: "response-" + prepared.stageID.uuidString.lowercased(),
            previousResponseID: parent, providerID: capabilities.providerID, providerVersion: capabilities.providerVersion,
            modelKey: capabilities.modelKey, providerInstanceID: capabilities.providerInstanceID,
            messages: calls.isEmpty ? ["completed actual fixture turn"] : [], toolCalls: calls,
            usage: .init(capacity: 262_144, inputTokens: 1_000, outputTokens: 20, source: .providerExact, confidence: 1),
            completed: true, finishReason: calls.isEmpty ? .stop : .toolCalls)
    }
}
private final class JournalClock: Clock, @unchecked Sendable {
    private let lock = NSLock(); private var value = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); value.addTimeInterval(seconds); lock.unlock() }
}
private enum JournalSQL {
    static func execute(_ url: URL, _ sql: String) throws { try connection(url) { guard sqlite3_exec($0, sql, nil, nil, nil) == SQLITE_OK else { throw JournalFixtureError.interrupted } } }
    static func value(_ url: URL, _ sql: String) throws -> String {
        try connection(url) { db in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw JournalFixtureError.interrupted }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { throw JournalFixtureError.interrupted }
            return String(cString: value)
        }
    }
    private static func connection<T>(_ url: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else { throw JournalFixtureError.interrupted }
        defer { sqlite3_close_v2(db) }; return try body(db)
    }
}

private final class JournalReadObservation: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    var called: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func record() { lock.lock(); value = true; lock.unlock() }
}
