import Foundation
import XCTest
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

    func testNoticeTextIsBoundedAndRedactsSecrets() throws {
        let fixture = try NoticeFixture(summary: "api_key=super-secret-value")
        defer { fixture.cleanup() }
        let event = try fixture.record(.violation, observationID: UUID(), occurredAt: Date())
        let notice = try XCTUnwrap(try fixture.notices.queue(event))
        XCTAssertFalse(notice.summary.contains("super-secret-value"))
        let text = try XCTUnwrap(StjornarvaldPolicyNoticeFormatter.interactivePresentation(
            notices: Array(repeating: notice, count: 100), maximumBytes: 1_024
        ))
        XCTAssertLessThanOrEqual(text.utf8.count, 1_024)
        XCTAssertTrue(text.contains("Development continues"))
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
