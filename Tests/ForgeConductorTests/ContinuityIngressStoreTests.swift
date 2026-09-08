// ContinuityIngressStoreTests.swift
// Exercises the actual source SQLite transaction and immutable delivery boundary.

import XCTest
import SQLite3
@testable import ForgeConductorCore

final class ContinuityIngressStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuity-ingress-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var database: URL { directory.appendingPathComponent("source.sqlite3") }

    private func authority(
        project: ProjectID = ProjectID(),
        generation: ProjectGeneration = .initial,
        task: UUID = UUID(),
        binding: UUID = UUID(),
        assignment: String = UUID().uuidString.lowercased(),
        digest: String = JSONSupport.sha256Hex("operator-approved immutable assignment")
    ) throws -> ContinuityIngressAuthorization {
        try ContinuityIngressAuthorization(
            projectID: project, projectGeneration: generation,
            sourceBindingID: binding, taskID: task,
            assignmentID: assignment, assignmentSHA256: digest,
            authorizationScope: ToolAuthorizationScope(
                canonicalRoots: [directory], allowedTools: ["context_get", "fs_read"],
                networkAllowed: false, maximumInlineOutputBytes: 65_536
            )
        )
    }

    private func packet(id: String = UUID().uuidString.lowercased(), ready: Bool = true) -> HandoffPacket {
        HandoffPacket(
            id: id, createdAt: "2026-09-08T10:00:00Z", updatedAt: "2026-09-08T10:00:00Z",
            source: .model, resumeReady: ready,
            clientID: "shared-host-process", goal: "Continue the authorized fixture task",
            nextActions: ["Read the predetermined fixture"]
        )
    }

    private func expectIngressError<T>(
        _ expected: ContinuityIngressError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () throws -> T
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            XCTAssertEqual($0 as? ContinuityIngressError, expected, file: file, line: line)
        }
    }

    func testSourcePacketRevisionAndOutboxRollbackTogether() throws {
        let authorization = try authority()
        let original = packet()
        let store = try SQLiteStore(
            path: database, postMigrationCommitObserver: nil,
            beforeMutationCommitObserver: { kind in
                if kind == .handoff { throw StoreError.execFailed("injected source commit failure") }
            }
        )
        defer { store.close() }
        XCTAssertThrowsError(try store.handoffCommit(
            original, authorization: authorization, automaticHandoffEnabled: true
        ))
        XCTAssertNil(try store.handoffGet(id: original.id))
        XCTAssertNil(try store.memoryGet(key: "continuity/latest"))
        XCTAssertNil(try store.continuityLatestRevision(continuityID: original.id, authorization: authorization))
        XCTAssertTrue(try store.pendingContinuityHandoffs().isEmpty)
    }

    func testCommittedDeliverySurvivesReopenBeforeAnyManagerAcknowledgment() throws {
        let authorization = try authority()
        let original = packet()
        let store = try SQLiteStore(path: database)
        let committed = try store.handoffCommit(
            original, authorization: authorization, automaticHandoffEnabled: true
        )
        let operation = try XCTUnwrap(committed.delivery).operationID
        store.close()

        let reopened = try SQLiteStore(path: database)
        defer { reopened.close() }
        let queued = try XCTUnwrap(reopened.pendingContinuityHandoffs().first)
        XCTAssertEqual(queued.operationID, operation)
        XCTAssertEqual(queued.handoff, committed.revision)
        XCTAssertEqual(queued.state, .pending)
        XCTAssertEqual(queued.attempts, 0)
        XCTAssertEqual(queued.handoff.canonicalPacketJSON,
                       try ForgeJSONCanonicalizationV1.data(from: original.asDictionary()))
        XCTAssertEqual(queued.handoff.identity.packetSHA256,
                       JSONSupport.sha256Hex(queued.handoff.canonicalPacketJSON))
        XCTAssertNotNil(try reopened.handoffGet(id: original.id))
    }

    func testFrozenRevisionSurvivesLegacyMutationAndOldCommitRetryDoesNotRewindLatest() throws {
        let store = try SQLiteStore(path: database)
        defer { store.close() }
        let authorization = try authority()
        let original = packet()
        let first = try store.handoffCommit(
            original, authorization: authorization, automaticHandoffEnabled: true
        )
        var changed = original
        changed.goal = "A later update under the same source ID"
        changed.updatedAt = "2026-09-08T10:01:00Z"
        try store.handoffUpsert(changed)

        let retried = try store.handoffCommit(
            original, authorization: authorization, automaticHandoffEnabled: true
        )
        XCTAssertEqual(retried, first)
        XCTAssertEqual(try store.handoffGet(id: original.id)?.goal, changed.goal)
        XCTAssertEqual(try store.continuityHandoffRevision(
            identity: first.revision.identity, authorization: authorization
        ), first.revision)

        let second = try store.handoffCommit(
            changed, authorization: authorization, automaticHandoffEnabled: true
        )
        XCTAssertEqual(second.revision.identity.revision, 2)
        XCTAssertNotEqual(first.revision.identity.packetSHA256, second.revision.identity.packetSHA256)
        XCTAssertNotEqual(first.delivery?.operationID, second.delivery?.operationID)
        XCTAssertEqual(try store.continuityLatestRevision(
            continuityID: original.id, authorization: authorization
        ), second.revision)
        XCTAssertEqual(try store.continuityHandoffRevision(
            identity: first.revision.identity, authorization: authorization
        ).canonicalPacketJSON, first.revision.canonicalPacketJSON)
    }

    func testSoftAndDisabledCommitsDoNotAutomaticallyEnqueueAndExplicitSubmissionConverges() throws {
        let store = try SQLiteStore(path: database)
        defer { store.close() }
        let authorization = try authority()
        let soft = try store.handoffCommit(
            packet(ready: false), authorization: authorization, automaticHandoffEnabled: true
        )
        XCTAssertNil(soft.delivery)
        expectIngressError(.invalidRequest("handoff_is_not_resume_ready")) {
            try store.enqueueContinuityHandoff(identity: soft.revision.identity, authorization: authorization)
        }
        let disabledPacket = packet()
        let disabled = try store.handoffCommit(
            disabledPacket, authorization: authorization, automaticHandoffEnabled: false
        )
        XCTAssertNil(disabled.delivery)
        XCTAssertNotNil(try store.handoffGet(id: disabledPacket.id))
        XCTAssertTrue(try store.pendingContinuityHandoffs().isEmpty)

        let explicit = try store.enqueueContinuityHandoff(
            identity: disabled.revision.identity, authorization: authorization
        )
        let automatic = try store.handoffCommit(
            disabledPacket, authorization: authorization, automaticHandoffEnabled: true
        )
        XCTAssertEqual(explicit, automatic.delivery)
        XCTAssertEqual(try store.pendingContinuityHandoffs().count, 1)
    }

    func testTwoSourceConnectionsConvergeOnOneCommitAndOneDeliveryLease() async throws {
        let authorization = try authority()
        let original = packet()
        let first = try SQLiteStore(path: database)
        let second = try SQLiteStore(path: database)
        defer { first.close(); second.close() }
        let left = Task.detached {
            try first.handoffCommit(original, authorization: authorization, automaticHandoffEnabled: true)
        }
        let right = Task.detached {
            try second.handoffCommit(original, authorization: authorization, automaticHandoffEnabled: true)
        }
        let leftResult = try await left.value
        let rightResult = try await right.value
        XCTAssertEqual(leftResult, rightResult)
        let operationID = try XCTUnwrap(leftResult.delivery).operationID
        let firstClaim = Task.detached {
            try first.claimContinuityHandoff(operationID: operationID, owner: "manager-one")
        }
        let secondClaim = Task.detached {
            try second.claimContinuityHandoff(operationID: operationID, owner: "manager-two")
        }
        let claims = try await [firstClaim.value, secondClaim.value]
        XCTAssertEqual(claims.compactMap { $0 }.count, 1)
        XCTAssertEqual(try first.continuityDelivery(operationID: operationID)?.attempts, 1)
        XCTAssertTrue(try first.pendingContinuityHandoffs().isEmpty)
    }

    func testAuthorizationIsCheckedBeforeDuplicateOrExactRevisionDisclosure() throws {
        let store = try SQLiteStore(path: database)
        defer { store.close() }
        let allowed = try authority()
        let original = packet()
        let committed = try store.handoffCommit(
            original, authorization: allowed, automaticHandoffEnabled: true
        )
        let changedBindings = [
            try authority(),
            try authority(project: allowed.projectID, task: allowed.taskID),
            try authority(
                project: allowed.projectID, task: allowed.taskID, binding: allowed.sourceBindingID,
                assignment: allowed.assignmentID, digest: JSONSupport.sha256Hex("different assignment")
            ),
        ]
        for wrong in changedBindings {
            expectIngressError(.authorityMismatch) {
                try store.handoffCommit(original, authorization: wrong, automaticHandoffEnabled: true)
            }
            expectIngressError(.authorityMismatch) {
                try store.continuityLatestRevision(continuityID: original.id, authorization: wrong)
            }
            expectIngressError(.authorityMismatch) {
                try store.enqueueContinuityHandoff(identity: committed.revision.identity, authorization: wrong)
            }
        }
        XCTAssertEqual(try store.pendingContinuityHandoffs().count, 1)
    }

    func testTaskInvalidationSurvivesReopenAndCannotRepopulateAnotherSourceID() throws {
        let project = ProjectID()
        let transferred = try authority(project: project)
        let unaffected = try authority(project: project)
        let store = try SQLiteStore(path: database)
        let first = try store.handoffCommit(packet(), authorization: transferred, automaticHandoffEnabled: true)
        let second = try store.handoffCommit(packet(), authorization: unaffected, automaticHandoffEnabled: true)
        let firstOperation = try XCTUnwrap(first.delivery).operationID
        let claim = try XCTUnwrap(store.claimContinuityHandoff(operationID: firstOperation, owner: "manager"))
        XCTAssertEqual(try store.invalidateContinuityIngress(
            projectID: project, throughGeneration: .initial, taskID: transferred.taskID
        ), 1)
        expectIngressError(.invalidated) {
            try store.acknowledgeContinuityHandoff(
                claim: claim, acceptanceReceiptSHA256: JSONSupport.sha256Hex("late acceptance")
            )
        }
        XCTAssertEqual(try store.continuityDelivery(operationID: firstOperation)?.state, .invalidated)
        store.close()

        let reopened = try SQLiteStore(path: database)
        defer { reopened.close() }
        expectIngressError(.invalidated) {
            try reopened.handoffCommit(packet(), authorization: transferred, automaticHandoffEnabled: true)
        }
        expectIngressError(.invalidated) {
            try reopened.enqueueContinuityHandoff(identity: first.revision.identity, authorization: transferred)
        }
        XCTAssertEqual(try reopened.pendingContinuityHandoffs().map(\.operationID), [try XCTUnwrap(second.delivery).operationID])
        XCTAssertEqual(try reopened.invalidateContinuityIngress(projectID: project, throughGeneration: .initial), 1)
        expectIngressError(.invalidated) {
            try reopened.handoffCommit(packet(), authorization: unaffected, automaticHandoffEnabled: true)
        }
        let nextGeneration = try authority(project: project, generation: ProjectGeneration(2))
        XCTAssertNotNil(try reopened.handoffCommit(
            packet(), authorization: nextGeneration, automaticHandoffEnabled: true
        ).delivery)
    }

    func testExpiredClaimCannotRetryOrAcknowledgeAfterAnotherOwnerAndAckCannotRevive() throws {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_000))
        let store = try SQLiteStore(path: database, clock: clock)
        defer { store.close() }
        let authorization = try authority()
        let committed = try store.handoffCommit(packet(), authorization: authorization, automaticHandoffEnabled: true)
        let operation = try XCTUnwrap(committed.delivery).operationID
        _ = try store.enqueueContinuityHandoff(identity: committed.revision.identity, authorization: authorization)
        let old = try XCTUnwrap(store.claimContinuityHandoff(operationID: operation, owner: "old", leaseSeconds: 2))
        clock.date = clock.date.addingTimeInterval(3)
        let current = try XCTUnwrap(store.claimContinuityHandoff(operationID: operation, owner: "current"))
        XCTAssertEqual(current.delivery.attempts, 2)
        expectIngressError(.deliveryConflict) {
            try store.retryContinuityHandoff(claim: old, errorCode: "late_retry", retryDelaySeconds: 1)
        }
        let receipt = JSONSupport.sha256Hex("exact control-plane acceptance")
        expectIngressError(.deliveryConflict) {
            try store.acknowledgeContinuityHandoff(claim: old, acceptanceReceiptSHA256: receipt)
        }
        let acknowledged = try store.acknowledgeContinuityHandoff(claim: current, acceptanceReceiptSHA256: receipt)
        XCTAssertEqual(acknowledged.state, .acknowledged)
        XCTAssertEqual(try store.acknowledgeContinuityHandoff(
            claim: current, acceptanceReceiptSHA256: receipt
        ), acknowledged)
        expectIngressError(.deliveryConflict) {
            try store.retryContinuityHandoff(claim: current, errorCode: "must_not_revive", retryDelaySeconds: 1)
        }
        XCTAssertEqual(try store.enqueueContinuityHandoff(
            identity: committed.revision.identity, authorization: authorization
        ), acknowledged)
        XCTAssertTrue(try store.pendingContinuityHandoffs().isEmpty)
    }

    func testDeliveryRetryBudgetBlocksAndRepeatedSubmissionDoesNotResetIt() throws {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_000))
        let store = try SQLiteStore(path: database, clock: clock)
        defer { store.close() }
        let authorization = try authority()
        let committed = try store.handoffCommit(packet(), authorization: authorization, automaticHandoffEnabled: true)
        let operation = try XCTUnwrap(committed.delivery).operationID
        for attempt in 1...ContinuityIngressLimits.maximumAttempts {
            let claim = try XCTUnwrap(store.claimContinuityHandoff(operationID: operation, owner: "manager"))
            XCTAssertEqual(claim.delivery.attempts, attempt)
            let result = try store.retryContinuityHandoff(
                claim: claim, errorCode: "manager_unavailable", retryDelaySeconds: 1
            )
            XCTAssertEqual(result.state, attempt == ContinuityIngressLimits.maximumAttempts ? .blocked : .pending)
            clock.date = clock.date.addingTimeInterval(2)
        }
        XCTAssertNil(try store.claimContinuityHandoff(operationID: operation, owner: "new-manager"))
        let resubmitted = try store.enqueueContinuityHandoff(
            identity: committed.revision.identity, authorization: authorization
        )
        XCTAssertEqual(resubmitted.state, .blocked)
        XCTAssertTrue(resubmitted.explicitlyRequested)
        XCTAssertEqual(resubmitted.attempts, ContinuityIngressLimits.maximumAttempts)
        XCTAssertTrue(try store.pendingContinuityHandoffs().isEmpty)
    }

    func testOversizePacketAndFullOutboxCannotLeavePartialSourceCommit() throws {
        let store = try SQLiteStore(path: database)
        defer { store.close() }
        let authorization = try authority()
        var oversized = packet()
        oversized.goal = String(repeating: "x", count: ContinuityIngressLimits.maximumPacketBytes + 1)
        expectIngressError(.capacityExceeded("packet bytes")) {
            try store.handoffCommit(oversized, authorization: authorization, automaticHandoffEnabled: true)
        }
        XCTAssertNil(try store.handoffGet(id: oversized.id))
        for _ in 0..<ContinuityIngressLimits.maximumPendingDeliveries {
            _ = try store.handoffCommit(packet(), authorization: authorization, automaticHandoffEnabled: true)
        }
        let overflow = packet()
        expectIngressError(.capacityExceeded("pending deliveries")) {
            try store.handoffCommit(overflow, authorization: authorization, automaticHandoffEnabled: true)
        }
        XCTAssertNil(try store.handoffGet(id: overflow.id))
        XCTAssertNil(try store.continuityLatestRevision(continuityID: overflow.id, authorization: authorization))
        XCTAssertEqual(try store.pendingContinuityHandoffs().count, ContinuityIngressLimits.maximumQueryRows)
        expectIngressError(.invalidRequest("query_limit")) { try store.pendingContinuityHandoffs(limit: 33) }
    }

    func testPostCommitCancellationReturnsDurableResultAndPrecommitCancellationRollsBack() throws {
        let authorization = try authority()
        let postControl = ToolCallCancellation(timeoutSeconds: 10)
        let committedStore = try SQLiteStore(
            path: database, postMigrationCommitObserver: nil,
            didMutationCommitObserver: { if $0 == .handoff { postControl.cancel() } }
        )
        let committed = try committedStore.handoffCommit(
            packet(), authorization: authorization, automaticHandoffEnabled: true, cancellation: postControl
        )
        XCTAssertTrue(postControl.isCancelled)
        XCTAssertNotNil(committed.delivery)
        XCTAssertEqual(try committedStore.pendingContinuityHandoffs().count, 1)
        committedStore.close()

        let preControl = ToolCallCancellation(timeoutSeconds: 10)
        let failedStore = try SQLiteStore(
            path: directory.appendingPathComponent("cancelled.sqlite3"), postMigrationCommitObserver: nil,
            beforeMutationCommitObserver: { if $0 == .handoff { preControl.cancel() } }
        )
        defer { failedStore.close() }
        let failedPacket = packet()
        XCTAssertThrowsError(try failedStore.handoffCommit(
            failedPacket, authorization: authorization, automaticHandoffEnabled: true, cancellation: preControl
        )) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertNil(try failedStore.handoffGet(id: failedPacket.id))
        XCTAssertTrue(try failedStore.pendingContinuityHandoffs().isEmpty)
    }

    func testVersionSixMigrationPreservesLegacyPacketAndDoesNotEnrollIt() throws {
        let legacy = packet()
        let initial = try SQLiteStore(path: database)
        try initial.handoffUpsert(legacy)
        initial.close()
        try rawSQL("""
            DROP TABLE continuity_ingress_outbox;
            DROP TABLE continuity_ingress_revisions;
            DROP TABLE continuity_ingress_invalidations;
            UPDATE schema_version SET version=6;
            """)
        let migrated = try SQLiteStore(path: database)
        defer { migrated.close() }
        XCTAssertEqual(try migrated.handoffGet(id: legacy.id)?.goal, legacy.goal)
        XCTAssertTrue(try migrated.pendingContinuityHandoffs().isEmpty)
        XCTAssertNil(try migrated.continuityLatestRevision(continuityID: legacy.id, authorization: authority()))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("source.pre-migration-v6.sqlite3").path
        ))
    }

    func testCorruptedFrozenPacketCannotBeDelivered() throws {
        let store = try SQLiteStore(path: database)
        defer { store.close() }
        let committed = try store.handoffCommit(packet(), authorization: authority(), automaticHandoffEnabled: true)
        let operation = try XCTUnwrap(committed.delivery).operationID
        try rawSQL("UPDATE continuity_ingress_revisions SET packet_json=X'7b7d';")
        XCTAssertThrowsError(try store.pendingContinuityHandoffs())
        XCTAssertThrowsError(try store.claimContinuityHandoff(operationID: operation, owner: "manager"))
    }

    func testOwnedPacketsAreExcludedBeforeAllLegacyReadsWhileUnownedPacketsRemainAvailable() throws {
        let store = try SQLiteStore(path: database)
        defer { store.close() }
        var ready = packet()
        ready.clientID = "legacy-client"
        var soft = packet(ready: false)
        soft.clientID = "other-client"
        try store.handoffUpsert(ready)
        try store.handoffUpsert(soft)
        let authorization = try authority()
        var ownedPacket = packet()
        ownedPacket.clientID = "shared-host-process"
        let committed = try store.handoffCommit(
            ownedPacket, authorization: authorization, automaticHandoffEnabled: true
        )

        XCTAssertNil(try store.handoffLegacyGet(id: ownedPacket.id))
        XCTAssertEqual(try store.handoffLegacyGet(id: ready.id)?.id, ready.id)
        XCTAssertEqual(try store.handoffLegacyLatest()?.id, soft.id)
        XCTAssertEqual(try store.handoffLegacyLatest(resumeReadyOnly: true)?.id, ready.id)
        XCTAssertNil(try store.handoffLegacyLatest(clientID: ownedPacket.clientID))
        XCTAssertEqual(try store.handoffLegacyLatest(clientID: ready.clientID)?.id, ready.id)
        XCTAssertEqual(try store.handoffLegacyList().map(\.id), [soft.id, ready.id])
        XCTAssertEqual(try store.handoffLegacyList(limit: 1).map(\.id), [soft.id])
        XCTAssertEqual(try store.handoffLegacyListAll().map(\.id), [soft.id, ready.id])
        XCTAssertEqual(try store.continuityHandoffRevision(
            identity: committed.revision.identity, authorization: authorization
        ), committed.revision)
        XCTAssertNotNil(try store.handoffGet(id: ownedPacket.id))

        ownedPacket.goal = "A later compatibility write cannot remove task ownership"
        try store.handoffUpsert(ownedPacket)
        XCTAssertNil(try store.handoffLegacyGet(id: ownedPacket.id))
        XCTAssertEqual(try store.handoffLegacyListAll().map(\.id), [soft.id, ready.id])
        try store.invalidateContinuityIngress(
            projectID: authorization.projectID, throughGeneration: authorization.projectGeneration,
            taskID: authorization.taskID
        )
        XCTAssertNil(try store.handoffLegacyGet(id: ownedPacket.id))
        XCTAssertEqual(try store.handoffLegacyLatest()?.id, soft.id)
    }

    func testOwnedCommitRepairAndLegacyOverwriteNeverPublishOwnedGlobalMemoryPointers() throws {
        let store = try SQLiteStore(path: database)
        defer { store.close() }
        let legacy = packet()
        try store.handoffUpsert(legacy)
        let authorization = try authority()
        var owned = packet()
        _ = try store.handoffCommit(owned, authorization: authorization, automaticHandoffEnabled: true)

        func assertLegacyPointers() throws {
            XCTAssertEqual(try store.memoryGet(key: "continuity/latest"), legacy.id)
            XCTAssertEqual(try store.memoryGetNote(key: "continuity/resume_ready")?.body, legacy.id)
            XCTAssertFalse(try store.memoryList(
                prefix: "continuity/", includeSystem: true, limit: 20
            ).contains { $0.body == owned.id })
            XCTAssertTrue(try store.memorySearch(query: owned.id, includeSystem: true, limit: 20).isEmpty)
        }
        try assertLegacyPointers()
        try store.handoffRepairPointers()
        try assertLegacyPointers()
        owned.goal = "A compatibility overwrite keeps the immutable owner"
        try store.handoffUpsert(owned)
        try assertLegacyPointers()

        // An ID that had a legacy pointer before becoming owned must lose that
        // global projection in the same authorized source transaction.
        let promoted = packet()
        try store.handoffUpsert(promoted)
        XCTAssertEqual(try store.memoryGet(key: "continuity/latest"), promoted.id)
        _ = try store.handoffCommit(promoted, authorization: authorization, automaticHandoffEnabled: true)
        try assertLegacyPointers()
        XCTAssertTrue(try store.memorySearch(query: promoted.id, includeSystem: true, limit: 20).isEmpty)

        let isolated = try SQLiteStore(path: directory.appendingPathComponent("owned-only.sqlite3"))
        defer { isolated.close() }
        _ = try isolated.handoffCommit(packet(), authorization: authorization, automaticHandoffEnabled: true)
        try isolated.handoffRepairPointers()
        XCTAssertNil(try isolated.memoryGet(key: "continuity/latest"))
        XCTAssertNil(try isolated.memoryGetNote(key: "continuity/resume_ready"))
    }

    func testAutomaticThenExplicitSubmissionPreservesOperationAndLiveLeaseAcrossRestart() throws {
        let authorization = try authority()
        let original = packet()
        let store = try SQLiteStore(path: database)
        let automatic = try store.handoffCommit(
            original, authorization: authorization, automaticHandoffEnabled: true
        )
        let initial = try XCTUnwrap(automatic.delivery)
        XCTAssertFalse(initial.explicitlyRequested)
        XCTAssertEqual(try ContinuityIngressOperationIdentity(revision: automatic.revision).operationID,
                       initial.operationID)
        let claim = try XCTUnwrap(store.claimContinuityHandoff(operationID: initial.operationID, owner: "manager"))
        let explicit = try store.enqueueContinuityHandoff(identity: automatic.revision.identity, authorization: authorization)
        XCTAssertTrue(explicit.explicitlyRequested)
        XCTAssertEqual(explicit.operationID, initial.operationID)
        XCTAssertEqual(explicit.handoff, initial.handoff)
        XCTAssertEqual(explicit.state, claim.delivery.state)
        XCTAssertEqual(explicit.attempts, claim.delivery.attempts)
        XCTAssertEqual(explicit.leaseToken, claim.token)
        XCTAssertEqual(explicit.leaseExpiresAt, claim.delivery.leaseExpiresAt)
        XCTAssertEqual(try store.handoffCommit(
            original, authorization: authorization, automaticHandoffEnabled: true
        ).delivery, explicit, "An automatic retry cannot downgrade explicit provenance")
        store.close()

        let reopened = try SQLiteStore(path: database)
        defer { reopened.close() }
        XCTAssertEqual(try reopened.continuityDelivery(operationID: initial.operationID), explicit)
        XCTAssertEqual(try reopened.enqueueContinuityHandoff(
            identity: automatic.revision.identity, authorization: authorization
        ), explicit)
    }

    func testExplicitPromotionCannotReviveAcknowledgedOrInvalidatedDelivery() throws {
        let store = try SQLiteStore(path: database)
        defer { store.close() }
        let authorization = try authority()
        let automatic = try store.handoffCommit(packet(), authorization: authorization, automaticHandoffEnabled: true)
        let operation = try XCTUnwrap(automatic.delivery).operationID
        let claim = try XCTUnwrap(store.claimContinuityHandoff(operationID: operation, owner: "manager"))
        let accepted = try store.acknowledgeContinuityHandoff(
            claim: claim, acceptanceReceiptSHA256: JSONSupport.sha256Hex("durable acceptance")
        )
        XCTAssertFalse(accepted.explicitlyRequested)
        let explicit = try store.enqueueContinuityHandoff(identity: automatic.revision.identity, authorization: authorization)
        XCTAssertTrue(explicit.explicitlyRequested)
        XCTAssertEqual(explicit.state, .acknowledged)
        XCTAssertEqual(explicit.operationID, accepted.operationID)
        XCTAssertEqual(explicit.attempts, accepted.attempts)
        XCTAssertEqual(explicit.leaseToken, accepted.leaseToken)
        XCTAssertEqual(explicit.leaseExpiresAt, accepted.leaseExpiresAt)
        XCTAssertEqual(explicit.acceptanceReceiptSHA256, accepted.acceptanceReceiptSHA256)
        XCTAssertEqual(explicit.acknowledgedAt, accepted.acknowledgedAt)
        XCTAssertTrue(try store.pendingContinuityHandoffIDs(limit: 32).isEmpty)

        let pending = try store.handoffCommit(packet(), authorization: authorization, automaticHandoffEnabled: true)
        let pendingOperation = try XCTUnwrap(pending.delivery).operationID
        try store.invalidateContinuityIngress(
            projectID: authorization.projectID, throughGeneration: authorization.projectGeneration,
            taskID: authorization.taskID
        )
        expectIngressError(.invalidated) {
            try store.enqueueContinuityHandoff(identity: pending.revision.identity, authorization: authorization)
        }
        let invalidated = try XCTUnwrap(store.continuityDelivery(operationID: pendingOperation))
        XCTAssertEqual(invalidated.state, .invalidated)
        XCTAssertFalse(invalidated.explicitlyRequested)
    }

    func testVersionSevenUpgradePreservesOperationAndDefaultsUnknownProvenanceToAutomatic() throws {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_000))
        let authorization = try authority()
        let initial = try SQLiteStore(path: database, clock: clock)
        let committed = try initial.handoffCommit(packet(), authorization: authorization, automaticHandoffEnabled: true)
        let operation = try XCTUnwrap(committed.delivery).operationID
        let claim = try XCTUnwrap(initial.claimContinuityHandoff(operationID: operation, owner: "prior-manager"))
        initial.close()
        // Reconstruct the actual v7 column layout with an existing immutable
        // snapshot, claimed delivery, operation key and lease still in place.
        try rawSQL("""
            ALTER TABLE continuity_ingress_outbox DROP COLUMN explicitly_requested;
            UPDATE schema_version SET version=7;
            """)
        let upgraded = try SQLiteStore(path: database, clock: clock)
        defer { upgraded.close() }
        let restored = try XCTUnwrap(upgraded.continuityDelivery(operationID: operation))
        XCTAssertFalse(restored.explicitlyRequested)
        XCTAssertEqual(restored, claim.delivery)
        XCTAssertEqual(try ContinuityIngressOperationIdentity(revision: restored.handoff).operationID, operation)
        let explicit = try upgraded.enqueueContinuityHandoff(identity: committed.revision.identity, authorization: authorization)
        XCTAssertTrue(explicit.explicitlyRequested)
        XCTAssertEqual(explicit.leaseToken, restored.leaseToken)
        XCTAssertEqual(explicit.attempts, restored.attempts)
        XCTAssertEqual(explicit.handoff, restored.handoff)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("source.pre-migration-v7.sqlite3").path
        ))
    }

    func testMetadataPaginationIsolatesCorruptFirstRowWithoutQuarantiningValidWork() throws {
        let store = try SQLiteStore(path: database)
        defer { store.close() }
        let authorization = try authority()
        let one = try XCTUnwrap(store.handoffCommit(packet(), authorization: authorization, automaticHandoffEnabled: true).delivery)
        let two = try XCTUnwrap(store.handoffCommit(packet(), authorization: authorization, automaticHandoffEnabled: true).delivery)
        let sorted = [one, two].sorted { $0.operationID.uuidString < $1.operationID.uuidString }
        let corrupt = sorted[0]
        let valid = sorted[1]
        try rawSQL("UPDATE continuity_ingress_revisions SET packet_json=X'7b7d' WHERE continuity_id='\(corrupt.handoff.identity.continuityID)';")

        XCTAssertEqual(try store.pendingContinuityHandoffIDs(limit: 1), [corrupt.operationID])
        XCTAssertEqual(try store.pendingContinuityHandoffIDs(limit: 1, afterOperationID: corrupt.operationID), [valid.operationID])
        XCTAssertTrue(try store.pendingContinuityHandoffIDs(limit: 1, afterOperationID: valid.operationID).isEmpty)
        XCTAssertThrowsError(try store.continuityDelivery(operationID: corrupt.operationID))
        XCTAssertFalse(try store.quarantineMalformedContinuityDelivery(operationID: valid.operationID))
        XCTAssertTrue(try store.quarantineMalformedContinuityDelivery(operationID: corrupt.operationID))
        XCTAssertFalse(try store.quarantineMalformedContinuityDelivery(operationID: corrupt.operationID))
        XCTAssertEqual(try store.pendingContinuityHandoffs().map(\.operationID), [valid.operationID])
        XCTAssertEqual(try store.continuityDelivery(operationID: valid.operationID), valid)
        XCTAssertNotNil(try store.claimContinuityHandoff(operationID: valid.operationID, owner: "manager"))
    }

    func testMalformedDeliveryCannotBeQuarantinedWhileItsLeaseIsLive() throws {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_000))
        let store = try SQLiteStore(path: database, clock: clock)
        defer { store.close() }
        let delivery = try XCTUnwrap(store.handoffCommit(
            packet(), authorization: authority(), automaticHandoffEnabled: true
        ).delivery)
        _ = try XCTUnwrap(store.claimContinuityHandoff(operationID: delivery.operationID, owner: "manager", leaseSeconds: 2))
        try rawSQL("UPDATE continuity_ingress_revisions SET packet_json=X'7b7d';")
        XCTAssertFalse(try store.quarantineMalformedContinuityDelivery(operationID: delivery.operationID))
        XCTAssertTrue(try store.pendingContinuityHandoffIDs(limit: 32).isEmpty)
        clock.date = clock.date.addingTimeInterval(3)
        XCTAssertEqual(try store.pendingContinuityHandoffIDs(limit: 32), [delivery.operationID])
        XCTAssertTrue(try store.quarantineMalformedContinuityDelivery(operationID: delivery.operationID))
        XCTAssertTrue(try store.pendingContinuityHandoffIDs(limit: 32).isEmpty)
    }

    func testPreAdmissionDeferralRestoresOnlyCurrentAttemptAndCannotReplayOrOverrideExplicitStart() throws {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_000))
        let store = try SQLiteStore(path: database, clock: clock)
        defer { store.close() }
        let authorization = try authority()
        let delivery = try XCTUnwrap(store.handoffCommit(
            packet(), authorization: authorization, automaticHandoffEnabled: true
        ).delivery)
        let old = try XCTUnwrap(store.claimContinuityHandoff(
            operationID: delivery.operationID, owner: "old", leaseSeconds: 2
        ))
        clock.date = clock.date.addingTimeInterval(3)
        expectIngressError(.deliveryConflict) { try store.validateContinuityHandoffClaim(claim: old) }
        let current = try XCTUnwrap(store.claimContinuityHandoff(operationID: delivery.operationID, owner: "current"))
        XCTAssertEqual(current.delivery.attempts, 2)
        XCTAssertEqual(try store.validateContinuityHandoffClaim(claim: current), current.delivery)
        expectIngressError(.deliveryConflict) { try store.deferUnsubmittedContinuityHandoff(claim: old) }
        XCTAssertTrue(try store.deferUnsubmittedContinuityHandoff(claim: current))
        let deferred = try XCTUnwrap(store.continuityDelivery(operationID: delivery.operationID))
        XCTAssertEqual(deferred.state, .pending)
        XCTAssertEqual(deferred.attempts, 1, "Only this unsubmitted attempt is restored")
        XCTAssertEqual(deferred.lastErrorCode, "automatic_delivery_disabled")
        XCTAssertNil(deferred.leaseOwner)
        XCTAssertNil(deferred.leaseToken)
        XCTAssertNil(deferred.leaseExpiresAt)
        expectIngressError(.deliveryConflict) { try store.deferUnsubmittedContinuityHandoff(claim: current) }
        XCTAssertEqual(try store.continuityDelivery(operationID: delivery.operationID), deferred)

        let promotedClaim = try XCTUnwrap(store.claimContinuityHandoff(operationID: delivery.operationID, owner: "current"))
        let promoted = try store.enqueueContinuityHandoff(identity: delivery.handoff.identity, authorization: authorization)
        XCTAssertTrue(promoted.explicitlyRequested)
        XCTAssertEqual(try store.validateContinuityHandoffClaim(claim: promotedClaim), promoted)
        XCTAssertFalse(try store.deferUnsubmittedContinuityHandoff(claim: promotedClaim))
        XCTAssertEqual(try store.continuityDelivery(operationID: delivery.operationID), promoted)
        let acknowledged = try store.acknowledgeContinuityHandoff(
            claim: promotedClaim, acceptanceReceiptSHA256: JSONSupport.sha256Hex("accepted explicit operation")
        )
        expectIngressError(.deliveryConflict) { try store.deferUnsubmittedContinuityHandoff(claim: promotedClaim) }
        XCTAssertEqual(try store.continuityDelivery(operationID: delivery.operationID), acknowledged)
    }

    private func rawSQL(_ sql: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(database.path, &handle) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw StoreError.openFailed("fixture database")
        }
        defer { sqlite3_close(handle) }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw StoreError.execFailed(String(cString: sqlite3_errmsg(handle)))
        }
    }
}
