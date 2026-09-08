import XCTest
#if SWIFT_PACKAGE
import ForgeNativeSessionHostPlugin
#endif
@testable import ForgeConductorCore

final class NativeSourcePressureDecisionTests: XCTestCase, @unchecked Sendable {
    func testContinuationSeparatesActualUsageFromProspectiveInputAndKeepsCompatibility() async throws {
        let f = try await MeasurementFixture.make(priorUsage: usage(input: 1_000, output: 200, total: 50_000), priorBytes: 90_000)
        let admitted = try admission(NativeSourceBudgetEvaluator.providerDecision(prepared: f.prepared,
            preflight: f.preflight, capabilities: f.capabilities, policySelection: f.selection, binding: f.binding()))
        let legacy = try NativeSourceBudgetEvaluator.providerApproval(prepared: f.prepared, preflight: f.preflight,
            capabilities: f.capabilities, policySelection: f.selection)
        let addition = try ContextBudgetMath.estimateTokens(serializedBytes: XCTUnwrap(f.preflight.serializedInputByteCount),
            policy: ContextBudgetPolicy())
        XCTAssertEqual(admitted.retainedInputTokens, 1_200 + addition)
        XCTAssertEqual(admitted.accounting.rawProviderUsage, f.prepared.priorUsage)
        XCTAssertEqual(admitted.retainedInputTokens, legacy.retainedInputTokens)
        XCTAssertEqual(admitted.ceilings, legacy.ceilings)
        XCTAssertEqual(admitted.action, .normal)
    }

    func testProviderProjectionAtThresholdAndBeyondCapacityRetainsHonestActualUsage() async throws {
        let probe = try await MeasurementFixture.make(priorUsage: usage(input: 1, output: 0, total: 1))
        let configuration = try PersistedManagedRunBudgetEvaluator.configuration(capabilities: probe.capabilities, selection: probe.selection)
        let ceilings = try NativeSourceBudgetEvaluator.effectiveCeilings(current: configuration,
            selection: probe.selection, limits: probe.preflight.limits, frozen: nil)
        let added = try ContextBudgetMath.estimateTokens(serializedBytes: XCTUnwrap(probe.preflight.serializedInputByteCount), policy: configuration.policy)
        let reserves = try ceilings.reserves.fixedTotal()
        let boundary = Int(ceil(Double(ceilings.effectiveContextTokens) * ceilings.rolloverRatio))
        for target in [boundary - 1, boundary, ceilings.effectiveContextTokens + 100] {
            let actual = try usage(input: target - reserves - added - 7, output: 7, total: 1_000_000)
            let f = try await MeasurementFixture.make(priorUsage: actual)
            let decision = NativeSourceBudgetEvaluator.providerDecision(prepared: f.prepared, preflight: f.preflight,
                capabilities: f.capabilities, policySelection: f.selection, binding: f.binding())
            if target < boundary {
                XCTAssertEqual(try admission(decision).action, .checkpoint)
            } else {
                let pressure = try pressure(decision)
                XCTAssertEqual(pressure.reason, .projectedInputContext)
                XCTAssertEqual(pressure.observation.fields.actual.rawProviderUsage, actual)
                XCTAssertEqual(pressure.observation.fields.actual.retainedInputTokens, actual.inputTokens + actual.outputTokens)
                XCTAssertEqual(try pressure.observation.projectedTotalTokens, target)
                XCTAssertEqual(pressure.observation.fields.prospective?.projectedRetainedInputTokens,
                    actual.inputTokens + actual.outputTokens + added)
                XCTAssertEqual(pressure.action, target > ceilings.effectiveContextTokens ? .emergency : .rollover)
            }
        }
    }

    func testAcceptedAssistantOnlyResultUsesWholeHistoryWhenUsageMissingAndPreservesExactRawUsage() async throws {
        for observed in [nil, try usage(input: 5, output: 2, total: 7, source: .serializedEstimate),
                         try usage(input: 120_000, output: 300, total: 1_000_000)] {
            let f = try await MeasurementFixture.make(root: true)
            let context = try f.accepted(usage: observed, retainedBytes: 300_000)
            let decision = NativeSourceBudgetEvaluator.acceptedDecision(context: context, policySelection: f.selection)
            let measured: NativeSourceBudgetObservation
            switch decision {
            case .admitted(let value): measured = value
            case .pressure(let value): measured = value.observation
            case .blocked(let failure): XCTFail("Unexpected blocker \(failure.code)"); return
            }
            XCTAssertNil(measured.fields.prospective)
            XCTAssertEqual(measured.fields.actual.retainedSerializedBytes, 300_000)
            XCTAssertEqual(measured.fields.actual.rawProviderUsage, observed)
            XCTAssertEqual(measured.binding.admittedCallsInStage, 0)
            if observed?.source == .providerExact {
                XCTAssertEqual(measured.fields.actual.retainedInputTokens, 120_300)
                XCTAssertEqual(measured.fields.actual.source, .providerExact)
                XCTAssertEqual(measured.fields.actual.confidence, 1)
            } else {
                XCTAssertEqual(measured.fields.actual.retainedInputTokens, 125_000)
                XCTAssertEqual(measured.fields.actual.source, .serializedEstimate)
                XCTAssertEqual(measured.fields.actual.confidence, ContextBudgetSupervisor.serializedEstimateConfidence)
            }
        }
    }

    func testObservedOverflowIsUnknownNumericUsageAndCannotBeAnOrdinaryApproval() async throws {
        let raw = try usage(input: 10, output: 1, total: 11, source: .providerOverflow)
        let f = try await MeasurementFixture.make(root: true)
        let context = try f.accepted(usage: raw, retainedBytes: 20_000)
        let result = try pressure(NativeSourceBudgetEvaluator.acceptedDecision(context: context, policySelection: f.selection))
        XCTAssertEqual(result.reason, .observedContextOverflow)
        XCTAssertEqual(result.action, .emergency)
        XCTAssertNil(result.observation.fields.actual.retainedInputTokens)
        XCTAssertNil(try result.observation.observedTotalTokens)
        XCTAssertEqual(result.observation.fields.actual.rawProviderUsage, raw)
        XCTAssertEqual(result.observation.fields.actual.confidence, raw.confidence)
        let next = try await MeasurementFixture.make(priorUsage: raw)
        XCTAssertEqual(try pressure(NativeSourceBudgetEvaluator.providerDecision(prepared: next.prepared,
            preflight: next.preflight, capabilities: next.capabilities, policySelection: next.selection,
            binding: next.binding())).reason, .observedContextOverflow)
    }

    func testQuotaCountsOriginalReadsAndPriorAdmittedCallsWithoutChargingAnAnswer() async throws {
        let f = try await MeasurementFixture.make(priorUsage: usage(input: 100, output: 20, total: 120))
        let full = f.binding(sourceReads: 24, priorCalls: 40)
        _ = try admission(NativeSourceBudgetEvaluator.providerDecision(prepared: f.prepared, preflight: f.preflight,
            capabilities: f.capabilities, policySelection: f.selection, binding: full))
        XCTAssertEqual(blocker(NativeSourceBudgetEvaluator.providerDecision(prepared: f.prepared, preflight: f.preflight,
            capabilities: f.capabilities, policySelection: f.selection, binding: f.binding(sourceReads: 25, priorCalls: 40))), .toolQuotaExceeded)
        let tighter = try f.selection(policy: .init(tools: .init(callsPerTurn: 2, callsPerSession: 4, callsPerRun: 8)))
        XCTAssertEqual(blocker(NativeSourceBudgetEvaluator.providerDecision(prepared: f.prepared, preflight: f.preflight,
            capabilities: f.capabilities, policySelection: tighter, binding: f.binding(sourceReads: 2, priorCalls: 3))), .toolQuotaExceeded)
    }

    func testInvalidPreflightIdentityPolicyAndUnknownStagesNeverBecomePressure() async throws {
        let f = try await MeasurementFixture.make(priorUsage: usage(input: 130_000, output: 10, total: 130_010))
        let missing = try f.copyPreflight(inputBytes: nil)
        XCTAssertEqual(blocker(NativeSourceBudgetEvaluator.providerDecision(prepared: f.prepared, preflight: missing,
            capabilities: f.capabilities, policySelection: f.selection, binding: f.binding())), .unsupportedProvider)
        let wrongModel = try capabilities(model: "fixture/other-model")
        XCTAssertEqual(blocker(NativeSourceBudgetEvaluator.providerDecision(prepared: f.prepared, preflight: f.preflight,
            capabilities: wrongModel, policySelection: f.selection, binding: f.binding())), .providerIdentityMismatch)
        let wrongProject = try BudgetPolicyState().resolve(.init(kind: .projectOverride,
            projectID: ProjectID().description, projectGeneration: 1))
        XCTAssertEqual(blocker(NativeSourceBudgetEvaluator.providerDecision(prepared: f.prepared, preflight: f.preflight,
            capabilities: f.capabilities, policySelection: wrongProject, binding: f.binding())), .requestIdentityMismatch)
        for state in [NativeSourceProviderStageState.submitted, .outcomeUnknown] {
            let unknown = f.copyPrepared(state: state)
            XCTAssertEqual(blocker(NativeSourceBudgetEvaluator.providerDecision(prepared: unknown, preflight: f.preflight,
                capabilities: f.capabilities, policySelection: f.selection, binding: f.binding())), .stageNotEvaluable)
        }
        let changed = try f.copyPreflight(inputBytes: f.preflight.serializedInputByteCount, fingerprint: String(repeating: "c", count: 64))
        XCTAssertEqual(blocker(NativeSourceBudgetEvaluator.providerDecision(prepared: f.copyPrepared(retained: f.preflight),
            preflight: changed, capabilities: f.capabilities, policySelection: f.selection,
            binding: f.binding())), .configurationChanged)
    }

    func testOriginalOutputAndReserveFloorsAreBlockersInsteadOfPressure() async throws {
        let f = try await MeasurementFixture.make(priorUsage: usage(input: 1_000, output: 200, total: 1_200))
        let current = try PersistedManagedRunBudgetEvaluator.configuration(capabilities: f.capabilities, selection: f.selection)
        let original = try NativeSourceBudgetEvaluator.effectiveCeilings(current: current, selection: f.selection,
            limits: f.preflight.limits, frozen: nil)
        let lowerOutput = NativeSourceBudgetCeilings(effectiveContextTokens: original.effectiveContextTokens,
            maximumOutputTokens: 32, tools: original.tools, reserves: original.reserves,
            checkpointRatio: original.checkpointRatio, rolloverRatio: original.rolloverRatio, emergencyRatio: original.emergencyRatio)
        XCTAssertEqual(blocker(NativeSourceBudgetEvaluator.providerDecision(prepared: f.copyPrepared(frozen: lowerOutput),
            preflight: f.preflight, capabilities: f.capabilities, policySelection: f.selection,
            binding: f.binding())), .originalOutputLimitExceeded)
        let hugeReserves = NativeSourceBudgetCeilings(effectiveContextTokens: original.effectiveContextTokens,
            maximumOutputTokens: original.maximumOutputTokens, tools: original.tools,
            reserves: .init(outputTokens: 64, schemaTokens: original.effectiveContextTokens, handoffTokens: 1, recoveryTokens: 1),
            checkpointRatio: original.checkpointRatio, rolloverRatio: original.rolloverRatio, emergencyRatio: original.emergencyRatio)
        XCTAssertEqual(blocker(NativeSourceBudgetEvaluator.providerDecision(prepared: f.copyPrepared(frozen: hugeReserves),
            preflight: f.preflight, capabilities: f.capabilities, policySelection: f.selection,
            binding: f.binding())), .reserveFloorsCannotFit)
    }

    func testMetadataRoundTripPreservesOverCapacityAndRejectsAlteredOrOversizedValues() async throws {
        let f = try await MeasurementFixture.make(root: true)
        let context = try f.accepted(usage: usage(input: 200_000, output: 1_000, total: 800_000), retainedBytes: 400_000)
        let decision = try pressure(NativeSourceBudgetEvaluator.acceptedDecision(context: context, policySelection: f.selection))
        let bytes = try NativeSourceBudgetMetadata.pressure(decision).canonicalJSON()
        XCTAssertLessThanOrEqual(bytes.count, 32_768)
        XCTAssertEqual(try NativeSourceBudgetMetadata.storedSnapshot(from: bytes).canonicalJSON(), bytes)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        object["unrecognized"] = true
        XCTAssertThrowsError(try NativeSourceBudgetMetadata.storedSnapshot(from: ForgeJSONCanonicalizationV1.data(from: object)))
        XCTAssertThrowsError(try NativeSourceBudgetMetadata.storedSnapshot(from: Data(repeating: 32, count: 32_769)))
        var p = try XCTUnwrap(object["pressure"] as? [String: Any])
        var observation = try XCTUnwrap(p["observation"] as? [String: Any])
        var actual = try XCTUnwrap(observation["actual"] as? [String: Any])
        actual["retainedInputTokens"] = 1
        observation["actual"] = actual; p["observation"] = observation; object["pressure"] = p
        object.removeValue(forKey: "unrecognized")
        XCTAssertThrowsError(try NativeSourceBudgetMetadata.storedSnapshot(from: ForgeJSONCanonicalizationV1.data(from: object)))
        let invalid = f.binding(ordinal: 0)
        XCTAssertThrowsError(try invalid.validated())
        XCTAssertThrowsError(try NativeSourceBudgetMetadata.blocked(.init(binding: invalid,
            code: .invalidMeasurement, observation: nil)).canonicalJSON())
    }

    func testResponseIdentifiersUse1024BytesButToolCallsRemain512Bytes() throws {
        let stage = UUID()
        _ = try NativeSourceAcceptedResultIdentity(stageID: stage, providerRequestID: stage.uuidString.lowercased(),
            providerResponseID: String(repeating: "r", count: 1_024), resultSHA256: sha).validated()
        XCTAssertThrowsError(try NativeSourceAcceptedResultIdentity(stageID: stage, providerRequestID: stage.uuidString.lowercased(),
            providerResponseID: String(repeating: "r", count: 1_025), resultSHA256: sha).validated())
        XCTAssertThrowsError(try NativeSourcePendingCallIdentity(ordinal: 0, providerCallID: String(repeating: "c", count: 513),
            toolName: "fs_read", callSHA256: sha, argumentsSHA256: sha).validated())
    }

    func testRealAcceptedReadKeepsFullCeilingAndSeparatesAccumulatedPressureFromIntrinsicBlocker() async throws {
        let fixture = try await NativeSourceHTTPFixture.create()
        defer { fixture.stop() }
        let lease = try await fixture.enrollAndLease()
        let value = try await fixture.acceptedNativeCall(lease: lease, name: "fs_read", arguments: ["path": fixture.file.path])
        let call = value.resolved
        let binding = try await fixture.app.projectContexts.repository.nativeSourceBudgetBinding(
            stageID: call.reference.stageID, boundary: .beforeToolOutput, pendingCallOrdinal: 0,
            credential: fixture.credential, lease: lease)
        let provider = try MeasurementFixture.provider()
        let input = try NativeSourceBudgetEvaluator.emptyContinuationInput(priorOutputs: [], callID: call.callID)
        let next = try ProviderContinuationRequest(operationID: UUID(), idempotencyKey: UUID().uuidString,
            modelKey: value.preflight.modelKey, previousResponseID: call.responseID, input: input,
            tools: MeasurementFixture.tools())
        let preflight = try await provider.preflightContinuation(next)
        let requirement = try NativeSourceToolOutputRequirement.readCeiling(65_536)
        XCTAssertEqual(requirement.encoding, .canonicalJSONTwofoldV1)
        XCTAssertEqual(requirement.additionalEscapedPayloadBytes, 131_072)
        let current = try fixture.policy()
        let result = try admission(NativeSourceBudgetEvaluator.outputDecision(call: call, priorOutputs: [],
            emptyOutputPreflight: preflight, requirement: requirement, capabilities: capabilities(),
            policySelection: current, binding: binding))
        XCTAssertEqual(result.maximumCanonicalToolResultBytes, 65_536)
        XCTAssertEqual(result.maximumEscapedPayloadBytes, 131_072)
        XCTAssertEqual(result.maximumResultTokens, 4_096)
        let default128K = try capabilities(context: 131_072)
        XCTAssertEqual(try admission(NativeSourceBudgetEvaluator.outputDecision(call: call, priorOutputs: [],
            emptyOutputPreflight: preflight, requirement: requirement, capabilities: default128K,
            policySelection: current, binding: binding)).maximumCanonicalToolResultBytes, 65_536)
        let original = try XCTUnwrap(call.prepared.frozenCeilings)
        let prior = try NativeSourceBudgetEvaluator.retainedInput(priorUsage: call.acceptedUsage,
            priorSerializedBytes: call.retainedContextSerializedBytes,
            incrementalInputBytes: XCTUnwrap(preflight.serializedInputByteCount), fullWireBytes: preflight.bodyByteCount,
            policy: ContextBudgetPolicy())
        let extra = try ContextBudgetMath.estimateTokens(serializedBytes: requirement.additionalEscapedPayloadBytes,
            policy: ContextBudgetPolicy())
        // The unchanged full result fits empty context, but not the actual accepted
        // response plus the next input. No fixture usage or result bytes are edited.
        let capacity = Int(ceil(Double(extra + (try original.reserves.fixedTotal()) + max(1, prior / 2)) / original.rolloverRatio))
        let accumulated = try BudgetPolicyState(globalPolicy: .init(context: .init(mode: .manual, maxContextTokens: capacity)))
            .resolve(current.scope)
        let pressured = try pressure(NativeSourceBudgetEvaluator.outputDecision(call: call, priorOutputs: [],
            emptyOutputPreflight: preflight, requirement: requirement, capabilities: default128K,
            policySelection: accumulated, binding: binding))
        XCTAssertEqual(pressured.reason, .projectedToolResultContext)
        XCTAssertEqual(pressured.observation.fields.actual.rawProviderUsage, call.acceptedUsage)
        XCTAssertEqual(pressured.observation.fields.prospective?.outputRequirement?.maximumFullToolResultBytes, 65_536)
        let tight = try BudgetPolicyState(globalPolicy: .init(context: .init(mode: .manual, maxContextTokens: 32_768)))
            .resolve(current.scope)
        XCTAssertEqual(blocker(NativeSourceBudgetEvaluator.outputDecision(call: call, priorOutputs: [],
            emptyOutputPreflight: preflight, requirement: requirement, capabilities: default128K,
            policySelection: tight, binding: binding)), .fullResultCannotFit)
        XCTAssertEqual(blocker(NativeSourceBudgetEvaluator.outputDecision(call: call, priorOutputs: [],
            emptyOutputPreflight: preflight, requirement: try .readCeiling(32_768), capabilities: default128K,
            policySelection: current, binding: binding)), .invalidMeasurement)
        var bindingObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(binding)) as? [String: Any])
        var pending = try XCTUnwrap(bindingObject["pendingCall"] as? [String: Any])
        pending["argumentsSHA256"] = String(repeating: "c", count: 64)
        bindingObject["pendingCall"] = pending
        let altered = try JSONDecoder().decode(NativeSourceBudgetBinding.self,
            from: ForgeJSONCanonicalizationV1.data(from: bindingObject))
        XCTAssertEqual(blocker(NativeSourceBudgetEvaluator.outputDecision(call: call, priorOutputs: [],
            emptyOutputPreflight: preflight, requirement: requirement, capabilities: default128K,
            policySelection: current, binding: altered)), .requestIdentityMismatch)
        let drained = await fixture.service.shutdown()
        XCTAssertTrue(drained)
    }

    func testRealReadyHandoffNeedsNoUnusedContinuationPreflight() async throws {
        let fixture = try await NativeSourceHTTPFixture.create()
        defer { fixture.stop() }
        let lease = try await fixture.enrollAndLease()
        let value = try await fixture.acceptedNativeCall(lease: lease, name: "session_handoff",
            arguments: ["goal": "Continue exact approved source work", "summary": "Fixture progress", "next_actions": ["Read the approved fixture"]])
        let requirement = NativeSourceToolOutputRequirement(kind: .readyHandoff, encoding: .noContinuationV1,
            maximumFullToolResultBytes: 1_048_576, additionalEscapedPayloadBytes: 0, resultTokenEstimate: nil,
            preparedPacketSHA256: nil, canonicalToolResultSHA256: nil, canonicalPayloadSHA256: nil)
        let binding = try await fixture.app.projectContexts.repository.nativeSourceBudgetBinding(
            stageID: value.reference.stageID, boundary: .beforeToolOutput, pendingCallOrdinal: 0,
            credential: fixture.credential, lease: lease)
        let result = try admission(NativeSourceBudgetEvaluator.outputDecision(call: value.resolved, priorOutputs: [],
            emptyOutputPreflight: nil, requirement: requirement, capabilities: capabilities(context: 512),
            policySelection: fixture.policy(), binding: binding))
        XCTAssertEqual(result.maximumCanonicalToolResultBytes, 1_048_576)
        XCTAssertEqual(result.priorOutputsSHA256, value.resolved.priorOutputsSHA256)
        let drained = await fixture.service.shutdown()
        XCTAssertTrue(drained)
    }

    func testReadyHandoffCannotBypassCurrentQuotaIncludingReadsBeforeEnrollment() async throws {
        let fixture = try await NativeSourceHTTPFixture.create()
        defer { fixture.stop() }
        let session = try fixture.initializeReady(credential: fixture.credential)
        for ordinal in 0..<2 {
            let read = try fixture.call("fs_read", id: "before-enrollment-\(ordinal)",
                arguments: ["path": fixture.file.path], session: session)
            XCTAssertEqual(read["ok"] as? Bool, true)
        }
        let lease = try await fixture.enrollAndLease()
        let value = try await fixture.acceptedNativeCall(lease: lease, name: "session_handoff",
            arguments: ["goal": "Continue exact approved source work", "summary": "Two approved reads completed",
                "next_actions": ["Continue the approved task"]])
        let binding = try await fixture.app.projectContexts.repository.nativeSourceBudgetBinding(
            stageID: value.reference.stageID, boundary: .beforeToolOutput, pendingCallOrdinal: 0,
            credential: fixture.credential, lease: lease)
        XCTAssertEqual(binding.sourceReadCallsBeforeEnrollment, 2)
        XCTAssertEqual(binding.admittedProviderCallsBeforeStage, 0)
        XCTAssertEqual(binding.admittedCallsInStage, 1)
        let requirement = NativeSourceToolOutputRequirement(kind: .readyHandoff, encoding: .noContinuationV1,
            maximumFullToolResultBytes: 1_048_576, additionalEscapedPayloadBytes: 0, resultTokenEstimate: nil,
            preparedPacketSHA256: nil, canonicalToolResultSHA256: nil, canonicalPayloadSHA256: nil)
        let scope = try fixture.policy().scope
        for runLimit in [2, 8] {
            let tighter = try BudgetPolicyState(globalPolicy: .init(tools: .init(callsPerTurn: 1,
                callsPerSession: 2, callsPerRun: runLimit, maxInFlight: 1))).resolve(scope)
            XCTAssertEqual(blocker(NativeSourceBudgetEvaluator.outputDecision(call: value.resolved, priorOutputs: [],
                emptyOutputPreflight: nil, requirement: requirement, capabilities: try capabilities(context: 512),
                policySelection: tighter, binding: binding)), .toolQuotaExceeded,
                "A ready handoff retains its context exemption, but two prior reads plus this admitted call exceed the current quota")
        }
        let equalLimit = try BudgetPolicyState(globalPolicy: .init(tools: .init(callsPerTurn: 1,
            callsPerSession: 3, callsPerRun: 3, maxInFlight: 1))).resolve(scope)
        let admitted = try admission(NativeSourceBudgetEvaluator.outputDecision(call: value.resolved, priorOutputs: [],
            emptyOutputPreflight: nil, requirement: requirement, capabilities: capabilities(context: 512),
            policySelection: equalLimit, binding: binding))
        XCTAssertEqual(admitted.maximumCanonicalToolResultBytes, 1_048_576)
        XCTAssertEqual(admitted.priorOutputsSHA256, binding.completedOutputsSHA256)
        let drained = await fixture.service.shutdown()
        XCTAssertTrue(drained)
    }

    private var sha: String { String(repeating: "a", count: 64) }
    private func usage(input: Int, output: Int, total: Int, source: ProviderUsageSource = .providerExact) throws -> ProviderUsage {
        try .init(capacity: 131_072, inputTokens: input, outputTokens: output, totalTokens: total,
            source: source, confidence: source == .providerExact || source == .tokenizerExact ? 1 : 0.5)
    }
    private func capabilities(context: Int = 262_144, model: String = "fixture/source-model") throws -> ProviderCapabilities {
        try MeasurementFixture.capabilities(context: context, model: model)
    }
    private func admission<T: Sendable>(_ decision: NativeSourceBudgetDecision<T>, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        guard case .admitted(let result) = decision else { XCTFail("Expected positive admission", file: file, line: line); throw NativeSourcePressureModelError.invalidMetadata }
        return result
    }
    private func pressure<T: Sendable>(_ decision: NativeSourceBudgetDecision<T>, file: StaticString = #filePath, line: UInt = #line) throws -> NativeSourcePressureDecision {
        guard case .pressure(let result) = decision else { XCTFail("Expected numerical pressure", file: file, line: line); throw NativeSourcePressureModelError.invalidMetadata }
        return result
    }
    private func blocker<T: Sendable>(_ decision: NativeSourceBudgetDecision<T>, file: StaticString = #filePath, line: UInt = #line) -> NativeSourceBudgetFailureCode? {
        guard case .blocked(let result) = decision else { XCTFail("Expected nonpressure blocker", file: file, line: line); return nil }
        return result.code
    }


}

/// Pure, nondispatching measurement fixtures. The plugin supplies real local
/// preflight bytes; these metadata values confer no CP authority or provider work.
private struct MeasurementFixture {
    let projectID: ProjectID
    let prepared: NativeSourcePreparedTurn
    let preflight: ProviderRequestPreflight
    let capabilities: ProviderCapabilities
    let selection: BudgetPolicySelection
    let previousStageID: UUID
    static let sha = String(repeating: "a", count: 64)

    static func make(root: Bool = false, priorUsage: ProviderUsage? = nil, priorBytes: Int = 0) async throws -> Self {
        let projectID = ProjectID(), stageID = UUID(), previous = UUID()
        let request: NativeSourceProviderRequest
        let preflight: ProviderRequestPreflight
        let provider = try provider()
        if root {
            let value = try ProviderRootRequest(operationID: stageID, idempotencyKey: stageID.uuidString.lowercased(),
                modelKey: "fixture/source-model", input: "Bounded approved source fixture", tools: tools())
            request = .root(value); preflight = try await provider.preflightRoot(value)
        } else {
            let value = try ProviderContinuationRequest(operationID: stageID, idempotencyKey: stageID.uuidString.lowercased(),
                modelKey: "fixture/source-model", previousResponseID: "resp_prior",
                input: Data(#"[{"role":"user","content":"Continue approved work"}]"#.utf8), tools: tools())
            request = .continuation(value); preflight = try await provider.preflightContinuation(value)
        }
        let prepared = NativeSourcePreparedTurn(conversationID: UUID(), taskID: UUID(), stageID: stageID, requestID: UUID(),
            ordinal: root ? 1 : 2, state: .prepared, request: request, intentSHA256: sha,
            deadline: "2026-09-08T20:00:00Z", priorUsage: priorUsage, priorContextSerializedBytes: priorBytes,
            frozenCeilings: nil, retainedPreflight: nil, retainedCapabilities: nil)
        return try .init(projectID: projectID, prepared: prepared, preflight: preflight, capabilities: capabilities(context: 131_072),
            selection: BudgetPolicyState().resolve(.init(kind: .projectOverride, projectID: projectID.description, projectGeneration: 1)),
            previousStageID: previous)
    }
    static func provider() throws -> LMStudioManagedModelProvider {
        LMStudioManagedModelProvider(transport: try LMStudioManagedSessionTransport(configuration: .init(
            baseURL: URL(string: "http://127.0.0.1:1")!, modelKey: "fixture/source-model", maximumOutputTokens: 64)))
    }
    static func tools() throws -> [Data] {
        try MCPNativeTaskSourceProfile.providerToolDefinitions(catalog: .production(toolNames: MCPNativeTaskSourceProfile.sourceToolNames.sorted()))
    }
    static func capabilities(context: Int, model: String = "fixture/source-model") throws -> ProviderCapabilities {
        try .init(providerID: "lmstudio", providerVersion: "fixture-1", modelKey: model,
            providerInstanceID: "fixture-source-instance", contextLength: context, maximumContextLength: 262_144,
            statefulResponses: true, streaming: true, customTools: true, mcp: false, structuredOutput: true,
            usageReporting: true, idempotencyLookup: true, capabilityFingerprintSHA256: sha)
    }
    func selection(policy: BudgetPolicy) throws -> BudgetPolicySelection {
        try BudgetPolicyState(globalPolicy: policy).resolve(selection.scope)
    }
    func binding(sourceReads: Int = 0, priorCalls: Int = 0, ordinal: Int? = nil,
        boundary: NativeSourceBudgetBoundary = .beforeProviderPost,
        observed: NativeSourceAcceptedResultIdentity? = nil) -> NativeSourceBudgetBinding {
        let prior: NativeSourceAcceptedResultIdentity?
        switch prepared.request {
        case .root: prior = nil
        case .continuation: prior = .init(stageID: previousStageID, providerRequestID: previousStageID.uuidString.lowercased(),
            providerResponseID: "resp_prior", resultSHA256: Self.sha)
        }
        return .init(projectID: projectID, projectGeneration: .init(1), taskID: prepared.taskID,
            capabilityID: prepared.taskID, capabilityEpoch: 1, conversationID: prepared.conversationID,
            conversationRevision: 1, stageID: prepared.stageID, stageOrdinal: ordinal ?? prepared.ordinal,
            logicalRequestID: prepared.requestID, assignmentSHA256: Self.sha, logicalInputSHA256: Self.sha,
            intentSHA256: prepared.intentSHA256, sourceInferenceDeadline: prepared.deadline,
            stageState: boundary == .beforeProviderPost ? .prepared : .accepted, boundary: boundary,
            observedResult: observed ?? prior, completedOutputCount: 0, completedOutputsSHA256: JSONSupport.sha256Hex(Data("[]".utf8)),
            pendingCall: nil, sourceReadCallsBeforeEnrollment: sourceReads, admittedProviderCallsBeforeStage: priorCalls,
            admittedCallsInStage: 0, sourceMaximumCalls: 64)
    }
    func copyPrepared(state: NativeSourceProviderStageState? = nil, frozen: NativeSourceBudgetCeilings? = nil,
                      retained: ProviderRequestPreflight? = nil) -> NativeSourcePreparedTurn {
        .init(conversationID: prepared.conversationID, taskID: prepared.taskID, stageID: prepared.stageID,
            requestID: prepared.requestID, ordinal: prepared.ordinal, state: state ?? prepared.state,
            request: prepared.request, intentSHA256: prepared.intentSHA256, deadline: prepared.deadline,
            priorUsage: prepared.priorUsage, priorContextSerializedBytes: prepared.priorContextSerializedBytes,
            frozenCeilings: frozen, retainedPreflight: retained, retainedCapabilities: retained == nil ? nil : capabilities)
    }
    func copyPreflight(inputBytes: Int?, fingerprint: String? = nil) throws -> ProviderRequestPreflight {
        try .init(kind: preflight.kind, modelKey: preflight.modelKey, configurationRevision: preflight.configurationRevision,
            configurationFingerprintSHA256: fingerprint ?? preflight.configurationFingerprintSHA256, limits: preflight.limits,
            bodySHA256: preflight.bodySHA256, bodyByteCount: preflight.bodyByteCount, serializedInputByteCount: inputBytes)
    }
    func accepted(usage: ProviderUsage?, retainedBytes: Int) throws -> NativeSourceAcceptedBudgetContext {
        let turn = try ProviderTurn(requestID: prepared.stageID.uuidString.lowercased(), responseID: "resp_current",
            providerID: capabilities.providerID, providerVersion: capabilities.providerVersion, modelKey: capabilities.modelKey,
            providerInstanceID: capabilities.providerInstanceID, messages: [], toolCalls: [], usage: usage,
            completed: true, finishReason: .stop)
        let result = try NativeSourceJournalCoding.encode(NativeSourceJournalCoding.turn(turn), maximum: NativeSourceJournalCoding.maximumTurnBytes)
        let binding = binding(boundary: .acceptedProviderResponse, observed: .init(stageID: prepared.stageID,
            providerRequestID: turn.requestID, providerResponseID: turn.responseID, resultSHA256: JSONSupport.sha256Hex(result)))
        return .init(binding: binding, accepted: .init(prepared: copyPrepared(state: .accepted, retained: preflight), turn: turn, calls: []),
            retainedContextSerializedBytes: retainedBytes)
    }
}
