// ContextContinuityService.swift
// What: Owns context handoff packets and agent-continuity snapshots for chat resume.
// How: Builds packets from tool args + open agent sessions, persists SQLite/files,
// projects current-task.md, and returns MCP-ready payloads with resume seeds.
// Why: Stdio MCP clients (LM Studio) need durable cross-chat state without HTTP.

import Foundation
import Darwin

/// Context + agent continuity control plane (stdio MCP / same serve binary).
public final class ContextContinuityService: @unchecked Sendable {
    static let maximumAgentSnapshots = 128
    private let paths: AppPaths
    private let store: SQLiteStore
    private let sessions: AgentSessionService
    private let diagnostics: DiagnosticLog
    private let clock: any Clock
    private let lock = NSLock()
    private static let processPersistenceLock = NSLock()
    private static let persistenceLockTimeout: TimeInterval = 3

    public init(
        paths: AppPaths,
        store: SQLiteStore,
        sessions: AgentSessionService,
        diagnostics: DiagnosticLog,
        clock: any Clock = SystemClock()
    ) {
        self.paths = paths
        self.store = store
        self.sessions = sessions
        self.diagnostics = diagnostics
        self.clock = clock
        do {
            try reconcileProjections()
        } catch {
            diagnostics.warn("continuity_projection_reconcile_failed", [
                "error": "\(error)",
            ], category: .general)
        }
    }

    // MARK: - Public tool operations

    /// Performs only exact authorized source reads and packet construction. The
    /// control-plane owner persists the resulting bytes in its request intent
    /// before calling commitPreparedAuthorizedSourceCommit. Retries never build
    /// a new random identity or timestamp from a changed mutable checkpoint.
    func prepareAuthorizedSourceCommit(
        arguments: [String: Any], clientID: ClientID, source: HandoffSource,
        finalize: Bool, authorization: ContinuityIngressAuthorization,
        cancellation: ToolCallCancellation? = nil
    ) throws -> PreparedContinuitySourceCommit {
        try authorization.validate()
        try lockContinuityMutex(lock, operation: "prepare native source commit", cancellation: cancellation)
        defer { lock.unlock() }
        return try withPersistenceFileLock(cancellation: cancellation) {
            var packet = try buildPacket(arguments: arguments, clientID: clientID, source: source,
                finalize: finalize, authorization: authorization, cancellation: cancellation)
            packet.resumeReady = finalize
            let prepared = try PreparedContinuitySourceCommit.preparing(packet)
            try requireNativeSourceResponseBudget(prepared)
            try cancellation?.checkCancellation()
            return prepared
        }
    }

    /// Commits the already frozen packet through the existing immutable revision
    /// and outbox transaction. The enclosing live CP guard is still required.
    /// If CP receipt persistence was interrupted, source digest dedup returns the
    /// original revision and delivery rather than manufacturing another packet.
    func commitPreparedAuthorizedSourceCommit(
        _ prepared: PreparedContinuitySourceCommit,
        authorization: ContinuityIngressAuthorization,
        automaticHandoffEnabled: Bool,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ContinuityHandoffCommit {
        try authorization.validate()
        let packet = try prepared.packet()
        try requireNativeSourceResponseBudget(prepared)
        let persisted = try mutateAndPersist(authorization: authorization,
            automaticHandoffEnabled: automaticHandoffEnabled, cancellation: cancellation) { packet }
        guard let commit = persisted.ingressCommit,
              commit.revision.canonicalPacketJSON == prepared.canonicalPacketJSON,
              commit.revision.identity.packetSHA256 == prepared.packetSHA256 else {
            throw ContinuityIngressError.integrityFailure("prepared source commit differs")
        }
        return commit
    }

    /// The manager invokes this inside its live task-authorization transaction.
    /// Packet text remains task data; the supplied native authorization fixes the
    /// project, assignment and scope independently of that text. Both model and
    /// runtime handoffs use this same source commit boundary.
    func commitAuthorizedHandoff(
        arguments: [String: Any],
        clientID: ClientID,
        source: HandoffSource,
        finalize: Bool,
        authorization: ContinuityIngressAuthorization,
        automaticHandoffEnabled: Bool,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ContinuityHandoffCommit {
        let persisted = try mutateAndPersist(
            authorization: authorization,
            automaticHandoffEnabled: automaticHandoffEnabled,
            cancellation: cancellation
        ) {
            var packet = try buildPacket(
                arguments: arguments, clientID: clientID, source: source,
                finalize: finalize, authorization: authorization,
                cancellation: cancellation
            )
            // A later soft checkpoint is a new non-resume-ready revision, even
            // when its exact predecessor packet had already been finalized.
            // The earlier immutable delivery remains intact.
            packet.resumeReady = finalize
            return packet
        }
        guard let commit = persisted.ingressCommit else {
            throw ContinuityIngressError.integrityFailure("authorized source commit is missing")
        }
        return commit
    }

    /// Native task responses retain the established packet fields without
    /// advertising shared legacy projections that intentionally exclude tasks.
    func authorizedCommitPayload(_ commit: ContinuityHandoffCommit, finalize: Bool) throws -> [String: Any] {
        let revision = commit.revision
        guard revision.canonicalPacketJSON.count <= ContinuityIngressLimits.maximumPacketBytes,
              JSONSupport.sha256Hex(revision.canonicalPacketJSON) == revision.identity.packetSHA256,
              let object = try JSONSerialization.jsonObject(with: revision.canonicalPacketJSON) as? [String: Any],
              let packet = HandoffPacket.fromDictionary(object),
              packet.id == revision.identity.continuityID, packet.resumeReady == finalize,
              revision.resumeReady == finalize,
              try ForgeJSONCanonicalizationV1.data(from: packet.asDictionary()) == revision.canonicalPacketJSON else {
            throw ContinuityIngressError.integrityFailure("native source commit payload differs")
        }
        return nativeSourceCommitPayload(packet: packet, finalize: finalize,
            revision: revision.identity.revision, packetSHA256: revision.identity.packetSHA256,
            operationID: commit.delivery?.operationID.uuidString.lowercased())
    }

    private func nativeSourceCommitPayload(packet: HandoffPacket, finalize: Bool,
        revision: Int64, packetSHA256: String, operationID: String?
    ) -> [String: Any] {
        var payload = successPayload(packet, action: finalize ? "handoff" : "checkpoint")
        payload["paths"] = [:] as [String: Any]
        payload["projection_ok"] = false
        payload["projection_repair_pending"] = false
        payload["projection_excluded"] = true
        payload["canonical_location"] = "task_scoped_sqlite"
        payload["continuity_id"] = packet.id
        payload["revision"] = revision
        payload["packet_sha256"] = packetSHA256
        payload["operation_id"] = operationID as Any? ?? NSNull()
        return payload
    }

    /// Worst-size identity fields are used only to measure serialization; this
    /// preflight object is never stored, disclosed, or treated as a receipt.
    /// NUL maximizes JSON escaping for any permitted 256-byte request ID.
    func requireNativeSourceResponseBudget(_ prepared: PreparedContinuitySourceCommit) throws {
        let encoded = try MCPToolResponse.data(
            id: String(repeating: "\u{0}", count: 256), result: nativeSourcePreparedToolResult(prepared))
        guard encoded.count <= 1_048_576 else {
            throw ContinuityIngressError.capacityExceeded("native source response bytes")
        }
    }

    /// Serialization-only upper bound for a prepared immutable packet. The
    /// actual receipt still comes exclusively from commitPreparedAuthorizedSourceCommit.
    func nativeSourcePreparedToolResult(_ prepared: PreparedContinuitySourceCommit) throws -> ToolResult {
        .success(nativeSourceCommitPayload(packet: try prepared.packet(), finalize: prepared.finalize,
            revision: Int64.max, packetSHA256: prepared.packetSHA256,
            operationID: "ffffffff-ffff-ffff-ffff-ffffffffffff"))
    }

    /// Exact immutable retrieval for an already authorized caller or provisional
    /// successor. Reading never adopts a workspace or clears predecessor fences.
    func authorizedHandoff(
        identity: ContinuityHandoffIdentity,
        authorization: ContinuityIngressAuthorization,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ContinuityHandoffRevision {
        try store.continuityHandoffRevision(
            identity: identity, authorization: authorization, cancellation: cancellation
        )
    }

    /// Called after the control plane authenticates exact native task ownership.
    /// This does not repair receipts, acquire a lease, or advance source state.
    func authorizedOperationProgress(acceptance: ContinuityIngressAcceptanceReceipt,
        engine: ContinuityStateEngine, cancellation: ToolCallCancellation? = nil
    ) throws -> ContinuityOperationProgressEvidence {
        let source = try store.continuityOperationProgressSource(acceptance: acceptance, cancellation: cancellation)
        let canonical = try engine.sourceBootstrap(operationID: acceptance.operationID,
            authorization: acceptance.authorization, cancellation: cancellation)
        return ContinuityOperationProgressEvidence(source: source.source, delivery: source.delivery, canonical: canonical)
    }

    /// The manager calls this only through its durable operation cancellation
    /// claim. A source-store marker by itself does not grant control authority.
    func cancelAuthorizedHandoff(request: ContinuityOperationCancellationRequest,
        acceptance: ContinuityIngressAcceptanceReceipt, cancellation: ToolCallCancellation? = nil
    ) throws -> ContinuityOperationCancellationMarker {
        try store.cancelContinuitySourceDelivery(request: request, acceptance: acceptance, cancellation: cancellation)
    }

    /// Explicit start authorizes one frozen handoff without changing automatic
    /// policy. The control plane authenticates native task correlation before
    /// reading source data or returning a previously accepted request.
    func submitAuthorizedHandoff(
        _ request: ContinuityExplicitHandoffRequest,
        taskID: UUID, correlation: VerifiedContinuityTaskCorrelation?,
        context: ToolInvocationContext, owner: ProjectBindingOwner,
        repository: ProjectControlPlaneRepository, config: ConfigStore,
        cancellation: ToolCallCancellation? = nil
    ) async throws -> ContinuityExplicitStartReceipt {
        guard let generation = Int(exactly: context.projectGeneration.rawValue) else {
            throw ContinuityIngressError.invalidRequest("project_generation")
        }
        let selection = try config.budgetPolicySelection(scope: BudgetPolicyScope(kind: .projectOverride,
            projectID: context.projectID.description, projectGeneration: generation))
        let requestID = try request.requestID(taskID: taskID, projectID: context.projectID,
                                             generation: context.projectGeneration)
        let source = store
        return try await repository.submitExplicitContinuityIngress(taskID: taskID, correlation: correlation,
            context: context, owner: owner, requestID: requestID, continuityID: request.continuityID,
            policySelection: selection, cancellation: cancellation) { authorization in
                guard let revision = try source.continuityLatestRevision(continuityID: request.continuityID,
                    authorization: authorization, cancellation: cancellation) else {
                    throw ContinuityIngressError.notFound
                }
                // This remains durable if control-plane admission is interrupted.
                // The outbox alone cannot grant explicit execution permission.
                return try source.enqueueContinuityHandoff(identity: revision.identity,
                    authorization: authorization, cancellation: cancellation).handoff
            }
    }

    /// Soft save — write/update packet; work may continue.
    public func checkpoint(
        arguments: [String: Any],
        clientID: ClientID,
        source: HandoffSource = .model,
        cancellation: ToolCallCancellation? = nil
    ) throws -> [String: Any] {
        let persisted = try mutateAndPersist(cancellation: cancellation) {
            try buildPacket(
                arguments: arguments,
                clientID: clientID,
                source: source,
                finalize: false,
                cancellation: cancellation
            )
        }
        let packet = persisted.packet
        diagnostics.info("session_checkpoint", [
            "handoff_id": packet.id,
            "client_id": clientID.rawValue,
            "source": source.rawValue,
            "agents": "\(packet.agents.count)",
        ], category: .general)
        return successPayload(packet, action: "checkpoint", projectionWarning: persisted.projectionWarning)
    }

    /// Finalize for new-chat resume.
    public func handoff(
        arguments: [String: Any],
        clientID: ClientID,
        source: HandoffSource = .model,
        cancellation: ToolCallCancellation? = nil
    ) throws -> [String: Any] {
        let persisted = try mutateAndPersist(cancellation: cancellation) {
            var packet = try buildPacket(
                arguments: arguments,
                clientID: clientID,
                source: source,
                finalize: true,
                cancellation: cancellation
            )
            packet.resumeReady = true
            if packet.resumeSeed.isEmpty {
                packet.resumeSeed = packet.defaultResumeSeed()
                packet.resumeSeedIsCustom = false
            }
            return packet
        }
        let packet = persisted.packet
        diagnostics.info("session_handoff", [
            "handoff_id": packet.id,
            "client_id": clientID.rawValue,
            "source": source.rawValue,
            "agents": "\(packet.agents.count)",
        ], category: .general)
        var payload = successPayload(packet, action: "handoff", projectionWarning: persisted.projectionWarning)
        payload["handoff_required"] = true
        payload["message"] =
            "Handoff saved. Start a new LM Studio chat with Forge MCP enabled, then call context_get " +
            "(or use resume.seed as the first user message)."
        return payload
    }

    public func get(
        id: String? = nil,
        preferResumeReady: Bool = false,
        cancellation: ToolCallCancellation? = nil
    ) throws -> [String: Any] {
        let packet: HandoffPacket?
        if let id, !id.isEmpty {
            packet = try store.handoffLegacyGet(id: id, cancellation: cancellation)
        } else {
            packet = try store.handoffLegacyLatest(
                resumeReadyOnly: preferResumeReady,
                cancellation: cancellation
            ) ?? store.handoffLegacyLatest(
                resumeReadyOnly: false,
                cancellation: cancellation
            )
        }
        guard let packet else {
            let message: String
            if let id, !id.isEmpty {
                message = "No handoff packet found for id \(id)."
            } else {
                message = "No handoff packet yet. Call session_checkpoint or session_handoff during work."
            }
            return [
                "ok": true,
                "found": false,
                "message": message,
                "bootstrap": [
                    "forge_status",
                    "session_checkpoint when you have a goal",
                ],
            ]
        }
        var payload = successPayload(packet, action: "get")
        payload["found"] = true
        return payload
    }

    public func list(
        limit: Int = 10,
        cancellation: ToolCallCancellation? = nil
    ) throws -> [String: Any] {
        let packets = try store.handoffLegacyList(limit: limit, cancellation: cancellation)
        return [
            "ok": true,
            "count": packets.count,
            "handoffs": packets.map { p in
                [
                    "id": p.id,
                    "updated_at": p.updatedAt,
                    "source": p.source.rawValue,
                    "resume_ready": p.resumeReady,
                    "goal": p.goal,
                    "status": p.status,
                    "agent_count": p.agents.count,
                ] as [String: Any]
            },
        ]
    }

    /// Compact status for forge_status.
    public func statusSummary(
        cancellation: ToolCallCancellation? = nil
    ) throws -> [String: Any] {
        let latest = try store.handoffLegacyLatest(
            resumeReadyOnly: false,
            cancellation: cancellation
        )
        let resume = try store.handoffLegacyLatest(
            resumeReadyOnly: true,
            cancellation: cancellation
        )
        let open = try store.sessionList(cancellation: cancellation).filter(\.status.isOpen)
        return [
            "latest_id": latest?.id as Any,
            "latest_updated_at": latest?.updatedAt as Any,
            "resume_ready": resume != nil,
            "resume_id": resume?.id as Any,
            "open_agent_sessions": open.count,
            "tools": [
                "session_checkpoint",
                "session_handoff",
                "context_get",
                "context_list",
            ],
            "note": "New chat bootstrap: call context_get over stdio MCP (forge-conductor).",
            "auto": [
                "checkpoint_every_tools": ContinuityAutomation.checkpointEveryTools,
                "handoff_every_tools": ContinuityAutomation.handoffEveryTools,
                "note": "Forge writes checkpoints and handoffs from tool progress; the model does not have to call session_*.",
            ],
        ]
    }

    /// Runtime checkpoint/handoff inferred from tool progress (not a model call).
    public func autoPersist(
        clientID: ClientID,
        reason: String,
        finalize: Bool,
        inferred: [String: Any],
        cancellation: ToolCallCancellation? = nil
    ) throws -> HandoffPacket {
        let persisted = try mutateAndPersist(cancellation: cancellation) {
            var args = inferred
            if let latest = try store.handoffLegacyLatest(
                clientID: clientID.rawValue,
                cancellation: cancellation
            ) ?? store.handoffLegacyLatest(
                resumeReadyOnly: false,
                cancellation: cancellation
            ) {
                args["handoff_id"] = latest.id
                // Runtime inference fills blanks only. A model/budget packet already
                // has the structured task; overwriting it would drop operator state.
                if !latest.goal.isEmpty { args.removeValue(forKey: "goal") }
                if latest.cwd?.isEmpty == false { args.removeValue(forKey: "cwd") }
                if !latest.nextActions.isEmpty { args.removeValue(forKey: "next_actions") }
                if !latest.blockers.isEmpty { args.removeValue(forKey: "blockers") }
                if !latest.keyFiles.isEmpty { args.removeValue(forKey: "key_files") }
                if !latest.decisions.isEmpty { args.removeValue(forKey: "decisions") }
                if !latest.narrative.isEmpty { args.removeValue(forKey: "narrative") }
                if latest.projectSlug?.isEmpty == false { args.removeValue(forKey: "project_slug") }
            }
            // Soft auto-checkpoints must not invent a status. Forcing
            // "in_progress" is what made an exploration packet look like a live resume.
            if finalize, args["status"] == nil {
                args["status"] = "handoff_ready"
            }
            var packet = try buildPacket(
                arguments: args,
                clientID: clientID,
                source: .auto,
                finalize: finalize,
                preserveAuthorIdentity: true,
                cancellation: cancellation
            )
            if packet.goal.isEmpty {
                packet.goal = finalize ? "Auto-handoff: \(reason)" : "Auto-checkpoint: \(reason)"
            }
            if finalize {
                let note = "Runtime continuity: \(reason)"
                if packet.narrative.isEmpty {
                    packet.narrative = note
                } else if !packet.narrative.contains(note) {
                    packet.narrative = String(
                        "\(packet.narrative)\n\n\(note)".prefix(HandoffPacket.maxNarrativeChars)
                    )
                }
            }
            if finalize {
                packet.resumeReady = true
                if !packet.resumeSeedIsCustom {
                    packet.resumeSeed = packet.defaultResumeSeed()
                }
            }
            return packet
        }
        diagnostics.info(finalize ? "auto_handoff_persist" : "auto_checkpoint_persist", [
            "handoff_id": persisted.packet.id,
            "client_id": clientID.rawValue,
            "reason": reason,
        ], category: .general)
        if finalize {
            try? writeNextChatHint(persisted.packet)
        }
        return persisted.packet
    }

    /// Auto-checkpoint used by budget policy (identical tool-loop / pressure).
    public func budgetAutoCheckpoint(
        clientID: ClientID,
        reason: String,
        cancellation: ToolCallCancellation? = nil
    ) throws -> HandoffPacket {
        let persisted = try mutateAndPersist(cancellation: cancellation) {
            var args: [String: Any] = ["status": "budget_pressure"]
            if let latest = try store.handoffLegacyLatest(
                clientID: clientID.rawValue,
                cancellation: cancellation
            ) {
                args["handoff_id"] = latest.id
            }
            var packet = try buildPacket(
                arguments: args,
                clientID: clientID,
                source: .budget,
                finalize: true,
                cancellation: cancellation
            )
            if packet.goal.isEmpty { packet.goal = "Auto-checkpoint: \(reason)" }
            if packet.nextActions.isEmpty {
                packet.nextActions = [
                    "Start a new chat if context is full",
                    "Call context_get",
                    "Continue from open agents",
                ]
            }
            let budgetNote = "Budget trigger: \(reason)"
            if packet.narrative.isEmpty {
                packet.narrative = budgetNote
            } else if !packet.narrative.contains(budgetNote) {
                packet.narrative = String(
                    "\(packet.narrative)\n\n\(budgetNote)".prefix(HandoffPacket.maxNarrativeChars)
                )
            }
            packet.resumeReady = true
            if !packet.resumeSeedIsCustom {
                packet.resumeSeed = packet.defaultResumeSeed()
            }
            return packet
        }
        let packet = persisted.packet
        diagnostics.warn("budget_handoff", [
            "handoff_id": packet.id,
            "client_id": clientID.rawValue,
            "reason": reason,
        ], category: .tools)
        try? writeNextChatHint(packet)
        return packet
    }

    private func writeNextChatHint(_ packet: HandoffPacket) throws {
        let seed = packet.resumeSeed.isEmpty ? packet.defaultResumeSeed() : packet.resumeSeed
        let body = """
        # Next chat

        Forge handed this work off. LM Studio cannot be opened to a new GUI chat from here.

        1. Start a **new** LM Studio chat with the Forge-Conductor preset and both MCP servers enabled.
        2. Call `context_get` (handoff id `\(packet.id)`).
        3. Continue from the packet. Do not keep using the previous chat — its project tools are blocked.

        ## Resume seed

        \(seed)
        """
        try body.write(to: paths.memoryNextChat, atomically: true, encoding: .utf8)
    }

    // MARK: - Build / persist

    private func buildPacket(
        arguments: [String: Any],
        clientID: ClientID,
        source: HandoffSource,
        finalize: Bool,
        preserveAuthorIdentity: Bool = false,
        authorization: ContinuityIngressAuthorization? = nil,
        cancellation: ToolCallCancellation? = nil
    ) throws -> HandoffPacket {
        try cancellation?.checkCancellation()
        let now = ISO8601.string(from: clock.now())
        let existingID = ToolArgHelpers.string(arguments, "handoff_id")
            ?? ToolArgHelpers.string(arguments, "id")
        let explicitResumeSeed = ToolArgHelpers.string(arguments, "resume_seed")
        var base = HandoffPacket(
            updatedAt: now,
            source: source,
            clientID: clientID.rawValue
        )
        if let existingID {
            let prior: HandoffPacket?
            if let authorization {
                // Authorize the exact source identity before reading any prior
                // packet. A mutable compatibility row is never a scoped fallback.
                if let frozen = try store.continuityLatestRevision(
                    continuityID: existingID, authorization: authorization,
                    cancellation: cancellation
                ) {
                    prior = HandoffPacket.fromDictionary(
                        try JSONSupport.object(from: frozen.canonicalPacketJSON)
                    )
                } else {
                    prior = nil
                }
            } else {
                prior = try store.handoffLegacyGet(id: existingID, cancellation: cancellation)
            }
            guard let prior else {
                throw StoreError.notFound("Unknown handoff packet: \(existingID)")
            }
            base = prior
            base.updatedAt = now
            if !(preserveAuthorIdentity && !finalize) {
                base.source = source
            }
        } else if authorization == nil, let latest = try store.handoffLegacyLatest(
            clientID: clientID.rawValue,
            cancellation: cancellation
        ), !latest.resumeReady {
            // Continue the calling MCP client's open packet when no id is supplied.
            base = latest
            base.updatedAt = now
            if !(preserveAuthorIdentity && !finalize) {
                base.source = source
            }
        } else {
            base.createdAt = now
            base.updatedAt = now
        }
        if preserveAuthorIdentity, existingID != nil || (base.clientID?.isEmpty == false) {
            // Keep the author of an existing packet. Diagnostic/smoke clients
            // must not become the resume identity.
        } else {
            base.clientID = clientID.rawValue
        }

        if let goal = ToolArgHelpers.string(arguments, "goal"), !goal.isEmpty { base.goal = goal }
        if let status = ToolArgHelpers.string(arguments, "status"), !status.isEmpty { base.status = status }
        if let slug = ToolArgHelpers.string(arguments, "project_slug")
            ?? ToolArgHelpers.string(arguments, "project") {
            base.projectSlug = slug
        }
        if let cwd = ToolArgHelpers.string(arguments, "cwd") { base.cwd = cwd }
        if let chat = ToolArgHelpers.string(arguments, "chat_label")
            ?? ToolArgHelpers.string(arguments, "chat") {
            base.chatLabel = chat
        }
        if let narrative = ToolArgHelpers.string(arguments, "narrative")
            ?? ToolArgHelpers.string(arguments, "summary") {
            base.narrative = String(narrative.prefix(HandoffPacket.maxNarrativeChars))
        }
        if let seed = explicitResumeSeed {
            base.resumeSeed = seed
            base.resumeSeedIsCustom = !seed.isEmpty
        }

        if let blockers = arguments["blockers"] as? [String] {
            base.blockers = blockers
        } else if let b = ToolArgHelpers.string(arguments, "blockers") {
            base.blockers = b.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        if let next = arguments["next_actions"] as? [String] {
            base.nextActions = next
        } else if let n = ToolArgHelpers.string(arguments, "next_actions") {
            base.nextActions = n.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        if let files = arguments["key_files"] as? [String] {
            base.keyFiles = files
        } else if let f = ToolArgHelpers.string(arguments, "key_files") {
            base.keyFiles = f.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        if let decisions = arguments["decisions"] as? [String] {
            base.decisions = decisions
        }

        if authorization == nil {
            let currentAgents = try snapshotAgents(
                clientID: clientID,
                cancellation: cancellation
            )
            if existingID != nil {
                // A resumed chat may checkpoint the recovered packet before it has
                // reattached every listed agent. Keep prior snapshots whose durable
                // sessions are still open, replacing them as the new client reattaches.
                base.agents = try mergeOpenAgentSnapshots(
                    prior: base.agents,
                    current: currentAgents,
                    cancellation: cancellation
                )
            } else {
                base.agents = currentAgents
            }

            // Legacy client-scoped snapshots remain available on their existing
            // path. A shared transport does not authorize importing another task's
            // agent goal, directory or open sessions into a scoped handoff.
            if let binding = try sessions.binding(for: clientID, cancellation: cancellation) {
                if base.goal.isEmpty { base.goal = binding.goal }
                if base.cwd == nil || base.cwd?.isEmpty == true { base.cwd = binding.cwd }
            }
        }

        if finalize {
            base.resumeReady = true
        }
        if explicitResumeSeed == nil, !base.resumeSeedIsCustom {
            base.resumeSeed = base.defaultResumeSeed()
        }
        return base
    }

    private func snapshotAgents(
        clientID: ClientID,
        cancellation: ToolCallCancellation?
    ) throws -> [AgentContinuitySnapshot] {
        let open = try store.sessionList(cancellation: cancellation).filter(\.status.isOpen)

        // Deduplicate by session id
        var seen = Set<String>()
        var snaps: [AgentContinuitySnapshot] = []
        for s in open where s.clientID == clientID {
            try cancellation?.checkCancellation()
            if snaps.count >= Self.maximumAgentSnapshots { break }
            if seen.contains(s.id.rawValue) { continue }
            seen.insert(s.id.rawValue)

            var goal = ""
            var cwd: String?
            if let body = try optionalMemoryGet(
                key: "agent_run/\(s.id.rawValue)",
                cancellation: cancellation
            ),
               let data = body.data(using: .utf8),
               let obj = try? JSONSupport.object(from: data) {
                goal = obj["goal"] as? String ?? ""
                cwd = obj["cwd"] as? String
            }
            if goal.isEmpty,
               let binding = try sessions.binding(for: clientID, cancellation: cancellation),
               binding.sessionID == s.id {
                goal = binding.goal
                cwd = binding.cwd
            }

            snaps.append(
                AgentContinuitySnapshot(
                    sessionID: s.id.rawValue,
                    agentID: s.agentID,
                    goal: goal,
                    cwd: cwd,
                    status: s.status.rawValue,
                    updatedAt: ISO8601.string(from: s.updatedAt),
                    resumeHint:
                        "agent_run_status(session_id: \"\(s.id.rawValue)\"); " +
                        "if stale, agent_run_complete then agent_run_start with same goal/cwd"
                )
            )
        }
        return snaps
    }

    private func mergeOpenAgentSnapshots(
        prior: [AgentContinuitySnapshot],
        current: [AgentContinuitySnapshot],
        cancellation: ToolCallCancellation?
    ) throws -> [AgentContinuitySnapshot] {
        var currentBySession: [String: AgentContinuitySnapshot] = [:]
        for snapshot in current {
            currentBySession[snapshot.sessionID] = snapshot
        }

        var merged: [AgentContinuitySnapshot] = []
        var seen = Set<String>()
        for snapshot in prior where seen.insert(snapshot.sessionID).inserted {
            try cancellation?.checkCancellation()
            if merged.count >= Self.maximumAgentSnapshots { break }
            guard let session = try store.sessionGet(
                id: SessionID(snapshot.sessionID),
                cancellation: cancellation
            ),
                  session.status.isOpen else {
                continue
            }
            merged.append(currentBySession.removeValue(forKey: snapshot.sessionID) ?? snapshot)
        }
        for snapshot in current where seen.insert(snapshot.sessionID).inserted {
            try cancellation?.checkCancellation()
            if merged.count >= Self.maximumAgentSnapshots { break }
            merged.append(snapshot)
        }
        return merged
    }

    private func optionalMemoryGet(
        key: String,
        cancellation: ToolCallCancellation?
    ) throws -> String? {
        do {
            return try store.memoryGet(key: key, cancellation: cancellation)
        } catch is CancellationError {
            throw CancellationError()
        } catch is ToolCallDeadlineExceeded {
            throw ToolCallDeadlineExceeded()
        } catch {
            return nil
        }
    }

    private struct PersistenceOutcome {
        var packet: HandoffPacket
        var projectionWarning: String?
        var ingressCommit: ContinuityHandoffCommit? = nil
    }

    private func mutateAndPersist(
        authorization: ContinuityIngressAuthorization? = nil,
        automaticHandoffEnabled: Bool = false,
        cancellation: ToolCallCancellation?,
        _ mutation: () throws -> HandoffPacket
    ) throws -> PersistenceOutcome {
        try lockContinuityMutex(
            lock,
            operation: "lock continuity service",
            cancellation: cancellation
        )
        defer { lock.unlock() }
        try cancellation?.checkCancellation()
        try paths.ensureLayout()
        return try withPersistenceFileLock(cancellation: cancellation) {
            try cancellation?.checkCancellation()
            let packet = try mutation()
            let ingress: ContinuityHandoffCommit?
            if let authorization {
                ingress = try store.handoffCommit(
                    packet, authorization: authorization,
                    automaticHandoffEnabled: automaticHandoffEnabled,
                    cancellation: cancellation
                )
            } else {
                try store.handoffUpsert(packet, cancellation: cancellation)
                ingress = nil
            }
            // SQLite is authoritative. A cancellation observed after this point
            // cannot turn the durable handoff into a reported failure.
            if ingress != nil {
                // Shared legacy projections carry no task authorization. Keep
                // scoped packets at the exact, authorized SQLite read boundary.
                return PersistenceOutcome(packet: packet, projectionWarning: nil, ingressCommit: ingress)
            }
            do {
                try writeProjections(packet)
                return PersistenceOutcome(packet: packet, projectionWarning: nil, ingressCommit: ingress)
            } catch {
                diagnostics.warn("continuity_projection_write_failed", [
                    "handoff_id": packet.id,
                    "error": "\(error)",
                ], category: .general)
                return PersistenceOutcome(packet: packet, projectionWarning: "\(error)", ingressCommit: ingress)
            }
        }
    }

    /// SQLite is authoritative. Rebuild the readable projections at process start
    /// so an interrupted write cannot leave LATEST/current-task.json out of sync.
    private func reconcileProjections() throws {
        try lockContinuityMutex(
            lock,
            operation: "lock continuity service",
            cancellation: nil
        )
        defer { lock.unlock() }
        try paths.ensureLayout()
        try withPersistenceFileLock(cancellation: nil) {
            try store.handoffRepairPointers()
            try ensureMemoryIndex()
            for packet in try store.handoffLegacyListAll() {
                do {
                    try writePacketProjection(packet)
                } catch {
                    diagnostics.warn("continuity_packet_projection_reconcile_failed", [
                        "handoff_id": packet.id,
                        "error": "\(error)",
                    ], category: .general)
                }
            }
            if let latest = try store.handoffLegacyLatest(resumeReadyOnly: false) {
                try writeLatestProjections(latest)
            }
        }
    }

    private func writeProjections(_ packet: HandoffPacket) throws {
        try writePacketProjection(packet)
        try writeLatestProjections(packet)
    }

    private func writePacketProjection(_ packet: HandoffPacket) throws {
        let fileURL = try packetProjectionURL(id: packet.id)
        let data = try JSONSupport.data(from: packet.asDictionary())
        try data.write(to: fileURL, options: .atomic)
    }

    private func writeLatestProjections(_ packet: HandoffPacket) throws {
        // Pointer for latest
        let latestURL = paths.memoryHandoffsDir.appendingPathComponent("LATEST")
        try packet.id.write(to: latestURL, atomically: true, encoding: .utf8)

        try projectCurrentTask(packet)
        try ensureMemoryIndex()
    }

    private func packetProjectionURL(id: String) throws -> URL {
        let root = paths.memoryHandoffsDir.standardizedFileURL
        let candidate = root.appendingPathComponent("\(id).json").standardizedFileURL
        guard candidate.deletingLastPathComponent() == root else {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: CocoaError.fileWriteInvalidFileName.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "Invalid handoff projection id"]
            )
        }
        return candidate
    }

    /// Primary and fallback MCP processes share one home. An advisory file lock
    /// makes the SQLite write and its JSON/Markdown projections one serialized unit.
    private func withPersistenceFileLock<T>(
        cancellation: ToolCallCancellation?,
        _ body: () throws -> T
    ) throws -> T {
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(Self.persistenceLockTimeout * 1_000_000_000)
        try lockContinuityMutex(
            Self.processPersistenceLock,
            operation: "lock process continuity service",
            cancellation: cancellation
        )
        defer { Self.processPersistenceLock.unlock() }
        try cancellation?.checkCancellation()

        let mode = mode_t(S_IRUSR | S_IWUSR)
        let descriptor = paths.memoryContinuityLock.path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR, mode)
        }
        guard descriptor >= 0 else {
            throw posixPersistenceError(operation: "open continuity lock")
        }
        defer { _ = Darwin.close(descriptor) }

        while Darwin.lockf(descriptor, F_TLOCK, 0) != 0 {
            let code = errno
            guard code == EACCES || code == EAGAIN else {
                throw posixPersistenceError(operation: "lock continuity projections", code: code)
            }
            try cancellation?.checkCancellation()
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                throw posixPersistenceError(operation: "lock continuity projections", code: EBUSY)
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        defer { _ = Darwin.lockf(descriptor, F_ULOCK, 0) }
        try cancellation?.checkCancellation()
        return try body()
    }

    private func lockContinuityMutex(
        _ mutex: NSLock,
        operation: String,
        cancellation: ToolCallCancellation?
    ) throws {
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(Self.persistenceLockTimeout * 1_000_000_000)
        while !mutex.lock(before: Date().addingTimeInterval(0.01)) {
            try cancellation?.checkCancellation()
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                throw posixPersistenceError(operation: operation, code: EBUSY)
            }
        }
        do {
            try cancellation?.checkCancellation()
        } catch {
            mutex.unlock()
            throw error
        }
    }

    private func posixPersistenceError(operation: String, code: Int32 = errno) -> NSError {
        return NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Failed to \(operation): \(String(cString: strerror(code)))",
            ]
        )
    }

    private func projectCurrentTask(_ packet: HandoffPacket) throws {
        var md = """
        # Current Work

        **Status:** \(packet.status)
        **Handoff id:** `\(packet.id)`
        **Source:** \(packet.source.rawValue)
        **Resume ready:** \(packet.resumeReady)
        """
        if let slug = packet.projectSlug { md += "\n**Project slug:** \(slug)" }
        if let cwd = packet.cwd { md += "\n**Workspace / cwd:** \(cwd)" }
        md += "\n\n## Goal\n\n\(packet.goal.isEmpty ? "_(not set)_" : packet.goal)\n"
        if !packet.nextActions.isEmpty {
            md += "\n## Next actions\n\n"
            for a in packet.nextActions { md += "- [ ] \(a)\n" }
        }
        if !packet.blockers.isEmpty {
            md += "\n## Blockers\n\n"
            for b in packet.blockers { md += "- \(b)\n" }
        }
        if !packet.agents.isEmpty {
            md += "\n## Open agents\n\n"
            for a in packet.agents {
                md += "- **\(a.agentID)** `\(a.sessionID)` — \(a.status)"
                if !a.goal.isEmpty { md += " — \(a.goal)" }
                md += "\n"
            }
        }
        if !packet.narrative.isEmpty {
            md += "\n## Narrative\n\n\(packet.narrative)\n"
        }
        md += "\n## Last updated\n\n\(packet.updatedAt)\n"
        try md.write(to: paths.memoryCurrentTask, atomically: true, encoding: .utf8)
    }

    private func ensureMemoryIndex() throws {
        guard !FileManager.default.fileExists(atPath: paths.memoryIndex.path) else { return }
        let index = """
        # Forge Conductor — Durable Memory

        | Path | Purpose |
        |------|---------|
        | `INDEX.md` | This map |
        | `current-task.md` | Active goal / handoff projection |
        | `handoffs/` | Versioned context + agent continuity packets |

        Bootstrap every new chat: `forge_status` → `context_get` → continue task.
        """
        try index.write(to: paths.memoryIndex, atomically: true, encoding: .utf8)
    }

    private func successPayload(
        _ packet: HandoffPacket,
        action: String,
        projectionWarning: String? = nil
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "ok": true,
            "action": action,
            "handoff_id": packet.id,
            "resume_ready": packet.resumeReady,
            "packet": packet.asDictionary(),
            "resume_seed": packet.resumeSeed.isEmpty ? packet.defaultResumeSeed() : packet.resumeSeed,
            "paths": [
                "json": paths.memoryHandoffsDir.appendingPathComponent("\(packet.id).json").path,
                "current_task": paths.memoryCurrentTask.path,
            ] as [String: Any],
        ]
        payload["projection_ok"] = projectionWarning == nil
        payload["projection_repair_pending"] = projectionWarning != nil
        if let projectionWarning {
            payload["projection_warning"] = projectionWarning
        }
        return payload
    }
}
