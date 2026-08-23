// ContinuityModels.swift
// What: Defines durable rollover states, compact handoffs, budgets, and host contracts.
// How: Versioned values expose strict dictionaries at MCP and SQLite boundaries.
// Why: Session rollover must be replayable without relying on an in-memory chat transcript.

import Foundation

public enum ContinuityState: String, CaseIterable, Codable, Sendable {
    case active
    case checkpointPreparing
    case checkpointPersisted
    case successorRequested
    case successorCreated
    case successorBootstrapping
    case successorAcknowledged
    case predecessorSealed

    public var isTerminal: Bool { self == .predecessorSealed }

    public var next: ContinuityState? {
        switch self {
        case .active: .checkpointPreparing
        case .checkpointPreparing: .checkpointPersisted
        case .checkpointPersisted: .successorRequested
        case .successorRequested: .successorCreated
        case .successorCreated: .successorBootstrapping
        case .successorBootstrapping: .successorAcknowledged
        case .successorAcknowledged: .predecessorSealed
        case .predecessorSealed: nil
        }
    }
}

public struct ContinuityOperation: Sendable, Equatable {
    public var operationID: String
    public var projectID: String
    public var predecessorSessionID: String
    public var successorSessionID: String?
    public var handoffID: String
    public var state: ContinuityState
    public var attempt: Int
    public var adapterID: String
    public var idempotencyKey: String
    public var acknowledgedSessionID: String?
    public var acknowledgedHandoffID: String?
    public var createdAt: String
    public var updatedAt: String
    public var lastError: String?
    public var retryAt: String?
    public var stateChecksum: String

    public func asDictionary() -> [String: Any] {
        [
            "operation_id": operationID, "project_id": projectID,
            "predecessor_session_id": predecessorSessionID,
            "successor_session_id": successorSessionID as Any,
            "handoff_id": handoffID, "state": state.rawValue, "attempt": attempt,
            "adapter_id": adapterID, "idempotency_key": idempotencyKey,
            "acknowledged_session_id": acknowledgedSessionID as Any,
            "acknowledged_handoff_id": acknowledgedHandoffID as Any,
            "created_at": createdAt, "updated_at": updatedAt,
            "last_error": lastError as Any, "retry_at": retryAt as Any,
            "state_checksum": stateChecksum,
        ]
    }
}

public struct ContinuityHandoff: @unchecked Sendable {
    public static let schemaVersion = "1.0"
    public static let maximumEncodedBytes = 128 * 1024
    public static let maximumListItems = 128

    public var handoffID: String
    public var operationID: String
    public var createdAt: String
    public var project: [String: Any]
    public var predecessorSession: [String: Any]
    public var successorSession: [String: Any]?
    public var mission: String
    public var constraints: [String]
    public var currentWork: [String: Any]
    public var completedWork: [[String: Any]]
    public var openWork: [[String: Any]]
    public var decisions: [[String: Any]]
    public var validation: [String: Any]
    public var memoryReferences: [[String: Any]]
    public var evidenceReferences: [[String: Any]]
    public var nextActions: [[String: Any]]
    public var hostState: [String: Any]
    public var contentSHA256: String
    public var redactionComplete: Bool

    public init(
        handoffID: String = UUID().uuidString.lowercased(),
        operationID: String,
        createdAt: String = ISO8601.string(from: Date()),
        project: [String: Any],
        predecessorSession: [String: Any],
        successorSession: [String: Any]? = nil,
        mission: String,
        constraints: [String] = [],
        currentWork: [String: Any],
        completedWork: [[String: Any]] = [],
        openWork: [[String: Any]] = [],
        decisions: [[String: Any]] = [],
        validation: [String: Any] = ["passed_gates": [], "open_gates": [], "commands": []],
        memoryReferences: [[String: Any]] = [],
        evidenceReferences: [[String: Any]] = [],
        nextActions: [[String: Any]],
        hostState: [String: Any],
        contentSHA256: String = "",
        redactionComplete: Bool = true
    ) {
        self.handoffID = handoffID
        self.operationID = operationID
        self.createdAt = createdAt
        self.project = project
        self.predecessorSession = predecessorSession
        self.successorSession = successorSession
        self.mission = mission
        self.constraints = Array(constraints.prefix(Self.maximumListItems))
        self.currentWork = currentWork
        self.completedWork = Array(completedWork.prefix(Self.maximumListItems))
        self.openWork = Array(openWork.prefix(Self.maximumListItems))
        self.decisions = Array(decisions.prefix(Self.maximumListItems))
        self.validation = validation
        self.memoryReferences = Array(memoryReferences.prefix(Self.maximumListItems))
        self.evidenceReferences = Array(evidenceReferences.prefix(Self.maximumListItems))
        self.nextActions = Array(nextActions.prefix(Self.maximumListItems))
        self.hostState = hostState
        self.contentSHA256 = contentSHA256
        self.redactionComplete = redactionComplete
    }

    public func validated() throws -> ContinuityHandoff {
        guard UUID(uuidString: handoffID) != nil, UUID(uuidString: operationID) != nil else {
            throw ProjectMemoryError.invalidRequest("handoff_id and operation_id must be UUIDs")
        }
        guard let projectID = project["project_id"] as? String, UUID(uuidString: projectID) != nil,
              nonempty(project["display_name"]), nonempty(project["repository_root"]),
              nonempty(project["branch"]), nonempty(project["commit"]),
              project["dirty_summary"] is [String] else {
            throw ProjectMemoryError.invalidRequest("project handoff section is incomplete")
        }
        guard nonempty(predecessorSession["session_id"]),
              predecessorSession.keys.contains("provider_session_id"), predecessorSession.keys.contains("model"),
              !mission.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              nonempty(currentWork["phase_id"]), nonempty(currentWork["work_item_id"]),
              nonempty(currentWork["summary"]), currentWork["active_files"] is [String],
              validation["passed_gates"] is [String], validation["open_gates"] is [String],
              validation["commands"] is [[String: Any]],
              nonempty(hostState["adapter_id"]), nonempty(hostState["continuity_state"]),
              nonempty(hostState["context_budget_source"]), hostState["retry"] is [String: Any],
              !nextActions.isEmpty else {
            throw ProjectMemoryError.invalidRequest("handoff semantic sections are incomplete")
        }
        for (index, action) in nextActions.enumerated() {
            guard action["order"] is Int, nonempty(action["action"]),
                  action["command"] is String, nonempty(action["success_condition"]) else {
                throw ProjectMemoryError.invalidRequest("next_actions[\(index)] is incomplete")
            }
        }
        var copy = self
        copy.contentSHA256 = copy.calculatedSHA256()
        let encoded = try JSONSupport.data(from: copy.asDictionary())
        guard encoded.count <= Self.maximumEncodedBytes else {
            throw ProjectMemoryError.payloadTooLarge("handoff exceeds \(Self.maximumEncodedBytes) bytes")
        }
        return copy
    }

    public func asDictionary() -> [String: Any] {
        [
            "schema_version": Self.schemaVersion, "handoff_id": handoffID,
            "operation_id": operationID, "created_at": createdAt,
            "project": project, "predecessor_session": predecessorSession,
            "successor_session": successorSession as Any, "mission": mission,
            "constraints": constraints, "current_work": currentWork,
            "completed_work": completedWork, "open_work": openWork, "decisions": decisions,
            "validation": validation, "memory_references": memoryReferences,
            "evidence_references": evidenceReferences, "next_actions": nextActions,
            "host_state": hostState,
            "integrity": ["content_sha256": contentSHA256, "redaction_complete": redactionComplete] as [String: Any],
        ]
    }

    public func calculatedSHA256() -> String {
        var copy = asDictionary()
        copy["integrity"] = ["content_sha256": String(repeating: "0", count: 64), "redaction_complete": redactionComplete]
        return JSONSupport.sha256Hex((try? JSONSupport.canonicalJSON(copy)) ?? "")
    }

    public static func fromDictionary(_ value: [String: Any]) -> ContinuityHandoff? {
        guard value["schema_version"] as? String == schemaVersion,
              let handoffID = value["handoff_id"] as? String,
              let operationID = value["operation_id"] as? String,
              let createdAt = value["created_at"] as? String,
              let project = value["project"] as? [String: Any],
              let predecessor = value["predecessor_session"] as? [String: Any],
              let mission = value["mission"] as? String,
              let constraints = value["constraints"] as? [String],
              let current = value["current_work"] as? [String: Any],
              let completed = value["completed_work"] as? [[String: Any]],
              let open = value["open_work"] as? [[String: Any]],
              let decisions = value["decisions"] as? [[String: Any]],
              let validation = value["validation"] as? [String: Any],
              let memory = value["memory_references"] as? [[String: Any]],
              let evidence = value["evidence_references"] as? [[String: Any]],
              let actions = value["next_actions"] as? [[String: Any]],
              let host = value["host_state"] as? [String: Any],
              let integrity = value["integrity"] as? [String: Any],
              let hash = integrity["content_sha256"] as? String,
              let redacted = integrity["redaction_complete"] as? Bool else { return nil }
        let successor: [String: Any]?
        if value["successor_session"] is NSNull || value["successor_session"] == nil {
            successor = nil
        } else {
            guard let parsed = value["successor_session"] as? [String: Any] else { return nil }
            successor = parsed
        }
        return ContinuityHandoff(
            handoffID: handoffID, operationID: operationID, createdAt: createdAt,
            project: project, predecessorSession: predecessor, successorSession: successor,
            mission: mission, constraints: constraints, currentWork: current,
            completedWork: completed, openWork: open, decisions: decisions,
            validation: validation, memoryReferences: memory, evidenceReferences: evidence,
            nextActions: actions, hostState: host, contentSHA256: hash, redactionComplete: redacted
        )
    }

    private func nonempty(_ value: Any?) -> Bool {
        guard let value = value as? String else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum ContextBudgetAction: String, Sendable { case normal, checkpoint, rollover, emergency }

public struct ContextBudgetStatus: Sendable, Equatable {
    public var capacity: Int
    public var used: Int
    public var reserved: Int
    public var remaining: Int
    public var source: String
    public var confidence: Double
    public var action: ContextBudgetAction

    public func asDictionary() -> [String: Any] {
        ["capacity": capacity, "used": used, "reserved": reserved, "remaining": remaining,
         "source": source, "confidence": confidence, "action": action.rawValue]
    }
}

public struct ContextBudgetMonitor: Sendable {
    public var checkpointReserveFraction: Double = 0.20
    public var rolloverReserveFraction: Double = 0.10

    public init() {}

    public func exact(capacity: Int, used: Int, reserved: Int) throws -> ContextBudgetStatus {
        try evaluate(capacity: capacity, used: used, reserved: reserved, source: "provider_exact", confidence: 1)
    }

    public func estimated(capacity: Int, serializedBytes: Int, reserved: Int) throws -> ContextBudgetStatus {
        let estimatedTokens = Int(ceil(Double(max(serializedBytes, 0)) / 3.5))
        return try evaluate(capacity: capacity, used: estimatedTokens, reserved: reserved, source: "serialized_estimate", confidence: 0.65)
    }

    public func overflow(capacity: Int, reserved: Int) throws -> ContextBudgetStatus {
        var result = try evaluate(capacity: capacity, used: capacity, reserved: reserved, source: "provider_overflow", confidence: 1)
        result.action = .emergency
        return result
    }

    private func evaluate(capacity: Int, used: Int, reserved: Int, source: String, confidence: Double) throws -> ContextBudgetStatus {
        guard capacity > 0, used >= 0, reserved >= 0, reserved < capacity else {
            throw ProjectMemoryError.invalidRequest("context budget values are invalid")
        }
        let remaining = max(0, capacity - used - reserved)
        let usable = max(1, capacity - reserved)
        let fraction = Double(remaining) / Double(usable)
        let action: ContextBudgetAction
        if fraction <= rolloverReserveFraction { action = .rollover }
        else if fraction <= checkpointReserveFraction { action = .checkpoint }
        else { action = .normal }
        return ContextBudgetStatus(capacity: capacity, used: used, reserved: reserved, remaining: remaining, source: source, confidence: confidence, action: action)
    }
}

public struct HostCapabilities: Sendable, Equatable {
    public var create: Bool
    public var bootstrap: Bool
    public var usageReporting: Bool
    public var resume: Bool
    public var idempotency: Bool
    public var queryByIdempotencyKey: Bool

    public init(create: Bool, bootstrap: Bool, usageReporting: Bool, resume: Bool, idempotency: Bool, queryByIdempotencyKey: Bool) {
        self.create = create; self.bootstrap = bootstrap; self.usageReporting = usageReporting
        self.resume = resume; self.idempotency = idempotency; self.queryByIdempotencyKey = queryByIdempotencyKey
    }
}

public struct HostSession: Sendable, Equatable {
    public var id: String
    public var providerSessionID: String?
    public var model: String?
    public init(id: String, providerSessionID: String? = nil, model: String? = nil) {
        self.id = id; self.providerSessionID = providerSessionID; self.model = model
    }
}

public struct SessionCreationRequest: Sendable {
    public var operationID: String
    public var projectID: String
    public var predecessorSessionID: String
    public var idempotencyKey: String
}

public struct HandoffAcknowledgement: Sendable, Equatable {
    public var handoffID: String
    public var successorSessionID: String
    public var adapterID: String

    public init(handoffID: String, successorSessionID: String, adapterID: String) {
        self.handoffID = handoffID
        self.successorSessionID = successorSessionID
        self.adapterID = adapterID
    }
}

public protocol SessionHostAdapter: Sendable {
    var identifier: String { get }
    var version: String { get }
    func capabilities() async throws -> HostCapabilities
    func createSession(_ request: SessionCreationRequest) async throws -> HostSession
    func session(forIdempotencyKey key: String) async throws -> HostSession?
    func bootstrap(_ session: HostSession, handoff: ContinuityHandoff) async throws
    func awaitAcknowledgement(session: HostSession, handoffID: String, timeout: Duration) async throws -> HandoffAcknowledgement
    func cancel(operationID: String) async
}
