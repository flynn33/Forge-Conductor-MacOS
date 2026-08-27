// ContinuityToolPack.swift
// What: MCP tools for context handoff and agent continuity resume.
// How: Thin pack delegates to ContextContinuityService on ForgeApp.
// Why: Keeps continuity tools modular like other tool packs; stdio-only surface.

import Foundation

/// Context + agent continuity tools (stdio MCP).
public struct ContinuityToolPack: ToolPackHandling {
    public init() {}

    public var toolNames: [String] {
        [
            "session_checkpoint",
            "session_handoff",
            "context_get",
            "context_list",
        ]
    }

    public func handle(
        name: String,
        arguments: [String: Any],
        context: ToolInvocationContext?,
        clientID: ClientID,
        app: ForgeApp,
        cancellation: ToolCallCancellation?
    ) throws -> ToolResult? {
        guard toolNames.contains(name) else { return nil }
        try cancellation?.checkCancellation()
        switch name {
        case "session_checkpoint":
            let payload = try app.continuity.checkpoint(
                arguments: arguments,
                clientID: clientID,
                source: .model,
                cancellation: cancellation
            )
            return ToolResult(ok: true, payload: payload)
        case "session_handoff":
            let payload = try app.continuity.handoff(
                arguments: arguments,
                clientID: clientID,
                source: .model,
                cancellation: cancellation
            )
            return ToolResult(ok: true, payload: payload)
        case "context_get":
            let id = ToolArgHelpers.string(arguments, "handoff_id")
                ?? ToolArgHelpers.string(arguments, "id")
            let preferResume = ToolArgHelpers.bool(arguments, "resume_ready") ?? false
            var payload = try app.continuity.get(
                id: id,
                preferResumeReady: preferResume,
                cancellation: cancellation
            )
            try cancellation?.checkCancellation()
            if payload["found"] as? Bool == true,
               let packetObj = payload["packet"] as? [String: Any],
               let packet = HandoffPacket.fromDictionary(packetObj) {
                try app.continuityAutomation.adopt(
                    clientID: clientID,
                    packet: packet,
                    cancellation: cancellation
                )
                try app.continuityAutomation.clearBlock(
                    clientID: clientID,
                    cancellation: cancellation
                )
                payload["workspace_adopted"] = packet.cwd as Any
                payload["auto_continuity"] = try app.continuityAutomation.snapshot(
                    for: clientID,
                    cancellation: cancellation
                )
                payload["context_budget_cleared"] = true
            }
            return ToolResult(ok: true, payload: payload)
        case "context_list":
            let limit = ToolArgHelpers.int(arguments, "limit") ?? 10
            let payload = try app.continuity.list(limit: limit, cancellation: cancellation)
            try cancellation?.checkCancellation()
            return ToolResult(ok: true, payload: payload)
        default:
            return nil
        }
    }
}
