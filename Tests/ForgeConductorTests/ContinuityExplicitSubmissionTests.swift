import XCTest
import SQLite3
@testable import ForgeConductorCore

final class ContinuityExplicitSubmissionTests: XCTestCase {
    func testRequestRequiresOneExactBoundedIdentifierAndValidOptionalFields() throws {
        let request = try ContinuityExplicitHandoffRequest(arguments: [
            "continuity_id": "exact-source", "idempotency_key": "operator-start-1", "reason": "Resume approved work",
        ])
        XCTAssertEqual(request.continuityID, "exact-source")
        XCTAssertEqual(request.idempotencyKey, "operator-start-1")
        XCTAssertEqual(request.reason, "Resume approved work")
        let invalid: [[String: Any]] = [
            [:], ["continuity_id": NSNull()], ["continuity_id": ""],
            ["continuity_id": "latest/other"], ["continuity_id": " exact-source"],
            ["continuity_id": String(repeating: "a", count: 129)],
            ["continuity_id": "exact-source", "task_id": UUID().uuidString],
            ["continuity_id": "exact-source", "idempotency_key": NSNull()],
            ["continuity_id": "exact-source", "idempotency_key": ""],
            ["continuity_id": "exact-source", "idempotency_key": "key\n"],
            ["continuity_id": "exact-source", "idempotency_key": String(repeating: "é", count: 129)],
            ["continuity_id": "exact-source", "reason": false],
            ["continuity_id": "exact-source", "reason": " trailing "],
            ["continuity_id": "exact-source", "reason": "embedded\u{0}suffix"],
            ["continuity_id": "exact-source", "reason": String(repeating: "a", count: 513)],
        ]
        for arguments in invalid {
            XCTAssertThrowsError(try ContinuityExplicitHandoffRequest(arguments: arguments)) {
                guard let error = $0 as? ContinuityIngressError, case .invalidRequest = error else {
                    return XCTFail("Unexpected request rejection: \($0)")
                }
            }
        }
    }

    func testExplicitSubmissionPersistsPermitWhileAutomaticPolicyStaysDisabled() async throws {
        try await withFixture { fixture in
            let commit = try await fixture.commit()
            XCTAssertNil(commit.delivery)
            let submitted = try await fixture.submit(id: commit.revision.identity.continuityID, key: "disabled-start")
            XCTAssertEqual(submitted.acceptance.sourceIdentity, commit.revision.identity)
            XCTAssertEqual(submitted.acceptance.authorization, fixture.setup.record.authorization)
            XCTAssertEqual(submitted.permit.operationID, submitted.acceptance.operationID)
            XCTAssertEqual(submitted.permit.acceptanceReceiptSHA256, submitted.acceptance.receiptSHA256)
            XCTAssertEqual(submitted.permit.callerBindingID, fixture.setup.correlation.callerBindingID)
            XCTAssertEqual(submitted.permit.permitSHA256, JSONSupport.sha256Hex(submitted.permit.canonicalPermitJSON))
            XCTAssertFalse(try fixture.policy().policy.automaticHandoffEnabled)
            let delivery = try XCTUnwrap(fixture.app.store.continuityDelivery(operationID: submitted.acceptance.operationID))
            XCTAssertEqual(delivery.handoff, commit.revision)
            XCTAssertTrue(delivery.explicitlyRequested)
            XCTAssertEqual(delivery.state, .pending)
            XCTAssertEqual(delivery.attempts, 0)
            let runSnapshot = try await fixture.app.projectContexts.repository.autonomousRun(submitted.acceptance.runID)
            let run = try XCTUnwrap(runSnapshot)
            XCTAssertEqual(run.state, .awaitingBootstrap)
            XCTAssertNil(run.activeSessionID)
            try assertNoInlineProviderWork(fixture)
        }
    }

    func testAutomaticAndExplicitSubmissionConvergeBeforeManagerAcknowledgement() async throws {
        try await withFixture(automatic: true) { fixture in
            let commit = try await fixture.commit(automatic: true)
            let automatic = try XCTUnwrap(commit.delivery)
            let explicit = try await fixture.submit(id: commit.revision.identity.continuityID, key: "convergent-start")
            XCTAssertEqual(explicit.acceptance.operationID, automatic.operationID)
            let retryWithoutKey = try await fixture.submit(id: commit.revision.identity.continuityID)
            XCTAssertEqual(retryWithoutKey.acceptance, explicit.acceptance)
            XCTAssertEqual(retryWithoutKey.permit, explicit.permit)
            let drain = try ContinuityIngressDeliveryService(source: fixture.app.store,
                repository: fixture.app.projectContexts.repository, config: fixture.app.config)
            let report = try await drain.drainOnce()
            await drain.shutdown()
            XCTAssertEqual(report.accepted, 1)
            let acknowledged = try XCTUnwrap(fixture.app.store.continuityDelivery(operationID: automatic.operationID))
            XCTAssertTrue(acknowledged.explicitlyRequested)
            XCTAssertEqual(acknowledged.state, .acknowledged)
            XCTAssertEqual(acknowledged.acceptanceReceiptSHA256, explicit.acceptance.receiptSHA256)
            XCTAssertEqual(try ExplicitSubmissionSQLite.integer(fixture.app.paths.controlPlaneSQLite,
                "SELECT COUNT(*) FROM autonomous_runs"), 1)
            XCTAssertEqual(try ExplicitSubmissionSQLite.integer(fixture.app.paths.controlPlaneSQLite,
                "SELECT COUNT(*) FROM continuity_ingress_acceptances"), 1)
            try assertNoInlineProviderWork(fixture)
        }
    }

    func testExplicitPromotionPreservesAlreadyAcknowledgedAutomaticDelivery() async throws {
        try await withFixture(automatic: true) { fixture in
            let commit = try await fixture.commit(automatic: true)
            let operationID = try XCTUnwrap(commit.delivery?.operationID)
            let drain = try ContinuityIngressDeliveryService(source: fixture.app.store,
                repository: fixture.app.projectContexts.repository, config: fixture.app.config)
            let report = try await drain.drainOnce()
            await drain.shutdown()
            XCTAssertEqual(report.accepted, 1)
            let before = try XCTUnwrap(fixture.app.store.continuityDelivery(operationID: operationID))
            XCTAssertEqual(before.state, .acknowledged)
            XCTAssertFalse(before.explicitlyRequested)
            let prior = try fixture.app.config.budgetPolicySelection(scope: .globalDefault)
            _ = try fixture.app.config.updateBudgetPolicy(.init(scope: .globalDefault,
                expectedRevision: prior.revision, expectedGlobalRevision: prior.globalRevision,
                operation: .set, policy: BudgetPolicy(automaticHandoffEnabled: false)))
            let submitted = try await fixture.submit(id: commit.revision.identity.continuityID, key: "promote-acknowledged")
            XCTAssertEqual(submitted.acceptance.receiptSHA256, before.acceptanceReceiptSHA256)
            let after = try XCTUnwrap(fixture.app.store.continuityDelivery(operationID: operationID))
            XCTAssertTrue(after.explicitlyRequested)
            XCTAssertEqual(after.state, before.state)
            XCTAssertEqual(after.attempts, before.attempts)
            XCTAssertEqual(after.leaseOwner, before.leaseOwner)
            XCTAssertEqual(after.leaseToken, before.leaseToken)
            XCTAssertEqual(after.leaseExpiresAt, before.leaseExpiresAt)
            XCTAssertEqual(after.acknowledgedAt, before.acknowledgedAt)
            XCTAssertEqual(after.acceptanceReceiptSHA256, before.acceptanceReceiptSHA256)
            XCTAssertEqual(after.handoff, before.handoff)
            XCTAssertTrue(try fixture.app.store.pendingContinuityHandoffs().isEmpty)
            XCTAssertFalse(try fixture.policy().policy.automaticHandoffEnabled)
            try assertNoInlineProviderWork(fixture)
        }
    }

    func testKeyedReplayPinsOriginalRevisionAfterSameIDEditAndRestart() async throws {
        try await withFixture { fixture in
            let original = try await fixture.commit()
            let first = try await fixture.submit(id: original.revision.identity.continuityID, key: "pinned-request")
            // Exercise immutable request replay against a changed source store.
            // The manager's separate source fence rejects this as a new native
            // task mutation; this lower-level fixture supplies no new authority.
            let revised = try fixture.app.store.handoffCommit(HandoffPacket(
                id: original.revision.identity.continuityID, source: .model, resumeReady: true,
                clientID: fixture.context.clientID.rawValue, goal: "Approved task progress",
                narrative: "Later progress must not replace the accepted snapshot"),
                authorization: fixture.setup.record.authorization, automaticHandoffEnabled: false)
            XCTAssertGreaterThan(revised.revision.identity.revision, original.revision.identity.revision)
            XCTAssertNotEqual(revised.revision.canonicalPacketJSON, original.revision.canonicalPacketJSON)
            XCTAssertNil(revised.delivery)
            let repeated = try await fixture.submit(id: original.revision.identity.continuityID, key: "pinned-request")
            XCTAssertEqual(repeated, first)
            let home = fixture.app.paths.home
            _ = fixture.app.shutdown()
            let reopened = try ForgeApp.bootstrap(home: home)
            defer { _ = reopened.shutdown() }
            let restarted = ExplicitSubmissionFixture(app: reopened, projectID: fixture.projectID,
                owner: fixture.owner, context: fixture.context, setup: fixture.setup)
            let restored = try await restarted.submit(id: original.revision.identity.continuityID, key: "pinned-request")
            XCTAssertEqual(restored, first)
            let delivered = try XCTUnwrap(reopened.store.continuityDelivery(operationID: first.acceptance.operationID))
            XCTAssertEqual(delivered.handoff, original.revision)
            XCTAssertEqual(try reopened.store.pendingContinuityHandoffs().count, 1)
            let latest = try reopened.store.continuityLatestRevision(continuityID: original.revision.identity.continuityID,
                authorization: fixture.setup.record.authorization)
            XCTAssertEqual(latest, revised.revision)
            try assertNoInlineProviderWork(restarted)
        }
    }

    func testLiveTaskAuthorityPrecedesDuplicateDisclosureForSharedTransport() async throws {
        try await withFixture { fixture in
            let committed = try await fixture.commit()
            let first = try await fixture.submit(id: committed.revision.identity.continuityID, key: "private-request")
            let peer = try await fixture.peer()
            let request = try ContinuityExplicitHandoffRequest(arguments: [
                "continuity_id": committed.revision.identity.continuityID, "idempotency_key": "private-request",
            ])
            do {
                _ = try await fixture.app.continuity.submitAuthorizedHandoff(request,
                    taskID: fixture.setup.record.authorization.taskID, correlation: nil,
                    context: fixture.context, owner: fixture.owner,
                    repository: fixture.app.projectContexts.repository, config: fixture.app.config)
                XCTFail("A transport without task correlation disclosed the accepted request")
            } catch { XCTAssertEqual(error as? ContinuityTaskAuthorizationError, .taskCorrelationRequired) }
            do {
                _ = try await fixture.app.continuity.submitAuthorizedHandoff(request,
                    taskID: peer.setup.record.authorization.taskID, correlation: fixture.setup.correlation,
                    context: fixture.context, owner: fixture.owner,
                    repository: fixture.app.projectContexts.repository, config: fixture.app.config)
                XCTFail("Task A's correlation authorized Task B")
            } catch { XCTAssertEqual(error as? ContinuityTaskAuthorizationError, .authorityMismatch) }
            do {
                _ = try await peer.submit(id: committed.revision.identity.continuityID, key: "private-request")
                XCTFail("Task B read Task A's immutable source through a shared transport")
            } catch { XCTAssertEqual(error as? ContinuityIngressError, .authorityMismatch) }
            _ = try await fixture.app.projectContexts.repository.revokeContinuityTask(
                taskID: fixture.setup.record.authorization.taskID,
                projectID: fixture.projectID, expectedGeneration: .initial)
            do {
                _ = try await fixture.submit(id: committed.revision.identity.continuityID, key: "private-request")
                XCTFail("Revoked task replay disclosed its accepted request")
            } catch { XCTAssertEqual(error as? ContinuityTaskAuthorizationError, .revoked) }
            let peerCommit = try await peer.commit(id: "independent-peer-source")
            let peerStart = try await peer.submit(id: peerCommit.revision.identity.continuityID, key: "private-request")
            XCTAssertNotEqual(peerStart.acceptance.operationID, first.acceptance.operationID)
            XCTAssertEqual(peerStart.acceptance.authorization.taskID, peer.setup.record.authorization.taskID)
            try assertNoInlineProviderWork(fixture)
        }
    }

    func testOneIdempotencyKeyCannotSelectAnotherSource() async throws {
        try await withFixture { fixture in
            let firstSource = try await fixture.commit(id: "first-keyed-source")
            _ = try await fixture.commit(id: "second-keyed-source")
            let first = try await fixture.submit(id: firstSource.revision.identity.continuityID, key: "one-request")
            do {
                _ = try await fixture.submit(id: "second-keyed-source", key: "one-request")
                XCTFail("A reused request key selected a different immutable source")
            } catch { XCTAssertEqual(error as? ContinuitySourceActivationError, .conflict) }
            let repeated = try await fixture.submit(id: firstSource.revision.identity.continuityID, key: "another-request")
            XCTAssertEqual(repeated.acceptance, first.acceptance)
            XCTAssertEqual(repeated.permit, first.permit)
            XCTAssertEqual(try fixture.app.store.pendingContinuityHandoffs().map(\.operationID), [first.acceptance.operationID])
            try assertNoInlineProviderWork(fixture)
        }
    }

    func testMissingAndSoftSourcesDoNotCreateExplicitPermission() async throws {
        try await withFixture { fixture in
            do {
                _ = try await fixture.submit(id: "missing-source", key: "missing")
                XCTFail("Missing source produced explicit permission")
            } catch { XCTAssertEqual(error as? ContinuityIngressError, .notFound) }
            let soft = try await fixture.commit(id: "soft-source", finalize: false)
            XCTAssertFalse(soft.revision.resumeReady)
            do {
                _ = try await fixture.submit(id: soft.revision.identity.continuityID, key: "soft")
                XCTFail("A soft checkpoint became an explicit resume request")
            } catch { XCTAssertEqual(error as? ContinuityIngressError, .invalidRequest("handoff_is_not_resume_ready")) }
            XCTAssertTrue(try fixture.app.store.pendingContinuityHandoffs().isEmpty)
            XCTAssertEqual(try ExplicitSubmissionSQLite.integer(fixture.app.paths.controlPlaneSQLite,
                "SELECT COUNT(*) FROM autonomous_runs"), 0)
            try assertNoInlineProviderWork(fixture)
        }
    }

    func testMutationCapableSharedProcessSourceCannotMintTransferPermission() async throws {
        try await withFixture(mutationCapable: true) { fixture in
            let committed = try await fixture.commit()
            XCTAssertNil(committed.delivery)
            do {
                _ = try await fixture.submit(id: committed.revision.identity.continuityID, key: "ambiguous-source")
                XCTFail("A shared process binding substituted for a task-scoped mutation fence")
            } catch { XCTAssertEqual(error as? ContinuitySourceActivationError, .taskIdentityUnavailable) }
            XCTAssertTrue(try fixture.app.store.pendingContinuityHandoffs().isEmpty)
            XCTAssertEqual(try ExplicitSubmissionSQLite.integer(fixture.app.paths.controlPlaneSQLite,
                "SELECT COUNT(*) FROM autonomous_runs"), 0)
            try assertNoInlineProviderWork(fixture)
        }
    }

    private func withFixture(
        automatic: Bool = false,
        mutationCapable: Bool = false,
        _ body: (ExplicitSubmissionFixture) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuity-explicit-\(UUID().uuidString)")
            .resolvingSymlinksInPath().standardizedFileURL
        let projectRoot = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let app = try ForgeApp.bootstrap(home: root.appendingPathComponent("home"))
        defer { _ = app.shutdown(); try? FileManager.default.removeItem(at: root) }
        let prior = try app.config.budgetPolicySelection(scope: .globalDefault)
        _ = try app.config.updateBudgetPolicy(.init(scope: .globalDefault,
            expectedRevision: prior.revision, expectedGlobalRevision: prior.globalRevision,
            operation: .set, policy: BudgetPolicy(automaticHandoffEnabled: automatic)))
        let projectID = ProjectID()
        let repository = app.projectContexts.repository
        _ = try await repository.registerProjectUnchecked(projectID: projectID,
            displayName: "Explicit submission fixture", canonicalRoot: projectRoot)
        let owner = ProjectBindingOwner(kind: .mcpClient, id: "shared-explicit-transport")
        let allowedTools = mutationCapable ? ["fs_write"] : ["fs_read"]
        let scope = ToolAuthorizationScope(canonicalRoots: [projectRoot],
            writableRoots: mutationCapable ? [projectRoot] : [],
            allowedTools: Set(allowedTools), networkAllowed: false, maximumInlineOutputBytes: 65_536)
        let binding = try await repository.bind(owner: owner, projectID: projectID,
            generation: .initial, authorizationScope: scope)
        let context = binding.invocationContext(clientID: ClientID(owner.id))
        let assignment = try ContinuityTaskAssignment(assignmentID: "explicit-approved-assignment",
            assignmentBytes: Data("Read the approved project fixture".utf8),
            mission: "Read the approved project fixture", providerID: "lmstudio",
            adapterID: "forge.native-session-host", modelKey: "fixture/explicit-model",
            specification: .init(allowedTools: allowedTools, completionGates: ["G04"]),
            authorizationScope: scope)
        let setup = try await repository.authorizeContinuityTask(projectID: projectID,
            expectedGeneration: .initial, approvedAssignment: assignment,
            callerContext: context, callerOwner: owner)
        let fixture = ExplicitSubmissionFixture(app: app, projectID: projectID,
            owner: owner, context: context, setup: setup)
        try await body(fixture)
    }

    private func assertNoInlineProviderWork(_ fixture: ExplicitSubmissionFixture,
                                          file: StaticString = #filePath, line: UInt = #line) throws {
        for table in ["provider_sessions", "provider_turns", "tool_invocations", "context_budget_observations"] {
            XCTAssertEqual(try ExplicitSubmissionSQLite.integer(fixture.app.paths.controlPlaneSQLite,
                "SELECT COUNT(*) FROM \(table)"), 0, table, file: file, line: line)
        }
    }
}

private struct ExplicitSubmissionFixture: Sendable {
    let app: ForgeApp
    let projectID: ProjectID
    let owner: ProjectBindingOwner
    let context: ToolInvocationContext
    let setup: AuthorizedContinuityTaskSetup

    func commit(id: String = "explicit-source", narrative: String = "First exact frozen progress",
                automatic: Bool = false, finalize: Bool = true) async throws -> ContinuityHandoffCommit {
        let source = app.store
        return try await app.projectContexts.repository.withAuthorizedContinuityTask(
            taskID: setup.record.authorization.taskID, correlation: setup.correlation,
            context: context, owner: owner
        ) { authorization in
            try source.handoffCommit(HandoffPacket(id: id, source: .model,
                resumeReady: finalize, clientID: context.clientID.rawValue,
                goal: "Approved task progress", narrative: narrative),
                authorization: authorization, automaticHandoffEnabled: automatic)
        }
    }

    func peer() async throws -> ExplicitSubmissionFixture {
        let other = try await app.projectContexts.repository.authorizeContinuityTask(
            projectID: projectID, expectedGeneration: .initial,
            approvedAssignment: setup.record.assignment, callerContext: context, callerOwner: owner)
        return ExplicitSubmissionFixture(app: app, projectID: projectID,
            owner: owner, context: context, setup: other)
    }

    func policy() throws -> BudgetPolicySelection {
        try app.config.budgetPolicySelection(scope: .init(kind: .projectOverride,
            projectID: projectID.description, projectGeneration: 1))
    }

    func submit(id: String, key: String? = nil) async throws -> ContinuityExplicitStartReceipt {
        var arguments: [String: Any] = ["continuity_id": id]
        if let key { arguments["idempotency_key"] = key }
        let request = try ContinuityExplicitHandoffRequest(arguments: arguments)
        return try await app.continuity.submitAuthorizedHandoff(request,
            taskID: setup.record.authorization.taskID, correlation: setup.correlation,
            context: context, owner: owner, repository: app.projectContexts.repository, config: app.config)
    }
}

private enum ExplicitSubmissionSQLite {
    static func integer(_ url: URL, _ sql: String) throws -> Int {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close_v2(database) }
            throw ContinuityIngressError.integrityFailure("explicit fixture database open")
        }
        defer { sqlite3_close_v2(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ContinuityIngressError.integrityFailure("explicit fixture query prepare")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw ContinuityIngressError.integrityFailure("explicit fixture query row")
        }
        return Int(sqlite3_column_int64(statement, 0))
    }
}
