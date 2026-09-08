import XCTest
#if SWIFT_PACKAGE
import ForgeNativeSessionHostPlugin
#endif
@testable import ForgeConductorCore

final class NativeSourceBudgetEvaluatorTests: XCTestCase, @unchecked Sendable {
    func testMissingUsageRetainsWholeHistoryAndEstimatedUsageCannotLowerIt() throws {
        let policy = ContextBudgetPolicy()
        let missing = try NativeSourceBudgetEvaluator.retainedInput(priorUsage: nil,
            priorSerializedBytes: 12_000, incrementalInputBytes: 90, fullWireBytes: 3_000, policy: policy)
        XCTAssertEqual(missing, 6_250, "The default 3 bytes/token and 1.25 multiplier include the full 15,000-byte history")
        let lowerEstimate = try usage(input: 10, output: 5, total: 15, source: .serializedEstimate)
        XCTAssertEqual(try NativeSourceBudgetEvaluator.retainedInput(priorUsage: lowerEstimate,
            priorSerializedBytes: 12_000, incrementalInputBytes: 90, fullWireBytes: 3_000, policy: policy), missing)
        let higherEstimate = try usage(input: 8_000, output: 500, total: 8_500, source: .serializedEstimate)
        XCTAssertEqual(try NativeSourceBudgetEvaluator.retainedInput(priorUsage: higherEstimate,
            priorSerializedBytes: 12_000, incrementalInputBytes: 240, fullWireBytes: 3_000, policy: policy), 8_600)
        XCTAssertThrowsError(try NativeSourceBudgetEvaluator.retainedInput(priorUsage: nil,
            priorSerializedBytes: Int.max, incrementalInputBytes: 1, fullWireBytes: 1, policy: policy))
    }

    func testExactInputAndOutputIgnoreAmbiguousTotalAndDoNotRechargeUnchangedSchemas() throws {
        for source in [ProviderUsageSource.providerExact, .tokenizerExact] {
            let previous = try usage(input: 1_000, output: 200, total: 10_000, source: source)
            let retained = try NativeSourceBudgetEvaluator.retainedInput(priorUsage: previous,
                priorSerializedBytes: 20_000, incrementalInputBytes: 240, fullWireBytes: 12_000,
                policy: ContextBudgetPolicy())
            XCTAssertEqual(retained, 1_300, "Only observed input+output and the exact new input count toward this boundary")
        }
    }

    func testContinuationApprovalUsesExactTransportInputBytesAndLabelsEstimate() async throws {
        let provider = try provider()
        let tools = try sourceTools()
        let request = try ProviderContinuationRequest(operationID: UUID(), idempotencyKey: UUID().uuidString,
            modelKey: "fixture/source-model", previousResponseID: "resp_prior",
            input: ForgeJSONCanonicalizationV1.data(from: [["type": "function_call_output", "call_id": "call_original",
                "output": String(repeating: "/", count: 240)]]), tools: tools)
        let preflight = try await provider.preflightContinuation(request)
        let inputBytes = try XCTUnwrap(preflight.serializedInputByteCount)
        XCTAssertGreaterThan(inputBytes, request.input.count, "Actual encoder slash escaping must survive accounting")
        XCTAssertGreaterThan(preflight.bodyByteCount, inputBytes)
        let prior = try usage(input: 1_200, output: 400, total: 50_000)
        let prepared = makePrepared(request: .continuation(request), priorUsage: prior, priorBytes: 100_000)
        let result = try NativeSourceBudgetEvaluator.providerApproval(prepared: prepared, preflight: preflight,
            capabilities: capabilities(), policySelection: selection())
        let added = try ContextBudgetMath.estimateTokens(serializedBytes: inputBytes, policy: ContextBudgetPolicy())
        XCTAssertEqual(result.retainedInputTokens, 1_600 + added)
        XCTAssertLessThan(result.retainedInputTokens,
            1_600 + (try ContextBudgetMath.estimateTokens(serializedBytes: preflight.bodyByteCount, policy: ContextBudgetPolicy())))
        XCTAssertEqual(result.source, .serializedEstimate)
        XCTAssertEqual(result.confidence, ContextBudgetSupervisor.serializedEstimateConfidence)
        XCTAssertEqual(result.accounting.rawProviderUsage, prior)
        XCTAssertEqual(result.accounting.cut, "retained_input_before_next_operation")
        XCTAssertEqual(result.accounting.pendingInputID, prepared.intentSHA256)
        XCTAssertEqual(result.accounting.toolSchemaSHA256, JSONSupport.sha256Hex(
            try ForgeJSONCanonicalizationV1.data(from: tools.map { try JSONSerialization.jsonObject(with: $0) })))
        XCTAssertEqual(result.accounting.admittedTotalTokens, result.retainedInputTokens + result.futureReserveTokens)
        XCTAssertEqual(result.action, .normal)
    }

    func testContinuationRejectsMissingOrZeroSerializedInputWhileRootUsesWholeWire() async throws {
        let provider = try provider()
        let root = try ProviderRootRequest(operationID: UUID(), idempotencyKey: UUID().uuidString,
            modelKey: "fixture/source-model", input: "Bounded original source request", tools: sourceTools())
        let rootPreflight = try await provider.preflightRoot(root)
        let rootWithoutInput = try copy(rootPreflight, serializedInputByteCount: nil)
        let rootResult = try NativeSourceBudgetEvaluator.providerApproval(prepared: makePrepared(request: .root(root)),
            preflight: rootWithoutInput, capabilities: capabilities(), policySelection: selection())
        XCTAssertEqual(rootResult.retainedInputTokens,
            try ContextBudgetMath.estimateTokens(serializedBytes: rootPreflight.bodyByteCount, policy: ContextBudgetPolicy()))
        let next = try ProviderContinuationRequest(operationID: UUID(), idempotencyKey: UUID().uuidString,
            modelKey: root.modelKey, previousResponseID: "resp_prior", input: Data(#"[{"role":"user","content":"Continue the approved source task"}]"#.utf8), tools: root.tools)
        let preflight = try await provider.preflightContinuation(next)
        let missing = try copy(preflight, serializedInputByteCount: nil)
        XCTAssertThrowsError(try NativeSourceBudgetEvaluator.providerApproval(prepared: makePrepared(request: .continuation(next)),
            preflight: missing, capabilities: capabilities(), policySelection: selection())) {
            XCTAssertEqual($0 as? NativeSourceConversationError, .unsupportedProvider)
        }
        XCTAssertThrowsError(try copy(preflight, serializedInputByteCount: 0))
        XCTAssertThrowsError(try copy(preflight, serializedInputByteCount: preflight.bodyByteCount + 1))
    }

    func testOriginalCeilingsAndReserveFloorsCannotLoosenWithLaterPolicy() throws {
        let original = try selection(.init(context: .init(mode: .manual, maxContextTokens: 65_536,
            responseReserveTokens: 1_024, futureToolReserveTokens: 512, handoffReserveTokens: 1_024,
            recoveryReserveTokens: 256, safetyReserveTokens: 128,
            checkpointRatio: 0.60, rolloverRatio: 0.70, emergencyRatio: 0.80),
            tools: .init(callsPerTurn: 2, callsPerSession: 4, callsPerRun: 8, maxInFlight: 1,
                maxResultBytes: 4_096, maxRetainedResultTokens: 1_024, recoveryCallsPerRollover: 1)))
        let frozen = try ceilings(selection: original, outputTokens: 128)
        let looser = try selection(.init(context: .init(mode: .auto, responseReserveTokens: 0,
            futureToolReserveTokens: 0, handoffReserveTokens: 0, recoveryReserveTokens: 0, safetyReserveTokens: 0,
            checkpointRatio: 0.85, rolloverRatio: 0.90, emergencyRatio: 0.99),
            tools: .init(callsPerTurn: 4, callsPerSession: 16, callsPerRun: 32, maxInFlight: 2,
                maxResultBytes: 65_536, maxRetainedResultTokens: 4_096, recoveryCallsPerRollover: 8)))
        let retained = try ceilings(selection: looser, outputTokens: 128, frozen: frozen)
        XCTAssertEqual(retained, frozen)
        let tighter = try selection(.init(context: .init(mode: .manual, maxContextTokens: 32_768,
            responseReserveTokens: 2_048, futureToolReserveTokens: 256, handoffReserveTokens: 512,
            recoveryReserveTokens: 128, safetyReserveTokens: 64,
            checkpointRatio: 0.50, rolloverRatio: 0.60, emergencyRatio: 0.70),
            tools: .init(callsPerTurn: 1, callsPerSession: 2, callsPerRun: 4, maxInFlight: 1,
                maxResultBytes: 2_048, maxRetainedResultTokens: 512, recoveryCallsPerRollover: 1)))
        let tightened = try ceilings(selection: tighter, outputTokens: 64, frozen: retained)
        XCTAssertEqual(tightened.effectiveContextTokens, 32_768)
        XCTAssertEqual(tightened.maximumOutputTokens, 64)
        XCTAssertEqual(tightened.tools, tighter.policy.tools)
        XCTAssertEqual(tightened.reserves.outputTokens, 2_048)
        XCTAssertEqual(tightened.reserves.handoffTokens, frozen.reserves.handoffTokens)
        XCTAssertEqual(tightened.reserves.recoveryTokens, frozen.reserves.recoveryTokens)
        XCTAssertEqual(tightened.reserves.futureToolTokens, frozen.reserves.futureToolTokens)
        XCTAssertEqual(tightened.reserves.safetyTokens, frozen.reserves.safetyTokens)
        XCTAssertEqual(tightened.checkpointRatio, 0.50)
        XCTAssertEqual(tightened.rolloverRatio, 0.60)
        XCTAssertEqual(tightened.emergencyRatio, 0.70)
        XCTAssertEqual(try ceilings(selection: looser, outputTokens: 64, frozen: tightened), tightened)
    }

    func testActualOutputCapAndOversizedReserveFloorsRejectAdmission() throws {
        let saved = try selection()
        let frozen = try ceilings(selection: saved, outputTokens: 64)
        XCTAssertThrowsError(try ceilings(selection: saved, outputTokens: 65, frozen: frozen)) {
            XCTAssertEqual($0 as? NativeSourceConversationError, .budgetExceeded)
        }
        let small = try PersistedManagedRunBudgetEvaluator.configuration(capabilities: capabilities(context: 1_024), selection: saved)
        XCTAssertThrowsError(try NativeSourceBudgetEvaluator.effectiveCeilings(current: small,
            selection: saved, limits: limits(outputTokens: 2_048), frozen: nil))
        let impossible = NativeSourceBudgetCeilings(effectiveContextTokens: 65_536, maximumOutputTokens: 64,
            tools: frozen.tools, reserves: .init(outputTokens: 64, schemaTokens: 65_536,
                handoffTokens: 1, recoveryTokens: 1), checkpointRatio: 0.60, rolloverRatio: 0.70, emergencyRatio: 0.80)
        XCTAssertThrowsError(try ceilings(selection: saved, outputTokens: 64, frozen: impossible)) {
            XCTAssertEqual($0 as? NativeSourceConversationError, .budgetExceeded)
        }
    }

    func testProviderOverflowForcesEmergencyDespiteSmallSerializedInput() async throws {
        let request = try ProviderContinuationRequest(operationID: UUID(), idempotencyKey: UUID().uuidString,
            modelKey: "fixture/source-model", previousResponseID: "resp_prior", input: Data(#"[{"role":"user","content":"Continue the approved source task"}]"#.utf8), tools: sourceTools())
        let preflight = try await provider().preflightContinuation(request)
        let prior = try usage(input: 100, output: 20, total: 120, source: .providerOverflow)
        let result = try NativeSourceBudgetEvaluator.providerApproval(
            prepared: makePrepared(request: .continuation(request), priorUsage: prior), preflight: preflight,
            capabilities: capabilities(), policySelection: selection())
        XCTAssertEqual(result.action, .emergency)
        XCTAssertEqual(result.accounting.rawProviderUsage?.source, .providerOverflow)
    }

    func testDefaultReadBudgetReservesFullApprovedBytesWithIndependentResultTokenLimit() async throws {
        let fixture = try await NativeSourceHTTPFixture.create()
        defer { fixture.stop() }
        let lease = try await fixture.enrollAndLease()
        let accepted = try await fixture.acceptedNativeCall(lease: lease, name: "fs_read", arguments: ["path": fixture.file.path])
        let input = try NativeSourceBudgetEvaluator.emptyContinuationInput(priorOutputs: [], callID: accepted.resolved.callID)
        let placeholder = try XCTUnwrap((try JSONSerialization.jsonObject(with: input) as? [[String: Any]])?.last)
        XCTAssertEqual(placeholder["output"] as? String, "0", "The reservation uses a valid bounded transport input without relaxing output validation")
        let request = try ProviderContinuationRequest(operationID: UUID(), idempotencyKey: UUID().uuidString,
            modelKey: "fixture/source-model", previousResponseID: accepted.resolved.responseID, input: input, tools: sourceTools())
        let preflight = try await provider().preflightContinuation(request)
        XCTAssertGreaterThan(try XCTUnwrap(preflight.serializedInputByteCount), 0)
        let budget = try NativeSourceBudgetEvaluator.outputBudget(call: accepted.resolved, priorOutputs: [],
            emptyOutputPreflight: preflight, capabilities: capabilities(), policySelection: fixture.policy())
        XCTAssertEqual(budget.maximumCanonicalToolResultBytes, 65_536)
        XCTAssertGreaterThanOrEqual(budget.maximumEscapedPayloadBytes, 2 * 65_536)
        XCTAssertEqual(budget.maximumResultTokens, 4_096)
        let output = try await fixture.service.submitNativeCall(credential: fixture.credential, reference: accepted.reference,
            lease: lease, outputBudget: budget, cancellation: ToolCallCancellation(timeoutSeconds: 5))
        XCTAssertEqual(try JSONSupport.object(from: output.canonicalPayloadJSON)["content"] as? String, "native source marker one")
        let drained = await fixture.service.shutdown()
        XCTAssertTrue(drained)
    }

    func testReadyHandoffNeedsNoUnusedContinuationPreflight() async throws {
        let fixture = try await NativeSourceHTTPFixture.create()
        defer { fixture.stop() }
        let lease = try await fixture.enrollAndLease()
        let accepted = try await fixture.acceptedNativeCall(lease: lease, name: "session_handoff", arguments: ["goal": "Ready source fixture"])
        let budget = try NativeSourceBudgetEvaluator.outputBudget(call: accepted.resolved, priorOutputs: [],
            emptyOutputPreflight: nil, capabilities: capabilities(), policySelection: fixture.policy())
        XCTAssertEqual(budget.maximumCanonicalToolResultBytes, 1_048_576)
        let result = try await fixture.service.submitNativeCall(credential: fixture.credential, reference: accepted.reference,
            lease: lease, outputBudget: budget, cancellation: ToolCallCancellation(timeoutSeconds: 5))
        XCTAssertTrue(result.readyHandoffCommitted)
        let drained = await fixture.service.shutdown()
        XCTAssertTrue(drained)
    }

    private func provider() throws -> LMStudioManagedModelProvider {
        LMStudioManagedModelProvider(transport: try LMStudioManagedSessionTransport(configuration: .init(
            baseURL: URL(string: "http://127.0.0.1:1")!, modelKey: "fixture/source-model", maximumOutputTokens: 64)))
    }
    private func sourceTools() throws -> [Data] {
        try MCPNativeTaskSourceProfile.providerToolDefinitions(catalog: .production(
            toolNames: MCPNativeTaskSourceProfile.sourceToolNames.sorted()))
    }
    private func capabilities(context: Int = 262_144) throws -> ProviderCapabilities {
        try .init(providerID: "lmstudio", providerVersion: "fixture-1", modelKey: "fixture/source-model",
            providerInstanceID: "fixture-source-instance", contextLength: context, maximumContextLength: context,
            statefulResponses: true, streaming: true, customTools: true, mcp: false, structuredOutput: true,
            usageReporting: true, idempotencyLookup: true, capabilityFingerprintSHA256: String(repeating: "a", count: 64))
    }
    private func selection(_ policy: BudgetPolicy = .default) throws -> BudgetPolicySelection {
        try BudgetPolicyState(globalPolicy: policy).resolve(.globalDefault)
    }
    private func usage(input: Int, output: Int, total: Int,
                       source: ProviderUsageSource = .providerExact) throws -> ProviderUsage {
        try .init(capacity: 262_144, inputTokens: input, outputTokens: output, totalTokens: total,
            source: source, confidence: source == .providerExact || source == .tokenizerExact ? 1 : 0.5)
    }
    private func limits(outputTokens: Int = 64) throws -> ProviderExecutionLimits {
        try .init(maximumOutputTokens: outputTokens, maximumRequestBytes: 524_288,
            maximumResponseBytes: 2_097_152, maximumTextBytes: 524_288, maximumToolArgumentBytes: 262_144,
            maximumJSONBytes: 1_048_576, maximumSSELineBytes: 65_536, maximumSSEEventBytes: 262_144,
            connectTimeoutSeconds: 5, firstByteTimeoutSeconds: 15, idleTimeoutSeconds: 30, totalTimeoutSeconds: 120)
    }
    private func ceilings(selection: BudgetPolicySelection, outputTokens: Int,
                          frozen: NativeSourceBudgetCeilings? = nil) throws -> NativeSourceBudgetCeilings {
        let configuration = try PersistedManagedRunBudgetEvaluator.configuration(capabilities: capabilities(), selection: selection)
        return try NativeSourceBudgetEvaluator.effectiveCeilings(current: configuration, selection: selection,
            limits: limits(outputTokens: outputTokens), frozen: frozen)
    }
    private func copy(_ value: ProviderRequestPreflight, serializedInputByteCount: Int?) throws -> ProviderRequestPreflight {
        try .init(kind: value.kind, modelKey: value.modelKey, configurationRevision: value.configurationRevision,
            configurationFingerprintSHA256: value.configurationFingerprintSHA256, limits: value.limits,
            bodySHA256: value.bodySHA256, bodyByteCount: value.bodyByteCount, serializedInputByteCount: serializedInputByteCount)
    }
    private func makePrepared(request: NativeSourceProviderRequest, priorUsage: ProviderUsage? = nil,
                              priorBytes: Int = 0) -> NativeSourcePreparedTurn {
        let stageID: UUID
        switch request { case .root(let value): stageID = value.operationID
        case .continuation(let value): stageID = value.operationID }
        return .init(conversationID: UUID(), taskID: UUID(), stageID: stageID, requestID: UUID(), ordinal: 1,
            state: .prepared, request: request, intentSHA256: String(repeating: "b", count: 64),
            deadline: ISO8601.string(from: Date().addingTimeInterval(30)), priorUsage: priorUsage,
            priorContextSerializedBytes: priorBytes, frozenCeilings: nil, retainedPreflight: nil, retainedCapabilities: nil)
    }
}
