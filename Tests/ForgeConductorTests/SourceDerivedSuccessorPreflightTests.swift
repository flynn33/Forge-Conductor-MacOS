import XCTest
import SQLite3
#if SWIFT_PACKAGE
import ForgeNativeSessionHostPlugin
#endif
@testable import ForgeConductorCore

final class SourceDerivedSuccessorPreflightTests: XCTestCase, @unchecked Sendable {
    func testBootstrapAcknowledgementGetterReturnsExactProofAndRejectsDifferentParent() async throws {
        try await withFixture { fixture in
            let sessionID = try sourceDerivedUnwrap(fixture.run.activeSessionID)
            let result = try sourceDerivedUnwrap(try await fixture.repository.sourceDerivedBootstrapAcknowledgement(
                runID: fixture.run.runID, sessionID: sessionID,
                previousResponseID: fixture.bootstrapAcknowledgement.responseID, lease: fixture.lease))
            XCTAssertEqual(result.turn, fixture.bootstrapAcknowledgement)
            XCTAssertEqual(result.acknowledgementProviderTurnID,
                UUID(uuidString: fixture.bootstrapAcknowledgement.requestID))
            XCTAssertEqual(result.capabilities.providerID, fixture.bootstrapAcknowledgement.providerID)
            XCTAssertEqual(result.capabilities.modelKey, fixture.bootstrapAcknowledgement.modelKey)
            XCTAssertEqual(result.capabilities.providerInstanceID, fixture.bootstrapAcknowledgement.providerInstanceID)
            XCTAssertEqual(result.capabilities.contextLength, fixture.bootstrapAcknowledgement.usage?.capacity)
            let observed = await fixture.transport.snapshot()
            let root = try sourceDerivedUnwrap(observed.roots.first)
            let acknowledgement = try sourceDerivedUnwrap(observed.followups.first)
            let expectedRoot = try await SourceBootstrapFixtureWire.root(root, maximumOutputTokens: 1_024)
            let expectedACK = try await SourceBootstrapFixtureWire.continuation(acknowledgement, maximumOutputTokens: 1_024)
            XCTAssertEqual(result.preflight, expectedACK)
            XCTAssertGreaterThan(result.retainedContextSerializedBytes, expectedRoot.bodyByteCount + expectedACK.bodyByteCount,
                "Retained bootstrap history must include the actual provider responses as well as both POST bodies")
            let activation = try await fixture.repository.sourceActivationReceipt(runID: fixture.run.runID,
                operationID: fixture.acceptance.operationID, lease: fixture.lease)
            XCTAssertEqual(result.activationReceiptSHA256, try sourceDerivedUnwrap(activation).receiptSHA256)
            do {
                _ = try await fixture.repository.sourceDerivedBootstrapAcknowledgement(runID: fixture.run.runID,
                    sessionID: sessionID, previousResponseID: "different-ack-parent", lease: fixture.lease)
                XCTFail("A different response parent borrowed the accepted ACK context")
            } catch { XCTAssertEqual(error as? ContinuitySourceActivationError, .proofRequired) }
            let after = try await fixture.repository.sourceDerivedBootstrapAcknowledgement(runID: fixture.run.runID,
                sessionID: sessionID, previousResponseID: fixture.bootstrapAcknowledgement.responseID, lease: fixture.lease)
            XCTAssertEqual(after, result, "Rejected correlation must not alter or recreate bootstrap evidence")
        }
    }

    func testBootstrapAcknowledgementGetterRejectsMissingCorruptAndMismatchedProof() async throws {
        for corruption in [SourceDerivedFixture.ACKCorruption.missingPreflight, .corruptResult,
                           .differentProviderVersion, .differentProviderInstance] {
            try await withFixture { fixture in
                let sessionID = try sourceDerivedUnwrap(fixture.run.activeSessionID)
                let before = try sourceDerivedUnwrap(try await fixture.repository.sourceDerivedBootstrapAcknowledgement(
                    runID: fixture.run.runID, sessionID: sessionID,
                    previousResponseID: fixture.bootstrapAcknowledgement.responseID, lease: fixture.lease))
                XCTAssertEqual(before.turn, fixture.bootstrapAcknowledgement)
                try fixture.corruptAcknowledgement(corruption, turnID: before.acknowledgementProviderTurnID)
                do {
                    _ = try await fixture.repository.sourceDerivedBootstrapAcknowledgement(runID: fixture.run.runID,
                        sessionID: sessionID, previousResponseID: fixture.bootstrapAcknowledgement.responseID, lease: fixture.lease)
                    XCTFail("Damaged ACK provenance was accepted: \(corruption)")
                } catch {
                    if corruption != .corruptResult {
                        XCTAssertEqual(error as? ContinuitySourceActivationError, .proofRequired)
                    } else {
                        guard case ContinuityIngressError.integrityFailure = error else {
                            return XCTFail("Unexpected corrupt ACK error: \(error)")
                        }
                    }
                }
            }
        }
    }

    func testNativeSourceCarryoverPreservesReservedNilSchemaAndConsumesExactSuccessorOutput() async throws {
        try await withFixture { fixture in
            let before = try await fixture.repository.pendingAutomaticContinuation(runID: fixture.run.runID)
            let reserved = try sourceDerivedUnwrap(before)
            XCTAssertNil(reserved.intent.toolSchemaSHA256)
            XCTAssertEqual(reserved.intent.kind, .automaticContinuation)
            let carryover = try sourceDerivedUnwrap(try await fixture.repository.nativeSourceBudgetCarryover(runID: fixture.run.runID))
            XCTAssertEqual(carryover.taskID, fixture.taskID)
            XCTAssertEqual(carryover.runID, fixture.run.runID)
            XCTAssertEqual(carryover.acceptanceSHA256, fixture.acceptance.receiptSHA256)
            XCTAssertEqual(carryover.ceilings.maximumOutputTokens, 1_024)
            let acknowledgementUsage = try sourceDerivedUnwrap(fixture.bootstrapAcknowledgement.usage)
            let identity = ContextBudgetIdentity(runID: fixture.run.runID, projectID: fixture.run.projectID,
                projectGeneration: fixture.run.projectGeneration, sessionID: try sourceDerivedUnwrap(fixture.run.activeSessionID))
            await fixture.transport.observeFirstOrdinaryDispatch { [repository = fixture.repository] in
                let state = try sourceDerivedUnwrap(try await repository.contextBudgetState(identity: identity))
                let accounting = try sourceDerivedUnwrap(state.latestObservation?.accounting)
                XCTAssertEqual(accounting.rawProviderUsage, acknowledgementUsage,
                    "The first ordinary POST must be seeded from the actual bootstrap ACK")
                let retained = try sourceDerivedUnwrap(accounting.retainedInputTokens)
                XCTAssertGreaterThan(retained, acknowledgementUsage.inputTokens + acknowledgementUsage.outputTokens,
                    "The pending ordinary input must be charged on top of the exact ACK context")
                XCTAssertLessThan(retained, SourceDerivedTransport.initialSourceInputTokens,
                    "The separate source conversation's prior usage must not become successor retained context")
            }
            let stepper = try fixture.stepper()
            let (intent, pending, context) = try await fixture.prepare(stepper)
            let outcome = try await stepper.execute(intent, run: pending, context: context, lease: fixture.lease)
            guard case .continued(let work) = outcome else { return XCTFail("Expected actual source continuation consumption: \(outcome)") }
            XCTAssertEqual(work.metadata["provider_response_id"], "successor-consumed")
            let after = try await fixture.repository.providerTurn(reserved.intent.turnID)
            XCTAssertEqual(after?.intent, reserved.intent, "First submission cannot rewrite the reserved nil schema pin")
            XCTAssertEqual(after?.state, .completed)
            let stored = try await fixture.repository.sourceDerivedProviderTurnPreflight(
                turnID: reserved.intent.turnID, lease: fixture.lease)
            XCTAssertNil(try sourceDerivedUnwrap(stored).intent.toolSchemaSHA256)
            let observed = await fixture.transport.snapshot()
            XCTAssertEqual(observed.roots.count, 1, "Only the actual bootstrap creates a root")
            XCTAssertEqual(observed.followups.count, 3, "ACK, reserved continuation, and exact output consumption")
            XCTAssertEqual(observed.budgetChecks, 1)
            XCTAssertTrue(observed.consumedExactOutput)
            let input = try sourceDerivedUnwrap(observed.followups.last?.input.first)
            guard case .functionCallOutput(let callID, let output) = input else { return XCTFail("Missing retained function output") }
            XCTAssertEqual(callID, "successor-read-call")
            XCTAssertEqual(try JSONSupport.object(from: Data(output.utf8))["content"] as? String, fixture.marker)
            XCTAssertNil(try JSONSupport.object(from: Data(output.utf8))["payload"])
            let operation = try sourceDerivedUnwrap(fixture.operation())
            XCTAssertTrue(operation.isResumed)
            XCTAssertNotNil(operation.resumedReceiptSHA256)
        }
    }

    func testInheritedOutputCapAndActualBodyLimitRejectBeforeOrdinaryPost() async throws {
        for mode in [SourceDerivedTransport.Mode.oversizedOutput, .smallBody] {
            try await withFixture { fixture in
                let reserved = try sourceDerivedUnwrap(try await fixture.repository.pendingAutomaticContinuation(runID: fixture.run.runID))
                let admittedShape = try await fixture.automaticPreflight(reserved)
                XCTAssertEqual(admittedShape.limits.maximumOutputTokens, 1_024)
                XCTAssertGreaterThan(admittedShape.bodyByteCount, 1_024,
                    "The bounded fixture must actually exceed the selected transport body cap")
                await fixture.transport.setMode(mode)
                let stepper = try fixture.stepper()
                let (intent, pending, context) = try await fixture.prepare(stepper)
                do {
                    _ = try await stepper.execute(intent, run: pending, context: context, lease: fixture.lease)
                    XCTFail("Source-derived dispatch ignored \(mode)")
                } catch {
                    if mode == .oversizedOutput { XCTAssertTrue(error is ContextBudgetError, "Unexpected error: \(error)") }
                    else { XCTAssertTrue(error is LMStudioProviderError, "Unexpected error: \(error)") }
                }
                let observed = await fixture.transport.snapshot()
                XCTAssertEqual(observed.roots.count, 1)
                XCTAssertEqual(observed.followups.count, 1, "No ordinary provider POST may occur after failed preflight")
                let after = try await fixture.repository.providerTurn(reserved.intent.turnID)
                XCTAssertEqual(after?.intent, reserved.intent)
                XCTAssertEqual(after?.state, .intent)
                XCTAssertFalse(try sourceDerivedUnwrap(fixture.operation()).isResumed)
            }
        }
    }

    func testCompletedStepReplayUsesRetainedResponsesWithoutFreshProbeOrPost() async throws {
        try await withFixture { fixture in
            let reserved = try sourceDerivedUnwrap(try await fixture.repository.pendingAutomaticContinuation(runID: fixture.run.runID))
            let first = try fixture.stepper()
            let (intent, pending, context) = try await fixture.prepare(first)
            _ = try await first.execute(intent, run: pending, context: context, lease: fixture.lease)
            let completed = await fixture.transport.snapshot()
            XCTAssertTrue(completed.consumedExactOutput)
            let current = try sourceDerivedUnwrap(try await fixture.repository.autonomousRun(pending.runID))
            XCTAssertEqual(current.specification.work.pendingIntent, intent, "Simulate interruption before applying the step outcome")
            let completedTurn = try sourceDerivedUnwrap(try await fixture.repository.providerTurn(reserved.intent.turnID))
            let reformattedUsage = try fixture.reformatCompletedUsage(completedTurn)
            let retainedTurn = try sourceDerivedUnwrap(try await fixture.repository.providerTurn(reserved.intent.turnID))
            XCTAssertEqual(retainedTurn.usageJSON, reformattedUsage)
            XCTAssertNotEqual(retainedTurn.usageJSON, completedTurn.usageJSON)
            XCTAssertEqual(retainedTurn.intent, completedTurn.intent)
            XCTAssertEqual(retainedTurn.state, .completed)
            XCTAssertEqual(retainedTurn.providerRequestID, completedTurn.providerRequestID)
            XCTAssertEqual(retainedTurn.providerResponseID, completedTurn.providerResponseID)
            let restarted = try fixture.stepper()
            let replay = try await restarted.execute(intent, run: current, context: context, lease: fixture.lease)
            guard case .continued(let work) = replay else { return XCTFail("Expected exact completed response replay") }
            XCTAssertEqual(work.metadata["provider_response_id"], "successor-consumed")
            let after = await fixture.transport.snapshot()
            XCTAssertEqual(after.probes, completed.probes)
            XCTAssertEqual(after.roots.count, completed.roots.count)
            XCTAssertEqual(after.followups.count, completed.followups.count)
            XCTAssertEqual(after.followups.last?.input, completed.followups.last?.input)
            let replayedTurn = try await fixture.repository.providerTurn(reserved.intent.turnID)
            XCTAssertEqual(replayedTurn, retainedTurn, "Semantic usage replay must not rewrite a completed receipt")
        }
    }

    func testCompletedStepReplayAtSavedToolLimitOnePreservesHistoricalChildChain() async throws {
        try await withFixture { fixture in
            let reserved = try sourceDerivedUnwrap(try await fixture.repository.pendingAutomaticContinuation(runID: fixture.run.runID))
            let first = try fixture.stepper()
            let (intent, pending, context) = try await fixture.prepare(first)
            _ = try await first.execute(intent, run: pending, context: context, lease: fixture.lease)
            let completed = await fixture.transport.snapshot()
            XCTAssertTrue(completed.consumedExactOutput)
            let current = try sourceDerivedUnwrap(try await fixture.repository.autonomousRun(pending.runID))
            XCTAssertEqual(current.specification.work.pendingIntent, intent, "Simulate interruption before applying the step outcome")
            let completedTurn = try sourceDerivedUnwrap(try await fixture.repository.providerTurn(reserved.intent.turnID))
            let reformattedUsage = try fixture.reformatCompletedUsage(completedTurn)
            let retainedTurn = try sourceDerivedUnwrap(try await fixture.repository.providerTurn(reserved.intent.turnID))
            XCTAssertEqual(retainedTurn.usageJSON, reformattedUsage)
            XCTAssertNotEqual(retainedTurn.usageJSON, completedTurn.usageJSON)
            XCTAssertEqual(retainedTurn.intent, completedTurn.intent)
            XCTAssertEqual(retainedTurn.state, .completed)
            XCTAssertEqual(retainedTurn.providerRequestID, completedTurn.providerRequestID)
            XCTAssertEqual(retainedTurn.providerResponseID, completedTurn.providerResponseID)
            _ = try fixture.app.config.update(ManagerSettingsPatch(continuityRolloverToolCalls: 1))
            XCTAssertEqual(fixture.app.config.model.sessions.continuityRolloverToolCalls, 1)
            let restarted = try fixture.stepper()
            let replay = try await restarted.execute(intent, run: current, context: context, lease: fixture.lease)
            guard case .continued(let work) = replay else { return XCTFail("Expected exact completed response replay") }
            XCTAssertEqual(work.metadata["provider_response_id"], "successor-consumed")
            let after = await fixture.transport.snapshot()
            XCTAssertEqual(after.probes, completed.probes)
            XCTAssertEqual(after.roots.count, completed.roots.count)
            XCTAssertEqual(after.followups.count, completed.followups.count)
            XCTAssertEqual(after.followups.last?.input, completed.followups.last?.input)
            let replayedTurn = try await fixture.repository.providerTurn(reserved.intent.turnID)
            XCTAssertEqual(replayedTurn, retainedTurn, "Semantic usage replay must not rewrite a completed receipt")
            let countRequest = try await fixture.repository.pendingContextBudgetActionRequest(runID: pending.runID)
            XCTAssertNil(countRequest, "Historical source replay must finish its retained child chain without a new count request")
        }
    }

    func testCompletedLookupRejectsDifferentResponseIDAndUsage() async throws {
        for scenario in [SourceDerivedLookupScenario.differentResponseID, .differentUsage] {
            try await assertRejectedCompletedLookup(scenario)
        }
    }

    func testCompletedLookupRevalidatesCancellationAndReplacedLeaseAfterSuspension() async throws {
        for scenario in [SourceDerivedLookupScenario.cancelled, .replacedLease] {
            try await assertRejectedCompletedLookup(scenario)
        }
    }

    private func assertRejectedCompletedLookup(_ scenario: SourceDerivedLookupScenario) async throws {
        try await withFixture { fixture in
            let reserved = try sourceDerivedUnwrap(try await fixture.repository.pendingAutomaticContinuation(runID: fixture.run.runID))
            let first = try fixture.stepper()
            let (intent, pending, context) = try await fixture.prepare(first)
            _ = try await first.execute(intent, run: pending, context: context, lease: fixture.lease)
            let completed = try sourceDerivedUnwrap(try await fixture.repository.providerTurn(reserved.intent.turnID))
            XCTAssertEqual(completed.state, .completed)
            let before = await fixture.transport.snapshot()
            XCTAssertTrue(before.consumedExactOutput)
            let current = try sourceDerivedUnwrap(try await fixture.repository.autonomousRun(pending.runID))
            XCTAssertEqual(current.specification.work.pendingIntent, intent)
            let lookup = SourceDerivedLookupProvider(base: try fixture.provider(), scenario: scenario)
            let replay = try fixture.stepper(provider: lookup)
            let task = Task {
                try await replay.execute(intent, run: current, context: context, lease: fixture.lease)
            }
            var replacement: RunLease?
            do {
                try await lookup.waitUntilEntered()
                let actualReceipt = try sourceDerivedUnwrap(await lookup.originalReceipt())
                XCTAssertEqual(actualReceipt.requestID, completed.providerRequestID)
                XCTAssertEqual(actualReceipt.responseID, completed.providerResponseID,
                    "The interceptor must begin with the actual durably completed receipt")
                let identity = ContextBudgetIdentity(runID: current.runID, projectID: current.projectID,
                    projectGeneration: current.projectGeneration, sessionID: try sourceDerivedUnwrap(current.activeSessionID))
                let budgetAtLookup = try await fixture.repository.contextBudgetState(identity: identity)
                let observationsAtLookup = try await fixture.repository.contextBudgetObservations(identity: identity)
                let runAtLookup = try await fixture.repository.autonomousRun(current.runID)
                switch scenario {
                case .cancelled:
                    task.cancel()
                case .replacedLease:
                    let released = try await fixture.repository.releaseRunLease(fixture.lease)
                    XCTAssertTrue(released)
                    let newer = try await fixture.repository.acquireRunLease(runID: current.runID,
                        ownerID: "replacement-successor-owner")
                    replacement = newer
                    XCTAssertNotEqual(newer.ownerID, fixture.lease.ownerID)
                    let lateRelease = try await fixture.repository.releaseRunLease(fixture.lease)
                    XCTAssertFalse(lateRelease, "An old owner cannot release the replacement lease")
                case .differentResponseID, .differentUsage:
                    break
                }
                // The provider deliberately ignores cancellation until this bounded gate is released.
                // Revalidation must occur after the awaited receipt returns.
                await lookup.release()
                do {
                    _ = try await task.value
                    XCTFail("Completed lookup accepted invalidated evidence: \(scenario)")
                } catch {
                    switch scenario {
                    case .cancelled: XCTAssertTrue(error is CancellationError, "Unexpected cancellation error: \(error)")
                    case .replacedLease: XCTAssertEqual(error as? AutonomyError, .staleLease)
                    case .differentResponseID, .differentUsage: XCTAssertEqual(error as? AutonomyError, .intentConflict)
                    }
                }
                let retained = try await fixture.repository.providerTurn(reserved.intent.turnID)
                XCTAssertEqual(retained, completed, "Rejected lookup must preserve completed provider identity and usage")
                let budgetAfter = try await fixture.repository.contextBudgetState(identity: identity)
                let observationsAfter = try await fixture.repository.contextBudgetObservations(identity: identity)
                let runAfter = try await fixture.repository.autonomousRun(current.runID)
                XCTAssertEqual(budgetAfter, budgetAtLookup, "Rejected lookup must not account its returned usage")
                XCTAssertEqual(observationsAfter, observationsAtLookup)
                XCTAssertEqual(runAfter, runAtLookup, "Rejected lookup must not update resumed work")
                let after = await fixture.transport.snapshot()
                XCTAssertEqual(after.probes, before.probes)
                XCTAssertEqual(after.roots.count, before.roots.count)
                XCTAssertEqual(after.followups.count, before.followups.count)
                let lookupCount = await lookup.lookupCount()
                XCTAssertEqual(lookupCount, 1, "Rejected first receipt must not advance to a later recorded response")
                if let replacement {
                    let currentLease = try await fixture.repository.runLease(current.runID)
                    XCTAssertEqual(currentLease, replacement)
                    _ = try await fixture.repository.releaseRunLease(replacement)
                }
            } catch {
                task.cancel()
                await lookup.release()
                _ = await task.result
                if let replacement { _ = try? await fixture.repository.releaseRunLease(replacement) }
                throw error
            }
        }
    }

    func testUnknownAutomaticPostRemainsLookupOnlyAndAcceptsOnlyRecordedExactResponse() async throws {
        try await withFixture { fixture in
            let reserved = try sourceDerivedUnwrap(try await fixture.repository.pendingAutomaticContinuation(runID: fixture.run.runID))
            await fixture.transport.setMode(.unknownOrdinary)
            let first = try fixture.stepper()
            let (intent, pending, context) = try await fixture.prepare(first)
            do { _ = try await first.execute(intent, run: pending, context: context, lease: fixture.lease); XCTFail("Unknown POST completed") }
            catch { XCTAssertEqual(error as? LMStudioProviderError, .deadlineExceeded(phase: "total")) }
            let unknown = await fixture.transport.snapshot()
            XCTAssertEqual(unknown.followups.count, 2)
            let unresolved = try await fixture.repository.providerTurn(reserved.intent.turnID)
            XCTAssertEqual(unresolved?.state, .ambiguous)
            let replay = try fixture.stepper()
            do { _ = try await replay.execute(intent, run: pending, context: context, lease: fixture.lease); XCTFail("Absent receipt was resubmitted") }
            catch { XCTAssertEqual(error as? NativeSourceConversationError, .outcomeUnknown) }
            let missed = await fixture.transport.snapshot()
            XCTAssertEqual(missed.probes, unknown.probes)
            XCTAssertEqual(missed.followups.count, unknown.followups.count)
            await fixture.transport.allowUnknownReceipt()
            let resumed = try fixture.stepper()
            let outcome = try await resumed.execute(intent, run: pending, context: context, lease: fixture.lease)
            guard case .waitingResource = outcome else { return XCTFail("An answer without a tool effect cannot prove resumption") }
            let retained = try await fixture.repository.providerTurn(reserved.intent.turnID)
            XCTAssertEqual(retained?.intent, reserved.intent)
            XCTAssertEqual(retained?.state, .completed)
            XCTAssertEqual(retained?.providerResponseID, "successor-retained-answer")
            let settled = await fixture.transport.snapshot()
            XCTAssertEqual(settled.probes, unknown.probes)
            XCTAssertEqual(settled.followups.count, unknown.followups.count)
            XCTAssertFalse(try sourceDerivedUnwrap(fixture.operation()).isResumed)
        }
    }

    func testPendingFeedbackNoticePreservesExactSourcePrefixAndCompletedReplay() async throws {
        try await withFixture { fixture in
            let notices = try StjornarvaldPolicyNoticeRepository(paths: fixture.app.paths)
            try await queueFeedbackNotice(fixture, notices: notices)
            let policy = StjornarvaldCodingAgentPolicyReporter(repository: notices)
            await fixture.transport.expectPolicyNoticeOnFeedback()
            let sessionID = try sourceDerivedUnwrap(fixture.run.activeSessionID)
            let identity = ContextBudgetIdentity(runID: fixture.run.runID, projectID: fixture.run.projectID,
                projectGeneration: fixture.run.projectGeneration, sessionID: sessionID)
            await fixture.transport.observeFeedbackDispatch { request in
                let state = try sourceDerivedUnwrap(try await fixture.repository.contextBudgetState(identity: identity))
                let latest = try sourceDerivedUnwrap(state.latestObservation)
                let prefix = try sourceDerivedUnwrap(latest.accounting?.toolResultAccounting?.prefixes.last)
                let actual = try await SourceBootstrapFixtureWire.continuation(request, maximumOutputTokens: 1_024)
                let exactBytes = try sourceDerivedUnwrap(actual.serializedInputByteCount)
                XCTAssertGreaterThan(exactBytes, prefix.inputBytes)
                let outputOnly = LMStudioContinuationRequest(operationID: request.operationID, modelKey: request.modelKey,
                    previousResponseID: request.previousResponseID, input: [request.input[0]], tools: request.tools,
                    idempotencyKey: request.idempotencyKey)
                let original = try await SourceBootstrapFixtureWire.continuation(outputOnly, maximumOutputTokens: 1_024)
                XCTAssertEqual(original.serializedInputByteCount, prefix.inputBytes,
                    "The escaped production encoder's existing output prefix is retained exactly")
                let history = try await fixture.repository.contextBudgetObservations(identity: identity)
                let before = try sourceDerivedUnwrap(history.first { $0.triggerPoint == .afterToolResult
                    && $0.providerResponseID == request.previousResponseID })
                let delta = try ContextBudgetMath.estimateTokens(serializedBytes: exactBytes - prefix.inputBytes,
                    policy: state.configuration.policy)
                XCTAssertEqual(latest.used, before.used + delta, "Charge exact additive wire input bytes once")
            }
            let first = try fixture.stepper(policyContext: policy)
            let (intent, pending, context) = try await fixture.prepare(first)
            let result = try await first.execute(intent, run: pending, context: context, lease: fixture.lease)
            guard case .continued(let work) = result else { return XCTFail("Expected source feedback consumption: \(result)") }
            XCTAssertEqual(work.metadata["provider_response_id"], "successor-consumed")
            XCTAssertEqual(try notices.deliveryState("managed:\(intent.idempotencyKey):1"), .presented)
            let completed = await fixture.transport.snapshot()
            XCTAssertEqual(completed.followups.last?.input.count, 2)
            let beforeBudget = try await fixture.repository.contextBudgetState(identity: identity)
            let beforeHistory = try await fixture.repository.contextBudgetObservations(identity: identity)
            let current = try sourceDerivedUnwrap(try await fixture.repository.autonomousRun(pending.runID))
            let replay = try fixture.stepper(policyContext: policy)
            let outcome = try await replay.execute(intent, run: current, context: context, lease: fixture.lease)
            guard case .continued(let replayedWork) = outcome else { return XCTFail("Expected exact retained notice replay") }
            XCTAssertEqual(replayedWork.metadata["provider_response_id"], "successor-consumed")
            let after = await fixture.transport.snapshot()
            XCTAssertEqual(after.probes, completed.probes)
            XCTAssertEqual(after.roots, completed.roots)
            XCTAssertEqual(after.followups, completed.followups, "Replay must not POST or rewrite accepted child input")
            let afterBudget = try await fixture.repository.contextBudgetState(identity: identity)
            let afterHistory = try await fixture.repository.contextBudgetObservations(identity: identity)
            XCTAssertEqual(afterBudget, beforeBudget)
            XCTAssertEqual(afterHistory, beforeHistory)
        }
    }

    func testOutputOnlyCompletedChildDefersNewNoticeWithoutRewritingReplay() async throws {
        try await withFixture { fixture in
            let first = try fixture.stepper()
            let (intent, pending, context) = try await fixture.prepare(first)
            _ = try await first.execute(intent, run: pending, context: context, lease: fixture.lease)
            let completed = await fixture.transport.snapshot()
            XCTAssertEqual(completed.followups.last?.input.count, 1)
            let notices = try StjornarvaldPolicyNoticeRepository(paths: fixture.app.paths)
            try await queueFeedbackNotice(fixture, notices: notices)
            let policy = StjornarvaldCodingAgentPolicyReporter(repository: notices)
            let current = try sourceDerivedUnwrap(try await fixture.repository.autonomousRun(pending.runID))
            let replay = try fixture.stepper(policyContext: policy)
            let outcome = try await replay.execute(intent, run: current, context: context, lease: fixture.lease)
            guard case .continued = outcome else { return XCTFail("Expected original output-only child replay") }
            let after = await fixture.transport.snapshot()
            XCTAssertEqual(after.probes, completed.probes)
            XCTAssertEqual(after.roots, completed.roots)
            XCTAssertEqual(after.followups, completed.followups)
            XCTAssertEqual(try notices.deliveryState("managed:\(intent.idempotencyKey):1"), .deliveryDeferred)
            let remaining = await policy.pendingNotices(projectID: fixture.run.projectID.description,
                projectGeneration: 1, runID: fixture.run.runID.description, sessionID: fixture.run.activeSessionID,
                clientID: nil, maximumCount: 8, maximumBytes: 16 * 1_024)
            XCTAssertEqual(remaining.count, 1, "A newly queued notice cannot change an already frozen child hash")
        }
    }

    func testOptionalFeedbackNoticeDefersAtActualProviderBodyCap() async throws {
        try await withFixture { fixture in
            let notices = try StjornarvaldPolicyNoticeRepository(paths: fixture.app.paths)
            try await queueFeedbackNotice(fixture, notices: notices)
            let policy = StjornarvaldCodingAgentPolicyReporter(repository: notices)
            await fixture.transport.limitFeedbackBodyToOutputOnly()
            let stepper = try fixture.stepper(policyContext: policy)
            let (intent, pending, context) = try await fixture.prepare(stepper)
            let outcome = try await stepper.execute(intent, run: pending, context: context, lease: fixture.lease)
            guard case .continued(let work) = outcome else { return XCTFail("Optional notice blocked valid source tool output") }
            XCTAssertEqual(work.metadata["provider_response_id"], "successor-consumed")
            let snapshot = await fixture.transport.snapshot()
            XCTAssertTrue(snapshot.consumedExactOutput)
            XCTAssertEqual(snapshot.followups.last?.input.count, 1)
            let controls = await fixture.transport.policyControls()
            XCTAssertEqual(controls.rejectedNoticePreflights, 1, "Production serializer must reject the notice-bearing body before POST")
            XCTAssertNotNil(controls.feedbackMaximumRequestBytes)
            XCTAssertEqual(try notices.deliveryState("managed:\(intent.idempotencyKey):1"), .deliveryDeferred)
            let remaining = await policy.pendingNotices(projectID: fixture.run.projectID.description,
                projectGeneration: 1, runID: fixture.run.runID.description, sessionID: fixture.run.activeSessionID,
                clientID: nil, maximumCount: 8, maximumBytes: 16 * 1_024)
            XCTAssertEqual(remaining.count, 1)
        }
    }

    func testSourceFeedbackPrefixReceiptSurvivesReopenAndRejectsChangedFullInput() async throws {
        try await withFixture { fixture in
            let notices = try StjornarvaldPolicyNoticeRepository(paths: fixture.app.paths)
            try await queueFeedbackNotice(fixture, notices: notices)
            await fixture.transport.expectPolicyNoticeOnFeedback()
            let stepper = try fixture.stepper(policyContext: StjornarvaldCodingAgentPolicyReporter(repository: notices))
            let (intent, pending, context) = try await fixture.prepare(stepper)
            let outcome = try await stepper.execute(intent, run: pending, context: context, lease: fixture.lease)
            guard case .continued = outcome else { return XCTFail("Notice output was not consumed: \(outcome)") }
            let row = try fixture.feedbackPreflightRow()
            let receipt = try sourceDerivedUnwrap(try await fixture.repository.sourceDerivedProviderTurnPreflight(
                turnID: row.turnID, lease: fixture.lease))
            let snapshot = await fixture.transport.snapshot()
            guard let input = snapshot.followups.last?.input.first,
                  case .functionCallOutput(let callID, let output) = input else { return XCTFail("Missing actual output prefix") }
            let prefix = try ForgeJSONCanonicalizationV1.data(from: [["type": "function_call_output", "call_id": callID, "output": output]])
            XCTAssertEqual(receipt.toolOutputsPrefixSHA256, JSONSupport.sha256Hex(prefix))
            XCTAssertNotEqual(receipt.intent.inputSHA256, receipt.toolOutputsPrefixSHA256,
                "Actual notice child preserves its full input identity separately from the exact output prefix")
            let reopened = try ProjectControlPlaneRepository(databaseURL: fixture.app.paths.controlPlaneSQLite)
            do {
                let restored = try await reopened.sourceDerivedProviderTurnPreflight(turnID: row.turnID, lease: fixture.lease)
                XCTAssertEqual(restored, receipt, "FULL-durable prefix and all actual input/wire/scope identities survive owner reopen")
                await reopened.close()
            } catch { await reopened.close(); throw error }
            do {
                _ = try await fixture.repository.beginSourceDerivedProviderTurn(intent: receipt.intent,
                    preflight: receipt.preflight, capabilities: receipt.capabilities, lease: fixture.lease,
                    actualInput: Data("[]".utf8))
                XCTFail("A different full input acquired retained prefix authority")
            } catch { XCTAssertEqual(error as? NativeSourceConversationError, .integrityFailure) }
            let request = try sourceDerivedUnwrap(snapshot.followups.last)
            guard request.input.count == 2, case .message(let role, let text) = request.input[1] else {
                return XCTFail("Missing actual notice suffix")
            }
            let exactInput = try ForgeJSONCanonicalizationV1.data(from: [
                ["type": "function_call_output", "call_id": callID, "output": output],
                ["type": "message", "role": role, "content": text],
            ])
            XCTAssertEqual(JSONSupport.sha256Hex(exactInput), receipt.intent.inputSHA256)
            for scope in 0..<4 {
                let wrong = ProviderTurnIntent(turnID: receipt.intent.turnID, runID: receipt.intent.runID,
                    sessionID: scope == 0 ? UUID().uuidString.lowercased() : receipt.intent.sessionID,
                    operationID: scope == 1 ? UUID() : receipt.intent.operationID,
                    projectID: scope == 2 ? ProjectID() : receipt.intent.projectID,
                    projectGeneration: scope == 3 ? ProjectGeneration(receipt.intent.projectGeneration.rawValue == 1 ? 2 : 1) : receipt.intent.projectGeneration, kind: receipt.intent.kind,
                    idempotencyKey: receipt.intent.idempotencyKey, previousResponseID: receipt.intent.previousResponseID,
                    inputSHA256: receipt.intent.inputSHA256, toolSchemaSHA256: receipt.intent.toolSchemaSHA256)
                do {
                    _ = try await fixture.repository.beginSourceDerivedProviderTurn(intent: wrong,
                        preflight: receipt.preflight, capabilities: receipt.capabilities, lease: fixture.lease, actualInput: exactInput)
                    XCTFail("Correct prefix bytes may not authorize another session, operation, project, or generation")
                } catch { XCTAssertEqual(error as? AutonomyError, .intentConflict) }
            }
            let retained = try await fixture.repository.sourceDerivedProviderTurnPreflight(turnID: row.turnID, lease: fixture.lease)
            XCTAssertEqual(retained, receipt)
            let after = await fixture.transport.snapshot()
            XCTAssertEqual(after.probes, snapshot.probes)
            XCTAssertEqual(after.roots, snapshot.roots)
            XCTAssertEqual(after.followups, snapshot.followups, "Rejected replay may neither POST nor rewrite actual input")
        }
    }

    func testSourceFeedbackPrefixTamperAndLegacyOmissionCannotAuthorizeNoticeChild() async throws {
        try await withFixture { fixture in
            let notices = try StjornarvaldPolicyNoticeRepository(paths: fixture.app.paths)
            try await queueFeedbackNotice(fixture, notices: notices)
            await fixture.transport.expectPolicyNoticeOnFeedback()
            let stepper = try fixture.stepper(policyContext: StjornarvaldCodingAgentPolicyReporter(repository: notices))
            let (intent, pending, context) = try await fixture.prepare(stepper)
            let outcome = try await stepper.execute(intent, run: pending, context: context, lease: fixture.lease)
            guard case .continued = outcome else { return XCTFail("Notice output was not consumed: \(outcome)") }
            let row = try fixture.feedbackPreflightRow()
            let activation = try sourceDerivedUnwrap(try await fixture.repository.sourceActivationReceipt(
                runID: fixture.run.runID, operationID: fixture.acceptance.operationID, lease: fixture.lease))
            let original = try JSONSupport.object(from: Data(row.json.utf8))
            let originalPrefix = try sourceDerivedUnwrap(original["toolOutputsPrefixSHA256"] as? String)
            XCTAssertEqual(originalPrefix.utf8.count, 64)
            let before = await fixture.transport.snapshot()
            for corruption in 0..<6 {
                var object = original
                switch corruption {
                case 0: object["toolOutputsPrefixSHA256"] = (originalPrefix.hasPrefix("0") ? "1" : "0") + originalPrefix.dropFirst()
                case 1: object.removeValue(forKey: "toolOutputsPrefixSHA256")
                case 2: object["toolOutputsPrefixSHA256"] = NSNull()
                case 3: object["toolOutputsPrefixSHA256"] = "invalid-prefix"
                case 4: object["leaseEpoch"] = 0
                default:
                    var changedIntent = try sourceDerivedUnwrap(object["intent"] as? [String: Any])
                    let originalInput = try sourceDerivedUnwrap(changedIntent["inputSHA256"] as? String)
                    changedIntent["inputSHA256"] = (originalInput.hasPrefix("0") ? "1" : "0") + originalInput.dropFirst()
                    object["intent"] = changedIntent
                }
                if corruption >= 4 {
                    XCTAssertEqual(object["toolOutputsPrefixSHA256"] as? String, originalPrefix,
                        "Whole-receipt validation rejects drift even when the prefix SQL predicate still matches")
                }
                let changed = try ForgeJSONCanonicalizationV1.data(from: object)
                let changedRow = SourceDerivedFixture.FeedbackPreflightRow(turnID: row.turnID,
                    json: String(decoding: changed, as: UTF8.self), sha: JSONSupport.sha256Hex(changed))
                try fixture.replaceFeedbackPreflight(from: row, to: changedRow)
                do {
                    do {
                        _ = try await fixture.repository.sourceActivationReceipt(runID: fixture.run.runID,
                            operationID: fixture.acceptance.operationID, lease: fixture.lease)
                        XCTFail("Unproven or malformed additive input cannot sustain source resumption")
                    } catch { XCTAssertTrue(error is ContinuitySourceActivationError || error is NativeSourceConversationError) }
                    try fixture.replaceFeedbackPreflight(from: changedRow, to: row)
                } catch { try? fixture.replaceFeedbackPreflight(from: changedRow, to: row); throw error }
                let restored = try await fixture.repository.sourceActivationReceipt(runID: fixture.run.runID,
                    operationID: fixture.acceptance.operationID, lease: fixture.lease)
                XCTAssertEqual(restored, activation, "Restoration revalidates the exact original receipt rather than replacing proof")
            }
            let after = await fixture.transport.snapshot()
            XCTAssertEqual(after.probes, before.probes)
            XCTAssertEqual(after.roots, before.roots)
            XCTAssertEqual(after.followups, before.followups)
        }
    }

    func testOutputOnlySourceFeedbackKeepsLegacyPreflightEncoding() async throws {
        try await withFixture { fixture in
            let stepper = try fixture.stepper()
            let (intent, pending, context) = try await fixture.prepare(stepper)
            let outcome = try await stepper.execute(intent, run: pending, context: context, lease: fixture.lease)
            guard case .continued = outcome else { return XCTFail("Legacy output-only continuation did not resume: \(outcome)") }
            let row = try fixture.feedbackPreflightRow()
            let object = try JSONSupport.object(from: Data(row.json.utf8))
            XCTAssertNil(object["toolOutputsPrefixSHA256"], "Nil attestation remains omitted from legacy JSON")
            let decoded = try JSONDecoder().decode(SourceDerivedProviderTurnStoredPreflight.self, from: Data(row.json.utf8))
            XCTAssertNil(decoded.toolOutputsPrefixSHA256)
            let receipt = try decoded.validatedReceipt(sha256: row.sha)
            XCTAssertNil(receipt.toolOutputsPrefixSHA256)
            let actual = try await fixture.repository.sourceDerivedProviderTurnPreflight(turnID: row.turnID, lease: fixture.lease)
            XCTAssertEqual(actual, receipt)
            XCTAssertTrue(try sourceDerivedUnwrap(fixture.operation()).isResumed)
        }
    }

    private func queueFeedbackNotice(_ fixture: SourceDerivedFixture, notices: StjornarvaldPolicyNoticeRepository) async throws {
        let rule = try sourceDerivedUnwrap(RavenForgeDevelopmentPolicyAdapter().rules().first)
        let log = try StjornarvaldPolicyLogStore(databaseURL: fixture.app.paths.stjornarvaldPolicyLogSQLite,
            jsonlURL: fixture.app.paths.stjornarvaldPolicyLogJSONL)
        let candidate = PolicyViolationCandidate(rule: rule, observationID: UUID(),
            scope: .init(projectID: fixture.run.projectID.description, projectGeneration: 1,
                runID: fixture.run.runID.description, sessionID: fixture.run.activeSessionID),
            subjectIdentity: "owned-feedback-runtime", summary: "A shipping runtime is outside the native stack.",
            evidenceReferences: ["fixture-target-membership"], explanation: "A scoped feedback notice must be delivered.",
            confidence: 0.95, suggestedCorrection: "Remove the non-native shipping runtime.", conditionIdentity: "runtime")
        let finding = PolicyDetectorFinding(detectorID: "feedback-notice-fixture", disposition: .violation, candidate: candidate)
        let result = try StjornarvaldViolationLifecycleService(store: log).apply(finding, occurredAt: Date())
        guard case .recorded(_, let event) = result, try notices.queue(event) != nil else {
            throw AutonomyError.invalidRequest("Owned source notice fixture did not queue its event")
        }
    }

    private func withFixture(_ body: (SourceDerivedFixture) async throws -> Void) async throws {
        let fixture = try await SourceDerivedFixture.make()
        do { try await body(fixture); await fixture.close() }
        catch { await fixture.close(); throw error }
    }
}

private final class SourceDerivedFixture: @unchecked Sendable {
    let app: ForgeApp
    var repository: ProjectControlPlaneRepository { app.projectContexts.repository }
    let taskID: UUID
    let marker: String
    let acceptance: ContinuityIngressAcceptanceReceipt
    let lease: RunLease
    let run: AutonomousRunRecord
    let bootstrapAcknowledgement: ProviderTurn
    let worker: ManagedContinuityWorker
    let broker: ToolInvocationBroker
    let transport: SourceDerivedTransport
    let sourceService: NativeSourceConversationService
    let bridge: MCPTaskHTTPService

    private init(app: ForgeApp, taskID: UUID, marker: String, acceptance: ContinuityIngressAcceptanceReceipt,
        lease: RunLease, run: AutonomousRunRecord, bootstrapAcknowledgement: ProviderTurn,
        worker: ManagedContinuityWorker, broker: ToolInvocationBroker,
        transport: SourceDerivedTransport, sourceService: NativeSourceConversationService, bridge: MCPTaskHTTPService) {
        self.app = app; self.taskID = taskID; self.marker = marker; self.acceptance = acceptance
        self.lease = lease; self.run = run; self.bootstrapAcknowledgement = bootstrapAcknowledgement
        self.worker = worker; self.broker = broker
        self.transport = transport; self.sourceService = sourceService; self.bridge = bridge
    }

    static func make() async throws -> SourceDerivedFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("source-derived-successor-\(UUID().uuidString)")
            .resolvingSymlinksInPath().standardizedFileURL
        let app = try ForgeApp.bootstrap(home: directory.appendingPathComponent("home"))
        var service: NativeSourceConversationService?
        var bridge: MCPTaskHTTPService?
        do {
            let project = directory.appendingPathComponent("project")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let marker = "Exact successor bytes: \"quoted\" \\ path\nretained line"
            let file = project.appendingPathComponent("source.txt")
            try Data(marker.utf8).write(to: file)
            try app.config.update(["allowed_roots": [project.path]], save: true)
            let initialized = try app.projectMemory.initializeUnchecked(path: project.path)
            let projectID = ProjectID(try sourceDerivedUnwrap((initialized["project_id"] as? String).flatMap(UUID.init(uuidString:))))
            let taskID = UUID(), repository = app.projectContexts.repository
            _ = try await repository.registerProjectUnchecked(projectID: projectID, displayName: "Native source successor", canonicalRoot: project)
            let approval = try NativeContinuityTaskApproval(assignmentID: "native-source-successor",
                assignmentBytes: Data("Immutable successor source assignment".utf8), mission: "Read the approved source file",
                providerID: "lmstudio", adapterID: "forge.native-session-host", modelKey: "fixture/native",
                allowedTools: ["fs_read"], completionGates: ["G04"], resourceProfile: .automatic,
                filesystemAccess: "read_only", networkAllowed: false, maximumInlineOutputBytes: 8_192,
                sourceLimits: .init(maximumCalls: 64, maximumResultBytes: 8_192, maximumRequestSeconds: 60))
            let assignment = try ContinuityTaskAssignment(assignmentID: approval.assignmentID, assignmentBytes: approval.assignmentBytes,
                mission: approval.mission, providerID: approval.providerID, adapterID: approval.adapterID, modelKey: approval.modelKey,
                specification: .init(allowedTools: approval.allowedTools, completionGates: approval.completionGates),
                authorizationScope: .init(canonicalRoots: [project], writableRoots: [], allowedTools: ["fs_read"],
                    networkAllowed: false, maximumInlineOutputBytes: 8_192))
            let credential = try NativeTaskCapabilityCredential(capabilityID: UUID(), epoch: 1, secret: Data(repeating: 53, count: 32))
            let preparation = try NativeContinuityTaskPreparationRequest(requestID: UUID(), taskID: taskID,
                capabilityID: credential.capabilityID, projectID: projectID, projectGeneration: .initial,
                approval: approval, verifierSHA256: credential.verifier.sha256,
                expiresAt: ISO8601.string(from: Date().addingTimeInterval(3_600)))
            _ = try await repository.prepareNativeContinuityTask(request: preparation, approvedAssignment: assignment)
            let prior = try app.config.budgetPolicySelection(scope: .globalDefault)
            _ = try app.config.updateBudgetPolicy(.init(scope: .globalDefault, expectedRevision: prior.revision,
                expectedGlobalRevision: prior.globalRevision, operation: .set, policy: BudgetPolicy(automaticHandoffEnabled: true)))
            let managerID = UUID()
            let admittedBridge = MCPTaskHTTPService { credential, token in
                let attachment = try await repository.authenticateNativeTaskCapability(credential: credential, cancellation: token)
                return try MCPNativeTaskSourceDispatcher(app: app, attachment: attachment, managerInstanceID: managerID)
            }
            bridge = admittedBridge
            admittedBridge.listenerStarted(epoch: UUID()); admittedBridge.setOperational(true)
            let sourceTransport = SourceDerivedTransport(file: file, marker: marker, sourceOnly: true)
            let sourceProvider = try LMStudioManagedModelProvider(
                storageDirectory: app.paths.home.appendingPathComponent("native-source-provider"), transport: sourceTransport)
            let pool = try NativeProviderWorkAdmission(limit: 1)
            let sourceSessionID = UUID()
            let owner = NativeSourceConversationService(repository: repository, providerWorkAdmission: pool,
                managerInstanceID: managerID, clock: SystemClock(), attachmentResolver: { requested in
                    guard requested == taskID else { throw NativeSourceConversationError.notFound }
                    return .init(endpoint: URL(string: "http://127.0.0.1:8765/mcp/continuity")!,
                        credential: credential, sourceSessionID: sourceSessionID)
                }, providerResolver: { _ in sourceProvider }, configurationResolver: {
                    .init(revision: "0", endpoint: "http://127.0.0.1:1234", modelKey: "fixture/native",
                        credentialConfigured: false, saved: true)
                }, policyResolver: { projectID, generation in
                    try app.config.budgetPolicySelection(scope: .init(kind: .projectOverride,
                        projectID: projectID.description, projectGeneration: Int(generation.rawValue)))
                }, tools: { credential, lease, token in
                    try await admittedBridge.nativeProviderTools(credential: credential, lease: lease, cancellation: token)
                }, call: { credential, reference, lease, budget, checkpoint, token in
                    try await admittedBridge.submitNativeCall(credential: credential, reference: reference,
                        lease: lease, outputBudget: budget, preparedCheckpoint: checkpoint, cancellation: token)
                }, pressureIO: NativeSourcePressureIO(source: app.continuity), beginProviderOperation: { .init {} })
            service = owner
            owner.setOperational(true)
            let send = try NativeSourceSendRequest(taskID: taskID, requestID: UUID(), input: "Read and hand off the approved task")
            _ = try await owner.send(send, cancellation: .init(timeoutSeconds: 5))
            for _ in 0..<500 {
                if !(await owner.hasRetainedWork()) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            guard !(await owner.hasRetainedWork()) else { throw NativeSourceConversationError.deadlineExceeded }
            let status = try await owner.status(.init(taskID: taskID, requestID: send.requestID), cancellation: .init())
            XCTAssertEqual(status.conversationState, "source_fenced", String(decoding: status.canonicalJSON, as: UTF8.self))
            XCTAssertEqual(pool.activeCount, 0)
            let sourceCounts = await sourceTransport.snapshot()
            XCTAssertEqual(sourceCounts.roots.count, 1)
            XCTAssertEqual(sourceCounts.followups.count, 0)
            let ids = try app.store.pendingContinuityHandoffIDs(limit: 2)
            XCTAssertEqual(ids.count, 1)
            let delivery = try sourceDerivedUnwrap(app.store.continuityDelivery(operationID: sourceDerivedUnwrap(ids.first)))
            let policy = try app.config.budgetPolicySelection(scope: .init(kind: .projectOverride,
                projectID: projectID.description, projectGeneration: 1))
            let acceptance = try await repository.acceptContinuityIngress(source: delivery.handoff,
                operationID: delivery.operationID, policySelection: policy)
            let carryover = try sourceDerivedUnwrap(try await repository.nativeSourceBudgetCarryover(runID: acceptance.runID))
            XCTAssertEqual(carryover.taskID, taskID)
            let conversation = try await repository.nativeSourceConversation(taskID: taskID, credential: credential)
            XCTAssertEqual(carryover.conversationID, conversation?.conversationID)
            let lease = try await repository.acquireRunLease(runID: acceptance.runID, ownerID: "native-source-successor-owner")
            let transport = SourceDerivedTransport(file: file, marker: marker)
            let adapter = try LMStudioManagedSessionHostAdapterV2(storageDirectory: app.paths.home.appendingPathComponent("bootstrap-provider"), transport: transport)
            let worker = ManagedContinuityWorker(repository: repository, memory: app.projectMemory, adapterResolver: { _ in adapter })
            let broker = try ToolInvocationBroker(repository: repository, executor: app.tools,
                classifier: ProductionToolReplayCatalog.classifier(productionToolNames: app.tools.toolNames),
                sourcePolicyResolver: { context in
                    guard let generation = Int(exactly: context.projectGeneration.rawValue) else {
                        throw ProjectContextError.invalidGeneration(context.projectGeneration.rawValue)
                    }
                    return try app.config.budgetPolicySelection(scope: .init(kind: .projectOverride,
                        projectID: context.projectID.description, projectGeneration: generation))
                })
            let bootstrap = try await worker.executeSourceBootstrap(acceptance: acceptance, lease: lease, broker: broker,
                continuity: app.continuity, policyResolver: { try app.config.budgetPolicySelection(scope: $0) })
            let run = try await worker.activateSourceBootstrap(acceptance: acceptance, lease: lease,
                policyResolver: { try app.config.budgetPolicySelection(scope: $0) })
            return .init(app: app, taskID: taskID, marker: marker, acceptance: acceptance, lease: lease,
                run: run, bootstrapAcknowledgement: bootstrap.acknowledgementTurn, worker: worker,
                broker: broker, transport: transport, sourceService: owner, bridge: admittedBridge)
        } catch {
            if let service { _ = await service.shutdown(deadline: Date().addingTimeInterval(5)) }
            if let bridge { _ = await bridge.shutdown() }
            _ = app.shutdown(); try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func provider() throws -> LMStudioManagedModelProvider {
        try LMStudioManagedModelProvider(storageDirectory: app.paths.home.appendingPathComponent("ordinary-provider"), transport: transport)
    }

    func stepper(provider suppliedProvider: (any ManagedModelProvider)? = nil,
        policyContext: any PolicyContextProviding = NoPolicyContextProvider()) throws -> ManagedProjectRunStepExecutor {
        let provider: any ManagedModelProvider = try suppliedProvider ?? self.provider()
        let catalog = try ToolDefinitionCatalog.production(toolNames: app.tools.toolNames)
        let budget = PersistedManagedRunBudgetEvaluator(repository: repository,
            policyResolver: { [app] in try app.config.budgetPolicySelection(scope: $0) },
            toolCallThresholdResolver: { [app] in
                try app.config.refreshIfChanged()
                return app.config.model.sessions.continuityRolloverToolCalls
            })
        return try ManagedProjectRunStepExecutor(repository: repository, providerResolver: { _ in provider },
            toolDefinitionResolver: { try catalog.providerToolDefinitions(allowedToolNames: $0) }, broker: broker,
            budget: budget, policyContext: policyContext, sourceResumption: { [worker, app] run, lease in
                try await worker.reconcileSourceResumption(run: run, lease: lease,
                    policyResolver: { try app.config.budgetPolicySelection(scope: $0) })
            })
    }

    func automaticPreflight(_ reserved: ProviderTurnRecord) async throws -> ProviderRequestPreflight {
        let provider = LMStudioManagedModelProvider(transport: transport)
        let catalog = try ToolDefinitionCatalog.production(toolNames: app.tools.toolNames)
        let tools = try catalog.providerToolDefinitions(allowedToolNames: Set(run.specification.allowedTools))
        return try await provider.preflightContinuation(.init(
            operationID: reserved.intent.operationID ?? reserved.intent.turnID,
            idempotencyKey: reserved.intent.idempotencyKey, modelKey: "fixture/native",
            previousResponseID: sourceDerivedUnwrap(reserved.intent.previousResponseID),
            input: ManagedContinuityWorker.automaticContinuationInput(), tools: tools))
    }

    func prepare(_ stepper: ManagedProjectRunStepExecutor) async throws
        -> (RunSideEffectIntent, AutonomousRunRecord, ToolInvocationContext) {
        let intent = try sourceDerivedUnwrap(try await stepper.prepareNextStep(for: run))
        let pending = try await repository.persistRunSideEffectIntent(runID: run.runID, lease: lease,
            expectedRevision: run.revision, intent: intent)
        let context = try await repository.invocationContext(for: .init(kind: .providerSession, id: sourceDerivedUnwrap(pending.activeSessionID)))
        return (intent, pending, context)
    }

    func operation() throws -> ContinuitySourceBootstrapOperation? {
        try ContinuityStateEngine(memory: app.projectMemory).sourceBootstrap(operationID: acceptance.operationID,
            authorization: acceptance.authorization)
    }

    struct FeedbackPreflightRow {
        let turnID: UUID
        let json: String
        let sha: String
    }

    func feedbackPreflightRow() throws -> FeedbackPreflightRow {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(app.paths.controlPlaneSQLite.path, &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw NativeSourceConversationError.integrityFailure
        }
        defer { sqlite3_close_v2(handle) }
        sqlite3_busy_timeout(handle, 3_000)
        let sql = "SELECT turn_id,source_preflight_json,source_preflight_sha256 FROM provider_turns WHERE run_id=? AND provider_response_id='successor-consumed' AND state='completed' LIMIT 2"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw NativeSourceConversationError.integrityFailure
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, run.runID.description, -1, transient) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { throw NativeSourceConversationError.integrityFailure }
        func text(_ index: Int32, maximum: Int) throws -> String {
            guard sqlite3_column_type(statement, index) == SQLITE_TEXT,
                  (1...maximum).contains(Int(sqlite3_column_bytes(statement, index))),
                  let pointer = sqlite3_column_text(statement, index) else { throw NativeSourceConversationError.integrityFailure }
            return String(cString: pointer)
        }
        let id = try sourceDerivedUnwrap(UUID(uuidString: text(0, maximum: 36)))
        let json = try text(1, maximum: SourceDerivedProviderTurnStoredPreflight.maximumBytes)
        let sha = try text(2, maximum: 64)
        guard sqlite3_step(statement) == SQLITE_DONE, JSONSupport.sha256Hex(Data(json.utf8)) == sha else {
            throw NativeSourceConversationError.integrityFailure
        }
        return .init(turnID: id, json: json, sha: sha)
    }

    func replaceFeedbackPreflight(from old: FeedbackPreflightRow, to new: FeedbackPreflightRow) throws {
        guard old.turnID == new.turnID, new.json.utf8.count <= SourceDerivedProviderTurnStoredPreflight.maximumBytes,
              JSONSupport.sha256Hex(Data(new.json.utf8)) == new.sha else { throw NativeSourceConversationError.integrityFailure }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(app.paths.controlPlaneSQLite.path, &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw NativeSourceConversationError.integrityFailure
        }
        defer { sqlite3_close_v2(handle) }
        sqlite3_busy_timeout(handle, 3_000)
        var statement: OpaquePointer?
        let sql = "UPDATE provider_turns SET source_preflight_json=?,source_preflight_sha256=? WHERE turn_id=? AND run_id=? AND state='completed' AND source_preflight_json=? AND source_preflight_sha256=?"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw NativeSourceConversationError.integrityFailure
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let bindings = [new.json, new.sha, old.turnID.uuidString.lowercased(), run.runID.description, old.json, old.sha]
        for (offset, value) in bindings.enumerated() {
            guard sqlite3_bind_text(statement, Int32(offset + 1), value, -1, transient) == SQLITE_OK else {
                throw NativeSourceConversationError.integrityFailure
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(handle) == 1 else {
            throw NativeSourceConversationError.integrityFailure
        }
    }

    func reformatCompletedUsage(_ completed: ProviderTurnRecord) throws -> String {
        XCTAssertEqual(completed.state, .completed)
        let original = try sourceDerivedUnwrap(completed.usageJSON)
        let usage = try JSONDecoder().decode(ProviderUsage.self, from: Data(original.utf8))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let bytes = try encoder.encode(usage)
        let reformatted = "\n" + String(decoding: bytes, as: UTF8.self) + "\n"
        XCTAssertNotEqual(reformatted, original, "The replay fixture must use a different JSON encoding")
        XCTAssertEqual(try JSONDecoder().decode(ProviderUsage.self, from: Data(reformatted.utf8)), usage,
            "Whitespace and key order must leave all provider usage fields unchanged")
        var handle: OpaquePointer?
        guard sqlite3_open_v2(app.paths.controlPlaneSQLite.path, &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw NativeSourceConversationError.integrityFailure
        }
        defer { sqlite3_close_v2(handle) }
        sqlite3_busy_timeout(handle, 3_000)
        let sql = "UPDATE provider_turns SET usage_json=? WHERE turn_id=? AND state='completed' AND usage_json=?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw NativeSourceConversationError.integrityFailure
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in [reformatted, completed.intent.turnID.uuidString.lowercased(), original].enumerated() {
            guard sqlite3_bind_text(statement, Int32(offset + 1), value, -1, transient) == SQLITE_OK else {
                throw NativeSourceConversationError.integrityFailure
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(handle) == 1 else {
            throw NativeSourceConversationError.integrityFailure
        }
        return reformatted
    }

    enum ACKCorruption: Sendable, Equatable {
        case missingPreflight, corruptResult, differentProviderVersion, differentProviderInstance
    }

    func corruptAcknowledgement(_ corruption: ACKCorruption, turnID: UUID) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(app.paths.controlPlaneSQLite.path, &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw NativeSourceConversationError.integrityFailure
        }
        defer { sqlite3_close_v2(handle) }
        sqlite3_busy_timeout(handle, 3_000)
        let sql: String
        let bindings: [String]
        switch corruption {
        case .missingPreflight:
            sql = "UPDATE provider_turns SET source_preflight_json=NULL,source_preflight_sha256=NULL WHERE turn_id=?"
            bindings = [turnID.uuidString.lowercased()]
        case .corruptResult:
            sql = "UPDATE continuity_bootstrap_provider_results SET result_json='{}' WHERE turn_id=?"
            bindings = [turnID.uuidString.lowercased()]
        case .differentProviderVersion, .differentProviderInstance:
            var object = try JSONSupport.object(from: JSONEncoder().encode(bootstrapAcknowledgement))
            let field = corruption == .differentProviderVersion ? "providerVersion" : "providerInstanceID"
            object[field] = "different-retained-provider"
            let encoded = try ForgeJSONCanonicalizationV1.data(from: object)
            let decoded = try JSONDecoder().decode(ProviderTurn.self, from: encoded)
            XCTAssertEqual(decoded.requestID, bootstrapAcknowledgement.requestID)
            XCTAssertEqual(decoded.responseID, bootstrapAcknowledgement.responseID)
            XCTAssertEqual(decoded.previousResponseID, bootstrapAcknowledgement.previousResponseID)
            XCTAssertEqual(decoded.toolCalls, bootstrapAcknowledgement.toolCalls)
            XCTAssertEqual(decoded.usage, bootstrapAcknowledgement.usage)
            sql = "UPDATE continuity_bootstrap_provider_results SET result_json=?,result_sha256=? WHERE turn_id=?"
            bindings = [String(decoding: encoded, as: UTF8.self), JSONSupport.sha256Hex(encoded), turnID.uuidString.lowercased()]
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw NativeSourceConversationError.integrityFailure
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in bindings.enumerated() {
            guard sqlite3_bind_text(statement, Int32(offset + 1), value, -1, transient) == SQLITE_OK else {
                throw NativeSourceConversationError.integrityFailure
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(handle) == 1 else {
            throw NativeSourceConversationError.integrityFailure
        }
    }

    func close() async {
        _ = await sourceService.shutdown(deadline: Date().addingTimeInterval(5))
        _ = await bridge.shutdown()
        _ = try? await repository.releaseRunLease(lease)
        _ = app.shutdown()
        try? FileManager.default.removeItem(at: app.paths.home.deletingLastPathComponent())
    }
}

private enum SourceDerivedLookupScenario: Sendable, Equatable {
    case differentResponseID, differentUsage, cancelled, replacedLease
}

/// Only receipt lookup is intercepted. All request serialization, dispatch, and durable
/// provider receipt loading use the same native implementation as the positive fixture.
private actor SourceDerivedLookupProvider: ManagedModelProviderObservedDispatching {
    nonisolated let providerID = "lmstudio"
    private let base: any ManagedModelProviderObservedDispatching
    private let scenario: SourceDerivedLookupScenario
    private var observed: ProviderTurn?
    private var count = 0
    private var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Error>?
    private var deadlineTask: Task<Void, Never>?

    init(base: any ManagedModelProviderObservedDispatching, scenario: SourceDerivedLookupScenario) {
        self.base = base; self.scenario = scenario
    }
    func probe() async throws -> ProviderCapabilities { try await base.probe() }
    func preflightRoot(_ request: ProviderRootRequest) async throws -> ProviderRequestPreflight {
        try await base.preflightRoot(request)
    }
    func preflightContinuation(_ request: ProviderContinuationRequest) async throws -> ProviderRequestPreflight {
        try await base.preflightContinuation(request)
    }
    func createRoot(_ request: ProviderRootRequest) async throws -> ProviderTurn { try await base.createRoot(request) }
    func continueSession(_ request: ProviderContinuationRequest) async throws -> ProviderTurn { try await base.continueSession(request) }
    func createRoot(_ request: ProviderRootRequest, observedCapabilities: ProviderCapabilities) async throws -> ProviderTurn {
        try await base.createRoot(request, observedCapabilities: observedCapabilities)
    }
    func continueSession(_ request: ProviderContinuationRequest, observedCapabilities: ProviderCapabilities) async throws -> ProviderTurn {
        try await base.continueSession(request, observedCapabilities: observedCapabilities)
    }
    func lookup(idempotencyKey: String) async throws -> ProviderTurn? { try await base.lookup(idempotencyKey: idempotencyKey) }
    func cancel(requestID: String) async { await base.cancel(requestID: requestID) }

    func lookupRecorded(idempotencyKey: String) async throws -> ProviderTurn? {
        guard let actual = try await base.lookupRecorded(idempotencyKey: idempotencyKey) else { return nil }
        count += 1
        guard count == 1 else { throw SourceDerivedLookupError.unexpectedSecondLookup }
        observed = actual
        entered = true
        if !released {
            try await withCheckedThrowingContinuation { (pending: CheckedContinuation<Void, Error>) in
                continuation = pending
                deadlineTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    await self?.expire()
                }
            }
        }
        let usage: ProviderUsage?
        if scenario == .differentUsage {
            let original = try sourceDerivedUnwrap(actual.usage)
            usage = try .init(capacity: original.capacity, inputTokens: original.inputTokens + 1,
                outputTokens: original.outputTokens, totalTokens: original.totalTokens + 1,
                source: original.source, confidence: original.confidence)
        } else { usage = actual.usage }
        return try .init(requestID: actual.requestID,
            responseID: scenario == .differentResponseID ? "different-recorded-response" : actual.responseID,
            previousResponseID: actual.previousResponseID, providerID: actual.providerID,
            providerVersion: actual.providerVersion, modelKey: actual.modelKey,
            providerInstanceID: actual.providerInstanceID, messages: actual.messages, toolCalls: actual.toolCalls,
            structuredOutputJSON: actual.structuredOutputJSON, usage: usage, completed: actual.completed,
            finishReason: actual.finishReason, rawArtifactID: actual.rawArtifactID)
    }
    func waitUntilEntered() async throws {
        for _ in 0..<300 {
            if entered { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SourceDerivedLookupError.deadlineExceeded
    }
    func originalReceipt() -> ProviderTurn? { observed }
    func lookupCount() -> Int { count }
    func release() {
        released = true
        deadlineTask?.cancel(); deadlineTask = nil
        let pending = continuation; continuation = nil
        pending?.resume()
    }
    private func expire() {
        deadlineTask = nil
        let pending = continuation; continuation = nil
        pending?.resume(throwing: SourceDerivedLookupError.deadlineExceeded)
    }
}

private enum SourceDerivedLookupError: Error { case deadlineExceeded, unexpectedSecondLookup }

private actor SourceDerivedTransport: LMStudioManagedTransportObservedDispatching {
    static let initialSourceInputTokens = 20_000
    enum Mode: Sendable { case normal, oversizedOutput, smallBody, unknownOrdinary }
    private let file: URL
    private let marker: String
    private let sourceOnly: Bool
    private var mode = Mode.normal
    private var probes = 0
    private var roots: [LMStudioRootRequest] = []
    private var followups: [LMStudioContinuationRequest] = []
    private var consumedExactOutput = false
    private var unknownReceipt: (String, LMStudioResponseTurn)?
    private var unknownReceiptAvailable = false
    private var ordinaryDispatchObserver: (@Sendable () async throws -> Void)?
    private var budgetChecks = 0
    private var expectFeedbackNotice = false
    private var capFeedbackBody = false
    private var feedbackMaximumRequestBytes: Int?
    private var rejectedNoticePreflights = 0
    private var feedbackDispatchObserver: (@Sendable (LMStudioContinuationRequest) async throws -> Void)?
    init(file: URL, marker: String, sourceOnly: Bool = false) {
        self.file = file; self.marker = marker; self.sourceOnly = sourceOnly
    }
    func setMode(_ mode: Mode) { self.mode = mode }
    func expectPolicyNoticeOnFeedback() { expectFeedbackNotice = true }
    func limitFeedbackBodyToOutputOnly() { capFeedbackBody = true }
    func observeFeedbackDispatch(_ observer: @escaping @Sendable (LMStudioContinuationRequest) async throws -> Void) {
        feedbackDispatchObserver = observer
    }
    func policyControls() -> (rejectedNoticePreflights: Int, feedbackMaximumRequestBytes: Int?) {
        (rejectedNoticePreflights, feedbackMaximumRequestBytes)
    }
    func allowUnknownReceipt() { unknownReceiptAvailable = true }
    func observeFirstOrdinaryDispatch(_ observer: @escaping @Sendable () async throws -> Void) {
        ordinaryDispatchObserver = observer
    }
    func probe() async throws -> LMStudioProviderCapabilities {
        probes += 1
        return .init(modelKey: "fixture/native", loadedInstanceID: "fixture/native@131072",
            contextLength: 131_072, maximumContextLength: 131_072, parallelism: 1, flashAttention: true,
            trainedForToolUse: true, streamingVerified: true, functionToolContractVerified: true,
            usageReportingVerified: true, capabilityFingerprintSHA256: String(repeating: "a", count: 64),
            contractProbeResponseID: "source-derived-probe")
    }
    func preflightRoot(_ request: LMStudioRootRequest) async throws -> ProviderRequestPreflight {
        try await SourceBootstrapFixtureWire.root(request, maximumOutputTokens: 1_024)
    }
    func preflightContinuation(_ request: LMStudioContinuationRequest) async throws -> ProviderRequestPreflight {
        if capFeedbackBody, request.previousResponseID == "successor-work-response",
           let first = request.input.first, case .functionCallOutput(_, let output) = first, output != "0" {
            if feedbackMaximumRequestBytes == nil {
                var outputOnly = request
                outputOnly.input = [request.input[0]]
                let baseline = try await SourceBootstrapFixtureWire.continuation(outputOnly, maximumOutputTokens: 1_024)
                feedbackMaximumRequestBytes = max(1_024, baseline.bodyByteCount + 32)
            }
            do {
                return try await SourceBootstrapFixtureWire.continuation(request,
                    maximumRequestBytes: sourceDerivedUnwrap(feedbackMaximumRequestBytes), maximumOutputTokens: 1_024)
            } catch {
                if request.input.count == 2 { rejectedNoticePreflights += 1 }
                throw error
            }
        }
        return try await SourceBootstrapFixtureWire.continuation(request,
            maximumRequestBytes: mode == .smallBody ? 1_024 : 512 * 1_024,
            maximumOutputTokens: mode == .oversizedOutput ? 4_096 : 1_024)
    }
    func createRoot(_ request: LMStudioRootRequest, observedFingerprint: String) async throws -> LMStudioResponseTurn {
        try observation(observedFingerprint)
        return try await createRoot(request)
    }
    func continueSession(_ request: LMStudioContinuationRequest, observedFingerprint: String) async throws -> LMStudioResponseTurn {
        try observation(observedFingerprint)
        return try await continueSession(request)
    }
    private func observation(_ fingerprint: String) throws {
        guard fingerprint == String(repeating: "a", count: 64) else { throw NativeSourceConversationError.conflict }
    }
    func createRoot(_ request: LMStudioRootRequest) async throws -> LMStudioResponseTurn {
        _ = try await preflightRoot(request)
        roots.append(request)
        if sourceOnly {
            let read = try ForgeJSONCanonicalizationV1.data(from: ["path": file.path])
            let handoff = try ForgeJSONCanonicalizationV1.data(from: ["goal": "Continue the approved assignment",
                "summary": "Actual source read was preserved", "next_actions": ["Read the approved source file"]])
            return .init(responseID: "source-provider-response", previousResponseID: nil, model: "fixture/native",
                status: "completed", assistantText: "", functionCalls: [
                    .init(itemID: "source-read-item", callID: "source-read-call", name: "fs_read",
                        arguments: String(decoding: read, as: UTF8.self)),
                    .init(itemID: "source-handoff-item", callID: "source-handoff-call", name: "session_handoff",
                        arguments: String(decoding: handoff, as: UTF8.self))
                ], usage: .init(inputTokens: Self.initialSourceInputTokens, outputTokens: 80,
                    totalTokens: Self.initialSourceInputTokens + 80))
        }
        let object = try sourceDerivedUnwrap(JSONSerialization.jsonObject(with: Data(request.userInput.utf8)) as? [String: Any])
        return try turn(responseID: "successor-bootstrap-root", parent: nil, callID: "successor-context-call",
            name: "context_get", arguments: ["handoff_id": sourceDerivedUnwrap(object["continuity_id"] as? String)])
    }
    func continueSession(_ request: LMStudioContinuationRequest) async throws -> LMStudioResponseTurn {
        _ = try await preflightContinuation(request)
        if request.previousResponseID == "successor-bootstrap-ack", let observer = ordinaryDispatchObserver {
            try await observer()
            budgetChecks += 1
        }
        if request.previousResponseID == "successor-work-response", let observer = feedbackDispatchObserver {
            try await observer(request)
        }
        followups.append(request)
        switch request.previousResponseID {
        case "successor-bootstrap-root":
            let definition = try sourceDerivedUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(sourceDerivedUnwrap(request.tools.first))) as? [String: Any])
            let parameters = try sourceDerivedUnwrap(definition["parameters"] as? [String: Any])
            let properties = try sourceDerivedUnwrap(parameters["properties"] as? [String: [String: Any]])
            var values: [String: Any] = [:]
            for (key, property) in properties { values[key] = try sourceDerivedUnwrap(property["const"]) }
            return try turn(responseID: "successor-bootstrap-ack", parent: request.previousResponseID,
                callID: "successor-ack-call", name: "forge_continuity_ack", arguments: values)
        case "successor-bootstrap-ack":
            if mode == .unknownOrdinary {
                let response = answer(responseID: "successor-retained-answer", parent: request.previousResponseID)
                unknownReceipt = (request.idempotencyKey, response)
                throw LMStudioProviderError.deadlineExceeded(phase: "total")
            }
            return try turn(responseID: "successor-work-response", parent: request.previousResponseID,
                callID: "successor-read-call", name: "fs_read", arguments: ["path": file.path])
        case "successor-work-response":
            guard request.input.count == (expectFeedbackNotice ? 2 : 1),
                  case .functionCallOutput(let callID, let output) = request.input[0],
                  callID == "successor-read-call", try JSONSupport.object(from: Data(output.utf8))["content"] as? String == marker else {
                throw NativeSourceConversationError.integrityFailure
            }
            if expectFeedbackNotice {
                guard case .message(let role, let text) = request.input[1], role == "user",
                      text.contains("STJORNARVALD POLICY CONTEXT") else { throw NativeSourceConversationError.integrityFailure }
            }
            consumedExactOutput = true
            return answer(responseID: "successor-consumed", parent: request.previousResponseID)
        default: throw NativeSourceConversationError.integrityFailure
        }
    }
    private func turn(responseID: String, parent: String?, callID: String, name: String,
        arguments: [String: Any]) throws -> LMStudioResponseTurn {
        .init(responseID: responseID, previousResponseID: parent, model: "fixture/native", status: "completed",
            assistantText: "", functionCalls: [.init(itemID: "item-" + callID, callID: callID, name: name,
                arguments: String(decoding: try ForgeJSONCanonicalizationV1.data(from: arguments), as: UTF8.self))],
            usage: .init(inputTokens: 1_200, outputTokens: 80, totalTokens: 1_280))
    }
    private func answer(responseID: String, parent: String) -> LMStudioResponseTurn {
        .init(responseID: responseID, previousResponseID: parent, model: "fixture/native", status: "completed",
            assistantText: "The exact approved result was consumed.", functionCalls: [],
            usage: .init(inputTokens: 1_800, outputTokens: 80, totalTokens: 1_880))
    }
    func receipt(forIdempotencyKey key: String) async -> LMStudioResponseTurn? {
        guard unknownReceiptAvailable, let unknownReceipt, unknownReceipt.0 == key else { return nil }
        return unknownReceipt.1
    }
    func cancel(operationID: String) async {}
    func snapshot() -> (probes: Int, roots: [LMStudioRootRequest], followups: [LMStudioContinuationRequest], consumedExactOutput: Bool, budgetChecks: Int) {
        (probes, roots, followups, consumedExactOutput, budgetChecks)
    }
}

private func sourceDerivedUnwrap<Value>(_ value: Value?, file: StaticString = #filePath, line: UInt = #line) throws -> Value {
    try XCTUnwrap(value, file: file, line: line)
}
