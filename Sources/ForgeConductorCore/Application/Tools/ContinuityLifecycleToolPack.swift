// ContinuityLifecycleToolPack.swift
// What: Exposes the durable continuity state machine through additive MCP tools.
// How: Synchronous control operations commit state and external creation remains capability-gated.
// Why: MCP-only clients can exchange exact handoffs without falsely claiming chat creation.

import Foundation

public struct ContinuityLifecycleToolPack: ToolPackHandling {
    public static let names = [
        "continuity.checkpoint", "continuity.prepare_handoff",
        "continuity.get_pending_handoff", "continuity.acknowledge_handoff",
        "continuity.resume", "continuity.status", "continuity.request_rollover",
    ]

    public init() {}
    public var toolNames: [String] { Self.names }

    public func handle(
        name: String,
        arguments: [String: Any],
        context: ToolInvocationContext?,
        clientID: ClientID,
        app: ForgeApp,
        cancellation: ToolCallCancellation?
    ) throws -> ToolResult? {
        guard Self.names.contains(name) else { return nil }
        do {
            try cancellation?.checkCancellation()
            let payload: [String: Any]
            switch name {
            case "continuity.checkpoint":
                payload = try app.continuityControl.checkpoint(
                    arguments: arguments,
                    cancellation: cancellation
                )
            case "continuity.prepare_handoff":
                payload = try app.continuityControl.prepareHandoff(
                    arguments: arguments,
                    cancellation: cancellation
                )
            case "continuity.request_rollover":
                payload = try app.continuityControl.requestRollover(
                    arguments: arguments,
                    cancellation: cancellation
                )
            case "continuity.get_pending_handoff":
                payload = try app.continuityControl.pending(
                    arguments: arguments,
                    cancellation: cancellation
                )
            case "continuity.acknowledge_handoff":
                payload = try app.continuityControl.acknowledge(
                    arguments: arguments,
                    cancellation: cancellation
                )
            case "continuity.resume":
                payload = try app.continuityControl.resume(
                    arguments: arguments,
                    cancellation: cancellation
                )
            case "continuity.status":
                payload = try app.continuityControl.status(
                    arguments: arguments,
                    cancellation: cancellation
                )
            default:
                throw ProjectMemoryError.invalidRequest("unknown continuity tool")
            }
            return .success(payload)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ToolCallDeadlineExceeded {
            throw error
        } catch let error as ProjectMemoryError {
            return .failure(code: error.code, message: error.localizedDescription, retryable: error == .databaseBusy)
        } catch {
            return .failure(code: "invalid_request", message: error.localizedDescription)
        }
    }

    public static func description(for name: String) -> String? {
        [
            "continuity.checkpoint": "Persist a compact project checkpoint and rollover operation.",
            "continuity.prepare_handoff": "Build and persist a canonical successor handoff.",
            "continuity.get_pending_handoff": "Fetch the latest unsealed project handoff.",
            "continuity.acknowledge_handoff": "Compare-and-set acknowledgment for an exact successor and handoff.",
            "continuity.resume": "Seal an acknowledged rollover and atomically select the successor.",
            "continuity.status": "Report durable continuity state, retry metadata, and active session.",
            "continuity.request_rollover": "Queue managed rollover work, or prepare an external handoff when the host is handoff-only.",
        ][name]
    }

    public static func schema(for name: String) -> [String: Any]? {
        guard names.contains(name) else { return nil }
        let string: [String: Any] = ["type": "string"]
        let array: [String: Any] = ["type": "array", "items": string, "maxItems": ContinuityHandoff.maximumListItems]
        func object(_ properties: [String: Any], required: [String]) -> [String: Any] {
            ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
        }
        switch name {
        case "continuity.checkpoint", "continuity.prepare_handoff", "continuity.request_rollover":
            return object([
                "project_id": string, "operation_id": string, "handoff_id": string,
                "predecessor_session_id": string, "provider_session_id": string, "model": string,
                "mission": string, "constraints": array, "phase_id": string, "work_item_id": string,
                "summary": string, "repository_root": string, "branch": string, "commit": string,
                "dirty_summary": array, "active_files": array, "open_work": array,
                "decisions": array, "passed_gates": array, "open_gates": array,
                "memory_record_ids": array, "evidence_ids": array, "next_actions": array,
                "adapter_id": string, "idempotency_key": string,
                "requested_by": string, "reason": string,
                "project_generation": ["type": "integer", "minimum": 1],
                "run_id": string,
                "assignment_id": string,
                "continuity_mode": [
                    "type": "string",
                    "enum": ContinuityMode.allCases.map(\.rawValue),
                ],
                "provider_id": string,
                "provider_response_id": string,
                "bootstrap_nonce": string,
                "budget_observation_id": string,
                "context_capacity": ["type": "integer", "minimum": 1],
                "context_used": ["type": "integer", "minimum": 0],
                "context_reserved": ["type": "integer", "minimum": 0],
                "context_remaining": ["type": "integer"],
                "context_confidence": ["type": "number", "minimum": 0, "maximum": 1],
                "context_action": [
                    "type": "string",
                    "enum": ["checkpoint", "rollover", "emergency"],
                ],
                "context_trigger": string,
                "context_budget_source": string,
                "remaining_budget_estimate": ["type": "number"],
            ], required: ["project_id", "predecessor_session_id", "mission"])
        case "continuity.acknowledge_handoff":
            return object([
                "project_id": string, "operation_id": string, "handoff_id": string,
                "successor_session_id": string, "adapter_id": string,
            ], required: ["project_id", "operation_id", "handoff_id", "successor_session_id"])
        case "continuity.resume":
            return object(["project_id": string, "operation_id": string], required: ["project_id", "operation_id"])
        default:
            return object(["project_id": string], required: ["project_id"])
        }
    }
}
