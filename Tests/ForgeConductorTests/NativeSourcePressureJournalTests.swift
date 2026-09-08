import XCTest
import SQLite3
@testable import ForgeConductorCore
#if SWIFT_PACKAGE
import ForgeNativeSessionHostPlugin
#endif

final class NativeSourcePressureJournalTests: XCTestCase {
    func testReceiptCleanupChecksLineageBeforeDecodingRetainedPacket() async throws {
        try await withFixture { f in
            let (claim, admission) = try await f.preparedPressure()
            f.clock.advance(301)
            let reference = NativeSourcePressureRecoveryReference(conversationID: claim.conversationID, stageID: claim.stageID,
                taskID: claim.taskID, capabilityID: claim.capabilityID, reservationID: admission.reservationID)
            try PressureSQL.execute(f.database, "UPDATE continuity_source_dispatch_origins SET scope_sha256='\(String(repeating: "0", count: 64))'")
            try PressureSQL.execute(f.database, "UPDATE native_source_requests SET prepared_packet_json='corrupt'")
            do {
                _ = try await f.repository.acquireNativeSourcePressureReceiptClaim(reference: reference, managerInstanceID: UUID())
                XCTFail("Mismatched dispatch lineage reached retained packet decoding")
            } catch { XCTAssertEqual(error as? NativeSourceConversationError, .notFound) }
        }
    }

    func testReceiptCleanupExpiryAtCommitRollsBackAndNewOwnerFencesOldClaim() async throws {
        try await withFixture { f in
            let (_, admission) = try await f.preparedPressure()
            let store = try SQLiteStore(path: f.database.deletingLastPathComponent().appendingPathComponent("receipt-source.sqlite"), clock: f.clock)
            defer { store.close() }
            let actual = try store.handoffCommit(admission.prepared.packet(), authorization: admission.authorization, automaticHandoffEnabled: true)
            f.clock.advance(301)
            let references = try await f.repository.pendingNativeSourcePressureReceipts()
            let reference = try XCTUnwrap(references.first)
            let old = try await f.repository.acquireNativeSourcePressureReceiptClaim(reference: reference, managerInstanceID: UUID())
            await f.repository.configureOperationObservers(beforeCommit: { f.clock.advance(31) })
            do {
                _ = try await f.repository.reconcileNativeSourcePressureReceipt(claim: old,
                    readExisting: { try store.readPreparedSourceCommitForReconciliation($0, authorization: $1) })
                XCTFail("Expired cleanup committed its audit update")
            } catch { XCTAssertEqual(error as? NativeSourceConversationError, .leaseUnavailable) }
            await f.repository.configureOperationObservers()
            XCTAssertEqual(try PressureSQL.value(f.database, "SELECT state FROM native_source_requests"), "pending")
            let reopened = try ProjectControlPlaneRepository(databaseURL: f.database, clock: f.clock)
            do {
                let current = try await reopened.acquireNativeSourcePressureReceiptClaim(reference: reference, managerInstanceID: UUID())
                let staleRelease = try await f.repository.releaseNativeSourcePressureReceiptClaim(old)
                XCTAssertFalse(staleRelease)
                let called = PressureCallbackObservation()
                do {
                    _ = try await f.repository.reconcileNativeSourcePressureReceipt(claim: old,
                        readExisting: { _, _ in called.record(); return nil })
                    XCTFail("Stale cleanup owner reached the source")
                } catch { XCTAssertEqual(error as? NativeSourceConversationError, .leaseUnavailable) }
                XCTAssertFalse(called.called)
                let recovered = try await reopened.reconcileNativeSourcePressureReceipt(claim: current,
                    readExisting: { try store.readPreparedSourceCommitForReconciliation($0, authorization: $1) })
                XCTAssertEqual(recovered?.revision.identity, actual.revision.identity)
                _ = try await reopened.releaseNativeSourcePressureReceiptClaim(current)
                await reopened.close()
            } catch { await reopened.close(); throw error }
        }
    }

    func testReceiptCleanupAfterCancellationRetainsExistingSourceWithoutRestoringWork() async throws {
        try await withFixture { f in
            let (claim, admission) = try await f.preparedPressure()
            let store = try SQLiteStore(path: f.database.deletingLastPathComponent().appendingPathComponent("receipt-source.sqlite"), clock: f.clock)
            defer { store.close() }
            let actual = try store.handoffCommit(admission.prepared.packet(), authorization: admission.authorization,
                automaticHandoffEnabled: admission.automaticHandoffEnabled)
            let requestID = try UUID(uuidString: PressureSQL.value(f.database, "SELECT request_id FROM native_source_provider_turns"))
            _ = try await f.repository.requestNativeSourceConversationCancellation(conversationID: claim.conversationID,
                requestID: XCTUnwrap(requestID), cancelRequestID: UUID(), credential: f.credential)
            _ = try await f.repository.releaseNativeSourcePressureClaim(claim)
            let references = try await f.repository.pendingNativeSourcePressureReceipts()
            XCTAssertEqual(references.count, 1)
            let cleanup = try await f.repository.acquireNativeSourcePressureReceiptClaim(reference: XCTUnwrap(references.first), managerInstanceID: UUID())
            let recovered = try await f.repository.reconcileNativeSourcePressureReceipt(claim: cleanup,
                readExisting: { try store.readPreparedSourceCommitForReconciliation($0, authorization: $1) })
            XCTAssertEqual(recovered?.revision.identity, actual.revision.identity)
            XCTAssertEqual(try PressureSQL.value(f.database, "SELECT cancelled FROM native_source_conversations"), "1")
            XCTAssertEqual(try PressureSQL.value(f.database, "SELECT state FROM native_source_conversations"), "stopped")
            XCTAssertEqual(try PressureSQL.value(f.database, "SELECT state FROM native_source_provider_turns"), "accepted")
            XCTAssertEqual(try PressureSQL.value(f.database, "SELECT state FROM native_source_requests"), "completed")
            let replay = try await f.repository.reconcileNativeSourcePressureReceipt(claim: cleanup,
                readExisting: { _, _ in throw PressureFixtureError.interrupted })
            XCTAssertEqual(try NativeSourceCommitEvidence.encode(XCTUnwrap(replay)), try NativeSourceCommitEvidence.encode(actual))
            _ = try await f.repository.releaseNativeSourcePressureReceiptClaim(cleanup)
            do {
                _ = try await f.repository.acquireNativeSourcePressureClaim(conversationID: claim.conversationID,
                    stageID: claim.stageID, credential: f.credential, managerInstanceID: UUID())
                XCTFail("Receipt cleanup restored cancelled execution")
            } catch { XCTAssertEqual(error as? NativeSourceConversationError, .cancelled) }
        }
    }

    func testReceiptCleanupAfterStorageExpiryReadsInvalidatedRevisionAndPreservesDeadline() async throws {
        try await withFixture { f in
            let (_, admission) = try await f.preparedPressure()
            let store = try SQLiteStore(path: f.database.deletingLastPathComponent().appendingPathComponent("receipt-source.sqlite"), clock: f.clock)
            defer { store.close() }
            _ = try store.handoffCommit(admission.prepared.packet(), authorization: admission.authorization,
                automaticHandoffEnabled: true)
            _ = try store.invalidateContinuityIngress(projectID: admission.authorization.projectID,
                throughGeneration: admission.authorization.projectGeneration)
            let deadline = try PressureSQL.value(f.database, "SELECT deadline FROM native_source_requests")
            f.clock.advance(301)
            let references = try await f.repository.pendingNativeSourcePressureReceipts()
            let cleanup = try await f.repository.acquireNativeSourcePressureReceiptClaim(reference: XCTUnwrap(references.first), managerInstanceID: UUID())
            let recovered = try await f.repository.reconcileNativeSourcePressureReceipt(claim: cleanup,
                readExisting: { try store.readPreparedSourceCommitForReconciliation($0, authorization: $1) })
            XCTAssertEqual(recovered?.revision.canonicalPacketJSON, admission.prepared.canonicalPacketJSON)
            XCTAssertEqual(try PressureSQL.value(f.database, "SELECT deadline FROM native_source_requests"), deadline)
            XCTAssertEqual(try PressureSQL.value(f.database, "SELECT state FROM native_source_conversations"), "stopped")
            XCTAssertEqual(try PressureSQL.value(f.database, "SELECT COUNT(*) FROM native_source_provider_calls"), "0")
            _ = try await f.repository.releaseNativeSourcePressureReceiptClaim(cleanup)
        }
    }

    func testReceiptCleanupAfterCapabilityRevocationUsesNoBearerGrant() async throws {
        try await withFixture { f in
            let (claim, admission) = try await f.preparedPressure()
            let store = try SQLiteStore(path: f.database.deletingLastPathComponent().appendingPathComponent("receipt-source.sqlite"), clock: f.clock)
            defer { store.close() }
            let actual = try store.handoffCommit(admission.prepared.packet(), authorization: admission.authorization, automaticHandoffEnabled: true)
            let revoke = try NativeContinuityTaskRevocationRequest(requestID: UUID(), taskID: f.taskID,
                capabilityID: f.credential.capabilityID, projectID: admission.authorization.projectID,
                projectGeneration: admission.authorization.projectGeneration, expectedEpoch: f.credential.epoch)
            _ = try await f.repository.revokeNativeContinuityTask(request: revoke)
            _ = try await f.repository.releaseNativeSourcePressureClaim(claim)
            let references = try await f.repository.pendingNativeSourcePressureReceipts()
            let cleanup = try await f.repository.acquireNativeSourcePressureReceiptClaim(reference: XCTUnwrap(references.first), managerInstanceID: UUID())
            let recovered = try await f.repository.reconcileNativeSourcePressureReceipt(claim: cleanup,
                readExisting: { try store.readPreparedSourceCommitForReconciliation($0, authorization: $1) })
            XCTAssertEqual(recovered?.revision.identity, actual.revision.identity)
            XCTAssertEqual(try PressureSQL.value(f.database, "SELECT state FROM native_task_capabilities"), "revoked")
            XCTAssertEqual(try PressureSQL.value(f.database, "SELECT COUNT(*) FROM native_task_capabilities WHERE verifier_sha256 IS NOT NULL"), "0")
            _ = try await f.repository.releaseNativeSourcePressureReceiptClaim(cleanup)
        }
    }

    func testReceiptCleanupDistinguishesUnavailableStoreFromAbsentCommit() async throws {
        try await withFixture { f in
            let (_, admission) = try await f.preparedPressure()
            f.clock.advance(301)
            let refs = try await f.repository.pendingNativeSourcePressureReceipts()
            let reference = try XCTUnwrap(refs.first)
            let cleanup = try await f.repository.acquireNativeSourcePressureReceiptClaim(reference: reference, managerInstanceID: UUID())
            do {
                _ = try await f.repository.reconcileNativeSourcePressureReceipt(claim: cleanup,
                    readExisting: { _, _ in throw PressureFixtureError.interrupted })
                XCTFail("Unavailable source was treated as an absent revision")
            } catch { XCTAssertEqual(error as? PressureFixtureError, .interrupted) }
            XCTAssertEqual(try PressureSQL.value(f.database, "SELECT quarantined FROM native_source_requests"), "0")
            let missing = try await f.repository.reconcileNativeSourcePressureReceipt(claim: cleanup, readExisting: { _, _ in nil })
            XCTAssertNil(missing)
            XCTAssertEqual(try PressureSQL.value(f.database, "SELECT quarantined FROM native_source_requests"), "1")
            XCTAssertEqual(try PressureSQL.value(f.database, "SELECT packet_sha256 FROM native_source_requests"), admission.prepared.packetSHA256)
            _ = try await f.repository.releaseNativeSourcePressureReceiptClaim(cleanup)
            let pending = try await f.repository.pendingNativeSourcePressureReceipts()
            XCTAssertTrue(pending.isEmpty)
        }
    }

    func testReceiptCleanupRejectsLiveWriterAndExpiredCleanupLease() async throws {
        try await withFixture { f in
            let (claim, admission) = try await f.preparedPressure()
            let reference = NativeSourcePressureRecoveryReference(conversationID: claim.conversationID, stageID: claim.stageID,
                taskID: claim.taskID, capabilityID: claim.capabilityID, reservationID: admission.reservationID)
            do {
                _ = try await f.repository.acquireNativeSourcePressureReceiptClaim(reference: reference, managerInstanceID: UUID())
                XCTFail("Receipt cleanup acquired live write authority")
            } catch { XCTAssertEqual(error as? NativeSourceConversationError, .conflict) }
            f.clock.advance(301)
            let cleanup = try await f.repository.acquireNativeSourcePressureReceiptClaim(reference: reference, managerInstanceID: UUID())
            f.clock.advance(31)
            let called = PressureCallbackObservation()
            do {
                _ = try await f.repository.reconcileNativeSourcePressureReceipt(claim: cleanup,
                    readExisting: { _, _ in called.record(); return nil })
                XCTFail("Expired cleanup lease reached the source")
            } catch { XCTAssertEqual(error as? NativeSourceConversationError, .leaseUnavailable) }
            XCTAssertFalse(called.called)
        }
    }

    func testPressureSourceCommitRetainsActualReceiptAfterLateCancellation() async throws {
        try await withFixture { f in
            let (claim, admission) = try await f.preparedPressure()
            let store = try SQLiteStore(path: f.database.deletingLastPathComponent().appendingPathComponent("pressure-source.sqlite"), clock: f.clock)
            defer { store.close() }
            let cancellation = ToolCallCancellation()
            guard case .commit(let attempt) = try await f.repository.beginNativeSourcePressureCommitAttempt(admission: admission,
                claim: claim, credential: f.credential, policySelection: f.policy,
                readExisting: { try store.readPreparedSourceCommitForReconciliation($0, authorization: $1) }) else {
                return XCTFail("Missing source write attempt")
            }
            let committed = try await f.repository.commitNativeSourceBudgetHandoff(attempt: attempt, claim: claim,
                credential: f.credential, policySelection: f.policy,
                readExisting: { try store.readPreparedSourceCommitForReconciliation($0, authorization: $1) },
                commit: { prepared, auth, automatic in
                    let actual = try store.handoffCommit(prepared.packet(), authorization: auth, automaticHandoffEnabled: automatic)
                    cancellation.cancel()
                    return actual
                }, cancellation: cancellation)
            XCTAssertNotNil(committed.delivery)
            XCTAssertEqual(try PressureSQL.value(f.database, "SELECT state FROM native_source_requests"), "completed")
            XCTAssertEqual(try PressureSQL.value(f.database, "SELECT blocked_code FROM native_source_provider_turns"), "pressure_committed")
            let replay = try await f.repository.commitNativeSourceBudgetHandoff(attempt: attempt, claim: claim,
                credential: f.credential, policySelection: f.policy,
                readExisting: { _, _ in throw PressureFixtureError.interrupted },
                commit: { _, _, _ in throw PressureFixtureError.interrupted })
            XCTAssertEqual(replay.revision.identity, committed.revision.identity)
            XCTAssertEqual(try NativeSourceCommitEvidence.encode(replay), try NativeSourceCommitEvidence.encode(committed))
        }
    }

    func testPressureReceiptReadbackClosesSourceCommitToControlPlaneCrashWindow() async throws {
        try await withFixture { f in
            let (claim, admission) = try await f.preparedPressure()
            let store = try SQLiteStore(path: f.database.deletingLastPathComponent().appendingPathComponent("pressure-source.sqlite"), clock: f.clock)
            defer { store.close() }
            guard case .commit(let attempt) = try await f.repository.beginNativeSourcePressureCommitAttempt(admission: admission,
                claim: claim, credential: f.credential, policySelection: f.policy,
                readExisting: { try store.readPreparedSourceCommitForReconciliation($0, authorization: $1) }) else {
                return XCTFail("Missing source write attempt")
            }
            let written = PressureCallbackObservation()
            await f.repository.configureOperationObservers(beforeCommit: { if written.called { throw PressureFixtureError.interrupted } })
            do {
                _ = try await f.repository.commitNativeSourceBudgetHandoff(attempt: attempt, claim: claim,
                    credential: f.credential, policySelection: f.policy,
                    readExisting: { try store.readPreparedSourceCommitForReconciliation($0, authorization: $1) },
                    commit: {
                        let actual = try store.handoffCommit($0.packet(), authorization: $1, automaticHandoffEnabled: $2)
                        written.record()
                        return actual
                    })
                XCTFail("Expected CP commit interruption")
            } catch { XCTAssertEqual(error as? PressureFixtureError, .interrupted) }
            let actual = try XCTUnwrap(store.readPreparedSourceCommitForReconciliation(admission.prepared, authorization: admission.authorization))
            XCTAssertEqual(try PressureSQL.value(f.database, "SELECT state FROM native_source_requests"), "pending")
            await f.repository.close()
            let reopened = try ProjectControlPlaneRepository(databaseURL: f.database, clock: f.clock)
            do {
                guard case .completed(let recovered) = try await reopened.beginNativeSourcePressureCommitAttempt(admission: admission,
                    claim: claim, credential: f.credential, policySelection: f.policy,
                    readExisting: { try store.readPreparedSourceCommitForReconciliation($0, authorization: $1) }) else {
                    throw PressureFixtureError.interrupted
                }
                XCTAssertEqual(try NativeSourceCommitEvidence.encode(recovered), try NativeSourceCommitEvidence.encode(actual))
                XCTAssertEqual(try PressureSQL.value(f.database, "SELECT recovery_attempts FROM native_source_requests"), "1")
                XCTAssertEqual(try PressureSQL.value(f.database, "SELECT state FROM native_source_requests"), "completed")
                await reopened.close()
            } catch { await reopened.close(); throw error }
        }
    }

    func testPressureDeliveryOptOutIsFrozenBeforeWriteAndNeverReenabled() async throws {
        try await withFixture { f in
            let (claim, admission) = try await f.preparedPressure()
            let store = try SQLiteStore(path: f.database.deletingLastPathComponent().appendingPathComponent("pressure-source.sqlite"), clock: f.clock)
            defer { store.close() }
            let disabled = try BudgetPolicyState(globalPolicy: .init(context: f.policy.policy.context,
                tools: f.policy.policy.tools, automaticHandoffEnabled: false)).resolve(f.policy.scope)
            guard case .commit(let attempt) = try await f.repository.beginNativeSourcePressureCommitAttempt(admission: admission,
                claim: claim, credential: f.credential, policySelection: disabled,
                readExisting: { try store.readPreparedSourceCommitForReconciliation($0, authorization: $1) }) else {
                return XCTFail("Missing opted-out attempt")
            }
            XCTAssertEqual(try PressureSQL.value(f.database, "SELECT automatic_enabled FROM native_source_requests"), "0")
            let committed = try await f.repository.commitNativeSourceBudgetHandoff(attempt: attempt, claim: claim,
                credential: f.credential, policySelection: f.policy,
                readExisting: { try store.readPreparedSourceCommitForReconciliation($0, authorization: $1) },
                commit: { try store.handoffCommit($0.packet(), authorization: $1, automaticHandoffEnabled: $2) })
            XCTAssertTrue(committed.revision.resumeReady)
            XCTAssertNil(committed.delivery)
            XCTAssertEqual(committed.revision.canonicalPacketJSON, admission.prepared.canonicalPacketJSON)
            XCTAssertEqual(try PressureSQL.value(f.database, "SELECT automatic_enabled FROM native_source_requests"), "0")
        }
    }

    func testPressureStorageAttemptsAreBoundedAndStaleAttemptCannotWrite() async throws {
        try await withFixture { f in
            let (claim, admission) = try await f.preparedPressure()
            guard case .commit(let first) = try await f.repository.beginNativeSourcePressureCommitAttempt(admission: admission,
                claim: claim, credential: f.credential, policySelection: f.policy, readExisting: { _, _ in nil }) else {
                return XCTFail("Missing first attempt")
            }
            for _ in 2...8 {
                _ = try await f.repository.beginNativeSourcePressureCommitAttempt(admission: admission,
                    claim: claim, credential: f.credential, policySelection: f.policy, readExisting: { _, _ in nil })
            }
            do {
                _ = try await f.repository.beginNativeSourcePressureCommitAttempt(admission: admission,
                    claim: claim, credential: f.credential, policySelection: f.policy, readExisting: { _, _ in nil })
                XCTFail("Pressure storage exceeded its durable attempt budget")
            } catch { XCTAssertEqual(error as? NativeSourceConversationError, .capacityExceeded) }
            let called = PressureCallbackObservation()
            do {
                _ = try await f.repository.commitNativeSourceBudgetHandoff(attempt: first, claim: claim,
                    credential: f.credential, policySelection: f.policy, readExisting: { _, _ in nil },
                    commit: { _, _, _ in called.record(); throw PressureFixtureError.interrupted })
                XCTFail("Stale storage attempt reached its writer")
            } catch { XCTAssertEqual(error as? NativeSourceConversationError, .conflict) }
            XCTAssertFalse(called.called)
            XCTAssertEqual(try PressureSQL.value(f.database, "SELECT recovery_attempts FROM native_source_requests"), "8")
        }
    }

    func testConsumedPressureAttemptCannotRepeatItsWriterAfterFailure() async throws {
        try await withFixture { f in
            let (claim, admission) = try await f.preparedPressure()
            guard case .commit(let attempt) = try await f.repository.beginNativeSourcePressureCommitAttempt(admission: admission,
                claim: claim, credential: f.credential, policySelection: f.policy, readExisting: { _, _ in nil }) else {
                return XCTFail("Missing attempt")
            }
            do {
                _ = try await f.repository.commitNativeSourceBudgetHandoff(attempt: attempt, claim: claim,
                    credential: f.credential, policySelection: f.policy, readExisting: { _, _ in nil },
                    commit: { _, _, _ in throw PressureFixtureError.interrupted })
                XCTFail("Expected interrupted source writer")
            } catch { XCTAssertEqual(error as? PressureFixtureError, .interrupted) }
            XCTAssertEqual(try PressureSQL.value(f.database, "SELECT error_code FROM native_source_requests"), "pressure_attempt_started")
            let called = PressureCallbackObservation()
            do {
                _ = try await f.repository.commitNativeSourceBudgetHandoff(attempt: attempt, claim: claim,
                    credential: f.credential, policySelection: f.policy, readExisting: { _, _ in nil },
                    commit: { _, _, _ in called.record(); throw PressureFixtureError.interrupted })
                XCTFail("Consumed attempt called its writer twice")
            } catch { XCTAssertEqual(error as? NativeSourceConversationError, .conflict) }
            XCTAssertFalse(called.called)
        }
    }

    func testDisabledPressureCommitCrashThenEnablePreservesAbsentDelivery() async throws {
        try await withFixture { f in
            let (claim, admission) = try await f.preparedPressure()
            let store = try SQLiteStore(path: f.database.deletingLastPathComponent().appendingPathComponent("pressure-source.sqlite"), clock: f.clock)
            defer { store.close() }
            let disabled = try BudgetPolicyState(globalPolicy: .init(context: f.policy.policy.context,
                tools: f.policy.policy.tools, automaticHandoffEnabled: false)).resolve(f.policy.scope)
            guard case .commit(let attempt) = try await f.repository.beginNativeSourcePressureCommitAttempt(admission: admission,
                claim: claim, credential: f.credential, policySelection: disabled,
                readExisting: { try store.readPreparedSourceCommitForReconciliation($0, authorization: $1) }) else {
                return XCTFail("Missing disabled attempt")
            }
            let written = PressureCallbackObservation()
            await f.repository.configureOperationObservers(beforeCommit: { if written.called { throw PressureFixtureError.interrupted } })
            do {
                _ = try await f.repository.commitNativeSourceBudgetHandoff(attempt: attempt, claim: claim,
                    credential: f.credential, policySelection: disabled,
                    readExisting: { try store.readPreparedSourceCommitForReconciliation($0, authorization: $1) },
                    commit: {
                        let actual = try store.handoffCommit($0.packet(), authorization: $1, automaticHandoffEnabled: $2)
                        written.record()
                        return actual
                    })
                XCTFail("Expected receipt commit interruption")
            } catch { XCTAssertEqual(error as? PressureFixtureError, .interrupted) }
            await f.repository.configureOperationObservers()
            guard case .completed(let recovered) = try await f.repository.beginNativeSourcePressureCommitAttempt(admission: admission,
                claim: claim, credential: f.credential, policySelection: f.policy,
                readExisting: { try store.readPreparedSourceCommitForReconciliation($0, authorization: $1) }) else {
                return XCTFail("Recovery attempted another source write")
            }
            XCTAssertNil(recovered.delivery)
            XCTAssertEqual(try PressureSQL.value(f.database, "SELECT automatic_enabled FROM native_source_requests"), "0")
            XCTAssertEqual(try PressureSQL.value(f.database, "SELECT recovery_attempts FROM native_source_requests"), "1")
            XCTAssertEqual(try PressureSQL.value(f.database, "SELECT state FROM native_source_conversations"), "source_fenced")
        }
    }

    func testPressureReadbackFailureCannotAuthorizeWriteOrConsumeAttempt() async throws {
        try await withFixture { f in
            let (claim, admission) = try await f.preparedPressure()
            do {
                _ = try await f.repository.beginNativeSourcePressureCommitAttempt(admission: admission,
                    claim: claim, credential: f.credential, policySelection: f.policy,
                    readExisting: { _, _ in throw PressureFixtureError.interrupted })
                XCTFail("Failed source lookup was treated as absence")
            } catch { XCTAssertEqual(error as? PressureFixtureError, .interrupted) }
            XCTAssertEqual(try PressureSQL.value(f.database, "SELECT recovery_attempts FROM native_source_requests"), "0")
        }
    }

    func testPressurePreparationFreezesOneExactUnchargedSourceIntent() async throws {
        try await withFixture { f in
            let context = try await f.pressureContext()
            guard case .pressure(let claim) = try await f.repository.recordNativeSourceBudgetDisposition(
                metadata: f.pressureMetadata(context), credential: f.credential, lease: f.lease, policySelection: f.policy) else {
                return XCTFail("Missing pressure claim")
            }
            guard case .commit(let first) = try await f.repository.prepareNativeSourceBudgetHandoff(claim: claim,
                credential: f.credential, policySelection: f.policy, responsePreflight: { try PressureFixture.responsePreflight($0) }) else {
                return XCTFail("Missing frozen pressure handoff")
            }
            XCTAssertTrue(first.prepared.finalize)
            XCTAssertTrue(first.automaticHandoffEnabled)
            let packet = try first.prepared.packet()
            XCTAssertTrue(packet.resumeSeed.contains("Retained source progress"))
            XCTAssertTrue(packet.resumeSeed.contains("read fixture"))
            XCTAssertTrue(packet.resumeSeed.contains("immutable document marker"))
            XCTAssertEqual(try PressureSQL.value(f.database, "SELECT COUNT(*) FROM native_source_requests"), "1")
            XCTAssertEqual(try PressureSQL.value(f.database, "SELECT SUM(charged_calls) FROM native_source_requests"), "0")
            XCTAssertEqual(try PressureSQL.value(f.database, "SELECT COUNT(*) FROM native_source_provider_calls"), "0")
            XCTAssertEqual(try PressureSQL.value(f.database, "SELECT pressure_reservation_id FROM native_source_provider_turns"), first.reservationID.uuidString.lowercased())
            let pending = try await f.repository.pendingNativeSourceCommits()
            XCTAssertTrue(pending.isEmpty, "Generic recovery must not acquire a pressure request")
            let before = try PressureSQL.snapshot(f.database)
            guard case .commit(let replay) = try await f.repository.prepareNativeSourceBudgetHandoff(claim: claim,
                credential: f.credential, policySelection: f.policy, responsePreflight: { _ in throw PressureFixtureError.interrupted }) else {
                return XCTFail("Missing exact preparation replay")
            }
            XCTAssertEqual(replay.prepared, first.prepared)
            XCTAssertEqual(replay.reservationID, first.reservationID)
            XCTAssertEqual(try PressureSQL.snapshot(f.database), before)
            try await f.repository.releaseNativeSourceConversationLease(lease: f.lease)
            _ = try await f.repository.nativeSourcePressureDisposition(claim: claim, credential: f.credential)
        }
    }

    func testPressurePacketRetainsCompletedReadAndUntouchedCallWithoutRefundingEither() async throws {
        try await withFixture(priorReads: 2) { f in
            let prepared = try await f.prepare()
            let approval = try await f.approval(prepared)
            guard case .dispatch(let dispatch) = try await f.begin(prepared, approval) else { return XCTFail("Missing dispatch") }
            let actual = try f.turn(prepared, calls: [f.call(id: "completed-read"), f.call(id: "untouched-read")])
            let accepted = try await f.repository.acceptNativeSourceProviderTurn(claim: dispatch, turn: actual,
                credential: f.credential, lease: f.lease)
            try await f.finishRead(accepted.calls[0], approval)
            let context = try await f.repository.nativeSourceAcceptedBudgetContext(stageID: prepared.stageID,
                credential: f.credential, lease: f.lease)
            let tightened = try BudgetPolicyState(globalPolicy: .init(context: .init(checkpointRatio: 0.001,
                rolloverRatio: 0.002, emergencyRatio: 0.003), tools: f.policy.policy.tools,
                automaticHandoffEnabled: true)).resolve(f.policy.scope)
            guard case .pressure(let pressure) = NativeSourceBudgetEvaluator.acceptedDecision(context: context, policySelection: tightened),
                  case .pressure(let claim) = try await f.repository.recordNativeSourceBudgetDisposition(metadata: .pressure(pressure),
                    credential: f.credential, lease: f.lease, policySelection: tightened),
                  case .commit(let admission) = try await f.repository.prepareNativeSourceBudgetHandoff(claim: claim,
                    credential: f.credential, policySelection: tightened, responsePreflight: { try PressureFixture.responsePreflight($0) }) else {
                return XCTFail("Completed-prefix pressure did not prepare a handoff")
            }
            let seed = try admission.prepared.packet().resumeSeed
            XCTAssertTrue(seed.contains("completed-read"))
            XCTAssertTrue(seed.contains("retained read output"))
            XCTAssertTrue(seed.contains("untouched-read"))
            XCTAssertEqual(try PressureSQL.value(f.database, "SELECT COUNT(*) FROM native_source_requests WHERE method='fs_read'"), "3")
            XCTAssertEqual(try PressureSQL.value(f.database, "SELECT COUNT(*) FROM native_source_provider_calls"), "2")
            XCTAssertEqual(try PressureSQL.value(f.database, "SELECT COUNT(*) FROM native_source_provider_calls WHERE output_json IS NOT NULL"), "1")
            XCTAssertEqual(try PressureSQL.value(f.database, "SELECT COUNT(*) FROM native_source_provider_calls WHERE reservation_id IS NULL"), "1")
        }
    }

    func testPressurePreparationCancellationAtCommitLeavesNoReservation() async throws {
        try await withFixture { f in
            let context = try await f.pressureContext()
            guard case .pressure(let claim) = try await f.repository.recordNativeSourceBudgetDisposition(
                metadata: f.pressureMetadata(context), credential: f.credential, lease: f.lease, policySelection: f.policy) else {
                return XCTFail("Missing pressure claim")
            }
            let before = try PressureSQL.snapshot(f.database)
            let cancellation = ToolCallCancellation()
            await f.repository.configureOperationObservers(beforeCommit: { cancellation.cancel() })
            do {
                _ = try await f.repository.prepareNativeSourceBudgetHandoff(claim: claim, credential: f.credential,
                    policySelection: f.policy, responsePreflight: { try PressureFixture.responsePreflight($0) }, cancellation: cancellation)
                XCTFail("Cancelled preparation retained a source reservation")
            } catch { XCTAssertTrue(error is CancellationError) }
            await f.repository.configureOperationObservers()
            XCTAssertEqual(try PressureSQL.snapshot(f.database), before)
        }
    }

    func testRecordedPressureRecomputesActualUsageAndFencesOrdinaryLease() async throws {
        try await withFixture { f in
            let context = try await f.pressureContext()
            let metadata = try f.pressureMetadata(context)
            let intent = try PressureSQL.value(f.database, "SELECT intent_json FROM native_source_provider_turns")
            let result = try PressureSQL.value(f.database, "SELECT result_sha256 FROM native_source_provider_turns")
            guard case .pressure(let claim) = try await f.repository.recordNativeSourceBudgetDisposition(
                metadata: metadata, credential: f.credential, lease: f.lease, policySelection: f.policy) else {
                return XCTFail("Actual retained pressure did not produce a storage claim")
            }
            let stored = try await f.repository.nativeSourcePressureDisposition(claim: claim, credential: f.credential)
            XCTAssertEqual(try stored.metadata.canonicalJSON(), try metadata.canonicalJSON())
            XCTAssertEqual(stored.fenceRevision, context.binding.conversationRevision + 1)
            XCTAssertEqual(try PressureSQL.value(f.database, "SELECT intent_json FROM native_source_provider_turns"), intent)
            XCTAssertEqual(try PressureSQL.value(f.database, "SELECT result_sha256 FROM native_source_provider_turns"), result)
            XCTAssertEqual(try PressureSQL.value(f.database, "SELECT state FROM native_source_provider_turns"), "accepted")
            XCTAssertEqual(try PressureSQL.value(f.database, "SELECT COUNT(*) FROM native_source_requests"), "0")
            do {
                _ = try await f.repository.renewNativeSourceConversationLease(lease: f.lease, credential: f.credential)
                XCTFail("Ordinary inference lease survived pressure")
            } catch { XCTAssertEqual(error as? NativeSourceConversationError, .sourceFenced) }
            let beforeReplay = try PressureSQL.snapshot(f.database)
            guard case .pressure(let replay) = try await f.repository.recordNativeSourceBudgetDisposition(
                metadata: metadata, credential: f.credential, lease: f.lease, policySelection: f.policy) else {
                return XCTFail("Exact pressure replay failed")
            }
            XCTAssertEqual(replay.dispositionSHA256, claim.dispositionSHA256)
            XCTAssertEqual(replay.storageDeadline, claim.storageDeadline)
            XCTAssertEqual(try PressureSQL.snapshot(f.database), beforeReplay)
            try await f.repository.releaseNativeSourceConversationLease(lease: f.lease)
            let afterOrdinaryRelease = try await f.repository.nativeSourcePressureDisposition(claim: claim, credential: f.credential)
            XCTAssertEqual(afterOrdinaryRelease.fenceRevision, stored.fenceRevision)
        }
    }

    func testPressureRecoveryUsesOneDeadlineAndRejectsStaleOwner() async throws {
        try await withFixture { f in
            let context = try await f.pressureContext()
            guard case .pressure(let first) = try await f.repository.recordNativeSourceBudgetDisposition(
                metadata: f.pressureMetadata(context), credential: f.credential, lease: f.lease, policySelection: f.policy) else {
                return XCTFail("Missing pressure claim")
            }
            f.clock.advance(31)
            await f.repository.close()
            let reopened = try ProjectControlPlaneRepository(databaseURL: f.database, clock: f.clock)
            do {
                let recovered = try await reopened.acquireNativeSourcePressureClaim(conversationID: first.conversationID,
                    stageID: first.stageID, credential: f.credential, managerInstanceID: UUID())
                XCTAssertEqual(recovered.storageDeadline, first.storageDeadline)
                XCTAssertEqual(recovered.dispositionSHA256, first.dispositionSHA256)
                XCTAssertEqual(recovered.leaseEpoch, first.leaseEpoch + 1)
                do {
                    _ = try await reopened.nativeSourcePressureDisposition(claim: first, credential: f.credential)
                    XCTFail("Old owner read through new storage ownership")
                } catch { XCTAssertEqual(error as? NativeSourceConversationError, .leaseUnavailable) }
                let oldRelease = try await reopened.releaseNativeSourcePressureClaim(first)
                XCTAssertFalse(oldRelease)
                f.clock.advance(10)
                let renewed = try await reopened.renewNativeSourcePressureClaim(claim: recovered, credential: f.credential)
                XCTAssertEqual(renewed.storageDeadline, first.storageDeadline)
                XCTAssertGreaterThan(renewed.expiresAt, recovered.expiresAt)
                _ = try await reopened.releaseNativeSourcePressureClaim(renewed)
                f.clock.advance(260)
                do {
                    _ = try await reopened.acquireNativeSourcePressureClaim(conversationID: first.conversationID,
                        stageID: first.stageID, credential: f.credential, managerInstanceID: UUID())
                    XCTFail("Recovery minted a new pressure deadline")
                } catch { XCTAssertEqual(error as? NativeSourceConversationError, .deadlineExceeded) }
                await reopened.close()
            } catch { await reopened.close(); throw error }
        }
    }

    func testAlteredPressureObservationCannotMintFence() async throws {
        try await withFixture { f in
            let context = try await f.pressureContext()
            let metadata = try f.pressureMetadata(context)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: metadata.canonicalJSON()) as? [String: Any])
            var pressure = try XCTUnwrap(object["pressure"] as? [String: Any])
            pressure["reason"] = "observedContextOverflow"
            object["pressure"] = pressure
            XCTAssertThrowsError(try NativeSourceBudgetMetadata.storedSnapshot(from:
                ForgeJSONCanonicalizationV1.data(from: object)))
            let lower = try BudgetPolicyState(globalPolicy: .init(context: .init(maxContextTokens: 16_384),
                automaticHandoffEnabled: true)).resolve(f.policy.scope)
            let before = try PressureSQL.snapshot(f.database)
            do {
                _ = try await f.repository.recordNativeSourceBudgetDisposition(metadata: metadata,
                    credential: f.credential, lease: f.lease, policySelection: lower)
                XCTFail("Stale numerical policy was trusted")
            } catch { XCTAssertEqual(error as? NativeSourceConversationError, .conflict) }
            XCTAssertEqual(try PressureSQL.snapshot(f.database), before)
        }
    }

    func testPendingPressureCancellationPreservesProviderFactsAndStopsStorage() async throws {
        try await withFixture { f in
            let context = try await f.pressureContext()
            guard case .pressure(let claim) = try await f.repository.recordNativeSourceBudgetDisposition(
                metadata: f.pressureMetadata(context), credential: f.credential, lease: f.lease, policySelection: f.policy) else {
                return XCTFail("Missing pressure claim")
            }
            let metadata = try PressureSQL.value(f.database, "SELECT pressure_decision_json FROM native_source_provider_turns")
            _ = try await f.repository.requestNativeSourceConversationCancellation(conversationID: claim.conversationID,
                requestID: context.accepted.prepared.requestID, cancelRequestID: UUID(), credential: f.credential)
            XCTAssertEqual(try PressureSQL.value(f.database, "SELECT cancelled FROM native_source_conversations"), "1")
            XCTAssertEqual(try PressureSQL.value(f.database, "SELECT state FROM native_source_provider_turns"), "accepted")
            XCTAssertEqual(try PressureSQL.value(f.database, "SELECT pressure_decision_json FROM native_source_provider_turns"), metadata)
            do {
                _ = try await f.repository.nativeSourcePressureDisposition(claim: claim, credential: f.credential)
                XCTFail("Cancellation allowed pressure storage")
            } catch { XCTAssertEqual(error as? NativeSourceConversationError, .cancelled) }
            let released = try await f.repository.releaseNativeSourcePressureClaim(claim)
            XCTAssertTrue(released)
        }
    }

    func testPressureFenceRollsBackWhenLeaseExpiresAtCommit() async throws {
        try await withFixture { f in
            let context = try await f.pressureContext()
            let metadata = try f.pressureMetadata(context)
            let before = try PressureSQL.snapshot(f.database)
            await f.repository.configureOperationObservers(beforeCommit: { [clock = f.clock] in clock.advance(31) })
            do {
                _ = try await f.repository.recordNativeSourceBudgetDisposition(metadata: metadata,
                    credential: f.credential, lease: f.lease, policySelection: f.policy)
                XCTFail("An expired owner committed a pressure fence")
            } catch { XCTAssertEqual(error as? NativeSourceConversationError, .leaseUnavailable) }
            await f.repository.configureOperationObservers()
            XCTAssertEqual(try PressureSQL.snapshot(f.database), before)
            XCTAssertEqual(try PressureSQL.value(f.database,
                "SELECT COUNT(*) FROM native_source_provider_turns WHERE pressure_decision_json IS NOT NULL"), "0")
        }
    }

    func testPressureFenceCancellationAtCommitRollsBackAllChanges() async throws {
        try await withFixture { f in
            let context = try await f.pressureContext()
            let metadata = try f.pressureMetadata(context)
            let before = try PressureSQL.snapshot(f.database)
            let cancellation = ToolCallCancellation()
            await f.repository.configureOperationObservers(beforeCommit: { cancellation.cancel() })
            do {
                _ = try await f.repository.recordNativeSourceBudgetDisposition(metadata: metadata,
                    credential: f.credential, lease: f.lease, policySelection: f.policy, cancellation: cancellation)
                XCTFail("Cancelled pressure fence committed")
            } catch { XCTAssertTrue(error is CancellationError) }
            await f.repository.configureOperationObservers()
            XCTAssertEqual(try PressureSQL.snapshot(f.database), before)
            guard case .pressure = try await f.repository.recordNativeSourceBudgetDisposition(metadata: metadata,
                credential: f.credential, lease: f.lease, policySelection: f.policy) else {
                return XCTFail("Rolled-back pressure could not be recorded by a live caller")
            }
        }
    }

    func testPressureRecoveryCannotStealLiveOwnerAndRollsBackExpiredGrant() async throws {
        try await withFixture { f in
            let context = try await f.pressureContext()
            guard case .pressure(let claim) = try await f.repository.recordNativeSourceBudgetDisposition(
                metadata: f.pressureMetadata(context), credential: f.credential, lease: f.lease, policySelection: f.policy) else {
                return XCTFail("Missing pressure claim")
            }
            let before = try PressureSQL.snapshot(f.database)
            do {
                _ = try await f.repository.acquireNativeSourcePressureClaim(conversationID: claim.conversationID,
                    stageID: claim.stageID, credential: f.credential, managerInstanceID: UUID())
                XCTFail("Competing owner stole a live storage lease")
            } catch { XCTAssertEqual(error as? NativeSourceConversationError, .leaseUnavailable) }
            XCTAssertEqual(try PressureSQL.snapshot(f.database), before)
            f.clock.advance(31)
            await f.repository.configureOperationObservers(beforeCommit: { [clock = f.clock] in clock.advance(31) })
            do {
                _ = try await f.repository.acquireNativeSourcePressureClaim(conversationID: claim.conversationID,
                    stageID: claim.stageID, credential: f.credential, managerInstanceID: UUID())
                XCTFail("Recovery returned an already expired lease")
            } catch { XCTAssertEqual(error as? NativeSourceConversationError, .leaseUnavailable) }
            await f.repository.configureOperationObservers()
            XCTAssertEqual(try PressureSQL.snapshot(f.database), before)
        }
    }

    func testPreProviderPressureFencesWithoutDispatchAndPreservesIntent() async throws {
        try await withFixture { f in
            let prepared = try await f.prepare(userInput: String(repeating: "\u{1}", count: 16_000))
            let approval = try await f.approval(prepared)
            let current = try BudgetPolicyState(globalPolicy: .init(context: .init(mode: .manual, maxContextTokens: 16_384),
                automaticHandoffEnabled: true)).resolve(f.policy.scope)
            let binding = try await f.repository.nativeSourceBudgetBinding(stageID: prepared.stageID,
                boundary: .beforeProviderPost, credential: f.credential, lease: f.lease)
            let retained = try await f.repository.nativeSourcePreparedTurn(stageID: prepared.stageID,
                credential: f.credential, lease: f.lease)
            let decision = NativeSourceBudgetEvaluator.providerDecision(prepared: retained,
                preflight: approval.preflight, capabilities: f.capabilities, policySelection: current, binding: binding)
            let pressure: NativeSourcePressureDecision
            switch decision {
            case .pressure(let value): pressure = value
            case .blocked(let failure): return XCTFail("Pre-provider input was blocked: \(failure.code)")
            case .admitted(let approval): return XCTFail("Input admitted at \(approval.retainedInputTokens) retained tokens")
            }
            guard case .pressure(let claim) = try await f.repository.recordNativeSourceBudgetDisposition(
                metadata: .pressure(pressure), credential: f.credential, lease: f.lease, policySelection: current) else {
                return XCTFail("Verified pre-provider pressure did not persist")
            }
            let stored = try await f.repository.nativeSourcePressureDisposition(claim: claim, credential: f.credential)
            XCTAssertEqual(stored.binding.stageState, .prepared)
            XCTAssertEqual(stored.binding.intentSHA256, prepared.intentSHA256)
            XCTAssertNil(stored.binding.observedResult)
            XCTAssertEqual(try PressureSQL.value(f.database,
                "SELECT COUNT(*) FROM native_source_provider_turns WHERE post_json IS NOT NULL OR result_json IS NOT NULL OR dispatch_nonce IS NOT NULL"), "0")
            XCTAssertEqual(try PressureSQL.value(f.database, "SELECT COUNT(*) FROM native_source_requests"), "0")
            do {
                _ = try await f.begin(prepared, approval)
                XCTFail("Fenced prepared request was allowed to dispatch")
            } catch { XCTAssertEqual(error as? NativeSourceConversationError, .conflict) }
            XCTAssertEqual(try PressureSQL.value(f.database,
                "SELECT COUNT(*) FROM native_source_provider_turns WHERE post_json IS NOT NULL OR dispatch_nonce IS NOT NULL"), "0")
            let originalIntent = try PressureSQL.value(f.database, "SELECT intent_json FROM native_source_provider_turns")
            _ = try await f.repository.requestNativeSourceConversationCancellation(conversationID: claim.conversationID,
                requestID: prepared.requestID, cancelRequestID: UUID(), credential: f.credential)
            XCTAssertEqual(try PressureSQL.value(f.database, "SELECT state FROM native_source_provider_turns"), "prepared")
            XCTAssertEqual(try PressureSQL.value(f.database, "SELECT intent_json FROM native_source_provider_turns"), originalIntent)
            do {
                _ = try await f.repository.nativeSourcePressureDisposition(claim: claim, credential: f.credential)
                XCTFail("Cancelled pre-provider pressure retained storage authority")
            } catch { XCTAssertEqual(error as? NativeSourceConversationError, .cancelled) }
        }
    }

    func testProviderQuotaBlockerHasNoPressureClaimOrStorageDeadline() async throws {
        try await withFixture(priorReads: 2) { f in
            let prepared = try await f.prepare()
            let approval = try await f.approval(prepared)
            let binding = try await f.repository.nativeSourceBudgetBinding(stageID: prepared.stageID,
                boundary: .beforeProviderPost, credential: f.credential, lease: f.lease)
            let current = try BudgetPolicyState(globalPolicy: .init(tools: .init(callsPerTurn: 1,
                callsPerSession: 1, callsPerRun: 1, maxInFlight: 1))).resolve(f.policy.scope)
            let retained = try await f.repository.nativeSourcePreparedTurn(stageID: prepared.stageID,
                credential: f.credential, lease: f.lease)
            guard case .blocked(let failure) = NativeSourceBudgetEvaluator.providerDecision(prepared: retained,
                preflight: approval.preflight, capabilities: f.capabilities, policySelection: current, binding: binding) else {
                return XCTFail("Expected quota blocker")
            }
            guard case .blocked(let stored) = try await f.repository.recordNativeSourceBudgetDisposition(
                metadata: .blocked(failure), credential: f.credential, lease: f.lease, policySelection: current) else {
                return XCTFail("Quota blocker created storage authority")
            }
            XCTAssertNil(stored.storageDeadline)
            XCTAssertEqual(failure.code, .toolQuotaExceeded)
            XCTAssertEqual(try PressureSQL.value(f.database, "SELECT state FROM native_source_provider_turns"), "prepared")
            XCTAssertEqual(try PressureSQL.value(f.database, "SELECT COUNT(*) FROM native_source_requests"), "2")
        }
    }

    func testSchemaEightUpgradePreservesLegacyIntentAndVerifiedBackup() async throws {
        try await withFixture { f in
            let prepared = try await f.prepare()
            let current = try PressureSQL.value(f.database, "SELECT intent_json FROM native_source_provider_turns")
            var old = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(current.utf8)) as? [String: Any])
            old.removeValue(forKey: "logicalInputVersion"); old.removeValue(forKey: "logicalInput")
            let legacy = try ForgeJSONCanonicalizationV1.data(from: old)
            await f.repository.close()
            try PressureSQL.replaceIntent(f.database, stageID: prepared.stageID, bytes: legacy)
            try PressureSQL.removePressureExtension(f.database)
            let before = try Data(contentsOf: f.database)
            let reopened = try ProjectControlPlaneRepository(databaseURL: f.database, clock: f.clock)
            do {
                XCTAssertEqual(try PressureSQL.value(f.database, "SELECT intent_json FROM native_source_provider_turns"), String(decoding: legacy, as: UTF8.self))
                XCTAssertEqual(try PressureSQL.value(f.database, "SELECT intent_sha256 FROM native_source_provider_turns"), JSONSupport.sha256Hex(legacy))
                let read = try await reopened.nativeSourceRequest(taskID: f.taskID, requestID: prepared.requestID,
                    expectedUserInput: "read fixture", credential: f.credential)
                XCTAssertEqual(read?.stageID, prepared.stageID)
                let manifest = try JSONDecoder().decode(VerifiedMigrationBackupManifest.self,
                    from: Data(contentsOf: VerifiedMigrationBackup.activeManifestURL(for: f.database, scope: .continuityIngress)))
                XCTAssertEqual(manifest.sourceVersion, 8); XCTAssertEqual(manifest.targetVersion, 9)
                XCTAssertEqual(manifest.state, .completed)
                let backup = f.database.deletingLastPathComponent().appendingPathComponent(manifest.backupFilename)
                XCTAssertEqual(JSONSupport.sha256Hex(try Data(contentsOf: backup)), manifest.backupSHA256)
                XCTAssertEqual(try PressureSQL.value(backup, "SELECT intent_json FROM native_source_provider_turns"), String(decoding: legacy, as: UTF8.self))
                XCTAssertEqual(try PressureSQL.value(backup, "SELECT COUNT(*) FROM pragma_table_xinfo('native_source_provider_turns') WHERE name LIKE 'pressure_%'"), "0")
                XCTAssertNotEqual(try Data(contentsOf: f.database), before)
                await reopened.close()
                let again = try ProjectControlPlaneRepository(databaseURL: f.database, clock: f.clock)
                await again.close()
                XCTAssertEqual(JSONSupport.sha256Hex(try Data(contentsOf: backup)), manifest.backupSHA256)
                let jobs = try RuntimeJobRepository(databaseURL: f.database)
                await jobs.close()
                XCTAssertEqual(try PressureSQL.value(f.database, "SELECT version FROM runtime_job_schema_version"), "5")
            } catch { await reopened.close(); throw error }
        }
    }

    func testPreparedAndZeroCallBudgetReadsAreFactualAndReadOnly() async throws {
        try await withFixture(priorReads: 2) { f in
            let prepared = try await f.prepare()
            let initial = try await f.repository.nativeSourceBudgetBinding(stageID: prepared.stageID,
                boundary: .beforeProviderPost, credential: f.credential, lease: f.lease)
            XCTAssertEqual(initial.sourceReadCallsBeforeEnrollment, 2)
            XCTAssertEqual(initial.admittedProviderCallsBeforeStage, 0); XCTAssertEqual(initial.admittedCallsInStage, 0)
            XCTAssertEqual(initial.sourceMaximumCalls, 64); XCTAssertEqual(initial.stageOrdinal, 1)
            XCTAssertNil(initial.observedResult)
            let approval = try await f.approval(prepared)
            guard case .dispatch(let claim) = try await f.begin(prepared, approval) else { return XCTFail("Missing dispatch") }
            let actual = try ProviderTurn(requestID: prepared.stageID.uuidString.lowercased(), responseID: String(repeating: "r", count: 1_024),
                providerID: f.capabilities.providerID, providerVersion: f.capabilities.providerVersion, modelKey: f.capabilities.modelKey,
                providerInstanceID: f.capabilities.providerInstanceID, messages: [String(repeating: "/\u{1}", count: 1_024)],
                toolCalls: [], usage: nil, completed: true, finishReason: .stop)
            _ = try await f.repository.acceptNativeSourceProviderTurn(claim: claim, turn: actual, credential: f.credential, lease: f.lease)
            let before = try PressureSQL.snapshot(f.database)
            let context = try await f.repository.nativeSourceAcceptedBudgetContext(stageID: prepared.stageID,
                credential: f.credential, lease: f.lease)
            XCTAssertEqual(context.accepted.turn, actual)
            XCTAssertNil(context.accepted.turn.usage)
            XCTAssertEqual(context.binding.observedResult?.providerResponseID, actual.responseID)
            XCTAssertEqual(context.binding.completedOutputCount, 0); XCTAssertTrue(context.accepted.calls.isEmpty)
            XCTAssertGreaterThanOrEqual(context.retainedContextSerializedBytes, approval.preflight.bodyByteCount + (try JSONEncoder().encode(actual).count))
            XCTAssertEqual(try PressureSQL.snapshot(f.database), before)
            _ = try await f.prepare(requestID: UUID())
            do {
                _ = try await f.repository.nativeSourceAcceptedBudgetContext(stageID: prepared.stageID, credential: f.credential, lease: f.lease)
                XCTFail("Old answer became current pressure context")
            } catch { XCTAssertEqual(error as? NativeSourceConversationError, .conflict) }
        }
    }

    func testCallPrefixAndLogicalInputSurviveContinuationWithoutAnotherDebit() async throws {
        try await withFixture(priorReads: 2) { f in
            let prepared = try await f.prepare(), approval = try await f.approval(prepared)
            let body = try PressureSQL.value(f.database, "SELECT intent_json FROM native_source_provider_turns")
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
            XCTAssertEqual(object["logicalInput"] as? String, "read fixture")
            XCTAssertEqual(object["logicalInputVersion"] as? Int, 1)
            guard case .dispatch(let claim) = try await f.begin(prepared, approval) else { return XCTFail("Missing dispatch") }
            let accepted = try await f.repository.acceptNativeSourceProviderTurn(claim: claim,
                turn: f.turn(prepared, calls: [f.call(id: "first-original"), f.call(id: "second-original")]),
                credential: f.credential, lease: f.lease)
            do {
                _ = try await f.repository.nativeSourceBudgetBinding(stageID: prepared.stageID, boundary: .beforeToolOutput,
                    pendingCallOrdinal: 1, credential: f.credential, lease: f.lease)
                XCTFail("Unfinished prefix was skipped")
            } catch { XCTAssertEqual(error as? NativeSourceConversationError, .conflict) }
            try await f.finishRead(accepted.calls[0], approval)
            let binding = try await f.repository.nativeSourceBudgetBinding(stageID: prepared.stageID, boundary: .beforeToolOutput,
                pendingCallOrdinal: 1, credential: f.credential, lease: f.lease)
            XCTAssertEqual(binding.completedOutputCount, 1)
            XCTAssertEqual(binding.pendingCall?.providerCallID, "second-original")
            XCTAssertEqual(binding.sourceReadCallsBeforeEnrollment, 2)
            XCTAssertEqual(binding.admittedCallsInStage, 2)
            let call = try await f.repository.resolveNativeSourceProviderCall(reference: accepted.calls[1], credential: f.credential, lease: f.lease)
            XCTAssertEqual(binding.completedOutputsSHA256, call.priorOutputsSHA256)
            let before = try PressureSQL.snapshot(f.database)
            _ = try await f.repository.nativeSourceAcceptedBudgetContext(stageID: prepared.stageID, credential: f.credential, lease: f.lease)
            XCTAssertEqual(try PressureSQL.snapshot(f.database), before)
            try await f.finishRead(accepted.calls[1], approval)
            let next = try await f.repository.prepareNativeSourceToolContinuation(acceptedStageID: prepared.stageID,
                credential: f.credential, lease: f.lease)
            let nextJSON = try PressureSQL.value(f.database, "SELECT intent_json FROM native_source_provider_turns WHERE ordinal=2")
            let nextObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(nextJSON.utf8)) as? [String: Any])
            XCTAssertEqual(nextObject["logicalInput"] as? String, object["logicalInput"] as? String)
            XCTAssertEqual(nextObject["logicalInputSHA"] as? String, object["logicalInputSHA"] as? String)
            let nextBinding = try await f.repository.nativeSourceBudgetBinding(stageID: next.stageID,
                boundary: .beforeProviderPost, credential: f.credential, lease: f.lease)
            XCTAssertEqual(nextBinding.admittedProviderCallsBeforeStage, 2)
            XCTAssertEqual(nextBinding.admittedCallsInStage, 0)
            XCTAssertEqual(nextBinding.observedResult?.stageID, prepared.stageID)
        }
    }

    func testUnknownOrExpiredLeaseCannotMintBudgetBinding() async throws {
        try await withFixture { f in
            let prepared = try await f.prepare(), approval = try await f.approval(prepared)
            guard case .dispatch(let claim) = try await f.begin(prepared, approval) else { return XCTFail("Missing dispatch") }
            do {
                _ = try await f.repository.nativeSourceBudgetBinding(stageID: prepared.stageID,
                    boundary: .beforeProviderPost, credential: f.credential, lease: f.lease)
                XCTFail("Submitted request became a local pressure boundary")
            } catch { XCTAssertEqual(error as? NativeSourceConversationError, .conflict) }
            try await f.repository.recordNativeSourceProviderOutcome(claim: claim, outcome: .unknown)
            let before = try PressureSQL.snapshot(f.database)
            do {
                _ = try await f.repository.nativeSourceAcceptedBudgetContext(stageID: prepared.stageID, credential: f.credential, lease: f.lease)
                XCTFail("Unknown POST became accepted context")
            } catch { XCTAssertEqual(error as? NativeSourceConversationError, .conflict) }
            XCTAssertEqual(try PressureSQL.snapshot(f.database), before)
            f.clock.advance(31)
            do {
                _ = try await f.repository.nativeSourceBudgetBinding(stageID: prepared.stageID,
                    boundary: .beforeProviderPost, credential: f.credential, lease: f.lease)
                XCTFail("Expired lease disclosed a binding")
            } catch { XCTAssertEqual(error as? NativeSourceConversationError, .leaseUnavailable) }
        }
    }

    func testReadyHandoffCannotOmitOriginalReadDebitAfterPolicyTightens() async throws {
        try await withFixture(priorReads: 2) { f in
            let prepared = try await f.prepare(), approval = try await f.approval(prepared)
            guard case .dispatch(let claim) = try await f.begin(prepared, approval) else { return XCTFail("Missing dispatch") }
            let readyCall = try ProviderToolCall(callID: "actual-ready-call", name: "session_handoff",
                argumentsJSON: ForgeJSONCanonicalizationV1.data(from: ["goal":"Continue the approved work"]))
            let accepted = try await f.repository.acceptNativeSourceProviderTurn(claim: claim,
                turn: f.turn(prepared, calls: [readyCall]), credential: f.credential, lease: f.lease)
            let reference = try XCTUnwrap(accepted.calls.first)
            let call = try await f.repository.resolveNativeSourceProviderCall(reference: reference, credential: f.credential, lease: f.lease)
            let binding = try await f.repository.nativeSourceBudgetBinding(stageID: prepared.stageID, boundary: .beforeToolOutput,
                pendingCallOrdinal: 0, credential: f.credential, lease: f.lease)
            XCTAssertEqual(binding.sourceReadCallsBeforeEnrollment, 2)
            XCTAssertEqual(binding.admittedCallsInStage, 1)
            let lowered = try BudgetPolicyState(globalPolicy: .init(tools: .init(callsPerTurn: 2,
                callsPerSession: 2, callsPerRun: 2))).resolve(f.policy.scope)
            let budget = try NativeSourceProviderOutputBudget(conversationID: reference.conversationID, stageID: reference.stageID,
                callOrdinal: reference.ordinal, configurationFingerprintSHA256: approval.preflight.configurationFingerprintSHA256,
                priorOutputsSHA256: call.priorOutputsSHA256, maximumCanonicalToolResultBytes: 1_048_576,
                maximumEscapedPayloadBytes: 524_288, maximumResultTokens: 1_048_576)
            let request = try NativeSourceCommitRequest(key: call.key, canonicalArgumentsJSON: call.canonicalArgumentsJSON,
                managerInstanceID: f.lease.managerInstanceID, finalize: true)
            let callback = PressureCallbackObservation()
            let before = try PressureSQL.snapshot(f.database)
            do {
                _ = try await f.repository.prepareContinuitySourceCommit(request: request,
                    correlation: f.attachment.setup.correlation, context: f.attachment.context, owner: f.attachment.owner,
                    policySelection: lowered, prepare: { _ in callback.record(); throw PressureFixtureError.interrupted },
                    reference: reference, credential: f.credential, lease: f.lease, outputBudget: budget,
                    validatePreparedOutput: { _ in }, encodeResult: { _ in throw PressureFixtureError.interrupted })
                XCTFail("Ready handoff ignored the original read debit")
            } catch { XCTAssertEqual(error as? NativeSourceConversationError, .budgetExceeded) }
            XCTAssertFalse(callback.called, "Source prepare must not run after source total3 exceeds the current cap2")
            XCTAssertEqual(try PressureSQL.snapshot(f.database), before)
            XCTAssertEqual(try PressureSQL.value(f.database, "SELECT COUNT(*) FROM native_source_requests WHERE method='session_handoff'"), "0")
        }
    }

    func testReadyHandoffAtExactQuotaCountsProviderReadOnlyOnce() async throws {
        for priorReads in [1, 2] {
            try await withFixture(priorReads: priorReads) { f in
                let prepared = try await f.prepare(), approval = try await f.approval(prepared)
                guard case .dispatch(let claim) = try await f.begin(prepared, approval) else { return XCTFail("Missing dispatch") }
                let ready = try ProviderToolCall(callID: "ready-at-exact-quota", name: "session_handoff",
                    argumentsJSON: ForgeJSONCanonicalizationV1.data(from: ["goal":"Continue the approved work"]))
                let calls: [ProviderToolCall]
                if priorReads == 1 { calls = [try f.call(id: "provider-read-before-ready"), ready] }
                else { calls = [ready] }
                let accepted = try await f.repository.acceptNativeSourceProviderTurn(claim: claim,
                    turn: f.turn(prepared, calls: calls), credential: f.credential, lease: f.lease)
                if priorReads == 1 { try await f.finishRead(XCTUnwrap(accepted.calls.first), approval) }
                let reference = try XCTUnwrap(accepted.calls.last)
                let call = try await f.repository.resolveNativeSourceProviderCall(reference: reference, credential: f.credential, lease: f.lease)
                let binding = try await f.repository.nativeSourceBudgetBinding(stageID: prepared.stageID, boundary: .beforeToolOutput,
                    pendingCallOrdinal: reference.ordinal, credential: f.credential, lease: f.lease)
                XCTAssertEqual(binding.sourceReadCallsBeforeEnrollment + binding.admittedProviderCallsBeforeStage + binding.admittedCallsInStage, 3)
                XCTAssertEqual(try PressureSQL.value(f.database, "SELECT COUNT(*) FROM native_source_requests WHERE method='fs_read'"), "2")
                let exact = try BudgetPolicyState(globalPolicy: .init(tools: .init(callsPerTurn: 2,
                    callsPerSession: 3, callsPerRun: 3))).resolve(f.policy.scope)
                let budget = try NativeSourceProviderOutputBudget(conversationID: reference.conversationID, stageID: reference.stageID,
                    callOrdinal: reference.ordinal, configurationFingerprintSHA256: approval.preflight.configurationFingerprintSHA256,
                    priorOutputsSHA256: call.priorOutputsSHA256, maximumCanonicalToolResultBytes: 1_048_576,
                    maximumEscapedPayloadBytes: 524_288, maximumResultTokens: 1_048_576)
                let request = try NativeSourceCommitRequest(key: call.key, canonicalArgumentsJSON: call.canonicalArgumentsJSON,
                    managerInstanceID: f.lease.managerInstanceID, finalize: true)
                let callback = PressureCallbackObservation(), before = try PressureSQL.snapshot(f.database)
                do {
                    _ = try await f.repository.prepareContinuitySourceCommit(request: request,
                        correlation: f.attachment.setup.correlation, context: f.attachment.context, owner: f.attachment.owner,
                        policySelection: exact, prepare: { _ in callback.record(); throw PressureFixtureError.interrupted },
                        reference: reference, credential: f.credential, lease: f.lease, outputBudget: budget,
                        validatePreparedOutput: { _ in }, encodeResult: { _ in throw PressureFixtureError.interrupted })
                    XCTFail("Fixture callback should interrupt before source mutation")
                } catch { XCTAssertEqual(error as? PressureFixtureError, .interrupted) }
                XCTAssertTrue(callback.called, "Source total3 must remain eligible at the exact cap3")
                XCTAssertEqual(try PressureSQL.snapshot(f.database), before)
            }
        }
    }

    func testCallerAndStageMetadataRejectBeforeCorruptBodyDecode() async throws {
        try await withFixture { f in
            let prepared = try await f.prepare()
            let invalid = try NativeTaskCapabilityCredential(capabilityID: f.credential.capabilityID, epoch: 1, secret: Data(repeating: 99, count: 32))
            try PressureSQL.execute(f.database, "UPDATE native_source_provider_turns SET intent_json='corrupt',intent_sha256='" + String(repeating: "a", count: 64) + "'")
            do {
                _ = try await f.repository.nativeSourceBudgetBinding(stageID: prepared.stageID,
                    boundary: .beforeProviderPost, credential: invalid, lease: f.lease)
                XCTFail("Invalid credential reached corrupt body")
            } catch { XCTAssertEqual(error as? NativeTaskCapabilityError, .credentialRejected) }
            try PressureSQL.execute(f.database, "UPDATE native_source_provider_turns SET conversation_id='" + UUID().uuidString.lowercased() + "'")
            do {
                _ = try await f.repository.nativeSourceBudgetBinding(stageID: prepared.stageID,
                    boundary: .beforeProviderPost, credential: f.credential, lease: f.lease)
                XCTFail("Foreign stage exposed an integrity oracle")
            } catch { XCTAssertEqual(error as? NativeSourceConversationError, .notFound) }
        }
    }

    func testPartialAndUnknownPressureSchemasDoNotBecomeMigrationBaselines() async throws {
        for variant in ["partial", "extra", "index", "constraint", "trigger"] {
            try await withFixture { f in
                _ = try await f.prepare()
                await f.repository.close()
                switch variant {
                case "partial":
                    try PressureSQL.execute(f.database, "DROP INDEX native_source_pressure_reservation; ALTER TABLE native_source_provider_turns DROP COLUMN pressure_reservation_id")
                case "extra":
                    try PressureSQL.execute(f.database, "ALTER TABLE native_source_provider_turns ADD COLUMN unrelated_extension TEXT")
                case "index":
                    try PressureSQL.execute(f.database, "DROP INDEX native_source_pressure_reservation")
                case "constraint":
                    try PressureSQL.removePressureExtension(f.database)
                    try PressureSQL.execute(f.database, "ALTER TABLE native_source_provider_turns ADD COLUMN pressure_decision_json TEXT; ALTER TABLE native_source_provider_turns ADD COLUMN pressure_decision_sha256 TEXT; ALTER TABLE native_source_provider_turns ADD COLUMN pressure_reservation_id TEXT; " + NativeSourcePressureSchema.indexSQL)
                default:
                    try PressureSQL.execute(f.database, "CREATE TRIGGER extra_pressure_trigger AFTER UPDATE ON native_source_provider_turns BEGIN SELECT 1; END")
                }
                let before = try Data(contentsOf: f.database)
                do {
                    let opened = try ProjectControlPlaneRepository(databaseURL: f.database, clock: f.clock)
                    await opened.close(); XCTFail("Accepted malformed pressure schema: \(variant)")
                } catch { XCTAssertTrue(error is ProjectContextError) }
                XCTAssertEqual(try Data(contentsOf: f.database), before)
                do {
                    let jobs = try RuntimeJobRepository(databaseURL: f.database)
                    await jobs.close(); XCTFail("Malformed pressure schema became runtime baseline: \(variant)")
                } catch { XCTAssertTrue(error is RuntimeJobError) }
                XCTAssertEqual(try Data(contentsOf: f.database), before)
            }
        }
    }

    func testPressureColumnBoundsAndPairingRejectBeforeMutation() async throws {
        try await withFixture { f in
            _ = try await f.prepare()
            let before = try PressureSQL.snapshot(f.database)
            for sql in [
                "UPDATE native_source_provider_turns SET pressure_decision_json='{}'",
                "UPDATE native_source_provider_turns SET pressure_decision_sha256='" + String(repeating: "a", count: 64) + "'",
                "UPDATE native_source_provider_turns SET pressure_decision_json='{}',pressure_decision_sha256='" + String(repeating: "A", count: 64) + "'",
                "UPDATE native_source_provider_turns SET pressure_decision_json=printf('%.*c',32769,'x'),pressure_decision_sha256='" + String(repeating: "a", count: 64) + "'",
                "UPDATE native_source_provider_turns SET pressure_decision_json='[]',pressure_decision_sha256='" + String(repeating: "a", count: 64) + "'"
            ] { XCTAssertThrowsError(try PressureSQL.execute(f.database, sql)) }
            XCTAssertEqual(try PressureSQL.snapshot(f.database), before)
        }
    }

    func testVersionedInputRejectsMissingVersionAndChangedCriticalBytes() async throws {
        for variant in ["version", "text", "size"] {
            try await withFixture { f in
                let prepared = try await f.prepare()
                let raw = try PressureSQL.value(f.database, "SELECT intent_json FROM native_source_provider_turns")
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
                switch variant {
                case "version": object.removeValue(forKey: "logicalInputVersion")
                case "text": object["logicalInput"] = "changed pending input"
                default: object["logicalInput"] = String(repeating: "x", count: 16_385)
                }
                try PressureSQL.replaceIntent(f.database, stageID: prepared.stageID, bytes: ForgeJSONCanonicalizationV1.data(from: object))
                do {
                    _ = try await f.repository.nativeSourcePreparedTurn(stageID: prepared.stageID, credential: f.credential, lease: f.lease)
                    XCTFail("Invalid versioned logical input decoded")
                } catch { XCTAssertEqual(error as? NativeSourceConversationError, .integrityFailure) }
            }
        }
    }

    func testRetainedBudgetEnvelopeRequiresExactHashAndStopFence() async throws {
        try await withFixture { f in
            let prepared = try await f.prepare()
            let binding = try await f.repository.nativeSourceBudgetBinding(stageID: prepared.stageID,
                boundary: .beforeProviderPost, credential: f.credential, lease: f.lease)
            let envelope = try NativeSourceStoredBudgetDisposition(version: 1,
                metadata: .blocked(.init(binding: binding, code: .evaluationFailed, observation: nil)),
                fenceRevision: binding.conversationRevision + 1, recordedAt: ISO8601.string(from: f.clock.now()),
                storageDeadline: nil).validated()
            let bytes = try NativeSourceJournalCoding.encode(envelope, maximum: 32_768)
            let json = String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "'", with: "''")
            try PressureSQL.execute(f.database, "UPDATE native_source_provider_turns SET pressure_decision_json='" + json
                + "',pressure_decision_sha256='" + JSONSupport.sha256Hex(bytes) + "',blocked_code='source_budget_blocked'")
            do {
                _ = try await f.repository.nativeSourcePreparedTurn(stageID: prepared.stageID, credential: f.credential, lease: f.lease)
                XCTFail("Metadata without its stop fence decoded")
            } catch { XCTAssertEqual(error as? NativeSourceConversationError, .integrityFailure) }
            try PressureSQL.execute(f.database, "UPDATE native_source_conversations SET state='stopped',revision=revision+1")
            let retained = try await f.repository.nativeSourcePreparedTurn(stageID: prepared.stageID, credential: f.credential, lease: f.lease)
            XCTAssertEqual(retained.intentSHA256, prepared.intentSHA256)
            do {
                _ = try await f.repository.nativeSourceBudgetBinding(stageID: prepared.stageID,
                    boundary: .beforeProviderPost, credential: f.credential, lease: f.lease)
                XCTFail("Blocked disposition minted another evaluation binding")
            } catch { XCTAssertEqual(error as? NativeSourceConversationError, .conflict) }
            try PressureSQL.execute(f.database, "UPDATE native_source_provider_turns SET pressure_decision_sha256='" + String(repeating: "f", count: 64) + "'")
            do {
                _ = try await f.repository.nativeSourcePreparedTurn(stageID: prepared.stageID, credential: f.credential, lease: f.lease)
                XCTFail("Tampered budget receipt decoded")
            } catch { XCTAssertEqual(error as? NativeSourceConversationError, .integrityFailure) }
        }
    }

    func testRevokedCapabilityRejectsBudgetReadWithoutChangingJournal() async throws {
        try await withFixture { f in
            let prepared = try await f.prepare()
            _ = try await f.repository.revokeNativeContinuityTask(request: .init(requestID: UUID(), taskID: f.taskID,
                capabilityID: f.credential.capabilityID, projectID: f.attachment.descriptor.projectID,
                projectGeneration: f.attachment.descriptor.projectGeneration, expectedEpoch: 1))
            let before = try PressureSQL.snapshot(f.database)
            do {
                _ = try await f.repository.nativeSourceBudgetBinding(stageID: prepared.stageID,
                    boundary: .beforeProviderPost, credential: f.credential, lease: f.lease)
                XCTFail("Revoked capability disclosed a budget binding")
            } catch { XCTAssertEqual(error as? NativeTaskCapabilityError, .credentialRejected) }
            XCTAssertEqual(try PressureSQL.snapshot(f.database), before)
        }
    }

    func testBoundedPreflightTextRejectsNontextMalformedAndOversizedValues() async throws {
        try await withFixture { f in
            await f.repository.close()
            try VerifiedMigrationBackup.withNonMutatingSQLitePreflight(databaseURL: f.database) { candidate in
                let db = try XCTUnwrap(candidate)
                XCTAssertEqual(try db.text("SELECT 'source schema'"), "source schema")
                XCTAssertNil(try db.text("SELECT NULL"))
                XCTAssertThrowsError(try db.text("SELECT 9"))
                XCTAssertThrowsError(try db.text("SELECT x'ff'"))
                XCTAssertThrowsError(try db.text("SELECT CAST(x'ff' AS TEXT)"))
                XCTAssertThrowsError(try db.text("SELECT printf('%.*c',32769,'x')"))
                XCTAssertThrowsError(try db.text("SELECT 'a'", maximumBytes: 0))
            }
        }
    }

    private func withFixture(priorReads: Int = 0, toolLimit: Int = 64, _ body: (PressureFixture) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-source-journal-\(UUID())").resolvingSymlinksInPath()
        let project = root.appendingPathComponent("project"), database = root.appendingPathComponent("control.sqlite3")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let clock = PressureClock(), repository = try ProjectControlPlaneRepository(databaseURL: database, clock: clock), projectID = ProjectID()
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
                    throw PressureFixtureError.interrupted
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

private enum PressureFixtureError: Error, Equatable { case interrupted }
private final class PressureCallbackObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func record() { lock.lock(); value = true; lock.unlock() }
    var called: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
private struct PressureApproval { let preflight: ProviderRequestPreflight; let budget: NativeSourceProviderBudgetApproval }
private struct PressureFixture {
    let database: URL, repository: ProjectControlPlaneRepository, clock: PressureClock
    let credential: NativeTaskCapabilityCredential, attachment: AuthenticatedContinuityTaskAttachment, policy: BudgetPolicySelection
    let taskID: UUID, lease: NativeSourceConversationLease, capabilities: ProviderCapabilities
    func preparedPressure() async throws -> (NativeSourcePressureClaim, NativeSourcePressureCommitAdmission) {
        let context = try await pressureContext()
        guard case .pressure(let claim) = try await repository.recordNativeSourceBudgetDisposition(
            metadata: pressureMetadata(context), credential: credential, lease: lease, policySelection: policy),
              case .commit(let admission) = try await repository.prepareNativeSourceBudgetHandoff(claim: claim,
                credential: credential, policySelection: policy, responsePreflight: { try Self.responsePreflight($0) }) else {
            throw PressureFixtureError.interrupted
        }
        return (claim, admission)
    }
    static func responsePreflight(_ prepared: PreparedContinuitySourceCommit) throws -> Data {
        try ForgeJSONCanonicalizationV1.data(from: ["jsonrpc":"2.0", "id":"pressure-test", "result":["structuredContent":[
            "packet":JSONSerialization.jsonObject(with: prepared.canonicalPacketJSON),
            "packet_sha256":prepared.packetSHA256, "continuity_id":prepared.continuityID]]])
    }
    func pressureContext() async throws -> NativeSourceAcceptedBudgetContext {
        let prepared = try await prepare()
        let approval = try await approval(prepared)
        guard case .dispatch(let claim) = try await begin(prepared, approval) else {
            throw PressureFixtureError.interrupted
        }
        let turn = try ProviderTurn(requestID: prepared.stageID.uuidString.lowercased(),
            responseID: "pressure-response-" + prepared.stageID.uuidString.lowercased(),
            providerID: capabilities.providerID, providerVersion: capabilities.providerVersion,
            modelKey: capabilities.modelKey, providerInstanceID: capabilities.providerInstanceID,
            messages: ["Retained source progress"], toolCalls: [],
            usage: .init(capacity: 262_144, inputTokens: 240_000, outputTokens: 20, source: .providerExact, confidence: 1),
            completed: true, finishReason: .stop)
        _ = try await repository.acceptNativeSourceProviderTurn(claim: claim, turn: turn,
            credential: credential, lease: lease)
        return try await repository.nativeSourceAcceptedBudgetContext(stageID: prepared.stageID,
            credential: credential, lease: lease)
    }
    func pressureMetadata(_ context: NativeSourceAcceptedBudgetContext) throws -> NativeSourceBudgetMetadata {
        guard case .pressure(let value) = NativeSourceBudgetEvaluator.acceptedDecision(context: context, policySelection: policy) else {
            throw PressureFixtureError.interrupted
        }
        return .pressure(value)
    }
    func prepare(requestID: UUID = UUID(), userInput: String = "read fixture") async throws -> NativeSourcePreparedTurn {
        let names: Set<String> = ["fs_read","session_checkpoint","session_handoff"]
        let tools = try ToolDefinitionCatalog.production(toolNames: names.sorted()).providerToolDefinitions(allowedToolNames: names)
        return try await repository.prepareNativeSourceProviderTurn(request: .init(requestID: requestID,
            conversationID: lease.conversationID, userInput: userInput), credential: credential, lease: lease, tools: tools)
    }
    func preflight(_ prepared: NativeSourcePreparedTurn) async throws -> ProviderRequestPreflight {
        let provider = LMStudioManagedModelProvider(transport: try LMStudioManagedSessionTransport(configuration:
            .init(baseURL: URL(string: "http://127.0.0.1:1")!, modelKey: "fixture/native", maximumOutputTokens: 64)))
        switch prepared.request {
        case .root(let request): return try await provider.preflightRoot(request)
        case .continuation(let request): return try await provider.preflightContinuation(request)
        }
    }
    func approval(_ prepared: NativeSourcePreparedTurn) async throws -> PressureApproval {
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
    func begin(_ prepared: NativeSourcePreparedTurn, _ approval: PressureApproval) async throws -> NativeSourceProviderPostAdmission {
        try await repository.beginNativeSourceProviderPost(prepared: prepared, preflight: approval.preflight, capabilities: capabilities,
            budget: approval.budget, credential: credential, lease: lease)
    }
    func finishRead(_ reference: NativeSourceProviderCallReference, _ approval: PressureApproval) async throws {
        let call = try await repository.resolveNativeSourceProviderCall(reference: reference, credential: credential, lease: lease)
        let budget = try NativeSourceProviderOutputBudget(conversationID: reference.conversationID, stageID: reference.stageID,
            callOrdinal: reference.ordinal, configurationFingerprintSHA256: approval.preflight.configurationFingerprintSHA256,
            priorOutputsSHA256: call.priorOutputsSHA256, maximumCanonicalToolResultBytes: 65_536,
            maximumEscapedPayloadBytes: 393_216, maximumResultTokens: 4_096)
        let request = try NativeSourceReadRequest(key: call.key, toolName: call.toolName,
            canonicalArgumentsJSON: call.canonicalArgumentsJSON, managerInstanceID: lease.managerInstanceID)
        guard case .execute(let admission) = try await repository.admitContinuitySourceRead(request: request,
            correlation: attachment.setup.correlation, context: attachment.context, owner: attachment.owner,
            policySelection: policy, reference: reference, credential: credential, lease: lease, outputBudget: budget) else {
            throw PressureFixtureError.interrupted
        }
        try await repository.beginContinuitySourceRead(admission: admission, policySelection: policy,
            reference: reference, credential: credential, lease: lease, outputBudget: budget)
        _ = try await repository.completeContinuitySourceRead(admission: admission,
            canonicalToolResultJSON: ForgeJSONCanonicalizationV1.data(from: ["ok":true,"is_error":false,"payload":["text":"retained read output"]]),
            policySelection: policy, reference: reference, credential: credential, lease: lease, outputBudget: budget)
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
private final class PressureClock: Clock, @unchecked Sendable {
    private let lock = NSLock(); private var value = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); value.addTimeInterval(seconds); lock.unlock() }
}
private enum PressureSQL {
    static func removePressureExtension(_ url: URL) throws {
        try execute(url, """
            DROP INDEX native_source_pressure_reservation;
            ALTER TABLE native_source_provider_turns DROP COLUMN pressure_reservation_id;
            ALTER TABLE native_source_provider_turns DROP COLUMN pressure_decision_sha256;
            ALTER TABLE native_source_provider_turns DROP COLUMN pressure_decision_json;
            """)
    }
    static func replaceIntent(_ url: URL, stageID: UUID, bytes: Data) throws {
        try connection(url) { db in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "UPDATE native_source_provider_turns SET intent_json=?,intent_sha256=? WHERE stage_id=?", -1, &statement, nil) == SQLITE_OK,
                  let statement else { throw PressureFixtureError.interrupted }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            guard sqlite3_bind_text(statement, 1, String(decoding: bytes, as: UTF8.self), -1, transient) == SQLITE_OK,
                  sqlite3_bind_text(statement, 2, JSONSupport.sha256Hex(bytes), -1, transient) == SQLITE_OK,
                  sqlite3_bind_text(statement, 3, stageID.uuidString.lowercased(), -1, transient) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(db) == 1 else { throw PressureFixtureError.interrupted }
        }
    }
    static func snapshot(_ url: URL) throws -> String {
        try value(url, """
            SELECT json_object(
              'stages',(SELECT json_group_array(json_array(stage_id,intent_json,intent_sha256,state,post_json,post_sha256,result_json,result_sha256,dispatch_nonce,dispatch_owner,dispatch_epoch,blocked_code,pressure_decision_json,pressure_decision_sha256,pressure_reservation_id,reserved_bytes)) FROM native_source_provider_turns),
              'conversation',(SELECT json_group_array(json_array(conversation_id,state,revision,active_stage_id,parent_response_id,lease_owner,lease_epoch,lease_expires_at,ceilings_json)) FROM native_source_conversations),
              'calls',(SELECT json_group_array(json_array(stage_id,ordinal,call_sha256,reservation_id,output_json,output_sha256,source_receipt_sha256)) FROM native_source_provider_calls),
              'source',(SELECT json_group_array(json_array(reservation_id,state,result_sha256)) FROM native_source_requests))
            """)
    }
    static func execute(_ url: URL, _ sql: String) throws { try connection(url) { guard sqlite3_exec($0, sql, nil, nil, nil) == SQLITE_OK else { throw PressureFixtureError.interrupted } } }
    static func value(_ url: URL, _ sql: String) throws -> String {
        try connection(url) { db in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw PressureFixtureError.interrupted }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { throw PressureFixtureError.interrupted }
            return String(cString: value)
        }
    }
    private static func connection<T>(_ url: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else { throw PressureFixtureError.interrupted }
        defer { sqlite3_close_v2(db) }; return try body(db)
    }
}
