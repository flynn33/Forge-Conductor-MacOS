// ContinuityToolPack.swift
// What: MCP tools for context handoff and agent continuity resume.
// How: Thin pack delegates to ContextContinuityService on ForgeApp.
// Why: Keeps continuity tools modular like other tool packs; stdio-only surface.

import Foundation
import CoreFoundation

/// Context + agent continuity tools (stdio MCP).
public struct ContinuityToolPack: ToolPackHandling {
    public init() {}

    /// The manager broker enters this path only while the control plane holds a
    /// live provisional grant. Decoded tool context cannot select this overload.
    /// Exact restoration never adopts a workspace or clears a predecessor fence.
    static func provisionalContextGet(
        arguments: [String: Any],
        identity: ContinuityHandoffIdentity,
        authorization: ContinuityIngressAuthorization,
        continuity: ContextContinuityService,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ToolResult {
        try cancellation?.checkCancellation()
        guard Set(arguments.keys).isSubset(of: ["handoff_id", "id", "resume_ready"]) else {
            throw ContinuityIngressError.invalidRequest("bootstrap_context_get_arguments")
        }
        let identifiers = ["handoff_id", "id"].compactMap { arguments[$0] }
        guard !identifiers.isEmpty, identifiers.allSatisfy({ value in
            guard let value = value as? String else { return false }
            return value == identity.continuityID
        }) else {
            throw ContinuityIngressError.invalidRequest("bootstrap_context_get_exact_id")
        }
        if let value = arguments["resume_ready"] {
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                throw ContinuityIngressError.invalidRequest("bootstrap_context_get_resume_ready")
            }
        }
        let revision = try continuity.authorizedHandoff(
            identity: identity, authorization: authorization, cancellation: cancellation
        )
        guard revision.resumeReady,
              let packet = try JSONSerialization.jsonObject(with: revision.canonicalPacketJSON) as? [String: Any] else {
            throw ContinuityIngressError.invalidRequest("bootstrap_context_get_resume_packet")
        }
        let result = ToolResult(ok: true, payload: [
            "ok": true, "found": true, "packet": packet,
            "continuity_id": identity.continuityID, "revision": identity.revision,
            "packet_sha256": identity.packetSHA256,
        ])
        let bytes = try ForgeJSONCanonicalizationV1.data(from: [
            "ok": result.ok, "is_error": result.isError, "payload": result.payload,
        ])
        guard bytes.count <= min(authorization.authorizationScope.maximumInlineOutputBytes,
                                 ToolInvocationBroker.maximumDurableResultBytes) else {
            throw AutonomyError.resultTooLarge
        }
        try cancellation?.checkCancellation()
        return result
    }

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
