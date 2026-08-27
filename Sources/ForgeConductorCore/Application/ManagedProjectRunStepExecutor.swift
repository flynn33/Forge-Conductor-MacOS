// Managed provider loop with durable turn and tool intents for one project-scoped run.

import Foundation

public protocol ManagedRunBudgetEvaluating: Sendable {
    func evaluateBeforeProviderTurn(
        run: AutonomousRunRecord,
        sessionID: String,
        capabilities: ProviderCapabilities,
        serializedInputBytes: Int
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

    private var providers: [String: any ManagedModelProvider] = [:]
    private var activeRequests: [RunID: ActiveProviderRequest] = [:]
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
    }

    public func prepareNextStep(for run: AutonomousRunRecord) async throws -> RunSideEffectIntent? {
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
        switch intent.kind {
        case .continuity:
            yieldedAfterStep = true
            return try await continuity.executeContinuityStep(
                intent: intent,
                run: run,
                context: context,
                lease: lease
            )
        case .providerTurn:
            let outcome = try await executeProviderStep(intent, run: run, lease: lease)
            yieldedAfterStep = true
            return outcome
        case .toolInvocation, .runtimeJob, .completionValidation:
            throw AutonomyError.invalidRequest(
                "managed step executor received an unsupported top-level side-effect kind"
            )
        }
    }

    public func cancel(runID: RunID) async {
        if let active = activeRequests.removeValue(forKey: runID) {
            await active.provider.cancel(requestID: active.requestID)
        }
    }

    private func executeProviderStep(
        _ sideEffect: RunSideEffectIntent,
        run: AutonomousRunRecord,
        lease: RunLease
    ) async throws -> ProjectRunStepOutcome {
        guard let adapterID = run.adapterID, !adapterID.isEmpty,
              let expectedProviderID = run.providerID, !expectedProviderID.isEmpty,
              let modelKey = run.modelKey, !modelKey.isEmpty else {
            return .failedTerminal(
                code: "managed_provider_configuration_missing",
                summary: "Run is missing its adapter, provider, or model identity"
            )
        }
        let provider = try resolvedProvider(adapterID: adapterID)
        let capabilities = try await provider.probe()
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
            let beforeAction = try await budget.evaluateBeforeProviderTurn(
                run: run,
                sessionID: sessionID,
                capabilities: capabilities,
                serializedInputBytes: input.count + tools.reduce(0) { $0 + $1.count }
            )
            strongestAction = Self.stronger(strongestAction, beforeAction)
            // A successor is not accepted until this exact turn is durably reserved.
            // Dispatch it before acting on another rollover signal so recovery cannot
            // create an endless chain of fresh sessions without consuming the handoff.
            if automatic == nil,
               strongestAction == .rollover || strongestAction == .emergency {
                work.metadata["provider_response_id"] = previousResponseID
                return .rolloverRequired(work)
            }

            var record: ProviderTurnRecord
            if let automatic {
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
                    operationID: run.activeOperationID,
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
                    lease: lease
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

            let afterAction = try await budget.observeProviderTurn(
                turn,
                run: run,
                sessionID: sessionID,
                capabilities: capabilities
            )
            strongestAction = Self.stronger(strongestAction, afterAction)

            guard !turn.toolCalls.isEmpty else {
                if strongestAction == .rollover || strongestAction == .emergency {
                    return .rolloverRequired(work)
                }
                if strongestAction == .checkpoint { return .checkpointRequired(work) }
                if let request = Self.completionRequest(from: turn.messages) {
                    let declaredGates = Set(run.specification.completionGates)
                    for (gate, proof) in request.gateEvidence
                    where declaredGates.contains(gate)
                        && work.evidenceReferences.contains(proof) {
                        work.metadata["completion_gate.\(gate).proof_sha256"] = proof
                    }
                    return .completionRequestedWithWork(request.summary, work)
                }
                work.nextAction = "Continue the mission from provider response \(turn.responseID)"
                return .continued(work)
            }

            var outputs: [[String: Any]] = []
            outputs.reserveCapacity(turn.toolCalls.count)
            for call in turn.toolCalls {
                let arguments = try Self.arguments(call.argumentsJSON)
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
                let toolAction = try await budget.observeToolResult(
                    serializedBytes: output.utf8.count,
                    providerResponseID: turn.responseID,
                    run: run,
                    sessionID: sessionID,
                    capabilities: capabilities
                )
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

    private func dispatchProviderTurn(
        record: inout ProviderTurnRecord,
        provider: any ManagedModelProvider,
        run: AutonomousRunRecord,
        modelKey: String,
        input: Data,
        tools: [Data],
        lease: RunLease
    ) async throws -> ProviderTurn {
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
                + "{\"forge_run_status\":\"completion_requested\",\"summary\":\"bounded summary\","
                + "\"gate_evidence\":{\"gate name\":\"persisted tool-result sha256\"}}."
        )
        return lines.joined(separator: "\n")
    }

    private struct CompletionRequest {
        let summary: String
        let gateEvidence: [String: String]
    }

    private static func completionRequest(from messages: [String]) -> CompletionRequest? {
        for message in messages.reversed() {
            guard let data = message.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["forge_run_status"] as? String == "completion_requested",
                  let summary = object["summary"] as? String,
                  !summary.isEmpty else { continue }
            let rawEvidence = object["gate_evidence"] as? [String: Any] ?? [:]
            let evidence = rawEvidence.reduce(into: [String: String]()) { result, entry in
                guard let value = entry.value as? String,
                      value.count == 64,
                      value.allSatisfy(\.isHexDigit),
                      entry.key.utf8.count <= 256 else { return }
                result[entry.key] = value.lowercased()
            }
            return CompletionRequest(
                summary: String(summary.prefix(2_048)),
                gateEvidence: evidence
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
