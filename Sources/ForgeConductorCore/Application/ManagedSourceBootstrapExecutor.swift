// Bridges native source bootstrap callbacks to the existing manager ledgers.

import Foundation

/// A single worker-owned exchange, with no scheduling loop or tool dispatcher.
/// Candidate authority never permits ordinary mission execution or activation.
actor ManagedSourceBootstrapExecutor: SourceBootstrapExecuting {
    private let repository: ProjectControlPlaneRepository
    private let engine: ContinuityStateEngine
    private let broker: ToolInvocationBroker
    private let continuity: ContextContinuityService
    private let request: SourceBootstrapRequest
    private var grant: ContinuityBootstrapGrant
    private var lease: RunLease
    private let policyResolver: PersistedManagedRunBudgetEvaluator.PolicyResolver
    private var retrieval: SourceBootstrapContextResult?
    private var rootResult: ProviderTurn?
    private var admittedCapabilities: [UUID: ProviderCapabilities] = [:]

    init(repository: ProjectControlPlaneRepository, engine: ContinuityStateEngine,
         broker: ToolInvocationBroker, continuity: ContextContinuityService,
         request: SourceBootstrapRequest, grant: ContinuityBootstrapGrant, lease: RunLease,
         policyResolver: @escaping PersistedManagedRunBudgetEvaluator.PolicyResolver) {
        self.repository = repository
        self.engine = engine
        self.broker = broker
        self.continuity = continuity
        self.request = request
        self.grant = grant
        self.lease = lease
        self.policyResolver = policyResolver
    }

    func prepareProviderTurn(intent: ProviderTurnIntent, input: Data, tools: [Data],
        capabilities: ProviderCapabilities, totalBootstrapInputBytes: Int
    ) async throws -> ProviderTurn? {
        try Task.checkCancellation()
        let selection = try await refreshAuthority()
        guard let run = try await repository.autonomousRun(request.runID),
              run.projectID == request.projectID, run.projectGeneration == request.projectGeneration,
              run.providerID == capabilities.providerID, run.modelKey == request.modelKey,
              capabilities.modelKey == request.modelKey, capabilities.statefulResponses,
              capabilities.customTools, tools.count == 1,
              intent.runID == request.runID, intent.sessionID == request.sessionID,
              intent.operationID == request.operationID, intent.kind == .bootstrap,
              intent.projectID == request.projectID, intent.projectGeneration == request.projectGeneration,
              intent.inputSHA256 == JSONSupport.sha256Hex(input) else {
            throw ContinuityIngressError.authorityMismatch
        }
        let toolObjects = try tools.map { try JSONSerialization.jsonObject(with: $0) }
        let schemas = try ForgeJSONCanonicalizationV1.data(from: toolObjects)
        guard intent.toolSchemaSHA256 == JSONSupport.sha256Hex(schemas),
              let tool = toolObjects.first as? [String: Any],
              tool["name"] as? String == (intent.previousResponseID == nil ? "context_get" : "forge_continuity_ack") else {
            throw ContinuityIngressError.authorityMismatch
        }
        // This is a conservative request preflight against the actual loaded
        // model. It is not fabricated provider usage or a predecessor budget.
        let configuration = try PersistedManagedRunBudgetEvaluator.configuration(
            capabilities: capabilities, selection: selection)
        let currentBytes = input.count.addingReportingOverflow(schemas.count)
        guard !currentBytes.overflow, totalBootstrapInputBytes >= currentBytes.partialValue else {
            throw ContextBudgetError.serializedInputTooLarge
        }
        let estimated = try ContextBudgetMath.estimateTokens(
            serializedBytes: totalBootstrapInputBytes, policy: configuration.policy)
        // The existing native transport caps each response at 4,096 tokens.
        // A smaller policy reserve cannot hide that possible wire output.
        // Fixed reserves already contain one policy response reserve.
        let responseBound = max(4_096, configuration.reserves.outputTokens)
        let responses = responseBound.multipliedReportingOverflow(by: 2)
        guard !responses.overflow else { throw ContextBudgetError.arithmeticOverflow }
        let additionalOutput = responses.partialValue - configuration.reserves.outputTokens
        let required = estimated.addingReportingOverflow(additionalOutput)
        guard !required.overflow, required.partialValue <= configuration.usableCapacity else {
            throw ContextBudgetError.insufficientUsableCapacity
        }
        if let previous = intent.previousResponseID {
            guard let rootResult, let usage = rootResult.usage,
                  rootResult.responseID == previous,
                  usage.source == .providerExact, usage.confidence == 1,
                  usage.capacity == capabilities.contextLength else {
                throw ContinuityIngressError.authorityMismatch
            }
            let retained = try PersistedManagedRunBudgetEvaluator.retainedTokensAfterResponse(usage)
            let added = try ContextBudgetMath.estimateTokens(serializedBytes: currentBytes.partialValue,
                policy: configuration.policy)
            let projected = retained.addingReportingOverflow(added)
            guard !projected.overflow else { throw ContextBudgetError.arithmeticOverflow }
            let remainingResponseReserve = responseBound - configuration.reserves.outputTokens
            let final = projected.partialValue.addingReportingOverflow(remainingResponseReserve)
            guard !final.overflow, final.partialValue <= configuration.usableCapacity else {
                throw ContextBudgetError.insufficientUsableCapacity
            }
        }
        _ = try await repository.reserveProviderSession(ProviderSessionIntent(
            sessionID: request.sessionID, runID: request.runID, projectID: request.projectID,
            projectGeneration: request.projectGeneration, providerID: capabilities.providerID,
            adapterID: run.adapterID ?? "", modelKey: request.modelKey,
            handoffID: request.handoffID, operationID: request.operationID,
            idempotencyKey: request.idempotencyKey,
            bootstrapNonceSHA256: JSONSupport.sha256Hex(request.bootstrapNonce.uuidString.lowercased()),
            handoffSHA256: request.handoffSHA256, status: .candidate, accepted: false
        ), lease: lease, bootstrapGrant: grant)
        let persisted = try await repository.persistProviderTurnIntent(intent, lease: lease, bootstrapGrant: grant)
        if intent.previousResponseID == nil {
            try await repository.preflightContinuityBootstrapRetrieval(
                grant: grant, rootTurnID: intent.turnID, lease: lease, policy: selection)
        }
        guard admittedCapabilities[intent.turnID] != nil || admittedCapabilities.count < 2 else {
            throw ContinuityIngressError.capacityExceeded("bootstrap admitted turns")
        }
        admittedCapabilities[intent.turnID] = capabilities
        if let completed = try await repository.continuityBootstrapProviderResult(
            grant: grant, turnID: intent.turnID, lease: lease) {
            return completed
        }
        switch persisted.state {
        case .intent, .ambiguous, .retryWait:
            _ = try await repository.transitionProviderTurn(turnID: intent.turnID,
                expected: persisted.state, to: .submitted, lease: lease, bootstrapGrant: grant)
        case .submitted, .streaming, .completed:
            // The provider's durable idempotency receipt reconciles a crash
            // between remote completion and the control-plane result commit.
            // Its unknown-outcome fence remains in force; no new key is issued.
            break
        case .failed, .cancelled:
            throw ContinuityIngressError.deliveryConflict
        }
        return nil
    }

    func retrieveContext(rootIntent: ProviderTurnIntent, rootTurn: ProviderTurn) async throws -> SourceBootstrapContextResult {
        try await refreshAuthority()
        guard rootIntent.previousResponseID == nil, rootTurn.previousResponseID == nil,
              rootTurn.toolCalls.count == 1, let call = rootTurn.toolCalls.first,
              call.name == "context_get",
              let arguments = try JSONSerialization.jsonObject(with: call.argumentsJSON) as? [String: Any] else {
            throw ContinuityIngressError.authorityMismatch
        }
        try await persistResult(intent: rootIntent, result: rootTurn)
        try await advanceRoot(responseID: rootTurn.responseID)
        let proof = try await broker.invokeProvisionalContextGet(
            BrokeredToolCall(providerCallID: call.callID, toolName: call.name, arguments: arguments),
            turnID: rootIntent.turnID, grant: grant, lease: lease,
            policySelection: currentPolicy(), continuity: continuity)
        let result = try SourceBootstrapContextResult(request: request, proof: proof)
        retrieval = result
        rootResult = rootTurn
        return result
    }

    func recordAcknowledgement(intent: ProviderTurnIntent, turn: ProviderTurn) async throws {
        try await refreshAuthority()
        guard let retrieval, turn.previousResponseID == retrieval.providerResponseID,
              intent.previousResponseID == retrieval.providerResponseID,
              turn.toolCalls.count == 1, let call = turn.toolCalls.first,
              call.name == "forge_continuity_ack" else { throw ContinuityIngressError.authorityMismatch }
        let acknowledgement = try JSONDecoder().decode(BootstrapAcknowledgementV2.self, from: call.argumentsJSON)
        guard acknowledgement.projectID == request.projectID,
              acknowledgement.projectGeneration == request.projectGeneration,
              acknowledgement.runID == request.runID, acknowledgement.operationID == request.operationID,
              acknowledgement.handoffID == request.handoffID, acknowledgement.handoffSHA256 == request.handoffSHA256,
              acknowledgement.nonce == request.bootstrapNonce.uuidString.lowercased(), acknowledgement.accepted else {
            throw ContinuityIngressError.authorityMismatch
        }
        let ackSHA = try ForgeJSONCanonicalizationV1.sha256Hex(of: JSONSerialization.jsonObject(with: call.argumentsJSON))
        try await persistResult(intent: intent, result: turn)
        let engine = self.engine, request = self.request
        _ = try await repository.withContinuityBootstrapAuthority(grant: grant, lease: lease) {
            guard let operation = try engine.sourceBootstrap(operationID: request.operationID,
                authorization: request.envelope.authorization), operation.successorSessionID == request.candidateID else {
                throw ContinuityIngressError.authorityMismatch
            }
            if operation.state == .successorAcknowledged {
                guard operation.successorProviderResponseID == turn.responseID,
                      operation.retrievalProofSHA256 == retrieval.proofSHA256,
                      operation.acknowledgementProofSHA256 == ackSHA else {
                    throw ContinuityIngressError.deliveryConflict
                }
                return operation
            }
            return try engine.transitionSourceBootstrap(operationID: request.operationID,
                authorization: request.envelope.authorization, expectedState: .successorBootstrapping,
                expectedChecksum: operation.stateChecksum, to: .successorAcknowledged,
                candidateID: request.candidateID, providerResponseID: turn.responseID,
                retrievalProofSHA256: retrieval.proofSHA256, acknowledgementProofSHA256: ackSHA)
        }
    }

    private func persistResult(intent: ProviderTurnIntent, result: ProviderTurn) async throws {
        guard let capabilities = admittedCapabilities[intent.turnID],
              result.providerID == capabilities.providerID,
              result.usage?.capacity == capabilities.contextLength,
              result.completed, result.finishReason == .toolCalls,
              result.usage?.source == .providerExact, result.usage?.confidence == 1,
              result.requestID == intent.turnID.uuidString.lowercased(),
              result.modelKey == request.modelKey, result.previousResponseID == intent.previousResponseID else {
            throw ContinuityIngressError.authorityMismatch
        }
        // Re-persisting the exact intent validates the current grant before any
        // receipt lookup or transition, including completed-result replay.
        let stored = try await repository.persistProviderTurnIntent(intent, lease: lease, bootstrapGrant: grant)
        if stored.state != .completed {
            guard [.submitted, .streaming, .ambiguous].contains(stored.state) else {
                throw ContinuityIngressError.deliveryConflict
            }
            let usageJSON = try result.usage.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
            _ = try await repository.transitionProviderTurn(turnID: intent.turnID, expected: stored.state,
                to: .completed, lease: lease, providerRequestID: result.requestID,
                providerResponseID: result.responseID, usageJSON: usageJSON, bootstrapGrant: grant)
        }
        try await repository.recordContinuityBootstrapProviderResult(
            grant: grant, turnID: intent.turnID, result: result, lease: lease)
    }

    private func advanceRoot(responseID: String) async throws {
        let engine = self.engine, request = self.request
        _ = try await repository.withContinuityBootstrapAuthority(grant: grant, lease: lease) {
            guard var operation = try engine.sourceBootstrap(operationID: request.operationID,
                authorization: request.envelope.authorization), operation.successorSessionID == request.candidateID else {
                throw ContinuityIngressError.authorityMismatch
            }
            if operation.state == .successorRequested {
                operation = try engine.transitionSourceBootstrap(operationID: request.operationID,
                    authorization: request.envelope.authorization, expectedState: operation.state,
                    expectedChecksum: operation.stateChecksum, to: .successorCreated,
                    candidateID: request.candidateID, providerResponseID: responseID)
            }
            if operation.state == .successorCreated {
                guard operation.successorProviderResponseID == responseID else { throw ContinuityIngressError.deliveryConflict }
                operation = try engine.transitionSourceBootstrap(operationID: request.operationID,
                    authorization: request.envelope.authorization, expectedState: operation.state,
                    expectedChecksum: operation.stateChecksum, to: .successorBootstrapping,
                    candidateID: request.candidateID)
            }
            guard operation.state == .successorAcknowledged
                || (operation.state == .successorBootstrapping && operation.successorProviderResponseID == responseID) else {
                throw ContinuityIngressError.deliveryConflict
            }
            return operation
        }
    }

    /// The existing coordinator owns lease renewal. This exchange may consume
    /// that renewal, but may never acquire another owner's lease or create a
    /// replacement candidate to recover an expired grant.
    @discardableResult
    private func refreshAuthority() async throws -> BudgetPolicySelection {
        try Task.checkCancellation()
        guard let current = try await repository.runLease(lease.runID),
              current.ownerID == lease.ownerID, current.epoch == lease.epoch else {
            throw AutonomyError.staleLease
        }
        let selection = try currentPolicy()
        _ = try await repository.validateContinuitySourceStartAuthority(
            acceptance: request.envelope.acceptance, lease: current, policySelection: selection)
        let renewed = try await repository.issueContinuityBootstrapGrant(
            envelope: grant.envelope, candidateID: grant.candidateID, lease: current)
        guard renewed.grantID == grant.grantID else { throw ContinuityIngressError.deliveryConflict }
        lease = current
        grant = renewed
        return selection
    }

    private func currentPolicy() throws -> BudgetPolicySelection {
        guard let generation = Int(exactly: request.projectGeneration.rawValue) else {
            throw ContextBudgetError.invalidPolicy
        }
        let selection = try policyResolver(BudgetPolicyScope(kind: .projectOverride,
            projectID: request.projectID.description, projectGeneration: generation))
        try ContinuityIngressAcceptanceReceipt.validatePolicy(selection, authorization: request.envelope.authorization)
        return selection
    }
}
