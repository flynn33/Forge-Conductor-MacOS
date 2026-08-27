// AgentSessionService.swift
// What: Owns the lifecycle of durable agent execution sessions.
// How: It validates catalog entries, persists start/status/completion transitions,
// enforces one active binding, and checks completion reports against declared schemas.
// Why: Central lifecycle rules keep every connector consistent and recoverable.

import Foundation

/// Owns specialist session lifecycle with durable active bindings.
public final class AgentSessionService: SessionManaging, @unchecked Sendable {
    private let store: SQLiteStore
    private let catalog: AgentCatalog
    private let audit: AuditService
    private let diagnostics: DiagnosticLog
    private let clock: any Clock
    private let idleTTL: TimeInterval
    private let beforeBindingCacheInstallObserver: (@Sendable (SessionID) -> Void)?
    private let beforeSessionCompletionCommitObserver: (@Sendable (SessionID) -> Void)?

    private var memoryBindings: [String: ActiveBinding] = [:]
    private let lock = NSLock()
    static let maxMemoryBindings = 128

    public init(
        store: SQLiteStore,
        catalog: AgentCatalog,
        audit: AuditService,
        diagnostics: DiagnosticLog,
        clock: any Clock = SystemClock(),
        idleTTL: TimeInterval = 14_400,
        beforeBindingCacheInstallObserver: (@Sendable (SessionID) -> Void)? = nil,
        beforeSessionCompletionCommitObserver: (@Sendable (SessionID) -> Void)? = nil
    ) {
        self.store = store
        self.catalog = catalog
        self.audit = audit
        self.diagnostics = diagnostics
        self.clock = clock
        self.idleTTL = idleTTL
        self.beforeBindingCacheInstallObserver = beforeBindingCacheInstallObserver
        self.beforeSessionCompletionCommitObserver = beforeSessionCompletionCommitObserver
    }

    // MARK: - Public API

    public func start(
        agentID: String,
        goal: String,
        clientID: ClientID,
        cwd: String? = nil,
        cancellation: ToolCallCancellation? = nil
    ) throws -> [String: Any] {
        try cancellation?.checkCancellation()
        guard let spec = catalog.get(agentID) else {
            return ToolResult.failure(
                code: "agent_not_found",
                message: "Unknown agent '\(agentID)'",
                retryable: true
            ).payload
        }

        let supersedeSummary = try JSONSupport.string(from: [
            "event": "superseded",
            "ok_to_reuse": true,
            "message": "Closed because a new agent session started",
            "new_agent_id": agentID,
        ])
        let timestamp = clock.now()
        let proposedSession = AgentSession(
            agentID: agentID,
            clientID: clientID,
            status: .open,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let binding = ActiveBinding(
            sessionID: proposedSession.id,
            agentID: agentID,
            goal: goal,
            toolsPrimary: spec.tools,
            toolsForbidden: spec.toolsForbidden,
            outputSchema: spec.outputSchema,
            doneDefinition: spec.doneDefinition,
            cwd: cwd
        )
        let runState: [String: Any] = [
            "session_id": proposedSession.id.rawValue,
            "agent_id": agentID,
            "goal": goal,
            "cwd": cwd as Any,
            "status": "running",
            "output_schema": spec.outputSchema,
            "first_moves": spec.firstMoves,
        ]
        let session = try store.sessionStartReplacingOpen(
            session: proposedSession,
            supersedeSummary: supersedeSummary,
            bindingBody: try bindingBody(binding),
            runBody: try JSONSupport.string(from: runState.compactNSNull()),
            cancellation: cancellation
        )
        installMemoryBindingIfDurableMatches(clientID: clientID, binding: binding)

        appendAuditBestEffort(
            tool: "agent_run_start",
            status: "ok",
            clientID: clientID.rawValue,
            args: [
                "session_id": session.id.rawValue,
                "agent_id": agentID,
                "agent_session_id": session.id.rawValue,
                "goal": goal,
            ],
            mutating: true
        )
        diagnostics.info("agent_run_start", [
            "agent_id": agentID,
            "session_id": session.id.rawValue,
        ])

        return [
            "ok": true,
            "session": sessionDict(session),
            "session_id": session.id.rawValue,
            "goal": goal,
            "cwd": cwd as Any,
            "agent": spec.asDictionary(includeBody: true),
            "first_moves": spec.firstMoves,
            "done_definition": spec.doneDefinition,
            "output_schema": spec.outputSchema,
            "tools_primary": spec.tools,
            "tools_forbidden": spec.toolsForbidden,
            "must_complete": true,
            "next": [
                "Adopt agent.body as role instructions",
                "Execute first_moves",
                "Prefer tools_primary",
                "REQUIRED: agent_run_complete(session_id: '\(session.id.rawValue)', report: {…output_schema})",
            ],
            "token_policy": "Large context host: do not skip specialists to save tokens.",
        ]
    }

    public func status(
        sessionID: SessionID,
        clientID: ClientID?,
        cancellation: ToolCallCancellation? = nil
    ) throws -> [String: Any] {
        var session = try store.sessionGet(id: sessionID, cancellation: cancellation)
        var reattached = false
        var activeCancellation = cancellation
        if let clientID, session?.status.isOpen == true {
            reattached = try attach(
                sessionID: sessionID,
                clientID: clientID,
                cancellation: cancellation
            )
            // Reattach can durably update ownership even when the public Boolean
            // remains false because the client identifier did not change.
            activeCancellation = nil
            session = try store.sessionGet(id: sessionID, cancellation: nil)
        }
        if let session, session.status.isOpen {
            do {
                _ = try store.sessionTouch(id: sessionID, cancellation: activeCancellation)
                activeCancellation = nil
            } catch is CancellationError {
                throw CancellationError()
            } catch is ToolCallDeadlineExceeded {
                throw ToolCallDeadlineExceeded()
            } catch {
                // Status remains useful when its best-effort idle timestamp cannot update.
            }
        }
        var idleSec: Int?
        var abandonRisk = false
        var mustComplete = false
        var reminder: String?
        if let session, session.status.isOpen {
            mustComplete = true
            let idle = Int(clock.now().timeIntervalSince(session.updatedAt))
            idleSec = idle
            abandonRisk = idle > 300
            reminder =
                "Session \(sessionID.rawValue) is still OPEN. You MUST call agent_run_complete before finishing."
            if abandonRisk {
                reminder! += " Idle ~\(idle)s — high risk of auto-close."
            }
        }
        let binding = try clientID.flatMap {
            try rehydrate(clientID: $0, cancellation: activeCancellation)
        }
        return [
            "ok": true,
            "session": session.map(sessionDict) as Any,
            "must_complete": mustComplete,
            "idle_sec": idleSec as Any,
            "abandon_risk": abandonRisk,
            "reattached": reattached,
            "reminder": reminder as Any,
            "active_binding": binding.map { b in
                [
                    "session_id": b.sessionID.rawValue,
                    "agent_id": b.agentID,
                    "goal": b.goal,
                ] as [String: Any]
            } as Any,
        ].compactNSNull()
    }

    public func complete(
        sessionID: SessionID,
        report: [String: Any]?,
        clientID: ClientID?,
        cancellation: ToolCallCancellation? = nil
    ) throws -> [String: Any] {
        guard let session = try store.sessionGet(id: sessionID, cancellation: cancellation) else {
            return ToolResult.failure(
                code: "session_not_found",
                message: "Unknown session \(sessionID.rawValue)",
                retryable: true
            ).payload
        }

        let reportObj = report ?? [:]
        let runBody = try store.memoryGet(
            key: "agent_run/\(sessionID.rawValue)",
            cancellation: cancellation
        )
        var schema: [String] = []
        var goal = ""
        if let runBody,
           let run = try? JSONSupport.object(from: Data(runBody.utf8)) {
            schema = run["output_schema"] as? [String] ?? []
            goal = run["goal"] as? String ?? ""
        }
        if schema.isEmpty, let spec = catalog.get(session.agentID) {
            schema = spec.outputSchema
        }

        var missing: [String] = []
        for key in schema {
            try cancellation?.checkCancellation()
            let v = reportObj[key]
            if v == nil { missing.append(key); continue }
            if let s = v as? String, s.isEmpty { missing.append(key); continue }
            if let a = v as? [Any], a.isEmpty { missing.append(key); continue }
            if let d = v as? [String: Any], d.isEmpty { missing.append(key); continue }
        }

        let summaryObj: [String: Any] = [
            "goal": goal,
            "report": reportObj,
            "missing_schema_keys": missing,
        ]
        let summary = try JSONSupport.string(from: summaryObj)
        beforeSessionCompletionCommitObserver?(sessionID)
        let closed = try store.sessionEndClearingBinding(
            id: sessionID,
            summary: String(summary.prefix(4000)),
            clientID: clientID,
            cancellation: cancellation
        )

        if let committedClientID = closed.clientID {
            removeMemoryBindingAfterCommit(
                clientID: committedClientID,
                sessionID: sessionID
            )
        }
        if let preflightClientID = session.clientID,
           preflightClientID != closed.clientID {
            removeMemoryBindingAfterCommit(
                clientID: preflightClientID,
                sessionID: sessionID
            )
        }
        if let clientID,
           clientID != closed.clientID,
           clientID != session.clientID {
            removeMemoryBindingAfterCommit(clientID: clientID, sessionID: sessionID)
        }

        let status = missing.isEmpty ? "ok" : "warn"
        appendAuditBestEffort(
            tool: "agent_run_complete",
            status: status,
            clientID: clientID?.rawValue,
            args: [
                "session_id": sessionID.rawValue,
                "agent_id": session.agentID,
                "agent_session_id": sessionID.rawValue,
                "missing_schema_keys": missing,
                "schema_complete": missing.isEmpty,
                "goal": String(goal.prefix(200)),
            ],
            error: missing.isEmpty ? nil : "missing_schema_keys=\(missing)",
            mutating: true
        )

        if !missing.isEmpty {
            diagnostics.warn("agent_run_incomplete", [
                "agent_id": session.agentID,
                "session_id": sessionID.rawValue,
                "missing": missing.joined(separator: ","),
            ])
        } else {
            diagnostics.info("agent_run_complete", [
                "agent_id": session.agentID,
                "session_id": sessionID.rawValue,
            ])
        }

        return [
            "ok": true,
            "session": sessionDict(closed),
            "report": reportObj,
            "schema_complete": missing.isEmpty,
            "missing_schema_keys": missing,
            "message": missing.isEmpty
                ? "Run complete."
                : "Run complete with missing report keys: \(missing). Fill output_schema next time.",
        ]
    }

    public func binding(for clientID: ClientID) -> ActiveBinding? {
        try? rehydrate(clientID: clientID, cancellation: nil)
    }

    public func binding(
        for clientID: ClientID,
        cancellation: ToolCallCancellation?
    ) throws -> ActiveBinding? {
        try rehydrate(clientID: clientID, cancellation: cancellation)
    }

    @discardableResult
    public func attach(
        sessionID: SessionID,
        clientID: ClientID,
        cancellation: ToolCallCancellation? = nil
    ) throws -> Bool {
        guard let session = try store.sessionGet(id: sessionID, cancellation: cancellation),
              session.status.isOpen else {
            return false
        }
        if session.clientID == clientID,
           try rehydrate(
            clientID: clientID,
            cancellation: cancellation
           )?.sessionID == sessionID {
            return false
        }

        let supersedeSummary = try JSONSupport.string(from: [
            "event": "superseded",
            "ok_to_reuse": true,
            "message": "Closed because an existing agent session was reattached",
            "reattached_session_id": sessionID.rawValue,
        ])
        var goal = ""
        var cwd: String?
        var toolsPrimary: [String] = []
        var toolsForbidden: [String] = []
        var outputSchema: [String] = []
        var doneDefinition: [String] = []
        if let runBody = try store.memoryGet(
            key: "agent_run/\(sessionID.rawValue)",
            cancellation: cancellation
        ),
           let run = try? JSONSupport.object(from: Data(runBody.utf8)) {
            goal = run["goal"] as? String ?? ""
            cwd = run["cwd"] as? String
            outputSchema = run["output_schema"] as? [String] ?? []
        }
        if let spec = catalog.get(session.agentID) {
            toolsPrimary = spec.tools
            toolsForbidden = spec.toolsForbidden
            if outputSchema.isEmpty { outputSchema = spec.outputSchema }
            doneDefinition = spec.doneDefinition
        }

        let previousClient = session.clientID
        let binding = ActiveBinding(
            sessionID: sessionID,
            agentID: session.agentID,
            goal: goal,
            toolsPrimary: toolsPrimary,
            toolsForbidden: toolsForbidden,
            outputSchema: outputSchema,
            doneDefinition: doneDefinition,
            cwd: cwd
        )
        let body = try bindingBody(binding)
        _ = try store.sessionReattach(
            id: sessionID,
            expectedClientID: previousClient,
            clientID: clientID,
            bindingBody: body,
            agentID: session.agentID,
            supersedeSummary: supersedeSummary,
            cancellation: cancellation
        )
        if let previousClient, previousClient != clientID {
            removeMemoryBindingAfterCommit(clientID: previousClient, sessionID: sessionID)
        }
        installMemoryBindingIfDurableMatches(clientID: clientID, binding: binding)
        diagnostics.info("agent_session_reattached", [
            "agent_id": session.agentID,
            "session_id": sessionID.rawValue,
            "client_id": clientID.rawValue,
        ])
        return previousClient != clientID
    }

    public func rehydrate(
        clientID: ClientID,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ActiveBinding? {
        var activeCancellation = cancellation
        for _ in 0..<4 {
            try activeCancellation?.checkCancellation()
            if let cached = try getBinding(
                clientID: clientID,
                cancellation: activeCancellation
            ) {
                if try store.agentBindingMatches(
                    clientID: clientID,
                    sessionID: cached.sessionID,
                    cancellation: activeCancellation
                ) {
                    return cached
                }
                let deleted = try store.agentBindingDeleteIfMatches(
                    clientID: clientID,
                    sessionID: cached.sessionID,
                    cancellation: activeCancellation
                )
                removeMemoryBindingAfterCommit(
                    clientID: clientID,
                    sessionID: cached.sessionID
                )
                if deleted { activeCancellation = nil }
            }

            if let body = try store.memoryGet(
                key: "agent_active/\(clientID.rawValue)",
                cancellation: activeCancellation
            ) {
                if let data = body.data(using: .utf8),
                   let object = try? JSONSupport.object(from: data),
                   object["cleared"] as? Bool != true,
                   let rawSessionID = object["session_id"] as? String,
                   let session = try store.sessionGet(
                    id: SessionID(rawSessionID),
                    cancellation: activeCancellation
                   ),
                   session.status.isOpen,
                   session.clientID == clientID {
                    let spec = catalog.get(session.agentID)
                    let binding = ActiveBinding(
                        sessionID: session.id,
                        agentID: object["agent_id"] as? String ?? session.agentID,
                        goal: object["goal"] as? String ?? "",
                        toolsPrimary: object["tools_primary"] as? [String] ?? spec?.tools ?? [],
                        toolsForbidden: object["tools_forbidden"] as? [String]
                            ?? spec?.toolsForbidden ?? [],
                        outputSchema: object["output_schema"] as? [String]
                            ?? spec?.outputSchema ?? [],
                        doneDefinition: object["done_definition"] as? [String]
                            ?? spec?.doneDefinition ?? [],
                        cwd: object["cwd"] as? String
                    )
                    if installMemoryBindingIfDurableMatches(
                        clientID: clientID,
                        binding: binding
                    ) {
                        diagnostics.info("agent_binding_rehydrated", [
                            "source": "memory",
                            "agent_id": binding.agentID,
                            "session_id": rawSessionID,
                        ])
                        return binding
                    }
                    continue
                }

                let deleted = try store.agentBindingDeleteIfUnchanged(
                    clientID: clientID,
                    expectedBody: body,
                    cancellation: activeCancellation
                )
                if deleted { activeCancellation = nil }
                continue
            }

            guard let session = try store.sessionOpen(
                for: clientID,
                cancellation: activeCancellation
            ) else {
                return nil
            }
            let spec = catalog.get(session.agentID)
            let binding = ActiveBinding(
                sessionID: session.id,
                agentID: session.agentID,
                goal: "",
                toolsPrimary: spec?.tools ?? [],
                toolsForbidden: spec?.toolsForbidden ?? [],
                outputSchema: spec?.outputSchema ?? [],
                doneDefinition: spec?.doneDefinition ?? []
            )
            let installed = try store.sessionInstallBindingIfUnchanged(
                sessionID: session.id,
                clientID: clientID,
                expectedCurrentSessionID: nil,
                bindingBody: try bindingBody(binding),
                agentID: session.agentID,
                cancellation: activeCancellation
            )
            if installed {
                activeCancellation = nil
                if installMemoryBindingIfDurableMatches(
                    clientID: clientID,
                    binding: binding
                ) {
                    diagnostics.warn("agent_binding_rehydrated", [
                        "source": "open_session",
                        "agent_id": binding.agentID,
                        "session_id": session.id.rawValue,
                        "message": "In-process binding missing; rehydrated from SQLite",
                    ])
                    return binding
                }
            }
        }
        throw StoreError.conflict(
            "Agent binding changed repeatedly while rehydrating \(clientID.rawValue)"
        )
    }

    public func touchIfActive(clientID: ClientID) {
        try? touchIfActive(clientID: clientID, cancellation: nil)
    }

    public func touchIfActive(
        clientID: ClientID,
        cancellation: ToolCallCancellation?
    ) throws {
        if let binding = try rehydrate(clientID: clientID, cancellation: cancellation) {
            _ = try store.sessionTouch(id: binding.sessionID, cancellation: cancellation)
        }
    }

    public func pruneStale() throws {
        _ = try pruneStale(cancellation: nil)
    }

    @discardableResult
    public func pruneStale(cancellation: ToolCallCancellation?) throws -> Bool {
        let cutoff = clock.now().addingTimeInterval(-idleTTL)
        let closed = try store.sessionPruneStale(
            cutoff: cutoff,
            cancellation: cancellation
        )
        for session in closed {
            if let clientID = session.clientID {
                removeMemoryBindingAfterCommit(
                    clientID: clientID,
                    sessionID: session.id
                )
            }
            let age: Int
            if let summary = session.summary,
               let object = try? JSONSupport.object(from: Data(summary.utf8)),
               let storedAge = object["age_sec"] as? Int {
                age = storedAge
            } else {
                age = 0
            }
            diagnostics.warn("agent_session_auto_closed", [
                "agent_id": session.agentID,
                "session_id": session.id.rawValue,
                "age_sec": "\(age)",
            ])
            appendAuditBestEffort(
                tool: "agent_session_auto_closed",
                status: "warn",
                clientID: session.clientID?.rawValue,
                args: [
                    "session_id": session.id.rawValue,
                    "agent_id": session.agentID,
                    "age_sec": age,
                    "ok_to_reuse": true,
                ],
                error: "abandoned session auto-closed after \(age)s idle",
                mutating: true
            )
        }
        return !closed.isEmpty
    }

    private func appendAuditBestEffort(
        tool: String,
        status: String,
        clientID: String?,
        args: [String: Any]?,
        error: String? = nil,
        mutating: Bool
    ) {
        if !audit.attemptAppend(
            tool: tool,
            status: status,
            clientID: clientID,
            args: args,
            error: error,
            mutating: mutating
        ) {
            diagnostics.warn("agent_lifecycle_audit_dropped", [
                "tool": tool,
                "client_id": clientID ?? "",
            ])
        }
    }

    // MARK: - Binding storage

    private func bindingBody(_ binding: ActiveBinding) throws -> String {
        try JSONSupport.string(from: [
            "session_id": binding.sessionID.rawValue,
            "agent_id": binding.agentID,
            "goal": binding.goal,
            "tools_primary": binding.toolsPrimary,
            "tools_forbidden": binding.toolsForbidden,
            "output_schema": binding.outputSchema,
            "done_definition": binding.doneDefinition,
            "cwd": binding.cwd as Any,
        ].compactNSNull())
    }

    private func removeMemoryBinding(
        clientID: ClientID,
        sessionID: SessionID,
        cancellation: ToolCallCancellation?
    ) throws {
        try withBindingLock(cancellation: cancellation) {
            if memoryBindings[clientID.rawValue]?.sessionID == sessionID {
                memoryBindings.removeValue(forKey: clientID.rawValue)
            }
        }
    }

    private func removeMemoryBindingAfterCommit(clientID: ClientID, sessionID: SessionID) {
        do {
            try removeMemoryBinding(clientID: clientID, sessionID: sessionID, cancellation: nil)
        } catch {
            diagnostics.warn("agent_binding_cache_cleanup_deferred", [
                "client_id": clientID.rawValue,
                "session_id": sessionID.rawValue,
                "error": "\(error)",
            ])
        }
    }

    private func getBinding(
        clientID: ClientID,
        cancellation: ToolCallCancellation?
    ) throws -> ActiveBinding? {
        try withBindingLock(cancellation: cancellation) {
            memoryBindings[clientID.rawValue]
        }
    }

    @discardableResult
    private func installMemoryBindingIfDurableMatches(
        clientID: ClientID,
        binding: ActiveBinding
    ) -> Bool {
        beforeBindingCacheInstallObserver?(binding.sessionID)
        do {
            return try withBindingLock(cancellation: nil) {
                guard try store.agentBindingMatches(
                    clientID: clientID,
                    sessionID: binding.sessionID,
                    cancellation: nil
                ) else {
                    if memoryBindings[clientID.rawValue]?.sessionID == binding.sessionID {
                        memoryBindings.removeValue(forKey: clientID.rawValue)
                    }
                    return false
                }
                if memoryBindings[clientID.rawValue] == nil,
                   memoryBindings.count >= Self.maxMemoryBindings,
                   let victim = memoryBindings.keys
                    .filter({ $0 != clientID.rawValue }).sorted().first {
                    memoryBindings.removeValue(forKey: victim)
                }
                memoryBindings[clientID.rawValue] = binding
                return true
            }
        } catch {
            diagnostics.warn("agent_binding_cache_update_deferred", [
                "client_id": clientID.rawValue,
                "session_id": binding.sessionID.rawValue,
                "error": "\(error)",
            ])
            return false
        }
    }

    private func withBindingLock<T>(
        cancellation: ToolCallCancellation?,
        _ body: () throws -> T
    ) throws -> T {
        let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        while !lock.lock(before: Date().addingTimeInterval(0.01)) {
            try cancellation?.checkCancellation()
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                throw StoreError.execFailed("agent binding cache is busy")
            }
        }
        defer { lock.unlock() }
        try cancellation?.checkCancellation()
        return try body()
    }

    var memoryBindingCount: Int {
        (try? withBindingLock(cancellation: nil) { memoryBindings.count }) ?? 0
    }

    private func sessionDict(_ s: AgentSession) -> [String: Any] {
        [
            "id": s.id.rawValue,
            "agent_id": s.agentID,
            "client_id": s.clientID?.rawValue as Any,
            "status": s.status.rawValue,
            "summary": s.summary as Any,
            "created_at": ISO8601.string(from: s.createdAt),
            "updated_at": ISO8601.string(from: s.updatedAt),
        ].compactNSNull()
    }
}

public extension Dictionary where Key == String, Value == Any {
    func compactNSNull() -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in self {
            if v is NSNull { continue }
            // Optional Any might still hold nil via as Any
            out[k] = v
        }
        return out
    }
}
