// ToolRouter.swift
// What: Dispatches named tool calls to independently registered tool-pack modules.
// How: It indexes handlers by declared names, authorizes each invocation, applies
// budget/loop guards, and records a sanitized audit result around the selected handler.
// Why: Connectors depend on one stable execution port while tool packs remain pluggable.

import Foundation
import CoreFoundation

/// Thin dispatcher: audits tool calls and routes to modular tool packs.
public final class ToolRouter: ToolExecuting, @unchecked Sendable {
    /// Total bound applied when a connector or managed provider does not request
    /// a shorter deadline. Runtime tools may impose an additional shorter bound.
    public static let defaultCallTimeoutSeconds: TimeInterval = 300
    public static let maximumRequestedDeadlineMilliseconds = 60_000

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
        try call(
            name: name,
            arguments: arguments,
            clientID: clientID,
            cancellation: nil
        )
    }

    public func call(
        name: String,
        arguments: [String: Any],
        clientID: ClientID,
        cancellation: ToolCallCancellation?
    ) throws -> ToolResult {
        let start = Date()
        let requestControl = cancellation
            ?? ToolCallCancellation(timeoutSeconds: Self.defaultCallTimeoutSeconds)
        do {
            try configureRequestCancellation(
                arguments: arguments,
                cancellation: requestControl
            )
        } catch is CancellationError {
            recordCancellation(
                tool: name,
                arguments: arguments,
                clientID: clientID,
                start: start,
                cancellation: requestControl
            )
            throw CancellationError()
        } catch is ToolCallDeadlineExceeded {
            return deadlineFailure(
                tool: name,
                arguments: arguments,
                clientID: clientID,
                start: start,
                cancellation: requestControl
            )
        } catch {
            return invalidDeadlineFailure(
                error,
                tool: name,
                arguments: arguments,
                clientID: clientID,
                start: start,
                cancellation: requestControl
            )
        }
        let context: ToolInvocationContext?
        do {
            if Self.contextRequiredTools.contains(name) {
                context = try app.projectContexts.invocationContext(
                    for: clientID,
                    cancellation: requestControl
                )
            } else {
                context = try? app.projectContexts.invocationContext(
                    for: clientID,
                    cancellation: requestControl
                )
            }
            if let context {
                try app.projectContexts.validate(
                    context,
                    cancellation: requestControl
                )
            }
            try requestControl.checkCancellation()
        } catch is CancellationError {
            recordCancellation(
                tool: name,
                arguments: arguments,
                clientID: clientID,
                start: start,
                cancellation: requestControl
            )
            throw CancellationError()
        } catch is ToolCallDeadlineExceeded {
            return deadlineFailure(
                tool: name,
                arguments: arguments,
                clientID: clientID,
                start: start,
                cancellation: requestControl
            )
        } catch {
            return projectContextFailure(
                error,
                tool: name,
                arguments: arguments,
                clientID: clientID,
                start: start,
                cancellation: requestControl
            )
        }
        return try callInternal(
            name: name,
            arguments: arguments,
            context: context,
            clientID: clientID,
            cancellation: requestControl,
            start: start
        )
    }

    public func call(
        name: String,
        arguments: [String: Any],
        context: ToolInvocationContext
    ) throws -> ToolResult {
        try call(
            name: name,
            arguments: arguments,
            context: context,
            cancellation: nil
        )
    }

    public func call(
        name: String,
        arguments: [String: Any],
        context: ToolInvocationContext,
        cancellation: ToolCallCancellation?
    ) throws -> ToolResult {
        let start = Date()
        let requestControl = cancellation
            ?? ToolCallCancellation(timeoutSeconds: Self.defaultCallTimeoutSeconds)
        do {
            try configureRequestCancellation(
                arguments: arguments,
                cancellation: requestControl
            )
        } catch is CancellationError {
            recordCancellation(
                tool: name,
                arguments: arguments,
                clientID: context.clientID,
                start: start,
                cancellation: requestControl
            )
            throw CancellationError()
        } catch is ToolCallDeadlineExceeded {
            return deadlineFailure(
                tool: name,
                arguments: arguments,
                clientID: context.clientID,
                start: start,
                cancellation: requestControl
            )
        } catch {
            return invalidDeadlineFailure(
                error,
                tool: name,
                arguments: arguments,
                clientID: context.clientID,
                start: start,
                cancellation: requestControl
            )
        }
        do {
            try app.projectContexts.validate(
                context,
                cancellation: requestControl
            )
            try requestControl.checkCancellation()
        } catch is CancellationError {
            recordCancellation(
                tool: name,
                arguments: arguments,
                clientID: context.clientID,
                start: start,
                cancellation: requestControl
            )
            throw CancellationError()
        } catch is ToolCallDeadlineExceeded {
            return deadlineFailure(
                tool: name,
                arguments: arguments,
                clientID: context.clientID,
                start: start,
                cancellation: requestControl
            )
        } catch {
            return projectContextFailure(
                error,
                tool: name,
                arguments: arguments,
                clientID: context.clientID,
                start: start,
                cancellation: requestControl
            )
        }
        return try callInternal(
            name: name,
            arguments: arguments,
            context: context,
            clientID: context.clientID,
            cancellation: requestControl,
            start: start
        )
    }

    private func callInternal(
        name: String,
        arguments: [String: Any],
        context: ToolInvocationContext?,
        clientID: ClientID,
        cancellation: ToolCallCancellation,
        start: Date
    ) throws -> ToolResult {
        let binding: ActiveBinding?
        do {
            try app.sessions.touchIfActive(
                clientID: clientID,
                cancellation: cancellation
            )
            binding = try app.sessions.rehydrate(
                clientID: clientID,
                cancellation: cancellation
            )
        } catch is CancellationError {
            recordCancellation(
                tool: name,
                arguments: arguments,
                clientID: clientID,
                start: start,
                cancellation: cancellation
            )
            throw CancellationError()
        } catch is ToolCallDeadlineExceeded {
            return deadlineFailure(
                tool: name,
                arguments: arguments,
                clientID: clientID,
                start: start,
                cancellation: cancellation
            )
        } catch {
            // Legacy session rehydration is ancillary for tools that do not require
            // an active binding. Preserve the prior fail-open behavior while making
            // cancellation and deadlines authoritative.
            app.diagnostics.warn("session_rehydrate_failed", [
                "tool": name,
                "client_id": clientID.rawValue,
                "error": "\(error)",
            ], category: .tools)
            binding = nil
        }

        let scopeMismatch: ToolResult?
        do {
            scopeMismatch = try projectScopeMismatch(
                tool: name,
                arguments: arguments,
                context: context,
                cancellation: cancellation
            )
        } catch is CancellationError {
            recordCancellation(
                tool: name,
                arguments: arguments,
                clientID: clientID,
                start: start,
                cancellation: cancellation
            )
            throw CancellationError()
        } catch is ToolCallDeadlineExceeded {
            return deadlineFailure(
                tool: name,
                arguments: arguments,
                clientID: clientID,
                start: start,
                cancellation: cancellation
            )
        }
        if let mismatch = scopeMismatch {
            return recordAndReturn(
                mismatch,
                tool: name,
                arguments: arguments,
                clientID: clientID,
                start: start,
                status: "denied",
                auditError: mismatch.payload["message"] as? String,
                mutating: Self.mutatingTools.contains(name),
                cancellation: cancellation
            )
        }

        let routedArguments: [String: Any]
        let authorizationDenial: (code: String, message: String)?
        let authorizationDecision: ToolAuthorizationDecision
        do {
            authorizationDecision = try authorization.authorize(
                tool: name,
                arguments: arguments,
                context: context,
                clientID: clientID,
                binding: binding,
                cancellation: cancellation
            )
        } catch is CancellationError {
            recordCancellation(
                tool: name,
                arguments: arguments,
                clientID: clientID,
                start: start,
                cancellation: cancellation
            )
            throw CancellationError()
        } catch is ToolCallDeadlineExceeded {
            return deadlineFailure(
                tool: name,
                arguments: arguments,
                clientID: clientID,
                start: start,
                cancellation: cancellation
            )
        }
        switch authorizationDecision {
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
        let bypassesContinuityBlock = isContinuity
            || ContinuityAutomation.resumeTools.contains(name)
        var continuityBlocked = false
        if !bypassesContinuityBlock {
            do {
                continuityBlocked = try app.continuityAutomation.isBlocked(
                    clientID,
                    cancellation: cancellation
                )
            } catch is CancellationError {
                recordCancellation(
                    tool: name,
                    arguments: routedArguments,
                    clientID: clientID,
                    start: start,
                    cancellation: cancellation
                )
                throw CancellationError()
            } catch is ToolCallDeadlineExceeded {
                return deadlineFailure(
                    tool: name,
                    arguments: routedArguments,
                    clientID: clientID,
                    start: start,
                    cancellation: cancellation
                )
            }
        }
        if continuityBlocked {
            let blocked: ToolResult
            do {
                blocked = try contextBudgetBlockResult(
                    clientID: clientID,
                    cancellation: cancellation
                )
            } catch is CancellationError {
                recordCancellation(
                    tool: name,
                    arguments: routedArguments,
                    clientID: clientID,
                    start: start,
                    cancellation: cancellation
                )
                throw CancellationError()
            } catch is ToolCallDeadlineExceeded {
                return deadlineFailure(
                    tool: name,
                    arguments: routedArguments,
                    clientID: clientID,
                    start: start,
                    cancellation: cancellation
                )
            }
            return recordAndReturn(
                blocked,
                tool: name,
                arguments: routedArguments,
                clientID: clientID,
                start: start,
                status: "error",
                auditError: blocked.payload["code"] as? String,
                mutating: false,
                cancellation: cancellation
            )
        }
        let loopCount = isContinuity
            ? 0
            : recordIdenticalCall(tool: name, arguments: routedArguments, clientID: clientID)

        if !isContinuity, loopCount > Self.budgetIdenticalCalls {
            // Hard stop runs before either denial return or dispatch. The repeated
            // tool therefore cannot execute, and continuation is never advertised
            // unless its resume-ready handoff was durably stored.
            let result: ToolResult
            do {
                result = try hardLoopResult(
                    tool: name,
                    loopCount: loopCount,
                    clientID: clientID,
                    authorizationDenialCode: authorizationDenial?.code,
                    cancellation: cancellation
                )
            } catch is CancellationError {
                recordCancellation(
                    tool: name,
                    arguments: routedArguments,
                    clientID: clientID,
                    start: start,
                    cancellation: cancellation
                )
                throw CancellationError()
            } catch is ToolCallDeadlineExceeded {
                return deadlineFailure(
                    tool: name,
                    arguments: routedArguments,
                    clientID: clientID,
                    start: start,
                    cancellation: cancellation
                )
            }
            return recordAndReturn(
                result,
                tool: name,
                arguments: routedArguments,
                clientID: clientID,
                start: start,
                status: "error",
                auditError: result.payload["code"] as? String,
                mutating: false,
                cancellation: cancellation
            )
        }

        if let denial = authorizationDenial {
            var result = ToolResult.failure(code: denial.code, message: denial.message, retryable: false)
            if loopCount == Self.maxIdenticalConsecutiveCalls + 1 {
                do {
                    result = try softBudgetResult(
                        result,
                        tool: name,
                        loopCount: loopCount,
                        clientID: clientID,
                        authorizationDenialCode: denial.code,
                        cancellation: cancellation
                    )
                } catch is CancellationError {
                    recordCancellation(
                        tool: name,
                        arguments: routedArguments,
                        clientID: clientID,
                        start: start,
                        cancellation: cancellation
                    )
                    throw CancellationError()
                } catch is ToolCallDeadlineExceeded {
                    return deadlineFailure(
                        tool: name,
                        arguments: routedArguments,
                        clientID: clientID,
                        start: start,
                        cancellation: cancellation
                    )
                }
            }
            return recordAndReturn(
                result,
                tool: name,
                arguments: routedArguments,
                clientID: clientID,
                start: start,
                status: "denied",
                auditError: denial.message,
                mutating: Self.mutatingTools.contains(name),
                cancellation: cancellation
            )
        }

        let result: ToolResult
        do {
            // This is the final shared-layer check before handing ownership to the
            // selected pack. Once a handler returns, its result stays authoritative:
            // a late deadline must not conceal an irreversible committed mutation.
            try cancellation.checkCancellation()
            let dispatched: ToolResult
            if name == "project_memory.initialize" {
                dispatched = try projectMemoryInitializationResult(
                    arguments: routedArguments,
                    clientID: clientID,
                    cancellation: cancellation
                )
            } else if let context, Self.projectMemoryMutatingTools.contains(name) {
                let serializedArguments = try SerializedToolArguments(routedArguments)
                dispatched = try app.projectContexts.commitIfCurrent(
                    context: context,
                    resultKind: name,
                    cancellation: cancellation
                ) { mutationControl in
                    try self.dispatch(
                        name: name,
                        arguments: try serializedArguments.decoded(),
                        context: context,
                        clientID: clientID,
                        cancellation: mutationControl
                    )
                }
            } else {
                dispatched = try dispatch(
                    name: name,
                    arguments: routedArguments,
                    context: context,
                    clientID: clientID,
                    cancellation: cancellation
                )
            }
            do {
                result = try attachBootstrapProjectContextIfNeeded(
                    dispatched,
                    tool: name,
                    arguments: routedArguments,
                    clientID: clientID,
                    cancellation: cancellation
                )
            } catch is CancellationError {
                result = committedBootstrapResult(
                    dispatched,
                    tool: name,
                    code: "request_cancelled"
                )
            } catch is ToolCallDeadlineExceeded {
                result = committedBootstrapResult(
                    dispatched,
                    tool: name,
                    code: "deadline_exceeded"
                )
            } catch {
                app.diagnostics.warn("project_context_attachment_pending", [
                    "tool": name,
                    "client_id": clientID.rawValue,
                    "error": "\(error)",
                ], category: .tools)
                result = committedBootstrapResult(
                    dispatched,
                    tool: name,
                    code: "project_context_attachment_failed"
                )
            }
        } catch is CancellationError {
            recordCancellation(
                tool: name,
                arguments: routedArguments,
                clientID: clientID,
                start: start,
                cancellation: cancellation
            )
            throw CancellationError()
        } catch is ToolCallDeadlineExceeded {
            return deadlineFailure(
                tool: name,
                arguments: routedArguments,
                clientID: clientID,
                start: start,
                cancellation: cancellation
            )
        } catch {
            var fail = ToolResult.failure(code: "tool_exception", message: "\(error)", retryable: true)
            if !isContinuity, loopCount == Self.maxIdenticalConsecutiveCalls + 1 {
                do {
                    fail = try softBudgetResult(
                        fail,
                        tool: name,
                        loopCount: loopCount,
                        clientID: clientID,
                        authorizationDenialCode: nil,
                        cancellation: cancellation
                    )
                } catch is CancellationError {
                    recordCancellation(
                        tool: name,
                        arguments: routedArguments,
                        clientID: clientID,
                        start: start,
                        cancellation: cancellation
                    )
                    throw CancellationError()
                } catch is ToolCallDeadlineExceeded {
                    return deadlineFailure(
                        tool: name,
                        arguments: routedArguments,
                        clientID: clientID,
                        start: start,
                        cancellation: cancellation
                    )
                }
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
                mutating: false,
                cancellation: cancellation
            )
        }

        var finalResult = result
        // The soft budget is based on repeated attempts, not execution success.
        // Keep the original outcome while attaching its durable resume handoff.
        if !isContinuity, loopCount == Self.maxIdenticalConsecutiveCalls + 1 {
            finalResult = (try? softBudgetResult(
                result,
                tool: name,
                loopCount: loopCount,
                clientID: clientID,
                authorizationDenialCode: nil,
                cancellation: cancellation
            )) ?? result
        }
        if !isContinuity,
           !cancellation.isCancelled,
           !cancellation.isDeadlineExceeded {
            finalResult = applyRuntimeContinuity(
                finalResult,
                tool: name,
                arguments: routedArguments,
                clientID: clientID,
                succeeded: result.ok,
                cancellation: cancellation
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
            mutating: Self.mutatingTools.contains(name),
            cancellation: cancellation
        )
    }

    private func softBudgetResult(
        _ result: ToolResult,
        tool: String,
        loopCount: Int,
        clientID: ClientID,
        authorizationDenialCode: String?,
        cancellation: ToolCallCancellation?
    ) throws -> ToolResult {
        let denialReason = authorizationDenialCode.map { " authorization_denial=\($0)" } ?? ""
        let packet: HandoffPacket
        do {
            packet = try app.continuity.budgetAutoCheckpoint(
                clientID: clientID,
                reason: "soft_budget identical \(tool) count=\(loopCount)\(denialReason)",
                cancellation: cancellation
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ToolCallDeadlineExceeded {
            throw error
        } catch {
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
        authorizationDenialCode: String?,
        cancellation: ToolCallCancellation?
    ) throws -> ToolResult {
        let denialReason = authorizationDenialCode.map { " authorization_denial=\($0)" } ?? ""
        do {
            let packet = try app.continuity.budgetAutoCheckpoint(
                clientID: clientID,
                reason: "identical_call_loop tool=\(tool) count=\(loopCount)\(denialReason)",
                cancellation: cancellation
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
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ToolCallDeadlineExceeded {
            throw error
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

    private func recordCancellation(
        tool: String,
        arguments: [String: Any],
        clientID: ClientID,
        start: Date,
        cancellation: ToolCallCancellation
    ) {
        let cancelled = ToolResult.failure(
            code: "request_cancelled",
            message: "Tool call cancelled",
            retryable: false
        )
        _ = recordAndReturn(
            cancelled,
            tool: tool,
            arguments: arguments,
            clientID: clientID,
            start: start,
            status: "cancelled",
            auditError: "request_cancelled",
            mutating: Self.mutatingTools.contains(tool),
            cancellation: cancellation
        )
    }

    private func recordAndReturn(
        _ result: ToolResult,
        tool: String,
        arguments: [String: Any],
        clientID: ClientID,
        start: Date,
        status: String,
        auditError: String?,
        mutating: Bool,
        cancellation: ToolCallCancellation? = nil
    ) -> ToolResult {
        let durationMs = Int(Date().timeIntervalSince(start) * 1000)
        let auditArguments = ToolAuditSanitizer.sanitize(arguments)
        if status == "cancelled" || status == "deadline_exceeded" {
            // The request token is already terminal. Submit evidence with its own
            // short control so audit contention cannot delay the wire response.
            _ = app.audit.attemptAppend(
                tool: tool,
                status: status,
                clientID: clientID.rawValue,
                args: auditArguments,
                durationMs: durationMs,
                error: auditError,
                mutating: mutating
            )
        } else {
            try? app.audit.append(
                tool: tool,
                status: status,
                clientID: clientID.rawValue,
                args: auditArguments,
                durationMs: durationMs,
                error: auditError,
                mutating: mutating,
                cancellation: cancellation
            )
        }
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
        "fs_write", "fs_edit", "fs_mkdir", "fs_delete", "fs_delete_recovery", "fs_move",
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
        "fs_write", "fs_edit", "fs_mkdir", "fs_delete", "fs_delete_recovery", "fs_move",
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
        succeeded: Bool,
        cancellation: ToolCallCancellation?
    ) -> ToolResult {
        guard let observation = app.continuityAutomation.observe(
            tool: tool,
            arguments: arguments,
            clientID: clientID,
            succeeded: succeeded,
            cancellation: cancellation
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

    private func contextBudgetBlockResult(
        clientID: ClientID,
        cancellation: ToolCallCancellation?
    ) throws -> ToolResult {
        let prior = try app.continuityAutomation.blockState(
            clientID,
            cancellation: cancellation
        )
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
        context: ToolInvocationContext?,
        cancellation: ToolCallCancellation?
    ) throws -> ToolResult? {
        try cancellation?.checkCancellation()
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
            try cancellation?.checkCancellation()
            let candidate = ToolArgHelpers.resolvePath(rawPath)
                .resolvingSymlinksInPath().standardizedFileURL
            try cancellation?.checkCancellation()
            guard context.authorizationScope.canonicalRoots.contains(where: {
                $0.standardizedFileURL == candidate
            }) else {
                return .failure(
                    code: ProjectContextError.projectScopeMismatch.code,
                    message: "The requested project root does not match the durable invocation context",
                    retryable: false
                )
            }
        }
        try cancellation?.checkCancellation()
        return nil
    }

    private func attachBootstrapProjectContextIfNeeded(
        _ result: ToolResult,
        tool: String,
        arguments: [String: Any],
        clientID: ClientID,
        cancellation: ToolCallCancellation?
    ) throws -> ToolResult {
        guard result.ok else { return result }
        switch tool {
        case "agent_run_start":
            guard let rawPath = ToolArgHelpers.string(arguments, "cwd") else {
                return result
            }
            let registered = try registerBootstrapProject(
                path: rawPath,
                requestedProjectID: nil,
                displayName: nil,
                repositoryIdentityAssertion: nil,
                clientID: clientID,
                cancellation: cancellation
            )
            var payload = result.payload
            payload["project_context_attached"] = true
            payload["project_id"] = registered.context.projectID.description
            payload["project_generation"] = registered.context.projectGeneration.rawValue
            payload["project_context"] = projectContextDictionary(registered.context)
            return ToolResult(ok: result.ok, payload: payload, isError: result.isError)
        default:
            return result
        }
    }

    private func projectMemoryInitializationResult(
        arguments: [String: Any],
        clientID: ClientID,
        cancellation: ToolCallCancellation
    ) throws -> ToolResult {
        guard let rawPath = ToolArgHelpers.string(arguments, "project_path")
                ?? ToolArgHelpers.string(arguments, "path") else {
            return .failure(
                code: ProjectMemoryError.invalidRequest("").code,
                message: "project_path is required",
                retryable: false
            )
        }
        var committedIdentity: ProjectMemoryDescriptor?
        var committedInitialization: [String: Any]?
        do {
            let registered = try registerBootstrapProject(
                path: rawPath,
                requestedProjectID: ToolArgHelpers.string(arguments, "project_id"),
                displayName: ToolArgHelpers.string(arguments, "display_name"),
                repositoryIdentityAssertion: ToolArgHelpers.string(
                    arguments,
                    "repository_identity"
                ),
                clientID: clientID,
                cancellation: cancellation,
                onIdentityCommitted: { descriptor in
                    committedIdentity = descriptor
                },
                onInitializationCommitted: { payload in
                    committedInitialization = payload
                }
            )
            var payload = registered.initialization
            payload["project_context_attached"] = true
            payload["project_id"] = registered.context.projectID.description
            payload["project_generation"] = registered.context.projectGeneration.rawValue
            payload["project_context"] = projectContextDictionary(registered.context)
            return .success(payload)
        } catch is CancellationError {
            if let committed = committedProjectMemoryResult(
                initialization: committedInitialization,
                identity: committedIdentity,
                code: "request_cancelled"
            ) {
                return committed
            }
            throw CancellationError()
        } catch let error as ToolCallDeadlineExceeded {
            if let committed = committedProjectMemoryResult(
                initialization: committedInitialization,
                identity: committedIdentity,
                code: "deadline_exceeded"
            ) {
                return committed
            }
            throw error
        } catch let error as ProjectContextError {
            if committedInitialization != nil || committedIdentity != nil {
                app.diagnostics.warn("project_context_attachment_pending", [
                    "tool": "project_memory.initialize",
                    "client_id": clientID.rawValue,
                    "error": "\(error)",
                ], category: .tools)
            }
            if let committed = committedProjectMemoryResult(
                initialization: committedInitialization,
                identity: committedIdentity,
                code: committedInitialization == nil
                    ? "project_memory_initialization_failed"
                    : "project_context_attachment_failed"
            ) {
                return committed
            }
            return .failure(
                code: error.code,
                message: error.localizedDescription,
                retryable: error == .databaseBusy
            )
        } catch let error as ProjectMemoryError {
            if let committed = committedProjectMemoryResult(
                initialization: committedInitialization,
                identity: committedIdentity,
                code: "project_memory_initialization_failed",
                initializationError: error
            ) {
                return committed
            }
            return .failure(
                code: error.code,
                message: error.localizedDescription,
                retryable: error == .databaseBusy
            )
        } catch {
            if let committed = committedProjectMemoryResult(
                initialization: committedInitialization,
                identity: committedIdentity,
                code: committedInitialization == nil
                    ? "project_memory_initialization_failed"
                    : "project_context_attachment_failed"
            ) {
                return committed
            }
            return .failure(
                code: "project_memory_initialization_failed",
                message: "\(error)",
                retryable: false
            )
        }
    }

    private func registerBootstrapProject(
        path: String,
        requestedProjectID: String?,
        displayName: String?,
        repositoryIdentityAssertion: String?,
        clientID: ClientID,
        cancellation: ToolCallCancellation?,
        onIdentityCommitted: ((ProjectMemoryDescriptor) -> Void)? = nil,
        onInitializationCommitted: (([String: Any]) -> Void)? = nil
    ) throws -> (
        preparation: ProjectRegistrationIdentityPreparation,
        context: ToolInvocationContext,
        initialization: [String: Any]
    ) {
        let target = try app.projectMemory.identities.discoverTarget(
            path: path,
            repositoryIdentityAssertion: repositoryIdentityAssertion,
            cancellation: cancellation
        )
        let preparation = try app.projectContexts.prepareControlledRegistration(
            identities: app.projectMemory.identities,
            target: target,
            requestedProjectID: requestedProjectID,
            displayName: displayName,
            cancellation: cancellation
        )
        guard let projectUUID = UUID(uuidString: preparation.descriptor.id) else {
            throw ProjectContextError.invalidIdentifier("project identifier")
        }

        let recovery = SecureFilesystemRecoveryLedger(paths: app.paths)
        do {
            return try recovery.withRetainedAuthorityFence(
                projectID: ProjectID(projectUUID),
                generation: preparation.expectedControlGeneration ?? .initial
            ) { _ in
                try app.projectContexts.validateControlledRegistration(
                    preparation,
                    identities: app.projectMemory.identities,
                    requestedProjectID: requestedProjectID,
                    displayName: displayName,
                    cancellation: cancellation
                )
                let accepted = try app.projectContexts.registerProject(
                    preparation: preparation,
                    cancellation: cancellation
                )
                let initialization = try app.projectMemory.commitInitialization(
                    preparation,
                    cancellation: nil,
                    onIdentityCommitted: onIdentityCommitted
                )
                onInitializationCommitted?(initialization)
                let activated = try app.projectContexts.finalizeRegistration(
                    preparation: preparation,
                    cancellation: nil
                )
                let context = try app.projectContexts.bindMCPClient(
                    project: activated,
                    clientID: clientID,
                    cancellation: nil
                )
                guard context.projectID.description.caseInsensitiveCompare(
                    preparation.descriptor.id
                ) == .orderedSame,
                      accepted.projectID == activated.projectID,
                      accepted.generation == activated.generation,
                      context.authorizationScope.canonicalRoots == [
                          preparation.target.canonicalRoot
                      ] else {
                    throw ProjectContextError.projectScopeMismatch
                }
                return (preparation, context, initialization)
            }
        } catch SecureFilesystemRecoveryLedgerError.retainedAuthority {
            throw ProjectContextError.retainedFilesystemRecovery(
                ProjectID(projectUUID)
            )
        } catch is SecureFilesystemRecoveryLedgerError {
            throw ProjectContextError.databaseBusy
        }
    }

    private func committedProjectMemoryResult(
        initialization: [String: Any]?,
        identity: ProjectMemoryDescriptor?,
        code: String,
        initializationError: ProjectMemoryError? = nil
    ) -> ToolResult? {
        if let initialization {
            return committedBootstrapResult(
                .success(initialization),
                tool: "project_memory.initialize",
                code: code
            )
        }
        guard let identity else { return nil }
        var payload: [String: Any] = [
            "ok": true,
            "project_id": identity.id,
            "capability_version": ProjectMemoryService.capabilityVersion,
            "limits": app.projectMemory.limits.asDictionary(),
            "migration_status": "pending",
            "project": identity.asDictionary(),
            "project_memory_initialization": "pending",
        ]
        payload["primary_commit_phase"] = "identity_published"
        if let initializationError {
            payload["project_memory_initialization_error"] = initializationError.code
        }
        return committedBootstrapResult(
            .success(payload),
            tool: "project_memory.initialize",
            code: code
        )
    }

    private func projectContextDictionary(
        _ context: ToolInvocationContext
    ) -> [String: Any] {
        [
            "project_id": context.projectID.description,
            "project_generation": context.projectGeneration.rawValue,
            "client_id": context.clientID.rawValue,
            "authorization_roots": context.authorizationScope.canonicalRoots.map(\.path),
            "maximum_inline_output_bytes": context.authorizationScope.maximumInlineOutputBytes,
        ]
    }

    private func committedBootstrapResult(
        _ result: ToolResult,
        tool: String,
        code: String
    ) -> ToolResult {
        guard result.ok,
              tool == "project_memory.initialize" || tool == "agent_run_start" else {
            return result
        }
        var payload = result.payload
        payload["primary_committed"] = true
        payload["project_context_attached"] = false
        payload["project_context_attachment"] = "pending"
        payload["project_context_error"] = code
        if payload["project_memory_initialization"] as? String == "pending" {
            payload["project_context_note"] =
                "The project identity was durably published before project-memory " +
                "initialization stopped. Retry project_memory.initialize for the same " +
                "workspace and project ID to initialize storage and attach the context."
        } else {
            payload["project_context_note"] =
                "The primary operation committed before project-context attachment stopped. " +
                "Retry project_memory.initialize for the same workspace to complete attachment."
        }
        payload["reconciled"] = false
        payload["reconciliation_required"] = true
        return ToolResult(ok: true, payload: payload, isError: false)
    }

    private func projectContextFailure(
        _ error: Error,
        tool: String,
        arguments: [String: Any],
        clientID: ClientID,
        start: Date,
        cancellation: ToolCallCancellation? = nil
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
            mutating: Self.mutatingTools.contains(tool),
            cancellation: cancellation
        )
    }

    private func configureRequestCancellation(
        arguments: [String: Any],
        cancellation: ToolCallCancellation
    ) throws {
        if cancellation.remainingTimeInterval == nil {
            try cancellation.tightenDeadline(
                milliseconds: Int(Self.defaultCallTimeoutSeconds * 1_000)
            )
        }
        if let milliseconds = try Self.requestedDeadlineMilliseconds(in: arguments) {
            try cancellation.tightenDeadline(milliseconds: milliseconds)
        }
        try cancellation.checkCancellation()
    }

    static func requestedDeadlineMilliseconds(
        in arguments: [String: Any]
    ) throws -> Int? {
        guard let rawValue = arguments["deadline_ms"] else { return nil }
        guard let number = rawValue as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              let milliseconds = Int(exactly: number.doubleValue),
              (1...Self.maximumRequestedDeadlineMilliseconds).contains(milliseconds) else {
            throw ToolCallDeadlineArgumentError()
        }
        return milliseconds
    }

    private func invalidDeadlineFailure(
        _ error: Error,
        tool: String,
        arguments: [String: Any],
        clientID: ClientID,
        start: Date,
        cancellation: ToolCallCancellation? = nil
    ) -> ToolResult {
        let result = ToolResult.failure(
            code: "invalid_deadline",
            message: error.localizedDescription,
            retryable: false
        )
        return recordAndReturn(
            result,
            tool: tool,
            arguments: arguments,
            clientID: clientID,
            start: start,
            status: "denied",
            auditError: "invalid_deadline",
            mutating: Self.mutatingTools.contains(tool),
            cancellation: cancellation
        )
    }

    private func deadlineFailure(
        tool: String,
        arguments: [String: Any],
        clientID: ClientID,
        start: Date,
        cancellation: ToolCallCancellation? = nil
    ) -> ToolResult {
        let result = ToolResult.failure(
            code: "deadline_exceeded",
            message: "Tool call deadline exceeded",
            retryable: true
        )
        return recordAndReturn(
            result,
            tool: tool,
            arguments: arguments,
            clientID: clientID,
            start: start,
            status: "deadline_exceeded",
            auditError: "deadline_exceeded",
            mutating: Self.mutatingTools.contains(tool),
            cancellation: cancellation
        )
    }

    private func dispatch(
        name: String,
        arguments: [String: Any],
        context: ToolInvocationContext?,
        clientID: ClientID,
        cancellation: ToolCallCancellation
    ) throws -> ToolResult {
        for pack in packs {
            if let result = try pack.handle(
                name: name,
                arguments: arguments,
                context: context,
                clientID: clientID,
                app: app,
                cancellation: cancellation
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

private struct ToolCallDeadlineArgumentError: Error, LocalizedError, Sendable {
    var errorDescription: String? {
        "deadline_ms must be an integer within 1...\(ToolRouter.maximumRequestedDeadlineMilliseconds)"
    }
}
