// ToolRouter.swift
// What: Dispatches named tool calls to independently registered tool-pack modules.
// How: It indexes handlers by declared names, authorizes each invocation, applies
// output limits, and records a sanitized audit result around the selected handler.
// Why: Connectors depend on one stable execution port while tool packs remain pluggable.

import Foundation

/// Thin dispatcher: audits tool calls and routes to modular tool packs.
public final class ToolRouter: ToolExecuting, @unchecked Sendable {
    // ForgeApp owns its router. An unowned back-reference keeps the composition
    // root acyclic while still giving modular tool packs access to app services.
    private unowned let app: ForgeApp
    private let packs: [any ToolPackHandling]
    private let authorization: any ToolAuthorizing

    public init(
        app: ForgeApp,
        packs: [any ToolPackHandling]? = nil,
        authorization: (any ToolAuthorizing)? = nil
    ) {
        self.app = app
        self.authorization = authorization ?? ToolAuthorizationService(paths: app.paths, config: app.config)
        self.packs = packs ?? [
            AgentToolPack(),
            FilesystemToolPack(),
            GitToolPack(),
            ShellToolPack(),
            DocsToolPack(),
            SearchToolPack(),
        ]
    }

    public var toolNames: [String] {
        Array(Set(packs.flatMap(\.toolNames))).sorted()
    }

    public func call(name: String, arguments: [String: Any], clientID: ClientID) throws -> ToolResult {
        let start = Date()
        app.sessions.touchIfActive(clientID: clientID)
        let binding = try? app.sessions.rehydrate(clientID: clientID)

        let authorizedArguments: [String: Any]
        switch authorization.authorize(
            tool: name,
            arguments: arguments,
            clientID: clientID,
            binding: binding
        ) {
        case .allowed(let normalized):
            authorizedArguments = normalized
        case .denied(let code, let message):
            let result = ToolResult.failure(code: code, message: message, retryable: false)
            try? app.audit.append(
                tool: name,
                status: "denied",
                clientID: clientID.rawValue,
                args: ToolAuditSanitizer.sanitize(arguments),
                durationMs: Int(Date().timeIntervalSince(start) * 1000),
                error: message,
                mutating: Self.mutatingTools.contains(name)
            )
            app.diagnostics.warn("tool_denied", [
                "tool": name,
                "client_id": clientID.rawValue,
                "code": code,
            ], category: .tools)
            return result
        }

        let result: ToolResult
        do {
            result = try dispatch(name: name, arguments: authorizedArguments, clientID: clientID)
        } catch {
            let fail = ToolResult.failure(code: "tool_exception", message: "\(error)", retryable: true)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            try? app.audit.append(
                tool: name,
                status: "error",
                clientID: clientID.rawValue,
                args: ToolAuditSanitizer.sanitize(authorizedArguments),
                durationMs: ms,
                error: "\(error)",
                mutating: false
            )
            app.diagnostics.error("tool_exception", [
                "tool": name,
                "error": "\(error)",
                "client_id": clientID.rawValue,
            ], category: .tools)
            return fail
        }

        let ms = Int(Date().timeIntervalSince(start) * 1000)
        let status = result.ok ? "ok" : "error"
        let mutating = Self.mutatingTools.contains(name)
        try? app.audit.append(
            tool: name,
            status: status,
            clientID: clientID.rawValue,
            args: ToolAuditSanitizer.sanitize(authorizedArguments),
            durationMs: ms,
            error: result.ok ? nil : (result.payload["message"] as? String),
            mutating: mutating
        )
        if result.ok {
            app.diagnostics.info("tool_call", [
                "tool": name,
                "duration_ms": "\(ms)",
                "client_id": clientID.rawValue,
                "mutating": mutating ? "true" : "false",
            ], category: .tools)
        } else {
            app.diagnostics.warn("tool_call_failed", [
                "tool": name,
                "duration_ms": "\(ms)",
                "client_id": clientID.rawValue,
                "message": (result.payload["message"] as? String) ?? "error",
            ], category: .tools)
        }
        return result
    }

    private static let mutatingTools: Set<String> = [
        "fs_write", "fs_edit", "fs_mkdir", "fs_delete", "fs_move",
        "git_add", "git_commit", "pdf_write", "pdf_from_file",
        "agent_run_start", "agent_run_complete", "shell_exec",
    ]

    private func dispatch(name: String, arguments: [String: Any], clientID: ClientID) throws -> ToolResult {
        for pack in packs {
            if let result = try pack.handle(name: name, arguments: arguments, clientID: clientID, app: app) {
                return result
            }
        }
        return .failure(code: "unknown_tool", message: "Unknown tool '\(name)'", retryable: false)
    }
}
