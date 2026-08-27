// ToolRouter.swift
// What: Dispatches named tool calls to independently registered tool-pack modules.
// How: It indexes handlers by declared names, authorizes each invocation, applies
// budget/loop guards, and records a sanitized audit result around the selected handler.
// Why: Connectors depend on one stable execution port while tool packs remain pluggable.

import Foundation

/// Thin dispatcher: audits tool calls and routes to modular tool packs.
public final class ToolRouter: ToolExecuting, @unchecked Sendable {
    // ForgeApp owns its router. An unowned back-reference keeps the composition
    // root acyclic while still giving modular tool packs access to app services.
    private unowned let app: ForgeApp
    private let packs: [any ToolPackHandling]
    private let authorization: any ToolAuthorizing
    /// Per-client consecutive identical call fingerprint (tool + canonical args).
    private let loopLock = NSLock()
    private var lastCallFingerprint: [String: (fingerprint: String, count: Int)] = [:]
    static let maxTrackedClients = 256
    private static let maxIdenticalConsecutiveCalls = 3
    /// Soft budget: after this many identical calls, auto-checkpoint + handoff_required.
    private static let budgetIdenticalCalls = 8

    public init(
        app: ForgeApp,
        packs: [any ToolPackHandling]? = nil,
        authorization: (any ToolAuthorizing)? = nil
    ) {
        self.app = app
        self.authorization = authorization ?? ToolAuthorizationService(paths: app.paths, config: app.config)
        self.packs = packs ?? [
            AgentToolPack(),
            MemoryToolPack(),
            ProjectMemoryToolPack(),
            ContinuityToolPack(),
            ContinuityLifecycleToolPack(),
            FilesystemToolPack(),
            GitToolPack(),
            RuntimeJobSynchronousToolPack(subsystem: app.runtimeJobs),
            DocsToolPack(),
            SearchToolPack(),
        ]
    }

    public var toolNames: [String] {
        Array(Set(packs.flatMap(\.toolNames))).sorted()
    }

    public func call(name: String, arguments: [String: Any], clientID: ClientID) throws -> ToolResult {
        let context: ToolInvocationContext?
        do {
            if Self.contextRequiredTools.contains(name) {
                context = try app.projectContexts.invocationContext(for: clientID)
            } else {
                context = try? app.projectContexts.invocationContext(for: clientID)
            }
            if let context {
                try app.projectContexts.validate(context)
            }
        } catch {
            return projectContextFailure(
                error,
                tool: name,
                arguments: arguments,
                clientID: clientID,
                start: Date()
            )
        }
        return try callInternal(
            name: name,
            arguments: arguments,
            context: context,
            clientID: clientID
        )
    }

    public func call(
        name: String,
        arguments: [String: Any],
        context: ToolInvocationContext
    ) throws -> ToolResult {
        do {
            try app.projectContexts.validate(context)
        } catch {
            return projectContextFailure(
                error,
                tool: name,
                arguments: arguments,
                clientID: context.clientID,
                start: Date()
            )
        }
        return try callInternal(
            name: name,
            arguments: arguments,
            context: context,
            clientID: context.clientID
        )
    }

    private func callInternal(
        name: String,
        arguments: [String: Any],
        context: ToolInvocationContext?,
        clientID: ClientID
    ) throws -> ToolResult {
        let start = Date()
        app.sessions.touchIfActive(clientID: clientID)
        let binding = try? app.sessions.rehydrate(clientID: clientID)

        if let mismatch = projectScopeMismatch(
            tool: name,
            arguments: arguments,
            context: context
        ) {
            return recordAndReturn(
                mismatch,
                tool: name,
                arguments: arguments,
                clientID: clientID,
                start: start,
                status: "denied",
                auditError: mismatch.payload["message"] as? String,
                mutating: Self.mutatingTools.contains(name)
            )
        }

        let routedArguments: [String: Any]
        let authorizationDenial: (code: String, message: String)?
        switch authorization.authorize(
            tool: name,
            arguments: arguments,
            context: context,
            clientID: clientID,
            binding: binding
        ) {
        case .allowed(let normalized):
            routedArguments = normalized
            authorizationDenial = nil
        case .denied(let code, let message):
            // A denied call cannot be normalized for dispatch. Its original arguments
            // are still safe to fingerprint and will be sanitized before audit storage.
            routedArguments = arguments
            authorizationDenial = (code, message)
        }

        // Continuity tools never count toward identical-call loops. Every other call
        // participates, including authorization denials, so policy failures cannot
        // evade the context-budget circuit breaker indefinitely.
        let isContinuity = ContinuityToolPack().toolNames.contains(name)
            || ContinuityLifecycleToolPack().toolNames.contains(name)
        if !isContinuity,
           !ContinuityAutomation.resumeTools.contains(name),
           app.continuityAutomation.isBlocked(clientID) {
            let blocked = contextBudgetBlockResult(clientID: clientID)
            return recordAndReturn(
                blocked,
                tool: name,
                arguments: routedArguments,
                clientID: clientID,
                start: start,
                status: "error",
                auditError: blocked.payload["code"] as? String,
                mutating: false
            )
        }
        let loopCount = isContinuity
            ? 0
            : recordIdenticalCall(tool: name, arguments: routedArguments, clientID: clientID)

        if !isContinuity, loopCount > Self.budgetIdenticalCalls {
            // Hard stop runs before either denial return or dispatch. The repeated
            // tool therefore cannot execute, and continuation is never advertised
            // unless its resume-ready handoff was durably stored.
            let result = hardLoopResult(
                tool: name,
                loopCount: loopCount,
                clientID: clientID,
                authorizationDenialCode: authorizationDenial?.code
            )
            return recordAndReturn(
                result,
                tool: name,
                arguments: routedArguments,
                clientID: clientID,
                start: start,
                status: "error",
                auditError: result.payload["code"] as? String,
                mutating: false
            )
        }

        if let denial = authorizationDenial {
            var result = ToolResult.failure(code: denial.code, message: denial.message, retryable: false)
            if loopCount == Self.maxIdenticalConsecutiveCalls + 1 {
                result = softBudgetResult(
                    result,
                    tool: name,
                    loopCount: loopCount,
                    clientID: clientID,
                    authorizationDenialCode: denial.code
                )
            }
            return recordAndReturn(
                result,
                tool: name,
                arguments: routedArguments,
                clientID: clientID,
                start: start,
                status: "denied",
                auditError: denial.message,
                mutating: Self.mutatingTools.contains(name)
            )
        }

        let result: ToolResult
        do {
            let dispatched: ToolResult
            if let context, Self.projectMemoryMutatingTools.contains(name) {
                dispatched = try app.projectContexts.commitIfCurrent(
                    context: context,
                    resultKind: name
                ) {
                    try self.dispatch(
                        name: name,
                        arguments: routedArguments,
                        context: context,
                        clientID: clientID
                    )
                }
            } else {
                dispatched = try dispatch(
                    name: name,
                    arguments: routedArguments,
                    context: context,
                    clientID: clientID
                )
            }
            result = try attachBootstrapProjectContextIfNeeded(
                dispatched,
                tool: name,
                arguments: routedArguments,
                clientID: clientID
            )
        } catch {
            var fail = ToolResult.failure(code: "tool_exception", message: "\(error)", retryable: true)
            if !isContinuity, loopCount == Self.maxIdenticalConsecutiveCalls + 1 {
                fail = softBudgetResult(
                    fail,
                    tool: name,
                    loopCount: loopCount,
                    clientID: clientID,
                    authorizationDenialCode: nil
                )
            }
            app.diagnostics.error("tool_exception", [
                "tool": name,
                "error": "\(error)",
                "client_id": clientID.rawValue,
            ], category: .tools)
            return recordAndReturn(
                fail,
                tool: name,
                arguments: routedArguments,
                clientID: clientID,
                start: start,
                status: "error",
                auditError: "\(error)",
                mutating: false
            )
        }

        var finalResult = result
        // The soft budget is based on repeated attempts, not execution success.
        // Keep the original outcome while attaching its durable resume handoff.
        if !isContinuity, loopCount == Self.maxIdenticalConsecutiveCalls + 1 {
            finalResult = softBudgetResult(
                result,
                tool: name,
                loopCount: loopCount,
                clientID: clientID,
                authorizationDenialCode: nil
            )
        }
        if !isContinuity {
            finalResult = applyRuntimeContinuity(
                finalResult,
                tool: name,
                arguments: routedArguments,
                clientID: clientID,
                succeeded: result.ok
            )
        }

        let status = finalResult.ok ? "ok" : "error"
        return recordAndReturn(
            finalResult,
            tool: name,
            arguments: routedArguments,
            clientID: clientID,
            start: start,
            status: status,
            auditError: finalResult.ok ? nil : Self.errorSummary(finalResult),
            mutating: Self.mutatingTools.contains(name)
        )
    }

    private func softBudgetResult(
        _ result: ToolResult,
        tool: String,
        loopCount: Int,
        clientID: ClientID,
        authorizationDenialCode: String?
    ) -> ToolResult {
        let denialReason = authorizationDenialCode.map { " authorization_denial=\($0)" } ?? ""
        guard let packet = try? app.continuity.budgetAutoCheckpoint(
            clientID: clientID,
            reason: "soft_budget identical \(tool) count=\(loopCount)\(denialReason)"
        ) else {
            return result
        }
        var payload = result.payload
        payload["handoff_required"] = true
        payload["handoff_id"] = packet.id
        payload["continuity_note"] =
            "Repeated identical tool calls detected. Handoff \(packet.id) saved. " +
            "Prefer new chat + context_get, or change arguments."
        payload["resume_seed"] = packet.resumeSeed.isEmpty ? packet.defaultResumeSeed() : packet.resumeSeed
        return ToolResult(ok: result.ok, payload: payload, isError: result.isError)
    }

    private func hardLoopResult(
        tool: String,
        loopCount: Int,
        clientID: ClientID,
        authorizationDenialCode: String?
    ) -> ToolResult {
        let denialReason = authorizationDenialCode.map { " authorization_denial=\($0)" } ?? ""
        do {
            let packet = try app.continuity.budgetAutoCheckpoint(
                clientID: clientID,
                reason: "identical_call_loop tool=\(tool) count=\(loopCount)\(denialReason)"
            )
            app.continuityAutomation.markBlocked(clientID: clientID, packet: packet)
            var payload: [String: Any] = [
                "ok": false,
                "code": "identical_call_loop",
                "message":
                    "Blocked repeated identical \(tool) (\(loopCount)×). " +
                    "Auto handoff \(packet.id) written. Start a new chat and call context_get.",
                "retryable": false,
                "handoff_required": true,
                "handoff_id": packet.id,
                "resume_seed": packet.resumeSeed.isEmpty ? packet.defaultResumeSeed() : packet.resumeSeed,
            ]
            if let authorizationDenialCode {
                payload["blocked_call_code"] = authorizationDenialCode
            }
            return ToolResult(ok: false, payload: payload, isError: true)
        } catch {
            let message =
                "Blocked repeated identical \(tool) (\(loopCount)×), but the required continuity " +
                "handoff could not be persisted. Resolve local continuity storage and call " +
                "session_handoff before continuing."
            var payload: [String: Any] = [
                "ok": false,
                "code": "continuity_persistence_failed",
                "message": message,
                "retryable": true,
                "handoff_required": true,
                "handoff_persisted": false,
                "loop_code": "identical_call_loop",
            ]
            if let authorizationDenialCode {
                payload["blocked_call_code"] = authorizationDenialCode
            }
            app.diagnostics.error("continuity_persistence_failed", [
                "tool": tool,
                "client_id": clientID.rawValue,
                "loop_count": "\(loopCount)",
                "error": "\(error)",
            ], category: .tools)
            return ToolResult(ok: false, payload: payload, isError: true)
        }
    }

    private func recordAndReturn(
        _ result: ToolResult,
        tool: String,
        arguments: [String: Any],
        clientID: ClientID,
        start: Date,
        status: String,
        auditError: String?,
        mutating: Bool
    ) -> ToolResult {
        let durationMs = Int(Date().timeIntervalSince(start) * 1000)
        try? app.audit.append(
            tool: tool,
            status: status,
            clientID: clientID.rawValue,
            args: ToolAuditSanitizer.sanitize(arguments),
            durationMs: durationMs,
            error: auditError,
            mutating: mutating
        )
        if status == "denied" {
            app.diagnostics.warn("tool_denied", [
                "tool": tool,
                "client_id": clientID.rawValue,
                "code": (result.payload["code"] as? String) ?? "denied",
            ], category: .tools)
        } else if result.ok {
            app.diagnostics.info("tool_call", [
                "tool": tool,
                "duration_ms": "\(durationMs)",
                "client_id": clientID.rawValue,
                "mutating": mutating ? "true" : "false",
            ], category: .tools)
        } else {
            app.diagnostics.warn("tool_call_failed", [
                "tool": tool,
                "duration_ms": "\(durationMs)",
                "client_id": clientID.rawValue,
                "message": (result.payload["message"] as? String) ?? "error",
            ], category: .tools)
        }
        return result
    }

    private static let mutatingTools: Set<String> = [
        "fs_write", "fs_edit", "fs_mkdir", "fs_delete", "fs_move",
        "git_add", "git_commit", "pdf_write", "pdf_from_file",
        "agent_run_start", "agent_run_status", "agent_run_complete", "shell_exec",
        "memory_set", "memory_delete",
        "project_memory.initialize", "project_memory.remember", "project_memory.remember_batch",
        "project_memory.update", "project_memory.forget", "project_memory.link",
        "project_memory.export", "project_memory.import",
        "session_checkpoint", "session_handoff",
        "continuity.checkpoint", "continuity.prepare_handoff",
        "continuity.acknowledge_handoff", "continuity.resume", "continuity.request_rollover",
        "process.run", "shell.run", "bash.run", "python.run", "powershell.run",
        "job.cancel",
    ]

    private static let contextRequiredTools: Set<String> = [
        "fs_write", "fs_edit", "fs_mkdir", "fs_delete", "fs_move",
        "git_status", "git_diff", "git_log", "git_add", "git_commit",
        "shell_exec", "pdf_write", "pdf_from_file",
        "project_memory.remember", "project_memory.remember_batch",
        "project_memory.search", "project_memory.get", "project_memory.update",
        "project_memory.forget", "project_memory.list_recent", "project_memory.link",
        "project_memory.export", "project_memory.import", "project_memory.status",
        "continuity.checkpoint", "continuity.prepare_handoff",
        "continuity.get_pending_handoff", "continuity.acknowledge_handoff",
        "continuity.resume", "continuity.status", "continuity.request_rollover",
        "runtime.capabilities", "process.run", "shell.run", "bash.run",
        "python.run", "powershell.run", "job.status", "job.read_output",
        "job.cancel", "job.list",
    ]

    private static let projectMemoryMutatingTools: Set<String> = [
        "project_memory.remember", "project_memory.remember_batch",
        "project_memory.update", "project_memory.forget", "project_memory.link",
        "project_memory.export", "project_memory.import",
    ]

    private func applyRuntimeContinuity(
        _ result: ToolResult,
        tool: String,
        arguments: [String: Any],
        clientID: ClientID,
        succeeded: Bool
    ) -> ToolResult {
        guard let observation = app.continuityAutomation.observe(
            tool: tool,
            arguments: arguments,
            clientID: clientID,
            succeeded: succeeded
        ) else {
            return result
        }
        var payload = result.payload
        payload["auto_continuity"] = observation.finalize ? "handoff" : "checkpoint"
        payload["auto_handoff_id"] = observation.packet.id
        if observation.finalize {
            payload["handoff_required"] = true
            payload["handoff_id"] = observation.packet.id
            payload["resume_seed"] = observation.packet.resumeSeed.isEmpty
                ? observation.packet.defaultResumeSeed()
                : observation.packet.resumeSeed
            payload["continuity_note"] =
                "Context budget: Forge auto-saved handoff \(observation.packet.id). " +
                "Further project tools are blocked on this client until context_get in a new chat."
        }
        return ToolResult(ok: result.ok, payload: payload, isError: result.isError)
    }

    private func contextBudgetBlockResult(clientID: ClientID) -> ToolResult {
        let prior = app.continuityAutomation.blockState(clientID)
        let payload: [String: Any] = [
            "ok": false,
            "code": "context_budget_exceeded",
            "message":
                "This chat has been handed off. Start a new LM Studio chat with Forge MCP enabled, " +
                "then call context_get. Further filesystem/shell/git tools are blocked here.",
            "retryable": false,
            "handoff_required": true,
            "handoff_id": prior.handoffID as Any,
            "resume_seed": prior.resumeSeed as Any,
        ]
        return ToolResult(ok: false, payload: payload, isError: true)
    }

    private static func errorSummary(_ result: ToolResult) -> String {
        if let message = result.payload["message"] as? String, !message.isEmpty {
            return message
        }
        if let code = result.payload["code"] as? String, !code.isEmpty {
            return code
        }
        if let exit = result.payload["exit_code"] {
            var summary = "exit_code=\(exit)"
            if result.payload["timed_out"] as? Bool == true {
                summary += " timed_out=true"
            }
            if let stderr = result.payload["stderr"] as? String {
                let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    summary += " stderr=\(trimmed.prefix(240))"
                }
            }
            return summary
        }
        return "error"
    }

    private func projectScopeMismatch(
        tool: String,
        arguments: [String: Any],
        context: ToolInvocationContext?
    ) -> ToolResult? {
        guard let context else { return nil }
        if let rawProjectID = ToolArgHelpers.string(arguments, "project_id"),
           let supplied = UUID(uuidString: rawProjectID),
           supplied != context.projectID.rawValue {
            return .failure(
                code: ProjectContextError.projectScopeMismatch.code,
                message: "The requested project does not match the durable invocation context",
                retryable: false
            )
        }
        if tool == "project_memory.initialize",
           let rawPath = ToolArgHelpers.string(arguments, "project_path")
                ?? ToolArgHelpers.string(arguments, "path") {
            let candidate = ToolArgHelpers.resolvePath(rawPath)
                .resolvingSymlinksInPath().standardizedFileURL
            guard context.authorizationScope.canonicalRoots.contains(where: {
                $0.resolvingSymlinksInPath().standardizedFileURL == candidate
            }) else {
                return .failure(
                    code: ProjectContextError.projectScopeMismatch.code,
                    message: "The requested project root does not match the durable invocation context",
                    retryable: false
                )
            }
        }
        return nil
    }

    private func attachBootstrapProjectContextIfNeeded(
        _ result: ToolResult,
        tool: String,
        arguments: [String: Any],
        clientID: ClientID
    ) throws -> ToolResult {
        guard result.ok else { return result }
        let descriptor: ProjectMemoryDescriptor
        let root: URL
        switch tool {
        case "project_memory.initialize":
            guard let projectID = result.payload["project_id"] as? String,
                  let rawPath = ToolArgHelpers.string(arguments, "project_path")
                    ?? ToolArgHelpers.string(arguments, "path") else {
                throw ProjectContextError.invalidIdentifier("initialized project context")
            }
            descriptor = try app.projectMemory.identities.descriptor(projectID: projectID)
            root = ToolArgHelpers.resolvePath(rawPath)
        case "agent_run_start":
            guard let rawPath = ToolArgHelpers.string(arguments, "cwd") else {
                return result
            }
            root = ToolArgHelpers.resolvePath(rawPath)
            let initialized = try app.projectMemory.initialize(path: root.path)
            guard let projectID = initialized["project_id"] as? String else {
                throw ProjectContextError.invalidIdentifier("agent project context")
            }
            descriptor = try app.projectMemory.identities.descriptor(projectID: projectID)
        default:
            return result
        }

        let context = try app.projectContexts.registerAndBindMCPClient(
            descriptor: descriptor,
            canonicalRoot: root,
            clientID: clientID
        )
        var payload = result.payload
        payload["project_id"] = context.projectID.description
        payload["project_generation"] = context.projectGeneration.rawValue
        payload["project_context"] = [
            "project_id": context.projectID.description,
            "project_generation": context.projectGeneration.rawValue,
            "client_id": context.clientID.rawValue,
            "authorization_roots": context.authorizationScope.canonicalRoots.map(\.path),
            "maximum_inline_output_bytes": context.authorizationScope.maximumInlineOutputBytes,
        ] as [String: Any]
        return ToolResult(ok: result.ok, payload: payload, isError: result.isError)
    }

    private func projectContextFailure(
        _ error: Error,
        tool: String,
        arguments: [String: Any],
        clientID: ClientID,
        start: Date
    ) -> ToolResult {
        let code: String
        let retryable: Bool
        if let contextError = error as? ProjectContextError {
            code = contextError.code
            retryable = contextError == .databaseBusy
        } else {
            code = "project_context_failure"
            retryable = false
        }
        let result = ToolResult.failure(
            code: code,
            message: error.localizedDescription,
            retryable: retryable
        )
        return recordAndReturn(
            result,
            tool: tool,
            arguments: arguments,
            clientID: clientID,
            start: start,
            status: "denied",
            auditError: error.localizedDescription,
            mutating: Self.mutatingTools.contains(tool)
        )
    }

    private func dispatch(
        name: String,
        arguments: [String: Any],
        context: ToolInvocationContext?,
        clientID: ClientID
    ) throws -> ToolResult {
        for pack in packs {
            if let result = try pack.handle(
                name: name,
                arguments: arguments,
                context: context,
                clientID: clientID,
                app: app
            ) {
                return result
            }
        }
        return .failure(code: "unknown_tool", message: "Unknown tool '\(name)'", retryable: false)
    }

    /// Returns the consecutive count for this fingerprint (1 = first).
    @discardableResult
    private func recordIdenticalCall(
        tool: String,
        arguments: [String: Any],
        clientID: ClientID
    ) -> Int {
        let fingerprint = "\(tool)|\(canonicalArgumentFingerprint(arguments))"
        let key = clientID.rawValue
        loopLock.lock()
        defer { loopLock.unlock() }
        if let previous = lastCallFingerprint[key], previous.fingerprint == fingerprint {
            let next = previous.count + 1
            lastCallFingerprint[key] = (fingerprint, next)
            return next
        }
        if lastCallFingerprint[key] == nil,
           lastCallFingerprint.count >= Self.maxTrackedClients,
           let victim = lastCallFingerprint.keys.filter({ $0 != key }).sorted().first {
            lastCallFingerprint.removeValue(forKey: victim)
        }
        lastCallFingerprint[key] = (fingerprint, 1)
        return 1
    }

    var trackedClientCount: Int {
        loopLock.lock(); defer { loopLock.unlock() }
        return lastCallFingerprint.count
    }

    private func canonicalArgumentFingerprint(_ arguments: [String: Any]) -> String {
        (try? JSONSupport.canonicalJSON(arguments))
            ?? String(describing: arguments)
    }
}
