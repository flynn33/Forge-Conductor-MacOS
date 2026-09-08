// Public CLU controls require a native task channel independent of work-tool scope.

import Foundation

struct ContinuityControlToolPack: ToolPackHandling {
    var toolNames: [String] { ContinuityControlToolName.allCases.map(\.rawValue) }

    func handle(name: String, arguments: [String: Any], context: ToolInvocationContext?,
                clientID: ClientID, app: ForgeApp, cancellation: ToolCallCancellation?) throws -> ToolResult? {
        try Self.sharedConnectionResult(name: name, arguments: arguments, app: app, cancellation: cancellation)
    }

    /// A project binding, client ID or decoded invocation context is not a task
    /// correlation. Discovery and validation remain available on a shared stream;
    /// only the native task session can reach the mutating control services.
    static func sharedConnectionResult(
        name: String, arguments: [String: Any], app: ForgeApp,
        role: ContinuityControlCapabilities.Role = .primary,
        connected: Bool? = nil, cancellation: ToolCallCancellation?
    ) throws -> ToolResult? {
        guard ContinuityControlToolName(rawValue: name) != nil else { return nil }
        let response: ContinuityControlToolResponse
        do {
            try cancellation?.checkCancellation()
            let request = try ContinuityControlToolRequest(name: name, arguments: arguments)
            switch request {
            case .capabilities:
                response = .capabilities(.init(
                    deployed: nil, connected: connected, ready: false,
                    automaticHandoffEnabled: nil, exactIDSupport: true,
                    providerMode: .externalChat, taskIdentity: .unavailable, role: role,
                    deploymentID: nil, buildVersion: ForgeApp.version,
                    qualification: .init(nativeAPI: .unqualified, desktopNewChat: .notObserved,
                        guiClosedRecovery: .notObserved, laterRollover: .notObserved),
                    reasons: ["task_identity_unavailable", "deployment_not_observed"]
                ))
            case .start, .status, .cancel:
                response = .failure(.init(.taskIdentityUnavailable))
            }
        } catch {
            response = .failure(.mapping(error))
        }
        let result = try response.toolResult()
        app.diagnostics.info("continuity_control_response", [
            "tool": name, "ok": result.ok ? "true" : "false", "task_identity": "unavailable",
        ], category: .tools)
        return result
    }
}
