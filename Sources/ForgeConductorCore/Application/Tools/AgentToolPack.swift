// AgentToolPack.swift
// What: Exposes catalog lookup and durable agent-session operations as tools.
// How: The pack validates arguments with shared helpers and delegates all domain
// behavior to AgentCatalogProviding and SessionManaging dependencies.
// Why: Tool protocol adaptation stays separate from agent lifecycle implementation.

import Foundation

/// Agent lifecycle and catalog tools.
public struct AgentToolPack: ToolPackHandling {
    private static let developmentPolicyInstruction =
        "Before making development changes, read every active Development Policy source "
        + "listed below in priority order with the development_policy query tools, then "
        + "follow all applicable requirements throughout the task. For a directory source, "
        + "start with AGENTS.md when present and follow the source's declared reading order. "
        + "Catalog or index status does not replace reading the source content. If no active "
        + "source is listed or a source cannot be read, report that exact condition before "
        + "making development changes."

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
                "development_policy": ["fs_list", "fs_read", "fs_glob", "search_text"],
                "continuity": [
                    "continuity.status", "continuity.get_pending_handoff",
                    "context_get",
                ],
            ],
            "required_actions": [[
                "action": "read_and_follow_development_policy",
                "required": true,
                "instruction": Self.developmentPolicyInstruction,
            ] as [String: Any]],
            "pid": ProcessInfo.processInfo.processIdentifier,
        ]
        var policySources: [DevelopmentPolicySource] = []
        var policyCatalogError: String?
        if let catalog = app.developmentPolicySources {
            do {
                policySources = try catalog.sources(includeRemoved: false, limit: 100)
            } catch {
                policyCatalogError = String(error.localizedDescription.prefix(1_024))
            }
        } else {
            policyCatalogError = "Development Policy source catalog is unavailable."
        }
        let governingPolicy = RavenForgeDevelopmentPolicyAdapter.identity
        let orderedPolicySources: [[String: Any]] = policySources.enumerated().map { index, source in
            var item: [String: Any] = [
                "priority": index + 1,
                "source_id": source.id.description,
                "origin": source.origin.rawValue,
                "display_name": source.displayName,
                "selected_path": source.selectedPath,
                "standardized_path": source.standardizedPath,
                "root_kind": source.rootKind.rawValue,
                "active": source.active,
                "interpretation_state": source.interpretationState.rawValue,
            ]
            if let revisionID = source.latestRevisionID {
                item["latest_revision_id"] = revisionID.description
            }
            if let observation = source.latestObservation {
                item["latest_observation"] = observation
            }
            return item
        }
        var developmentPolicy: [String: Any] = [
            "required": true,
            "catalog_available": policyCatalogError == nil,
            "configured": !orderedPolicySources.isEmpty,
            "instruction": Self.developmentPolicyInstruction,
            "source_count": orderedPolicySources.count,
            "sources": orderedPolicySources,
            "governing_policy": [
                "binding_id": governingPolicy.bindingID,
                "authority": governingPolicy.authority,
                "repository_url": governingPolicy.repositoryURL,
                "version": governingPolicy.version,
                "revision": governingPolicy.revision,
                "source_id": governingPolicy.sourceID.description,
            ] as [String: Any],
        ]
        if let policyCatalogError {
            developmentPolicy["error"] = policyCatalogError
        }
        payload["development_policy"] = developmentPolicy
        var locations: [String: String] = [:]
        if let primaryPolicySource = policySources.first {
            locations["development_policy"] = primaryPolicySource.selectedPath
        }
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
            locations.merge([
                "project_files": project.canonicalRoot.path,
                "instruction_store": app.paths.instructionPackageStoreDir.path,
                "continuity_store": projectStateDirectory
                    .appendingPathComponent("continuity", isDirectory: true).path,
            ]) { _, new in new }
            do {
                let queue = try ProjectInstructionQueueStore(paths: app.paths, clock: app.clock)
                let page = try queue.snapshotPage(
                    projectID: project.projectID,
                    generation: project.generation,
                    cursor: 0,
                    limit: 128
                )
                payload["instruction_packages"] = [
                    "project_id": project.projectID.description,
                    "project_generation": project.generation.rawValue,
                    "instruction": "Execute instruction packages in ascending position order. Use instruction_catalog and instruction_read to read each immutable snapshot before executing it.",
                    "total_packages": page.totalPackages,
                    "returned_packages": page.packages.count,
                    "next_cursor": page.nextCursor as Any,
                    "execution_order": page.packages.map { package in
                        [
                            "position": package.position,
                            "package_id": package.packageID,
                            "display_name": package.displayName,
                            "source_path": package.sourcePath,
                            "snapshot_sha256": package.contentSHA256,
                            "state": package.state.rawValue,
                        ] as [String: Any]
                    },
                ].compactNSNull()
            } catch {
                payload["instruction_packages"] = [
                    "project_id": project.projectID.description,
                    "project_generation": project.generation.rawValue,
                    "error": String(error.localizedDescription.prefix(1_024)),
                    "execution_order": [],
                ] as [String: Any]
            }
        }
        if !locations.isEmpty {
            payload["locations"] = locations
        }
        if ToolArgHelpers.bool(arguments, "resume") == true {
            let requestedHandoffID = ToolArgHelpers.string(arguments, "handoff_id")
            let resumed = try app.continuity.get(
                id: requestedHandoffID,
                preferResumeReady: true,
                cancellation: cancellation
            )
            payload["resume"] = resumed
            if let rolloverNonce = ToolArgHelpers.string(arguments, "rollover_nonce") {
                guard resumed["found"] as? Bool == true,
                      resumed["resume_ready"] as? Bool == true,
                      let actualHandoffID = resumed["handoff_id"] as? String,
                      requestedHandoffID?.lowercased() == actualHandoffID.lowercased() else {
                    throw ProjectMemoryError.invalidRequest(
                        "rollover acknowledgement requires the exact resume-ready handoff"
                    )
                }
                payload["interactive_resume_acknowledgement"] = try app.continuity
                    .recordInteractiveResumeAcknowledgement(
                        handoffID: actualHandoffID,
                        rolloverNonce: rolloverNonce,
                        clientID: clientID,
                        cancellation: cancellation
                    )
            }
        }
        let result = ToolResult.success(payload)
        try cancellation?.checkCancellation()
        return result
    }
}
