// ContinuityV2Models.swift
// Defines exact project-scoped handoff, bootstrap, and manager-command contracts.

import Foundation
import CoreFoundation

/// The sole byte encoding used by the V2 handoff integrity boundary.
/// Legacy JSON digests intentionally retain their existing encoder.
public enum ForgeJSONCanonicalizationV1 {
    public static let identifier = "forge-json-c14n-v1"

    public static func data(from object: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw ProjectMemoryError.invalidRequest(
                "forge-json-c14n-v1 requires a valid JSON object or array"
            )
        }
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    public static func sha256Hex(of object: Any) throws -> String {
        JSONSupport.sha256Hex(try data(from: object))
    }
}

public enum ContinuityMode: String, Codable, Sendable, CaseIterable {
    case managedAutonomous
    case externalMCPCompatibility
}

public struct ContinuityOperationV2: Sendable, Equatable {
    public static let schemaVersion = 2

    public var operationID: String
    public var projectID: String
    public var projectGeneration: UInt64
    public var runID: String
    public var predecessorSessionID: String
    public var predecessorProviderResponseID: String?
    public var successorSessionID: String?
    public var successorProviderResponseID: String?
    public var handoffID: String
    public var state: ContinuityState
    public var attempt: Int
    public var adapterID: String
    public var idempotencyKey: String
    public var bootstrapNonce: String
    public var acknowledgementSHA256: String?
    public var budgetObservationID: String?
    public var continuationIssued: Bool
    public var quarantineState: String?
    public var migrationSource: String?
    public var legacyRecordID: String?
    public var acknowledgedSessionID: String?
    public var acknowledgedHandoffID: String?
    public var createdAt: String
    public var updatedAt: String
    public var lastError: String?
    public var retryAt: String?
    public var stateChecksum: String

    public var projectIdentity: ProjectID? {
        UUID(uuidString: projectID).map(ProjectID.init)
    }

    public var generation: ProjectGeneration { ProjectGeneration(projectGeneration) }

    public var runIdentity: RunID? {
        UUID(uuidString: runID).map(RunID.init)
    }

    public func asDictionary() -> [String: Any] {
        [
            "schema_version": Self.schemaVersion,
            "operation_id": operationID,
            "project_id": projectID,
            "project_generation": projectGeneration,
            "run_id": runID,
            "predecessor_session_id": predecessorSessionID,
            "predecessor_provider_response_id": predecessorProviderResponseID as Any,
            "successor_session_id": successorSessionID as Any,
            "successor_provider_response_id": successorProviderResponseID as Any,
            "handoff_id": handoffID,
            "state": state.rawValue,
            "attempt": attempt,
            "adapter_id": adapterID,
            "idempotency_key": idempotencyKey,
            "bootstrap_nonce": bootstrapNonce,
            "acknowledgement_sha256": acknowledgementSHA256 as Any,
            "budget_observation_id": budgetObservationID as Any,
            "continuation_issued": continuationIssued,
            "quarantine_state": quarantineState as Any,
            "migration_source": migrationSource as Any,
            "legacy_record_id": legacyRecordID as Any,
            "acknowledged_session_id": acknowledgedSessionID as Any,
            "acknowledged_handoff_id": acknowledgedHandoffID as Any,
            "created_at": createdAt,
            "updated_at": updatedAt,
            "last_error": lastError as Any,
            "retry_at": retryAt as Any,
            "state_checksum": stateChecksum,
        ]
    }
}

public struct ContinuityHandoffV2: @unchecked Sendable {
    public static let schemaVersion = "2.0"
    public static let canonicalizationVersion = ForgeJSONCanonicalizationV1.identifier
    public static let targetEncodedBytes = 64 * 1024
    public static let maximumEncodedBytes = 128 * 1024
    public static let maximumListItems = 128

    public var handoffID: String
    public var operationID: String
    public var createdAt: String
    public var project: [String: Any]
    public var run: [String: Any]
    public var predecessorSession: [String: Any]
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
    public var contextBudget: [String: Any]
    public var bootstrap: [String: Any]
    public var contentSHA256: String
    public var redactionComplete: Bool

    public init(
        handoffID: String = UUID().uuidString.lowercased(),
        operationID: String,
        createdAt: String = ISO8601.string(from: Date()),
        project: [String: Any],
        run: [String: Any],
        predecessorSession: [String: Any],
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
        contextBudget: [String: Any],
        bootstrap: [String: Any],
        contentSHA256: String = "",
        redactionComplete: Bool = true
    ) {
        self.handoffID = handoffID
        self.operationID = operationID
        self.createdAt = createdAt
        self.project = project
        self.run = run
        self.predecessorSession = predecessorSession
        self.mission = mission
        self.constraints = constraints
        self.currentWork = currentWork
        self.completedWork = completedWork
        self.openWork = openWork
        self.decisions = decisions
        self.validation = validation
        self.memoryReferences = memoryReferences
        self.evidenceReferences = evidenceReferences
        self.nextActions = nextActions
        self.contextBudget = contextBudget
        self.bootstrap = bootstrap
        self.contentSHA256 = contentSHA256
        self.redactionComplete = redactionComplete
    }

    public var projectID: String? { project["project_id"] as? String }
    public var projectGeneration: UInt64? { Self.unsignedInteger(project["generation"]) }
    public var runID: String? { run["run_id"] as? String }
    public var continuityMode: ContinuityMode? {
        (run["continuity_mode"] as? String).flatMap(ContinuityMode.init(rawValue:))
    }
    public var bootstrapNonce: String? { bootstrap["nonce"] as? String }

    public func validated() throws -> ContinuityHandoffV2 {
        guard UUID(uuidString: handoffID) != nil, UUID(uuidString: operationID) != nil else {
            throw ProjectMemoryError.invalidRequest("handoff_id and operation_id must be UUIDs")
        }
        guard ISO8601.date(from: createdAt) != nil else {
            throw ProjectMemoryError.invalidRequest("created_at must be an ISO-8601 timestamp")
        }
        guard Self.hasExactKeys(
            project,
            [
                "project_id", "generation", "display_name", "repository_root",
                "branch", "commit", "dirty_summary",
            ]
        ), Self.hasExactKeys(run, ["run_id", "continuity_mode", "assignment_id"]),
        Self.hasExactKeys(
            predecessorSession,
            ["session_id", "provider_id", "provider_response_id", "adapter_id", "model"]
        ), Self.hasExactKeys(validation, ["passed_gates", "open_gates", "commands"]),
        Self.hasExactKeys(
            contextBudget,
            ["capacity", "used", "reserved", "remaining", "source", "confidence", "action", "trigger"]
        ), Self.hasExactKeys(
            bootstrap,
            ["nonce", "acknowledgement_contract_version"]
        ) else {
            throw ProjectMemoryError.invalidRequest("V2 handoff contains unsupported section fields")
        }
        guard let projectID, UUID(uuidString: projectID) != nil,
              let generation = projectGeneration,
              generation > 0, generation <= UInt64(Int64.max),
              Self.nonempty(project["display_name"]), Self.nonempty(project["repository_root"]),
              project["branch"] is String, project["commit"] is String,
              let dirty = project["dirty_summary"] as? [String], dirty.count <= Self.maximumListItems else {
            throw ProjectMemoryError.invalidRequest("V2 project identity is incomplete")
        }
        try Self.requireBytes(project["display_name"] as? String, maximum: 512, field: "project.display_name")
        try Self.requireBytes(project["repository_root"] as? String, maximum: 4_096, field: "project.repository_root")
        try Self.requireBytes(project["branch"] as? String, maximum: 1_024, field: "project.branch")
        try Self.requireBytes(project["commit"] as? String, maximum: 256, field: "project.commit")
        try Self.requireStrings(dirty, maximumBytes: 4_096, field: "project.dirty_summary")
        guard let runID, UUID(uuidString: runID) != nil,
              continuityMode != nil, run.keys.contains("assignment_id") else {
            throw ProjectMemoryError.invalidRequest("V2 run identity is incomplete")
        }
        if !(run["assignment_id"] is NSNull) {
            guard let assignment = run["assignment_id"] as? String else {
                throw ProjectMemoryError.invalidRequest("run.assignment_id must be a string or null")
            }
            try Self.requireBytes(assignment, maximum: 1_024, field: "run.assignment_id")
        }
        guard Self.nonempty(predecessorSession["session_id"]),
              Self.nonempty(predecessorSession["provider_id"]),
              predecessorSession.keys.contains("provider_response_id"),
              Self.nonempty(predecessorSession["adapter_id"]),
              Self.nonempty(predecessorSession["model"]),
              !mission.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProjectMemoryError.invalidRequest("V2 predecessor or mission is incomplete")
        }
        try Self.requireBytes(predecessorSession["session_id"] as? String, maximum: 1_024, field: "predecessor.session_id")
        try Self.requireBytes(predecessorSession["provider_id"] as? String, maximum: 256, field: "predecessor.provider_id")
        if !(predecessorSession["provider_response_id"] is NSNull) {
            try Self.requireBytes(
                predecessorSession["provider_response_id"] as? String,
                maximum: 2_048,
                field: "predecessor.provider_response_id"
            )
        }
        try Self.requireBytes(predecessorSession["adapter_id"] as? String, maximum: 256, field: "predecessor.adapter_id")
        try Self.requireBytes(predecessorSession["model"] as? String, maximum: 1_024, field: "predecessor.model")
        try Self.requireBytes(mission, maximum: 16_384, field: "mission")
        try Self.requireStrings(constraints, maximumBytes: 4_096, field: "constraints")
        guard Self.nonempty(currentWork["phase_id"]), Self.nonempty(currentWork["work_item_id"]),
              Self.nonempty(currentWork["summary"]),
              let activeFiles = currentWork["active_files"] as? [String],
              activeFiles.count <= Self.maximumListItems,
              let passedGates = validation["passed_gates"] as? [String],
              let openGates = validation["open_gates"] as? [String],
              let validationCommands = validation["commands"] as? [[String: Any]],
              validationCommands.count <= Self.maximumListItems,
              !nextActions.isEmpty else {
            throw ProjectMemoryError.invalidRequest("V2 work or validation sections are incomplete")
        }
        try Self.requireBytes(currentWork["phase_id"] as? String, maximum: 512, field: "current_work.phase_id")
        try Self.requireBytes(currentWork["work_item_id"] as? String, maximum: 512, field: "current_work.work_item_id")
        try Self.requireBytes(currentWork["summary"] as? String, maximum: 16_384, field: "current_work.summary")
        try Self.requireStrings(activeFiles, maximumBytes: 4_096, field: "current_work.active_files")
        try Self.validateLists([constraints, activeFiles, passedGates, openGates])
        try Self.requireStrings(passedGates, maximumBytes: 512, field: "validation.passed_gates")
        try Self.requireStrings(openGates, maximumBytes: 512, field: "validation.open_gates")
        guard completedWork.count <= Self.maximumListItems,
              openWork.count <= Self.maximumListItems,
              decisions.count <= Self.maximumListItems,
              memoryReferences.count <= Self.maximumListItems,
              evidenceReferences.count <= Self.maximumListItems,
              nextActions.count <= Self.maximumListItems else {
            throw ProjectMemoryError.payloadTooLarge("V2 handoff list exceeds \(Self.maximumListItems) entries")
        }
        for (index, item) in (completedWork + openWork).enumerated() {
            guard Self.nonempty(item["id"]), Self.nonempty(item["summary"]),
                  Self.nonempty(item["status"]) else {
                throw ProjectMemoryError.invalidRequest("work item[\(index)] is incomplete")
            }
            try Self.requireBytes(item["id"] as? String, maximum: 512, field: "work item id")
            try Self.requireBytes(item["summary"] as? String, maximum: 8_192, field: "work item summary")
            try Self.requireBytes(item["status"] as? String, maximum: 256, field: "work item status")
        }
        for (index, decision) in decisions.enumerated() {
            guard Self.nonempty(decision["decision"]),
                  let evidence = decision["evidence"] as? [String],
                  evidence.count <= 32 else {
                throw ProjectMemoryError.invalidRequest("decisions[\(index)] is incomplete")
            }
            try Self.requireBytes(decision["decision"] as? String, maximum: 8_192, field: "decision")
            try Self.requireStrings(evidence, maximumBytes: 4_096, field: "decision evidence")
        }
        for (index, reference) in (memoryReferences + evidenceReferences).enumerated() {
            let required: Set<String> = ["id", "kind", "sha256"]
            let allowed = required.union(["summary"])
            guard Set(reference.keys).isSuperset(of: required),
                  Set(reference.keys).isSubset(of: allowed),
                  Self.nonempty(reference["id"]), Self.nonempty(reference["kind"]),
                  let hash = reference["sha256"] as? String, Self.isLowercaseSHA256(hash) else {
                throw ProjectMemoryError.invalidRequest("reference[\(index)] is invalid")
            }
            try Self.requireBytes(reference["id"] as? String, maximum: 1_024, field: "reference id")
            try Self.requireBytes(reference["kind"] as? String, maximum: 256, field: "reference kind")
            if let summary = reference["summary"] as? String {
                try Self.requireBytes(summary, maximum: 4_096, field: "reference summary")
            }
        }
        for (index, action) in nextActions.enumerated() {
            let required: Set<String> = ["order", "action", "command", "success_condition"]
            let allowed = required.union(["replay_class"])
            guard Set(action.keys).isSuperset(of: required),
                  Set(action.keys).isSubset(of: allowed),
                  Self.unsignedInteger(action["order"]) != nil,
                  Self.nonempty(action["action"]), action["command"] is String,
                  Self.nonempty(action["success_condition"]) else {
                throw ProjectMemoryError.invalidRequest("next_actions[\(index)] is incomplete")
            }
            try Self.requireBytes(action["action"] as? String, maximum: 8_192, field: "next action")
            try Self.requireBytes(action["command"] as? String, maximum: 8_192, field: "next action command")
            try Self.requireBytes(
                action["success_condition"] as? String,
                maximum: 8_192,
                field: "next action success condition"
            )
            if let replay = action["replay_class"] as? String,
               !["read_only", "idempotent", "reconciled", "non_replayable"].contains(replay) {
                throw ProjectMemoryError.invalidRequest("next_actions[\(index)].replay_class is invalid")
            }
        }
        guard let capacity = Self.integer(contextBudget["capacity"]), capacity > 0,
              let used = Self.integer(contextBudget["used"]), used >= 0,
              let reserved = Self.integer(contextBudget["reserved"]), reserved >= 0,
              Self.integer(contextBudget["remaining"]) != nil,
              ["provider_exact", "tokenizer_exact", "serialized_estimate", "provider_overflow"]
                .contains(contextBudget["source"] as? String ?? ""),
              let confidence = Self.double(contextBudget["confidence"]), (0...1).contains(confidence),
              ["checkpoint", "rollover", "emergency"]
                .contains(contextBudget["action"] as? String ?? ""),
              Self.nonempty(contextBudget["trigger"]) else {
            throw ProjectMemoryError.invalidRequest("V2 context budget is incomplete")
        }
        guard let nonce = bootstrapNonce, (32...512).contains(nonce.utf8.count),
              Self.integer(bootstrap["acknowledgement_contract_version"]) == 2,
              redactionComplete else {
            throw ProjectMemoryError.invalidRequest("V2 bootstrap or redaction contract is invalid")
        }
        try Self.requireBytes(contextBudget["trigger"] as? String, maximum: 2_048, field: "context_budget.trigger")
        var copy = self
        let calculated = copy.calculatedSHA256()
        if !contentSHA256.isEmpty {
            guard Self.isLowercaseSHA256(contentSHA256), contentSHA256 == calculated else {
                throw ProjectMemoryError.integrityFailure("V2 handoff content SHA-256 does not match")
            }
        }
        copy.contentSHA256 = calculated
        let encoded = try ForgeJSONCanonicalizationV1.data(from: copy.asDictionary())
        guard encoded.count <= Self.maximumEncodedBytes else {
            throw ProjectMemoryError.payloadTooLarge("V2 handoff exceeds \(Self.maximumEncodedBytes) bytes")
        }
        return copy
    }

    public func asDictionary() -> [String: Any] {
        [
            "schema_version": Self.schemaVersion,
            "handoff_id": handoffID,
            "operation_id": operationID,
            "created_at": createdAt,
            "project": project,
            "run": run,
            "predecessor_session": predecessorSession,
            "mission": mission,
            "constraints": constraints,
            "current_work": currentWork,
            "completed_work": completedWork,
            "open_work": openWork,
            "decisions": decisions,
            "validation": validation,
            "memory_references": memoryReferences,
            "evidence_references": evidenceReferences,
            "next_actions": nextActions,
            "context_budget": contextBudget,
            "bootstrap": bootstrap,
            "integrity": [
                "canonicalization_version": Self.canonicalizationVersion,
                "content_sha256": contentSHA256,
                "redaction_complete": redactionComplete,
            ] as [String: Any],
        ]
    }

    public func calculatedSHA256() -> String {
        var payload = asDictionary()
        payload.removeValue(forKey: "integrity")
        return (try? ForgeJSONCanonicalizationV1.sha256Hex(of: payload)) ?? ""
    }

    public func encodedJSON() throws -> Data {
        try ForgeJSONCanonicalizationV1.data(from: asDictionary())
    }

    public static func fromDictionary(_ value: [String: Any]) -> ContinuityHandoffV2? {
        let requiredTopLevel: Set<String> = [
            "schema_version", "handoff_id", "operation_id", "created_at", "project", "run",
            "predecessor_session", "mission", "constraints", "current_work", "completed_work",
            "open_work", "decisions", "validation", "memory_references",
            "evidence_references", "next_actions", "context_budget", "bootstrap", "integrity",
        ]
        guard Set(value.keys) == requiredTopLevel,
              value["schema_version"] as? String == schemaVersion,
              let handoffID = value["handoff_id"] as? String,
              let operationID = value["operation_id"] as? String,
              let createdAt = value["created_at"] as? String,
              let project = value["project"] as? [String: Any],
              let run = value["run"] as? [String: Any],
              let predecessor = value["predecessor_session"] as? [String: Any],
              let mission = value["mission"] as? String,
              let constraints = value["constraints"] as? [String],
              let currentWork = value["current_work"] as? [String: Any],
              let completedWork = value["completed_work"] as? [[String: Any]],
              let openWork = value["open_work"] as? [[String: Any]],
              let decisions = value["decisions"] as? [[String: Any]],
              let validation = value["validation"] as? [String: Any],
              let memoryReferences = value["memory_references"] as? [[String: Any]],
              let evidenceReferences = value["evidence_references"] as? [[String: Any]],
              let nextActions = value["next_actions"] as? [[String: Any]],
              let contextBudget = value["context_budget"] as? [String: Any],
              let bootstrap = value["bootstrap"] as? [String: Any],
              let integrity = value["integrity"] as? [String: Any],
              Set(integrity.keys) == Set([
                "canonicalization_version", "content_sha256", "redaction_complete",
              ]),
              integrity["canonicalization_version"] as? String == canonicalizationVersion,
              let contentSHA256 = integrity["content_sha256"] as? String,
              isLowercaseSHA256(contentSHA256),
              let redactionComplete = integrity["redaction_complete"] as? Bool else {
            return nil
        }
        let candidate = ContinuityHandoffV2(
            handoffID: handoffID,
            operationID: operationID,
            createdAt: createdAt,
            project: project,
            run: run,
            predecessorSession: predecessor,
            mission: mission,
            constraints: constraints,
            currentWork: currentWork,
            completedWork: completedWork,
            openWork: openWork,
            decisions: decisions,
            validation: validation,
            memoryReferences: memoryReferences,
            evidenceReferences: evidenceReferences,
            nextActions: nextActions,
            contextBudget: contextBudget,
            bootstrap: bootstrap,
            contentSHA256: contentSHA256,
            redactionComplete: redactionComplete
        )
        return try? candidate.validated()
    }

    private static func validateLists(_ lists: [[String]]) throws {
        for list in lists {
            guard list.count <= maximumListItems else {
                throw ProjectMemoryError.payloadTooLarge("V2 handoff list exceeds \(maximumListItems) entries")
            }
        }
    }

    private static func hasExactKeys(_ value: [String: Any], _ keys: Set<String>) -> Bool {
        Set(value.keys) == keys
    }

    private static func requireBytes(_ value: String?, maximum: Int, field: String) throws {
        guard let value, value.utf8.count <= maximum else {
            throw ProjectMemoryError.payloadTooLarge("\(field) exceeds \(maximum) bytes")
        }
    }

    private static func requireStrings(
        _ values: [String],
        maximumBytes: Int,
        field: String
    ) throws {
        for value in values {
            try requireBytes(value, maximum: maximumBytes, field: field)
        }
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        let range = value.startIndex..<value.endIndex
        return value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) == range
    }

    private static func nonempty(_ value: Any?) -> Bool {
        guard let value = value as? String else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func integer(_ value: Any?) -> Int? {
        if isBoolean(value) { return nil }
        if let value = value as? Int { return value }
        if let value = value as? NSNumber {
            let decimal = value.doubleValue
            guard decimal.isFinite,
                  decimal.rounded(.towardZero) == decimal,
                  decimal >= Double(Int.min), decimal <= Double(Int.max) else {
                return nil
            }
            return value.intValue
        }
        return nil
    }

    private static func unsignedInteger(_ value: Any?) -> UInt64? {
        guard let integer = integer(value), integer >= 0 else { return nil }
        return UInt64(integer)
    }

    private static func double(_ value: Any?) -> Double? {
        if isBoolean(value) { return nil }
        if let value = value as? Double { return value }
        if let value = value as? NSNumber, value.doubleValue.isFinite {
            return value.doubleValue
        }
        return nil
    }

    private static func isBoolean(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}

public struct BootstrapChallenge: Codable, Sendable, Equatable {
    public let nonce: String
    public let acknowledgementContractVersion: Int

    public init(nonce: String, acknowledgementContractVersion: Int = 2) {
        self.nonce = nonce
        self.acknowledgementContractVersion = acknowledgementContractVersion
    }
}

public struct BootstrapAcknowledgementV2: Codable, Sendable, Equatable {
    public let acknowledgementContractVersion: Int
    public let projectID: ProjectID
    public let projectGeneration: ProjectGeneration
    public let runID: RunID
    public let operationID: UUID
    public let handoffID: UUID
    public let handoffSHA256: String
    public let nonce: String
    public let accepted: Bool

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case acknowledgementContractVersion = "acknowledgement_contract_version"
        case projectID = "project_id"
        case projectGeneration = "project_generation"
        case runID = "run_id"
        case operationID = "operation_id"
        case handoffID = "handoff_id"
        case handoffSHA256 = "handoff_sha256"
        case nonce, accepted
    }

    private struct WireFieldKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }

        init?(intValue: Int) {
            self.stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    public init(
        acknowledgementContractVersion: Int = 2,
        projectID: ProjectID,
        projectGeneration: ProjectGeneration,
        runID: RunID,
        operationID: UUID,
        handoffID: UUID,
        handoffSHA256: String,
        nonce: String,
        accepted: Bool = true
    ) {
        self.acknowledgementContractVersion = acknowledgementContractVersion
        self.projectID = projectID
        self.projectGeneration = projectGeneration
        self.runID = runID
        self.operationID = operationID
        self.handoffID = handoffID
        self.handoffSHA256 = handoffSHA256
        self.nonce = nonce
        self.accepted = accepted
    }

    public init(from decoder: any Decoder) throws {
        let wireContainer = try decoder.container(keyedBy: WireFieldKey.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let suppliedKeys = Set(wireContainer.allKeys.map(\.stringValue))
        let requiredKeys = Set(CodingKeys.allCases.map(\.rawValue))
        guard suppliedKeys == requiredKeys else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "bootstrap acknowledgement fields must exactly match the V2 schema"
                )
            )
        }

        let contractVersion = try container.decode(
            Int.self,
            forKey: .acknowledgementContractVersion
        )
        let projectIDString = try container.decode(String.self, forKey: .projectID)
        let generation = try container.decode(UInt64.self, forKey: .projectGeneration)
        let runIDString = try container.decode(String.self, forKey: .runID)
        let operationIDString = try container.decode(String.self, forKey: .operationID)
        let handoffIDString = try container.decode(String.self, forKey: .handoffID)
        let checksum = try container.decode(String.self, forKey: .handoffSHA256)
        let nonce = try container.decode(String.self, forKey: .nonce)
        let accepted = try container.decode(Bool.self, forKey: .accepted)

        guard contractVersion == 2,
              generation > 0,
              generation <= UInt64(Int64.max),
              let projectUUID = UUID(uuidString: projectIDString),
              let runUUID = UUID(uuidString: runIDString),
              let operationUUID = UUID(uuidString: operationIDString),
              let handoffUUID = UUID(uuidString: handoffIDString),
              Self.isLowercaseSHA256(checksum),
              (32...512).contains(nonce.count),
              accepted else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "bootstrap acknowledgement violates the exact V2 wire schema"
                )
            )
        }

        self.init(
            acknowledgementContractVersion: contractVersion,
            projectID: ProjectID(projectUUID),
            projectGeneration: ProjectGeneration(generation),
            runID: RunID(runUUID),
            operationID: operationUUID,
            handoffID: handoffUUID,
            handoffSHA256: checksum,
            nonce: nonce,
            accepted: accepted
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(
            acknowledgementContractVersion,
            forKey: .acknowledgementContractVersion
        )
        try container.encode(projectID.description, forKey: .projectID)
        try container.encode(projectGeneration.rawValue, forKey: .projectGeneration)
        try container.encode(runID.description, forKey: .runID)
        try container.encode(operationID.uuidString.lowercased(), forKey: .operationID)
        try container.encode(handoffID.uuidString.lowercased(), forKey: .handoffID)
        try container.encode(handoffSHA256, forKey: .handoffSHA256)
        try container.encode(nonce, forKey: .nonce)
        try container.encode(accepted, forKey: .accepted)
    }

    public func validate(handoff: ContinuityHandoffV2) throws {
        guard acknowledgementContractVersion == 2,
              projectID.description == handoff.projectID,
              projectGeneration.rawValue == handoff.projectGeneration,
              runID.description == handoff.runID,
              operationID.uuidString.caseInsensitiveCompare(handoff.operationID) == .orderedSame,
              handoffID.uuidString.caseInsensitiveCompare(handoff.handoffID) == .orderedSame,
              handoffSHA256 == handoff.contentSHA256,
              nonce == handoff.bootstrapNonce,
              accepted else {
            throw ProjectMemoryError.conflict("bootstrap acknowledgement does not match the exact V2 handoff")
        }
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        let range = value.startIndex..<value.endIndex
        return value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) == range
    }
}

public struct SessionCreationRequestV2: Sendable, Equatable {
    public let operationID: UUID
    public let projectID: ProjectID
    public let projectGeneration: ProjectGeneration
    public let runID: RunID
    public let predecessorSessionID: String
    public let modelKey: String
    public let idempotencyKey: String

    public init(
        operationID: UUID,
        projectID: ProjectID,
        projectGeneration: ProjectGeneration,
        runID: RunID,
        predecessorSessionID: String,
        modelKey: String,
        idempotencyKey: String
    ) {
        self.operationID = operationID
        self.projectID = projectID
        self.projectGeneration = projectGeneration
        self.runID = runID
        self.predecessorSessionID = predecessorSessionID
        self.modelKey = modelKey
        self.idempotencyKey = idempotencyKey
    }
}

public struct BootstrapReceipt: Sendable, Equatable {
    public let acknowledgement: BootstrapAcknowledgementV2
    public let internalSessionID: String
    public let providerResponseID: String
    public let modelKey: String
    public let adapterID: String
    public let usage: ContextBudgetStatus?
    public let createdAt: String

    public init(
        acknowledgement: BootstrapAcknowledgementV2,
        internalSessionID: String,
        providerResponseID: String,
        modelKey: String,
        adapterID: String,
        usage: ContextBudgetStatus? = nil,
        createdAt: String = ISO8601.string(from: Date())
    ) {
        self.acknowledgement = acknowledgement
        self.internalSessionID = internalSessionID
        self.providerResponseID = providerResponseID
        self.modelKey = modelKey
        self.adapterID = adapterID
        self.usage = usage
        self.createdAt = createdAt
    }
}

public struct HostCapabilitiesV2: Sendable, Equatable {
    public let atomicCreateAndBootstrap: Bool
    public let freshRoot: Bool
    public let usageReporting: Bool
    public let idempotencyLookup: Bool
    public let projectGenerationFencing: Bool

    public init(
        atomicCreateAndBootstrap: Bool,
        freshRoot: Bool,
        usageReporting: Bool,
        idempotencyLookup: Bool,
        projectGenerationFencing: Bool
    ) {
        self.atomicCreateAndBootstrap = atomicCreateAndBootstrap
        self.freshRoot = freshRoot
        self.usageReporting = usageReporting
        self.idempotencyLookup = idempotencyLookup
        self.projectGenerationFencing = projectGenerationFencing
    }
}

public protocol SessionHostAdapterV2: Sendable {
    var identifier: String { get }
    var version: String { get }
    func capabilitiesV2() async throws -> HostCapabilitiesV2
    func createAndBootstrap(
        request: SessionCreationRequestV2,
        handoffJSON: Data,
        challenge: BootstrapChallenge
    ) async throws -> BootstrapReceipt
    func receipt(forIdempotencyKey key: String) async throws -> BootstrapReceipt?
    func cancel(operationID: UUID) async
}

public enum ContinuityCommandType: String, Codable, Sendable, CaseIterable {
    case checkpoint
    case rollover
    case emergencyRollover = "emergency_rollover"
    case recover
}

public enum ContinuityCommandState: String, Codable, Sendable, CaseIterable {
    case queued
    case claimed
    case running
    case completed
    case retryWait = "retry_wait"
    case failed
    case cancelled
}

public struct ContinuityCommand: Codable, Sendable, Equatable {
    public let commandID: UUID
    public let operationID: UUID
    public let runID: RunID
    public let projectID: ProjectID
    public let projectGeneration: ProjectGeneration
    public let type: ContinuityCommandType
    public let requestedBy: String
    public let reason: String
    public let state: ContinuityCommandState
    public let idempotencyKey: String
    public let payloadSHA256: String
    public let attempt: Int
    public let retryAt: String?
    public let lastErrorCode: String?
    public let lastErrorSummary: String?
    public let createdAt: String
    public let updatedAt: String

    public func asDictionary() -> [String: Any] {
        [
            "command_id": commandID.uuidString.lowercased(),
            "operation_id": operationID.uuidString.lowercased(),
            "run_id": runID.description,
            "project_id": projectID.description,
            "project_generation": projectGeneration.rawValue,
            "command_type": type.rawValue,
            "requested_by": requestedBy,
            "reason": reason,
            "state": state.rawValue,
            "idempotency_key": idempotencyKey,
            "payload_sha256": payloadSHA256,
            "attempt": attempt,
            "retry_at": retryAt as Any,
            "last_error_code": lastErrorCode as Any,
            "last_error_summary": lastErrorSummary as Any,
            "created_at": createdAt,
            "updated_at": updatedAt,
        ]
    }
}

public struct ContinuityCommandRequest: Sendable, Equatable {
    public let operationID: UUID
    public let runID: RunID
    public let projectID: ProjectID
    public let projectGeneration: ProjectGeneration
    public let type: ContinuityCommandType
    public let requestedBy: String
    public let reason: String
    public let idempotencyKey: String
    public let payloadSHA256: String

    public init(
        operationID: UUID,
        runID: RunID,
        projectID: ProjectID,
        projectGeneration: ProjectGeneration,
        type: ContinuityCommandType,
        requestedBy: String,
        reason: String,
        idempotencyKey: String,
        payloadSHA256: String
    ) {
        self.operationID = operationID
        self.runID = runID
        self.projectID = projectID
        self.projectGeneration = projectGeneration
        self.type = type
        self.requestedBy = requestedBy
        self.reason = reason
        self.idempotencyKey = idempotencyKey
        self.payloadSHA256 = payloadSHA256
    }
}

public enum ContinuityCommandQueueError: Error, LocalizedError, Equatable, Sendable {
    case runNotFound(RunID)
    case commandNotFound(UUID)
    case invalidCommand(String)
    case invalidTransition(ContinuityCommandState, ContinuityCommandState)
    case claimConflict

    public var errorDescription: String? {
        switch self {
        case .runNotFound(let runID): "Autonomous run not found: \(runID)"
        case .commandNotFound(let commandID): "Continuity command not found: \(commandID.uuidString.lowercased())"
        case .invalidCommand(let reason): "Invalid continuity command: \(reason)"
        case .invalidTransition(let from, let to):
            "Invalid continuity command transition: \(from.rawValue) -> \(to.rawValue)"
        case .claimConflict: "Continuity command was claimed by another manager"
        }
    }
}

public struct LegacyContinuityMigrationReceipt: Sendable, Equatable {
    public let receiptID: String
    public let projectID: String
    public let importedCount: Int
    public let skippedCount: Int
    public let quarantinedCount: Int
    public let startedAt: String
    public let completedAt: String

    public func asDictionary() -> [String: Any] {
        [
            "receipt_id": receiptID,
            "project_id": projectID,
            "source_version": "legacy_global",
            "target_version": ContinuityHandoffV2.schemaVersion,
            "imported_count": importedCount,
            "skipped_count": skippedCount,
            "quarantined_count": quarantinedCount,
            "started_at": startedAt,
            "completed_at": completedAt,
        ]
    }
}
