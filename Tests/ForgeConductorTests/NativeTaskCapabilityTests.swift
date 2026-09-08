import XCTest
import SQLite3
@testable import ForgeConductorCore

final class NativeTaskCapabilityTests: XCTestCase {
    func testCredentialCanonicalEncodingAndDomainSeparation() throws {
        let id = UUID(), bytes = Data(repeating: 73, count: 32)
        let first = try NativeTaskCapabilityCredential(capabilityID: id, epoch: 1, secret: bytes)
        let repeated = try NativeTaskCapabilityCredential(authorizationValue: first.authorizationValue)
        XCTAssertEqual(first.verifier, repeated.verifier)
        XCTAssertNotEqual(first.verifier.sha256, try NativeTaskCapabilityCredential(capabilityID: id, epoch: 2, secret: bytes).verifier.sha256)
        XCTAssertNotEqual(first.verifier.sha256, try NativeTaskCapabilityCredential(capabilityID: UUID(), epoch: 1, secret: bytes).verifier.sha256)
        XCTAssertThrowsError(try NativeTaskCapabilityCredential(authorizationValue: first.authorizationValue.replacingOccurrences(of: ":1:", with: ":01:")))
        XCTAssertThrowsError(try NativeTaskCapabilityCredential(authorizationValue: first.authorizationValue + ":"))
        XCTAssertThrowsError(try NativeTaskSourceLimits(maximumCalls: 65, maximumResultBytes: 65_536, maximumRequestSeconds: 60))
    }

    func testPreparationAndCommandReplayRetainHistoryAcrossRestartAndRevocation() async throws {
        try await withFixture { f in
            let original = try await f.repository.prepareNativeContinuityTask(request: f.request, approvedAssignment: f.assignment)
            XCTAssertTrue(original.replayed)
            let before = try NativeAuthoritySQL.value(f.database, "SELECT assignment_json FROM continuity_task_authorizations")
            XCTAssertEqual(try NativeAuthoritySQL.value(f.database, "SELECT COUNT(*) FROM autonomous_runs"), "0")
            XCTAssertEqual(try NativeAuthoritySQL.value(f.database, "SELECT COUNT(*) FROM native_task_capabilities"), "1")
            XCTAssertEqual(try NativeAuthoritySQL.value(f.database, "SELECT COUNT(*) FROM project_bindings"), "2")
            let next = try NativeTaskCapabilityCredential(capabilityID: f.credential.capabilityID, epoch: 2, secret: Data(repeating: 38, count: 32))
            let rotation = try NativeContinuityTaskRotationRequest(requestID: UUID(), taskID: f.request.taskID,
                capabilityID: f.request.capabilityID, projectID: f.projectID, projectGeneration: .initial, expectedEpoch: 1,
                verifierSHA256: next.verifier.sha256, expiresAt: f.request.expiresAt)
            let rotated = try await f.repository.rotateNativeContinuityTask(request: rotation)
            XCTAssertEqual(rotated.current.epoch, 2)
            await expect(.credentialRejected) { _ = try await f.repository.authenticateNativeTaskCapability(credential: f.credential) }
            await expect(.credentialRejected) {
                _ = try await f.repository.validateContinuityOperationControlAuthority(taskID: f.request.taskID,
                    correlation: f.attachment.setup.correlation, context: f.attachment.context, owner: f.attachment.owner)
            }
            let revoke = try NativeContinuityTaskRevocationRequest(requestID: UUID(), taskID: f.request.taskID,
                capabilityID: f.request.capabilityID, projectID: f.projectID, projectGeneration: .initial, expectedEpoch: 2)
            _ = try await f.repository.revokeNativeContinuityTask(request: revoke)
            await f.repository.close()
            let reopened = try ProjectControlPlaneRepository(databaseURL: f.database, clock: f.clock)
            do {
                let replay = try await reopened.rotateNativeContinuityTask(request: rotation)
                XCTAssertTrue(replay.replayed); XCTAssertEqual(replay.receipt, rotated.receipt)
                XCTAssertEqual(replay.current.state, .revoked); XCTAssertEqual(replay.current.epoch, 3)
                let preparation = try await reopened.prepareNativeContinuityTask(request: f.request, approvedAssignment: f.assignment)
                XCTAssertEqual(preparation.receipt, original.receipt); XCTAssertEqual(preparation.current.state, .revoked)
                await expect(.credentialRejected) { _ = try await reopened.authenticateNativeTaskCapability(credential: next) }
                XCTAssertEqual(try NativeAuthoritySQL.value(f.database, "SELECT assignment_json FROM continuity_task_authorizations"), before)
                XCTAssertEqual(try NativeAuthoritySQL.value(f.database, "SELECT COUNT(*) FROM native_task_commands"), "3")
                XCTAssertEqual(try NativeAuthoritySQL.value(f.database, "SELECT COUNT(*) FROM native_source_requests"), "0")
                await reopened.close()
            } catch { await reopened.close(); throw error }
        }
    }

    func testWrongVerifierCannotDecodeCorruptAssignmentAndOriginChangeIsIrreversible() async throws {
        try await withFixture { f in
            let original = try NativeAuthoritySQL.value(f.database, "SELECT assignment_json FROM continuity_task_authorizations")
            try NativeAuthoritySQL.execute(f.database, "UPDATE continuity_task_authorizations SET assignment_json='{}'")
            let wrong = try NativeTaskCapabilityCredential(capabilityID: f.request.capabilityID, epoch: 1, secret: Data(repeating: 41, count: 32))
            await expect(.credentialRejected) { _ = try await f.repository.authenticateNativeTaskCapability(credential: wrong) }
            do { _ = try await f.repository.authenticateNativeTaskCapability(credential: f.credential); XCTFail("Owned corruption was accepted") }
            catch { XCTAssertNotEqual(error as? NativeTaskCapabilityError, .credentialRejected) }
            try NativeAuthoritySQL.execute(f.database, "UPDATE continuity_task_authorizations SET assignment_json=?", [original])
            try NativeAuthoritySQL.execute(f.database, "UPDATE project_bindings SET active=0 WHERE binding_id=?", [f.attachment.descriptor.originalCallerBindingID.uuidString.lowercased()])
            try NativeAuthoritySQL.execute(f.database, "UPDATE project_bindings SET active=1 WHERE binding_id=?", [f.attachment.descriptor.originalCallerBindingID.uuidString.lowercased()])
            await expect(.credentialRejected) { _ = try await f.repository.authenticateNativeTaskCapability(credential: f.credential) }
            XCTAssertEqual(try NativeAuthoritySQL.value(f.database, "SELECT invalidated FROM continuity_source_dispatch_origins"), "1")
        }
    }

    func testCancellationRollsBackCapabilityCreationAndSourceReservation() async throws {
        try await withFixture { f in
            let cancellation = ToolCallCancellation()
            await f.repository.configureOperationObservers(beforeCommit: { cancellation.cancel() })
            do { _ = try await f.read(cancellation: cancellation); XCTFail("Cancelled reservation committed") }
            catch { XCTAssertTrue(error is CancellationError) }
            await f.repository.configureOperationObservers()
            XCTAssertEqual(try NativeAuthoritySQL.value(f.database, "SELECT COUNT(*) FROM native_source_requests"), "0")
            let secondID = UUID(), cap = UUID()
            let credential = try NativeTaskCapabilityCredential(capabilityID: cap, epoch: 1, secret: Data(repeating: 3, count: 32))
            let request = try NativeContinuityTaskPreparationRequest(requestID: UUID(), taskID: secondID, capabilityID: cap,
                projectID: f.projectID, projectGeneration: .initial, approval: f.request.approval,
                verifierSHA256: credential.verifier.sha256, expiresAt: f.request.expiresAt)
            let cancelled = ToolCallCancellation()
            await f.repository.configureOperationObservers(beforeCommit: { cancelled.cancel() })
            do { _ = try await f.repository.prepareNativeContinuityTask(request: request, approvedAssignment: f.assignment, cancellation: cancelled); XCTFail("Cancelled task committed") }
            catch { XCTAssertTrue(error is CancellationError) }
            await f.repository.configureOperationObservers()
            XCTAssertEqual(try NativeAuthoritySQL.value(f.database, "SELECT COUNT(*) FROM continuity_task_authorizations"), "1")
            XCTAssertEqual(try NativeAuthoritySQL.value(f.database, "SELECT COUNT(*) FROM project_bindings"), "2")
        }
    }

    func testReadDebitSurvivesRevocationAndUnknownExecutionWithoutOutputDisclosure() async throws {
        try await withFixture { f in
            guard case .execute(let admission) = try await f.read() else { return XCTFail("Missing read reservation") }
            try await f.repository.beginContinuitySourceRead(admission: admission, policySelection: f.policy)
            let revoke = try NativeContinuityTaskRevocationRequest(requestID: UUID(), taskID: f.request.taskID,
                capabilityID: f.request.capabilityID, projectID: f.projectID, projectGeneration: .initial, expectedEpoch: 1)
            _ = try await f.repository.revokeNativeContinuityTask(request: revoke)
            await expect(.credentialRejected) {
                _ = try await f.repository.completeContinuitySourceRead(admission: admission, canonicalToolResultJSON: f.result, policySelection: f.policy)
            }
            try await f.repository.finishContinuitySourceReadWithoutDisclosure(admission: admission, outcome: .withheld)
            XCTAssertEqual(try NativeAuthoritySQL.value(f.database, "SELECT state FROM native_source_requests"), "withheld")
            XCTAssertEqual(try NativeAuthoritySQL.value(f.database, "SELECT charged_calls FROM native_source_requests"), "1")
            XCTAssertEqual(try NativeAuthoritySQL.value(f.database, "SELECT COUNT(*) FROM native_source_requests WHERE result_json IS NOT NULL"), "0")
        }
    }

    func testCompletedReadReplayRechecksReducedResultPolicyAndExpiryWithoutRecharge() async throws {
        try await withFixture { f in
            let request = try f.readRequest()
            guard case .execute(let admission) = try await f.read(request: request) else { return XCTFail("Missing reservation") }
            try await f.repository.beginContinuitySourceRead(admission: admission, policySelection: f.policy)
            let receipt = try await f.repository.completeContinuitySourceRead(admission: admission, canonicalToolResultJSON: f.result, policySelection: f.policy)
            guard case .completed(let replay) = try await f.read(request: request) else { return XCTFail("Missing completed replay") }
            XCTAssertEqual(replay, receipt)
            let tiny = BudgetPolicy(tools: .init(maxResultBytes: 1))
            let policy = try BudgetPolicyState(globalPolicy: tiny).resolve(.init(kind: .projectOverride,
                projectID: f.projectID.description, projectGeneration: 1))
            await expect(.budgetExceeded) { _ = try await f.read(request: request, policy: policy) }
            f.clock.advance(3_601)
            await expect(.resultExpired) { _ = try await f.read(request: request) }
            XCTAssertEqual(try NativeAuthoritySQL.value(f.database, "SELECT COUNT(*) FROM native_source_requests"), "1")
            XCTAssertEqual(try NativeAuthoritySQL.value(f.database, "SELECT charged_calls FROM native_source_requests"), "1")
        }
    }

    func testConcurrentReadReservationsAreBoundedAcrossConnectionsAndRestartNeverRedispatchesExecutingRead() async throws {
        try await withFixture { f in
            let other = try ProjectControlPlaneRepository(databaseURL: f.database, clock: f.clock)
            do {
                let request = try f.readRequest()
                guard case .execute(let first) = try await f.read(request: request) else { return XCTFail("Missing first reservation") }
                guard case .inProgress = try await other.admitContinuitySourceRead(request: request,
                    correlation: f.attachment.setup.correlation, context: f.attachment.context, owner: f.attachment.owner, policySelection: f.policy) else {
                    return XCTFail("A duplicate admitted read received a second execution owner")
                }
                try await f.repository.beginContinuitySourceRead(admission: first, policySelection: f.policy)
                guard case .inProgress = try await other.admitContinuitySourceRead(request: request,
                    correlation: f.attachment.setup.correlation, context: f.attachment.context, owner: f.attachment.owner, policySelection: f.policy) else {
                    return XCTFail("An executing read was dispatched twice")
                }
                _ = try await f.read()
                await expect(.budgetExceeded) { _ = try await f.read() }
                f.clock.advance(31)
                await expect(.resultExpired) { _ = try await f.read(request: request) }
                guard case .execute(let next) = try await f.read() else { return XCTFail("Expired records retained a live slot") }
                try await other.beginContinuitySourceRead(admission: next, policySelection: f.policy)
                XCTAssertEqual(try NativeAuthoritySQL.value(f.database, "SELECT COUNT(*) FROM native_source_requests"), "3")
                await other.close()
            } catch { await other.close(); throw error }
        }
    }

    func testSourceReadDeadlineHonorsExplicitRequestAndRetainsFixedReplayDeadline() async throws {
        try await withFixture(maximumRequestSeconds: 60) { f in
            for (requested, seconds) in [(nil, 30), (45_000, 45), (60_000, 60), (5_000, 5)] as [(Int?, Int)] {
                let request = try f.readRequest(deadlineMilliseconds: requested)
                XCTAssertEqual(request.effectiveDeadlineMilliseconds(limits: f.attachment.sourceLimits), seconds * 1_000)
                let cancellation = ToolCallCancellation(timeoutSeconds: 300)
                try cancellation.tightenDeadline(milliseconds: request.effectiveDeadlineMilliseconds(limits: f.attachment.sourceLimits))
                XCTAssertGreaterThan(try XCTUnwrap(cancellation.remainingTimeInterval), TimeInterval(seconds - 1))
                guard case .execute(let admission) = try await f.read(request: request) else { return XCTFail("Missing deadline reservation") }
                XCTAssertEqual(admission.deadline, ISO8601.string(from: f.clock.now().addingTimeInterval(TimeInterval(seconds))))
                f.clock.advance(1)
                guard case .inProgress(let replayDeadline) = try await f.read(request: request) else { return XCTFail("Missing fixed pending replay") }
                XCTAssertEqual(replayDeadline, admission.deadline)
                try await f.repository.finishContinuitySourceReadWithoutDisclosure(admission: admission, outcome: .failed)
            }
            for invalid in [true, "45000", 0, 60_001, 1.5] as [Any] {
                let data = try ForgeJSONCanonicalizationV1.data(from: ["path": "fixture.txt", "deadline_ms": invalid])
                XCTAssertThrowsError(try NativeSourceReadRequest(key: f.readRequest().key, toolName: "fs_read",
                    canonicalArgumentsJSON: data, managerInstanceID: UUID()))
            }
            XCTAssertEqual(try NativeAuthoritySQL.value(f.database, "SELECT COUNT(*) FROM native_source_requests"), "4")
        }
    }

    func testLoweredInFlightPolicyGatesNewExecutionAcrossConnectionsWithoutRevokingRunningRead() async throws {
        try await withFixture { f in
            let other = try ProjectControlPlaneRepository(databaseURL: f.database, clock: f.clock)
            do {
                let initial = try BudgetPolicyState(globalPolicy: BudgetPolicy(tools: .init(maxInFlight: 2))).resolve(
                    .init(kind: .projectOverride, projectID: f.projectID.description, projectGeneration: 1))
                let lowered = try BudgetPolicyState(globalPolicy: BudgetPolicy(tools: .init(maxInFlight: 1))).resolve(
                    .init(kind: .projectOverride, projectID: f.projectID.description, projectGeneration: 1))
                guard case .execute(let first) = try await f.read(policy: initial),
                      case .execute(let second) = try await f.read(policy: initial) else { return XCTFail("Missing original reservations") }
                try await f.repository.beginContinuitySourceRead(admission: first, policySelection: lowered)
                await expect(.budgetExceeded) {
                    try await other.beginContinuitySourceRead(admission: second, policySelection: lowered)
                }
                XCTAssertEqual(try NativeAuthoritySQL.value(f.database,
                    "SELECT state FROM native_source_requests WHERE reservation_id=?", [first.reservationID.uuidString.lowercased()]), "executing")
                XCTAssertEqual(try NativeAuthoritySQL.value(f.database,
                    "SELECT state FROM native_source_requests WHERE reservation_id=?", [second.reservationID.uuidString.lowercased()]), "admitted")
                XCTAssertEqual(try NativeAuthoritySQL.value(f.database, "SELECT COUNT(*) FROM native_source_requests"), "2")
                _ = try await f.repository.completeContinuitySourceRead(admission: first,
                    canonicalToolResultJSON: f.result, policySelection: lowered)
                try await other.beginContinuitySourceRead(admission: second, policySelection: lowered)
                _ = try await other.completeContinuitySourceRead(admission: second,
                    canonicalToolResultJSON: f.result, policySelection: lowered)
                XCTAssertEqual(try NativeAuthoritySQL.value(f.database,
                    "SELECT COUNT(*) FROM native_source_requests WHERE state='completed'"), "2")
                XCTAssertEqual(try NativeAuthoritySQL.value(f.database, "SELECT MAX(charged_calls) FROM native_source_requests"), "2")
                await other.close()
            } catch { await other.close(); throw error }
        }
    }

    func testSourceReadDeadlineClipsToApprovalCredentialExpiryAndEarlierCancellation() async throws {
        try await withFixture(maximumRequestSeconds: 10) { f in
            let request = try f.readRequest(deadlineMilliseconds: 45_000)
            guard case .execute(let admission) = try await f.read(request: request) else { return XCTFail("Missing approval-limited reservation") }
            XCTAssertEqual(admission.deadline, ISO8601.string(from: f.clock.now().addingTimeInterval(10)))
            try await f.repository.finishContinuitySourceReadWithoutDisclosure(admission: admission, outcome: .failed)
            let cancellation = ToolCallCancellation(timeoutSeconds: 8)
            guard case .execute(let shorter) = try await f.read(cancellation: cancellation) else { return XCTFail("Missing caller-limited reservation") }
            let seconds = try XCTUnwrap(ISO8601.date(from: shorter.deadline)).timeIntervalSince(f.clock.now())
            XCTAssertGreaterThanOrEqual(seconds, 6); XCTAssertLessThanOrEqual(seconds, 8)
            try await f.repository.finishContinuitySourceReadWithoutDisclosure(admission: shorter, outcome: .failed)
            f.clock.advance(86_396)
            guard case .execute(let expiring) = try await f.read() else { return XCTFail("Missing expiry-limited reservation") }
            XCTAssertEqual(expiring.deadline, f.request.expiresAt)
        }
    }

    func testFrozenHandoffRecoversAfterSourceCommitBeforeCPReceiptAndCarriesReadDebitOnce() async throws {
        try await withFixture { f in
            guard case .execute(let read) = try await f.read() else { return XCTFail("Missing read") }
            try await f.repository.beginContinuitySourceRead(admission: read, policySelection: f.policy)
            _ = try await f.repository.completeContinuitySourceRead(admission: read, canonicalToolResultJSON: f.result, policySelection: f.policy)
            let packet = HandoffPacket(id: "native-frozen", createdAt: ISO8601.string(from: f.clock.now()),
                updatedAt: ISO8601.string(from: f.clock.now()), resumeReady: true,
                clientID: f.attachment.context.clientID.rawValue, goal: "Actual frozen handoff")
            let prepared = try PreparedContinuitySourceCommit.preparing(packet)
            let request = try NativeSourceCommitRequest(key: .init(sessionID: UUID(), requestIDSHA256: JSONSupport.sha256Hex(Data("commit".utf8))),
                canonicalArgumentsJSON: Data("{}".utf8), managerInstanceID: UUID(), finalize: true)
            guard case .commit(let admission) = try await f.repository.prepareContinuitySourceCommit(request: request,
                correlation: f.attachment.setup.correlation, context: f.attachment.context, owner: f.attachment.owner,
                policySelection: f.policy, prepare: { _ in prepared }) else { return XCTFail("Missing frozen intent") }
            await expect(.sourceFenced) { _ = try await f.read() }
            // A verified source-store commit may succeed while the CP receipt
            // transaction fails. Its first committed packet remains unchanged.
            await f.repository.configureOperationObservers(beforeCommit: { throw NativeTaskCapabilityError.operationBusy })
            do {
                _ = try await f.repository.commitContinuitySourceRequest(admission: admission, commit: { value, auth, automatic in
                    let object = try JSONSerialization.jsonObject(with: value.canonicalPacketJSON) as! [String: Any]
                    return try f.source.handoffCommit(try XCTUnwrap(HandoffPacket.fromDictionary(object)), authorization: auth, automaticHandoffEnabled: automatic)
                }); XCTFail("Injected CP failure did not run")
            } catch { XCTAssertEqual(error as? NativeTaskCapabilityError, .operationBusy) }
            await f.repository.configureOperationObservers()
            XCTAssertEqual(try NativeAuthoritySQL.value(f.database, "SELECT state FROM native_source_requests WHERE method='session_handoff'"), "pending")
            await f.repository.close()
            let reopened = try ProjectControlPlaneRepository(databaseURL: f.database, clock: f.clock)
            do {
                let pending = try await reopened.pendingNativeSourceCommits()
                let reference = try XCTUnwrap(pending.first)
                let recovered = try await reopened.reconcileNativeSourceCommit(reference: reference, commit: { value, auth, automatic in
                    let object = try JSONSerialization.jsonObject(with: value.canonicalPacketJSON) as! [String: Any]
                    return try f.source.handoffCommit(try XCTUnwrap(HandoffPacket.fromDictionary(object)), authorization: auth, automaticHandoffEnabled: automatic)
                })
                let committed = try XCTUnwrap(recovered)
                XCTAssertEqual(committed.revision.identity.revision, 1)
                XCTAssertEqual(committed.revision.canonicalPacketJSON, prepared.canonicalPacketJSON)
                let operationID = try ContinuityIngressOperationIdentity(revision: committed.revision).operationID
                let accepted = try await reopened.acceptContinuityIngress(source: committed.revision, operationID: operationID, policySelection: f.policy)
                let repeated = try await reopened.acceptContinuityIngress(source: committed.revision, operationID: operationID, policySelection: f.policy)
                XCTAssertEqual(accepted, repeated)
                XCTAssertEqual(try NativeAuthoritySQL.value(f.database, "SELECT charged_calls FROM native_source_run_offsets"), "1")
                XCTAssertEqual(try NativeAuthoritySQL.value(f.database, "SELECT COUNT(*) FROM native_source_run_offsets"), "1")
                XCTAssertEqual(try NativeAuthoritySQL.value(f.database, "SELECT COUNT(*) FROM provider_sessions"), "0")
                let lease = try await reopened.acquireRunLease(runID: accepted.runID, ownerID: "native-budget-proof")
                let envelope = try ContinuitySourceBootstrapEnvelope(acceptance: accepted, bootstrapNonce: UUID())
                let approvedBytes = try NativeAuthoritySQL.value(f.database, "SELECT assignment_json FROM continuity_task_authorizations")
                let grant = try await reopened.issueContinuityBootstrapGrant(envelope: envelope, candidateID: UUID(), lease: lease)
                XCTAssertEqual(grant.envelope.authorization.authorizationScope.allowedTools, ["fs_read"])
                XCTAssertFalse(ToolGrantSemantics.grants(tool: "context_get", from: grant.envelope.authorization.authorizationScope.allowedTools))
                let session = ProviderSessionIntent(sessionID: grant.sessionID, runID: accepted.runID, projectID: f.projectID,
                    projectGeneration: .initial, providerID: f.assignment.providerID, adapterID: f.assignment.adapterID, modelKey: f.assignment.modelKey,
                    handoffID: envelope.handoffID, operationID: accepted.operationID, idempotencyKey: "source-offset-root",
                    bootstrapNonceSHA256: JSONSupport.sha256Hex(envelope.bootstrapNonce.uuidString.lowercased()),
                    handoffSHA256: envelope.envelopeSHA256, status: .candidate, accepted: false)
                try await reopened.reserveProviderSession(session, lease: lease, bootstrapGrant: grant)
                let turn = ProviderTurnIntent(runID: accepted.runID, sessionID: grant.sessionID, operationID: accepted.operationID,
                    projectID: f.projectID, projectGeneration: .initial, kind: .bootstrap, idempotencyKey: "source-offset-root-turn",
                    inputSHA256: String(repeating: "a", count: 64), toolSchemaSHA256: String(repeating: "b", count: 64))
                _ = try await reopened.persistProviderTurnIntent(turn, lease: lease, bootstrapGrant: grant)
                _ = try await reopened.transitionProviderTurn(turnID: turn.turnID, expected: .intent, to: .submitted, lease: lease, bootstrapGrant: grant)
                let call = try ProviderToolCall(callID: "source-offset-call", name: "context_get",
                    argumentsJSON: ForgeJSONCanonicalizationV1.data(from: ["handoff_id": committed.revision.identity.continuityID]))
                let provider = try ProviderTurn(requestID: "source-offset-request", responseID: "source-offset-response",
                    providerID: f.assignment.providerID, providerVersion: "fixture", modelKey: f.assignment.modelKey,
                    messages: [], toolCalls: [call], usage: nil, completed: true, finishReason: .toolCalls)
                _ = try await reopened.transitionProviderTurn(turnID: turn.turnID, expected: .submitted, to: .completed,
                    lease: lease, providerRequestID: provider.requestID, providerResponseID: provider.responseID, bootstrapGrant: grant)
                let foreignCall = try ProviderToolCall(callID: call.callID, name: "context_get",
                    argumentsJSON: ForgeJSONCanonicalizationV1.data(from: ["handoff_id": "another-source"]))
                let foreignResult = try ProviderTurn(requestID: provider.requestID, responseID: provider.responseID,
                    providerID: provider.providerID, providerVersion: provider.providerVersion, modelKey: provider.modelKey,
                    messages: [], toolCalls: [foreignCall], usage: nil, completed: true, finishReason: .toolCalls)
                do {
                    try await reopened.recordContinuityBootstrapProviderResult(grant: grant, turnID: turn.turnID, result: foreignResult, lease: lease)
                    XCTFail("Exact recovery grant accepted another source ID")
                } catch { XCTAssertEqual(error as? ContinuityIngressError, .authorityMismatch) }
                try await reopened.recordContinuityBootstrapProviderResult(grant: grant, turnID: turn.turnID, result: provider, lease: lease)
                let intent = ToolInvocationIntent(turnID: turn.turnID, runID: accepted.runID, sessionID: grant.sessionID,
                    projectID: f.projectID, projectGeneration: .initial, providerCallID: call.callID, toolName: call.name,
                    replayClass: .readOnly, idempotencyKey: nil, argumentsSHA256: JSONSupport.sha256Hex(call.argumentsJSON))
                do {
                    _ = try await reopened.persistToolInvocationIntent(intent, lease: lease, sourcePolicy: f.policy)
                    XCTFail("Ordinary context_get bypassed the exact recovery grant")
                } catch { XCTAssertEqual(error as? AutonomyError, .bootstrapRequired(accepted.runID)) }
                _ = try await reopened.persistToolInvocationIntent(intent, lease: lease, bootstrapGrant: grant, bootstrapPolicy: f.policy)
                let lowered = try BudgetPolicyState(globalPolicy: BudgetPolicy(tools: .init(callsPerTurn: 1, callsPerSession: 1,
                    callsPerRun: 1, maxInFlight: 1), automaticHandoffEnabled: true)).resolve(
                        .init(kind: .projectOverride, projectID: f.projectID.description, projectGeneration: 1))
                await expect(.budgetExceeded) {
                    _ = try await reopened.persistToolInvocationIntent(intent, lease: lease, bootstrapGrant: grant, bootstrapPolicy: lowered)
                }
                await expect(.budgetExceeded) {
                    try await reopened.preflightContinuityBootstrapRetrieval(grant: grant, rootTurnID: turn.turnID, lease: lease, policy: lowered)
                }
                let inclusive = try BudgetPolicyState(globalPolicy: BudgetPolicy(tools: .init(callsPerTurn: 1, callsPerSession: 1,
                    callsPerRun: 2, maxInFlight: 1), automaticHandoffEnabled: true)).resolve(
                        .init(kind: .projectOverride, projectID: f.projectID.description, projectGeneration: 1))
                let reserved = try await reopened.persistToolInvocationIntent(intent, lease: lease, bootstrapGrant: grant, bootstrapPolicy: inclusive)
                XCTAssertEqual(reserved.invocationID, intent.invocationID)
                XCTAssertEqual(try NativeAuthoritySQL.value(f.database, "SELECT COUNT(*) FROM tool_invocations"), "1")
                XCTAssertEqual(try NativeAuthoritySQL.value(f.database, "SELECT charged_calls FROM native_source_run_offsets"), "1")
                _ = try await reopened.transitionToolInvocation(invocationID: intent.invocationID, expected: .intent,
                    to: .executing, lease: lease, bootstrapGrant: grant)
                let proof = try await reopened.executeContinuityBootstrapRetrieval(grant: grant,
                    invocationID: intent.invocationID, lease: lease) { expected in
                    let actual = try f.source.continuityHandoffRevision(identity: expected.identity, authorization: expected.authorization)
                    let payload: [String: Any] = ["ok": true, "found": true,
                        "packet": try JSONSerialization.jsonObject(with: actual.canonicalPacketJSON),
                        "continuity_id": actual.identity.continuityID, "revision": actual.identity.revision,
                        "packet_sha256": actual.identity.packetSHA256]
                    return try ContinuityBootstrapReadResult(canonicalToolResultJSON:
                        ForgeJSONCanonicalizationV1.data(from: ["ok": true, "is_error": false, "payload": payload]))
                }
                XCTAssertEqual(proof.sourceIdentity, committed.revision.identity)
                XCTAssertEqual(try NativeAuthoritySQL.value(f.database, "SELECT COUNT(*) FROM continuity_bootstrap_retrieval_proofs"), "1")
                XCTAssertEqual(try NativeAuthoritySQL.value(f.database, "SELECT assignment_json FROM continuity_task_authorizations"), approvedBytes)
                let attachment = try await reopened.authenticateNativeTaskCapability(credential: f.credential)
                guard case .completed(let replay) = try await reopened.prepareContinuitySourceCommit(request: request,
                    correlation: attachment.setup.correlation, context: attachment.context, owner: attachment.owner,
                    policySelection: f.policy, prepare: { _ in throw NativeTaskCapabilityError.integrityFailure }) else { return XCTFail("Missing immutable commit replay") }
                XCTAssertEqual(replay, committed)
                await reopened.close()
            } catch { await reopened.close(); throw error }
        }
    }

    func testVerifiedCapabilitySixMigrationPreservesExistingTaskAndOriginWithoutBackfill() async throws {
        try await withFixture { f in
            let assignment = try NativeAuthoritySQL.value(f.database, "SELECT assignment_json FROM continuity_task_authorizations")
            await f.repository.close()
            try NativeAuthoritySQL.execute(f.database, "ALTER TABLE provider_turns DROP COLUMN source_preflight_sha256; ALTER TABLE provider_turns DROP COLUMN source_preflight_json; DROP TABLE native_source_provider_run_offsets; DROP TABLE native_source_provider_calls; DROP TABLE native_source_capability_checks; DROP TABLE native_source_provider_turns; DROP TABLE native_source_conversations; DROP TABLE native_source_run_offsets; DROP TABLE native_source_requests; DROP TABLE native_task_commands; DROP TABLE native_task_capabilities;")
            let reopened = try ProjectControlPlaneRepository(databaseURL: f.database, clock: f.clock)
            do {
                XCTAssertEqual(try NativeAuthoritySQL.value(f.database, "SELECT assignment_json FROM continuity_task_authorizations"), assignment)
                XCTAssertEqual(try NativeAuthoritySQL.value(f.database, "SELECT COUNT(*) FROM native_task_capabilities"), "0")
                XCTAssertEqual(try NativeAuthoritySQL.value(f.database, "SELECT COUNT(*) FROM continuity_source_dispatch_origins"), "1")
                let manifest = try Data(contentsOf: VerifiedMigrationBackup.activeManifestURL(for: f.database, scope: .continuityIngress))
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: manifest) as? [String: Any])
                XCTAssertEqual(object["source_version"] as? Int, 7); XCTAssertEqual(object["target_version"] as? Int, 8)
                await expect(.requestConflict) { _ = try await reopened.prepareNativeContinuityTask(request: f.request, approvedAssignment: f.assignment) }
                await reopened.close()
            } catch { await reopened.close(); throw error }
        }
    }

    private func expect(_ expected: NativeTaskCapabilityError, file: StaticString = #filePath, line: UInt = #line,
        _ body: () async throws -> Void) async {
        do { try await body(); XCTFail("Expected native task denial", file: file, line: line) }
        catch { XCTAssertEqual(error as? NativeTaskCapabilityError, expected, file: file, line: line) }
    }

    private func withFixture(maximumRequestSeconds: Int = 30, _ body: (NativeAuthorityFixture) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-task-authority-\(UUID().uuidString)").resolvingSymlinksInPath()
        let project = root.appendingPathComponent("project"), database = root.appendingPathComponent("control.sqlite3")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let clock = NativeAuthorityClock(), repository = try ProjectControlPlaneRepository(databaseURL: database, clock: clock)
        let source = try SQLiteStore(path: root.appendingPathComponent("source.sqlite3")), projectID = ProjectID()
        do {
            _ = try await repository.registerProjectUnchecked(projectID: projectID, displayName: "Native authority", canonicalRoot: project)
            let approval = try NativeContinuityTaskApproval(assignmentID: "native-read", assignmentBytes: Data("Read approved fixture".utf8),
                mission: "Read approved fixture", providerID: "lmstudio", adapterID: "forge.native-session-host", modelKey: "fixture/native",
                allowedTools: ["fs_read"], completionGates: ["G04"], resourceProfile: .automatic, filesystemAccess: "read_only", networkAllowed: false,
                maximumInlineOutputBytes: 65_536, sourceLimits: .init(maximumCalls: 64, maximumResultBytes: 65_536, maximumRequestSeconds: maximumRequestSeconds))
            let scope = ToolAuthorizationScope(canonicalRoots: [project], writableRoots: [], allowedTools: ["fs_read"], networkAllowed: false, maximumInlineOutputBytes: 65_536)
            let assignment = try ContinuityTaskAssignment(assignmentID: approval.assignmentID, assignmentBytes: approval.assignmentBytes, mission: approval.mission,
                providerID: approval.providerID, adapterID: approval.adapterID, modelKey: approval.modelKey,
                specification: .init(allowedTools: approval.allowedTools, completionGates: approval.completionGates), authorizationScope: scope)
            let cap = UUID(), credential = try NativeTaskCapabilityCredential(capabilityID: cap, epoch: 1, secret: Data(repeating: 17, count: 32))
            let request = try NativeContinuityTaskPreparationRequest(requestID: UUID(), taskID: UUID(), capabilityID: cap, projectID: projectID,
                projectGeneration: .initial, approval: approval, verifierSHA256: credential.verifier.sha256,
                expiresAt: ISO8601.string(from: clock.now().addingTimeInterval(86_400)))
            _ = try await repository.prepareNativeContinuityTask(request: request, approvedAssignment: assignment)
            let attachment = try await repository.authenticateNativeTaskCapability(credential: credential)
            let policy = try BudgetPolicyState(globalPolicy: BudgetPolicy(automaticHandoffEnabled: true)).resolve(
                .init(kind: .projectOverride, projectID: projectID.description, projectGeneration: 1))
            try await body(.init(database: database, repository: repository, source: source, projectID: projectID, clock: clock,
                request: request, assignment: assignment, credential: credential, attachment: attachment, policy: policy))
            source.close(); await repository.close(); try FileManager.default.removeItem(at: root)
        } catch { source.close(); await repository.close(); try? FileManager.default.removeItem(at: root); throw error }
    }
}

private struct NativeAuthorityFixture: Sendable {
    let database: URL, repository: ProjectControlPlaneRepository, source: SQLiteStore, projectID: ProjectID, clock: NativeAuthorityClock
    let request: NativeContinuityTaskPreparationRequest, assignment: ContinuityTaskAssignment, credential: NativeTaskCapabilityCredential
    let attachment: AuthenticatedContinuityTaskAttachment, policy: BudgetPolicySelection
    var result: Data { get throws { try ForgeJSONCanonicalizationV1.data(from: ["ok": true, "is_error": false, "payload": ["text": "actual read result"]]) } }
    func readRequest(deadlineMilliseconds: Int? = nil) throws -> NativeSourceReadRequest {
        var arguments: [String: Any] = ["path": "fixture.txt"]
        if let deadlineMilliseconds { arguments["deadline_ms"] = deadlineMilliseconds }
        return try .init(key: .init(sessionID: UUID(), requestIDSHA256: JSONSupport.sha256Hex(Data(UUID().uuidString.utf8))),
            toolName: "fs_read", canonicalArgumentsJSON: ForgeJSONCanonicalizationV1.data(from: arguments), managerInstanceID: UUID())
    }
    func read(request: NativeSourceReadRequest? = nil, policy selected: BudgetPolicySelection? = nil,
        cancellation: ToolCallCancellation? = nil) async throws -> NativeSourceReadAdmissionResult {
        try await repository.admitContinuitySourceRead(request: request ?? readRequest(), correlation: attachment.setup.correlation,
            context: attachment.context, owner: attachment.owner, policySelection: selected ?? policy, cancellation: cancellation)
    }
}
private final class NativeAuthorityClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); value.addTimeInterval(seconds); lock.unlock() }
}
private enum NativeAuthoritySQL {
    static func execute(_ url: URL, _ sql: String, _ bindings: [String] = []) throws {
        try connection(url) { db in
            if bindings.isEmpty {
                guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw NativeTaskCapabilityError.integrityFailure }; return
            }
            try statement(db, sql, bindings) { guard sqlite3_step($0) == SQLITE_DONE else { throw NativeTaskCapabilityError.integrityFailure } }
        }
    }
    static func value(_ url: URL, _ sql: String, _ bindings: [String] = []) throws -> String {
        try connection(url) { db in try statement(db, sql, bindings) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { throw NativeTaskCapabilityError.integrityFailure }
            return String(cString: text)
        } }
    }
    private static func statement<T>(_ db: OpaquePointer, _ sql: String, _ values: [String], _ body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw NativeTaskCapabilityError.integrityFailure }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() { _ = sqlite3_bind_text(statement, Int32(index + 1), value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        return try body(statement)
    }
    private static func connection<T>(_ url: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else { throw NativeTaskCapabilityError.integrityFailure }
        defer { sqlite3_close_v2(db) }; return try body(db)
    }
}
