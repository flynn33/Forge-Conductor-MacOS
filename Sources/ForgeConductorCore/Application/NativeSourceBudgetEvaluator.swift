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
            ceilings.tools.maxResultBytes, escapedHeadroom / CanonicalToolResultOutputBounds.maximumStringExpansion,
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

extension NativeSourceBudgetEvaluator {
    /// Pure decisions never turn a generic thrown budget error into handoff authority.
    /// CP independently verifies the supplied read binding before persisting metadata.
    static func providerDecision(prepared: NativeSourcePreparedTurn, preflight: ProviderRequestPreflight,
        capabilities: ProviderCapabilities, policySelection: BudgetPolicySelection,
        binding: NativeSourceBudgetBinding) -> NativeSourceBudgetDecision<NativeSourceProviderBudgetApproval> {
        var observation: NativeSourceBudgetObservation?
        do {
            try match(prepared, binding: binding, boundary: .beforeProviderPost)
            if let retained = prepared.retainedPreflight {
                try demand(retained == preflight, .configurationChanged)
            }
            let inputs = try decisionInputs(preflight: preflight, capabilities: capabilities,
                selection: policySelection, frozen: prepared.frozenCeilings, binding: binding)
            let inputBytes: Int
            let tools: [Data]
            switch prepared.request {
            case .root(let request):
                try demand(preflight.kind == .root && request.operationID == prepared.stageID
                    && request.modelKey == preflight.modelKey && binding.observedResult == nil, .requestIdentityMismatch)
                inputBytes = preflight.bodyByteCount; tools = request.tools
            case .continuation(let request):
                try demand(preflight.kind == .continuation && request.operationID == prepared.stageID
                    && request.modelKey == preflight.modelKey
                    && request.previousResponseID == binding.observedResult?.providerResponseID, .requestIdentityMismatch)
                guard let measured = preflight.serializedInputByteCount else { throw DecisionFailure(.unsupportedProvider) }
                inputBytes = measured; tools = request.tools
            }
            let actual = try observedContext(usage: prepared.priorUsage, bytes: prepared.priorContextSerializedBytes,
                policy: inputs.configuration.policy)
            let projected = try retainedInput(priorUsage: prepared.priorUsage,
                priorSerializedBytes: prepared.priorContextSerializedBytes, incrementalInputBytes: inputBytes,
                fullWireBytes: preflight.bodyByteCount, policy: inputs.configuration.policy)
            let measured = try NativeSourceBudgetObservation(.init(binding: binding,
                preflight: .init(preflight), capabilities: capabilities, configuration: inputs.configuration,
                originalCeilings: prepared.frozenCeilings, effectiveCeilings: inputs.ceilings,
                toolSchemaSHA256: schemaFingerprint(tools), actual: actual,
                prospective: .init(projectedRetainedInputTokens: projected, serializedInputBytes: inputBytes,
                    outputRequirement: nil, continuationPreflight: nil)))
            observation = measured
            if let pressure = try pressure(measured, prospectiveReason: .projectedInputContext) { return .pressure(pressure) }
            let reserves = try inputs.ceilings.reserves.fixedTotal()
            let accounting = try ContextBudgetAccounting(version: "admitted_total_v2",
                cut: "retained_input_before_next_operation", retainedInputTokens: projected,
                futureReserveTokens: reserves, rawProviderUsage: prepared.priorUsage,
                resolvedPolicy: inputs.configuration.resolvedPolicy, toolSchemaSHA256: measured.fields.toolSchemaSHA256,
                pendingInputID: prepared.intentSHA256)
            return .admitted(try .init(policySelection: policySelection,
                effectiveContextTokens: inputs.ceilings.effectiveContextTokens, retainedInputTokens: projected,
                futureReserveTokens: reserves, limits: preflight.limits, ceilings: inputs.ceilings,
                accounting: accounting, source: .serializedEstimate,
                confidence: ContextBudgetSupervisor.serializedEstimateConfidence,
                action: action(retainedInputTokens: projected, ceilings: inputs.ceilings, overflow: false)))
        } catch { return .blocked(.init(binding: binding, code: failureCode(error), observation: observation)) }
    }

    static func acceptedDecision(context: NativeSourceAcceptedBudgetContext,
        policySelection: BudgetPolicySelection) -> NativeSourceBudgetDecision<NativeSourceBudgetObservation> {
        let binding = context.binding
        var observation: NativeSourceBudgetObservation?
        do {
            let accepted = context.accepted, prepared = accepted.prepared, turn = accepted.turn
            try match(prepared, binding: binding, boundary: .acceptedProviderResponse)
            try demand(turn.completed && turn.requestID == binding.observedResult?.providerRequestID
                && turn.responseID == binding.observedResult?.providerResponseID
                && turn.toolCalls.count == binding.admittedCallsInStage && accepted.calls.count == turn.toolCalls.count,
                .requestIdentityMismatch)
            let bytes = try NativeSourceJournalCoding.encode(NativeSourceJournalCoding.turn(turn),
                maximum: NativeSourceJournalCoding.maximumTurnBytes)
            try demand(JSONSupport.sha256Hex(bytes) == binding.observedResult?.resultSHA256, .requestIdentityMismatch)
            guard let preflight = prepared.retainedPreflight, let capabilities = prepared.retainedCapabilities else {
                throw DecisionFailure(.invalidPreflight)
            }
            try demand(turn.modelKey == capabilities.modelKey && turn.providerID == capabilities.providerID
                && turn.providerVersion == capabilities.providerVersion && turn.providerInstanceID == capabilities.providerInstanceID,
                .providerIdentityMismatch)
            let inputs = try decisionInputs(preflight: preflight, capabilities: capabilities,
                selection: policySelection, frozen: prepared.frozenCeilings, binding: binding)
            let measured = try NativeSourceBudgetObservation(.init(binding: binding, preflight: .init(preflight),
                capabilities: capabilities, configuration: inputs.configuration, originalCeilings: prepared.frozenCeilings,
                effectiveCeilings: inputs.ceilings, toolSchemaSHA256: schemaFingerprint(requestTools(prepared)),
                actual: observedContext(usage: turn.usage, bytes: context.retainedContextSerializedBytes,
                    policy: inputs.configuration.policy), prospective: nil))
            observation = measured
            if let pressure = try pressure(measured, prospectiveReason: nil) { return .pressure(pressure) }
            return .admitted(measured)
        } catch { return .blocked(.init(binding: binding, code: failureCode(error), observation: observation)) }
    }

    static func outputDecision(call: ResolvedNativeSourceProviderCall,
        priorOutputs: [NativeSourceProviderCallOutput], emptyOutputPreflight: ProviderRequestPreflight?,
        requirement: NativeSourceToolOutputRequirement, capabilities: ProviderCapabilities,
        policySelection: BudgetPolicySelection, binding: NativeSourceBudgetBinding)
        -> NativeSourceBudgetDecision<NativeSourceProviderOutputBudget> {
        var observation: NativeSourceBudgetObservation?
        do {
            try match(call.prepared, binding: binding, boundary: .beforeToolOutput)
            _ = try requirement.validated()
            try demand(binding.pendingCall?.ordinal == call.reference.ordinal
                && binding.pendingCall?.providerCallID == call.callID && binding.pendingCall?.toolName == call.toolName
                && binding.observedResult?.providerResponseID == call.responseID
                && call.providerOperationID == binding.stageID
                && call.reference.conversationID == binding.conversationID && call.reference.stageID == binding.stageID
                && call.attachment.descriptor.taskID == binding.taskID
                && call.attachment.descriptor.capabilityID == binding.capabilityID
                && call.attachment.descriptor.epoch == binding.capabilityEpoch,
                .requestIdentityMismatch)
            let arguments = try ForgeJSONCanonicalizationV1.data(from: JSONSerialization.jsonObject(with: call.canonicalArgumentsJSON))
            let argumentsSHA = JSONSupport.sha256Hex(arguments)
            let callMap: [String: Any] = ["conversation_id": binding.conversationID.uuidString.lowercased(),
                "stage_id": binding.stageID.uuidString.lowercased(), "ordinal": call.reference.ordinal,
                "response_id": call.responseID, "call_id": call.callID, "tool": call.toolName,
                "arguments_sha256": argumentsSHA]
            try demand(arguments == call.canonicalArgumentsJSON && binding.pendingCall?.argumentsSHA256 == argumentsSHA
                && binding.pendingCall?.callSHA256 == JSONSupport.sha256Hex(try ForgeJSONCanonicalizationV1.data(from: callMap)),
                .requestIdentityMismatch)
            try validatePrefix(priorOutputs, call: call, binding: binding)
            guard let retained = call.prepared.retainedPreflight else { throw DecisionFailure(.invalidPreflight) }
            _ = try NativeSourceStoredPreflight(retained).value()
            try demand(retained.modelKey == capabilities.modelKey
                && call.prepared.retainedCapabilities?.providerID == capabilities.providerID
                && call.prepared.retainedCapabilities?.providerVersion == capabilities.providerVersion
                && call.prepared.retainedCapabilities?.providerInstanceID == capabilities.providerInstanceID,
                .providerIdentityMismatch)
            try validateSelection(policySelection, binding: binding)
            // A committed final handoff has no subsequent provider output requirement.
            // Its packet, authority, current policy and wire checks remain in CP/bridge.
            if requirement.kind == .readyHandoff {
                try demand(call.toolName == "session_handoff" && emptyOutputPreflight == nil, .requestIdentityMismatch)
                try validateQuotas(binding, current: policySelection.policy.tools,
                    original: call.prepared.frozenCeilings?.tools)
                return .admitted(try .init(conversationID: call.reference.conversationID, stageID: call.reference.stageID,
                    callOrdinal: call.reference.ordinal, configurationFingerprintSHA256: retained.configurationFingerprintSHA256,
                    priorOutputsSHA256: call.priorOutputsSHA256, maximumCanonicalToolResultBytes: requirement.maximumFullToolResultBytes,
                    maximumEscapedPayloadBytes: 524_288, maximumResultTokens: 1_048_576))
            }
            guard let next = emptyOutputPreflight, let inputBytes = next.serializedInputByteCount else {
                throw DecisionFailure(.invalidPreflight)
            }
            try demand(next.kind == .continuation && next.modelKey == retained.modelKey
                && next.configurationFingerprintSHA256 == retained.configurationFingerprintSHA256
                && next.configurationRevision == retained.configurationRevision && next.limits == retained.limits,
                .configurationChanged)
            let inputs = try decisionInputs(preflight: retained, capabilities: capabilities,
                selection: policySelection, frozen: call.prepared.frozenCeilings, binding: binding)
            let baseline = try retainedInput(priorUsage: call.acceptedUsage,
                priorSerializedBytes: call.retainedContextSerializedBytes, incrementalInputBytes: inputBytes,
                fullWireBytes: next.bodyByteCount, policy: inputs.configuration.policy)
            let additional = try ContextBudgetMath.estimateTokens(serializedBytes: requirement.additionalEscapedPayloadBytes,
                policy: inputs.configuration.policy)
            let projected = try checkedAdd(baseline, additional)
            let measured = try NativeSourceBudgetObservation(.init(binding: binding, preflight: .init(retained),
                capabilities: capabilities, configuration: inputs.configuration, originalCeilings: call.prepared.frozenCeilings,
                effectiveCeilings: inputs.ceilings, toolSchemaSHA256: schemaFingerprint(requestTools(call.prepared)),
                actual: observedContext(usage: call.acceptedUsage, bytes: call.retainedContextSerializedBytes,
                    policy: inputs.configuration.policy),
                prospective: .init(projectedRetainedInputTokens: projected, serializedInputBytes: inputBytes,
                    outputRequirement: requirement, continuationPreflight: .init(next))))
            observation = measured
            if call.toolName == "fs_read" {
                let full = min(65_536, call.attachment.sourceLimits.maximumResultBytes,
                    call.attachment.setup.record.assignment.authorizationScope.maximumInlineOutputBytes,
                    inputs.ceilings.tools.maxResultBytes)
                try demand(requirement.kind == .readCeiling && requirement.maximumFullToolResultBytes == full,
                    .invalidMeasurement)
            } else {
                try demand(call.toolName == "session_checkpoint" && requirement.kind == .preparedCheckpoint,
                    .requestIdentityMismatch)
                try demand(requirement.maximumFullToolResultBytes <= inputs.ceilings.tools.maxResultBytes
                    && (requirement.resultTokenEstimate ?? Int.max) <= inputs.ceilings.tools.maxRetainedResultTokens,
                    .resultPolicyExceeded)
            }
            let reserves = try inputs.ceilings.reserves.fixedTotal()
            let threshold = try ratioTokens(inputs.ceilings.effectiveContextTokens, inputs.ceilings.rolloverRatio)
            // The full operation must fit even without accumulated context. A new
            // root cannot waive this original/current requirement or its threshold.
            try demand(try checkedAdd(additional, reserves) < threshold, .fullResultCannotFit)
            let wireLimit = min(524_288, next.limits.maximumRequestBytes)
            try demand(requirement.additionalEscapedPayloadBytes < wireLimit, .fullResultCannotFit)
            try demand(try checkedAdd(next.bodyByteCount, requirement.additionalEscapedPayloadBytes) <= wireLimit,
                .intrinsicRequestTooLarge)
            if let pressure = try pressure(measured, prospectiveReason: .projectedToolResultContext) { return .pressure(pressure) }
            let remainingTokens = threshold - (try checkedAdd(baseline, reserves)) - 1
            try demand(remainingTokens > 0, .invalidMeasurement)
            return .admitted(try .init(conversationID: call.reference.conversationID, stageID: call.reference.stageID,
                callOrdinal: call.reference.ordinal, configurationFingerprintSHA256: next.configurationFingerprintSHA256,
                priorOutputsSHA256: call.priorOutputsSHA256,
                maximumCanonicalToolResultBytes: requirement.maximumFullToolResultBytes,
                maximumEscapedPayloadBytes: max(1, requirement.additionalEscapedPayloadBytes),
                maximumResultTokens: min(inputs.ceilings.tools.maxRetainedResultTokens, remainingTokens)))
        } catch { return .blocked(.init(binding: binding, code: failureCode(error), observation: observation)) }
    }

    private struct DecisionFailure: Error { let code: NativeSourceBudgetFailureCode; init(_ code: NativeSourceBudgetFailureCode) { self.code = code } }
    private struct DecisionInputs { let configuration: ContextBudgetConfiguration; let ceilings: NativeSourceBudgetCeilings }
    private static func demand(_ value: Bool, _ code: NativeSourceBudgetFailureCode) throws {
        guard value else { throw DecisionFailure(code) }
    }
    private static func checkedAdd(_ lhs: Int, _ rhs: Int) throws -> Int {
        let result = lhs.addingReportingOverflow(rhs)
        try demand(lhs >= 0 && rhs >= 0, .invalidMeasurement)
        try demand(!result.overflow, .arithmeticOverflow)
        return result.partialValue
    }
    private static func failureCode(_ error: Error) -> NativeSourceBudgetFailureCode {
        if let error = error as? DecisionFailure { return error.code }
        if let error = error as? ContextBudgetError {
            switch error {
            case .arithmeticOverflow: return .arithmeticOverflow
            case .invalidPolicy, .invalidReserve, .insufficientUsableCapacity: return .invalidPolicy
            case .selectedInstanceNotLoaded, .ambiguousLoadedInstance, .modelNotLoaded, .modelLoadRequired: return .unsupportedProvider
            default: return .invalidMeasurement
            }
        }
        // A generic budgetExceeded or provider context-error string is never pressure.
        return .invalidMeasurement
    }
    private static func match(_ prepared: NativeSourcePreparedTurn, binding: NativeSourceBudgetBinding,
        boundary: NativeSourceBudgetBoundary) throws {
        try demand(prepared.ordinal <= 8, .exchangeRoundLimit)
        try demand(prepared.state == .prepared || prepared.state == .accepted, .stageNotEvaluable)
        _ = try binding.validated()
        try demand(binding.boundary == boundary && prepared.state == binding.stageState
            && prepared.stageID == binding.stageID && prepared.conversationID == binding.conversationID
            && prepared.taskID == binding.taskID && prepared.requestID == binding.logicalRequestID
            && prepared.ordinal == binding.stageOrdinal && prepared.intentSHA256 == binding.intentSHA256
            && prepared.deadline == binding.sourceInferenceDeadline, .requestIdentityMismatch)
    }
    private static func requestTools(_ prepared: NativeSourcePreparedTurn) -> [Data] {
        switch prepared.request { case .root(let request): request.tools; case .continuation(let request): request.tools }
    }
    private static func decisionInputs(preflight: ProviderRequestPreflight, capabilities: ProviderCapabilities,
        selection: BudgetPolicySelection, frozen: NativeSourceBudgetCeilings?, binding: NativeSourceBudgetBinding) throws -> DecisionInputs {
        do { _ = try NativeSourceStoredPreflight(preflight).value() }
        catch { throw DecisionFailure(.invalidPreflight) }
        try demand(preflight.modelKey == capabilities.modelKey, .providerIdentityMismatch)
        try demand(capabilities.customTools && capabilities.statefulResponses, .unsupportedProvider)
        try demand(preflight.bodyByteCount <= min(524_288, preflight.limits.maximumRequestBytes), .intrinsicRequestTooLarge)
        try validateSelection(selection, binding: binding)
        let current = try configuration(capabilities: capabilities, selection: selection)
        do { _ = try frozen?.validated() }
        catch { throw DecisionFailure(.invalidPolicy) }
        try demand(preflight.limits.maximumOutputTokens <= (frozen?.maximumOutputTokens ?? Int.max), .originalOutputLimitExceeded)
        let capacity = min(current.capacity.capacity, frozen?.effectiveContextTokens ?? Int.max)
        try demand(preflight.limits.maximumOutputTokens <= capacity, .reserveFloorsCannotFit)
        let old = frozen?.reserves, now = current.reserves
        let reserves = ContextBudgetReserves(outputTokens: max(preflight.limits.maximumOutputTokens, now.outputTokens, old?.outputTokens ?? 0),
            schemaTokens: max(now.schemaTokens, old?.schemaTokens ?? 0), handoffTokens: max(now.handoffTokens, old?.handoffTokens ?? 0),
            recoveryTokens: max(now.recoveryTokens, old?.recoveryTokens ?? 0), futureToolTokens: max(now.futureToolTokens, old?.futureToolTokens ?? 0),
            safetyTokens: max(now.safetyTokens, old?.safetyTokens ?? 0))
        try demand(try reserves.fixedTotal() < capacity, .reserveFloorsCannotFit)
        let ceilings = try effectiveCeilings(current: current, selection: selection, limits: preflight.limits, frozen: frozen)
        try validateQuotas(binding, current: ceilings.tools, original: nil)
        return .init(configuration: current, ceilings: ceilings)
    }
    private static func validateQuotas(_ binding: NativeSourceBudgetBinding,
        current: BudgetToolPolicy, original: BudgetToolPolicy?) throws {
        do { _ = try current.validated(); _ = try original?.validated() }
        catch { throw DecisionFailure(.invalidPolicy) }
        let prior = try checkedAdd(binding.sourceReadCallsBeforeEnrollment, binding.admittedProviderCallsBeforeStage)
        let total = try checkedAdd(prior, binding.admittedCallsInStage)
        let perTurn = min(current.callsPerTurn, original?.callsPerTurn ?? Int.max)
        let aggregate = min(binding.sourceMaximumCalls, current.callsPerSession, current.callsPerRun,
            original?.callsPerSession ?? Int.max, original?.callsPerRun ?? Int.max)
        try demand(binding.admittedCallsInStage <= perTurn && total <= aggregate, .toolQuotaExceeded)
    }
    private static func observedContext(usage: ProviderUsage?, bytes: Int, policy: ContextBudgetPolicy) throws -> NativeSourceObservedContext {
        if let usage {
            _ = try ProviderUsage(capacity: usage.capacity, inputTokens: usage.inputTokens, outputTokens: usage.outputTokens,
                totalTokens: usage.totalTokens, source: usage.source, confidence: usage.confidence)
            switch usage.source {
            case .providerExact, .tokenizerExact:
                return .init(retainedInputTokens: try checkedAdd(usage.inputTokens, usage.outputTokens), retainedSerializedBytes: bytes,
                    rawProviderUsage: usage, source: usage.source == .providerExact ? .providerExact : .tokenizerExact, confidence: usage.confidence)
            case .providerOverflow:
                return .init(retainedInputTokens: nil, retainedSerializedBytes: bytes, rawProviderUsage: usage,
                    source: .providerOverflow, confidence: usage.confidence)
            case .serializedEstimate: break
            }
        }
        let estimate = try ContextBudgetMath.estimateTokens(serializedBytes: bytes, policy: policy)
        let lower = try usage.map { try checkedAdd($0.inputTokens, $0.outputTokens) } ?? 0
        return .init(retainedInputTokens: max(estimate, lower), retainedSerializedBytes: bytes, rawProviderUsage: usage,
            source: .serializedEstimate, confidence: ContextBudgetSupervisor.serializedEstimateConfidence)
    }
    private static func pressure(_ observation: NativeSourceBudgetObservation,
        prospectiveReason: NativeSourcePressureReason?) throws -> NativeSourcePressureDecision? {
        if observation.fields.actual.source == .providerOverflow {
            return try .init(observation: observation, reason: .observedContextOverflow, action: .emergency)
        }
        guard let total = try observation.projectedTotalTokens ?? observation.observedTotalTokens else {
            throw DecisionFailure(.invalidMeasurement)
        }
        let ceilings = observation.fields.effectiveCeilings
        guard total >= (try ratioTokens(ceilings.effectiveContextTokens, ceilings.rolloverRatio)) else { return nil }
        let action: ContextBudgetAction = total >= (try ratioTokens(ceilings.effectiveContextTokens, ceilings.emergencyRatio)) ? .emergency : .rollover
        return try .init(observation: observation,
            reason: prospectiveReason ?? (action == .emergency ? .emergencyThreshold : .rolloverThreshold), action: action)
    }
    private static func validatePrefix(_ outputs: [NativeSourceProviderCallOutput], call: ResolvedNativeSourceProviderCall,
        binding: NativeSourceBudgetBinding) throws {
        try demand(outputs.count == binding.completedOutputCount && outputs.count == call.reference.ordinal
            && binding.completedOutputsSHA256 == call.priorOutputsSHA256, .invalidOutputPrefix)
        for (ordinal, output) in outputs.enumerated() {
            try demand(output.reference.conversationID == binding.conversationID && output.reference.stageID == binding.stageID
                && output.reference.ordinal == ordinal && output.responseID == call.responseID && !output.readyHandoffCommitted
                && output.resultSHA256 == JSONSupport.sha256Hex(output.canonicalToolResultJSON)
                && output.payloadSHA256 == JSONSupport.sha256Hex(output.canonicalPayloadJSON), .invalidOutputPrefix)
        }
        let prefix: [[String: Any]] = outputs.map {
            ["type": "function_call_output", "call_id": $0.callID,
             "output": String(decoding: $0.canonicalPayloadJSON, as: UTF8.self)]
        }
        try demand(JSONSupport.sha256Hex(try ForgeJSONCanonicalizationV1.data(from: prefix))
            == binding.completedOutputsSHA256, .invalidOutputPrefix)
    }
    private static func validateSelection(_ selection: BudgetPolicySelection,
        binding: NativeSourceBudgetBinding) throws {
        do { _ = try selection.scope.validated(); _ = try selection.policy.validated() }
        catch { throw DecisionFailure(.invalidPolicy) }
        try demand(selection.scope.kind == .projectOverride && selection.scope.projectID == binding.projectID.description
            && selection.scope.projectGeneration == Int(exactly: binding.projectGeneration.rawValue), .requestIdentityMismatch)
    }
}
