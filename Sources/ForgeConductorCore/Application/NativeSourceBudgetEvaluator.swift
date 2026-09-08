import Foundation

/// Pure pre-effect accounting for a source conversation, which has no managed RunID.
/// Authority and durable compare-and-swap validation remain in the control plane.
enum NativeSourceBudgetEvaluator {
    static func providerApproval(prepared: NativeSourcePreparedTurn,
        preflight: ProviderRequestPreflight, capabilities: ProviderCapabilities,
        policySelection: BudgetPolicySelection) throws -> NativeSourceProviderBudgetApproval {
        let current = try configuration(capabilities: capabilities, selection: policySelection)
        let ceilings = try effectiveCeilings(current: current, selection: policySelection,
            limits: preflight.limits, frozen: prepared.frozenCeilings)
        let inputBytes: Int
        let tools: [Data]
        switch prepared.request {
        case .root(let request):
            guard preflight.kind == .root, request.modelKey == preflight.modelKey,
                  request.operationID == prepared.stageID else { throw NativeSourceConversationError.integrityFailure }
            inputBytes = preflight.bodyByteCount; tools = request.tools
        case .continuation(let request):
            guard preflight.kind == .continuation, request.modelKey == preflight.modelKey,
                  request.operationID == prepared.stageID else { throw NativeSourceConversationError.integrityFailure }
            guard let serializedInputBytes = preflight.serializedInputByteCount else {
                throw NativeSourceConversationError.unsupportedProvider
            }
            inputBytes = serializedInputBytes; tools = request.tools
        }
        guard preflight.modelKey == capabilities.modelKey,
              preflight.bodyByteCount <= min(524_288, preflight.limits.maximumRequestBytes) else {
            throw NativeSourceConversationError.budgetExceeded
        }
        let retained = try retainedInput(priorUsage: prepared.priorUsage,
            priorSerializedBytes: prepared.priorContextSerializedBytes,
            incrementalInputBytes: inputBytes, fullWireBytes: preflight.bodyByteCount,
            policy: current.policy)
        let reserves = try ceilings.reserves.fixedTotal()
        let accounting = try ContextBudgetAccounting(version: "admitted_total_v2",
            cut: "retained_input_before_next_operation", retainedInputTokens: retained,
            futureReserveTokens: reserves, rawProviderUsage: prepared.priorUsage,
            resolvedPolicy: current.resolvedPolicy,
            toolSchemaSHA256: schemaFingerprint(tools), pendingInputID: prepared.intentSHA256)
        let action = try action(retainedInputTokens: retained, ceilings: ceilings,
            overflow: prepared.priorUsage?.source == .providerOverflow)
        return try NativeSourceProviderBudgetApproval(policySelection: policySelection,
            effectiveContextTokens: ceilings.effectiveContextTokens, retainedInputTokens: retained,
            futureReserveTokens: reserves, limits: preflight.limits, ceilings: ceilings, accounting: accounting,
            source: .serializedEstimate, confidence: ContextBudgetSupervisor.serializedEstimateConfidence,
            action: action)
    }

    static func outputBudget(call: ResolvedNativeSourceProviderCall,
        priorOutputs: [NativeSourceProviderCallOutput], emptyOutputPreflight: ProviderRequestPreflight?,
        capabilities: ProviderCapabilities, policySelection: BudgetPolicySelection) throws -> NativeSourceProviderOutputBudget {
        guard let retained = call.prepared.retainedPreflight else {
            throw NativeSourceConversationError.integrityFailure
        }
        // No continuation follows a ready handoff. Its independently bounded MCP receipt
        // remains available even if the unused next provider envelope has no headroom.
        if call.toolName == "session_handoff" {
            return try .init(conversationID: call.reference.conversationID, stageID: call.reference.stageID,
                callOrdinal: call.reference.ordinal,
                configurationFingerprintSHA256: retained.configurationFingerprintSHA256,
                priorOutputsSHA256: call.priorOutputsSHA256,
                maximumCanonicalToolResultBytes: 1_048_576, maximumEscapedPayloadBytes: 524_288,
                maximumResultTokens: 1_048_576)
        }
        guard let emptyOutputPreflight, priorOutputs.count == call.reference.ordinal, priorOutputs.count < 16,
              emptyOutputPreflight.kind == .continuation,
              emptyOutputPreflight.modelKey == capabilities.modelKey,
              retained.configurationFingerprintSHA256 == emptyOutputPreflight.configurationFingerprintSHA256 else {
            throw NativeSourceConversationError.integrityFailure
        }
        for (ordinal, output) in priorOutputs.enumerated() {
            guard output.reference.conversationID == call.reference.conversationID,
                  output.reference.stageID == call.reference.stageID,
                  output.reference.ordinal == ordinal, output.responseID == call.responseID,
                  !output.readyHandoffCommitted else { throw NativeSourceConversationError.integrityFailure }
        }
        let current = try configuration(capabilities: capabilities, selection: policySelection)
        let ceilings = try effectiveCeilings(current: current, selection: policySelection,
            limits: emptyOutputPreflight.limits, frozen: call.prepared.frozenCeilings)
        guard let serializedInputBytes = emptyOutputPreflight.serializedInputByteCount else {
            throw NativeSourceConversationError.unsupportedProvider
        }
        let input = try retainedInput(priorUsage: call.acceptedUsage,
            priorSerializedBytes: call.retainedContextSerializedBytes,
            incrementalInputBytes: serializedInputBytes, fullWireBytes: emptyOutputPreflight.bodyByteCount,
            policy: current.policy)
        let total = try add(input, ceilings.reserves.fixedTotal())
        // The next dispatch must still fall strictly below the rollover boundary.
        let rollover = try ratioTokens(ceilings.effectiveContextTokens, ceilings.rolloverRatio)
        guard call.acceptedUsage?.source != .providerOverflow, total < rollover else {
            throw NativeSourceConversationError.budgetExceeded
        }
        let remainingTokens = rollover - total - 1
        let tokenBytes = floor(Double(remainingTokens) * current.policy.serializedBytesPerToken
            / current.policy.estimateSafetyMultiplier)
        guard tokenBytes.isFinite, let boundedTokenBytes = Int(exactly: tokenBytes) else {
            throw NativeSourceConversationError.budgetExceeded
        }
        let wireLimit = min(524_288, emptyOutputPreflight.limits.maximumRequestBytes)
        let escapedHeadroom = min(wireLimit - emptyOutputPreflight.bodyByteCount, boundedTokenBytes)
        let resultTokens = min(ceilings.tools.maxRetainedResultTokens, remainingTokens)
        let bytesForResultTokens = floor(Double(resultTokens) * current.policy.serializedBytesPerToken
            / current.policy.estimateSafetyMultiplier)
        guard let resultTokenBytes = Int(exactly: bytesForResultTokens) else {
            throw NativeSourceConversationError.budgetExceeded
        }
        let resultCap = min(call.toolName == "fs_read" ? 65_536 : 1_048_576,
            ceilings.tools.maxResultBytes, escapedHeadroom / 6,
            call.toolName == "fs_read" ? Int.max : resultTokenBytes)
        return try .init(conversationID: call.reference.conversationID, stageID: call.reference.stageID,
            callOrdinal: call.reference.ordinal,
            configurationFingerprintSHA256: emptyOutputPreflight.configurationFingerprintSHA256,
            priorOutputsSHA256: call.priorOutputsSHA256,
            maximumCanonicalToolResultBytes: resultCap, maximumEscapedPayloadBytes: escapedHeadroom,
            maximumResultTokens: resultTokens)
    }

    static func emptyContinuationInput(priorOutputs: [NativeSourceProviderCallOutput], callID: String) throws -> Data {
        var input: [[String: Any]] = priorOutputs.map {
            ["type": "function_call_output", "call_id": $0.callID,
             "output": String(decoding: $0.canonicalPayloadJSON, as: UTF8.self)]
        }
        // A nonempty placeholder passes the existing transport contract. It is never dispatched.
        // Its byte remains charged while the full actual payload is reserved additionally.
        input.append(["type": "function_call_output", "call_id": callID, "output": "0"])
        return try ForgeJSONCanonicalizationV1.data(from: input)
    }

    static func effectiveCeilings(current: ContextBudgetConfiguration, selection: BudgetPolicySelection,
        limits: ProviderExecutionLimits, frozen: NativeSourceBudgetCeilings?) throws -> NativeSourceBudgetCeilings {
        _ = try frozen?.validated()
        let selected = try selection.policy.validated()
        guard let resolved = current.resolvedPolicy else { throw NativeSourceConversationError.integrityFailure }
        let capacity = min(current.capacity.capacity, frozen?.effectiveContextTokens ?? Int.max)
        guard limits.maximumOutputTokens <= (frozen?.maximumOutputTokens ?? Int.max),
              limits.maximumOutputTokens <= capacity else { throw NativeSourceConversationError.budgetExceeded }
        let original = frozen?.reserves
        let reserves = ContextBudgetReserves(
            outputTokens: max(limits.maximumOutputTokens, current.reserves.outputTokens, original?.outputTokens ?? 0),
            schemaTokens: max(current.reserves.schemaTokens, original?.schemaTokens ?? 0),
            handoffTokens: max(current.reserves.handoffTokens, original?.handoffTokens ?? 0),
            recoveryTokens: max(current.reserves.recoveryTokens, original?.recoveryTokens ?? 0),
            futureToolTokens: max(current.reserves.futureToolTokens, original?.futureToolTokens ?? 0),
            safetyTokens: max(current.reserves.safetyTokens, original?.safetyTokens ?? 0))
        let tools = selected.tools, originalTools = frozen?.tools
        let boundedTools = try BudgetToolPolicy(
            callsPerTurn: min(tools.callsPerTurn, originalTools?.callsPerTurn ?? Int.max),
            callsPerSession: min(tools.callsPerSession, originalTools?.callsPerSession ?? Int.max),
            callsPerRun: min(tools.callsPerRun, originalTools?.callsPerRun ?? Int.max),
            maxInFlight: min(tools.maxInFlight, originalTools?.maxInFlight ?? Int.max),
            maxResultBytes: min(tools.maxResultBytes, originalTools?.maxResultBytes ?? Int.max),
            maxRetainedResultTokens: min(tools.maxRetainedResultTokens, originalTools?.maxRetainedResultTokens ?? Int.max),
            recoveryCallsPerRollover: min(tools.recoveryCallsPerRollover, originalTools?.recoveryCallsPerRollover ?? Int.max)).validated()
        guard try reserves.fixedTotal() < capacity else { throw NativeSourceConversationError.budgetExceeded }
        return try NativeSourceBudgetCeilings(effectiveContextTokens: capacity,
            maximumOutputTokens: min(limits.maximumOutputTokens, frozen?.maximumOutputTokens ?? Int.max),
            tools: boundedTools, reserves: reserves,
            checkpointRatio: min(resolved.effectiveCheckpointRatio, frozen?.checkpointRatio ?? 1),
            rolloverRatio: min(resolved.effectiveRolloverRatio, frozen?.rolloverRatio ?? 1),
            emergencyRatio: min(resolved.effectiveEmergencyRatio, frozen?.emergencyRatio ?? 1)).validated()
    }

    static func retainedInput(priorUsage: ProviderUsage?, priorSerializedBytes: Int,
        incrementalInputBytes: Int, fullWireBytes: Int, policy: ContextBudgetPolicy) throws -> Int {
        guard priorSerializedBytes >= 0, incrementalInputBytes >= 0, fullWireBytes > 0 else {
            throw NativeSourceConversationError.integrityFailure
        }
        if let usage = priorUsage, usage.source == .providerExact || usage.source == .tokenizerExact {
            return try add(PersistedManagedRunBudgetEvaluator.retainedTokensAfterResponse(usage),
                ContextBudgetMath.estimateTokens(serializedBytes: incrementalInputBytes, policy: policy))
        }
        let fallback = try ContextBudgetMath.estimateTokens(
            serializedBytes: add(priorSerializedBytes, fullWireBytes), policy: policy)
        guard let usage = priorUsage else { return fallback }
        return max(fallback, try add(PersistedManagedRunBudgetEvaluator.retainedTokensAfterResponse(usage),
            ContextBudgetMath.estimateTokens(serializedBytes: incrementalInputBytes, policy: policy)))
    }

    private static func configuration(capabilities: ProviderCapabilities,
        selection: BudgetPolicySelection) throws -> ContextBudgetConfiguration {
        guard capabilities.statefulResponses, capabilities.customTools else {
            throw NativeSourceConversationError.unsupportedProvider
        }
        return try PersistedManagedRunBudgetEvaluator.configuration(capabilities: capabilities, selection: selection)
    }

    private static func action(retainedInputTokens: Int, ceilings: NativeSourceBudgetCeilings,
        overflow: Bool) throws -> ContextBudgetAction {
        let total = try add(retainedInputTokens, ceilings.reserves.fixedTotal())
        if overflow { return .emergency }
        if total >= (try ratioTokens(ceilings.effectiveContextTokens, ceilings.emergencyRatio)) { return .emergency }
        if total >= (try ratioTokens(ceilings.effectiveContextTokens, ceilings.rolloverRatio)) { return .rollover }
        if total >= (try ratioTokens(ceilings.effectiveContextTokens, ceilings.checkpointRatio)) { return .checkpoint }
        return .normal
    }

    private static func schemaFingerprint(_ tools: [Data]) throws -> String {
        let objects = try tools.map { try JSONSerialization.jsonObject(with: $0) }
        return JSONSupport.sha256Hex(try ForgeJSONCanonicalizationV1.data(from: objects))
    }
    private static func add(_ lhs: Int, _ rhs: Int) throws -> Int {
        let sum = lhs.addingReportingOverflow(rhs)
        guard lhs >= 0, rhs >= 0, !sum.overflow else { throw NativeSourceConversationError.budgetExceeded }
        return sum.partialValue
    }
    private static func ratioTokens(_ capacity: Int, _ ratio: Double) throws -> Int {
        let value = ceil(Double(capacity) * ratio)
        guard value.isFinite, let count = Int(exactly: value) else { throw NativeSourceConversationError.budgetExceeded }
        return count
    }
}
