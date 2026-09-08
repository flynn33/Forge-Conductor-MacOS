import XCTest
#if SWIFT_PACKAGE
import ForgeNativeSessionHostPlugin
#endif
@testable import ForgeConductorCore

final class NativeSourceInheritedBudgetTests: XCTestCase, @unchecked Sendable {
    func testLooserCurrentPolicyPreservesSourceLimitsAndActualSelection() throws {
        let inherited = try inheritance()
        let selection = try selection(context(mode: .auto, capacity: 131_072, output: 0,
            handoff: 0, recovery: 0, future: 0, safety: 0, checkpoint: 0.85, rollover: 0.90, emergency: 0.99))
        let configuration = try PersistedManagedRunBudgetEvaluator.configuration(
            capabilities: capabilities(131_072), selection: selection, inheritance: inherited)
        let resolved = try XCTUnwrap(configuration.resolvedPolicy)
        XCTAssertEqual(configuration.capacity.capacity, 32_768)
        XCTAssertEqual(configuration.capacity.activeInstanceID, "inherited-budget-instance")
        XCTAssertEqual(configuration.capacity.maximumContextLength, 262_144)
        XCTAssertEqual(resolved.verifiedLoadedContextTokens, 131_072)
        XCTAssertEqual(resolved.selection, selection)
        XCTAssertEqual(resolved.requestedContextTokens, 131_072)
        XCTAssertEqual(resolved.inheritedSourceBudget, inherited)
        XCTAssertEqual(configuration.reserves, inherited.reserves)
        XCTAssertEqual(resolved.effectiveCheckpointRatio, 0.60)
        XCTAssertEqual(resolved.effectiveRolloverRatio, 0.70)
        XCTAssertEqual(resolved.effectiveEmergencyRatio, 0.80)
    }

    func testTighterCurrentPolicyUsesMinimumCeilingsAndIndividualReserveFloors() throws {
        let inherited = try inheritance()
        let selection = try selection(context(capacity: 16_384, output: 2_048,
            handoff: 128, recovery: 512, future: 64, safety: 256,
            checkpoint: 0.50, rollover: 0.65, emergency: 0.75))
        let configuration = try PersistedManagedRunBudgetEvaluator.configuration(
            capabilities: capabilities(65_536), selection: selection, inheritance: inherited)
        let resolved = try XCTUnwrap(configuration.resolvedPolicy)
        XCTAssertEqual(configuration.capacity.capacity, 16_384)
        XCTAssertEqual(resolved.verifiedLoadedContextTokens, 65_536)
        XCTAssertEqual(resolved.selection, selection)
        XCTAssertEqual(configuration.reserves, .init(outputTokens: 2_048, schemaTokens: 32,
            handoffTokens: 512, recoveryTokens: 512, futureToolTokens: 128, safetyTokens: 256))
        XCTAssertEqual(resolved.effectiveCheckpointRatio, 0.50)
        XCTAssertEqual(resolved.effectiveRolloverRatio, 0.65)
        XCTAssertEqual(resolved.effectiveEmergencyRatio, 0.75)
        let smallerLoaded = try PersistedManagedRunBudgetEvaluator.configuration(
            capabilities: capabilities(8_192), selection: selection, inheritance: inherited)
        XCTAssertEqual(smallerLoaded.capacity.capacity, 8_192)
        XCTAssertEqual(smallerLoaded.resolvedPolicy?.verifiedLoadedContextTokens, 8_192)
        XCTAssertThrowsError(try PersistedManagedRunBudgetEvaluator.configuration(
            capabilities: capabilities(2_048), selection: selection, inheritance: inherited))
    }

    func testInheritanceRequiresRealSelectionAndPreservesStricterQualificationRatios() throws {
        let inherited = try inheritance()
        XCTAssertThrowsError(try PersistedManagedRunBudgetEvaluator.configuration(
            capabilities: capabilities(65_536), inheritance: inherited)) {
            XCTAssertEqual($0 as? ContextBudgetError, .invalidPolicy)
        }
        let selection = try selection(context())
        let override = ContextBudgetPolicy(checkpointFraction: 0.90, rolloverFraction: 0.80, emergencyFraction: 0.30)
        let configuration = try PersistedManagedRunBudgetEvaluator.configuration(
            capabilities: capabilities(65_536), policyOverride: override,
            selection: selection, inheritance: inherited)
        let resolved = try XCTUnwrap(configuration.resolvedPolicy)
        XCTAssertEqual(resolved.effectiveCheckpointRatio, 0.10, accuracy: 0.000_001)
        XCTAssertEqual(resolved.effectiveRolloverRatio, 0.20, accuracy: 0.000_001)
        XCTAssertEqual(resolved.effectiveEmergencyRatio, 0.70, accuracy: 0.000_001)
        XCTAssertEqual(resolved.selection, selection)
    }

    func testInheritedProvenanceAndConfigurationSurviveCodableRestart() throws {
        let carryover = try carryover()
        let inherited = try InheritedSourceContextBudget(carryover: carryover)
        let configuration = try PersistedManagedRunBudgetEvaluator.configuration(
            capabilities: capabilities(65_536), selection: selection(context()), inheritance: inherited)
        let data = try JSONEncoder().encode(configuration)
        let reopened = try JSONDecoder().decode(ContextBudgetConfiguration.self, from: data).validated()
        XCTAssertEqual(reopened, configuration)
        let provenance = try XCTUnwrap(reopened.resolvedPolicy?.inheritedSourceBudget)
        XCTAssertEqual(provenance.runID, carryover.runID)
        XCTAssertEqual(provenance.taskID, carryover.taskID)
        XCTAssertEqual(provenance.conversationID, carryover.conversationID)
        XCTAssertEqual(provenance.acceptanceSHA256, carryover.acceptanceSHA256)
        XCTAssertEqual(provenance.journalSHA256, carryover.journalSHA256)
        XCTAssertEqual(provenance.maximumOutputTokens, carryover.ceilings.maximumOutputTokens)
        let object = try jsonObject(provenance)
        XCTAssertNil(object["observedInputTokens"])
        XCTAssertNil(object["observedOutputTokens"], "Cumulative source usage is not successor retained context")
    }

    func testLegacyNilInheritanceKeepsExistingWireShapeAndResolution() throws {
        let configuration = try PersistedManagedRunBudgetEvaluator.configuration(
            capabilities: capabilities(65_536), selection: selection(context(capacity: 16_384)))
        let resolved = try XCTUnwrap(configuration.resolvedPolicy)
        let object = try jsonObject(resolved)
        XCTAssertEqual(Set(object.keys), ["selection", "verifiedLoadedContextTokens", "effectiveContextTokens",
            "thresholdContract", "effectiveCheckpointRatio", "effectiveRolloverRatio", "effectiveEmergencyRatio"])
        let legacy = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let reopened = try JSONDecoder().decode(ResolvedContextBudgetPolicy.self, from: legacy)
        XCTAssertEqual(reopened, resolved)
        XCTAssertNil(reopened.inheritedSourceBudget)
        XCTAssertEqual(reopened.effectiveContextTokens, 16_384)
        XCTAssertEqual(reopened.verifiedLoadedContextTokens, 65_536)
    }

    func testMalformedInheritedBoundsAndRelaxedStoredResolutionAreRejected() throws {
        let inherited = try inheritance()
        let original = try jsonObject(inherited)
        let invalidFields: [(String, Any)] = [
            ("version", "unknown"), ("acceptanceSHA256", String(repeating: "A", count: 64)),
            ("journalSHA256", "short"), ("taskID", "not-a-uuid"),
            ("effectiveContextTokens", 0), ("effectiveContextTokens", Int.max),
            ("maximumOutputTokens", 0), ("maximumOutputTokens", 32_769),
            ("checkpointRatio", 0), ("rolloverRatio", 0.60), ("emergencyRatio", 1.1)
        ]
        for (key, value) in invalidFields {
            var object = original; object[key] = value
            XCTAssertThrowsError(try JSONDecoder().decode(InheritedSourceContextBudget.self,
                from: JSONSerialization.data(withJSONObject: object)), key)
        }
        var invalidReserves = original
        var reserveObject = try XCTUnwrap(original["reserves"] as? [String: Any])
        reserveObject["output_tokens"] = Int.max
        invalidReserves["reserves"] = reserveObject
        XCTAssertThrowsError(try JSONDecoder().decode(InheritedSourceContextBudget.self,
            from: JSONSerialization.data(withJSONObject: invalidReserves)))

        let configuration = try PersistedManagedRunBudgetEvaluator.configuration(
            capabilities: capabilities(65_536), selection: selection(context()), inheritance: inherited)
        let resolved = try XCTUnwrap(configuration.resolvedPolicy)
        for (key, value) in [("effectiveContextTokens", 65_536.0), ("effectiveCheckpointRatio", 0.80)] {
            var object = try jsonObject(resolved); object[key] = value
            XCTAssertThrowsError(try JSONDecoder().decode(ResolvedContextBudgetPolicy.self,
                from: JSONSerialization.data(withJSONObject: object)), key)
        }
        let underReserved = ContextBudgetConfiguration(capacity: configuration.capacity,
            reserves: .init(outputTokens: 0, schemaTokens: 0, handoffTokens: 0, recoveryTokens: 0),
            policy: configuration.policy, resolvedPolicy: resolved)
        XCTAssertThrowsError(try underReserved.validated()) {
            XCTAssertEqual($0 as? ContextBudgetError, .invalidReserve)
        }
        let foreignIdentity = ContextBudgetIdentity(runID: RunID(), projectID: ProjectID(),
            projectGeneration: .initial, sessionID: "foreign-source-budget-session")
        let foreignState = PersistedContextBudgetState(identity: foreignIdentity,
            configuration: configuration, updatedAt: "2026-09-08T12:00:00Z")
        XCTAssertThrowsError(try foreignState.validated()) {
            XCTAssertEqual($0 as? ContextBudgetError, .invalidPersistedState)
        }
    }

    func testActualPreflightCapIsEnforcedAndOriginalOutputFloorSurvivesNilObservation() async throws {
        let inherited = try inheritance()
        let selection = try selection(context())
        let preflight = try await preflight(outputTokens: 64)
        let bounded = try PersistedManagedRunBudgetEvaluator.configuration(capabilities: capabilities(65_536),
            selection: selection, inheritance: inherited, providerPreflight: preflight)
        XCTAssertEqual(bounded.reserves.outputTokens, 1_024)
        let oversized = try await self.preflight(outputTokens: 65)
        XCTAssertThrowsError(try PersistedManagedRunBudgetEvaluator.configuration(capabilities: capabilities(65_536),
            selection: selection, inheritance: inherited, providerPreflight: oversized)) {
            XCTAssertEqual($0 as? ContextBudgetError, .insufficientUsableCapacity)
        }
        let wrongModel = try ProviderRequestPreflight(kind: preflight.kind, modelKey: "another-model",
            configurationRevision: preflight.configurationRevision,
            configurationFingerprintSHA256: preflight.configurationFingerprintSHA256, limits: preflight.limits,
            bodySHA256: preflight.bodySHA256, bodyByteCount: preflight.bodyByteCount,
            serializedInputByteCount: preflight.serializedInputByteCount)
        XCTAssertThrowsError(try PersistedManagedRunBudgetEvaluator.configuration(capabilities: capabilities(65_536),
            selection: selection, inheritance: inherited, providerPreflight: wrongModel)) {
            XCTAssertEqual($0 as? ContextBudgetError, .configurationMismatch)
        }
        let transportFloor = try InheritedSourceContextBudget(carryover: carryover(maximumOutputTokens: 2_048))
        let later = try PersistedManagedRunBudgetEvaluator.configuration(capabilities: capabilities(65_536),
            selection: self.selection(context(output: 0)), inheritance: transportFloor)
        XCTAssertEqual(later.reserves.outputTokens, 2_048, "A nil observation preflight cannot drop the inherited transport reserve")
    }

    func testActualSourceReceiptIsReappliedToCachedAndRestartedSupervisor() async throws {
        let fixture = try await NativeSourceHTTPFixture.create()
        defer { fixture.stop() }
        let originalContext = context(capacity: 32_768, output: 1_024, handoff: 512,
            recovery: 256, future: 128, safety: 64, checkpoint: 0.60, rollover: 0.70, emergency: 0.80)
        try update(fixture.app.config, context: originalContext)
        let sourceLease = try await fixture.enrollAndLease()
        let sourceCall = try await fixture.acceptedNativeCall(lease: sourceLease,
            name: "session_handoff", arguments: ["goal": "Carry the original source budget into the managed successor"])
        let output = try await fixture.service.submitNativeCall(credential: fixture.credential,
            reference: sourceCall.reference, lease: sourceLease,
            outputBudget: sourceCall.outputBudget(maximumBytes: 1_048_576, escapedBytes: 1),
            cancellation: ToolCallCancellation(timeoutSeconds: 5))
        XCTAssertTrue(output.readyHandoffCommitted)
        let delivery = try XCTUnwrap(fixture.app.store.pendingContinuityHandoffs().first)
        let repository = fixture.app.projectContexts.repository
        let acceptance = try await repository.acceptContinuityIngress(source: delivery.handoff,
            operationID: delivery.operationID, policySelection: fixture.policy())
        let carryoverValue = try await repository.nativeSourceBudgetCarryover(runID: acceptance.runID)
        let carryover = try XCTUnwrap(carryoverValue)
        XCTAssertEqual(carryover.admittedProviderCalls, 1)
        XCTAssertGreaterThan(carryover.observedInputTokens + carryover.observedOutputTokens, 200)
        let lease = try await repository.acquireRunLease(runID: acceptance.runID, ownerID: "inherited-budget-fixture")
        let envelope = try ContinuitySourceBootstrapEnvelope(acceptance: acceptance, bootstrapNonce: UUID())
        let grant = try await repository.issueContinuityBootstrapGrant(envelope: envelope, candidateID: UUID(), lease: lease)
        try await repository.reserveProviderSession(.init(sessionID: grant.sessionID, runID: acceptance.runID,
            projectID: fixture.projectID, projectGeneration: .initial, providerID: "lmstudio",
            adapterID: "forge.native-session-host", modelKey: "fixture/source-model", handoffID: envelope.handoffID,
            operationID: acceptance.operationID, idempotencyKey: "inherited-budget-candidate",
            bootstrapNonceSHA256: JSONSupport.sha256Hex(envelope.bootstrapNonce.uuidString.lowercased()),
            handoffSHA256: envelope.envelopeSHA256, status: .candidate, accepted: false), lease: lease, bootstrapGrant: grant)
        let runValue = try await repository.autonomousRun(acceptance.runID)
        let run = try XCTUnwrap(runValue)
        let identity = ContextBudgetIdentity(runID: run.runID, projectID: run.projectID,
            projectGeneration: run.projectGeneration, sessionID: grant.sessionID)
        let config = fixture.app.config
        let evaluator = PersistedManagedRunBudgetEvaluator(repository: repository,
            policyResolver: { try config.budgetPolicySelection(scope: $0) })
        let preflight = try await preflight(outputTokens: 64)
        let inputBytes = try XCTUnwrap(preflight.serializedInputByteCount)
        let accounting = ManagedBudgetInputAccounting(inputBytes: inputBytes,
            toolSchemaBytes: preflight.bodyByteCount - inputBytes,
            toolSchemaSHA256: String(repeating: "d", count: 64), pendingInputID: preflight.bodySHA256,
            inputAlreadyRetained: false, providerPreflight: preflight)
        let expectedInput = try ContextBudgetMath.estimateTokens(serializedBytes: preflight.bodyByteCount,
            policy: ContextBudgetPolicy())
        try update(config, context: context(mode: .auto, capacity: 131_072, output: 0,
            handoff: 0, recovery: 0, future: 0, safety: 0))
        _ = try await evaluator.evaluateBeforeProviderTurn(run: run, sessionID: grant.sessionID,
            capabilities: capabilities(131_072), accounting: accounting)
        let firstValue = try await repository.contextBudgetState(identity: identity)
        let first = try XCTUnwrap(firstValue)
        XCTAssertEqual(first.configuration.capacity.capacity, 32_768)
        XCTAssertEqual(first.latestObservation?.used, expectedInput, "Use only actual successor input, never cumulative source usage")
        XCTAssertGreaterThan(carryover.observedInputTokens + carryover.observedOutputTokens, expectedInput)
        XCTAssertEqual(first.configuration.resolvedPolicy?.inheritedSourceBudget,
            try InheritedSourceContextBudget(carryover: carryover))

        try update(config, context: context(capacity: 16_384, output: 2_048,
            handoff: 64, recovery: 64, future: 64, safety: 32,
            checkpoint: 0.50, rollover: 0.60, emergency: 0.70))
        _ = try await evaluator.evaluateBeforeProviderTurn(run: run, sessionID: grant.sessionID,
            capabilities: capabilities(131_072), accounting: accounting)
        let tightenedValue = try await repository.contextBudgetState(identity: identity)
        let tightened = try XCTUnwrap(tightenedValue)
        XCTAssertEqual(tightened.configuration.capacity.capacity, 16_384)
        XCTAssertEqual(tightened.configuration.reserves.outputTokens, 2_048)
        XCTAssertEqual(tightened.configuration.reserves.handoffTokens, 512)
        XCTAssertEqual(tightened.latestObservation?.used, expectedInput)
        XCTAssertEqual(tightened.configuration.resolvedPolicy?.selection, try fixture.policy())

        let drained = await fixture.service.shutdown()
        XCTAssertTrue(drained)
        let reopened = try fixture.reopened()
        defer { reopened.stop() }
        let restoredConfig = reopened.app.config
        let restoredRepository = reopened.app.projectContexts.repository
        try update(restoredConfig, context: context(mode: .auto, capacity: 131_072, output: 0,
            handoff: 0, recovery: 0, future: 0, safety: 0))
        let restarted = PersistedManagedRunBudgetEvaluator(repository: restoredRepository,
            policyResolver: { try restoredConfig.budgetPolicySelection(scope: $0) })
        _ = try await restarted.evaluateBeforeProviderTurn(run: run, sessionID: grant.sessionID,
            capabilities: capabilities(65_536), accounting: accounting)
        let restartedValue = try await restoredRepository.contextBudgetState(identity: identity)
        let state = try XCTUnwrap(restartedValue)
        XCTAssertEqual(state.configuration.capacity.capacity, 32_768)
        XCTAssertEqual(state.configuration.resolvedPolicy?.verifiedLoadedContextTokens, 65_536)
        XCTAssertEqual(state.configuration.reserves, carryover.ceilings.reserves)
        XCTAssertEqual(state.configuration.resolvedPolicy?.inheritedSourceBudget, first.configuration.resolvedPolicy?.inheritedSourceBudget)
        XCTAssertEqual(state.latestObservation?.used, expectedInput)
        let missingPreflight = ManagedBudgetInputAccounting(inputBytes: inputBytes,
            toolSchemaBytes: preflight.bodyByteCount - inputBytes,
            toolSchemaSHA256: String(repeating: "d", count: 64), pendingInputID: preflight.bodySHA256,
            inputAlreadyRetained: false)
        do {
            _ = try await restarted.evaluateBeforeProviderTurn(run: run, sessionID: grant.sessionID,
                capabilities: capabilities(65_536), accounting: missingPreflight)
            XCTFail("A source successor admitted a provider boundary without actual transport preflight")
        } catch { XCTAssertEqual(error as? ContextBudgetError, .invalidPolicy) }
        _ = try await restarted.observeToolResult(serializedBytes: 0, providerResponseID: "inherited-budget-observation",
            run: run, sessionID: grant.sessionID, capabilities: capabilities(65_536))
        let observedValue = try await restoredRepository.contextBudgetState(identity: identity)
        let observed = try XCTUnwrap(observedValue)
        XCTAssertGreaterThanOrEqual(observed.configuration.reserves.outputTokens, carryover.ceilings.maximumOutputTokens)
        XCTAssertEqual(observed.latestObservation?.used, expectedInput)
        let missingResolver = PersistedManagedRunBudgetEvaluator(repository: restoredRepository)
        do {
            _ = try await missingResolver.evaluateBeforeProviderTurn(run: run, sessionID: grant.sessionID,
                capabilities: capabilities(65_536), accounting: accounting)
            XCTFail("A source successor silently invented a current policy selection")
        } catch { XCTAssertEqual(error as? ContextBudgetError, .invalidPolicy) }
        let finalDrain = await reopened.service.shutdown()
        XCTAssertTrue(finalDrain)
    }

    private func context(mode: BudgetContextMode = .manual, capacity: Int = 65_536,
        output: Int = 1_024, handoff: Int = 512, recovery: Int = 256, future: Int = 128, safety: Int = 64,
        checkpoint: Double = 0.80, rollover: Double = 0.90, emergency: Double = 0.95) -> BudgetContextPolicy {
        .init(mode: mode, maxContextTokens: capacity, responseReserveTokens: output,
            futureToolReserveTokens: future, handoffReserveTokens: handoff, recoveryReserveTokens: recovery,
            safetyReserveTokens: safety, checkpointRatio: checkpoint, rolloverRatio: rollover, emergencyRatio: emergency)
    }

    private func selection(_ context: BudgetContextPolicy) throws -> BudgetPolicySelection {
        try BudgetPolicyState(globalRevision: 3, globalPolicy: .init(context: context)).resolve(.globalDefault)
    }

    private func update(_ store: ConfigStore, context: BudgetContextPolicy) throws {
        let selected = try store.budgetPolicySelection(scope: .globalDefault)
        _ = try store.updateBudgetPolicy(.init(scope: .globalDefault, expectedRevision: selected.revision,
            expectedGlobalRevision: selected.globalRevision, operation: .set,
            policy: .init(context: context, automaticHandoffEnabled: true)))
    }

    private func capabilities(_ tokens: Int) throws -> ProviderCapabilities {
        try .init(providerID: "lmstudio", providerVersion: "fixture-1", modelKey: "fixture/source-model",
            providerInstanceID: "inherited-budget-instance", contextLength: tokens, maximumContextLength: 262_144,
            statefulResponses: true, streaming: true, customTools: true, mcp: false, structuredOutput: true,
            usageReporting: true, idempotencyLookup: true, capabilityFingerprintSHA256: String(repeating: "a", count: 64))
    }

    private func carryover(maximumOutputTokens: Int = 64) throws -> NativeSourceBudgetCarryover {
        .init(conversationID: UUID(), taskID: UUID(), runID: RunID(), acceptanceSHA256: String(repeating: "a", count: 64),
            ceilings: .init(effectiveContextTokens: 32_768, maximumOutputTokens: maximumOutputTokens, tools: BudgetToolPolicy(),
                reserves: .init(outputTokens: 1_024, schemaTokens: 32, handoffTokens: 512,
                    recoveryTokens: 256, futureToolTokens: 128, safetyTokens: 64),
                checkpointRatio: 0.60, rolloverRatio: 0.70, emergencyRatio: 0.80),
            priorSourceReadCallsAtEnrollment: 2, providerStageCount: 4, admittedProviderCalls: 5,
            observedInputTokens: 50_000, observedOutputTokens: 2_000, exactUsageStageCount: 4,
            journalSHA256: String(repeating: "b", count: 64))
    }

    private func inheritance() throws -> InheritedSourceContextBudget {
        try .init(carryover: carryover())
    }

    private func preflight(outputTokens: Int) async throws -> ProviderRequestPreflight {
        let provider = LMStudioManagedModelProvider(transport: try LMStudioManagedSessionTransport(configuration: .init(
            baseURL: URL(string: "http://127.0.0.1:1")!, modelKey: "fixture/source-model", maximumOutputTokens: outputTokens)))
        return try await provider.preflightRoot(.init(operationID: UUID(), idempotencyKey: UUID().uuidString,
            modelKey: "fixture/source-model", input: String(repeating: "x", count: 240), tools: []))
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }
}
