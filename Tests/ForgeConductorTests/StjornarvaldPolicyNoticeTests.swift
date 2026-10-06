import Foundation
import XCTest
#if SWIFT_PACKAGE
import ForgeNativeSessionHostPlugin
#endif
@testable import ForgeConductorCore

final class StjornarvaldPolicyNoticeTests: XCTestCase {
    func testNoticeQueueDeduplicatesRepeatsHonorsQuietIntervalAndSupersedesCorrection() throws {
        let fixture = try NoticeFixture()
        defer { fixture.cleanup() }
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let opened = try fixture.record(.violation, observationID: UUID(), occurredAt: start)
        XCTAssertNotNil(try fixture.notices.queue(opened, now: start))

        let earlyRepeat = try fixture.record(
            .violation, observationID: UUID(), occurredAt: start.addingTimeInterval(30)
        )
        XCTAssertNil(try fixture.notices.queue(earlyRepeat, now: start.addingTimeInterval(30)))

        let lateRepeat = try fixture.record(
            .violation,
            observationID: UUID(),
            occurredAt: start.addingTimeInterval(StjornarvaldPolicyNoticeRepository.repeatQuietInterval + 1)
        )
        XCTAssertNotNil(try fixture.notices.queue(
            lateRepeat,
            now: start.addingTimeInterval(StjornarvaldPolicyNoticeRepository.repeatQuietInterval + 1)
        ))
        XCTAssertEqual(try fixture.pending().count, 2)

        let corrected = try fixture.record(
            .correction,
            observationID: UUID(),
            occurredAt: start.addingTimeInterval(StjornarvaldPolicyNoticeRepository.repeatQuietInterval + 2)
        )
        XCTAssertNil(try fixture.notices.queue(
            corrected,
            now: start.addingTimeInterval(StjornarvaldPolicyNoticeRepository.repeatQuietInterval + 2)
        ))
        XCTAssertTrue(try fixture.pending().isEmpty)

        let reopened = try fixture.record(
            .violation,
            observationID: UUID(),
            occurredAt: start.addingTimeInterval(StjornarvaldPolicyNoticeRepository.repeatQuietInterval + 3)
        )
        XCTAssertEqual(reopened.type, .reopened)
        XCTAssertNotNil(try fixture.notices.queue(
            reopened,
            now: start.addingTimeInterval(StjornarvaldPolicyNoticeRepository.repeatQuietInterval + 3)
        ))
        XCTAssertEqual(try fixture.pending().count, 1)
    }

    func testManagedDeliverySnapshotIsReplayStableAndLedgerDistinguishesStates() throws {
        let fixture = try NoticeFixture()
        defer { fixture.cleanup() }
        let start = Date(timeIntervalSince1970: 2_000_000_100)
        _ = try fixture.notices.queue(
            fixture.record(.violation, observationID: UUID(), occurredAt: start), now: start
        )
        let first = try fixture.notices.reserveManagedContext(
            projectID: fixture.projectID,
            projectGeneration: fixture.generation,
            runID: fixture.runID,
            sessionID: fixture.sessionID,
            deliveryID: "managed-delivery-1",
            maximumCount: 8,
            maximumBytes: 16 * 1_024,
            now: start
        )
        XCTAssertEqual(first.pendingNotices.count, 1)

        let repeatTime = start.addingTimeInterval(
            StjornarvaldPolicyNoticeRepository.repeatQuietInterval + 1
        )
        _ = try fixture.notices.queue(
            fixture.record(.violation, observationID: UUID(), occurredAt: repeatTime),
            now: repeatTime
        )
        let replay = try fixture.notices.reserveManagedContext(
            projectID: fixture.projectID,
            projectGeneration: fixture.generation,
            runID: fixture.runID,
            sessionID: fixture.sessionID,
            deliveryID: "managed-delivery-1",
            maximumCount: 8,
            maximumBytes: 16 * 1_024,
            now: repeatTime
        )
        XCTAssertEqual(replay, first)
        try fixture.notices.markDeferred(deliveryID: "managed-delivery-1", now: repeatTime)
        XCTAssertEqual(
            try fixture.notices.deliveryState("managed-delivery-1"), .deliveryDeferred
        )
        try fixture.notices.markPresented(
            deliveryID: "managed-delivery-1", now: repeatTime.addingTimeInterval(1)
        )
        XCTAssertEqual(try fixture.notices.deliveryState("managed-delivery-1"), .presented)
        XCTAssertFalse(StjornarvaldPolicyNoticeFormatter.managedContext(first)?.isEmpty ?? true)
    }

    func testManagedExecutorSuppliesAdditiveContextAndPreservesRunOutcome() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("stj-managed-notice-\(UUID().uuidString)", isDirectory: true)
        let repository = try ProjectControlPlaneRepository(
            databaseURL: root.appendingPathComponent("control.sqlite3")
        )
        defer {
            Task { await repository.close() }
            try? FileManager.default.removeItem(at: root)
        }
        let projectRoot = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let projectID = ProjectID()
        _ = try await repository.registerProjectUnchecked(
            projectID: projectID, displayName: "Policy Context Fixture", canonicalRoot: projectRoot
        )
        let run = try await repository.createAutonomousRun(AutonomousRunRequest(
            projectID: projectID,
            projectGeneration: .initial,
            mission: "Keep the existing outcome while receiving policy context",
            providerID: "notice-provider",
            adapterID: "notice-adapter",
            modelKey: "notice-model",
            specification: AutonomousRunSpecification(
                allowedTools: ["fixture.read"], completionGates: ["tests"]
            ),
            authorizationScope: ToolAuthorizationScope(
                canonicalRoots: [projectRoot], allowedTools: ["fixture.read"], networkAllowed: false,
                maximumInlineOutputBytes: 64 * 1_024
            )
        ))
        let provider = NoticeFixtureProvider()
        let context = RecordingPolicyContextProvider(notice: NoticeFixture.notice())
        let broker = ToolInvocationBroker(
            repository: repository,
            executor: EmptyToolExecutor(),
            classifier: StaticToolReplayClassifier(classifications: [:])
        )
        let stepper = try ManagedProjectRunStepExecutor(
            repository: repository,
            providerResolver: { _ in provider },
            toolDefinitionResolver: { _ in [] },
            broker: broker,
            policyContext: context
        )
        let lease = try await repository.acquireRunLease(runID: run.runID, ownerID: "notice-test")
        defer { Task { _ = try? await repository.releaseRunLease(lease) } }
        var running = run
        for state in [AutonomousRunState.validating, .ready, .starting, .running] {
            running = try await repository.transitionAutonomousRun(
                runID: running.runID,
                lease: lease,
                transition: AutonomousRunTransition(
                    expectedState: running.state,
                    expectedRevision: running.revision,
                    nextState: state,
                    eventType: "notice_test_\(state.rawValue)",
                    eventSummary: "Advance managed notice fixture"
                )
            )
        }
        let preparedIntent = try await stepper.prepareNextStep(for: running)
        let intent = try XCTUnwrap(preparedIntent)
        let pending = try await repository.persistRunSideEffectIntent(
            runID: running.runID,
            lease: lease,
            expectedRevision: running.revision,
            intent: intent
        )
        let invocationContext = ToolInvocationContext(
            projectID: pending.projectID,
            projectGeneration: pending.projectGeneration,
            clientID: ClientID("notice-test"),
            runID: pending.runID,
            authorizationScope: ToolAuthorizationScope(
                canonicalRoots: [projectRoot], allowedTools: ["fixture.read"], networkAllowed: false,
                maximumInlineOutputBytes: 64 * 1_024
            )
        )
        let outcome = try await stepper.execute(
            intent, run: pending, context: invocationContext, lease: lease
        )
        guard case .continued = outcome else { return XCTFail("policy context changed run outcome") }
        let input = await provider.input
        XCTAssertTrue(input.contains("STJORNARVALD POLICY CONTEXT"))
        XCTAssertTrue(input.contains("Stjornarvald has not changed tools"))
        let contextState = await context.snapshot()
        XCTAssertEqual(contextState.contextCalls, 1)
        XCTAssertEqual(contextState.presented.count, 1)
        XCTAssertTrue(contextState.deferred.isEmpty)
    }

    func testToolQueuedManagedNoticeReachesImmediateFeedbackWithoutChangingCanonicalOutput() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("stj-managed-feedback-notice-\(UUID().uuidString)", isDirectory: true)
        let repository = try ProjectControlPlaneRepository(
            databaseURL: root.appendingPathComponent("control.sqlite3")
        )
        defer {
            Task { await repository.close() }
            try? FileManager.default.removeItem(at: root)
        }
        let projectRoot = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let projectID = ProjectID()
        _ = try await repository.registerProjectUnchecked(
            projectID: projectID, displayName: "Policy Context Fixture", canonicalRoot: projectRoot
        )
        let run = try await repository.createAutonomousRun(AutonomousRunRequest(
            projectID: projectID,
            projectGeneration: .initial,
            mission: "Read the fixture, then request completion on the immediate feedback",
            providerID: "notice-provider",
            adapterID: "notice-adapter",
            modelKey: "notice-model",
            specification: AutonomousRunSpecification(
                allowedTools: ["fixture.read"], completionGates: ["tests"]
            ),
            authorizationScope: ToolAuthorizationScope(
                canonicalRoots: [projectRoot], allowedTools: ["fixture.read"], networkAllowed: false,
                maximumInlineOutputBytes: 64 * 1_024
            )
        ))
        let noticeFixture = try NoticeFixture()
        defer { noticeFixture.cleanup() }
        let provider = ToolFeedbackNoticeProvider()
        let toolExecutor = ToolFeedbackNoticeExecutor(fixture: noticeFixture)
        let context = StjornarvaldCodingAgentPolicyReporter(repository: noticeFixture.notices)
        let broker = ToolInvocationBroker(
            repository: repository,
            executor: toolExecutor,
            classifier: StaticToolReplayClassifier(classifications: ["fixture.read": .readOnly])
        )
        let stepper = try ManagedProjectRunStepExecutor(
            repository: repository,
            providerResolver: { _ in provider },
            toolDefinitionResolver: { _ in [] },
            broker: broker,
            policyContext: context
        )
        let lease = try await repository.acquireRunLease(runID: run.runID, ownerID: "notice-test")
        defer { Task { _ = try? await repository.releaseRunLease(lease) } }
        var running = run
        for state in [AutonomousRunState.validating, .ready, .starting, .running] {
            running = try await repository.transitionAutonomousRun(
                runID: running.runID,
                lease: lease,
                transition: AutonomousRunTransition(
                    expectedState: running.state,
                    expectedRevision: running.revision,
                    nextState: state,
                    eventType: "notice_test_\(state.rawValue)",
                    eventSummary: "Advance managed notice fixture"
                )
            )
        }
        let preparedIntent = try await stepper.prepareNextStep(for: running)
        let intent = try XCTUnwrap(preparedIntent)
        let pending = try await repository.persistRunSideEffectIntent(
            runID: running.runID,
            lease: lease,
            expectedRevision: running.revision,
            intent: intent
        )
        let invocationContext = ToolInvocationContext(
            projectID: pending.projectID,
            projectGeneration: pending.projectGeneration,
            clientID: ClientID("notice-test"),
            runID: pending.runID,
            authorizationScope: ToolAuthorizationScope(
                canonicalRoots: [projectRoot], allowedTools: ["fixture.read"], networkAllowed: false,
                maximumInlineOutputBytes: 64 * 1_024
            )
        )
        let outcome = try await stepper.execute(
            intent, run: pending, context: invocationContext, lease: lease
        )
        guard case .completionRequestedWithWork(let summary, _) = outcome else {
            return XCTFail("same-feedback notice delivery must preserve the provider completion outcome")
        }
        XCTAssertEqual(summary, "NOTICE_FEEDBACK_SEEN")
        let inputs = await provider.snapshot()
        XCTAssertEqual(inputs.rootCalls, 1)
        XCTAssertEqual(inputs.continuationCalls, 1)
        XCTAssertEqual(inputs.previousResponseID, "notice-feedback-root")
        XCTAssertFalse(inputs.rootInput.contains("STJORNARVALD POLICY CONTEXT"),
            "The notice is queued by the tool, after the root input is already dispatched.")
        let feedback = try XCTUnwrap(inputs.feedbackInput)
        let items = try XCTUnwrap(try JSONSerialization.jsonObject(with: feedback) as? [[String: Any]])
        let outputs = items.filter { $0["type"] as? String == "function_call_output" }
        XCTAssertEqual(outputs.count, 1)
        let output = try XCTUnwrap(outputs.first)
        XCTAssertEqual(output["call_id"] as? String, "notice-feedback-read")
        XCTAssertEqual(output["output"] as? String,
            try JSONSupport.canonicalJSON(ToolFeedbackNoticeExecutor.result.payload))
        XCTAssertEqual(toolExecutor.callCount, 1)
        let noticeScope = try XCTUnwrap(toolExecutor.scope)
        XCTAssertEqual(noticeScope.projectID, pending.projectID.description)
        XCTAssertEqual(noticeScope.projectGeneration, 1)
        XCTAssertEqual(noticeScope.runID, pending.runID.description)
        XCTAssertNotNil(noticeScope.sessionID)
        let supplied = try XCTUnwrap(String(data: feedback, encoding: .utf8))
        XCTAssertTrue(supplied.contains("STJORNARVALD POLICY CONTEXT"),
            "A notice queued by this exact tool effect must reach its immediate feedback turn.")
        XCTAssertTrue(supplied.contains("Stjornarvald has not changed tools"))
        XCTAssertEqual(try noticeFixture.notices.deliveryState("managed:\(intent.idempotencyKey):1"),
            .presented, "Mark presented only after the provider accepted that additive feedback context.")
    }

    func testOrdinaryLMStudioNoticeDefersAtMeasuredWholeBodyCapWithoutSourceCarryover() async throws {
        let transport = OrdinaryNoticeBodyCapTransport()
        let provider = LMStudioManagedModelProvider(transport: transport)
        try await withToolFeedbackNoticeFixture(provider: provider) { fixture in
            let carryover = try await fixture.repository.nativeSourceBudgetCarryover(runID: fixture.pending.runID)
            XCTAssertNil(carryover, "Exercise ordinary managed provider path, not source carryover admission")
            let outcome = try await fixture.stepper.execute(fixture.intent, run: fixture.pending,
                context: fixture.context, lease: fixture.lease)
            guard case .completionRequestedWithWork = outcome else { return XCTFail("Optional notice blocked ordinary valid tool feedback") }
            let controls = await transport.snapshot()
            XCTAssertEqual(controls.rootCalls, 1)
            XCTAssertEqual(controls.feedbackCalls, 1)
            XCTAssertEqual(controls.rejectedNoticePreflights, 1)
            XCTAssertGreaterThan(try XCTUnwrap(controls.maximumRequestBytes), try XCTUnwrap(controls.baseBodyBytes))
            XCTAssertGreaterThan(try XCTUnwrap(controls.noticeBodyBytes), try XCTUnwrap(controls.maximumRequestBytes))
            XCTAssertEqual(controls.feedbackInput.count, 1)
            guard case .functionCallOutput(let callID, let output) = controls.feedbackInput[0] else {
                return XCTFail("Original ordinary function output was lost")
            }
            XCTAssertEqual(callID, "notice-feedback-read")
            XCTAssertEqual(output, try JSONSupport.canonicalJSON(ToolFeedbackNoticeExecutor.result.payload))
            XCTAssertEqual(fixture.executor.callCount, 1)
            XCTAssertEqual(try fixture.notices.deliveryState("managed:\(fixture.intent.idempotencyKey):1"), .deliveryDeferred)
        }
    }

    func testLegacyLMStudioTransportWithoutOptionalPreflightKeepsOutputAndNoticePending() async throws {
        let transport = OrdinaryNoticeBodyCapTransport()
        let provider = LMStudioManagedModelProvider(transport: OrdinaryNoticeLegacyTransport(base: transport))
        try await withToolFeedbackNoticeFixture(provider: provider) { fixture in
            let outcome = try await fixture.stepper.execute(fixture.intent, run: fixture.pending,
                context: fixture.context, lease: fixture.lease)
            guard case .completionRequestedWithWork = outcome else { return XCTFail("Optional preflight refinement blocked legacy transport") }
            let controls = await transport.snapshot()
            XCTAssertEqual(controls.rootCalls, 1)
            XCTAssertEqual(controls.feedbackCalls, 1)
            XCTAssertEqual(controls.rejectedNoticePreflights, 0)
            XCTAssertEqual(controls.feedbackInput.count, 1)
            XCTAssertEqual(try fixture.notices.deliveryState("managed:\(fixture.intent.idempotencyKey):1"), .deliveryDeferred)
        }
    }

    func testFeedbackNoticeDefersAt128ItemsWithoutDroppingToolOutputs() async throws {
        let count = ManagedModelProviderContract.maximumMessageCount
        let provider = ToolFeedbackNoticeProvider(callCount: count)
        try await withToolFeedbackNoticeFixture(provider: provider, callCount: count) { fixture in
            let outcome = try await fixture.stepper.execute(fixture.intent, run: fixture.pending,
                context: fixture.context, lease: fixture.lease)
            guard case .completionRequestedWithWork = outcome else { return XCTFail("Optional notice changed full output-batch outcome") }
            let snapshot = await provider.snapshot()
            let input = try XCTUnwrap(snapshot.feedbackInput)
            let items = try XCTUnwrap(JSONSerialization.jsonObject(with: input) as? [[String: Any]])
            XCTAssertEqual(items.count, count)
            for (index, item) in items.enumerated() {
                XCTAssertEqual(item["type"] as? String, "function_call_output")
                XCTAssertEqual(item["call_id"] as? String, ToolFeedbackNoticeProvider.callID(index, count: count))
                XCTAssertEqual(item["output"] as? String, try JSONSupport.canonicalJSON(ToolFeedbackNoticeExecutor.result.payload))
            }
            XCTAssertEqual(fixture.executor.callCount, count)
            XCTAssertEqual(try fixture.notices.deliveryState("managed:\(fixture.intent.idempotencyKey):1"), .deliveryDeferred)
        }
    }

    func testFeedbackNoticeDefersAt512KiBWithoutChangingEscapedOutputBytes() async throws {
        let count = 64
        let empty = ToolResult.success(["value": ""])
        let skeleton: [[String: Any]] = try (0..<count).map { index in
            ["type": "function_call_output", "call_id": ToolFeedbackNoticeProvider.callID(index, count: count),
             "output": try JSONSupport.canonicalJSON(empty.payload)]
        }
        let skeletonBytes = try JSONSerialization.data(withJSONObject: skeleton,
            options: [.sortedKeys, .withoutEscapingSlashes]).count
        let padding = (ManagedModelProviderContract.maximumContinuationInputBytes - 100 - skeletonBytes) / count
        let result = ToolResult.success(["value": String(repeating: "x", count: padding)])
        let provider = ToolFeedbackNoticeProvider(callCount: count)
        try await withToolFeedbackNoticeFixture(provider: provider, callCount: count, result: result) { fixture in
            let outcome = try await fixture.stepper.execute(fixture.intent, run: fixture.pending,
                context: fixture.context, lease: fixture.lease)
            guard case .completionRequestedWithWork = outcome else { return XCTFail("Optional notice blocked valid near-cap output") }
            let snapshot = await provider.snapshot()
            let input = try XCTUnwrap(snapshot.feedbackInput)
            XCTAssertLessThanOrEqual(input.count, ManagedModelProviderContract.maximumContinuationInputBytes)
            XCTAssertGreaterThan(input.count, ManagedModelProviderContract.maximumContinuationInputBytes - 200)
            let items = try XCTUnwrap(JSONSerialization.jsonObject(with: input) as? [[String: Any]])
            XCTAssertEqual(items.count, count)
            let expected = try JSONSupport.canonicalJSON(result.payload)
            XCTAssertTrue(items.allSatisfy { $0["type"] as? String == "function_call_output" && $0["output"] as? String == expected })
            XCTAssertEqual(fixture.executor.callCount, count)
            XCTAssertEqual(try fixture.notices.deliveryState("managed:\(fixture.intent.idempotencyKey):1"), .deliveryDeferred)
        }
    }

    func testRejectedLegacyFeedbackNeverMarksPolicyNoticePresented() async throws {
        for mode in [ToolFeedbackNoticeProvider.Mode.wrongProvider, .incomplete] {
            let provider = ToolFeedbackNoticeProvider(mode: mode)
            try await withToolFeedbackNoticeFixture(provider: provider) { fixture in
                do {
                    _ = try await fixture.stepper.execute(fixture.intent, run: fixture.pending,
                        context: fixture.context, lease: fixture.lease)
                    XCTFail("Mismatched or incomplete feedback response was accepted")
                } catch { XCTAssertEqual(error as? ManagedModelProviderContractError, .incompleteTerminalResponse) }
                let snapshot = await provider.snapshot()
                XCTAssertTrue(String(decoding: try XCTUnwrap(snapshot.feedbackInput), as: UTF8.self).contains("STJORNARVALD POLICY CONTEXT"))
                XCTAssertEqual(try fixture.notices.deliveryState("managed:\(fixture.intent.idempotencyKey):1"), .deliveryDeferred)
                let scope = try XCTUnwrap(fixture.executor.scope)
                let pending = try fixture.notices.pending(targetKind: .managedProvider,
                    targetIdentity: StjornarvaldPolicyNoticeRepository.managedTargetIdentity(projectID: try XCTUnwrap(scope.projectID),
                        generation: try XCTUnwrap(scope.projectGeneration), runID: try XCTUnwrap(scope.runID), sessionID: scope.sessionID),
                    maximumCount: 8, maximumBytes: 16 * 1_024)
                XCTAssertEqual(pending.count, 1)
            }
        }
    }

    func testFeedbackNoticeDefersWhenBudgetRequestsRolloverBeforeSubmission() async throws {
        let provider = ToolFeedbackNoticeProvider()
        try await withToolFeedbackNoticeFixture(provider: provider, budget: FeedbackBeforeTurnRolloverBudget()) { fixture in
            let outcome = try await fixture.stepper.execute(fixture.intent, run: fixture.pending,
                context: fixture.context, lease: fixture.lease)
            guard case .rolloverRequired = outcome else { return XCTFail("Expected ordinary budget rollover deferral") }
            let snapshot = await provider.snapshot()
            XCTAssertEqual(snapshot.rootCalls, 1)
            XCTAssertEqual(snapshot.continuationCalls, 0, "Deferral must not POST notice-bearing feedback")
            XCTAssertEqual(fixture.executor.callCount, 1)
            XCTAssertEqual(try fixture.notices.deliveryState("managed:\(fixture.intent.idempotencyKey):1"), .deliveryDeferred)
        }
    }

    func testOrdinaryMCPAddsSeparateContentWithoutChangingCanonicalResult() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("stj-mcp-notice-\(UUID().uuidString)", isDirectory: true)
        let app = try ForgeApp.bootstrap(home: root)
        defer {
            _ = app.shutdown()
            try? FileManager.default.removeItem(at: root)
        }
        let noticeProvider = StaticInteractiveNoticeProvider(notice: NoticeFixture.notice())
        let withNotice = MCPServer(
            app: app,
            clientID: ClientID("notice-wire"),
            policyNoticeProvider: noticeProvider
        )
        let withoutNotice = MCPServer(
            app: app,
            clientID: ClientID("plain-wire"),
            policyNoticeProvider: NoInteractivePolicyNoticeProvider()
        )
        let request: [String: Any] = [
            "jsonrpc": "2.0", "id": 91, "method": "tools/call",
            "params": ["name": "unknown.notice.fixture", "arguments": [:]] as [String: Any],
        ]
        let decorated = try XCTUnwrap(withNotice.handle(request))
        let canonical = try XCTUnwrap(withoutNotice.handle(request))
        let decoratedResult = try XCTUnwrap(decorated["result"] as? [String: Any])
        let canonicalResult = try XCTUnwrap(canonical["result"] as? [String: Any])
        let decoratedStructured = try XCTUnwrap(
            decoratedResult["structuredContent"] as? [String: Any]
        )
        let canonicalStructured = try XCTUnwrap(
            canonicalResult["structuredContent"] as? [String: Any]
        )
        XCTAssertEqual(
            try JSONSupport.canonicalJSON(decoratedStructured),
            try JSONSupport.canonicalJSON(canonicalStructured)
        )
        XCTAssertEqual(decoratedResult["isError"] as? Bool, canonicalResult["isError"] as? Bool)
        let decoratedContent = try XCTUnwrap(decoratedResult["content"] as? [[String: Any]])
        let canonicalContent = try XCTUnwrap(canonicalResult["content"] as? [[String: Any]])
        XCTAssertEqual(decoratedContent.count, 2)
        XCTAssertEqual(canonicalContent.count, 1)
        XCTAssertEqual(
            try JSONSupport.canonicalJSON(decoratedContent[0]),
            try JSONSupport.canonicalJSON(canonicalContent[0])
        )
        XCTAssertTrue((decoratedContent[1]["text"] as? String)?.contains(
            "this notice did not change the tool result"
        ) == true)
        XCTAssertFalse(noticeProvider.controlsExecution)
    }

    func testInteractiveCacheRefreshesExactScopeAndRecordsPresentation() async throws {
        let fixture = try NoticeFixture()
        defer { fixture.cleanup() }
        let clientID = "scoped-mcp-client"
        let event = try fixture.record(
            .violation,
            observationID: UUID(),
            occurredAt: Date(),
            scope: DevelopmentObservationScope(
                projectID: fixture.projectID,
                projectGeneration: fixture.generation,
                clientID: clientID
            )
        )
        _ = try fixture.notices.queue(event)
        let cache = StjornarvaldInteractivePolicyNoticeCache(
            repository: fixture.notices,
            projectID: fixture.projectID,
            projectGeneration: fixture.generation,
            clientID: clientID
        )
        let deliveryID = "mcp-scoped-delivery"
        var presentation: PolicyNoticePresentation?
        for _ in 0..<100 where presentation == nil {
            presentation = cache.presentation(
                deliveryID: deliveryID,
                projectID: fixture.projectID,
                projectGeneration: fixture.generation,
                clientID: clientID,
                maximumCount: 8,
                maximumBytes: 16 * 1_024
            )
            if presentation == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        let delivered = try XCTUnwrap(presentation)
        XCTAssertEqual(delivered.notices.count, 1)
        cache.didPresent(delivered)
        var state: PolicyNoticeDeliveryState?
        for _ in 0..<100 where state != .presented {
            state = try fixture.notices.deliveryState(deliveryID)
            if state != .presented { try await Task.sleep(for: .milliseconds(10)) }
        }
        XCTAssertEqual(state, .presented)
    }

    func testInteractiveCacheDiscoversLaterNoticeInUnchangedScopeAndBecomesIdle() async throws {
        let fixture = try NoticeFixture()
        defer { fixture.cleanup() }
        let clientID = "long-lived-mcp-client"
        let cache = StjornarvaldInteractivePolicyNoticeCache(
            repository: fixture.notices, projectID: fixture.projectID,
            projectGeneration: fixture.generation, clientID: clientID
        )
        for _ in 0..<100 where cache.refreshState().workerActive {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(cache.refreshState().workerActive)
        let event = try fixture.record(.violation, observationID: UUID(), occurredAt: Date(),
            scope: DevelopmentObservationScope(projectID: fixture.projectID,
                projectGeneration: fixture.generation, clientID: clientID))
        _ = try fixture.notices.queue(event)
        var presentation: PolicyNoticePresentation?
        for _ in 0..<100 where presentation == nil {
            presentation = cache.presentation(deliveryID: "late-same-scope",
                projectID: fixture.projectID, projectGeneration: fixture.generation,
                clientID: clientID, maximumCount: 8, maximumBytes: 16 * 1_024)
            XCTAssertLessThanOrEqual(cache.refreshState().pendingTargetCount, 1)
            if presentation == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        let delivered = try XCTUnwrap(presentation)
        XCTAssertEqual(delivered.notices.map(\.violationID), [event.violationID])
        cache.didPresent(delivered)
        for _ in 0..<100 {
            if try fixture.notices.deliveryState(delivered.id) == .presented,
               !cache.refreshState().workerActive { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(try fixture.notices.deliveryState(delivered.id), .presented)
        XCTAssertFalse(cache.refreshState().workerActive)
        XCTAssertEqual(cache.refreshState().pendingTargetCount, 0)
        XCTAssertNil(cache.presentation(deliveryID: "different-generation",
            projectID: fixture.projectID, projectGeneration: fixture.generation + 1,
            clientID: clientID, maximumCount: 8, maximumBytes: 16 * 1_024))
    }

    func testInteractiveCacheSuppressesReceiptWhileAnEarlierReadPublishes() async throws {
        let fixture = try NoticeFixture()
        defer { fixture.cleanup() }
        let client = "receipt-interleaving-client"
        let event = try fixture.record(.violation, observationID: UUID(), occurredAt: Date(),
            scope: DevelopmentObservationScope(projectID: fixture.projectID,
                projectGeneration: fixture.generation, clientID: client))
        _ = try fixture.notices.queue(event)
        let gate = NoticeCacheInterleavingGate()
        defer { gate.releaseRead.signal(); gate.releaseReceipt.signal() }
        let cache = StjornarvaldInteractivePolicyNoticeCache(repository: fixture.notices,
            projectID: fixture.projectID, projectGeneration: fixture.generation, clientID: client,
            checkpoint: { gate.visit($0) })
        for _ in 0..<100 where cache.refreshState().workerActive {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(cache.refreshState().workerActive)
        gate.arm()
        let presentation = try XCTUnwrap(cache.presentation(deliveryID: "receipt-race-first",
            projectID: fixture.projectID, projectGeneration: fixture.generation,
            clientID: client, maximumCount: 8, maximumBytes: 16 * 1_024))
        XCTAssertEqual(gate.readEntered.wait(timeout: .now() + 2), .success)
        cache.didPresent(presentation)
        XCTAssertEqual(cache.refreshState().pendingPresentedNoticeCount, 1)
        XCTAssertLessThanOrEqual(cache.refreshState().pendingPresentedNoticeCount,
                                StjornarvaldInteractivePolicyNoticeCache.maximumPendingPresentedNoticeIDs)
        gate.releaseRead.signal()
        XCTAssertEqual(gate.receiptEntered.wait(timeout: .now() + 2), .success)
        // The read fetched this notice before didPresent. Its late publication
        // must not expose it again while the durable receipt is still pending.
        XCTAssertNil(cache.presentation(deliveryID: "receipt-race-second",
            projectID: fixture.projectID, projectGeneration: fixture.generation,
            clientID: client, maximumCount: 8, maximumBytes: 16 * 1_024))
        XCTAssertEqual(cache.refreshState().pendingPresentedNoticeCount, 1)
        gate.releaseReceipt.signal()
        for _ in 0..<100 {
            if try fixture.notices.deliveryState(presentation.id) == .presented,
               cache.refreshState().pendingPresentedNoticeCount == 0,
               !cache.refreshState().workerActive { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(try fixture.notices.deliveryState(presentation.id), .presented)
        XCTAssertEqual(cache.refreshState().pendingPresentedNoticeCount, 0)
        XCTAssertFalse(cache.refreshState().workerActive)
        XCTAssertFalse(gate.didTimeOut)
    }

    func testInteractiveManagerReservationIsReplayStableAndBatchReceiptIsValidated() throws {
        let fixture = try NoticeFixture()
        defer { fixture.cleanup() }
        let clientID = "manager-api-client"
        let event = try fixture.record(
            .violation,
            observationID: UUID(),
            occurredAt: Date(),
            scope: DevelopmentObservationScope(
                projectID: fixture.projectID,
                projectGeneration: fixture.generation,
                clientID: clientID
            )
        )
        _ = try fixture.notices.queue(event)
        let first = try XCTUnwrap(try fixture.notices.reserveInteractivePresentation(
            deliveryID: "manager-api-delivery",
            projectID: fixture.projectID,
            projectGeneration: fixture.generation,
            clientID: clientID,
            maximumCount: 8,
            maximumBytes: 16 * 1_024
        ))
        let replay = try XCTUnwrap(try fixture.notices.reserveInteractivePresentation(
            deliveryID: "manager-api-delivery",
            projectID: fixture.projectID,
            projectGeneration: fixture.generation,
            clientID: clientID,
            maximumCount: 8,
            maximumBytes: 16 * 1_024
        ))
        XCTAssertEqual(first.notices, replay.notices)
        XCTAssertEqual(first.digestSHA256, replay.digestSHA256)
        XCTAssertEqual(try fixture.notices.deliveryState(first.id), .pending)

        XCTAssertThrowsError(try fixture.notices.markPresented(
            deliveryIDs: [first.id, first.id]
        ))
        XCTAssertThrowsError(try fixture.notices.markPresented(
            deliveryIDs: [first.id, "unknown-delivery"]
        ))
        XCTAssertEqual(try fixture.notices.deliveryState(first.id), .pending)
        try fixture.notices.markPresented(deliveryIDs: [first.id])
        XCTAssertEqual(try fixture.notices.deliveryState(first.id), .presented)
    }

    func testNoticeTextIsBoundedAndRedactsSecrets() throws {
        let fixture = try NoticeFixture(summary: "api_key=super-secret-value")
        defer { fixture.cleanup() }
        let event = try fixture.record(.violation, observationID: UUID(), occurredAt: Date())
        let notice = try XCTUnwrap(try fixture.notices.queue(event))
        XCTAssertFalse(notice.summary.contains("super-secret-value"))
        XCTAssertEqual(notice.policyStatement, fixture.rule.statement)
        let text = try XCTUnwrap(StjornarvaldPolicyNoticeFormatter.interactivePresentation(
            notices: Array(repeating: notice, count: 100), maximumBytes: 1_024
        ))
        XCTAssertLessThanOrEqual(text.utf8.count, 1_024)
        XCTAssertTrue(text.contains("Policy:"))
        XCTAssertTrue(text.contains("Development continues"))
    }
}

private final class NoticeCacheInterleavingGate: @unchecked Sendable {
    let readEntered = DispatchSemaphore(value: 0)
    let receiptEntered = DispatchSemaphore(value: 0)
    let releaseRead = DispatchSemaphore(value: 0)
    let releaseReceipt = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var readArmed = false
    private var receiptArmed = false
    private var timedOut = false
    var didTimeOut: Bool {
        lock.lock(); defer { lock.unlock() }; return timedOut
    }
    func arm() {
        lock.lock(); readArmed = true; receiptArmed = true; lock.unlock()
    }
    func visit(_ checkpoint: StjornarvaldInteractivePolicyNoticeCache.Checkpoint) {
        lock.lock()
        let shouldWait: Bool
        let entered: DispatchSemaphore
        let release: DispatchSemaphore
        switch checkpoint {
        case .beforeCachePublication:
            shouldWait = readArmed; readArmed = false
            entered = readEntered; release = releaseRead
        case .beforeReceiptPersistence:
            shouldWait = receiptArmed; receiptArmed = false
            entered = receiptEntered; release = releaseReceipt
        }
        lock.unlock()
        guard shouldWait else { return }
        entered.signal()
        if release.wait(timeout: .now() + 2) == .timedOut {
            lock.lock(); timedOut = true; lock.unlock()
        }
    }
}

private final class NoticeFixture {
    let root: URL
    let database: URL
    let log: StjornarvaldPolicyLogStore
    let notices: StjornarvaldPolicyNoticeRepository
    let rule: PolicyRule
    let projectID = "project-notice"
    let generation = 1
    let runID = "run-notice"
    let sessionID = "session-notice"
    let summary: String

    init(summary: String = "Shipping runtime contains a non-native worker") throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("stj-notice-\(UUID().uuidString)", isDirectory: true)
        database = root.appendingPathComponent("policy.sqlite3")
        log = try StjornarvaldPolicyLogStore(
            databaseURL: database,
            jsonlURL: root.appendingPathComponent("policy.jsonl")
        )
        notices = try StjornarvaldPolicyNoticeRepository(databaseURL: database)
        rule = try XCTUnwrap(RavenForgeDevelopmentPolicyAdapter().rules().first)
        self.summary = summary
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func record(
        _ disposition: PolicyDetectorFindingDisposition,
        observationID: UUID,
        occurredAt: Date,
        scope: DevelopmentObservationScope? = nil
    ) throws -> PolicyViolationEvent {
        let candidate = PolicyViolationCandidate(
            rule: rule,
            observationID: observationID,
            scope: scope ?? DevelopmentObservationScope(
                projectID: projectID,
                projectGeneration: generation,
                runID: runID,
                sessionID: sessionID
            ),
            subjectIdentity: "shipping-runtime",
            summary: summary,
            evidenceReferences: ["target-membership"],
            explanation: summary,
            confidence: 0.95,
            suggestedCorrection: "Remove the non-native shipping runtime.",
            conditionIdentity: "runtime"
        )
        let finding = PolicyDetectorFinding(
            detectorID: "notice-fixture", disposition: disposition, candidate: candidate
        )
        let service = StjornarvaldViolationLifecycleService(store: log)
        let application = try service.apply(finding, occurredAt: occurredAt)
        guard case .recorded(_, let event) = application else {
            throw StjornarvaldPolicyNoticeError.invalid("fixture did not record an event")
        }
        return event
    }

    func pending() throws -> [CodingAgentPolicyNotice] {
        try notices.pending(
            targetKind: .managedProvider,
            targetIdentity: StjornarvaldPolicyNoticeRepository.managedTargetIdentity(
                projectID: projectID, generation: generation, runID: runID, sessionID: sessionID
            ),
            maximumCount: 64,
            maximumBytes: 16 * 1_024
        )
    }

    static func notice() -> CodingAgentPolicyNotice {
        let rule = RavenForgeDevelopmentPolicyAdapter().rules()[0]
        return CodingAgentPolicyNotice(
            violationID: PolicyViolationID(),
            ruleReference: rule.source,
            summary: "A shipping runtime is outside the native stack.",
            suggestedCorrection: "Move the runtime into the native target.",
            confidence: 0.95
        )
    }
}

private actor RecordingPolicyContextProvider: PolicyContextProviding {
    struct State: Sendable {
        let contextCalls: Int
        let presented: [String]
        let deferred: [String]
    }

    private let notice: CodingAgentPolicyNotice
    private var contextCalls = 0
    private var presentedIDs: [String] = []
    private var deferredIDs: [String] = []

    init(notice: CodingAgentPolicyNotice) { self.notice = notice }

    func context(
        projectID: String,
        projectGeneration: Int,
        runID: String,
        sessionID: String?,
        deliveryID: String,
        maximumCount: Int,
        maximumBytes: Int
    ) async -> PolicyContextSnapshot {
        contextCalls += 1
        return PolicyContextSnapshot(
            policyIdentity: "Raven Forge Development fixture",
            applicableRuleSummaries: ["Native shipping stack"],
            pendingNotices: [notice],
            limitations: []
        )
    }

    func presented(deliveryID: String) async { presentedIDs.append(deliveryID) }
    func deferred(deliveryID: String) async { deferredIDs.append(deliveryID) }

    func snapshot() -> State {
        State(contextCalls: contextCalls, presented: presentedIDs, deferred: deferredIDs)
    }
}

private actor NoticeFixtureProvider: ManagedModelProvider {
    nonisolated let providerID = "notice-provider"
    private(set) var input = ""
    private var receipts: [String: ProviderTurn] = [:]

    func probe() async throws -> ProviderCapabilities {
        try ProviderCapabilities(
            providerID: providerID,
            providerVersion: "fixture-1",
            modelKey: "notice-model",
            providerInstanceID: "notice-instance",
            contextLength: 32_768,
            maximumContextLength: 65_536,
            statefulResponses: true,
            streaming: true,
            customTools: true,
            mcp: false,
            structuredOutput: false,
            usageReporting: true,
            idempotencyLookup: true,
            capabilityFingerprintSHA256: String(repeating: "d", count: 64)
        )
    }

    func createRoot(_ request: ProviderRootRequest) async throws -> ProviderTurn {
        if let existing = receipts[request.idempotencyKey] { return existing }
        input = request.input
        let turn = try ProviderTurn(
            requestID: "notice-request",
            responseID: "notice-response",
            providerID: providerID,
            providerVersion: "fixture-1",
            modelKey: "notice-model",
            providerInstanceID: "notice-instance",
            messages: ["Continue the assigned work."],
            toolCalls: [],
            usage: nil,
            completed: true,
            finishReason: .stop
        )
        receipts[request.idempotencyKey] = turn
        return turn
    }

    func continueSession(_ request: ProviderContinuationRequest) async throws -> ProviderTurn {
        throw AutonomyError.invalidRequest("fixture does not continue")
    }

    func lookup(idempotencyKey: String) async throws -> ProviderTurn? { receipts[idempotencyKey] }
    func cancel(requestID: String) async {}
}

private final class EmptyToolExecutor: ToolExecuting, @unchecked Sendable {
    var toolNames: [String] { [] }
    func call(name: String, arguments: [String: Any], clientID: ClientID) throws -> ToolResult {
        .failure(code: "unexpected_tool", message: name)
    }
    func call(name: String, arguments: [String: Any], context: ToolInvocationContext) throws -> ToolResult {
        .failure(code: "unexpected_tool", message: name)
    }
}

private final class StaticInteractiveNoticeProvider:
    InteractivePolicyNoticeProviding, @unchecked Sendable {
    private let notice: CodingAgentPolicyNotice
    let controlsExecution = false

    init(notice: CodingAgentPolicyNotice) { self.notice = notice }

    func presentation(
        deliveryID: String,
        projectID: String?,
        projectGeneration: Int?,
        clientID: String,
        maximumCount: Int,
        maximumBytes: Int
    )
        -> PolicyNoticePresentation? {
        guard let text = StjornarvaldPolicyNoticeFormatter.interactivePresentation(
            notices: [notice], maximumBytes: maximumBytes
        ) else { return nil }
        return PolicyNoticePresentation(
            id: deliveryID,
            targetKind: .mcpClient,
            targetIdentity: "fixture-client",
            notices: [notice],
            text: text,
            digestSHA256: JSONSupport.sha256Hex(text)
        )
    }

    func didPresent(_ presentation: PolicyNoticePresentation) {}
}

private actor ToolFeedbackNoticeProvider: ManagedModelProvider {
    struct Snapshot: Sendable {
        let rootCalls: Int
        let continuationCalls: Int
        let rootInput: String
        let feedbackInput: Data?
        let previousResponseID: String?
    }
    enum Mode: Sendable { case normal, wrongProvider, incomplete }
    nonisolated let providerID = "notice-provider"
    private let callCount: Int
    private let mode: Mode
    init(callCount: Int = 1, mode: Mode = .normal) { self.callCount = callCount; self.mode = mode }
    nonisolated static func callID(_ index: Int, count: Int) -> String {
        count == 1 ? "notice-feedback-read" : "notice-feedback-read-\(index)"
    }
    private var receipts: [String: ProviderTurn] = [:]
    private var rootCalls = 0
    private var continuationCalls = 0
    private var rootInput = ""
    private var feedbackInput: Data?
    private var previousResponseID: String?

    func probe() async throws -> ProviderCapabilities {
        try ProviderCapabilities(
            providerID: providerID,
            providerVersion: "fixture-1",
            modelKey: "notice-model",
            providerInstanceID: "notice-instance",
            contextLength: 32_768,
            maximumContextLength: 65_536,
            statefulResponses: true,
            streaming: true,
            customTools: true,
            mcp: false,
            structuredOutput: false,
            usageReporting: true,
            idempotencyLookup: true,
            capabilityFingerprintSHA256: String(repeating: "d", count: 64)
        )
    }

    func createRoot(_ request: ProviderRootRequest) async throws -> ProviderTurn {
        if let existing = receipts[request.idempotencyKey] { return existing }
        guard rootCalls == 0 else { throw AutonomyError.invalidRequest("feedback fixture root duplicated") }
        rootCalls += 1
        rootInput = request.input
        let turn = try ProviderTurn(
            requestID: "notice-feedback-request-root", responseID: "notice-feedback-root",
            providerID: providerID, providerVersion: "fixture-1", modelKey: "notice-model",
            providerInstanceID: "notice-instance", messages: [],
            toolCalls: try (0..<callCount).map { index in
                try ProviderToolCall(callID: Self.callID(index, count: callCount), name: "fixture.read", argumentsJSON: Data("{}".utf8))
            }, usage: nil, completed: true, finishReason: .toolCalls
        )
        receipts[request.idempotencyKey] = turn
        return turn
    }

    func continueSession(_ request: ProviderContinuationRequest) async throws -> ProviderTurn {
        if let existing = receipts[request.idempotencyKey] { return existing }
        guard continuationCalls == 0, request.previousResponseID == "notice-feedback-root" else {
            throw AutonomyError.invalidRequest("feedback fixture continuation duplicated or misbound")
        }
        continuationCalls += 1
        feedbackInput = request.input
        previousResponseID = request.previousResponseID
        let turn = try ProviderTurn(
            requestID: "notice-feedback-request-final", responseID: "notice-feedback-final",
            previousResponseID: request.previousResponseID,
            providerID: mode == .wrongProvider ? "different-provider" : providerID, providerVersion: "fixture-1", modelKey: "notice-model",
            providerInstanceID: "notice-instance",
            messages: ["{\"forge_run_status\":\"completion_requested\",\"summary\":\"NOTICE_FEEDBACK_SEEN\"}"],
            toolCalls: [], usage: nil, completed: mode != .incomplete, finishReason: .stop
        )
        receipts[request.idempotencyKey] = turn
        return turn
    }

    func lookup(idempotencyKey: String) async throws -> ProviderTurn? { receipts[idempotencyKey] }
    func cancel(requestID: String) async {}
    func snapshot() -> Snapshot {
        Snapshot(rootCalls: rootCalls, continuationCalls: continuationCalls, rootInput: rootInput,
            feedbackInput: feedbackInput, previousResponseID: previousResponseID)
    }
}

private final class ToolFeedbackNoticeExecutor: ToolExecuting, @unchecked Sendable {
    static let result = ToolResult.success(["value": "UNCHANGED_CANONICAL_TOOL_RESULT"])
    var toolNames: [String] { ["fixture.read"] }
    private let fixture: NoticeFixture
    private let maximumCalls: Int
    private let returnedResult: ToolResult
    private(set) var callCount = 0
    private(set) var scope: DevelopmentObservationScope?

    init(fixture: NoticeFixture, maximumCalls: Int = 1, result: ToolResult = ToolFeedbackNoticeExecutor.result) {
        self.fixture = fixture; self.maximumCalls = maximumCalls; self.returnedResult = result
    }
    func call(name: String, arguments: [String: Any], clientID: ClientID) throws -> ToolResult {
        throw AutonomyError.invalidRequest("feedback fixture requires the actual bound invocation context")
    }
    func call(name: String, arguments: [String: Any], context: ToolInvocationContext) throws -> ToolResult {
        guard name == "fixture.read", arguments.isEmpty, callCount < maximumCalls,
              let runID = context.runID, let sessionID = context.providerSessionID,
              let generation = Int(exactly: context.projectGeneration.rawValue) else {
            throw AutonomyError.invalidRequest("feedback fixture tool effect duplicated or unbound")
        }
        callCount += 1
        let scope = DevelopmentObservationScope(projectID: context.projectID.description,
            projectGeneration: generation, runID: runID.description, sessionID: sessionID,
            clientID: context.clientID.rawValue)
        self.scope = scope
        if callCount == 1 {
            let now = Date()
            let event = try fixture.record(.violation, observationID: UUID(), occurredAt: now, scope: scope)
            guard try fixture.notices.queue(event, now: now) != nil else {
                throw AutonomyError.invalidRequest("feedback fixture failed to queue its source-owned notice")
            }
        }
        return returnedResult
    }
}

private struct ToolFeedbackNoticeRunFixture {
    let repository: ProjectControlPlaneRepository
    let stepper: ManagedProjectRunStepExecutor
    let intent: RunSideEffectIntent
    let pending: AutonomousRunRecord
    let context: ToolInvocationContext
    let lease: RunLease
    let notices: StjornarvaldPolicyNoticeRepository
    let executor: ToolFeedbackNoticeExecutor
}

private func withToolFeedbackNoticeFixture(provider: any ManagedModelProvider,
    callCount: Int = 1, result: ToolResult = ToolFeedbackNoticeExecutor.result,
    budget: any ManagedRunBudgetEvaluating = NoManagedRunBudgetEvaluator(),
    body: (ToolFeedbackNoticeRunFixture) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("stj-managed-feedback-notice-\(UUID().uuidString)", isDirectory: true)
        let repository = try ProjectControlPlaneRepository(
            databaseURL: root.appendingPathComponent("control.sqlite3")
        )
        var ownedLease: RunLease?
        do {
            let projectRoot = root.appendingPathComponent("project", isDirectory: true)
            try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
            let projectID = ProjectID()
            _ = try await repository.registerProjectUnchecked(
                projectID: projectID, displayName: "Policy Context Fixture", canonicalRoot: projectRoot
            )
            let run = try await repository.createAutonomousRun(AutonomousRunRequest(
                projectID: projectID,
                projectGeneration: .initial,
                mission: "Read the fixture, then request completion on the immediate feedback",
                providerID: provider.providerID,
                adapterID: "notice-adapter",
                modelKey: "notice-model",
                specification: AutonomousRunSpecification(
                    allowedTools: ["fixture.read"], completionGates: ["tests"]
                ),
                authorizationScope: ToolAuthorizationScope(
                    canonicalRoots: [projectRoot], allowedTools: ["fixture.read"], networkAllowed: false,
                    maximumInlineOutputBytes: 64 * 1_024
                )
            ))
            let noticeFixture = try NoticeFixture()
            defer { noticeFixture.cleanup() }
            let toolExecutor = ToolFeedbackNoticeExecutor(fixture: noticeFixture, maximumCalls: callCount, result: result)
            let context = StjornarvaldCodingAgentPolicyReporter(repository: noticeFixture.notices)
            let broker = ToolInvocationBroker(
                repository: repository,
                executor: toolExecutor,
                classifier: StaticToolReplayClassifier(classifications: ["fixture.read": .readOnly])
            )
            let stepper = try ManagedProjectRunStepExecutor(
                repository: repository,
                providerResolver: { _ in provider },
                toolDefinitionResolver: { _ in [] },
                broker: broker,
                budget: budget,
                policyContext: context
            )
            let lease = try await repository.acquireRunLease(runID: run.runID, ownerID: "notice-test")
            ownedLease = lease
            var running = run
            for state in [AutonomousRunState.validating, .ready, .starting, .running] {
                running = try await repository.transitionAutonomousRun(
                    runID: running.runID,
                    lease: lease,
                    transition: AutonomousRunTransition(
                        expectedState: running.state,
                        expectedRevision: running.revision,
                        nextState: state,
                        eventType: "notice_test_\(state.rawValue)",
                        eventSummary: "Advance managed notice fixture"
                    )
                )
            }
            let preparedIntent = try await stepper.prepareNextStep(for: running)
            let intent = try XCTUnwrap(preparedIntent)
            let pending = try await repository.persistRunSideEffectIntent(
                runID: running.runID,
                lease: lease,
                expectedRevision: running.revision,
                intent: intent
            )
            let invocationContext = ToolInvocationContext(
                projectID: pending.projectID,
                projectGeneration: pending.projectGeneration,
                clientID: ClientID("notice-test"),
                runID: pending.runID,
                authorizationScope: ToolAuthorizationScope(
                    canonicalRoots: [projectRoot], allowedTools: ["fixture.read"], networkAllowed: false,
                    maximumInlineOutputBytes: 64 * 1_024
                )
            )
            let fixture = ToolFeedbackNoticeRunFixture(repository: repository, stepper: stepper, intent: intent,
                pending: pending, context: invocationContext, lease: lease, notices: noticeFixture.notices, executor: toolExecutor)
            try await body(fixture)
            _ = try await repository.releaseRunLease(lease)
            ownedLease = nil
            await repository.close()
            try FileManager.default.removeItem(at: root)
        } catch {
            if let ownedLease { _ = try? await repository.releaseRunLease(ownedLease) }
            await repository.close()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
}

private struct FeedbackBeforeTurnRolloverBudget: ManagedRunBudgetEvaluating {
    func evaluateBeforeProviderTurn(run: AutonomousRunRecord, sessionID: String,
        capabilities: ProviderCapabilities, serializedInputBytes: Int) async throws -> ContextBudgetAction { .normal }
    func evaluateBeforeProviderTurn(run: AutonomousRunRecord, sessionID: String,
        capabilities: ProviderCapabilities, accounting: ManagedBudgetInputAccounting) async throws -> ContextBudgetAction {
        accounting.inputAlreadyRetained ? .rollover : .normal
    }
    func observeProviderTurn(_ turn: ProviderTurn, run: AutonomousRunRecord, sessionID: String,
        capabilities: ProviderCapabilities) async throws -> ContextBudgetAction { .normal }
    func observeToolResult(serializedBytes: Int, providerResponseID: String, run: AutonomousRunRecord,
        sessionID: String, capabilities: ProviderCapabilities) async throws -> ContextBudgetAction { .normal }
    func observeProviderOverflow(run: AutonomousRunRecord, sessionID: String,
        capabilities: ProviderCapabilities) async throws -> ContextBudgetAction { .emergency }
}

private actor OrdinaryNoticeBodyCapTransport: LMStudioManagedTransportRequestPreflighting {
    struct Snapshot: Sendable {
        let rootCalls: Int
        let feedbackCalls: Int
        let rejectedNoticePreflights: Int
        let baseBodyBytes: Int?
        let noticeBodyBytes: Int?
        let maximumRequestBytes: Int?
        let feedbackInput: [LMStudioResponseInput]
    }
    private var rootCalls = 0
    private var feedbackCalls = 0
    private var rejectedNoticePreflights = 0
    private var baseBodyBytes: Int?
    private var noticeBodyBytes: Int?
    private var maximumRequestBytes: Int?
    private var feedbackInput: [LMStudioResponseInput] = []
    private var receipts: [String: LMStudioResponseTurn] = [:]
    func probe() async throws -> LMStudioProviderCapabilities {
        .init(modelKey: "notice-model", loadedInstanceID: "notice-instance",
            contextLength: 32_768, maximumContextLength: 65_536, parallelism: 1, flashAttention: true,
            trainedForToolUse: true, streamingVerified: true, functionToolContractVerified: true,
            usageReportingVerified: true, capabilityFingerprintSHA256: String(repeating: "a", count: 64),
            contractProbeResponseID: "ordinary-notice-probe")
    }
    func preflightRoot(_ request: LMStudioRootRequest) async throws -> ProviderRequestPreflight {
        try await SourceBootstrapFixtureWire.root(request)
    }
    func preflightContinuation(_ request: LMStudioContinuationRequest) async throws -> ProviderRequestPreflight {
        var base = request
        base.input = [request.input[0]]
        let normal = try await SourceBootstrapFixtureWire.continuation(base)
        baseBodyBytes = normal.bodyByteCount
        maximumRequestBytes = max(1_024, normal.bodyByteCount + 32)
        if request.input.count == 2 {
            noticeBodyBytes = try await SourceBootstrapFixtureWire.continuation(request).bodyByteCount
        }
        do {
            return try await SourceBootstrapFixtureWire.continuation(request,
                maximumRequestBytes: try XCTUnwrap(maximumRequestBytes))
        } catch {
            if request.input.count == 2 { rejectedNoticePreflights += 1 }
            throw error
        }
    }
    func createRoot(_ request: LMStudioRootRequest) async throws -> LMStudioResponseTurn {
        _ = try await preflightRoot(request)
        rootCalls += 1
        let turn = LMStudioResponseTurn(responseID: "notice-feedback-root", previousResponseID: nil,
            model: "notice-model", status: "completed", assistantText: "",
            functionCalls: [.init(itemID: "ordinary-notice-read", callID: "notice-feedback-read",
                name: "fixture.read", arguments: "{}")],
            usage: .init(inputTokens: 0, outputTokens: 0, totalTokens: 0), usageWasReported: false)
        receipts[request.idempotencyKey] = turn
        return turn
    }
    func continueSession(_ request: LMStudioContinuationRequest) async throws -> LMStudioResponseTurn {
        _ = try await preflightContinuation(request)
        feedbackCalls += 1
        feedbackInput = request.input
        let turn = LMStudioResponseTurn(responseID: "notice-feedback-final", previousResponseID: request.previousResponseID,
            model: "notice-model", status: "completed",
            assistantText: "{\"forge_run_status\":\"completion_requested\",\"summary\":\"NOTICE_FEEDBACK_SEEN\"}",
            functionCalls: [], usage: .init(inputTokens: 0, outputTokens: 0, totalTokens: 0),
            usageWasReported: false)
        receipts[request.idempotencyKey] = turn
        return turn
    }
    func receipt(forIdempotencyKey key: String) async -> LMStudioResponseTurn? { receipts[key] }
    func cancel(operationID: String) async {}
    func snapshot() -> Snapshot {
        .init(rootCalls: rootCalls, feedbackCalls: feedbackCalls, rejectedNoticePreflights: rejectedNoticePreflights,
            baseBodyBytes: baseBodyBytes, noticeBodyBytes: noticeBodyBytes,
            maximumRequestBytes: maximumRequestBytes, feedbackInput: feedbackInput)
    }
}

private struct OrdinaryNoticeLegacyTransport: LMStudioManagedTransporting {
    let base: OrdinaryNoticeBodyCapTransport
    func probe() async throws -> LMStudioProviderCapabilities { try await base.probe() }
    func createRoot(_ request: LMStudioRootRequest) async throws -> LMStudioResponseTurn { try await base.createRoot(request) }
    func continueSession(_ request: LMStudioContinuationRequest) async throws -> LMStudioResponseTurn { try await base.continueSession(request) }
    func receipt(forIdempotencyKey key: String) async -> LMStudioResponseTurn? { await base.receipt(forIdempotencyKey: key) }
    func cancel(operationID: String) async { await base.cancel(operationID: operationID) }
}
