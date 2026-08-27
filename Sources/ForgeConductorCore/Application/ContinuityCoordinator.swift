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

public final class ContinuityStateEngine: @unchecked Sendable {
    private let memory: ProjectMemoryService

    public init(memory: ProjectMemoryService) { self.memory = memory }

    public func prepare(
        handoff: ContinuityHandoff,
        predecessorSessionID: String,
        adapterID: String,
        idempotencyKey: String,
        crashAfter: ContinuityCrashPoint? = nil
    ) throws -> ContinuityOperation {
        let validated = try handoff.validated()
        let repository = try memory.repositoryForProject(validated.project["project_id"] as? String ?? "")
        var operation = try repository.continuityCreateOperation(
            operationID: validated.operationID, predecessorSessionID: predecessorSessionID,
            handoffID: validated.handoffID, adapterID: adapterID, idempotencyKey: idempotencyKey
        )
        if operation.state == .active {
            // Persist the recovery payload before recording checkpoint intent so a restart at
            // checkpointPreparing can rebuild solely from the project ledger.
            try repository.continuityStoreHandoff(validated)
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
            operation = try repository.continuityTransition(
                operationID: operation.operationID, expected: .checkpointPreparing,
                to: .checkpointPersisted, evidence: validated.contentSHA256
            )
            if crashAfter == .checkpointPersisted {
                throw ContinuityRunError.injectedCrash(.checkpointPersisted)
            }
        }
        return operation
    }

    public func prepareV2(
        handoff: ContinuityHandoffV2,
        predecessorSessionID: String,
        predecessorProviderResponseID: String?,
        adapterID: String,
        idempotencyKey: String,
        budgetObservationID: String? = nil
    ) throws -> ContinuityOperationV2 {
        let validated = try handoff.validated()
        guard let projectID = validated.projectID else {
            throw ProjectMemoryError.invalidRequest("V2 handoff project_id is missing")
        }
        let repository = try memory.repositoryForProject(projectID)
        var operation = try repository.continuityCreateOperationV2(
            handoff: validated,
            predecessorSessionID: predecessorSessionID,
            predecessorProviderResponseID: predecessorProviderResponseID,
            adapterID: adapterID,
            idempotencyKey: idempotencyKey,
            budgetObservationID: budgetObservationID
        )
        if operation.state == .active {
            try repository.continuityStoreHandoffV2(validated)
            operation = try repository.continuityTransitionV2(
                operationID: operation.operationID,
                expected: .active,
                to: .checkpointPreparing,
                evidence: "v2_checkpoint_intent"
            )
        }
        if operation.state == .checkpointPreparing {
            try repository.continuityStoreHandoffV2(validated)
            operation = try repository.continuityTransitionV2(
                operationID: operation.operationID,
                expected: .checkpointPreparing,
                to: .checkpointPersisted,
                evidence: validated.contentSHA256
            )
        }
        return operation
    }

    public func operationV2(
        projectID: String,
        operationID: String
    ) throws -> ContinuityOperationV2? {
        try memory.repositoryForProject(projectID).continuityOperationV2(id: operationID)
    }

    public func activeOperationV2(projectID: String) throws -> ContinuityOperationV2? {
        try memory.repositoryForProject(projectID).continuityActiveOperationV2()
    }

    public func handoffV2(
        projectID: String,
        handoffID: String
    ) throws -> ContinuityHandoffV2? {
        try memory.repositoryForProject(projectID).continuityHandoffV2(id: handoffID)
    }

    public func transitionV2(
        projectID: String,
        operationID: String,
        expected: ContinuityState,
        to next: ContinuityState,
        successorSessionID: String? = nil,
        successorProviderResponseID: String? = nil,
        evidence: String? = nil
    ) throws -> ContinuityOperationV2 {
        try memory.repositoryForProject(projectID).continuityTransitionV2(
            operationID: operationID,
            expected: expected,
            to: next,
            successorSessionID: successorSessionID,
            successorProviderResponseID: successorProviderResponseID,
            evidence: evidence
        )
    }

    public func acknowledgeV2(
        projectID: String,
        operationID: String,
        receipt: BootstrapReceipt
    ) throws -> ContinuityOperationV2 {
        try memory.repositoryForProject(projectID).continuityAcknowledgeV2(
            operationID: operationID,
            receipt: receipt
        )
    }

    @discardableResult
    public func markContinuationIssuedV2(
        projectID: String,
        operationID: String
    ) throws -> Bool {
        try memory.repositoryForProject(projectID).continuityMarkContinuationIssuedV2(
            operationID: operationID
        )
    }

    public func operation(projectID: String, operationID: String) throws -> ContinuityOperation? {
        try memory.repositoryForProject(projectID).continuityOperation(id: operationID)
    }

    public func activeOperation(projectID: String) throws -> ContinuityOperation? {
        try memory.repositoryForProject(projectID).continuityActiveOperation()
    }

    public func handoff(projectID: String, handoffID: String) throws -> ContinuityHandoff? {
        try memory.repositoryForProject(projectID).continuityHandoff(id: handoffID)
    }

    public func transition(
        projectID: String,
        operationID: String,
        expected: ContinuityState,
        to next: ContinuityState,
        successorSessionID: String? = nil,
        evidence: String? = nil
    ) throws -> ContinuityOperation {
        try memory.repositoryForProject(projectID).continuityTransition(
            operationID: operationID, expected: expected, to: next,
            successorSessionID: successorSessionID, evidence: evidence
        )
    }

    public func adoptAndAcknowledgeExternalSuccessor(
        projectID: String,
        operationID: String,
        handoffID: String,
        successorSessionID: String,
        adapterID: String
    ) throws -> ContinuityOperation {
        let repository = try memory.repositoryForProject(projectID)
        guard var operation = try repository.continuityOperation(id: operationID) else {
            throw ProjectMemoryError.recordNotFound(operationID)
        }
        guard operation.adapterID == adapterID,
              operation.handoffID == handoffID,
              operation.successorSessionID == nil || operation.successorSessionID == successorSessionID else {
            throw ProjectMemoryError.conflict(
                "acknowledgment does not match exact handoff, successor, and adapter"
            )
        }
        if operation.state == .checkpointPersisted {
            operation = try repository.continuityTransition(
                operationID: operationID, expected: .checkpointPersisted,
                to: .successorRequested, evidence: "external_host_confirmed_create_intent"
            )
        }
        if operation.state == .successorRequested {
            operation = try repository.continuityTransition(
                operationID: operationID, expected: .successorRequested, to: .successorCreated,
                successorSessionID: successorSessionID, evidence: "external_host_confirmed_successor"
            )
        }
        if operation.state == .successorCreated {
            operation = try repository.continuityTransition(
                operationID: operationID, expected: .successorCreated,
                to: .successorBootstrapping, evidence: "external_host_confirmed_bootstrap"
            )
        }
        return try repository.continuityAcknowledge(
            operationID: operationID, handoffID: handoffID,
            successorSessionID: successorSessionID, adapterID: adapterID
        )
    }

    public func acknowledge(
        projectID: String,
        operationID: String,
        acknowledgement: HandoffAcknowledgement
    ) throws -> ContinuityOperation {
        try memory.repositoryForProject(projectID).continuityAcknowledge(
            operationID: operationID, handoffID: acknowledgement.handoffID,
            successorSessionID: acknowledgement.successorSessionID,
            adapterID: acknowledgement.adapterID
        )
    }

    public func seal(projectID: String, operationID: String) throws -> ContinuityOperation {
        try transition(
            projectID: projectID, operationID: operationID,
            expected: .successorAcknowledged, to: .predecessorSealed,
            evidence: "active_session_pointer_swapped"
        )
    }

    public func recordRetry(projectID: String, operationID: String, error: String) throws {
        try memory.repositoryForProject(projectID).continuityRecordRetry(
            operationID: operationID, error: error,
            retryAt: ISO8601.string(from: Date().addingTimeInterval(1))
        )
    }

    public func status(projectID: String) throws -> [String: Any] {
        let repository = try memory.repositoryForProject(projectID)
        if let operation = try repository.continuityActiveOperationV2() {
            let handoff = try repository.continuityHandoffV2(id: operation.handoffID)
            return [
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
                "active_session_id": try repository.continuityActiveSessionID() as Any,
                "retry": [
                    "error": operation.lastError as Any,
                    "retry_at": operation.retryAt as Any,
                ],
                "health": "ok",
                "schema_version": ContinuityOperationV2.schemaVersion,
            ]
        }
        let operation = try repository.continuityActiveOperation()
        return [
            "ok": true, "project_id": projectID,
            "state": operation?.state.rawValue ?? ContinuityState.active.rawValue,
            "operation": operation?.asDictionary() as Any,
            "pending_handoff_id": operation?.handoffID as Any,
            "active_session_id": try repository.continuityActiveSessionID() as Any,
            "retry": ["error": operation?.lastError as Any, "retry_at": operation?.retryAt as Any],
            "health": "ok", "schema_version": 1,
        ]
    }
}

/// Manager-owned async request path. It commits the project-local handoff first,
/// then durably enqueues one control-plane command before returning its operation ID.
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
        budgetObservationID: String? = nil
    ) async throws -> ContinuityCommand {
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
        let operation = try engine.prepareV2(
            handoff: validated,
            predecessorSessionID: predecessorSessionID,
            predecessorProviderResponseID: predecessorProviderResponseID,
            adapterID: adapterID,
            idempotencyKey: idempotencyKey,
            budgetObservationID: budgetObservationID
        )
        guard operation.state == .checkpointPersisted,
              let operationUUID = UUID(uuidString: operation.operationID) else {
            throw ProjectMemoryError.integrityFailure(
                "manager command cannot be queued before the V2 checkpoint is durable"
            )
        }
        let projectID = ProjectID(projectUUID)
        let projectGeneration = ProjectGeneration(generation)
        let runID = RunID(runUUID)
        try await controlPlane.reserveContinuityRun(
            runID: runID,
            projectID: projectID,
            projectGeneration: projectGeneration,
            assignmentID: validated.run["assignment_id"] as? String,
            mission: validated.mission,
            mode: .managedAutonomous
        )
        return try await controlPlane.enqueueContinuityCommand(
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
            )
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
    private let waitTimeout: DispatchTimeInterval

    public init(
        memory: ProjectMemoryService,
        controlPlane: ProjectControlPlaneRepository? = nil,
        waitTimeout: DispatchTimeInterval = .seconds(10)
    ) {
        self.memory = memory
        self.coordinator = ContinuityCoordinator(engine: ContinuityStateEngine(memory: memory))
        self.managedRouter = controlPlane.map {
            ManagedContinuityCommandRouter(memory: memory, controlPlane: $0)
        }
        self.waitTimeout = waitTimeout
    }

    public func prepare(arguments: [String: Any]) throws -> [String: Any] {
        if arguments["project_generation"] != nil || arguments["run_id"] != nil {
            return try prepareV2(arguments: arguments)
        }
        let handoff = try buildHandoff(arguments: arguments)
        let predecessor = try requiredString(arguments, "predecessor_session_id")
        let adapterID = string(arguments, "adapter_id") ?? "external-mcp"
        let idempotency = string(arguments, "idempotency_key") ?? handoff.operationID
        let operation = try coordinator.engine.prepare(
            handoff: handoff, predecessorSessionID: predecessor,
            adapterID: adapterID, idempotencyKey: idempotency
        )
        let durable = try coordinator.engine.handoff(
            projectID: operation.projectID, handoffID: operation.handoffID
        )
        return [
            "ok": true, "disposition": "memory_only_handoff_ready",
            "operation": operation.asDictionary(), "handoff": durable?.asDictionary() as Any,
            "host_capability": "external_session_creation_unconfirmed",
        ]
    }

    public func checkpoint(arguments: [String: Any]) throws -> [String: Any] {
        var payload = try prepare(arguments: arguments)
        payload["request_route"] = "checkpoint_only"
        payload["checkpoint_persisted"] = true
        payload["session_creation_confirmed"] = false
        return payload
    }

    public func prepareHandoff(arguments: [String: Any]) throws -> [String: Any] {
        var payload = try prepare(arguments: arguments)
        payload["request_route"] = "prepare_handoff"
        payload["handoff_prepared"] = true
        payload["session_creation_confirmed"] = false
        return payload
    }

    public func requestRollover(arguments: [String: Any]) throws -> [String: Any] {
        if string(arguments, "continuity_mode") == ContinuityMode.managedAutonomous.rawValue {
            return try requestManagedRollover(arguments: arguments)
        }
        var payload = try prepare(arguments: arguments)
        payload["request_route"] = "external_handoff_only"
        payload["external_capability"] = "handoff_only"
        payload["manager_operation_enqueued"] = false
        payload["session_creation_confirmed"] = false
        payload["disposition"] = "memory_only_handoff_ready"
        return payload
    }

    public func pending(arguments: [String: Any]) throws -> [String: Any] {
        let projectID = try requiredProjectID(arguments)
        if let operation = try coordinator.engine.activeOperationV2(projectID: projectID) {
            guard let handoff = try coordinator.engine.handoffV2(
                projectID: projectID,
                handoffID: operation.handoffID
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
        guard let operation = try coordinator.engine.activeOperation(projectID: projectID),
              let handoff = try coordinator.engine.handoff(projectID: projectID, handoffID: operation.handoffID) else {
            return ["ok": true, "found": false, "project_id": projectID]
        }
        return ["ok": true, "found": true, "operation": operation.asDictionary(), "handoff": handoff.asDictionary()]
    }

    public func acknowledge(arguments: [String: Any]) throws -> [String: Any] {
        let projectID = try requiredProjectID(arguments)
        let operation = try coordinator.engine.adoptAndAcknowledgeExternalSuccessor(
            projectID: projectID, operationID: try requiredString(arguments, "operation_id"),
            handoffID: try requiredString(arguments, "handoff_id"),
            successorSessionID: try requiredString(arguments, "successor_session_id"),
            adapterID: string(arguments, "adapter_id") ?? "external-mcp"
        )
        return ["ok": true, "operation": operation.asDictionary(), "acknowledged": true]
    }

    public func resume(arguments: [String: Any]) throws -> [String: Any] {
        let projectID = try requiredProjectID(arguments)
        let operation = try coordinator.engine.seal(
            projectID: projectID, operationID: try requiredString(arguments, "operation_id")
        )
        return ["ok": true, "operation": operation.asDictionary(), "resumed": true]
    }

    public func status(arguments: [String: Any]) throws -> [String: Any] {
        try coordinator.engine.status(projectID: requiredProjectID(arguments))
    }

    private func requestManagedRollover(arguments: [String: Any]) throws -> [String: Any] {
        guard let managedRouter else {
            throw ProjectMemoryError.integrityFailure(
                "managed continuity command queue is unavailable"
            )
        }
        let candidateHandoff = try buildHandoffV2(arguments: arguments)
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
            bootstrapNonceWasSupplied: arguments["bootstrap_nonce"] != nil
        )
        let requestedBy = string(arguments, "requested_by") ?? "continuity.request_rollover"
        let reason = string(arguments, "reason")
            ?? string(arguments, "context_trigger")
            ?? "managed rollover requested"
        let budgetObservationID = string(arguments, "budget_observation_id")
        let commandType: ContinuityCommandType = string(arguments, "context_action") == "emergency"
            ? .emergencyRollover
            : .rollover
        let command = try wait {
            try await managedRouter.request(
                handoff: handoff,
                predecessorSessionID: predecessorSessionID,
                predecessorProviderResponseID: predecessorProviderResponseID,
                adapterID: adapterID,
                idempotencyKey: idempotencyKey,
                requestedBy: requestedBy,
                reason: reason,
                commandType: commandType,
                budgetObservationID: budgetObservationID
            )
        }
        guard let operation = try coordinator.engine.operationV2(
            projectID: command.projectID.description,
            operationID: command.operationID.uuidString.lowercased()
        ), let durableHandoff = try coordinator.engine.handoffV2(
            projectID: command.projectID.description,
            handoffID: operation.handoffID
        ) else {
            throw ProjectMemoryError.integrityFailure(
                "queued managed operation could not be read back from project-local continuity"
            )
        }
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
            "handoff_schema_version": ContinuityHandoffV2.schemaVersion,
            "canonical_location": "project_local",
            "global_latest_authority": false,
        ]
    }

    private func reconciledManagedHandoff(
        _ candidate: ContinuityHandoffV2,
        idempotencyKey: String,
        bootstrapNonceWasSupplied: Bool
    ) throws -> ContinuityHandoffV2 {
        guard let projectID = candidate.projectID,
              let existing = try coordinator.engine.operationV2(
                projectID: projectID,
                operationID: candidate.operationID
              ) else {
            return candidate
        }
        guard existing.idempotencyKey == idempotencyKey,
              existing.handoffID == candidate.handoffID,
              existing.projectGeneration == candidate.projectGeneration,
              existing.runID == candidate.runID,
              let durable = try coordinator.engine.handoffV2(
                projectID: projectID,
                handoffID: existing.handoffID
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
        guard normalized.contentSHA256 == durable.contentSHA256 else {
            throw ProjectMemoryError.conflict(
                "managed rollover replay payload differs from the durable handoff"
            )
        }
        return durable
    }

    private func wait<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) throws -> Value {
        let semaphore = DispatchSemaphore(value: 0)
        let box = BlockingContinuityResult<Value>()
        Task.detached {
            do {
                box.store(.success(try await operation()))
            } catch {
                box.store(.failure(error))
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + waitTimeout) == .success else {
            throw ProjectMemoryError.databaseBusy
        }
        guard let result = box.take() else {
            throw ProjectMemoryError.integrityFailure(
                "managed continuity request completed without a result"
            )
        }
        return try result.get()
    }

    private func buildHandoff(arguments: [String: Any]) throws -> ContinuityHandoff {
        let projectID = try requiredProjectID(arguments)
        let descriptor = try memory.identities.descriptor(projectID: projectID)
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
        return try ContinuityHandoff(
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
    }

    private func prepareV2(arguments: [String: Any]) throws -> [String: Any] {
        let handoff = try buildHandoffV2(arguments: arguments)
        let predecessor = try requiredString(arguments, "predecessor_session_id")
        let adapterID = try requiredString(arguments, "adapter_id")
        let idempotency = string(arguments, "idempotency_key") ?? handoff.operationID
        let predecessorResponse = string(arguments, "provider_response_id")
        let operation = try coordinator.engine.prepareV2(
            handoff: handoff,
            predecessorSessionID: predecessor,
            predecessorProviderResponseID: predecessorResponse,
            adapterID: adapterID,
            idempotencyKey: idempotency,
            budgetObservationID: string(arguments, "budget_observation_id")
        )
        let durable = try coordinator.engine.handoffV2(
            projectID: operation.projectID,
            handoffID: operation.handoffID
        )
        return [
            "ok": true,
            "disposition": "memory_only_handoff_ready",
            "operation_id": operation.operationID,
            "operation": operation.asDictionary(),
            "handoff": durable?.asDictionary() as Any,
            "handoff_schema_version": ContinuityHandoffV2.schemaVersion,
            "canonical_location": "project_local",
            "global_latest_authority": false,
            "host_capability": "external_session_creation_unconfirmed",
        ]
    }

    private func buildHandoffV2(arguments: [String: Any]) throws -> ContinuityHandoffV2 {
        let projectID = try requiredProjectID(arguments)
        let descriptor = try memory.identities.descriptor(projectID: projectID)
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
        return try ContinuityHandoffV2(
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
