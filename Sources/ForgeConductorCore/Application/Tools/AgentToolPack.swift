// AgentToolPack.swift
// What: Exposes catalog lookup and durable agent-session operations as tools.
// How: The pack validates arguments with shared helpers and delegates all domain
// behavior to AgentCatalogProviding and SessionManaging dependencies.
// Why: Tool protocol adaptation stays separate from agent lifecycle implementation.

import Foundation

/// Agent lifecycle and catalog tools.
public struct AgentToolPack: ToolPackHandling {
    public init() {}

    public var toolNames: [String] {
        [
            "forge_status", "get_forge_status",
            "agent_list", "agent_get", "agent_context", "agent_recommend",
            "agent_run_start", "agent_run_status", "agent_run_complete",
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
        case "forge_status", "get_forge_status":
            return try forgeStatus(
                arguments: arguments,
                context: context,
                clientID: clientID,
                app: app,
                cancellation: cancellation
            )
        case "agent_list":
            let result = ToolResult.success([
                "ok": true,
                "agents": app.catalog.all().map { $0.asDictionary(includeBody: false) },
            ])
            try cancellation?.checkCancellation()
            return result
        case "agent_get", "agent_context":
            let id = ToolArgHelpers.string(arguments, "agent_id")
                ?? ToolArgHelpers.string(arguments, "id")
                ?? ToolArgHelpers.string(arguments, "name")
            guard let id, let spec = app.catalog.get(id) else {
                return .failure(code: "agent_not_found", message: "Unknown agent", retryable: true)
            }
            let result = ToolResult.success(
                spec.asDictionary(includeBody: true).merging(["ok": true]) { _, n in n }
            )
            try cancellation?.checkCancellation()
            return result
        case "agent_recommend":
            let task = ToolArgHelpers.string(arguments, "task") ?? ""
            let spec = app.catalog.recommend(task: task)
            let result = ToolResult.success([
                "ok": true,
                "agent_id": spec.id,
                "call": "agent_run_start(agent_id: '\(spec.id)', goal: ...)",
                "card": spec.asDictionary(includeBody: false),
            ])
            try cancellation?.checkCancellation()
            return result
        case "agent_run_start":
            let goal = ToolArgHelpers.string(arguments, "goal") ?? ""
            let id = ToolArgHelpers.string(arguments, "agent_id")
                ?? ToolArgHelpers.string(arguments, "id")
                ?? ToolArgHelpers.string(arguments, "name")
                ?? "explore"
            let cwd = ToolArgHelpers.string(arguments, "cwd")
            try cancellation?.checkCancellation()
            let payload = try app.sessions.start(
                agentID: id,
                goal: goal,
                clientID: clientID,
                cwd: cwd,
                cancellation: cancellation
            )
            return ToolResult(ok: payload["ok"] as? Bool ?? true, payload: payload)
        case "agent_run_status":
            guard let sid = ToolArgHelpers.string(arguments, "session_id") else {
                return .failure(code: "missing_session_id", message: "session_id required", retryable: true)
            }
            try cancellation?.checkCancellation()
            let payload = try app.sessions.status(
                sessionID: SessionID(sid),
                clientID: clientID,
                cancellation: cancellation
            )
            return ToolResult(ok: true, payload: payload)
        case "agent_run_complete":
            guard let sid = ToolArgHelpers.string(arguments, "session_id") else {
                return .failure(code: "missing_session_id", message: "session_id required", retryable: true)
            }
            let report = arguments["report"] as? [String: Any]
            try cancellation?.checkCancellation()
            let payload = try app.sessions.complete(
                sessionID: SessionID(sid),
                report: report,
                clientID: clientID,
                cancellation: cancellation
            )
            return ToolResult(ok: payload["ok"] as? Bool ?? true, payload: payload)
        default:
            return nil
        }
    }

    private func forgeStatus(
        arguments: [String: Any],
        context: ToolInvocationContext?,
        clientID: ClientID,
        app: ForgeApp,
        cancellation: ToolCallCancellation?
    ) throws -> ToolResult {
        let presence = try app.store.presenceRecords(cancellation: cancellation)
        let openSessions = try app.store.sessionList(
            cancellation: cancellation
        ).filter(\.status.isOpen)
        let memoryCount = (try? app.store.memoryCount(
            includeSystem: false,
            cancellation: cancellation
        )) ?? 0
        let continuity = (try? app.continuity.statusSummary(cancellation: cancellation)) ?? [:]
        let projects = try app.projectContexts.operatorProjects(
            cancellation: cancellation
        )
        var payload: [String: Any] = [
            "ok": true,
            "version": ForgeApp.version,
            "runtime": "swift",
            "home": app.paths.home.path,
            "client_id": clientID.rawValue,
            "agents": app.catalog.all().map(\.id),
            "tools": app.tools.toolNames,
            "memory_note_count": memoryCount,
            "presence_count": presence.count,
            "open_sessions": openSessions.count,
            "open_session_ids": openSessions.map(\.id.rawValue),
            "continuity": continuity,
            "auto_continuity": try app.continuityAutomation.snapshot(
                for: clientID,
                cancellation: cancellation
            ),
            "projects": projects.map { project in
                [
                    "project_id": project.projectID.description,
                    "project_generation": project.generation.rawValue,
                    "display_name": project.displayName,
                    "canonical_root": project.canonicalRoot.path,
                ] as [String: Any]
            },
            "query_tools": [
                "instructions": ["instruction_catalog", "instruction_read"],
                "project_files": ["fs_list", "fs_read", "fs_glob", "search_text"],
                "continuity": [
                    "continuity.status", "continuity.get_pending_handoff",
                    "context_get",
                ],
            ],
            "pid": ProcessInfo.processInfo.processIdentifier,
        ]
        let requestedProjectID: ProjectID?
        if let raw = ToolArgHelpers.string(arguments, "project_id") {
            guard let uuid = UUID(uuidString: raw) else {
                throw ProjectMemoryError.invalidRequest("project_id must be a UUID")
            }
            requestedProjectID = ProjectID(uuid)
        } else {
            requestedProjectID = nil
        }
        let selectedProject: ProjectControlRecord?
        if let context {
            selectedProject = try app.projectContexts.project(
                context.projectID,
                cancellation: cancellation
            )
        } else if let requestedProjectID {
            selectedProject = try app.projectContexts.project(
                requestedProjectID,
                cancellation: cancellation
            )
        } else {
            selectedProject = projects.count == 1 ? projects[0] : nil
        }
        if let project = selectedProject {
            let projectStateDirectory = app.paths.projectsDir.appendingPathComponent(
                project.projectID.description,
                isDirectory: true
            )
            payload["project"] = [
                "project_id": project.projectID.description,
                "project_generation": project.generation.rawValue,
                "canonical_root": project.canonicalRoot.path,
                "run_id": context?.runID?.description as Any,
            ] as [String: Any]
            payload["locations"] = [
                "project_files": project.canonicalRoot.path,
                "instruction_store": app.paths.instructionPackageStoreDir.path,
                "continuity_store": projectStateDirectory
                    .appendingPathComponent("continuity", isDirectory: true).path,
            ]
        }
        if ToolArgHelpers.bool(arguments, "resume") == true {
            payload["resume"] = try app.continuity.get(
                id: nil,
                preferResumeReady: true,
                cancellation: cancellation
            )
        }
        let result = ToolResult.success(payload)
        try cancellation?.checkCancellation()
        return result
    }
}
