// Advances one managed-autonomy rollover through the durable V2 state machine.

import Foundation

/// Test-only termination seams for the documented managed-rollover crash matrix.
/// Several logical host boundaries are co-located by the atomic V2 adapter call, but
/// retain distinct identities so each acceptance obligation remains explicit.
public enum ManagedContinuityCrashPoint: String, CaseIterable, Sendable {
    case checkpointIntent
    case handoffPersistence
    case successorRequestIntent
    case providerRootSideEffect
    case candidateSessionPersistence
    case bootstrapRequest
    case providerBootstrapResponse
    case acknowledgementPersistence
    case successorAcceptance
    case predecessorFence
    case continuationEnqueue
    case continuationSideEffect
}

public enum ManagedContinuityWorkerError: Error, LocalizedError, Sendable {
    case injectedCrash(ManagedContinuityCrashPoint)

    public var errorDescription: String? {
        switch self {
        case .injectedCrash(let point):
            "Injected managed-continuity crash at \(point.rawValue)"
        }
    }
}

public protocol ManagedContinuityHandoffBuilding: Sendable {
    func buildHandoff(
        operationID: UUID,
        handoffID: UUID,
        bootstrapNonce: String,
        run: AutonomousRunRecord,
        project: ProjectControlRecord,
        predecessor: ProviderSessionRecord,
        actionRequest: ContextBudgetActionRequest,
        observation: ContextBudgetObservation
    ) throws -> ContinuityHandoffV2
}

public struct DefaultManagedContinuityHandoffBuilder: ManagedContinuityHandoffBuilding, Sendable {
    public init() {}

    public func buildHandoff(
        operationID: UUID,
        handoffID: UUID,
        bootstrapNonce: String,
        run: AutonomousRunRecord,
        project: ProjectControlRecord,
        predecessor: ProviderSessionRecord,
        actionRequest: ContextBudgetActionRequest,
        observation: ContextBudgetObservation
    ) throws -> ContinuityHandoffV2 {
        guard actionRequest.continuityOperationID == operationID,
              actionRequest.identity.runID == run.runID,
              actionRequest.identity.projectID == run.projectID,
              actionRequest.identity.projectGeneration == run.projectGeneration,
              actionRequest.identity.sessionID == predecessor.sessionID,
              observation.observationID == actionRequest.observationID,
              observation.identity == actionRequest.identity,
              predecessor.runID == run.runID,
              predecessor.projectID == run.projectID,
              predecessor.projectGeneration == run.projectGeneration,
              predecessor.status == .active || predecessor.status == .fencing
                || predecessor.status == .fenced || predecessor.status == .sealed,
              run.continuityMode == .managedAutonomous else {
            throw ProjectMemoryError.conflict("managed handoff identities do not match")
        }
        guard run.specification.allowedTools.count <= ContinuityHandoffV2.maximumListItems,
              run.specification.completionGates.count <= ContinuityHandoffV2.maximumListItems,
              run.specification.work.evidenceReferences.count <= ContinuityHandoffV2.maximumListItems else {
            throw ProjectMemoryError.payloadTooLarge("managed handoff list exceeds its V2 bound")
        }
        let phase = run.specification.work.currentPhase ?? "managed-autonomy"
        let workItem = run.specification.work.workItem
            ?? run.assignmentID
            ?? run.runID.description
        let currentSummary = run.specification.work.nextAction ?? run.mission
        let nextAction = run.specification.work.nextAction ?? "Continue the managed mission"
        let constraints = run.specification.allowedTools.map { "Allowed tool: \($0)" }
        let dirtySummary = Self.stringArray(
            run.specification.work.metadata["git_dirty_summary"]
        )
        let branch = run.specification.work.metadata["git_branch"] ?? ""
        let commit = run.specification.work.metadata["git_commit"] ?? ""
        let providerResponse: Any = predecessor.providerResponseID ?? NSNull()
        let assignment: Any = run.assignmentID ?? NSNull()
        return try ContinuityHandoffV2(
            handoffID: handoffID.uuidString.lowercased(),
            operationID: operationID.uuidString.lowercased(),
            project: [
                "project_id": run.projectID.description,
                "generation": run.projectGeneration.rawValue,
                "display_name": project.displayName,
                "repository_root": project.canonicalRoot.path,
                "branch": branch,
                "commit": commit,
                "dirty_summary": dirtySummary,
            ],
            run: [
                "run_id": run.runID.description,
                "continuity_mode": run.continuityMode.rawValue,
                "assignment_id": assignment,
            ],
            predecessorSession: [
                "session_id": predecessor.sessionID,
                "provider_id": predecessor.providerID,
                "provider_response_id": providerResponse,
                "adapter_id": predecessor.adapterID,
                "model": predecessor.modelKey,
            ],
            mission: run.mission,
            constraints: constraints,
            currentWork: [
                "phase_id": phase,
                "work_item_id": workItem,
                "summary": currentSummary,
                "active_files": Self.stringArray(
                    run.specification.work.metadata["active_files"]
                ),
            ],
            validation: [
                "passed_gates": [] as [String],
                "open_gates": run.specification.completionGates,
                "commands": [] as [[String: Any]],
            ],
            nextActions: [[
                "order": 0,
                "action": nextAction,
                "command": "",
                "success_condition": "The next managed step commits a durable outcome",
                "replay_class": "reconciled",
            ]],
            contextBudget: [
                "capacity": observation.capacity,
                "used": observation.used,
                "reserved": observation.fixedReserve,
                "remaining": observation.remaining,
                "source": observation.source.rawValue,
                "confidence": observation.confidence,
                "action": actionRequest.requestedAction.rawValue,
                "trigger": actionRequest.reason,
            ],
            bootstrap: [
                "nonce": bootstrapNonce,
                "acknowledgement_contract_version": 2,
            ]
        ).validated()
    }

    private static func stringArray(_ value: String?) -> [String] {
        guard let value, !value.isEmpty else { return [] }
        return value.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}

public actor ManagedContinuityWorker: ManagedRunContinuityExecuting {
    public typealias AdapterResolver = @Sendable (
        _ adapterID: String
    ) throws -> any SessionHostAdapterV2

    public static let automaticContinuationPrompt =
        "Continue from the acknowledged durable handoff. Execute the first open action without replaying completed work."

    /// Exact provider input committed by the rollover transaction and later dispatched
    /// by the managed provider loop. Callers must not rebuild or re-encode this payload.
    public static func automaticContinuationInput() throws -> Data {
        try ForgeJSONCanonicalizationV1.data(from: [[
            "type": "message",
            "role": "user",
            "content": automaticContinuationPrompt,
        ]])
    }

    private let repository: ProjectControlPlaneRepository
    private let engine: ContinuityStateEngine
    private let adapterResolver: AdapterResolver
    private let handoffBuilder: any ManagedContinuityHandoffBuilding
    private let crashAfter: ManagedContinuityCrashPoint?

    public init(
        repository: ProjectControlPlaneRepository,
        memory: ProjectMemoryService,
        adapterResolver: @escaping AdapterResolver,
        handoffBuilder: any ManagedContinuityHandoffBuilding = DefaultManagedContinuityHandoffBuilder(),
        crashAfter: ManagedContinuityCrashPoint? = nil
    ) {
        self.repository = repository
        self.engine = ContinuityStateEngine(memory: memory)
        self.adapterResolver = adapterResolver
        self.handoffBuilder = handoffBuilder
        self.crashAfter = crashAfter
    }

    public func executeContinuityStep(
        intent: RunSideEffectIntent,
        run: AutonomousRunRecord,
        context: ToolInvocationContext,
        lease: RunLease
    ) async throws -> ProjectRunStepOutcome {
        guard intent.kind == .continuity,
              run.continuityMode == .managedAutonomous,
              lease.runID == run.runID,
              context.runID == run.runID,
              context.projectID == run.projectID,
              context.projectGeneration == run.projectGeneration else {
            throw AutonomyError.invalidRequest("managed continuity scope is invalid")
        }
        guard let request = try await actionRequest(for: run),
              request.identity.projectID == run.projectID,
              request.identity.projectGeneration == run.projectGeneration,
              let observation = try await repository.contextBudgetObservation(
                observationID: request.observationID
              ),
              let project = try await repository.project(run.projectID) else {
            throw ContextBudgetError.currentObservationRequired
        }
        try crashIfRequested(.checkpointIntent)

        var operation = try await preparedOperation(
            run: run,
            project: project,
            request: request,
            observation: observation
        )
        try crashIfRequested(.handoffPersistence)
        let projectID = run.projectID.description
        guard operation.operationID.caseInsensitiveCompare(
            request.continuityOperationID.uuidString
        ) == .orderedSame else {
            throw ProjectMemoryError.conflict("budget request names a different V2 operation")
        }
        let checkpointed = try await fulfillBudgetStage(
            requestID: request.requestID,
            stage: .checkpoint,
            lease: lease
        )
        if run.state == .checkpointing && checkpointed.requestedAction == .checkpoint {
            var work = run.specification.work
            work.metadata["continuity_operation_id"] = operation.operationID
            work.metadata["continuity_handoff_id"] = operation.handoffID
            work.metadata["continuity_handoff_sha256"] = try requiredHandoff(
                operation: operation,
                projectID: projectID
            ).contentSHA256
            return .continued(work)
        }
        if run.state == .checkpointing {
            var work = run.specification.work
            work.metadata["continuity_operation_id"] = operation.operationID
            return .rolloverRequired(work)
        }
        guard run.state == .rollingOver || run.state == .recovering else {
            throw AutonomyError.invalidRequest("run is not in a continuity execution state")
        }

        let handoff = try requiredHandoff(operation: operation, projectID: projectID)
        let operationID = request.continuityOperationID
        let commandType: ContinuityCommandType = checkpointed.requestedAction == .emergency
            ? .emergencyRollover : .rollover
        let queued = try await repository.enqueueContinuityCommand(
            ContinuityCommandRequest(
                operationID: operationID,
                runID: run.runID,
                projectID: run.projectID,
                projectGeneration: run.projectGeneration,
                type: commandType,
                requestedBy: "managed_continuity_worker",
                reason: checkpointed.reason,
                idempotencyKey: "continuity-command:\(operationID.uuidString.lowercased())",
                payloadSHA256: handoff.contentSHA256
            )
        )
        guard let claimed = try await repository.claimContinuityCommand(
            runID: run.runID,
            operationID: operationID,
            lease: lease
        ) else {
            throw ContinuityCommandQueueError.claimConflict
        }
        var command = claimed
        if command.state == .claimed {
            command = try await repository.transitionContinuityCommand(
                commandID: command.commandID,
                expected: .claimed,
                to: .running
            )
        }
        guard command.commandID == queued.commandID,
              command.state == .running || command.state == .completed else {
            throw ContinuityCommandQueueError.invalidCommand(
                "run-scoped rollover command is not executable"
            )
        }

        let predecessor = try await requiredProviderSession(operation.predecessorSessionID)
        if operation.state != .predecessorSealed, predecessor.status == .active {
            _ = try await repository.fenceProviderSessionForContinuity(
                runID: run.runID,
                operationID: operationID,
                predecessorSessionID: operation.predecessorSessionID,
                lease: lease
            )
            try crashIfRequested(.predecessorFence)
        }

        let adapter: (any SessionHostAdapterV2)?
        if operation.state.isTerminal {
            adapter = nil
        } else {
            let resolved = try adapterResolver(operation.adapterID)
            try await validateCapabilities(resolved, operation: operation)
            adapter = resolved
        }
        while !operation.state.isTerminal {
            switch operation.state {
            case .active, .checkpointPreparing:
                throw ProjectMemoryError.integrityFailure(
                    "rollover command preceded its durable V2 checkpoint"
                )
            case .checkpointPersisted:
                operation = try engine.transitionV2(
                    projectID: projectID,
                    operationID: operation.operationID,
                    expected: .checkpointPersisted,
                    to: .successorRequested,
                    evidence: "fresh_root_create_and_bootstrap_intent"
                )
                try crashIfRequested(.successorRequestIntent)
            case .successorRequested:
                guard let adapter else { throw ContinuityRunError.hostCapabilityUnavailable }
                let receipt = try await reconcileReceipt(
                    adapter: adapter,
                    operation: operation,
                    handoff: handoff,
                    run: run,
                    predecessor: predecessor,
                    lease: lease,
                    permitCreate: true
                )
                operation = try engine.transitionV2(
                    projectID: projectID,
                    operationID: operation.operationID,
                    expected: .successorRequested,
                    to: .successorCreated,
                    successorSessionID: receipt.internalSessionID,
                    successorProviderResponseID: receipt.providerResponseID,
                    evidence: handoff.contentSHA256
                )
            case .successorCreated:
                guard let adapter else { throw ContinuityRunError.hostCapabilityUnavailable }
                _ = try await reconcileReceipt(
                    adapter: adapter,
                    operation: operation,
                    handoff: handoff,
                    run: run,
                    predecessor: predecessor,
                    lease: lease,
                    permitCreate: false
                )
                operation = try engine.transitionV2(
                    projectID: projectID,
                    operationID: operation.operationID,
                    expected: .successorCreated,
                    to: .successorBootstrapping,
                    evidence: "atomic_bootstrap_receipt_reconciled"
                )
            case .successorBootstrapping:
                guard let adapter else { throw ContinuityRunError.hostCapabilityUnavailable }
                let receipt = try await reconcileReceipt(
                    adapter: adapter,
                    operation: operation,
                    handoff: handoff,
                    run: run,
                    predecessor: predecessor,
                    lease: lease,
                    permitCreate: false
                )
                operation = try engine.acknowledgeV2(
                    projectID: projectID,
                    operationID: operation.operationID,
                    receipt: receipt
                )
                try crashIfRequested(.acknowledgementPersistence)
            case .successorAcknowledged:
                guard let successorSessionID = operation.successorSessionID,
                      let handoffUUID = UUID(uuidString: handoff.handoffID) else {
                    throw ProjectMemoryError.integrityFailure(
                        "acknowledged successor identity is incomplete"
                    )
                }
                let acceptance = ContinuitySuccessorAcceptance(
                    operationID: operationID,
                    runID: run.runID,
                    projectID: run.projectID,
                    projectGeneration: run.projectGeneration,
                    predecessorSessionID: operation.predecessorSessionID,
                    candidateSessionID: successorSessionID,
                    handoffID: handoffUUID,
                    handoffSHA256: handoff.contentSHA256,
                    bootstrapNonceSHA256: JSONSupport.sha256Hex(handoff.bootstrapNonce ?? ""),
                    automaticContinuationInputSHA256: JSONSupport.sha256Hex(
                        try Self.automaticContinuationInput()
                    ),
                    automaticContinuationIdempotencyKey:
                        "automatic-continuation:\(operationID.uuidString.lowercased())"
                )
                let accepted = try await repository.acceptContinuitySuccessor(
                    acceptance,
                    lease: lease
                )
                try crashIfRequested(.successorAcceptance)
                try crashIfRequested(.continuationEnqueue)
                operation = try engine.transitionV2(
                    projectID: projectID,
                    operationID: operation.operationID,
                    expected: .successorAcknowledged,
                    to: .predecessorSealed,
                    evidence: accepted.winner.sessionID
                )
            case .predecessorSealed:
                break
            }
        }

        guard let successorSessionID = operation.successorSessionID else {
            throw ProjectMemoryError.integrityFailure("sealed operation has no successor")
        }
        let completed: ContinuityCommand
        if command.state == .completed {
            completed = command
        } else {
            completed = try await repository.completeContinuitySuccessor(
                runID: run.runID,
                operationID: operationID,
                predecessorSessionID: operation.predecessorSessionID,
                successorSessionID: successorSessionID,
                commandID: command.commandID,
                lease: lease
            )
        }
        guard completed.state == .completed,
              try await repository.automaticContinuation(operationID: operationID) != nil else {
            throw ProjectMemoryError.integrityFailure(
                "sealed rollover lacks its automatic continuation intent"
            )
        }
        _ = try engine.markContinuationIssuedV2(
            projectID: projectID,
            operationID: operation.operationID
        )
        let finalRequest = try await fulfillBudgetStage(
            requestID: request.requestID,
            stage: checkpointed.requestedAction,
            lease: lease
        )
        var work = run.specification.work
        work.metadata["provider_session_id"] = successorSessionID
        work.metadata["provider_response_id"] = operation.successorProviderResponseID
        work.metadata["continuity_operation_id"] = operation.operationID
        work.metadata["continuity_handoff_id"] = operation.handoffID
        work.metadata["continuity_handoff_sha256"] = handoff.contentSHA256
        work.metadata["continuity_action"] = finalRequest.requestedAction.rawValue
        if let turn = try await repository.automaticContinuation(operationID: operationID) {
            work.metadata["automatic_continuation_turn_id"] = turn.intent.turnID.uuidString.lowercased()
        }
        return .continued(work)
    }

    private func actionRequest(
        for run: AutonomousRunRecord
    ) async throws -> ContextBudgetActionRequest? {
        if let operationID = run.activeOperationID,
           let exact = try await repository.contextBudgetActionRequest(
            runID: run.runID,
            continuityOperationID: operationID
           ), exact.isPending {
            return exact
        }
        return try await repository.pendingContextBudgetActionRequest(runID: run.runID)
    }

    private func preparedOperation(
        run: AutonomousRunRecord,
        project: ProjectControlRecord,
        request: ContextBudgetActionRequest,
        observation: ContextBudgetObservation
    ) async throws -> ContinuityOperationV2 {
        let projectID = run.projectID.description
        let operationID = request.continuityOperationID.uuidString.lowercased()
        if let existing = try engine.operationV2(projectID: projectID, operationID: operationID) {
            guard existing.projectGeneration == run.projectGeneration.rawValue,
                  existing.runID == run.runID.description,
                  existing.predecessorSessionID == request.identity.sessionID,
                  existing.budgetObservationID == observation.observationID.uuidString.lowercased()
                    || existing.budgetObservationID == nil else {
                throw ProjectMemoryError.conflict("V2 operation identity changed")
            }
            let handoff: ContinuityHandoffV2
            if let durable = try engine.handoffV2(
                projectID: projectID,
                handoffID: existing.handoffID
            ) {
                handoff = try durable.validated()
            } else {
                guard existing.state == .active || existing.state == .checkpointPreparing,
                      let handoffID = UUID(uuidString: existing.handoffID) else {
                    throw ProjectMemoryError.integrityFailure(
                        "advanced V2 operation is missing its durable handoff"
                    )
                }
                let predecessor = try await requiredProviderSession(
                    existing.predecessorSessionID
                )
                handoff = try handoffBuilder.buildHandoff(
                    operationID: request.continuityOperationID,
                    handoffID: handoffID,
                    bootstrapNonce: existing.bootstrapNonce,
                    run: run,
                    project: project,
                    predecessor: predecessor,
                    actionRequest: request,
                    observation: observation
                )
            }
            guard handoff.operationID.caseInsensitiveCompare(existing.operationID) == .orderedSame,
                  handoff.handoffID.caseInsensitiveCompare(existing.handoffID) == .orderedSame,
                  handoff.contentSHA256 == handoff.calculatedSHA256() else {
                throw ProjectMemoryError.integrityFailure(
                    "V2 recovery handoff does not match its operation"
                )
            }
            if existing.state == .active || existing.state == .checkpointPreparing {
                return try engine.prepareV2(
                    handoff: handoff,
                    predecessorSessionID: existing.predecessorSessionID,
                    predecessorProviderResponseID: existing.predecessorProviderResponseID,
                    adapterID: existing.adapterID,
                    idempotencyKey: existing.idempotencyKey,
                    budgetObservationID: existing.budgetObservationID
                )
            }
            return existing
        }
        if let active = try engine.activeOperationV2(projectID: projectID),
           active.operationID.caseInsensitiveCompare(operationID) != .orderedSame {
            throw ProjectMemoryError.conflict("another V2 rollover operation is active")
        }
        let predecessor = try await requiredProviderSession(request.identity.sessionID)
        let handoffID = Self.stableUUID("handoff:\(operationID)")
        let nonce = Self.bootstrapNonce()
        let handoff = try handoffBuilder.buildHandoff(
            operationID: request.continuityOperationID,
            handoffID: handoffID,
            bootstrapNonce: nonce,
            run: run,
            project: project,
            predecessor: predecessor,
            actionRequest: request,
            observation: observation
        )
        return try engine.prepareV2(
            handoff: handoff,
            predecessorSessionID: predecessor.sessionID,
            predecessorProviderResponseID: predecessor.providerResponseID,
            adapterID: predecessor.adapterID,
            idempotencyKey: "continuity-bootstrap:\(operationID)",
            budgetObservationID: observation.observationID.uuidString.lowercased()
        )
    }

    private func requiredHandoff(
        operation: ContinuityOperationV2,
        projectID: String
    ) throws -> ContinuityHandoffV2 {
        guard let handoff = try engine.handoffV2(
            projectID: projectID,
            handoffID: operation.handoffID
        ) else {
            throw ProjectMemoryError.integrityFailure("durable V2 handoff is missing")
        }
        return try handoff.validated()
    }

    private func requiredProviderSession(
        _ sessionID: String
    ) async throws -> ProviderSessionRecord {
        guard let session = try await repository.providerSession(sessionID) else {
            throw AutonomyError.providerSessionNotFound(sessionID)
        }
        return session
    }

    private func validateCapabilities(
        _ adapter: any SessionHostAdapterV2,
        operation: ContinuityOperationV2
    ) async throws {
        let capabilities = try await adapter.capabilitiesV2()
        guard adapter.identifier == operation.adapterID,
              capabilities.atomicCreateAndBootstrap,
              capabilities.freshRoot,
              capabilities.idempotencyLookup,
              capabilities.projectGenerationFencing else {
            throw ContinuityRunError.hostCapabilityUnavailable
        }
    }

    private func reconcileReceipt(
        adapter: any SessionHostAdapterV2,
        operation: ContinuityOperationV2,
        handoff: ContinuityHandoffV2,
        run: AutonomousRunRecord,
        predecessor: ProviderSessionRecord,
        lease: RunLease,
        permitCreate: Bool
    ) async throws -> BootstrapReceipt {
        var receipt = try await adapter.receipt(forIdempotencyKey: operation.idempotencyKey)
        if receipt == nil, permitCreate {
            guard let operationID = UUID(uuidString: operation.operationID),
                  let nonce = handoff.bootstrapNonce else {
                throw ProjectMemoryError.integrityFailure("V2 bootstrap identity is invalid")
            }
            receipt = try await adapter.createAndBootstrap(
                request: SessionCreationRequestV2(
                    operationID: operationID,
                    projectID: run.projectID,
                    projectGeneration: run.projectGeneration,
                    runID: run.runID,
                    predecessorSessionID: predecessor.sessionID,
                    modelKey: predecessor.modelKey,
                    idempotencyKey: operation.idempotencyKey
                ),
                handoffJSON: try handoff.encodedJSON(),
                challenge: BootstrapChallenge(nonce: nonce)
            )
            // Atomic V2 hosts expose root creation, bootstrap request, and bootstrap
            // response as one recoverable call. These logical crash boundaries are
            // therefore intentionally co-located after the idempotent receipt exists.
            try crashIfRequested(.providerRootSideEffect)
            try crashIfRequested(.bootstrapRequest)
            try crashIfRequested(.providerBootstrapResponse)
        }
        guard let receipt else {
            throw ProjectMemoryError.integrityFailure(
                "successor receipt cannot be reconciled by idempotency key"
            )
        }
        try validateReceipt(
            receipt,
            adapter: adapter,
            operation: operation,
            handoff: handoff,
            run: run,
            predecessor: predecessor
        )
        try await repository.reserveProviderSession(
            ProviderSessionIntent(
                sessionID: receipt.internalSessionID,
                runID: run.runID,
                projectID: run.projectID,
                projectGeneration: run.projectGeneration,
                providerID: predecessor.providerID,
                adapterID: receipt.adapterID,
                modelKey: receipt.modelKey,
                providerResponseID: receipt.providerResponseID,
                predecessorSessionID: predecessor.sessionID,
                handoffID: receipt.acknowledgement.handoffID,
                operationID: receipt.acknowledgement.operationID,
                idempotencyKey: operation.idempotencyKey,
                bootstrapNonceSHA256: JSONSupport.sha256Hex(receipt.acknowledgement.nonce),
                handoffSHA256: receipt.acknowledgement.handoffSHA256,
                status: .candidate,
                accepted: false,
                contextCapacity: receipt.usage?.capacity ?? predecessor.contextCapacity
            ),
            lease: lease
        )
        try crashIfRequested(.candidateSessionPersistence)
        return receipt
    }

    private func validateReceipt(
        _ receipt: BootstrapReceipt,
        adapter: any SessionHostAdapterV2,
        operation: ContinuityOperationV2,
        handoff: ContinuityHandoffV2,
        run: AutonomousRunRecord,
        predecessor: ProviderSessionRecord
    ) throws {
        try receipt.acknowledgement.validate(handoff: handoff)
        let session = receipt.internalSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        let response = receipt.providerResponseID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard receipt.adapterID == adapter.identifier,
              receipt.adapterID == operation.adapterID,
              receipt.modelKey == predecessor.modelKey,
              session == receipt.internalSessionID,
              response == receipt.providerResponseID,
              !session.isEmpty, session.utf8.count <= 1_024,
              !response.isEmpty, response.utf8.count <= 2_048,
              session != predecessor.sessionID,
              receipt.acknowledgement.projectID == run.projectID,
              receipt.acknowledgement.projectGeneration == run.projectGeneration,
              receipt.acknowledgement.runID == run.runID,
              ISO8601.date(from: receipt.createdAt) != nil,
              receipt.usage.map({ $0.capacity > 0 && $0.used >= 0 && $0.reserved >= 0 }) ?? true else {
            throw ProjectMemoryError.conflict("bootstrap receipt identity is invalid")
        }
        if let successorSessionID = operation.successorSessionID {
            guard successorSessionID == receipt.internalSessionID,
                  operation.successorProviderResponseID == receipt.providerResponseID else {
                throw ProjectMemoryError.conflict("bootstrap receipt changed after successor creation")
            }
        }
    }

    private func fulfillBudgetStage(
        requestID: UUID,
        stage: ContextBudgetAction,
        lease: RunLease
    ) async throws -> ContextBudgetActionRequest {
        guard let current = try await repository.contextBudgetActionRequest(requestID: requestID) else {
            throw ContextBudgetError.actionRequestNotFound(requestID)
        }
        if (current.fulfilledAction?.severity ?? 0) >= stage.severity {
            return current
        }
        return try await repository.markContextBudgetActionFulfilled(
            requestID: requestID,
            expectedRevision: current.revision,
            fulfilledAction: stage,
            lease: lease
        )
    }

    private func crashIfRequested(_ point: ManagedContinuityCrashPoint) throws {
        if crashAfter == point { throw ManagedContinuityWorkerError.injectedCrash(point) }
    }

    private static func stableUUID(_ seed: String) -> UUID {
        let hash = JSONSupport.sha256Hex(seed)
        let value = String(hash.prefix(32))
        let formatted = "\(value.prefix(8))-\(value.dropFirst(8).prefix(4))-4\(value.dropFirst(13).prefix(3))-8\(value.dropFirst(17).prefix(3))-\(value.dropFirst(20).prefix(12))"
        return UUID(uuidString: formatted) ?? UUID()
    }

    private static func bootstrapNonce() -> String {
        (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
    }
}
