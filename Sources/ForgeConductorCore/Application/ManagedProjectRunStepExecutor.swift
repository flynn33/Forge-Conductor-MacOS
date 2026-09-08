// Managed provider loop with durable turn and tool intents for one project-scoped run.

import Foundation

/// Bytes at the request cut. Tool-result envelopes already committed through
/// observeToolResult are identified separately so a delivery retry is not usage.
public struct ManagedBudgetInputAccounting: Sendable, Equatable {
    public let inputBytes: Int
    public let toolSchemaBytes: Int
    public let toolSchemaSHA256: String
    public let pendingInputID: String
    public let inputAlreadyRetained: Bool
    public let providerPreflight: ProviderRequestPreflight?

    public init(inputBytes: Int, toolSchemaBytes: Int, toolSchemaSHA256: String,
                pendingInputID: String, inputAlreadyRetained: Bool,
                providerPreflight: ProviderRequestPreflight? = nil) {
        self.inputBytes = inputBytes; self.toolSchemaBytes = toolSchemaBytes
        self.toolSchemaSHA256 = toolSchemaSHA256; self.pendingInputID = pendingInputID
        self.inputAlreadyRetained = inputAlreadyRetained
        self.providerPreflight = providerPreflight
    }
}

public protocol ManagedRunBudgetEvaluating: Sendable {
    func evaluateBeforeProviderTurn(
        run: AutonomousRunRecord,
        sessionID: String,
        capabilities: ProviderCapabilities,
        serializedInputBytes: Int
    ) async throws -> ContextBudgetAction

    func evaluateBeforeProviderTurn(
        run: AutonomousRunRecord, sessionID: String, capabilities: ProviderCapabilities,
        accounting: ManagedBudgetInputAccounting
    ) async throws -> ContextBudgetAction

    func observeProviderTurn(
        _ turn: ProviderTurn,
        run: AutonomousRunRecord,
        sessionID: String,
        capabilities: ProviderCapabilities
    ) async throws -> ContextBudgetAction

    func observeToolResult(
        serializedBytes: Int,
        providerResponseID: String,
        run: AutonomousRunRecord,
        sessionID: String,
        capabilities: ProviderCapabilities
    ) async throws -> ContextBudgetAction

    func observeProviderOverflow(
        run: AutonomousRunRecord,
        sessionID: String,
        capabilities: ProviderCapabilities
    ) async throws -> ContextBudgetAction
}

public extension ManagedRunBudgetEvaluating {
    func evaluateBeforeProviderTurn(
        run: AutonomousRunRecord, sessionID: String, capabilities: ProviderCapabilities,
        accounting: ManagedBudgetInputAccounting
    ) async throws -> ContextBudgetAction {
        let sum = accounting.inputBytes.addingReportingOverflow(accounting.toolSchemaBytes)
        guard accounting.inputBytes >= 0, accounting.toolSchemaBytes >= 0, !sum.overflow else {
            throw ContextBudgetError.arithmeticOverflow
        }
        return try await evaluateBeforeProviderTurn(run: run, sessionID: sessionID,
                                                   capabilities: capabilities, serializedInputBytes: sum.partialValue)
    }
}

public struct NoManagedRunBudgetEvaluator: ManagedRunBudgetEvaluating, Sendable {
    public init() {}

    public func evaluateBeforeProviderTurn(
        run: AutonomousRunRecord,
        sessionID: String,
        capabilities: ProviderCapabilities,
        serializedInputBytes: Int
    ) async throws -> ContextBudgetAction { .normal }

    public func observeProviderTurn(
        _ turn: ProviderTurn,
        run: AutonomousRunRecord,
        sessionID: String,
        capabilities: ProviderCapabilities
    ) async throws -> ContextBudgetAction { .normal }

    public func observeToolResult(
        serializedBytes: Int,
        providerResponseID: String,
        run: AutonomousRunRecord,
        sessionID: String,
        capabilities: ProviderCapabilities
    ) async throws -> ContextBudgetAction { .normal }

    public func observeProviderOverflow(
        run: AutonomousRunRecord,
        sessionID: String,
        capabilities: ProviderCapabilities
    ) async throws -> ContextBudgetAction { .emergency }
}

public protocol ManagedRunContinuityExecuting: Sendable {
    func executeContinuityStep(
        intent: RunSideEffectIntent,
        run: AutonomousRunRecord,
        context: ToolInvocationContext,
        lease: RunLease
    ) async throws -> ProjectRunStepOutcome
}

public struct UnavailableManagedRunContinuityExecutor: ManagedRunContinuityExecuting, Sendable {
    public init() {}

    public func executeContinuityStep(
        intent: RunSideEffectIntent,
        run: AutonomousRunRecord,
        context: ToolInvocationContext,
        lease: RunLease
    ) async throws -> ProjectRunStepOutcome {
        .waitingResource(
            code: "continuity_worker_unavailable",
            summary: "The managed continuity worker is not available"
        )
    }
}

public actor ManagedProjectRunStepExecutor: ProjectRunStepExecuting {
    typealias SourceResumption = @Sendable (AutonomousRunRecord, RunLease) async throws -> AutonomousRunRecord
    public typealias ProviderResolver = @Sendable (
        _ adapterID: String
    ) throws -> any ManagedModelProvider
    public typealias ToolDefinitionResolver = @Sendable (
        _ allowedTools: Set<String>
    ) throws -> [Data]

    public static let maximumToolRounds = 32
    public static let maximumAssistantSummaryBytes = 16 * 1_024

    private struct ActiveProviderRequest: Sendable {
        let provider: any ManagedModelProvider
        let requestID: String
    }

    private let repository: ProjectControlPlaneRepository
    private let providerResolver: ProviderResolver
    private let toolDefinitionResolver: ToolDefinitionResolver
    private let broker: ToolInvocationBroker
    private let budget: any ManagedRunBudgetEvaluating
    private let continuity: any ManagedRunContinuityExecuting
    private let maximumToolRounds: Int
    private let sourceResumption: SourceResumption?

    private var providers: [String: any ManagedModelProvider] = [:]
    private var activeRequests: [RunID: ActiveProviderRequest] = [:]
    private var activeContinuity: (runID: RunID, task: Task<ProjectRunStepOutcome, Error>)?
    private var yieldedAfterStep = false

    public init(
        repository: ProjectControlPlaneRepository,
        providerResolver: @escaping ProviderResolver,
        toolDefinitionResolver: @escaping ToolDefinitionResolver,
        broker: ToolInvocationBroker,
        budget: any ManagedRunBudgetEvaluating = NoManagedRunBudgetEvaluator(),
        continuity: any ManagedRunContinuityExecuting = UnavailableManagedRunContinuityExecutor(),
        maximumToolRounds: Int = ManagedProjectRunStepExecutor.maximumToolRounds
    ) throws {
        try self.init(repository: repository, providerResolver: providerResolver,
            toolDefinitionResolver: toolDefinitionResolver, broker: broker, budget: budget,
            continuity: continuity, maximumToolRounds: maximumToolRounds, sourceResumption: nil)
    }

    init(
        repository: ProjectControlPlaneRepository,
        providerResolver: @escaping ProviderResolver,
        toolDefinitionResolver: @escaping ToolDefinitionResolver,
        broker: ToolInvocationBroker,
        budget: any ManagedRunBudgetEvaluating = NoManagedRunBudgetEvaluator(),
        continuity: any ManagedRunContinuityExecuting = UnavailableManagedRunContinuityExecutor(),
        maximumToolRounds: Int = ManagedProjectRunStepExecutor.maximumToolRounds,
        sourceResumption: SourceResumption?
    ) throws {
        guard (1...Self.maximumToolRounds).contains(maximumToolRounds) else {
            throw AutonomyError.invalidRequest("managed provider tool-round limit is outside bounds")
        }
        self.repository = repository
        self.providerResolver = providerResolver
        self.toolDefinitionResolver = toolDefinitionResolver
        self.broker = broker
        self.budget = budget
        self.continuity = continuity
        self.maximumToolRounds = maximumToolRounds
        self.sourceResumption = sourceResumption
    }

    public func prepareNextStep(for run: AutonomousRunRecord) async throws -> RunSideEffectIntent? {
        _ = try await repository.validateAutonomousRunExecutionAdmission(run.runID)
        if yieldedAfterStep {
            yieldedAfterStep = false
            return nil
        }
        if let pending = run.specification.work.pendingIntent { return pending }
        if run.state == .checkpointing || run.state == .rollingOver || run.state == .recovering {
            let key = "continuity:\(run.runID.description):\(run.revision)"
            return RunSideEffectIntent(
                intentID: Self.stableUUID(key),
                kind: .continuity,
                idempotencyKey: key,
                payloadSHA256: JSONSupport.sha256Hex(key),
                summary: "Recover or advance managed continuity"
            )
        }
        guard run.state == .running else { return nil }
        let priorResponseID = run.specification.work.metadata["provider_response_id"] ?? "root"
        let key = "provider:\(run.runID.description):\(run.revision):\(priorResponseID)"
        return RunSideEffectIntent(
            intentID: Self.stableUUID(key),
            kind: .providerTurn,
            idempotencyKey: key,
            payloadSHA256: JSONSupport.sha256Hex(Self.rootOrContinuationPrompt(for: run)),
            summary: "Execute one bounded managed-provider step"
        )
    }

    public func execute(
        _ intent: RunSideEffectIntent,
        run: AutonomousRunRecord,
        context: ToolInvocationContext,
        lease: RunLease
    ) async throws -> ProjectRunStepOutcome {
        try Task.checkCancellation()
        _ = try await repository.validateAutonomousRunExecutionAdmission(run.runID)
        switch intent.kind {
        case .continuity:
            guard activeContinuity == nil else {
                throw AutonomyError.invalidRequest("a continuity step is already active on this executor")
            }
            yieldedAfterStep = true
            let task = Task { [continuity] in
                try Task.checkCancellation()
                return try await continuity.executeContinuityStep(
                    intent: intent, run: run, context: context, lease: lease
                )
            }
            activeContinuity = (run.runID, task)
            defer { activeContinuity = nil }
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        case .providerTurn:
            let current = try await repository.validateAutonomousRunExecutionAdmission(run.runID)
            let source: ContinuitySourceActivationReceipt?
            if let operationID = current.activeOperationID {
                source = try await repository.sourceActivationReceipt(runID: current.runID, operationID: operationID, lease: lease)
            } else { source = nil }
            let outcome = try await executeProviderStep(intent, run: current, lease: lease, sourceActivation: source)
            try Task.checkCancellation()
            // Finish the complete bounded step before clearing its source operation.
            // The coordinator reloads the run revision before applying this outcome.
            if let sourceResumption { _ = try await sourceResumption(current, lease) }
            let reconciled = try await repository.validateAutonomousRunExecutionAdmission(current.runID)
            if let source, reconciled.activeOperationID != source.operationID {
                // A cleared operation is accepted only with the retained CP
                // resumption proof, including on replay after the final commit.
                guard reconciled.activeOperationID == nil,
                      try await repository.sourceActivationReceipt(runID: current.runID,
                        operationID: source.operationID, lease: lease) == source else {
                    throw AutonomyError.intentConflict
                }
            }
            yieldedAfterStep = true
            if let source, reconciled.activeOperationID == source.operationID {
                switch outcome {
                case .rolloverRequired, .checkpointRequired:
                    return Self.sourceBudgetDeferral
                case .continued, .completionRequested, .completionRequestedWithWork:
                    return .waitingResource(code: "source_continuation_effect_required",
                        summary: "The source successor must complete an authorized tool effect and consume its exact output before continuing")
                case .failedRecoverable(let code, let summary):
                    return .waitingResource(code: code, summary: summary)
                default: break
                }
            }
            return outcome
        case .toolInvocation, .runtimeJob, .completionValidation:
            throw AutonomyError.invalidRequest(
                "managed step executor received an unsupported top-level side-effect kind"
            )
        }
    }

    public func cancel(runID: RunID) async {
        if let active = activeContinuity, active.runID == runID {
            active.task.cancel()
        }
        if let active = activeRequests.removeValue(forKey: runID) {
            await active.provider.cancel(requestID: active.requestID)
        }
    }

    private func executeProviderStep(
        _ sideEffect: RunSideEffectIntent,
        run: AutonomousRunRecord,
        lease: RunLease,
        sourceActivation: ContinuitySourceActivationReceipt?
    ) async throws -> ProjectRunStepOutcome {
        _ = try await repository.validateAutonomousRunExecutionAdmission(run.runID)
        guard let adapterID = run.adapterID, !adapterID.isEmpty,
              let expectedProviderID = run.providerID, !expectedProviderID.isEmpty,
              let modelKey = run.modelKey, !modelKey.isEmpty else {
            return .failedTerminal(
                code: "managed_provider_configuration_missing",
                summary: "Run is missing its adapter, provider, or model identity"
            )
        }
        let provider = try resolvedProvider(adapterID: adapterID)
        let sourceCarryover = try await repository.nativeSourceBudgetCarryover(runID: run.runID)
        let observedProvider: (any ManagedModelProviderObservedDispatching)?
        if sourceCarryover != nil {
            guard let observed = provider as? any ManagedModelProviderObservedDispatching else {
                throw NativeSourceConversationError.unsupportedProvider
            }
            observedProvider = observed
        } else { observedProvider = nil }
        var capabilities: ProviderCapabilities
        if observedProvider != nil, let sessionID = run.activeSessionID {
            let automatic = try await automaticContinuation(run: run, sessionID: sessionID,
                previousResponseID: run.specification.work.metadata["provider_response_id"], work: run.specification.work)
            let turnID = automatic?.record.intent.turnID ?? Self.stableUUID("turn:\(sideEffect.idempotencyKey):round:0")
            if let existing = try await repository.providerTurn(turnID) {
                if let retained = try await repository.sourceDerivedProviderTurnPreflight(turnID: turnID, lease: lease) {
                    capabilities = retained.capabilities
                } else if existing.state != .intent {
                    throw NativeSourceConversationError.integrityFailure
                } else { capabilities = try await provider.probe() }
            } else { capabilities = try await provider.probe() }
        } else { capabilities = try await provider.probe() }
        guard provider.providerID == expectedProviderID,
              capabilities.providerID == expectedProviderID,
              capabilities.modelKey == modelKey,
              capabilities.statefulResponses,
              capabilities.customTools else {
            return .failedTerminal(
                code: "managed_provider_capability_mismatch",
                summary: "Configured provider identity or required capabilities do not match"
            )
        }

        let sessionID = try await ensureActiveSession(
            run: run,
            lease: lease,
            adapterID: adapterID,
            capabilities: capabilities
        )
        let providerContext = try await repository.invocationContext(
            for: ProjectBindingOwner(kind: .providerSession, id: sessionID),
            clientID: ClientID("autonomy:\(run.runID.description)")
        )
        let tools = try toolDefinitionResolver(Set(run.specification.allowedTools))
        let toolSchemaSHA256 = Self.toolSchemaSHA256(tools)
        var work = run.specification.work
        var previousResponseID = work.metadata["provider_response_id"]
        var continuationInput: Data?
        var strongestAction = ContextBudgetAction.normal
        if sourceCarryover != nil {
            guard let sourceBudget = budget as? any ManagedRunToolResultBudgetEvaluating else {
                throw NativeSourceConversationError.unsupportedProvider
            }
            let identity = ContextBudgetIdentity(runID: run.runID, projectID: run.projectID,
                projectGeneration: run.projectGeneration, sessionID: sessionID)
            let retained = try await repository.contextBudgetState(identity: identity)
            if retained?.latestObservation == nil {
                guard let previousResponseID,
                      let acknowledgement = try await repository.sourceDerivedBootstrapAcknowledgement(
                        runID: run.runID, sessionID: sessionID, previousResponseID: previousResponseID, lease: lease) else {
                    throw NativeSourceConversationError.integrityFailure
                }
                strongestAction = try await sourceBudget.seedSourceProviderTurn(run: run, sessionID: sessionID,
                    capabilities: acknowledgement.capabilities, turn: acknowledgement.turn,
                    retainedContextSerializedBytes: acknowledgement.retainedContextSerializedBytes)
            }
        }

        for round in 0..<maximumToolRounds {
            try Task.checkCancellation()
            let automatic = round == 0
                ? try await automaticContinuation(
                    run: run,
                    sessionID: sessionID,
                    previousResponseID: previousResponseID,
                    work: work
                )
                : nil
            let input = try automatic?.input ?? requestInput(
                run: run,
                previousResponseID: previousResponseID,
                continuationInput: continuationInput
            )
            let sourceDispatch: SourceDerivedDispatch?
            if let observedProvider {
                sourceDispatch = try await prepareSourceDerivedDispatch(sideEffect: sideEffect, run: run,
                    sessionID: sessionID, round: round, previousResponseID: previousResponseID,
                    input: input, tools: tools, toolSchemaSHA256: toolSchemaSHA256,
                    automatic: automatic, provider: observedProvider, capabilities: capabilities, lease: lease)
                capabilities = sourceDispatch!.capabilities
            } else { sourceDispatch = nil }
            let beforeAction: ContextBudgetAction
            if let sourceDispatch, sourceDispatch.record.state != .intent {
                // A recorded response or uncertain POST is reconciliation, not another input.
                beforeAction = .normal
            } else {
                beforeAction = try await budget.evaluateBeforeProviderTurn(
                run: run,
                sessionID: sessionID,
                capabilities: capabilities,
                accounting: ManagedBudgetInputAccounting(
                    inputBytes: sourceDispatch?.preflight.serializedInputByteCount ?? input.count,
                    toolSchemaBytes: sourceDispatch.map { $0.preflight.bodyByteCount - ($0.preflight.serializedInputByteCount ?? 0) }
                        ?? tools.reduce(0) { $0 + $1.count },
                    toolSchemaSHA256: toolSchemaSHA256,
                    pendingInputID: JSONSupport.sha256Hex("\(previousResponseID ?? "root"):\(JSONSupport.sha256Hex(input)):\(toolSchemaSHA256)"),
                    inputAlreadyRetained: continuationInput != nil,
                    providerPreflight: sourceDispatch?.preflight
                )
            )
            }
            strongestAction = Self.stronger(strongestAction, beforeAction)
            if sourceActivation != nil,
               strongestAction == .checkpoint || strongestAction == .rollover || strongestAction == .emergency {
                return Self.sourceBudgetDeferral
            }
            // A successor is not accepted until this exact turn is durably reserved.
            // Dispatch it before acting on another rollover signal so recovery cannot
            // create an endless chain of fresh sessions without consuming the handoff.
            if automatic == nil,
               strongestAction == .rollover || strongestAction == .emergency {
                work.metadata["provider_response_id"] = previousResponseID
                return .rolloverRequired(work)
            }

            var record: ProviderTurnRecord
            if let sourceDispatch {
                record = sourceDispatch.record
            } else if let automatic {
                record = automatic.record
            } else {
                let idempotencyKey = "\(sideEffect.idempotencyKey):round:\(round)"
                let turnID = Self.stableUUID("turn:\(idempotencyKey)")
                let kind: ProviderTurnKind
                if previousResponseID == nil {
                    kind = .initialRoot
                } else if round == 0 {
                    kind = .normalContinuation
                } else {
                    kind = .toolContinuation
                }
                let turnIntent = ProviderTurnIntent(
                    turnID: turnID,
                    runID: run.runID,
                    sessionID: sessionID,
                    operationID: try await operationForTurnReplay(turnID: turnID, sideEffect: sideEffect,
                        run: run, sessionID: sessionID, kind: kind, idempotencyKey: idempotencyKey,
                        previousResponseID: previousResponseID, input: input, toolSchemaSHA256: toolSchemaSHA256, lease: lease),
                    projectID: run.projectID,
                    projectGeneration: run.projectGeneration,
                    kind: kind,
                    idempotencyKey: idempotencyKey,
                    previousResponseID: previousResponseID,
                    inputSHA256: JSONSupport.sha256Hex(input),
                    toolSchemaSHA256: toolSchemaSHA256
                )
                record = try await repository.persistProviderTurnIntent(turnIntent, lease: lease)
            }
            let turn: ProviderTurn
            do {
                turn = try await dispatchProviderTurn(
                    record: &record,
                    provider: provider,
                    run: run,
                    modelKey: modelKey,
                    input: input,
                    tools: tools,
                    lease: lease,
                    sourceDispatch: sourceDispatch
                )
            } catch let failure as any ManagedProviderFailure
            where failure.managedProviderFailureDisposition == .contextOverflow {
                if record.intent.kind == .automaticContinuation {
                    return .failedRecoverable(
                        code: failure.managedProviderFailureCode,
                        summary: "The fresh successor could not consume its durable continuation within the provider context limit"
                    )
                }
                let overflowAction = try await budget.observeProviderOverflow(
                    run: run,
                    sessionID: sessionID,
                    capabilities: capabilities
                )
                strongestAction = Self.stronger(strongestAction, overflowAction)
                work.metadata["provider_overflow"] = "true"
                work.metadata["provider_overflow_code"] = failure.managedProviderFailureCode
                work.metadata["provider_response_id"] = previousResponseID
                return .rolloverRequired(work)
            }
            guard turn.completed,
                  turn.providerID == expectedProviderID,
                  turn.modelKey == modelKey,
                  turn.previousResponseID == previousResponseID else {
                throw ManagedModelProviderContractError.incompleteTerminalResponse
            }

            let historicalBudgetReplay: Bool
            if let sourceDispatch, let observedProvider {
                historicalBudgetReplay = try await sourceBudgetIsHistoricalReplay(run: run,
                    sessionID: sessionID, sideEffect: sideEffect, round: round,
                    dispatch: sourceDispatch, turn: turn, provider: observedProvider, lease: lease)
            } else { historicalBudgetReplay = false }

            previousResponseID = turn.responseID
            work.metadata["provider_response_id"] = turn.responseID
            work.metadata["provider_session_id"] = sessionID
            work.metadata["provider_adapter_id"] = adapterID
            work.metadata["provider_capability_sha256"] = capabilities.capabilityFingerprintSHA256
            if let usage = turn.usage {
                work.metadata["provider_context_used"] = String(usage.inputTokens)
                work.metadata["provider_context_capacity"] = String(usage.capacity)
            }
            if let summary = Self.boundedAssistantSummary(turn.messages) {
                work.metadata["provider_assistant_summary"] = summary
            }

            let afterAction: ContextBudgetAction
            if historicalBudgetReplay { afterAction = .normal }
            else {
                afterAction = try await budget.observeProviderTurn(
                    turn, run: run, sessionID: sessionID, capabilities: capabilities)
            }
            strongestAction = Self.stronger(strongestAction, afterAction)

            guard !turn.toolCalls.isEmpty else {
                if strongestAction == .rollover || strongestAction == .emergency {
                    return .rolloverRequired(work)
                }
                if strongestAction == .checkpoint { return .checkpointRequired(work) }
                if let request = Self.completionRequest(from: turn.messages) {
                    // Legacy gate_evidence fields remain wire-compatible but carry
                    // no authority. Only installed manager validators decide gates.
                    return .completionRequestedWithWork(request.summary, work)
                }
                work.nextAction = "Continue the mission from provider response \(turn.responseID)"
                return .continued(work)
            }

            var outputs: [[String: Any]] = []
            outputs.reserveCapacity(turn.toolCalls.count)
            var prefix = try ManagedToolResultPrefix(providerResponseID: turn.responseID, outputCount: 0,
                lastProviderCallID: nil, canonicalPrefixSHA256: JSONSupport.sha256Hex(Data("[]".utf8)), serializedInputByteCount: 0)
            for call in turn.toolCalls {
                let arguments = try Self.arguments(call.argumentsJSON)
                if !historicalBudgetReplay, let observedProvider, let sourceCarryover {
                    guard let sourceBudget = budget as? any ManagedRunToolResultBudgetEvaluating else {
                        throw NativeSourceConversationError.unsupportedProvider
                    }
                    let recorded = try await repository.toolInvocation(sessionID: sessionID, providerCallID: call.callID)
                    if recorded?.state != .completed {
                        var projectedOutputs = outputs
                        projectedOutputs.append(["type":"function_call_output", "call_id":call.callID, "output":"0"])
                        let projectionInput = try Self.canonicalData(projectedOutputs)
                        let preflight = try await sourceToolOutputPreflight(provider: observedProvider,
                            input: projectionInput, tools: tools, run: run, sideEffect: sideEffect,
                            round: round, previousResponseID: turn.responseID, modelKey: modelKey)
                        let ceiling = min(ToolInvocationBroker.maximumDurableResultBytes,
                            providerContext.authorizationScope.maximumInlineOutputBytes, sourceCarryover.ceilings.tools.maxResultBytes)
                        let projectionAction = try await sourceBudget.evaluateBeforeToolResult(run: run, sessionID: sessionID,
                            capabilities: capabilities, projection: .init(priorPrefix: prefix, providerCallID: call.callID,
                                continuationPreflight: preflight, maximumToolResultBytes: ceiling, toolSchemaSHA256: toolSchemaSHA256))
                        strongestAction = Self.stronger(strongestAction, projectionAction)
                        if projectionAction == .rollover || projectionAction == .emergency {
                            return .rolloverRequired(work)
                        }
                    }
                }
                let result = try await broker.invoke(
                    BrokeredToolCall(
                        providerCallID: call.callID,
                        toolName: call.name,
                        arguments: arguments,
                        idempotencyKey: "\(sessionID):\(call.callID)"
                    ),
                    turnID: record.intent.turnID,
                    context: providerContext,
                    lease: lease
                )
                let output = try JSONSupport.canonicalJSON(result.payload)
                let evidenceSHA256 = JSONSupport.sha256Hex(output)
                if !work.evidenceReferences.contains(evidenceSHA256) {
                    work.evidenceReferences.append(evidenceSHA256)
                }
                work.metadata[
                    "tool_evidence.\(call.name).\(call.callID)"
                ] = evidenceSHA256
                outputs.append([
                    "type": "function_call_output",
                    "call_id": call.callID,
                    "output": output,
                ])
                let toolAction: ContextBudgetAction
                if historicalBudgetReplay { toolAction = .normal }
                else if let observedProvider {
                    guard let sourceBudget = budget as? any ManagedRunToolResultBudgetEvaluating else {
                        throw NativeSourceConversationError.unsupportedProvider
                    }
                    let exactInput = try Self.canonicalData(outputs)
                    let preflight = try await sourceToolOutputPreflight(provider: observedProvider, input: exactInput,
                        tools: tools, run: run, sideEffect: sideEffect, round: round,
                        previousResponseID: turn.responseID, modelKey: modelKey)
                    guard let inputBytes = preflight.serializedInputByteCount else {
                        throw NativeSourceConversationError.unsupportedProvider
                    }
                    prefix = try .init(providerResponseID: turn.responseID, outputCount: outputs.count,
                        lastProviderCallID: call.callID, canonicalPrefixSHA256: JSONSupport.sha256Hex(exactInput),
                        serializedInputByteCount: inputBytes)
                    toolAction = try await sourceBudget.observeToolResultPrefix(run: run, sessionID: sessionID,
                        capabilities: capabilities, prefix: prefix)
                } else {
                toolAction = try await budget.observeToolResult(
                    serializedBytes: try Self.canonicalData([outputs[outputs.count - 1]]).count,
                    providerResponseID: turn.responseID,
                    run: run,
                    sessionID: sessionID,
                    capabilities: capabilities
                )
                }
                strongestAction = Self.stronger(strongestAction, toolAction)
            }
            continuationInput = try Self.canonicalData(outputs)
            if strongestAction == .rollover || strongestAction == .emergency {
                return .rolloverRequired(work)
            }
            if strongestAction == .checkpoint { return .checkpointRequired(work) }
        }

        return .failedRecoverable(
            code: "managed_provider_tool_round_limit",
            summary: "The provider exceeded the bounded tool-round limit"
        )
    }

    private static var sourceBudgetDeferral: ProjectRunStepOutcome {
        .waitingResource(code: "source_continuation_budget_pending",
            summary: "Current context limits defer the source continuation while its exact pending work and tool outputs remain durable")
    }

    /// A crash may leave the side effect pending after its source resumption was
    /// committed. Reuse a prior turn's operation only through its exact durable
    /// identity and the control plane's retained source activation receipt.
    private func operationForTurnReplay(turnID: UUID, sideEffect: RunSideEffectIntent,
        run: AutonomousRunRecord, sessionID: String, kind: ProviderTurnKind, idempotencyKey: String,
        previousResponseID: String?, input: Data, toolSchemaSHA256: String, lease: RunLease) async throws -> UUID? {
        guard let stored = try await repository.providerTurn(turnID),
              stored.intent.operationID != run.activeOperationID else { return run.activeOperationID }
        guard let operationID = stored.intent.operationID,
              run.specification.work.pendingIntent == sideEffect,
              stored.intent.turnID == turnID, stored.intent.runID == run.runID,
              stored.intent.sessionID == sessionID, stored.intent.projectID == run.projectID,
              stored.intent.projectGeneration == run.projectGeneration, stored.intent.kind == kind,
              stored.intent.idempotencyKey == idempotencyKey, stored.intent.previousResponseID == previousResponseID,
              stored.intent.inputSHA256 == JSONSupport.sha256Hex(input), stored.intent.toolSchemaSHA256 == toolSchemaSHA256,
              let receipt = try await repository.sourceActivationReceipt(runID: run.runID, operationID: operationID, lease: lease),
              receipt.candidateID.uuidString.lowercased() == sessionID,
              receipt.authorization.projectID == run.projectID,
              receipt.authorization.projectGeneration == run.projectGeneration else {
            throw AutonomyError.intentConflict
        }
        return receipt.operationID
    }

    private func resolvedProvider(adapterID: String) throws -> any ManagedModelProvider {
        if let provider = providers[adapterID] { return provider }
        let provider = try providerResolver(adapterID)
        providers[adapterID] = provider
        return provider
    }

    private func ensureActiveSession(
        run: AutonomousRunRecord,
        lease: RunLease,
        adapterID: String,
        capabilities: ProviderCapabilities
    ) async throws -> String {
        if let sessionID = run.activeSessionID { return sessionID }
        let sessionID = "managed-\(Self.stableUUID("session:\(run.runID.description)").uuidString.lowercased())"
        try await repository.reserveProviderSession(
            ProviderSessionIntent(
                sessionID: sessionID,
                runID: run.runID,
                projectID: run.projectID,
                projectGeneration: run.projectGeneration,
                providerID: capabilities.providerID,
                adapterID: adapterID,
                modelKey: capabilities.modelKey,
                idempotencyKey: "initial-session:\(run.runID.description)",
                contextCapacity: capabilities.contextLength
            ),
            lease: lease
        )
        return sessionID
    }

    private struct AutomaticContinuationDispatch {
        let record: ProviderTurnRecord
        let input: Data
    }

    /// Selects the one turn atomically reserved when the successor won rollover.
    /// The metadata lookup also covers a crash after the provider turn committed but
    /// before its response identity was copied into autonomous run work.
    private func automaticContinuation(
        run: AutonomousRunRecord,
        sessionID: String,
        previousResponseID: String?,
        work: AutonomousRunWork
    ) async throws -> AutomaticContinuationDispatch? {
        let pending = try await repository.pendingAutomaticContinuation(runID: run.runID)
        var candidate = pending
        if let rawTurnID = work.metadata["automatic_continuation_turn_id"],
           let turnID = UUID(uuidString: rawTurnID),
           let recorded = try await repository.providerTurn(turnID) {
            if let pending, pending.intent.turnID != recorded.intent.turnID {
                throw AutonomyError.intentConflict
            }
            if candidate == nil,
               recorded.state == .completed,
               work.metadata["provider_response_id"] != recorded.providerResponseID {
                candidate = recorded
            }
        }

        guard let candidate else {
            guard !run.continuationPending else {
                throw ProjectContextError.integrityFailure(
                    "accepted successor has no pending automatic continuation"
                )
            }
            return nil
        }
        let input = try ManagedContinuityWorker.automaticContinuationInput()
        guard candidate.intent.kind == .automaticContinuation,
              candidate.intent.runID == run.runID,
              candidate.intent.projectID == run.projectID,
              candidate.intent.projectGeneration == run.projectGeneration,
              candidate.intent.sessionID == sessionID,
              candidate.intent.previousResponseID == previousResponseID,
              candidate.intent.inputSHA256 == JSONSupport.sha256Hex(input) else {
            throw AutonomyError.intentConflict
        }
        if let rawOperationID = work.metadata["continuity_operation_id"] {
            guard let operationID = UUID(uuidString: rawOperationID),
                  candidate.intent.operationID == operationID else {
                throw AutonomyError.intentConflict
            }
        }
        return AutomaticContinuationDispatch(record: candidate, input: input)
    }

    // Reconcile an accounted descendant without another provider probe or POST.
    // Call after validateSourceDerivedResult/ordinary outer identity checks and
    // before observeProviderTurn. A true result authorizes skipping only historical
    // budget observation/projection/prefix mutation, never a tool/provider effect.
    private func sourceBudgetIsHistoricalReplay(
        run: AutonomousRunRecord, sessionID: String, sideEffect: RunSideEffectIntent,
        round: Int, dispatch: SourceDerivedDispatch, turn: ProviderTurn,
        provider: any ManagedModelProviderObservedDispatching, lease: RunLease
    ) async throws -> Bool {
        try Task.checkCancellation()
        guard (0..<maximumToolRounds).contains(round), sideEffect.kind == .providerTurn,
              run.specification.work.pendingIntent == sideEffect,
              let live = try await repository.autonomousRun(run.runID),
              live.specification.work.pendingIntent == sideEffect, live.activeSessionID == sessionID else {
            throw AutonomyError.intentConflict
        }
        _ = try await repository.validateAutonomousRunExecutionAdmission(run.runID)
        let identity = ContextBudgetIdentity(runID: run.runID, projectID: run.projectID,
            projectGeneration: run.projectGeneration, sessionID: sessionID)
        guard let stored = try await repository.contextBudgetState(identity: identity),
              let latest = try stored.validated().latestObservation,
              let accounted = latest.accounting?.toolResultAccounting else { return false }
        _ = try accounted.validated()
        guard latest.providerResponseID == accounted.providerResponseID else {
            throw NativeSourceConversationError.integrityFailure
        }
        if accounted.providerResponseID == turn.responseID || accounted.providerResponseID == turn.previousResponseID {
            return false // Exact replay of current response, or a genuinely new child.
        }

        // The current actual turn has already passed the original provider receipt
        // checks. Re-read its FULL-durable CP identity and its original preflight.
        guard let current = try await repository.providerTurn(dispatch.intent.turnID),
              current.state == .completed,
              sourceReplayIntent(current.intent) == dispatch.intent,
              current.providerResponseID == turn.responseID, current.providerRequestID == turn.requestID,
              try Self.matchesStoredUsage(current.usageJSON, actual: turn.usage),
              let currentPreflight = try await repository.sourceDerivedProviderTurnPreflight(
                turnID: current.intent.turnID, lease: lease),
              currentPreflight.intent == dispatch.intent,
              currentPreflight.preflight == dispatch.preflight, currentPreflight.capabilities == dispatch.capabilities,
              !turn.toolCalls.isEmpty,
              turn.toolCalls.count <= ManagedModelProviderContract.maximumToolCallCount else {
            throw NativeSourceConversationError.integrityFailure
        }
        try validateSourceDerivedResult(turn, dispatch: dispatch)

        // Derive the first child's input from every actual completed tool result in
        // provider call order. No missing/ambiguous call can become a new dispatch
        // merely because the budget has observed a later response.
        var outputs: [[String: Any]] = []
        outputs.reserveCapacity(turn.toolCalls.count)
        for call in turn.toolCalls {
            try Task.checkCancellation()
            var arguments = try Self.arguments(call.argumentsJSON)
            let key = "\(sessionID):\(call.callID)"
            // This is the same deterministic normalization as the existing broker;
            // it only checks identity and never supplies an execution owner.
            if ProductionToolReplayCatalog.acceptsDurableIdempotencyArgument.contains(call.name),
               arguments["idempotency_key"] == nil { arguments["idempotency_key"] = key }
            let argumentsSHA = JSONSupport.sha256Hex(try JSONSupport.canonicalJSON(arguments))
            guard call.callID.utf8.count <= 512,
                  let record = try await repository.toolInvocation(sessionID: sessionID, providerCallID: call.callID),
                  record.state == .completed, record.turnID == current.intent.turnID,
                  record.runID == run.runID, record.sessionID == sessionID,
                  record.projectID == run.projectID, record.projectGeneration == run.projectGeneration,
                  record.providerCallID == call.callID, record.toolName == call.name,
                  record.idempotencyKey == key, record.argumentsSHA256 == argumentsSHA,
                  let result = record.resultSummary, result.utf8.count <= ToolInvocationBroker.maximumDurableResultBytes,
                  record.resultSHA256 == JSONSupport.sha256Hex(result),
                  let full = try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any],
                  full["ok"] is Bool, full["is_error"] is Bool,
                  let payload = full["payload"] as? [String: Any] else {
                throw NativeSourceConversationError.integrityFailure
            }
            outputs.append(["type": "function_call_output", "call_id": call.callID,
                            "output": try JSONSupport.canonicalJSON(payload)])
        }
        let firstChildInputSHA = JSONSupport.sha256Hex(try Self.canonicalData(outputs))
        var previous = turn.responseID
        var seen = Set([previous])
        guard round + 1 < maximumToolRounds else { throw NativeSourceConversationError.integrityFailure }
        for nextRound in (round + 1)..<maximumToolRounds {
            try Task.checkCancellation()
            let key = "\(sideEffect.idempotencyKey):round:\(nextRound)"
            let turnID = Self.stableUUID("turn:\(key)")
            guard let next = try await repository.providerTurn(turnID), next.state == .completed,
                  next.intent.turnID == turnID, next.intent.runID == run.runID,
                  next.intent.projectID == run.projectID, next.intent.projectGeneration == run.projectGeneration,
                  next.intent.sessionID == sessionID, next.intent.kind == .toolContinuation,
                  next.intent.idempotencyKey == key, next.intent.operationID == current.intent.operationID,
                  next.intent.previousResponseID == previous,
                  nextRound != round + 1 || next.intent.inputSHA256 == firstChildInputSHA,
                  let responseID = next.providerResponseID, seen.insert(responseID).inserted,
                  let retained = try await repository.sourceDerivedProviderTurnPreflight(turnID: turnID, lease: lease),
                  retained.intent == sourceReplayIntent(next.intent) else {
                throw NativeSourceConversationError.integrityFailure
            }
            if responseID == accounted.providerResponseID {
                // A response ID alone is insufficient. Match the exact normalized
                // recorded target response whose digest the budget actually retained.
                guard let target = try await provider.lookupRecorded(idempotencyKey: key) else {
                    throw NativeSourceConversationError.outcomeUnknown
                }
                guard target.completed, target.responseID == responseID,
                      target.previousResponseID == next.intent.previousResponseID,
                      target.requestID == (next.intent.operationID ?? next.intent.turnID).uuidString.lowercased(),
                      target.requestID == next.providerRequestID,
                      target.providerID == retained.capabilities.providerID,
                      target.providerVersion == retained.capabilities.providerVersion,
                      target.modelKey == retained.capabilities.modelKey,
                      target.providerInstanceID == retained.capabilities.providerInstanceID,
                      try Self.matchesStoredUsage(next.usageJSON, actual: target.usage),
                      accounted.providerTurnSHA256 == (try ManagedToolResultBudgetValidation.turnSHA256(target)),
                      latest.accounting?.rawProviderUsage == target.usage else {
                    throw NativeSourceConversationError.integrityFailure
                }
                // Recheck authority after the asynchronous recorded lookup.
                guard let final = try await repository.sourceDerivedProviderTurnPreflight(turnID: turnID, lease: lease),
                      final == retained,
                      let live = try await repository.autonomousRun(run.runID),
                      live.specification.work.pendingIntent == sideEffect, live.activeSessionID == sessionID else {
                    throw AutonomyError.intentConflict
                }
                _ = try await repository.validateAutonomousRunExecutionAdmission(run.runID)
                return true
            }
            previous = responseID
        }
        throw NativeSourceConversationError.integrityFailure
    }

    private func sourceReplayIntent(_ value: ProviderTurnIntentRecord) -> ProviderTurnIntent {
        .init(turnID: value.turnID, runID: value.runID, sessionID: value.sessionID,
            operationID: value.operationID, projectID: value.projectID, projectGeneration: value.projectGeneration,
            kind: value.kind, idempotencyKey: value.idempotencyKey, previousResponseID: value.previousResponseID,
            inputSHA256: value.inputSHA256, toolSchemaSHA256: value.toolSchemaSHA256)
    }


    private func sourceToolOutputPreflight(provider: any ManagedModelProviderObservedDispatching,
        input: Data, tools: [Data], run: AutonomousRunRecord, sideEffect: RunSideEffectIntent,
        round: Int, previousResponseID: String, modelKey: String) async throws -> ProviderRequestPreflight {
        let key = "\(sideEffect.idempotencyKey):round:\(round + 1)"
        let turnID = Self.stableUUID("turn:\(key)")
        return try await provider.preflightContinuation(.init(operationID: run.activeOperationID ?? turnID,
            idempotencyKey: key, modelKey: modelKey, previousResponseID: previousResponseID, input: input, tools: tools))
    }

    private struct SourceDerivedDispatch {
        let record: ProviderTurnRecord
        let intent: ProviderTurnIntent
        let request: NativeSourceProviderRequest
        let preflight: ProviderRequestPreflight
        let capabilities: ProviderCapabilities
    }

    private func prepareSourceDerivedDispatch(sideEffect: RunSideEffectIntent, run: AutonomousRunRecord,
        sessionID: String, round: Int, previousResponseID: String?, input: Data, tools: [Data],
        toolSchemaSHA256: String, automatic: AutomaticContinuationDispatch?,
        provider: any ManagedModelProviderObservedDispatching, capabilities: ProviderCapabilities,
        lease: RunLease) async throws -> SourceDerivedDispatch {
        let key = automatic?.record.intent.idempotencyKey ?? "\(sideEffect.idempotencyKey):round:\(round)"
        let turnID = automatic?.record.intent.turnID ?? Self.stableUUID("turn:\(key)")
        let kind = automatic?.record.intent.kind ?? (previousResponseID == nil ? .initialRoot : (round == 0 ? .normalContinuation : .toolContinuation))
        let operationID: UUID?
        if let automatic { operationID = automatic.record.intent.operationID }
        else {
            operationID = try await operationForTurnReplay(turnID: turnID, sideEffect: sideEffect,
                run: run, sessionID: sessionID, kind: kind, idempotencyKey: key,
                previousResponseID: previousResponseID, input: input, toolSchemaSHA256: toolSchemaSHA256, lease: lease)
        }
        let intent = ProviderTurnIntent(turnID: turnID, runID: run.runID, sessionID: sessionID,
            operationID: operationID, projectID: run.projectID, projectGeneration: run.projectGeneration,
            kind: kind, idempotencyKey: key, previousResponseID: previousResponseID,
            inputSHA256: JSONSupport.sha256Hex(input),
            toolSchemaSHA256: automatic == nil ? toolSchemaSHA256 : automatic?.record.intent.toolSchemaSHA256)
        let record = try await repository.persistProviderTurnIntent(intent, lease: lease)
        let request: NativeSourceProviderRequest
        if let previousResponseID {
            request = try .continuation(.init(operationID: operationID ?? turnID, idempotencyKey: key,
                modelKey: capabilities.modelKey, previousResponseID: previousResponseID, input: input, tools: tools))
        } else {
            request = try .root(.init(operationID: operationID ?? turnID, idempotencyKey: key,
                modelKey: capabilities.modelKey, input: String(decoding: input, as: UTF8.self), tools: tools))
        }
        if let retained = try await repository.sourceDerivedProviderTurnPreflight(turnID: turnID, lease: lease) {
            guard retained.intent == intent else { throw AutonomyError.intentConflict }
            return .init(record: record, intent: intent, request: request,
                preflight: retained.preflight, capabilities: retained.capabilities)
        }
        guard record.state == .intent else { throw NativeSourceConversationError.integrityFailure }
        let preflight: ProviderRequestPreflight
        switch request {
        case .root(let value): preflight = try await provider.preflightRoot(value)
        case .continuation(let value): preflight = try await provider.preflightContinuation(value)
        }
        guard preflight.serializedInputByteCount != nil else { throw NativeSourceConversationError.unsupportedProvider }
        let observed = round == 0 ? capabilities : try await provider.probe()
        guard observed.providerID == capabilities.providerID, observed.modelKey == capabilities.modelKey,
              observed.statefulResponses, observed.customTools else { throw NativeSourceConversationError.unsupportedProvider }
        return .init(record: record, intent: intent, request: request, preflight: preflight, capabilities: observed)
    }

    private func dispatchSourceDerivedTurn(_ dispatch: SourceDerivedDispatch,
        provider: any ManagedModelProviderObservedDispatching, run: AutonomousRunRecord,
        lease: RunLease) async throws -> ProviderTurn {
        if dispatch.record.state == .intent {
            let actual: ProviderRequestPreflight
            switch dispatch.request {
            case .root(let request): actual = try await provider.preflightRoot(request)
            case .continuation(let request): actual = try await provider.preflightContinuation(request)
            }
            guard actual == dispatch.preflight else { throw AutonomyError.intentConflict }
        }
        let admission = try await repository.beginSourceDerivedProviderTurn(intent: dispatch.intent,
            preflight: dispatch.preflight, capabilities: dispatch.capabilities, lease: lease)
        switch admission {
        case .completed, .lookupOnly:
            guard let recovered = try await provider.lookupRecorded(idempotencyKey: dispatch.intent.idempotencyKey) else {
                throw NativeSourceConversationError.outcomeUnknown
            }
            try validateSourceDerivedResult(recovered, dispatch: dispatch)
            try Task.checkCancellation()
            _ = try await repository.validateAutonomousRunExecutionAdmission(run.runID)
            guard let retained = try await repository.sourceDerivedProviderTurnPreflight(
                turnID: dispatch.intent.turnID, lease: lease), retained.intent == dispatch.intent,
                retained.preflight == dispatch.preflight, retained.capabilities == dispatch.capabilities else {
                throw AutonomyError.intentConflict
            }
            if case .completed(let record) = admission {
                guard record.providerRequestID == recovered.requestID,
                      record.providerResponseID == recovered.responseID,
                      try Self.matchesStoredUsage(record.usageJSON, actual: recovered.usage) else {
                    throw AutonomyError.intentConflict
                }
            }
            if case .lookupOnly(let record) = admission {
                _ = try await repository.transitionProviderTurn(turnID: dispatch.intent.turnID,
                    expected: record.state, to: .completed, lease: lease,
                    providerRequestID: recovered.requestID, providerResponseID: recovered.responseID,
                    usageJSON: try Self.usageJSON(recovered.usage))
            }
            return recovered
        case .dispatch: break
        }
        let operationID = dispatch.intent.operationID ?? dispatch.intent.turnID
        activeRequests[run.runID] = .init(provider: provider, requestID: operationID.uuidString.lowercased())
        defer { activeRequests.removeValue(forKey: run.runID) }
        do {
            _ = try await repository.validateAutonomousRunExecutionAdmission(run.runID)
            let turn: ProviderTurn
            switch dispatch.request {
            case .root(let request): turn = try await provider.createRoot(request, observedCapabilities: dispatch.capabilities)
            case .continuation(let request): turn = try await provider.continueSession(request, observedCapabilities: dispatch.capabilities)
            }
            try validateSourceDerivedResult(turn, dispatch: dispatch)
            _ = try await repository.transitionProviderTurn(turnID: dispatch.intent.turnID, expected: .submitted,
                to: .completed, lease: lease, providerRequestID: turn.requestID, providerResponseID: turn.responseID,
                usageJSON: try Self.usageJSON(turn.usage))
            return turn
        } catch {
            _ = try? await repository.transitionProviderTurn(turnID: dispatch.intent.turnID,
                expected: .submitted, to: .ambiguous, lease: lease,
                errorCode: "source_provider_outcome_unknown", errorSummary: "The submitted provider request requires recorded receipt reconciliation")
            throw error
        }
    }

    private func validateSourceDerivedResult(_ turn: ProviderTurn, dispatch: SourceDerivedDispatch) throws {
        guard turn.completed,
              turn.requestID == (dispatch.intent.operationID ?? dispatch.intent.turnID).uuidString.lowercased(),
              turn.previousResponseID == dispatch.intent.previousResponseID,
              turn.providerID == dispatch.capabilities.providerID,
              turn.modelKey == dispatch.capabilities.modelKey,
              turn.providerVersion == dispatch.capabilities.providerVersion,
              turn.providerInstanceID == dispatch.capabilities.providerInstanceID else {
            throw AutonomyError.intentConflict
        }
    }

    private func dispatchProviderTurn(
        record: inout ProviderTurnRecord,
        provider: any ManagedModelProvider,
        run: AutonomousRunRecord,
        modelKey: String,
        input: Data,
        tools: [Data],
        lease: RunLease,
        sourceDispatch: SourceDerivedDispatch? = nil
    ) async throws -> ProviderTurn {
        _ = try await repository.validateAutonomousRunExecutionAdmission(run.runID)
        if let sourceDispatch {
            guard let observed = provider as? any ManagedModelProviderObservedDispatching else {
                throw NativeSourceConversationError.unsupportedProvider
            }
            return try await dispatchSourceDerivedTurn(sourceDispatch, provider: observed, run: run, lease: lease)
        }
        if record.state == .completed {
            guard let recovered = try await provider.lookup(
                idempotencyKey: record.intent.idempotencyKey
            ) else {
                throw AutonomyError.invalidRequest(
                    "completed provider turn cannot be reconciled from its idempotency key"
                )
            }
            return recovered
        }
        switch record.state {
        case .intent:
            record = try await repository.transitionProviderTurn(
                turnID: record.intent.turnID,
                expected: .intent,
                to: .submitted,
                lease: lease
            )
        case .ambiguous, .retryWait:
            if let recovered = try await provider.lookup(
                idempotencyKey: record.intent.idempotencyKey
            ) {
                record = try await repository.transitionProviderTurn(
                    turnID: record.intent.turnID,
                    expected: record.state,
                    to: .completed,
                    lease: lease,
                    providerRequestID: recovered.requestID,
                    providerResponseID: recovered.responseID,
                    usageJSON: try Self.usageJSON(recovered.usage)
                )
                return recovered
            }
            record = try await repository.transitionProviderTurn(
                turnID: record.intent.turnID,
                expected: record.state,
                to: .submitted,
                lease: lease
            )
        case .submitted:
            if let recovered = try await provider.lookup(
                idempotencyKey: record.intent.idempotencyKey
            ) {
                record = try await repository.transitionProviderTurn(
                    turnID: record.intent.turnID,
                    expected: .submitted,
                    to: .completed,
                    lease: lease,
                    providerRequestID: recovered.requestID,
                    providerResponseID: recovered.responseID,
                    usageJSON: try Self.usageJSON(recovered.usage)
                )
                return recovered
            }
        case .streaming:
            if let recovered = try await provider.lookup(
                idempotencyKey: record.intent.idempotencyKey
            ) {
                record = try await repository.transitionProviderTurn(
                    turnID: record.intent.turnID,
                    expected: .streaming,
                    to: .completed,
                    lease: lease,
                    providerRequestID: recovered.requestID,
                    providerResponseID: recovered.responseID,
                    usageJSON: try Self.usageJSON(recovered.usage)
                )
                return recovered
            }
            throw AutonomyError.invalidRequest("streaming provider turn is not yet reconcilable")
        case .failed, .cancelled:
            throw AutonomyError.invalidRequest("provider turn is no longer executable")
        case .completed:
            fatalError("completed provider turn handled before switch")
        }

        let operationID = record.intent.operationID ?? record.intent.turnID
        activeRequests[run.runID] = ActiveProviderRequest(
            provider: provider,
            requestID: operationID.uuidString.lowercased()
        )
        defer { activeRequests.removeValue(forKey: run.runID) }
        do {
            _ = try await repository.validateAutonomousRunExecutionAdmission(run.runID)
            let turn: ProviderTurn
            if let previousResponseID = record.intent.previousResponseID {
                turn = try await provider.continueSession(ProviderContinuationRequest(
                    operationID: operationID,
                    idempotencyKey: record.intent.idempotencyKey,
                    modelKey: modelKey,
                    previousResponseID: previousResponseID,
                    input: input,
                    tools: tools
                ))
            } else {
                turn = try await provider.createRoot(ProviderRootRequest(
                    operationID: operationID,
                    idempotencyKey: record.intent.idempotencyKey,
                    modelKey: modelKey,
                    input: String(decoding: input, as: UTF8.self),
                    tools: tools
                ))
            }
            record = try await repository.transitionProviderTurn(
                turnID: record.intent.turnID,
                expected: .submitted,
                to: .completed,
                lease: lease,
                providerRequestID: turn.requestID,
                providerResponseID: turn.responseID,
                usageJSON: try Self.usageJSON(turn.usage)
            )
            return turn
        } catch {
            let providerFailure = error as? any ManagedProviderFailure
            let failureState: ProviderTurnState
            switch providerFailure?.managedProviderFailureDisposition {
            case .blockedConfiguration:
                // Configuration can be corrected in place. Preserve the exact turn
                // identity so an explicit resume reconciles before retrying it.
                failureState = .retryWait
            case .contextOverflow, .failedTerminal:
                failureState = .failed
            case .cancelled:
                // Cancellation can be manager shutdown or an operator control request.
                // Keep the idempotent turn reconcilable; the run coordinator owns the
                // durable run-state decision after it knows why execution stopped.
                failureState = .ambiguous
            case .waitingProvider, .failedRecoverable, nil:
                // A transport outage or incomplete terminal response may have happened
                // after the provider accepted the idempotent operation. Reconcile it.
                failureState = .ambiguous
            }
            _ = try? await repository.transitionProviderTurn(
                turnID: record.intent.turnID,
                expected: .submitted,
                to: failureState,
                lease: lease,
                errorCode: providerFailure?.managedProviderFailureCode
                    ?? "provider_submission_ambiguous",
                errorSummary: String(error.localizedDescription.prefix(2_048))
            )
            throw error
        }
    }

    private func requestInput(
        run: AutonomousRunRecord,
        previousResponseID: String?,
        continuationInput: Data?
    ) throws -> Data {
        if let continuationInput { return continuationInput }
        let prompt = Self.rootOrContinuationPrompt(for: run)
        guard previousResponseID != nil else { return Data(prompt.utf8) }
        return try Self.canonicalData([[
            "type": "message",
            "role": "user",
            "content": prompt,
        ]])
    }

    private static func rootOrContinuationPrompt(for run: AutonomousRunRecord) -> String {
        var lines = [
            "You are executing a Forge Conductor managed autonomous run.",
            "Run: \(run.runID.description)",
            "Project: \(run.projectID.description) generation \(run.projectGeneration.rawValue)",
            "Mission: \(run.mission)",
            "Use only the supplied project-bound tools. Do not claim completion without evidence.",
        ]
        if let phase = run.specification.work.currentPhase { lines.append("Current phase: \(phase)") }
        if let item = run.specification.work.workItem { lines.append("Work item: \(item)") }
        if let next = run.specification.work.nextAction { lines.append("Next action: \(next)") }
        lines.append("Completion gates: \(run.specification.completionGates.joined(separator: ", "))")
        lines.append(
            "When work is ready for deterministic validation, respond with exactly "
                + "{\"forge_run_status\":\"completion_requested\",\"summary\":\"bounded summary\"}. "
                + "The manager independently executes the registered completion gates."
        )
        return lines.joined(separator: "\n")
    }

    private struct CompletionRequest {
        let summary: String
    }

    private static func completionRequest(from messages: [String]) -> CompletionRequest? {
        for message in messages.reversed() {
            guard let data = message.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["forge_run_status"] as? String == "completion_requested",
                  let summary = object["summary"] as? String,
                  !summary.isEmpty else { continue }
            return CompletionRequest(
                summary: String(summary.prefix(2_048))
            )
        }
        return nil
    }

    private static func arguments(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ManagedModelProviderContractError.invalidValue(
                "provider tool arguments must be a JSON object"
            )
        }
        return object
    }

    private static func canonicalData(_ value: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(value) else {
            throw ManagedModelProviderContractError.invalidValue(
                "managed provider input is not representable JSON"
            )
        }
        return try JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    /// Stored rows may use an older encoder's object order. Compare every
    /// validated usage field without rewriting the original observed receipt.
    private static func matchesStoredUsage(_ json: String?, actual: ProviderUsage?) throws -> Bool {
        guard let json else { return actual == nil }
        guard let actual, !json.isEmpty, json.utf8.count <= 64 * 1_024 else { return false }
        let decoded = try JSONDecoder().decode(ProviderUsage.self, from: Data(json.utf8))
        let validated = try ProviderUsage(capacity: decoded.capacity, inputTokens: decoded.inputTokens,
            outputTokens: decoded.outputTokens, totalTokens: decoded.totalTokens,
            source: decoded.source, confidence: decoded.confidence)
        return validated == actual
    }

    private static func usageJSON(_ usage: ProviderUsage?) throws -> String? {
        guard let usage else { return nil }
        let data = try JSONEncoder().encode(usage)
        return String(decoding: data, as: UTF8.self)
    }

    private static func toolSchemaSHA256(_ tools: [Data]) -> String {
        JSONSupport.sha256Hex(tools.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n"))
    }

    private static func boundedAssistantSummary(_ messages: [String]) -> String? {
        guard !messages.isEmpty else { return nil }
        let joined = messages.joined(separator: "\n")
        guard !joined.isEmpty else { return nil }
        var output = ""
        output.reserveCapacity(min(joined.count, maximumAssistantSummaryBytes))
        for scalar in joined.unicodeScalars {
            let candidate = output + String(scalar)
            if candidate.utf8.count > maximumAssistantSummaryBytes { break }
            output = candidate
        }
        return output
    }

    private static func stronger(
        _ lhs: ContextBudgetAction,
        _ rhs: ContextBudgetAction
    ) -> ContextBudgetAction {
        lhs.severity >= rhs.severity ? lhs : rhs
    }

    private static func stableUUID(_ value: String) -> UUID {
        let digest = JSONSupport.sha256Hex(value)
        return UUID(uuidString:
            "\(digest.prefix(8))-\(digest.dropFirst(8).prefix(4))-\(digest.dropFirst(12).prefix(4))-\(digest.dropFirst(16).prefix(4))-\(digest.dropFirst(20).prefix(12))"
        )!
    }
}
