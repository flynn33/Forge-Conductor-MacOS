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

    public init(memory: ProjectMemoryService) {
        self.memory = memory
        self.coordinator = ContinuityCoordinator(engine: ContinuityStateEngine(memory: memory))
    }

    public func prepare(arguments: [String: Any]) throws -> [String: Any] {
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

    public func pending(arguments: [String: Any]) throws -> [String: Any] {
        let projectID = try requiredProjectID(arguments)
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
}
