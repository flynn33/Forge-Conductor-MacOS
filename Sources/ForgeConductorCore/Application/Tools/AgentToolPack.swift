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
            let cwd = ToolArgHelpers.string(arguments, "cwd") ?? context?.authorizationScope.canonicalRoots.first?.path
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
        try cancellation?.checkCancellation()
        var configurationRefreshError: String?
        do {
            try app.config.refreshIfChanged()
        } catch {
            configurationRefreshError = String(error.localizedDescription.unicodeScalars.prefix(256))
        }
        try cancellation?.checkCancellation()
        let presence = try app.store.presenceRecords(cancellation: cancellation)
        let openSessions = try app.store.sessionList(
            cancellation: cancellation
        ).filter(\.status.isOpen)
        let memoryCount = (try? app.store.memoryCount(
            includeSystem: false,
            cancellation: cancellation
        )) ?? 0
        let automation = try app.continuityAutomation.snapshot(for: clientID, cancellation: cancellation)
        let projects = try app.projectContexts.operatorProjects(
            cancellation: cancellation
        )
        let projectMetadata = try app.projectMemory.identities.descriptors(
            projectIDs: projects.map { $0.projectID.description },
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
            "continuity": [:] as [String: Any],
            "auto_continuity": automation,
            "projects": projects.map { project in
                [
                    "project_id": project.projectID.description,
                    "project_generation": project.generation.rawValue,
                    "display_name": project.displayName,
                    "canonical_root": project.canonicalRoot.path,
                    "github_repository_url": projectMetadata[project.projectID.description]?.githubRepositoryURL as Any,
                ] as [String: Any]
            },
            "query_tools": [
                "instructions": ["instruction_catalog", "instruction_read"],
                "project_files": ["fs_list", "fs_read", "fs_glob", "search_text"],
                "web": ["web.search", "web.fetch", "web.render"],
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
        if let configurationRefreshError {
            payload["configuration_refresh"] = [
                "state": "failed",
                "using_cached_settings": true,
                "error": configurationRefreshError,
            ] as [String: Any]
        }
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
        var effectiveContext = context
        if effectiveContext == nil, let selectedProject {
            do {
                effectiveContext = try app.projectContexts.bindMCPClient(
                    project: selectedProject,
                    clientID: clientID,
                    reactivateInactiveBinding: false,
                    cancellation: cancellation
                )
            } catch let error as ProjectContextError {
                // A reset or archive intentionally fences the prior client row.
                // Status remains readable, but only project_memory.initialize may
                // reactivate that deliberately invalidated binding.
                guard case .projectContextRequired = error else { throw error }
            }
        }
        if let effectiveContext {
            payload["project_context"] = [
                "attached": true,
                "project_id": effectiveContext.projectID.description,
                "project_generation": effectiveContext.projectGeneration.rawValue,
                "client_id": effectiveContext.clientID.rawValue,
                "network_allowed": effectiveContext.authorizationScope.networkAllowed,
            ] as [String: Any]
        } else {
            payload["project_context"] = [
                "attached": false,
                "selection_required": selectedProject == nil,
                "reinitialization_required": selectedProject != nil,
            ] as [String: Any]
        }
        if let project = selectedProject {
            let selectedMetadata = try projectMetadata[project.projectID.description]
                ?? app.projectMemory.identities.descriptors(
                    projectIDs: [project.projectID.description], cancellation: cancellation
                )[project.projectID.description]
            let projectStateDirectory = app.paths.projectsDir.appendingPathComponent(
                project.projectID.description,
                isDirectory: true
            )
            payload["project"] = [
                "project_id": project.projectID.description,
                "project_generation": project.generation.rawValue,
                "canonical_root": project.canonicalRoot.path,
                "github_repository_url": selectedMetadata?.githubRepositoryURL as Any,
                "run_id": effectiveContext?.runID?.description as Any,
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
        let readScope = try app.continuityAutomation.packetReadScope(context: effectiveContext, cancellation: cancellation)
        var continuity = (try? app.continuity.statusSummary(readScope: readScope, cancellation: cancellation)) ?? [:]
        if var policy = continuity["auto"] as? [String: Any] {
            policy["checkpoint_every_tools"] = automation["checkpoint_every_tools"]
            policy["handoff_every_tools"] = automation["handoff_every_tools"]
            continuity["auto"] = policy
        }
        payload["continuity"] = continuity
        if ToolArgHelpers.bool(arguments, "resume") == true {
            let requestedHandoffID = ToolArgHelpers.string(arguments, "handoff_id")
            let resumed = try app.continuity.get(
                id: requestedHandoffID,
                preferResumeReady: true,
                readScope: readScope,
                cancellation: cancellation
            )
            payload["resume"] = resumed
            if resumed["found"] as? Bool == true,
               let object = resumed["packet"] as? [String: Any],
               let packet = HandoffPacket.fromDictionary(object),
               packet.runtimeJobContinuation != nil {
                payload["runtime_continuation_status"] = try runtimeContinuationStatus(
                    packet: packet, context: effectiveContext, app: app,
                    cancellation: cancellation
                )
            }
            if let rolloverNonce = ToolArgHelpers.string(arguments, "rollover_nonce") {
                guard resumed["found"] as? Bool == true,
                      resumed["resume_ready"] as? Bool == true,
                      let actualHandoffID = resumed["handoff_id"] as? String,
                      let object = resumed["packet"] as? [String: Any],
                      let packet = HandoffPacket.fromDictionary(object),
                      requestedHandoffID?.lowercased() == actualHandoffID.lowercased() else {
                    throw ProjectMemoryError.invalidRequest(
                        "rollover acknowledgement requires the exact resume-ready handoff"
                    )
                }
                payload["interactive_resume_acknowledgement"] = try app.continuityAutomation
                    .recordInteractiveResumeAcknowledgement(
                        packet: packet,
                        rolloverNonce: rolloverNonce,
                        clientID: clientID,
                        cancellation: cancellation
                    )
            }
            if resumed["found"] as? Bool == true,
               let object = resumed["packet"] as? [String: Any],
               let packet = HandoffPacket.fromDictionary(object) {
                let nonce = ToolArgHelpers.string(arguments, "rollover_nonce")
                let matchesNonce = nonce == nil || nonce?.lowercased()
                    == ContextContinuityService.interactiveRolloverNonce(handoffID: packet.id).lowercased()
                // Any nonce receipt must be durable before releasing the predecessor.
                // The legacy receipt API remains available; only the GUI's exact
                // expected nonce can release a scoped continuity budget.
                payload["context_budget_cleared"] = matchesNonce
                    ? try app.continuityAutomation.clearBlockReportingResult(
                        clientID: clientID, packet: packet, cancellation: cancellation)
                    : false
                payload["auto_continuity"] = try app.continuityAutomation.snapshot(
                    for: clientID, cancellation: cancellation)
            }
        }
        let result = ToolResult.success(payload)
        try cancellation?.checkCancellation()
        return result
    }

    private func runtimeContinuationStatus(
        packet: HandoffPacket,
        context: ToolInvocationContext?,
        app: ForgeApp,
        cancellation: ToolCallCancellation?
    ) throws -> [String: Any] {
        guard let snapshot = packet.runtimeJobContinuation else { return [:] }
        let unresolved: [String: Any] = [
            "handoff_id": packet.id, "available": false,
            "attention_required": true, "reason": "current_job_authorization_required",
            "replay_permitted": false,
        ]
        guard let context, context.runID == nil, context.providerSessionID == nil,
              context.runtimeJobID == nil,
              context.authorizationScope.allowedTools.contains("job.status")
                || context.authorizationScope.allowedTools.contains("*"),
              snapshot.scopeKey == app.continuityAutomation.runtimeScopeKey(context),
              let source = try app.store.interactiveContinuityHandoffRecord(
                packetID: packet.id, cancellation: cancellation),
              source.runtimeScopeKey == snapshot.scopeKey,
              source.packet == packet else { return unresolved }
        let service = app.runtimeJobs.service
        let status = try RuntimeJobSynchronousToolPack.wait(
            timeoutSeconds: RuntimeJobSynchronousToolPack.controlTimeoutSeconds,
            cancellation: cancellation, committedResultWins: false
        ) {
            var results: [[String: Any]] = []
            for reference in snapshot.submissions {
                try Task.checkCancellation()
                var result = reference.asDictionary()
                do {
                    let job = try await service.status(jobID: reference.jobID, context: context)
                    result["available"] = true
                    result["state"] = job.state.rawValue
                    if let exitCode = job.exitCode { result["exit_code"] = exitCode }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Source admission can survive a CP rollback or retention.
                    // Absence never establishes that a command may be replayed.
                    result["available"] = false
                    result["state"] = "unresolved"
                    result["attention_required"] = true
                    result["reason"] = "job_record_unavailable_or_unauthorized"
                }
                result["replay_permitted"] = false
                results.append(result)
            }
            return ToolResult.success(["submissions": results])
        }
        return ["handoff_id": packet.id, "schema_version": snapshot.schemaVersion,
                "available": true, "submissions": status.payload["submissions"] as Any,
                "replay_permitted": false]
    }
}
