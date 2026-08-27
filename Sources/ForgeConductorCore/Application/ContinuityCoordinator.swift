// ContinuityCoordinator.swift
// What: Drives the durable project rollover state machine and crash recovery.
// How: Every intent is committed before host side effects and replayed idempotently.
// Why: A context rollover must produce one acknowledged successor despite interruption.

import Foundation

public enum ContinuityCrashPoint: String, CaseIterable, Sendable {
    case checkpointPreparing, checkpointPersisted, successorRequested
    case createSideEffect, successorCreated, successorBootstrapping
    case bootstrapSideEffect, successorAcknowledged, predecessorSealed
}

public enum ContinuityRunError: Error, LocalizedError, Sendable {
    case injectedCrash(ContinuityCrashPoint)
    case hostCapabilityUnavailable
    case acknowledgementTimeout

    public var errorDescription: String? {
        switch self {
        case .injectedCrash(let point): "Injected crash at \(point.rawValue)"
        case .hostCapabilityUnavailable: "Host cannot create and bootstrap a successor session"
        case .acknowledgementTimeout: "Successor acknowledgment timed out"
        }
    }
}

struct PreparedContinuityOutcome: @unchecked Sendable {
    let operation: ContinuityOperation
    let handoff: ContinuityHandoff
}

struct PreparedContinuityV2Outcome: @unchecked Sendable {
    let operation: ContinuityOperationV2
    let handoff: ContinuityHandoffV2
    let projectionRepairPending: Bool
}

public final class ContinuityStateEngine: @unchecked Sendable {
    private let memory: ProjectMemoryService

    public init(memory: ProjectMemoryService) { self.memory = memory }

    public func prepare(
        handoff: ContinuityHandoff,
        predecessorSessionID: String,
        adapterID: String,
        idempotencyKey: String,
        crashAfter: ContinuityCrashPoint? = nil,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ContinuityOperation {
        try prepareOutcome(
            handoff: handoff,
            predecessorSessionID: predecessorSessionID,
            adapterID: adapterID,
            idempotencyKey: idempotencyKey,
            crashAfter: crashAfter,
            cancellation: cancellation
        ).operation
    }

    func prepareOutcome(
        handoff: ContinuityHandoff,
        predecessorSessionID: String,
        adapterID: String,
        idempotencyKey: String,
        crashAfter: ContinuityCrashPoint? = nil,
        cancellation: ToolCallCancellation? = nil
    ) throws -> PreparedContinuityOutcome {
        try cancellation?.checkCancellation()
        let validated = try handoff.validated()
        try cancellation?.checkCancellation()
        let repository = try memory.repositoryForProject(
            validated.project["project_id"] as? String ?? "",
            cancellation: cancellation
        )
        // Creation is the durable commit boundary. Once it starts, finish the
        // idempotent checkpoint sequence so a caller never receives cancellation
        // for an operation that was actually committed.
        try cancellation?.checkCancellation()
        var operation = try repository.continuityCreateOperation(
            operationID: validated.operationID, predecessorSessionID: predecessorSessionID,
            handoffID: validated.handoffID, adapterID: adapterID, idempotencyKey: idempotencyKey,
            cancellation: cancellation
        )
        var committedHandoff: ContinuityHandoff?
        if operation.state == .active {
            // Persist the recovery payload before recording checkpoint intent so a restart at
            // checkpointPreparing can rebuild solely from the project ledger.
            try repository.continuityStoreHandoff(validated)
            committedHandoff = validated
            operation = try repository.continuityTransition(
                operationID: operation.operationID, expected: .active, to: .checkpointPreparing,
                evidence: "checkpoint_intent"
            )
            if crashAfter == .checkpointPreparing {
                throw ContinuityRunError.injectedCrash(.checkpointPreparing)
            }
        }
        if operation.state == .checkpointPreparing {
            try repository.continuityStoreHandoff(validated)
            committedHandoff = validated
            operation = try repository.continuityTransition(
                operationID: operation.operationID, expected: .checkpointPreparing,
                to: .checkpointPersisted, evidence: validated.contentSHA256
            )
            if crashAfter == .checkpointPersisted {
                throw ContinuityRunError.injectedCrash(.checkpointPersisted)
            }
        }
        if committedHandoff == nil {
            committedHandoff = try repository.continuityHandoff(id: operation.handoffID)
        }
        guard let committedHandoff else {
            throw ProjectMemoryError.integrityFailure(
                "prepared V1 operation is missing its durable handoff"
            )
        }
        return PreparedContinuityOutcome(
            operation: operation,
            handoff: committedHandoff
        )
    }

    public func prepareV2(
        handoff: ContinuityHandoffV2,
        predecessorSessionID: String,
        predecessorProviderResponseID: String?,
        adapterID: String,
        idempotencyKey: String,
        budgetObservationID: String? = nil,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ContinuityOperationV2 {
        try prepareV2Outcome(
            handoff: handoff,
            predecessorSessionID: predecessorSessionID,
            predecessorProviderResponseID: predecessorProviderResponseID,
            adapterID: adapterID,
            idempotencyKey: idempotencyKey,
            budgetObservationID: budgetObservationID,
            cancellation: cancellation
        ).operation
    }

    func prepareV2Outcome(
        handoff: ContinuityHandoffV2,
        predecessorSessionID: String,
        predecessorProviderResponseID: String?,
        adapterID: String,
        idempotencyKey: String,
        budgetObservationID: String? = nil,
        cancellation: ToolCallCancellation? = nil,
        didCommitCheckpoint: (@Sendable (ContinuityOperationV2, ContinuityHandoffV2) -> Void)? = nil
    ) throws -> PreparedContinuityV2Outcome {
        try cancellation?.checkCancellation()
        let validated = try handoff.validated()
        guard let projectID = validated.projectID else {
            throw ProjectMemoryError.invalidRequest("V2 handoff project_id is missing")
        }
        try cancellation?.checkCancellation()
        let repository = try memory.repositoryForProject(
            projectID,
            cancellation: cancellation
        )
        // As with V1, operation creation begins a crash-recoverable durable
        // sequence. Complete that sequence even if transport cancellation races it.
        try cancellation?.checkCancellation()
        let defersProjectionUntilCheckpoint = didCommitCheckpoint != nil
        let checkpointReceiptPublication = BlockingContinuityResult<Bool>()
        var operation: ContinuityOperationV2
        do {
            operation = try repository.continuityCreateOperationV2(
                handoff: validated,
                predecessorSessionID: predecessorSessionID,
                predecessorProviderResponseID: predecessorProviderResponseID,
                adapterID: adapterID,
                idempotencyKey: idempotencyKey,
                budgetObservationID: budgetObservationID,
                cancellation: cancellation,
                repairProjectionImmediately: !defersProjectionUntilCheckpoint
            )
        } catch {
            operation = try reconcilePreparedV2(
                repository: repository,
                handoff: validated,
                predecessorSessionID: predecessorSessionID,
                predecessorProviderResponseID: predecessorProviderResponseID,
                adapterID: adapterID,
                idempotencyKey: idempotencyKey,
                minimumState: .active,
                originalError: error
            )
        }
        if operation.state == .active {
            do {
                try repository.continuityStoreHandoffV2(
                    validated,
                    repairProjectionImmediately: !defersProjectionUntilCheckpoint
                )
            } catch {
                operation = try reconcilePreparedV2(
                    repository: repository,
                    handoff: validated,
                    predecessorSessionID: predecessorSessionID,
                    predecessorProviderResponseID: predecessorProviderResponseID,
                    adapterID: adapterID,
                    idempotencyKey: idempotencyKey,
                    minimumState: .active,
                    originalError: error
                )
            }
            if operation.state == .active {
                do {
                    operation = try repository.continuityTransitionV2(
                        operationID: operation.operationID,
                        expected: .active,
                        to: .checkpointPreparing,
                        evidence: "v2_checkpoint_intent",
                        repairProjectionImmediately: !defersProjectionUntilCheckpoint
                    )
                } catch {
                    operation = try reconcilePreparedV2(
                        repository: repository,
                        handoff: validated,
                        predecessorSessionID: predecessorSessionID,
                        predecessorProviderResponseID: predecessorProviderResponseID,
                        adapterID: adapterID,
                        idempotencyKey: idempotencyKey,
                        minimumState: .checkpointPreparing,
                        originalError: error
                    )
                }
            }
        }
        if operation.state == .checkpointPreparing {
            do {
                try repository.continuityStoreHandoffV2(
                    validated,
                    repairProjectionImmediately: !defersProjectionUntilCheckpoint
                )
            } catch {
                operation = try reconcilePreparedV2(
                    repository: repository,
                    handoff: validated,
                    predecessorSessionID: predecessorSessionID,
                    predecessorProviderResponseID: predecessorProviderResponseID,
                    adapterID: adapterID,
                    idempotencyKey: idempotencyKey,
                    minimumState: .checkpointPreparing,
                    originalError: error
                )
            }
            if operation.state == .checkpointPreparing {
                do {
                    operation = try repository.continuityTransitionV2(
                        operationID: operation.operationID,
                        expected: .checkpointPreparing,
                        to: .checkpointPersisted,
                        evidence: validated.contentSHA256,
                        repairProjectionImmediately: !defersProjectionUntilCheckpoint,
                        didCommitCanonical: { committed in
                            checkpointReceiptPublication.store(.success(true))
                            didCommitCheckpoint?(committed, validated)
                        }
                    )
                } catch {
                    operation = try reconcilePreparedV2(
                        repository: repository,
                        handoff: validated,
                        predecessorSessionID: predecessorSessionID,
                        predecessorProviderResponseID: predecessorProviderResponseID,
                        adapterID: adapterID,
                        idempotencyKey: idempotencyKey,
                        minimumState: .checkpointPersisted,
                        originalError: error
                    )
                }
            }
        }
        if operation.state == .checkpointPersisted,
           checkpointReceiptPublication.take() == nil {
            // Replays may arrive after the original checkpoint commit. Publishing
            // the already durable canonical row is equally truthful and happens
            // before any deferred projection work.
            didCommitCheckpoint?(operation, validated)
        }
        if defersProjectionUntilCheckpoint {
            _ = try? repository.repairContinuityProjections()
        }
        return PreparedContinuityV2Outcome(
            operation: operation,
            handoff: validated,
            projectionRepairPending: (try? repository.continuityProjectionRepairPending(
                operationID: operation.operationID
            )) ?? true
        )
    }

    private func reconcilePreparedV2(
        repository: ProjectMemoryRepository,
        handoff: ContinuityHandoffV2,
        predecessorSessionID: String,
        predecessorProviderResponseID: String?,
        adapterID: String,
        idempotencyKey: String,
        minimumState: ContinuityState,
        originalError: Error
    ) throws -> ContinuityOperationV2 {
        guard let committed = try? repository.continuityOperationV2(id: handoff.operationID),
              committed.projectID == handoff.projectID,
              committed.projectGeneration == handoff.projectGeneration,
              committed.runID == handoff.runID,
              committed.predecessorSessionID == predecessorSessionID,
              committed.predecessorProviderResponseID == predecessorProviderResponseID,
              committed.handoffID == handoff.handoffID,
              committed.adapterID == adapterID,
              committed.idempotencyKey == idempotencyKey,
              committed.bootstrapNonce == handoff.bootstrapNonce,
              Self.stateRank(committed.state) >= Self.stateRank(minimumState),
              let durableHandoff = try? repository.continuityHandoffV2(id: handoff.handoffID),
              durableHandoff.operationID == handoff.operationID,
              durableHandoff.contentSHA256 == handoff.contentSHA256 else {
            throw originalError
        }
        return committed
    }

    private static func stateRank(_ state: ContinuityState) -> Int {
        switch state {
        case .active: 0
        case .checkpointPreparing: 1
        case .checkpointPersisted: 2
        case .successorRequested: 3
        case .successorCreated: 4
        case .successorBootstrapping: 5
        case .successorAcknowledged: 6
        case .predecessorSealed: 7
        }
    }

    public func operationV2(
        projectID: String,
        operationID: String,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ContinuityOperationV2? {
        try cancellation?.checkCancellation()
        let value = try memory.repositoryForProject(
            projectID,
            cancellation: cancellation
        ).continuityOperationV2(id: operationID, cancellation: cancellation)
        try cancellation?.checkCancellation()
        return value
    }

    public func activeOperationV2(
        projectID: String,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ContinuityOperationV2? {
        try cancellation?.checkCancellation()
        let value = try memory.repositoryForProject(
            projectID,
            cancellation: cancellation
        ).continuityActiveOperationV2(cancellation: cancellation)
        try cancellation?.checkCancellation()
        return value
    }

    public func handoffV2(
        projectID: String,
        handoffID: String,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ContinuityHandoffV2? {
        try cancellation?.checkCancellation()
        let value = try memory.repositoryForProject(
            projectID,
            cancellation: cancellation
        ).continuityHandoffV2(id: handoffID, cancellation: cancellation)
        try cancellation?.checkCancellation()
        return value
    }

    public func transitionV2(
        projectID: String,
        operationID: String,
        expected: ContinuityState,
        to next: ContinuityState,
        successorSessionID: String? = nil,
        successorProviderResponseID: String? = nil,
        evidence: String? = nil,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ContinuityOperationV2 {
        try cancellation?.checkCancellation()
        return try memory.repositoryForProject(
            projectID,
            cancellation: cancellation
        ).continuityTransitionV2(
            operationID: operationID,
            expected: expected,
            to: next,
            successorSessionID: successorSessionID,
            successorProviderResponseID: successorProviderResponseID,
            evidence: evidence,
            cancellation: cancellation
        )
    }

    public func acknowledgeV2(
        projectID: String,
        operationID: String,
        receipt: BootstrapReceipt,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ContinuityOperationV2 {
        try cancellation?.checkCancellation()
        return try memory.repositoryForProject(
            projectID,
            cancellation: cancellation
        ).continuityAcknowledgeV2(
            operationID: operationID,
            receipt: receipt,
            cancellation: cancellation
        )
    }

    @discardableResult
    public func markContinuationIssuedV2(
        projectID: String,
        operationID: String,
        cancellation: ToolCallCancellation? = nil
    ) throws -> Bool {
        try cancellation?.checkCancellation()
        return try memory.repositoryForProject(
            projectID,
            cancellation: cancellation
        ).continuityMarkContinuationIssuedV2(
            operationID: operationID,
            cancellation: cancellation
        )
    }

    public func operation(
        projectID: String,
        operationID: String,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ContinuityOperation? {
        try cancellation?.checkCancellation()
        let value = try memory.repositoryForProject(
            projectID,
            cancellation: cancellation
        ).continuityOperation(id: operationID, cancellation: cancellation)
        try cancellation?.checkCancellation()
        return value
    }

    public func activeOperation(
        projectID: String,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ContinuityOperation? {
        try cancellation?.checkCancellation()
        let value = try memory.repositoryForProject(
            projectID,
            cancellation: cancellation
        ).continuityActiveOperation(cancellation: cancellation)
        try cancellation?.checkCancellation()
        return value
    }

    public func handoff(
        projectID: String,
        handoffID: String,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ContinuityHandoff? {
        try cancellation?.checkCancellation()
        let value = try memory.repositoryForProject(
            projectID,
            cancellation: cancellation
        ).continuityHandoff(id: handoffID, cancellation: cancellation)
        try cancellation?.checkCancellation()
        return value
    }

    public func transition(
        projectID: String,
        operationID: String,
        expected: ContinuityState,
        to next: ContinuityState,
        successorSessionID: String? = nil,
        evidence: String? = nil,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ContinuityOperation {
        try cancellation?.checkCancellation()
        return try memory.repositoryForProject(
            projectID,
            cancellation: cancellation
        ).continuityTransition(
            operationID: operationID, expected: expected, to: next,
            successorSessionID: successorSessionID, evidence: evidence,
            cancellation: cancellation
        )
    }

    public func adoptAndAcknowledgeExternalSuccessor(
        projectID: String,
        operationID: String,
        handoffID: String,
        successorSessionID: String,
        adapterID: String,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ContinuityOperation {
        try cancellation?.checkCancellation()
        let repository = try memory.repositoryForProject(
            projectID,
            cancellation: cancellation
        )
        guard var operation = try repository.continuityOperation(
            id: operationID,
            cancellation: cancellation
        ) else {
            throw ProjectMemoryError.recordNotFound(operationID)
        }
        guard operation.adapterID == adapterID,
              operation.handoffID == handoffID,
              operation.successorSessionID == nil || operation.successorSessionID == successorSessionID else {
            throw ProjectMemoryError.conflict(
                "acknowledgment does not match exact handoff, successor, and adapter"
            )
        }
        // The first transition is the mutation boundary. From this point the
        // idempotent state machine is completed and its actual outcome is returned.
        try cancellation?.checkCancellation()
        var mutationCancellation = cancellation
        if operation.state == .checkpointPersisted {
            operation = try repository.continuityTransition(
                operationID: operationID, expected: .checkpointPersisted,
                to: .successorRequested, evidence: "external_host_confirmed_create_intent",
                cancellation: mutationCancellation
            )
            mutationCancellation = nil
        }
        if operation.state == .successorRequested {
            operation = try repository.continuityTransition(
                operationID: operationID, expected: .successorRequested, to: .successorCreated,
                successorSessionID: successorSessionID, evidence: "external_host_confirmed_successor",
                cancellation: mutationCancellation
            )
            mutationCancellation = nil
        }
        if operation.state == .successorCreated {
            operation = try repository.continuityTransition(
                operationID: operationID, expected: .successorCreated,
                to: .successorBootstrapping, evidence: "external_host_confirmed_bootstrap",
                cancellation: mutationCancellation
            )
            mutationCancellation = nil
        }
        return try repository.continuityAcknowledge(
            operationID: operationID, handoffID: handoffID,
            successorSessionID: successorSessionID, adapterID: adapterID,
            cancellation: mutationCancellation
        )
    }

    public func acknowledge(
        projectID: String,
        operationID: String,
        acknowledgement: HandoffAcknowledgement,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ContinuityOperation {
        try cancellation?.checkCancellation()
        return try memory.repositoryForProject(
            projectID,
            cancellation: cancellation
        ).continuityAcknowledge(
            operationID: operationID, handoffID: acknowledgement.handoffID,
            successorSessionID: acknowledgement.successorSessionID,
            adapterID: acknowledgement.adapterID,
            cancellation: cancellation
        )
    }

    public func seal(
        projectID: String,
        operationID: String,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ContinuityOperation {
        try transition(
            projectID: projectID, operationID: operationID,
            expected: .successorAcknowledged, to: .predecessorSealed,
            evidence: "active_session_pointer_swapped",
            cancellation: cancellation
        )
    }

    public func recordRetry(
        projectID: String,
        operationID: String,
        error: String,
        cancellation: ToolCallCancellation? = nil
    ) throws {
        try cancellation?.checkCancellation()
        try memory.repositoryForProject(
            projectID,
            cancellation: cancellation
        ).continuityRecordRetry(
            operationID: operationID, error: error,
            retryAt: ISO8601.string(from: Date().addingTimeInterval(1)),
            cancellation: cancellation
        )
    }

    public func status(
        projectID: String,
        cancellation: ToolCallCancellation? = nil
    ) throws -> [String: Any] {
        try cancellation?.checkCancellation()
        let repository = try memory.repositoryForProject(
            projectID,
            cancellation: cancellation
        )
        if let operation = try repository.continuityActiveOperationV2(cancellation: cancellation) {
            let handoff = try repository.continuityHandoffV2(
                id: operation.handoffID,
                cancellation: cancellation
            )
            let payload: [String: Any] = [
                "ok": true,
                "project_id": projectID,
                "project_generation": operation.projectGeneration,
                "run_id": operation.runID,
                "state": operation.state.rawValue,
                "operation": operation.asDictionary(),
                "pending_handoff_id": operation.handoffID,
                "handoff_schema_version": ContinuityHandoffV2.schemaVersion,
                "continuity_mode": handoff?.continuityMode?.rawValue as Any,
                "canonical_location": "project_local",
                "global_latest_authority": false,
                "projection_repair_pending": try repository.continuityProjectionRepairPending(
                    operationID: operation.operationID,
                    cancellation: cancellation
                ),
                "active_session_id": try repository.continuityActiveSessionID(
                    cancellation: cancellation
                ) as Any,
                "retry": [
                    "error": operation.lastError as Any,
                    "retry_at": operation.retryAt as Any,
                ],
                "health": "ok",
                "schema_version": ContinuityOperationV2.schemaVersion,
            ]
            try cancellation?.checkCancellation()
            return payload
        }
        let operation = try repository.continuityActiveOperation(cancellation: cancellation)
        let payload: [String: Any] = [
            "ok": true, "project_id": projectID,
            "state": operation?.state.rawValue ?? ContinuityState.active.rawValue,
            "operation": operation?.asDictionary() as Any,
            "pending_handoff_id": operation?.handoffID as Any,
            "active_session_id": try repository.continuityActiveSessionID(
                cancellation: cancellation
            ) as Any,
            "retry": ["error": operation?.lastError as Any, "retry_at": operation?.retryAt as Any],
            "health": "ok", "schema_version": 1,
        ]
        try cancellation?.checkCancellation()
        return payload
    }
}

/// Manager-owned async request path. It commits the project-local handoff first,
/// then durably enqueues one control-plane command before returning its operation ID.
struct ManagedContinuityRequestOutcome: @unchecked Sendable {
    let command: ContinuityCommand
    let operation: ContinuityOperationV2
    let handoff: ContinuityHandoffV2
    let projectionRepairPending: Bool
}

private struct ManagedContinuityCheckpointReceipt: Sendable {
    let operation: ContinuityOperationV2
    let handoff: ContinuityHandoffV2
    let projectionRepairPending: Bool
}

private enum ManagedContinuityBridgeOutcome: @unchecked Sendable {
    case queued(ManagedContinuityRequestOutcome)
    case checkpointCommitted(ManagedContinuityCheckpointReceipt)
}

public actor ManagedContinuityCommandRouter {
    private let engine: ContinuityStateEngine
    private let controlPlane: ProjectControlPlaneRepository

    public init(
        memory: ProjectMemoryService,
        controlPlane: ProjectControlPlaneRepository
    ) {
        self.engine = ContinuityStateEngine(memory: memory)
        self.controlPlane = controlPlane
    }

    @discardableResult
    public func request(
        handoff: ContinuityHandoffV2,
        predecessorSessionID: String,
        predecessorProviderResponseID: String?,
        adapterID: String,
        idempotencyKey: String,
        requestedBy: String,
        reason: String,
        commandType: ContinuityCommandType = .rollover,
        budgetObservationID: String? = nil,
        cancellation: ToolCallCancellation? = nil
    ) async throws -> ContinuityCommand {
        try await requestOutcome(
            handoff: handoff,
            predecessorSessionID: predecessorSessionID,
            predecessorProviderResponseID: predecessorProviderResponseID,
            adapterID: adapterID,
            idempotencyKey: idempotencyKey,
            requestedBy: requestedBy,
            reason: reason,
            commandType: commandType,
            budgetObservationID: budgetObservationID,
            cancellation: cancellation,
            didPersistCheckpoint: nil,
            didCommitCheckpoint: nil
        ).command
    }

    func requestOutcome(
        handoff: ContinuityHandoffV2,
        predecessorSessionID: String,
        predecessorProviderResponseID: String?,
        adapterID: String,
        idempotencyKey: String,
        requestedBy: String,
        reason: String,
        commandType: ContinuityCommandType = .rollover,
        budgetObservationID: String? = nil,
        cancellation: ToolCallCancellation? = nil,
        didPersistCheckpoint: (@Sendable () -> Void)? = nil,
        didCommitCheckpoint: (@Sendable (ContinuityOperationV2, ContinuityHandoffV2, Bool) -> Void)? = nil
    ) async throws -> ManagedContinuityRequestOutcome {
        try Task.checkCancellation()
        try cancellation?.checkCancellation()
        let validated = try handoff.validated()
        guard validated.continuityMode == .managedAutonomous,
              let projectString = validated.projectID,
              let projectUUID = UUID(uuidString: projectString),
              let generation = validated.projectGeneration,
              let runString = validated.runID,
              let runUUID = UUID(uuidString: runString) else {
            throw ProjectMemoryError.invalidRequest(
                "managed rollover requires exact project generation and run identity"
            )
        }
        let projectID = ProjectID(projectUUID)
        let projectGeneration = ProjectGeneration(generation)
        let runID = RunID(runUUID)
        // Reserve and validate the exact manager identity before creating a
        // project-local checkpoint that would otherwise block future rollovers.
        try await controlPlane.reserveContinuityRun(
            runID: runID,
            projectID: projectID,
            projectGeneration: projectGeneration,
            assignmentID: validated.run["assignment_id"] as? String,
            mission: validated.mission,
            mode: .managedAutonomous,
            cancellation: cancellation
        )
        // This is the last cancellation point before the project-local operation
        // may become durable. After prepareV2 starts, the router completes the
        // idempotent command enqueue and returns that outcome.
        try Task.checkCancellation()
        try cancellation?.checkCancellation()
        let prepared = try engine.prepareV2Outcome(
            handoff: validated,
            predecessorSessionID: predecessorSessionID,
            predecessorProviderResponseID: predecessorProviderResponseID,
            adapterID: adapterID,
            idempotencyKey: idempotencyKey,
            budgetObservationID: budgetObservationID,
            cancellation: cancellation,
            didCommitCheckpoint: { operation, durableHandoff in
                didCommitCheckpoint?(operation, durableHandoff, true)
            }
        )
        let operation = prepared.operation
        guard operation.state == .checkpointPersisted,
              let operationUUID = UUID(uuidString: operation.operationID) else {
            throw ProjectMemoryError.integrityFailure(
                "manager command cannot be queued before the V2 checkpoint is durable"
            )
        }
        didPersistCheckpoint?()
        // The checkpoint is canonical now. Finish the idempotent enqueue with an
        // internal bounded database deadline even if the caller departs, so the
        // transport cannot report failure while a queued enqueue later commits.
        let command = try await controlPlane.enqueueContinuityCommand(
            ContinuityCommandRequest(
                operationID: operationUUID,
                runID: runID,
                projectID: projectID,
                projectGeneration: projectGeneration,
                type: commandType,
                requestedBy: requestedBy,
                reason: reason,
                idempotencyKey: idempotencyKey,
                payloadSHA256: validated.contentSHA256
            ),
            cancellation: nil
        )
        return ManagedContinuityRequestOutcome(
            command: command,
            operation: operation,
            handoff: prepared.handoff,
            projectionRepairPending: prepared.projectionRepairPending
        )
    }
}

public actor ContinuityCoordinator {
    public nonisolated let engine: ContinuityStateEngine

    public init(engine: ContinuityStateEngine) { self.engine = engine }

    public func requestRollover(
        handoff: ContinuityHandoff,
        predecessorSessionID: String,
        adapter: any SessionHostAdapter,
        idempotencyKey: String,
        crashAfter: ContinuityCrashPoint? = nil
    ) async throws -> ContinuityOperation {
        let capabilities = try await adapter.capabilities()
        guard capabilities.create, capabilities.bootstrap,
              capabilities.idempotency || capabilities.queryByIdempotencyKey else {
            _ = try engine.prepare(
                handoff: handoff, predecessorSessionID: predecessorSessionID,
                adapterID: adapter.identifier, idempotencyKey: idempotencyKey
            )
            throw ContinuityRunError.hostCapabilityUnavailable
        }
        let projectID = handoff.project["project_id"] as? String ?? ""
        var operation: ContinuityOperation
        do {
            operation = try engine.prepare(
                handoff: handoff, predecessorSessionID: predecessorSessionID,
                adapterID: adapter.identifier, idempotencyKey: idempotencyKey,
                crashAfter: crashAfter
            )
        } catch {
            try? engine.recordRetry(
                projectID: projectID, operationID: handoff.operationID,
                error: error.localizedDescription
            )
            throw error
        }
        do {
            while !operation.state.isTerminal {
                switch operation.state {
                case .active:
                    operation = try engine.transition(
                        projectID: operation.projectID, operationID: operation.operationID,
                        expected: .active, to: .checkpointPreparing
                    )
                    try crashIfRequested(crashAfter, .checkpointPreparing)
                case .checkpointPreparing:
                    operation = try engine.prepare(
                        handoff: handoff, predecessorSessionID: predecessorSessionID,
                        adapterID: adapter.identifier, idempotencyKey: idempotencyKey
                    )
                    try crashIfRequested(crashAfter, .checkpointPersisted)
                case .checkpointPersisted:
                    operation = try engine.transition(
                        projectID: operation.projectID, operationID: operation.operationID,
                        expected: .checkpointPersisted, to: .successorRequested,
                        evidence: "host_create_intent"
                    )
                    try crashIfRequested(crashAfter, .successorRequested)
                case .successorRequested:
                    let request = SessionCreationRequest(
                        operationID: operation.operationID, projectID: operation.projectID,
                        predecessorSessionID: operation.predecessorSessionID,
                        idempotencyKey: operation.idempotencyKey
                    )
                    let existingSession = try await adapter.session(
                        forIdempotencyKey: operation.idempotencyKey
                    )
                    let session: HostSession
                    if let existingSession {
                        session = existingSession
                    } else {
                        session = try await adapter.createSession(request)
                    }
                    try crashIfRequested(crashAfter, .createSideEffect)
                    operation = try engine.transition(
                        projectID: operation.projectID, operationID: operation.operationID,
                        expected: .successorRequested, to: .successorCreated,
                        successorSessionID: session.id, evidence: "host_successor_reconciled"
                    )
                    try crashIfRequested(crashAfter, .successorCreated)
                case .successorCreated:
                    operation = try engine.transition(
                        projectID: operation.projectID, operationID: operation.operationID,
                        expected: .successorCreated, to: .successorBootstrapping,
                        evidence: "bootstrap_intent"
                    )
                    try crashIfRequested(crashAfter, .successorBootstrapping)
                case .successorBootstrapping:
                    guard let successorID = operation.successorSessionID,
                          let durableHandoff = try engine.handoff(
                            projectID: operation.projectID, handoffID: operation.handoffID
                          ) else {
                        throw ProjectMemoryError.integrityFailure("successor or handoff is missing")
                    }
                    let session = HostSession(id: successorID)
                    try await adapter.bootstrap(session, handoff: durableHandoff)
                    try crashIfRequested(crashAfter, .bootstrapSideEffect)
                    let acknowledgement = try await adapter.awaitAcknowledgement(
                        session: session, handoffID: operation.handoffID, timeout: .seconds(5)
                    )
                    operation = try engine.acknowledge(
                        projectID: operation.projectID, operationID: operation.operationID,
                        acknowledgement: acknowledgement
                    )
                    try crashIfRequested(crashAfter, .successorAcknowledged)
                case .successorAcknowledged:
                    operation = try engine.seal(
                        projectID: operation.projectID, operationID: operation.operationID
                    )
                    try crashIfRequested(crashAfter, .predecessorSealed)
                case .predecessorSealed:
                    break
                }
            }
            return operation
        } catch {
            try? engine.recordRetry(
                projectID: operation.projectID, operationID: operation.operationID,
                error: error.localizedDescription
            )
            throw error
        }
    }

    public func recover(
        projectID: String,
        adapter: any SessionHostAdapter
    ) async throws -> ContinuityOperation? {
        guard let operation = try engine.activeOperation(projectID: projectID),
              let handoff = try engine.handoff(projectID: projectID, handoffID: operation.handoffID) else {
            return nil
        }
        return try await requestRollover(
            handoff: handoff, predecessorSessionID: operation.predecessorSessionID,
            adapter: adapter, idempotencyKey: operation.idempotencyKey
        )
    }

    private func crashIfRequested(_ requested: ContinuityCrashPoint?, _ point: ContinuityCrashPoint) throws {
        if requested == point { throw ContinuityRunError.injectedCrash(point) }
    }
}

public final class ContinuityControlService: @unchecked Sendable {
    public let coordinator: ContinuityCoordinator
    private let memory: ProjectMemoryService
    private let managedRouter: ManagedContinuityCommandRouter?
    private let waitTimeoutSeconds: TimeInterval
    private let cancellationCleanupTimeoutSeconds: TimeInterval
    private let didPrepareDurableObserver: (@Sendable () -> Void)?
    private let didManagedCommandEnqueueObserver: (@Sendable () -> Void)?

    public convenience init(
        memory: ProjectMemoryService,
        controlPlane: ProjectControlPlaneRepository? = nil,
        waitTimeout: DispatchTimeInterval = .seconds(10),
        cancellationCleanupTimeout: DispatchTimeInterval = .seconds(10)
    ) {
        self.init(
            memory: memory,
            controlPlane: controlPlane,
            waitTimeout: waitTimeout,
            cancellationCleanupTimeout: cancellationCleanupTimeout,
            didPrepareDurableObserver: nil,
            didManagedCommandEnqueueObserver: nil
        )
    }

    init(
        memory: ProjectMemoryService,
        controlPlane: ProjectControlPlaneRepository?,
        waitTimeout: DispatchTimeInterval,
        cancellationCleanupTimeout: DispatchTimeInterval,
        didPrepareDurableObserver: (@Sendable () -> Void)?,
        didManagedCommandEnqueueObserver: (@Sendable () -> Void)?
    ) {
        self.memory = memory
        self.coordinator = ContinuityCoordinator(engine: ContinuityStateEngine(memory: memory))
        self.managedRouter = controlPlane.map {
            ManagedContinuityCommandRouter(memory: memory, controlPlane: $0)
        }
        self.waitTimeoutSeconds = Self.boundedSeconds(
            waitTimeout,
            fallback: 10
        )
        self.cancellationCleanupTimeoutSeconds = Self.boundedSeconds(
            cancellationCleanupTimeout,
            fallback: 10
        )
        self.didPrepareDurableObserver = didPrepareDurableObserver
        self.didManagedCommandEnqueueObserver = didManagedCommandEnqueueObserver
    }

    public func prepare(
        arguments: [String: Any],
        cancellation: ToolCallCancellation? = nil
    ) throws -> [String: Any] {
        try cancellation?.checkCancellation()
        if arguments["project_generation"] != nil || arguments["run_id"] != nil {
            return try prepareV2(arguments: arguments, cancellation: cancellation)
        }
        let handoff = try buildHandoff(arguments: arguments, cancellation: cancellation)
        let predecessor = try requiredString(arguments, "predecessor_session_id")
        let adapterID = string(arguments, "adapter_id") ?? "external-mcp"
        let idempotency = string(arguments, "idempotency_key") ?? handoff.operationID
        try cancellation?.checkCancellation()
        let prepared = try coordinator.engine.prepareOutcome(
            handoff: handoff, predecessorSessionID: predecessor,
            adapterID: adapterID, idempotencyKey: idempotency,
            cancellation: cancellation
        )
        let operation = prepared.operation
        didPrepareDurableObserver?()
        // prepare returned only after storing this validated handoff. Carry that
        // committed result forward instead of adding a new throwing readback.
        return [
            "ok": true, "disposition": "memory_only_handoff_ready",
            "operation": operation.asDictionary(), "handoff": prepared.handoff.asDictionary(),
            "host_capability": "external_session_creation_unconfirmed",
        ]
    }

    public func checkpoint(
        arguments: [String: Any],
        cancellation: ToolCallCancellation? = nil
    ) throws -> [String: Any] {
        var payload = try prepare(arguments: arguments, cancellation: cancellation)
        payload["request_route"] = "checkpoint_only"
        payload["checkpoint_persisted"] = true
        payload["session_creation_confirmed"] = false
        return payload
    }

    public func prepareHandoff(
        arguments: [String: Any],
        cancellation: ToolCallCancellation? = nil
    ) throws -> [String: Any] {
        var payload = try prepare(arguments: arguments, cancellation: cancellation)
        payload["request_route"] = "prepare_handoff"
        payload["handoff_prepared"] = true
        payload["session_creation_confirmed"] = false
        return payload
    }

    public func requestRollover(
        arguments: [String: Any],
        cancellation: ToolCallCancellation? = nil
    ) throws -> [String: Any] {
        try cancellation?.checkCancellation()
        if string(arguments, "continuity_mode") == ContinuityMode.managedAutonomous.rawValue {
            return try requestManagedRollover(
                arguments: arguments,
                cancellation: cancellation
            )
        }
        var payload = try prepare(arguments: arguments, cancellation: cancellation)
        payload["request_route"] = "external_handoff_only"
        payload["external_capability"] = "handoff_only"
        payload["manager_operation_enqueued"] = false
        payload["session_creation_confirmed"] = false
        payload["disposition"] = "memory_only_handoff_ready"
        return payload
    }

    public func pending(
        arguments: [String: Any],
        cancellation: ToolCallCancellation? = nil
    ) throws -> [String: Any] {
        try cancellation?.checkCancellation()
        let projectID = try requiredProjectID(arguments)
        if let operation = try coordinator.engine.activeOperationV2(
            projectID: projectID,
            cancellation: cancellation
        ) {
            guard let handoff = try coordinator.engine.handoffV2(
                projectID: projectID,
                handoffID: operation.handoffID,
                cancellation: cancellation
            ) else {
                throw ProjectMemoryError.integrityFailure(
                    "active V2 operation is missing its exact project-local handoff"
                )
            }
            return [
                "ok": true,
                "found": true,
                "schema_version": ContinuityOperationV2.schemaVersion,
                "handoff_schema_version": ContinuityHandoffV2.schemaVersion,
                "canonical_location": "project_local",
                "global_latest_authority": false,
                "operation": operation.asDictionary(),
                "handoff": handoff.asDictionary(),
            ]
        }
        guard let operation = try coordinator.engine.activeOperation(
                projectID: projectID,
                cancellation: cancellation
              ),
              let handoff = try coordinator.engine.handoff(
                projectID: projectID,
                handoffID: operation.handoffID,
                cancellation: cancellation
              ) else {
            return ["ok": true, "found": false, "project_id": projectID]
        }
        return ["ok": true, "found": true, "operation": operation.asDictionary(), "handoff": handoff.asDictionary()]
    }

    public func acknowledge(
        arguments: [String: Any],
        cancellation: ToolCallCancellation? = nil
    ) throws -> [String: Any] {
        try cancellation?.checkCancellation()
        let projectID = try requiredProjectID(arguments)
        let operation = try coordinator.engine.adoptAndAcknowledgeExternalSuccessor(
            projectID: projectID, operationID: try requiredString(arguments, "operation_id"),
            handoffID: try requiredString(arguments, "handoff_id"),
            successorSessionID: try requiredString(arguments, "successor_session_id"),
            adapterID: string(arguments, "adapter_id") ?? "external-mcp",
            cancellation: cancellation
        )
        return ["ok": true, "operation": operation.asDictionary(), "acknowledged": true]
    }

    public func resume(
        arguments: [String: Any],
        cancellation: ToolCallCancellation? = nil
    ) throws -> [String: Any] {
        try cancellation?.checkCancellation()
        let projectID = try requiredProjectID(arguments)
        let operation = try coordinator.engine.seal(
            projectID: projectID,
            operationID: try requiredString(arguments, "operation_id"),
            cancellation: cancellation
        )
        return ["ok": true, "operation": operation.asDictionary(), "resumed": true]
    }

    public func status(
        arguments: [String: Any],
        cancellation: ToolCallCancellation? = nil
    ) throws -> [String: Any] {
        try coordinator.engine.status(
            projectID: requiredProjectID(arguments),
            cancellation: cancellation
        )
    }

    private func requestManagedRollover(
        arguments: [String: Any],
        cancellation: ToolCallCancellation?
    ) throws -> [String: Any] {
        let requestControl = cancellation ?? ToolCallCancellation()
        try requestControl.checkCancellation()
        guard let managedRouter else {
            throw ProjectMemoryError.integrityFailure(
                "managed continuity command queue is unavailable"
            )
        }
        let candidateHandoff = try buildHandoffV2(
            arguments: arguments,
            cancellation: requestControl
        )
        guard candidateHandoff.continuityMode == .managedAutonomous else {
            throw ProjectMemoryError.invalidRequest(
                "managed rollover requires continuity_mode=managedAutonomous"
            )
        }
        let predecessorSessionID = try requiredString(arguments, "predecessor_session_id")
        let predecessorProviderResponseID = string(arguments, "provider_response_id")
        let adapterID = try requiredString(arguments, "adapter_id")
        let idempotencyKey = string(arguments, "idempotency_key") ?? candidateHandoff.operationID
        let handoff = try reconciledManagedHandoff(
            candidateHandoff,
            idempotencyKey: idempotencyKey,
            bootstrapNonceWasSupplied: arguments["bootstrap_nonce"] != nil,
            cancellation: requestControl
        )
        let requestedBy = string(arguments, "requested_by") ?? "continuity.request_rollover"
        let reason = string(arguments, "reason")
            ?? string(arguments, "context_trigger")
            ?? "managed rollover requested"
        let budgetObservationID = string(arguments, "budget_observation_id")
        let commandType: ContinuityCommandType = string(arguments, "context_action") == "emergency"
            ? .emergencyRollover
            : .rollover
        try requestControl.checkCancellation()
        let committedReceipt = BlockingContinuityResult<ManagedContinuityBridgeOutcome>()
        let bridgeOutcome: ManagedContinuityBridgeOutcome = try wait(
            cancellation: requestControl,
            committedResultWins: true,
            committedReceipt: committedReceipt
        ) {
            let outcome = try await managedRouter.requestOutcome(
                handoff: handoff,
                predecessorSessionID: predecessorSessionID,
                predecessorProviderResponseID: predecessorProviderResponseID,
                adapterID: adapterID,
                idempotencyKey: idempotencyKey,
                requestedBy: requestedBy,
                reason: reason,
                commandType: commandType,
                budgetObservationID: budgetObservationID,
                cancellation: requestControl,
                didPersistCheckpoint: self.didPrepareDurableObserver,
                didCommitCheckpoint: { operation, durableHandoff, projectionRepairPending in
                    committedReceipt.store(.success(.checkpointCommitted(
                        ManagedContinuityCheckpointReceipt(
                            operation: operation,
                            handoff: durableHandoff,
                            projectionRepairPending: projectionRepairPending
                        )
                    )))
                }
            )
            return .queued(outcome)
        }
        if case .checkpointCommitted(let receipt) = bridgeOutcome {
            return [
                "ok": true,
                "disposition": "manager_enqueue_recovery_pending",
                "request_route": "manager_command_queue",
                "continuity_mode": ContinuityMode.managedAutonomous.rawValue,
                "manager_operation_enqueued": false,
                "enqueue_status": "pending",
                "session_creation_confirmed": false,
                "operation_id": receipt.operation.operationID,
                "operation": receipt.operation.asDictionary(),
                "handoff": receipt.handoff.asDictionary(),
                "projection_repair_pending": receipt.projectionRepairPending,
                "handoff_schema_version": ContinuityHandoffV2.schemaVersion,
                "canonical_location": "project_local",
                "global_latest_authority": false,
            ]
        }
        guard case .queued(let outcome) = bridgeOutcome else {
            throw ProjectMemoryError.integrityFailure(
                "managed continuity bridge returned an invalid receipt"
            )
        }
        didManagedCommandEnqueueObserver?()
        let command = outcome.command
        let operation = outcome.operation
        let durableHandoff = outcome.handoff
        return [
            "ok": true,
            "disposition": "manager_operation_queued",
            "request_route": "manager_command_queue",
            "continuity_mode": ContinuityMode.managedAutonomous.rawValue,
            "manager_operation_enqueued": true,
            "session_creation_confirmed": false,
            "operation_id": operation.operationID,
            "command_id": command.commandID.uuidString.lowercased(),
            "command": command.asDictionary(),
            "operation": operation.asDictionary(),
            "handoff": durableHandoff.asDictionary(),
            "projection_repair_pending": outcome.projectionRepairPending,
            "handoff_schema_version": ContinuityHandoffV2.schemaVersion,
            "canonical_location": "project_local",
            "global_latest_authority": false,
        ]
    }

    private func reconciledManagedHandoff(
        _ candidate: ContinuityHandoffV2,
        idempotencyKey: String,
        bootstrapNonceWasSupplied: Bool,
        cancellation: ToolCallCancellation?
    ) throws -> ContinuityHandoffV2 {
        try cancellation?.checkCancellation()
        guard let projectID = candidate.projectID,
              let existing = try coordinator.engine.operationV2(
                projectID: projectID,
                operationID: candidate.operationID,
                cancellation: cancellation
              ) else {
            return candidate
        }
        guard existing.idempotencyKey == idempotencyKey,
              existing.handoffID == candidate.handoffID,
              existing.projectGeneration == candidate.projectGeneration,
              existing.runID == candidate.runID,
              let durable = try coordinator.engine.handoffV2(
                projectID: projectID,
                handoffID: existing.handoffID,
                cancellation: cancellation
              ) else {
            throw ProjectMemoryError.conflict(
                "managed rollover replay does not match the durable operation identity"
            )
        }
        var comparable = candidate
        comparable.createdAt = durable.createdAt
        comparable.contentSHA256 = ""
        if !bootstrapNonceWasSupplied {
            comparable.bootstrap["nonce"] = durable.bootstrapNonce
        }
        let normalized = try comparable.validated()
        try cancellation?.checkCancellation()
        guard normalized.contentSHA256 == durable.contentSHA256 else {
            throw ProjectMemoryError.conflict(
                "managed rollover replay payload differs from the durable handoff"
            )
        }
        return durable
    }

    private func wait<Value: Sendable>(
        cancellation: ToolCallCancellation?,
        committedResultWins: Bool,
        committedReceipt: BlockingContinuityResult<Value>? = nil,
        _ operation: @escaping @Sendable () async throws -> Value
    ) throws -> Value {
        let semaphore = DispatchSemaphore(value: 0)
        let box = BlockingContinuityResult<Value>()
        let task = Task {
            do {
                box.store(.success(try await operation()))
            } catch {
                box.store(.failure(error))
            }
            semaphore.signal()
        }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(waitTimeoutSeconds)
        while semaphore.wait(timeout: .now() + .milliseconds(25)) != .success {
            do {
                try cancellation?.checkCancellation()
            } catch {
                return try stopAndReconcile(
                    task: task,
                    semaphore: semaphore,
                    box: box,
                    cancellation: cancellation,
                    initiatingError: error,
                    committedResultWins: committedResultWins,
                    committedReceipt: committedReceipt,
                    reason: "request cancellation"
                )
            }
            guard clock.now < deadline else {
                return try stopAndReconcile(
                    task: task,
                    semaphore: semaphore,
                    box: box,
                    cancellation: cancellation,
                    initiatingError: ProjectMemoryError.databaseBusy,
                    committedResultWins: committedResultWins,
                    committedReceipt: committedReceipt,
                    reason: "bounded wait timeout"
                )
            }
        }
        guard let result = box.take() else {
            throw ProjectMemoryError.integrityFailure(
                "managed continuity request completed without a result"
            )
        }
        return try result.get()
    }

    private func stopAndReconcile<Value: Sendable>(
        task: Task<Void, Never>,
        semaphore: DispatchSemaphore,
        box: BlockingContinuityResult<Value>,
        cancellation: ToolCallCancellation?,
        initiatingError: Error,
        committedResultWins: Bool,
        committedReceipt: BlockingContinuityResult<Value>?,
        reason: String
    ) throws -> Value {
        cancellation?.cancel()
        task.cancel()
        let clock = ContinuousClock()
        let cleanupDeadline = clock.now + .seconds(cancellationCleanupTimeoutSeconds)
        while semaphore.wait(timeout: .now() + .milliseconds(25)) != .success,
              clock.now < cleanupDeadline {}
        if let result = box.take() {
            guard committedResultWins else { throw initiatingError }
            switch result {
            case .success(let value):
                return value
            case .failure(let error) where error is CancellationError:
                throw initiatingError
            case .failure(let error):
                throw error
            }
        }
        if committedResultWins,
           let receipt = committedReceipt?.take(),
           case .success(let value) = receipt {
            return value
        }
        throw ProjectMemoryError.integrityFailure(
            "managed continuity \(reason) exceeded its cancellation cleanup deadline"
        )
    }

    private static func boundedSeconds(
        _ interval: DispatchTimeInterval,
        fallback: TimeInterval
    ) -> TimeInterval {
        let seconds: TimeInterval
        switch interval {
        case .seconds(let value):
            seconds = TimeInterval(value)
        case .milliseconds(let value):
            seconds = TimeInterval(value) / 1_000
        case .microseconds(let value):
            seconds = TimeInterval(value) / 1_000_000
        case .nanoseconds(let value):
            seconds = TimeInterval(value) / 1_000_000_000
        case .never:
            seconds = fallback
        @unknown default:
            seconds = fallback
        }
        return min(60, max(0.025, seconds.isFinite ? seconds : fallback))
    }

    private func buildHandoff(
        arguments: [String: Any],
        cancellation: ToolCallCancellation?
    ) throws -> ContinuityHandoff {
        try cancellation?.checkCancellation()
        let projectID = try requiredProjectID(arguments)
        let descriptor = try memory.identities.descriptor(
            projectID: projectID,
            cancellation: cancellation
        )
        try cancellation?.checkCancellation()
        let operationID = string(arguments, "operation_id") ?? UUID().uuidString.lowercased()
        let handoffID = string(arguments, "handoff_id") ?? UUID().uuidString.lowercased()
        let predecessor = try requiredString(arguments, "predecessor_session_id")
        let repositoryRoot = string(arguments, "repository_root") ?? descriptor.aliases.last ?? "."
        let mission = try requiredString(arguments, "mission")
        let phase = string(arguments, "phase_id") ?? "unknown"
        let workItem = string(arguments, "work_item_id") ?? phase
        let summary = string(arguments, "summary") ?? mission
        let adapterID = string(arguments, "adapter_id") ?? "external-mcp"
        let budgetSource = string(arguments, "context_budget_source") ?? "caller_reported"
        let actionStrings = strings(arguments["next_actions"])
        let actions = (actionStrings.isEmpty ? ["Continue current work"] : actionStrings)
            .prefix(ContinuityHandoff.maximumListItems).enumerated().map { index, action in
                ["order": index + 1, "action": action, "command": "", "success_condition": "Action completed and checkpointed"] as [String: Any]
            }
        let project: [String: Any] = [
            "project_id": projectID, "display_name": descriptor.displayName,
            "repository_root": repositoryRoot, "branch": string(arguments, "branch") ?? "unknown",
            "commit": string(arguments, "commit") ?? "0000000",
            "dirty_summary": strings(arguments["dirty_summary"]),
        ]
        let predecessorSection: [String: Any] = [
            "session_id": predecessor, "provider_session_id": string(arguments, "provider_session_id") as Any,
            "model": string(arguments, "model") as Any,
        ]
        let handoff = try ContinuityHandoff(
            handoffID: handoffID, operationID: operationID, project: project,
            predecessorSession: predecessorSection, mission: mission,
            constraints: strings(arguments["constraints"]),
            currentWork: [
                "phase_id": phase, "work_item_id": workItem, "summary": summary,
                "active_files": strings(arguments["active_files"]),
            ],
            openWork: strings(arguments["open_work"]).map { ["summary": $0] },
            decisions: strings(arguments["decisions"]).map { ["summary": $0] },
            validation: [
                "passed_gates": strings(arguments["passed_gates"]),
                "open_gates": strings(arguments["open_gates"]),
                "commands": [] as [[String: Any]],
            ],
            memoryReferences: strings(arguments["memory_record_ids"]).map { ["record_id": $0] },
            evidenceReferences: strings(arguments["evidence_ids"]).map { ["evidence_id": $0] },
            nextActions: actions,
            hostState: [
                "adapter_id": adapterID, "continuity_state": ContinuityState.checkpointPreparing.rawValue,
                "context_budget_source": budgetSource,
                "remaining_budget_estimate": arguments["remaining_budget_estimate"] as Any,
                "retry": [:] as [String: Any],
            ]
        ).validated()
        try cancellation?.checkCancellation()
        return handoff
    }

    private func prepareV2(
        arguments: [String: Any],
        cancellation: ToolCallCancellation?
    ) throws -> [String: Any] {
        try cancellation?.checkCancellation()
        let handoff = try buildHandoffV2(
            arguments: arguments,
            cancellation: cancellation
        )
        let predecessor = try requiredString(arguments, "predecessor_session_id")
        let adapterID = try requiredString(arguments, "adapter_id")
        let idempotency = string(arguments, "idempotency_key") ?? handoff.operationID
        let predecessorResponse = string(arguments, "provider_response_id")
        let prepared = try coordinator.engine.prepareV2Outcome(
            handoff: handoff,
            predecessorSessionID: predecessor,
            predecessorProviderResponseID: predecessorResponse,
            adapterID: adapterID,
            idempotencyKey: idempotency,
            budgetObservationID: string(arguments, "budget_observation_id"),
            cancellation: cancellation
        )
        let operation = prepared.operation
        didPrepareDurableObserver?()
        // prepareV2 returned only after storing this exact validated handoff.
        // A secondary readback cannot be allowed to conceal that committed result.
        return [
            "ok": true,
            "disposition": "memory_only_handoff_ready",
            "operation_id": operation.operationID,
            "operation": operation.asDictionary(),
            "handoff": prepared.handoff.asDictionary(),
            "projection_repair_pending": prepared.projectionRepairPending,
            "handoff_schema_version": ContinuityHandoffV2.schemaVersion,
            "canonical_location": "project_local",
            "global_latest_authority": false,
            "host_capability": "external_session_creation_unconfirmed",
        ]
    }

    private func buildHandoffV2(
        arguments: [String: Any],
        cancellation: ToolCallCancellation?
    ) throws -> ContinuityHandoffV2 {
        try cancellation?.checkCancellation()
        let projectID = try requiredProjectID(arguments)
        let descriptor = try memory.identities.descriptor(
            projectID: projectID,
            cancellation: cancellation
        )
        try cancellation?.checkCancellation()
        guard let projectGeneration = unsigned(arguments["project_generation"]),
              projectGeneration > 0 else {
            throw ProjectMemoryError.invalidRequest("project_generation is required for V2")
        }
        let runID = try requiredString(arguments, "run_id").lowercased()
        guard UUID(uuidString: runID) != nil else {
            throw ProjectMemoryError.invalidRequest("run_id must be a UUID")
        }
        let modeValue = string(arguments, "continuity_mode")
            ?? ContinuityMode.externalMCPCompatibility.rawValue
        guard let mode = ContinuityMode(rawValue: modeValue) else {
            throw ProjectMemoryError.invalidRequest("continuity_mode is invalid")
        }
        let operationID = string(arguments, "operation_id") ?? UUID().uuidString.lowercased()
        let handoffID = string(arguments, "handoff_id") ?? UUID().uuidString.lowercased()
        let predecessor = try requiredString(arguments, "predecessor_session_id")
        let adapterID = try requiredString(arguments, "adapter_id")
        let providerID = try requiredString(arguments, "provider_id")
        let model = try requiredString(arguments, "model")
        let mission = try requiredString(arguments, "mission")
        let phase = string(arguments, "phase_id") ?? "unknown"
        let workItem = string(arguments, "work_item_id") ?? phase
        let summary = string(arguments, "summary") ?? mission
        let repositoryRoot = string(arguments, "repository_root") ?? descriptor.aliases.last ?? "."
        guard let capacity = integer(arguments["context_capacity"]), capacity > 0,
              let used = integer(arguments["context_used"]), used >= 0,
              let reserved = integer(arguments["context_reserved"]), reserved >= 0,
              let remaining = integer(arguments["context_remaining"]),
              let confidence = decimal(arguments["context_confidence"]),
              let budgetSource = string(arguments, "context_budget_source"),
              let budgetAction = string(arguments, "context_action"),
              let budgetTrigger = string(arguments, "context_trigger") else {
            throw ProjectMemoryError.invalidRequest(
                "V2 context capacity, usage, reserve, remaining, source, confidence, action, and trigger are required"
            )
        }
        let nonce = string(arguments, "bootstrap_nonce") ?? (
            UUID().uuidString.replacingOccurrences(of: "-", with: "")
                + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        ).lowercased()
        let actionStrings = strings(arguments["next_actions"])
        let actions = (actionStrings.isEmpty ? ["Continue current work"] : actionStrings)
            .enumerated().map { index, action in
                [
                    "order": index,
                    "action": action,
                    "command": "",
                    "success_condition": "Action completed and checkpointed",
                    "replay_class": "reconciled",
                ] as [String: Any]
            }
        let openWork = strings(arguments["open_work"]).enumerated().map { index, summary in
            [
                "id": "open-\(index)",
                "summary": summary,
                "status": "open",
            ] as [String: Any]
        }
        let decisions = strings(arguments["decisions"]).map { decision in
            [
                "decision": decision,
                "evidence": [] as [String],
            ] as [String: Any]
        }
        let assignment: Any = string(arguments, "assignment_id").map { $0 as Any } ?? NSNull()
        let providerResponse: Any = string(arguments, "provider_response_id").map { $0 as Any } ?? NSNull()
        let handoff = try ContinuityHandoffV2(
            handoffID: handoffID,
            operationID: operationID,
            project: [
                "project_id": projectID,
                "generation": Int(projectGeneration),
                "display_name": descriptor.displayName,
                "repository_root": repositoryRoot,
                "branch": string(arguments, "branch") ?? "",
                "commit": string(arguments, "commit") ?? "",
                "dirty_summary": strings(arguments["dirty_summary"]),
            ],
            run: [
                "run_id": runID,
                "continuity_mode": mode.rawValue,
                "assignment_id": assignment,
            ],
            predecessorSession: [
                "session_id": predecessor,
                "provider_id": providerID,
                "provider_response_id": providerResponse,
                "adapter_id": adapterID,
                "model": model,
            ],
            mission: mission,
            constraints: strings(arguments["constraints"]),
            currentWork: [
                "phase_id": phase,
                "work_item_id": workItem,
                "summary": summary,
                "active_files": strings(arguments["active_files"]),
            ],
            openWork: openWork,
            decisions: decisions,
            validation: [
                "passed_gates": strings(arguments["passed_gates"]),
                "open_gates": strings(arguments["open_gates"]),
                "commands": [] as [[String: Any]],
            ],
            memoryReferences: [],
            evidenceReferences: [],
            nextActions: actions,
            contextBudget: [
                "capacity": capacity,
                "used": used,
                "reserved": reserved,
                "remaining": remaining,
                "source": budgetSource,
                "confidence": confidence,
                "action": budgetAction,
                "trigger": budgetTrigger,
            ],
            bootstrap: [
                "nonce": nonce,
                "acknowledgement_contract_version": 2,
            ]
        ).validated()
        try cancellation?.checkCancellation()
        return handoff
    }

    private func requiredProjectID(_ arguments: [String: Any]) throws -> String {
        let value = try requiredString(arguments, "project_id").lowercased()
        guard UUID(uuidString: value) != nil else { throw ProjectMemoryError.invalidRequest("project_id must be a UUID") }
        return value
    }

    private func requiredString(_ arguments: [String: Any], _ key: String) throws -> String {
        guard let value = string(arguments, key), !value.isEmpty else {
            throw ProjectMemoryError.invalidRequest("\(key) is required")
        }
        return value
    }

    private func string(_ arguments: [String: Any], _ key: String) -> String? {
        ToolArgHelpers.string(arguments, key)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func strings(_ value: Any?) -> [String] {
        if let values = value as? [String] { return values }
        if let values = value as? [Any] { return values.compactMap { $0 as? String } }
        return []
    }

    private func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private func unsigned(_ value: Any?) -> UInt64? {
        guard let value = integer(value), value >= 0 else { return nil }
        return UInt64(value)
    }

    private func decimal(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }
}

private final class BlockingContinuityResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?

    func store(_ value: Result<Value, Error>) {
        lock.lock()
        result = value
        lock.unlock()
    }

    func take() -> Result<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}
