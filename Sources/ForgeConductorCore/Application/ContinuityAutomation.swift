// ContinuityAutomation.swift
// What: Runtime continuity that does not wait for the model to call session_*.
// How: Tracks per-client progress, infers workspace from packets and tool paths,
// and persists checkpoint/handoff packets from the tool router.
// Why: Long LM Studio turns never invoked session_handoff; the server must.

import Foundation

/// Extra observed workspace roots used for project context, relative-path
/// defaults, continuity evidence, and destructive-root protection.
public protocol WorkspaceRootProviding: AnyObject {
    func additionalRoots(for clientID: ClientID) -> [URL]
    func additionalRoots(
        for clientID: ClientID,
        cancellation: ToolCallCancellation?
    ) throws -> [URL]
}

public extension WorkspaceRootProviding {
    func additionalRoots(
        for clientID: ClientID,
        cancellation: ToolCallCancellation?
    ) throws -> [URL] {
        try cancellation?.checkCancellation()
        let roots = additionalRoots(for: clientID)
        try cancellation?.checkCancellation()
        return roots
    }
}

/// Observed result of a progress tool that may annotate the MCP payload.
public struct ContinuityObservation: Sendable {
    public var packet: HandoffPacket
    public var finalize: Bool
    public var reason: String
}

struct RuntimeContinuityProgress: Codable, Sendable {
    var epoch = UUID().uuidString.lowercased()
    var progressCount = 0
    var failureCount = 0
    var lastCheckpointCount = 0
    var lastHandoffCount = 0
    var lastCheckpointFailureCount = 0
    var lastHandoffFailureCount = 0
    var startedAt: Date?
    var lastCheckpointAt: Date?
    var lastHandoffAt: Date?
    var lastTools: [String] = []
    var lastPaths: [String] = []
    var blocked = false
    var lastHandoffID: String?
    var lastResumeSeed: String?
    var latestPacketID: String?
    var latestRuntimeCheckpointID: String?
    var capacityFailure: String?
    var pending: RuntimeContinuityProgressClaim?
    var rolloverRequested: Bool?
    var runtimeJobSubmissions: [RuntimeJobContinuationReference]?

    func runtimeJobSnapshot(scopeKey: String) throws -> RuntimeJobContinuationSnapshot? {
        guard let submissions = runtimeJobSubmissions, !submissions.isEmpty else { return nil }
        guard let origin = UUID(uuidString: epoch) else {
            throw StoreError.execFailed("runtime continuity epoch is invalid")
        }
        return try RuntimeJobContinuationSnapshot(schemaVersion: 1, scopeKey: scopeKey,
            originEpoch: origin, submissions: submissions).validated()
    }

    static func utf8Prefix(_ value: String, maximumBytes: Int) -> String {
        var output = ""
        output.reserveCapacity(maximumBytes)
        var bytes = 0
        for scalar in value.unicodeScalars {
            let text = String(scalar)
            let count = text.utf8.count
            guard bytes + count <= maximumBytes else { break }
            output.append(text)
            bytes += count
        }
        return output
    }

    static func resumeSeed(for packet: HandoffPacket) -> String {
        utf8Prefix(packet.resumeSeed.isEmpty ? packet.defaultResumeSeed() : packet.resumeSeed, maximumBytes: 16_384)
    }

    func validated() throws -> Self {
        let counters = [progressCount, failureCount, lastCheckpointCount, lastHandoffCount,
                        lastCheckpointFailureCount, lastHandoffFailureCount]
        guard UUID(uuidString: epoch) != nil, counters.allSatisfy({ (0...1_000_000).contains($0) }),
              lastCheckpointCount <= progressCount, lastHandoffCount <= progressCount,
              lastCheckpointFailureCount <= failureCount, lastHandoffFailureCount <= failureCount,
              lastTools.count <= 12, lastPaths.count <= 16,
              lastTools.allSatisfy({ $0.utf8.count <= 256 }),
              lastPaths.allSatisfy({ $0.utf8.count <= 4_096 }),
              [lastHandoffID, latestPacketID, latestRuntimeCheckpointID].compactMap({ $0 }).allSatisfy({ UUID(uuidString: $0) != nil }),
              capacityFailure.map({ $0.utf8.count <= 1_024 }) ?? true,
              lastResumeSeed.map({ $0.utf8.count <= 16_384 }) ?? true else {
            throw StoreError.execFailed("runtime continuity progress is invalid")
        }
        if let pending {
            guard pending.scopeKey.utf8.count == 64, pending.epoch == epoch,
                  UUID(uuidString: pending.packetID) != nil, UUID(uuidString: pending.ownerID) != nil,
                  (0...progressCount).contains(pending.progressCount),
                  (0...failureCount).contains(pending.failureCount),
                  pending.claimedAt.timeIntervalSinceReferenceDate.isFinite,
                  pending.expiresAt.timeIntervalSinceReferenceDate.isFinite else {
                throw StoreError.execFailed("runtime continuity claim is invalid")
            }
        }
        if let runtimeJobSubmissions {
            guard runtimeJobSubmissions.count <= RuntimeJobContinuationSnapshot.maximumReferences,
                  Set(runtimeJobSubmissions.map(\.submissionID)).count == runtimeJobSubmissions.count,
                  runtimeJobSubmissions.allSatisfy({ RuntimeJobContinuationReference.tools.contains($0.tool) }) else {
                throw StoreError.execFailed("runtime continuity submissions are invalid")
            }
        }
        return self
    }
}

struct RuntimeContinuityProgressClaim: Codable, Sendable, Equatable {
    let scopeKey: String
    let epoch: String
    let packetID: String
    var ownerID: String
    let finalize: Bool
    let progressCount: Int
    let failureCount: Int
    let claimedAt: Date
    var expiresAt: Date
}

/// Server-side continuity: checkpoint and handoff without a model tool call.
public final class ContinuityAutomation: WorkspaceRootProviding, @unchecked Sendable {
    public static let checkpointEveryTools = 50
    public static let handoffEveryTools = 200
    public static let checkpointIntervalSec: TimeInterval = 1_800
    public static let handoffIntervalSec: TimeInterval = 7_200
    public static let checkpointEveryFailedTools = 50
    public static let handoffEveryFailedTools = 200
    static let progressClaimLeaseSec: TimeInterval = 30
    static let maxTrackedClients = 128
    static let maxImplicitRootsPerClient = 16

    private let store: SQLiteStore
    private let sessions: AgentSessionService
    private let continuity: ContextContinuityService
    private let diagnostics: DiagnosticLog
    private let clock: any Clock
    private let projectContexts: ProjectContextService?
    private let configStore: ConfigStore?
    private let lock = NSLock()

    private struct ClientState {
        var progressCount = 0
        var lastCheckpointCount = 0
        var lastHandoffCount = 0
        var lastCheckpointAt: Date?
        var lastHandoffAt: Date?
        var implicitRoots: [URL] = []
        var lastTools: [String] = []
        var lastPaths: [String] = []
        var blocked = false
        var lastHandoffID: String?
        var lastResumeSeed: String?
    }

    private var state: [String: ClientState] = [:]

    public init(
        store: SQLiteStore,
        sessions: AgentSessionService,
        continuity: ContextContinuityService,
        diagnostics: DiagnosticLog,
        clock: any Clock,
        projectContexts: ProjectContextService? = nil,
        configStore: ConfigStore? = nil
    ) {
        self.store = store
        self.sessions = sessions
        self.continuity = continuity
        self.diagnostics = diagnostics
        self.clock = clock
        self.projectContexts = projectContexts
        self.configStore = configStore
    }

    public func additionalRoots(for clientID: ClientID) -> [URL] {
        (try? additionalRoots(for: clientID, cancellation: nil)) ?? []
    }

    public func additionalRoots(
        for clientID: ClientID,
        cancellation: ToolCallCancellation?
    ) throws -> [URL] {
        let context = try runtimeContext(for: clientID, cancellation: cancellation)
        let key = context.map { runtimeScopeKey($0) } ?? clientID.rawValue
        let implicit = try withStateLock(cancellation: cancellation) {
            state[key]?.implicitRoots ?? []
        }

        var roots = implicit
        if let context {
            roots.append(contentsOf: context.authorizationScope.canonicalRoots)
            if let progress = try store.runtimeContinuityProgress(scopeKey: key, cancellation: cancellation) {
                roots.append(contentsOf: progress.lastPaths.map { ToolArgHelpers.resolvePath($0).deletingLastPathComponent() })
            }
            return uniqued(roots)
        }
        if let binding = try sessions.binding(for: clientID, cancellation: cancellation),
           let cwd = binding.cwd,
           !cwd.isEmpty {
            roots.append(ToolArgHelpers.resolvePath(cwd))
        }
        let clientPacket = try bestEffortHandoff(
            clientID: clientID.rawValue,
            cancellation: cancellation
        )
        let globalPacket = try bestEffortHandoff(
            clientID: nil,
            cancellation: cancellation
        )
        if let packet = clientPacket ?? globalPacket,
           let cwd = packet.cwd, !cwd.isEmpty {
            roots.append(ToolArgHelpers.resolvePath(cwd))
        }
        if let packet = globalPacket {
            for file in packet.keyFiles {
                try cancellation?.checkCancellation()
                let url = ToolArgHelpers.resolvePath(file)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                    roots.append(isDir.boolValue ? url : url.deletingLastPathComponent())
                }
            }
        }
        try cancellation?.checkCancellation()
        return uniqued(roots)
    }

    private func bestEffortHandoff(
        clientID: String?,
        cancellation: ToolCallCancellation?
    ) throws -> HandoffPacket? {
        do {
            return try store.handoffLatest(
                resumeReadyOnly: false,
                clientID: clientID,
                cancellation: cancellation
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ToolCallDeadlineExceeded {
            throw error
        } catch {
            return nil
        }
    }

    /// Remember a workspace from a loaded handoff packet or an adopted path.
    public func adopt(clientID: ClientID, paths: [String]) {
        try? adopt(clientID: clientID, paths: paths, cancellation: nil)
    }

    public func adopt(
        clientID: ClientID,
        paths: [String],
        cancellation: ToolCallCancellation?
    ) throws {
        var urls: [URL] = []
        for raw in paths {
            try cancellation?.checkCancellation()
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            urls.append(
                try directoryURL(
                    for: ToolArgHelpers.resolvePath(trimmed),
                    cancellation: cancellation
                )
            )
        }
        guard !urls.isEmpty else { return }
        let context = try runtimeContext(for: clientID, cancellation: cancellation)
        let key = context.map { runtimeScopeKey($0) } ?? clientID.rawValue
        try withStateLock(cancellation: cancellation) {
            var current = state[key] ?? ClientState()
            current.implicitRoots = Array(
                uniqued(current.implicitRoots + urls).suffix(Self.maxImplicitRootsPerClient)
            )
            makeRoomForClientIfNeeded(key)
            state[key] = current
        }
    }

    public func adopt(clientID: ClientID, packet: HandoffPacket) {
        try? adopt(clientID: clientID, packet: packet, cancellation: nil)
    }

    public func adopt(
        clientID: ClientID,
        packet: HandoffPacket,
        cancellation: ToolCallCancellation?
    ) throws {
        if let context = try runtimeContext(for: clientID, cancellation: cancellation),
           !packetMatchesProject(packet, context: context) { return }
        var paths: [String] = packet.keyFiles
        if let cwd = packet.cwd { paths.insert(cwd, at: 0) }
        try adopt(clientID: clientID, paths: paths, cancellation: cancellation)
    }

    /// Record a dispatched tool. Returns a packet when the runtime persisted continuity.
    public func observe(
        tool: String,
        arguments: [String: Any],
        clientID: ClientID,
        succeeded: Bool,
        cancellation: ToolCallCancellation? = nil,
        trustedContext: ToolInvocationContext? = nil
    ) -> ContinuityObservation? {
        let attemptID = UUID()
        var stage = "progress_observation"
        var operation = "unavailable_before_threshold_selection"
        var persistenceAttempted = false
        do {
            try cancellation?.checkCancellation()
            if let trustedContext {
                guard trustedContext.clientID == clientID, let projectContexts else {
                    throw ProjectContextError.projectScopeMismatch
                }
                try projectContexts.validate(trustedContext, cancellation: cancellation)
                // Manager-owned runs and provider sessions have their own durable
                // capacity evaluators and lifecycle. They must not become ordinary
                // external-chat epochs through a same-client MCP lookup.
                if trustedContext.runID != nil || trustedContext.providerSessionID != nil {
                    return nil
                }
            }
            if Self.progressTools.contains(tool) {
                try configStore?.refreshIfChanged()
                try cancellation?.checkCancellation()
            }
            let observedPath = ToolArgHelpers.string(arguments, "path")
                ?? ToolArgHelpers.string(arguments, "cwd")
            if let observedPath {
                try adopt(
                    clientID: clientID,
                    paths: [observedPath],
                    cancellation: cancellation
                )
            }
            if Self.progressTools.contains(tool),
               let context = try runtimeContext(for: clientID, cancellation: cancellation) {
                stage = "durable_progress"
                return try observeDurable(
                    tool: tool, observedPath: observedPath, clientID: clientID,
                    context: context, succeeded: succeeded, attemptID: attemptID,
                    cancellation: cancellation
                )
            }
            guard succeeded, Self.progressTools.contains(tool) else { return nil }

            let now = clock.now()
            let handoffThreshold = handoffToolThreshold
            let checkpointThreshold = min(Self.checkpointEveryTools, handoffThreshold)
            let update = try withStateLock(cancellation: cancellation) { () -> (
                current: ClientState,
                progress: Int,
                checkpointDue: Bool,
                handoffDue: Bool
            ) in
                var current = state[clientID.rawValue] ?? ClientState()
                if current.lastCheckpointAt == nil { current.lastCheckpointAt = now }
                if current.lastHandoffAt == nil { current.lastHandoffAt = now }
                current.progressCount += 1
                current.lastTools.append(tool)
                if current.lastTools.count > 12 {
                    current.lastTools.removeFirst(current.lastTools.count - 12)
                }
                if let observedPath {
                    current.lastPaths.append(observedPath)
                    if current.lastPaths.count > 16 {
                        current.lastPaths.removeFirst(current.lastPaths.count - 16)
                    }
                }
                let progress = current.progressCount
                let sinceCheckpoint = progress - current.lastCheckpointCount
                let sinceHandoff = progress - current.lastHandoffCount
                let forcePersist = Self.forcePersistTools.contains(tool)
                let checkpointDue = forcePersist
                    || sinceCheckpoint >= checkpointThreshold
                    || current.lastCheckpointAt.map({
                        now.timeIntervalSince($0) >= Self.checkpointIntervalSec
                    }) == true
                let handoffDue = sinceHandoff >= handoffThreshold
                    || current.lastHandoffAt.map({
                        now.timeIntervalSince($0) >= Self.handoffIntervalSec
                    }) == true
                makeRoomForClientIfNeeded(clientID.rawValue)
                state[clientID.rawValue] = current
                return (current, progress, checkpointDue, handoffDue)
            }

            guard update.checkpointDue || update.handoffDue else { return nil }
            operation = update.handoffDue ? "handoff" : "checkpoint"
            stage = "inference"
            let inferred = try inferredArguments(
                clientID: clientID,
                lastTools: update.current.lastTools,
                lastPaths: update.current.lastPaths,
                cancellation: cancellation
            )
            let finalize = update.handoffDue
            let reason = finalize
                ? "auto_handoff progress=\(update.progress)"
                : "auto_checkpoint progress=\(update.progress)"
            stage = "packet_persistence"
            persistenceAttempted = true
            let packet = try continuity.autoPersist(
                clientID: clientID,
                reason: reason,
                finalize: finalize,
                inferred: inferred,
                attemptID: attemptID,
                cancellation: cancellation
            )
            // The packet is durable at this point. Updating the in-memory mirror is
            // best effort and must not let a late cancellation hide that commit.
            try? withStateLock(cancellation: nil) {
                if var next = state[clientID.rawValue] {
                    next.lastCheckpointCount = update.progress
                    next.lastCheckpointAt = now
                    if finalize {
                        next.lastHandoffCount = update.progress
                        next.lastHandoffAt = now
                        next.blocked = true
                        next.lastHandoffID = packet.id
                        next.lastResumeSeed = packet.resumeSeed.isEmpty
                            ? packet.defaultResumeSeed()
                            : packet.resumeSeed
                    }
                    state[clientID.rawValue] = next
                }
            }
            diagnostics.info(finalize ? "auto_handoff" : "auto_checkpoint", [
                "handoff_id": packet.id,
                "client_id": clientID.rawValue,
                "progress": "\(update.progress)",
                "reason": reason,
                "attempt_id": attemptID.uuidString,
                "operation": operation,
                "finalize": finalize ? "true" : "false",
                "resume_ready": packet.resumeReady ? "true" : "false",
                "source": packet.source.rawValue,
                "save_outcome": "committed",
                "successor_request_state": finalize
                    ? "deferred_to_interactive_successor" : "not_applicable_checkpoint",
            ], category: .general)
            return ContinuityObservation(packet: packet, finalize: finalize, reason: reason)
        } catch is CancellationError {
            return nil
        } catch is ToolCallDeadlineExceeded {
            return nil
        } catch {
            if !persistenceAttempted {
                diagnostics.warn("auto_continuity_failed", [
                    "attempt_id": attemptID.uuidString,
                    "client_id": clientID.rawValue,
                    "operation": operation,
                    "error": "\(error)",
                    "error_type": String(reflecting: type(of: error)),
                    "error_domain": (error as NSError).domain,
                    "error_numeric_code": "\((error as NSError).code)",
                    "failure_stage": stage,
                    "handoff_id": "unavailable_before_packet_build",
                    "successor_request_state": "not_requested_before_persistence",
                ], category: .general)
            }
            return nil
        }
    }

    public func isBlocked(_ clientID: ClientID) -> Bool {
        (try? isBlocked(clientID, cancellation: nil)) ?? false
    }

    public func isBlocked(
        _ clientID: ClientID,
        cancellation: ToolCallCancellation?
    ) throws -> Bool {
        if let context = try runtimeContext(for: clientID, cancellation: cancellation) {
            return try store.runtimeContinuityProgress(
                scopeKey: runtimeScopeKey(context), cancellation: cancellation
            )?.blocked == true
        }
        return try withStateLock(cancellation: cancellation) {
            state[clientID.rawValue]?.blocked == true
        }
    }

    public func blockState(_ clientID: ClientID) -> (handoffID: String?, resumeSeed: String?) {
        (try? blockState(clientID, cancellation: nil)) ?? (nil, nil)
    }

    public func blockState(
        _ clientID: ClientID,
        cancellation: ToolCallCancellation?
    ) throws -> (handoffID: String?, resumeSeed: String?) {
        if let context = try runtimeContext(for: clientID, cancellation: cancellation) {
            let progress = try store.runtimeContinuityProgress(scopeKey: runtimeScopeKey(context), cancellation: cancellation)
            return (progress?.lastHandoffID, progress?.lastResumeSeed)
        }
        return try withStateLock(cancellation: cancellation) {
            let current = state[clientID.rawValue]
            return (current?.lastHandoffID, current?.lastResumeSeed)
        }
    }

    public func markBlocked(clientID: ClientID, packet: HandoffPacket) {
        if let context = try? runtimeContext(for: clientID, cancellation: nil) {
            _ = try? store.updateRuntimeContinuityProgress(scopeKey: runtimeScopeKey(context)) { progress in
                progress.blocked = true
                progress.lastHandoffID = packet.id
                progress.lastResumeSeed = RuntimeContinuityProgress.resumeSeed(for: packet)
            }
            return
        }
        markLocalBlocked(clientID: clientID, packet: packet)
    }

    private func markLocalBlocked(clientID: ClientID, packet: HandoffPacket) {
        try? withStateLock(cancellation: nil) {
            var current = state[clientID.rawValue] ?? ClientState()
            current.blocked = true
            current.lastHandoffID = packet.id
            current.lastResumeSeed = packet.resumeSeed.isEmpty
                ? packet.defaultResumeSeed()
                : packet.resumeSeed
            makeRoomForClientIfNeeded(clientID.rawValue)
            state[clientID.rawValue] = current
        }
    }

    func budgetAutoCheckpoint(
        clientID: ClientID,
        reason: String,
        blockProgress: Bool = false,
        cancellation: ToolCallCancellation?
    ) throws -> HandoffPacket {
        guard let context = try runtimeContext(for: clientID, cancellation: cancellation) else {
            let packet = try continuity.budgetAutoCheckpoint(
                clientID: clientID, reason: reason, cancellation: cancellation
            )
            if blockProgress { markLocalBlocked(clientID: clientID, packet: packet) }
            return packet
        }
        let key = runtimeScopeKey(context)
        do {
            return try continuity.budgetRuntimeCheckpoint(
                clientID: clientID, reason: reason, context: context, scopeKey: key,
                blockProgress: blockProgress, cancellation: cancellation
            )
        } catch let StoreError.execFailed(message) where message == SQLiteStore.runtimeContinuityPacketCapacityMessage {
            _ = try? store.updateRuntimeContinuityProgress(scopeKey: key) { $0.capacityFailure = message }
            throw StoreError.execFailed(message)
        }
    }

    public func clearBlock(clientID: ClientID) {
        try? clearBlock(clientID: clientID, cancellation: nil)
    }

    func recordInteractiveResumeAcknowledgement(
        packet: HandoffPacket,
        rolloverNonce: String,
        clientID: ClientID,
        cancellation: ToolCallCancellation?
    ) throws -> [String: Any] {
        guard let packetScope = try store.runtimeContinuityPacketScopeKey(
            packetID: packet.id, cancellation: cancellation
        ) else {
            return try continuity.recordInteractiveResumeAcknowledgement(
                handoffID: packet.id, rolloverNonce: rolloverNonce,
                clientID: clientID, cancellation: cancellation
            )
        }
        guard let projectContexts,
              let context = try runtimeContext(for: clientID, cancellation: cancellation),
              context.runID == nil, context.providerSessionID == nil,
              runtimeScopeKey(context) == packetScope else {
            throw ProjectContextError.projectScopeMismatch
        }
        // Hold the native binding/generation fence through this bounded receipt
        // write. Clearing the current epoch remains a separate exact-ID operation.
        let receiptData = try projectContexts.commitIfCurrent(
            context: context, resultKind: "interactive_resume_acknowledgement",
            cancellation: cancellation
        ) { control in
            guard try self.store.runtimeContinuityPacketScopeKey(
                packetID: packet.id, cancellation: control
            ) == packetScope,
                  let persisted = try self.store.handoffLegacyGet(id: packet.id, cancellation: control),
                  persisted.resumeReady, persisted.clientID == clientID.rawValue,
                  self.packetMatchesProject(persisted, context: context) else {
                throw ProjectContextError.projectScopeMismatch
            }
            return try JSONSupport.data(from: self.continuity.recordInteractiveResumeAcknowledgement(
                handoffID: persisted.id, rolloverNonce: rolloverNonce,
                clientID: clientID, cancellation: control
            ))
        }
        return try JSONSupport.object(from: receiptData)
    }

    public func clearBlock(
        clientID: ClientID,
        packet: HandoffPacket? = nil,
        cancellation: ToolCallCancellation?
    ) throws {
        _ = try clearBlockReportingResult(clientID: clientID, packet: packet, cancellation: cancellation)
    }

    func clearBlockReportingResult(
        clientID: ClientID,
        packet: HandoffPacket? = nil,
        cancellation: ToolCallCancellation?
    ) throws -> Bool {
        if let context = try runtimeContext(for: clientID, cancellation: cancellation) {
            var cleared = false
            let key = runtimeScopeKey(context)
            _ = try store.updateRuntimeContinuityProgress(scopeKey: key, cancellation: cancellation) { progress in
                if let packet {
                    guard packetMatchesProject(packet, context: context),
                          packet.resumeReady, progress.lastHandoffID == packet.id else { return }
                }
                if progress.runtimeJobSubmissions?.isEmpty == false {
                    guard let packet,
                          packet.runtimeJobContinuation == (try progress.runtimeJobSnapshot(scopeKey: key)) else {
                        return
                    }
                }
                // This is Forge's logical continuity epoch. Shared stdio exposes no
                // authenticated identity for the external host's individual chat.
                var successor = RuntimeContinuityProgress()
                successor.latestPacketID = packet?.id
                progress = successor
                cleared = true
            }
            return cleared
        }
        if let packet, try store.runtimeContinuityPacketScopeKey(packetID: packet.id, cancellation: cancellation) != nil {
            // Read-only recovery before explicit project binding cannot release
            // another deployment's durable continuity epoch.
            return false
        }
        try withStateLock(cancellation: cancellation) {
            if var current = state[clientID.rawValue] {
                current.blocked = false
                current.progressCount = 0
                current.lastCheckpointCount = 0
                current.lastHandoffCount = 0
                state[clientID.rawValue] = current
            }
        }
        return true
    }

    public func snapshot(for clientID: ClientID) -> [String: Any] {
        (try? snapshot(for: clientID, cancellation: nil)) ?? ["enabled": true]
    }

    public func snapshot(
        for clientID: ClientID,
        cancellation: ToolCallCancellation?
    ) throws -> [String: Any] {
        if let context = try runtimeContext(for: clientID, cancellation: cancellation) {
            let key = runtimeScopeKey(context)
            let progress = try store.runtimeContinuityProgress(scopeKey: key, cancellation: cancellation)
            let roots = try withStateLock(cancellation: cancellation) { state[key]?.implicitRoots ?? [] }
            let attention = try runtimeContinuityFailureReceipt(for: clientID, cancellation: cancellation)
            return [
                "enabled": true,
                "checkpoint_every_tools": min(Self.checkpointEveryTools, handoffToolThreshold),
                "handoff_every_tools": handoffToolThreshold,
                "progress_count": progress?.progressCount ?? 0,
                "failed_tool_count": progress?.failureCount ?? 0,
                "tool_call_count": (progress?.progressCount ?? 0) + (progress?.failureCount ?? 0),
                "checkpoint_every_failed_tools": min(Self.checkpointEveryFailedTools, handoffToolThreshold),
                "handoff_every_failed_tools": handoffToolThreshold,
                "blocked": progress?.blocked ?? false,
                "handoff_id": progress?.lastHandoffID as Any,
                "implicit_roots": roots.map(\.path),
                "project_id": context.projectID.description,
                "project_generation": context.projectGeneration.rawValue,
                "continuity_epoch": progress?.epoch as Any,
                "session_identity_source": "forge_logical_epoch",
                "external_context_usage": "unavailable",
                "continuity_attention_required": attention != nil,
                "continuity_error": attention?["message"] as Any,
                "continuity_attention": attention as Any,
            ]
        }
        let current = try withStateLock(cancellation: cancellation) {
            state[clientID.rawValue]
        }
        return [
            "enabled": true,
            "checkpoint_every_tools": min(Self.checkpointEveryTools, handoffToolThreshold),
            "handoff_every_tools": handoffToolThreshold,
            "progress_count": current?.progressCount ?? 0,
            "blocked": current?.blocked ?? false,
            "handoff_id": current?.lastHandoffID as Any,
            "implicit_roots": (current?.implicitRoots ?? []).map(\.path),
        ]
    }

    var trackedClientCount: Int {
        lock.lock(); defer { lock.unlock() }
        return state.count
    }

    private func runtimeContext(
        for clientID: ClientID,
        cancellation: ToolCallCancellation?
    ) throws -> ToolInvocationContext? {
        guard let projectContexts else { return nil }
        do {
            return try projectContexts.invocationContext(for: clientID, cancellation: cancellation)
        } catch ProjectContextError.projectContextRequired {
            return nil
        } catch ProjectContextError.invalidIdentifier("binding owner") {
            // An invalid owner cannot have a durable binding. Bootstrap still
            // owns reporting a committed initialization with pending attachment.
            return nil
        }
    }

    func runtimeScopeKey(_ context: ToolInvocationContext) -> String {
        // Only native-validated identity participates. Tool arguments cannot select
        // a project generation, deployment client, or provider session.
        JSONSupport.sha256Hex("runtime-continuity-v1:\(context.projectID.description):\(context.projectGeneration.rawValue):\(JSONSupport.sha256Hex(context.clientID.rawValue)):\(JSONSupport.sha256Hex(context.providerSessionID ?? "forge-logical-epoch"))")
    }

    /// The runtime CP transaction validates the caller before invoking this
    /// separate precommit seam. Its closure owns only a bounded Source mutation.
    func prepareOrdinaryRuntimeJobAdmission(
        tool: String,
        context: ToolInvocationContext,
        cancellation: ToolCallCancellation?
    ) throws -> RuntimeJobPreCommitAdmission? {
        guard context.runID == nil, context.providerSessionID == nil, context.runtimeJobID == nil,
              RuntimeJobContinuationReference.tools.contains(tool) else { return nil }
        let key = runtimeScopeKey(context)
        let progress = try store.updateRuntimeContinuityProgress(scopeKey: key, cancellation: cancellation) { current in
            guard !current.blocked else {
                throw StoreError.conflict("runtime continuity is already handed off")
            }
            guard (current.runtimeJobSubmissions?.count ?? 0) < RuntimeJobContinuationSnapshot.maximumReferences else {
                throw StoreError.conflict("runtime continuity submission capacity reached before job commit")
            }
        }
        let epoch = progress.epoch
        let submissionID = UUID()
        let source = store
        return { record in
            guard record.projectID == context.projectID,
                  record.projectGeneration == context.projectGeneration else {
                throw ProjectContextError.projectScopeMismatch
            }
            _ = try source.updateRuntimeContinuityProgress(scopeKey: key, cancellation: cancellation) { current in
                guard current.epoch == epoch, !current.blocked else {
                    throw StoreError.conflict("runtime continuity epoch changed before job commit")
                }
                var submissions = current.runtimeJobSubmissions ?? []
                guard submissions.count < RuntimeJobContinuationSnapshot.maximumReferences,
                      !submissions.contains(where: { $0.submissionID == submissionID }) else {
                    throw StoreError.conflict("runtime continuity admission was consumed or reached capacity")
                }
                submissions.append(RuntimeJobContinuationReference(submissionID: submissionID,
                    jobID: record.jobID, tool: tool))
                current.runtimeJobSubmissions = submissions
                _ = try current.runtimeJobSnapshot(scopeKey: key)
                if submissions.count == RuntimeJobContinuationSnapshot.maximumReferences {
                    current.rolloverRequested = true
                }
            }
        }
    }

    func packetReadScope(
        context: ToolInvocationContext?,
        cancellation: ToolCallCancellation?
    ) throws -> ContinuityPacketReadScope {
        guard let context else {
            if let projectContexts,
               let selection = try projectContexts.soleActiveContinuityReadProject(cancellation: cancellation) {
                return ContinuityPacketReadScope(
                    runtimeScopeKeys: Set(selection.contexts.map(runtimeScopeKey)),
                    canonicalRoots: [selection.project.canonicalRoot], legacyRequiresProjectRoot: false
                )
            }
            // Ambiguous recovery retains the original NULL-owned legacy surface.
            return ContinuityPacketReadScope(runtimeScopeKeys: [], canonicalRoots: nil)
        }
        guard let projectContexts else { throw ProjectContextError.projectScopeMismatch }
        let current = try projectContexts.continuityReadContexts(for: context, cancellation: cancellation)
        var keys = Set(current.map(runtimeScopeKey))
        keys.insert(runtimeScopeKey(context))
        return ContinuityPacketReadScope(runtimeScopeKeys: keys,
            canonicalRoots: context.authorizationScope.canonicalRoots)
    }

    private var handoffToolThreshold: Int {
        configStore?.model.sessions.continuityRolloverToolCalls ?? Self.handoffEveryTools
    }

    func runtimeContinuityFailureReceipt(
        for clientID: ClientID,
        cancellation: ToolCallCancellation? = nil
    ) throws -> [String: Any]? {
        guard let context = try runtimeContext(for: clientID, cancellation: cancellation) else { return nil }
        let progress = try store.runtimeContinuityProgress(scopeKey: runtimeScopeKey(context), cancellation: cancellation)
        let message: String
        let resource: String
        let limit: Int
        if let failure = progress?.capacityFailure {
            message = failure
            resource = "runtime_continuity_packets"
            limit = SQLiteStore.maximumRuntimeContinuityPackets
        } else if progress == nil, try store.runtimeContinuityScopeCapacityReached(cancellation: cancellation) {
            message = "Runtime continuity scope capacity reached. Existing evidence was retained."
            resource = "runtime_continuity_scopes"
            limit = SQLiteStore.maximumRuntimeContinuityScopes
        } else { return nil }
        return ["code": "continuity_capacity_reached", "message": message,
                "attention_required": true, "resource": resource, "limit": limit,
                "handoff_persisted": false, "retryable": false]
    }

    private func packetMatchesProject(_ packet: HandoffPacket, context: ToolInvocationContext) -> Bool {
        guard let cwd = packet.cwd else { return false }
        let path = ToolArgHelpers.resolvePath(cwd).resolvingSymlinksInPath().standardizedFileURL.path
        return context.authorizationScope.canonicalRoots.contains { root in
            let canonical = root.resolvingSymlinksInPath().standardizedFileURL.path
            return path == canonical || path.hasPrefix(canonical + "/")
        }
    }

    private func observeDurable(
        tool: String,
        observedPath: String?,
        clientID: ClientID,
        context: ToolInvocationContext,
        succeeded: Bool,
        attemptID: UUID,
        cancellation: ToolCallCancellation?,
        accountProgress: Bool = true
    ) throws -> ContinuityObservation? {
        let now = clock.now()
        let handoffThreshold = handoffToolThreshold
        let checkpointThreshold = min(Self.checkpointEveryTools, handoffThreshold)
        let key = runtimeScopeKey(context)
        let ownerID = attemptID.uuidString
        let progress = try store.updateRuntimeContinuityProgress(scopeKey: key, cancellation: cancellation) { current in
            guard !current.blocked else { return }
            if accountProgress {
                if current.startedAt == nil { current.startedAt = now }
                if succeeded {
                    current.progressCount = min(current.progressCount + 1, 1_000_000)
                } else {
                    current.failureCount = min(current.failureCount + 1, 1_000_000)
                }
                current.lastTools = Array((current.lastTools + [tool]).suffix(12))
                if let observedPath {
                    current.lastPaths = Array((current.lastPaths + [RuntimeContinuityProgress.utf8Prefix(observedPath, maximumBytes: 4_096)]).suffix(16))
                }
            }
            let sinceHandoff = current.progressCount - current.lastHandoffCount
                + current.failureCount - current.lastHandoffFailureCount
            let handoffDue = current.rolloverRequested == true || sinceHandoff >= handoffThreshold
                || (current.runtimeJobSubmissions?.count ?? 0) >= RuntimeJobContinuationSnapshot.maximumReferences
                || now.timeIntervalSince(current.lastHandoffAt ?? current.startedAt ?? now) >= Self.handoffIntervalSec
            if handoffDue { current.rolloverRequested = true }
            if var pending = current.pending {
                if pending.expiresAt <= now {
                    pending.ownerID = ownerID
                    pending.expiresAt = now.addingTimeInterval(Self.progressClaimLeaseSec)
                    current.pending = pending
                }
                return
            }
            let sinceCheckpoint = current.progressCount - current.lastCheckpointCount
                + current.failureCount - current.lastCheckpointFailureCount
            let checkpointDue = accountProgress && (Self.forcePersistTools.contains(tool)
                || sinceCheckpoint >= checkpointThreshold
                || now.timeIntervalSince(current.lastCheckpointAt ?? current.startedAt ?? now) >= Self.checkpointIntervalSec)
            guard checkpointDue || handoffDue else { return }
            current.pending = RuntimeContinuityProgressClaim(
                scopeKey: key, epoch: current.epoch, packetID: current.latestRuntimeCheckpointID ?? UUID().uuidString.lowercased(),
                ownerID: ownerID, finalize: handoffDue, progressCount: current.progressCount,
                failureCount: current.failureCount, claimedAt: now,
                expiresAt: now.addingTimeInterval(Self.progressClaimLeaseSec)
            )
        }
        guard let claim = progress.pending, claim.ownerID == ownerID else { return nil }
        var inferred = try inferredArguments(
            clientID: clientID, lastTools: progress.lastTools, lastPaths: progress.lastPaths,
            context: context,
            cancellation: cancellation
        )
        // The trusted selected project owns the packet root. Another client's
        // global legacy packet cannot become this project's task or identity.
        if let root = context.authorizationScope.canonicalRoots.first { inferred["cwd"] = root.path }
        let reason = "auto_\(claim.finalize ? "handoff" : "checkpoint") progress=\(claim.progressCount) failed_tools=\(claim.failureCount)"
        let committed: RuntimeContinuityCommit
        do {
            committed = try continuity.autoPersistRuntime(
                clientID: clientID, reason: reason, inferred: inferred, attemptID: attemptID,
                claim: claim, priorPacketID: progress.latestPacketID, cancellation: cancellation
            )
        } catch {
            // A failed transaction retains its exact packet intent. Make this
            // observer's claim immediately retryable without stealing a newer claim.
            _ = try? store.updateRuntimeContinuityProgress(scopeKey: key) { current in
                if current.pending == claim {
                    current.pending?.expiresAt = now
                    if case let StoreError.execFailed(message) = error,
                       message == SQLiteStore.runtimeContinuityPacketCapacityMessage {
                        current.capacityFailure = message
                    }
                }
            }
            throw error
        }
        let packet = committed.packet
        diagnostics.info(committed.finalize ? "auto_handoff" : "auto_checkpoint", [
            "handoff_id": packet.id, "client_id": clientID.rawValue,
            "project_id": context.projectID.description,
            "project_generation": "\(context.projectGeneration.rawValue)",
            "continuity_epoch": claim.epoch, "progress": "\(committed.progressCount)",
            "failed_tools": "\(committed.failureCount)", "reason": committed.reason,
            "attempt_id": attemptID.uuidString,
            "operation": committed.finalize ? "handoff" : "checkpoint",
            "finalize": committed.finalize ? "true" : "false",
            "resume_ready": packet.resumeReady ? "true" : "false",
            "source": packet.source.rawValue, "save_outcome": "committed",
            "successor_request_state": committed.finalize
                ? "deferred_to_interactive_successor" : "not_applicable_checkpoint",
        ], category: .general)
        let observation = ContinuityObservation(packet: packet, finalize: committed.finalize, reason: committed.reason)
        if accountProgress, !committed.finalize,
           let promoted = try observeDurable(
            tool: tool, observedPath: observedPath, clientID: clientID, context: context,
            succeeded: succeeded, attemptID: attemptID, cancellation: cancellation,
            accountProgress: false
           ) {
            return promoted
        }
        return observation
    }

    private func withStateLock<Value>(
        cancellation: ToolCallCancellation?,
        _ body: () throws -> Value
    ) throws -> Value {
        let lockDeadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        while !lock.lock(before: Date().addingTimeInterval(0.01)) {
            try cancellation?.checkCancellation()
            guard DispatchTime.now().uptimeNanoseconds < lockDeadline else {
                throw StoreError.execFailed("continuity state is busy")
            }
        }
        defer { lock.unlock() }
        try cancellation?.checkCancellation()
        return try body()
    }

    private func makeRoomForClientIfNeeded(_ key: String) {
        guard state[key] == nil, state.count >= Self.maxTrackedClients else { return }
        if let victim = state.keys.filter({ $0 != key }).sorted().first {
            state.removeValue(forKey: victim)
        }
    }

    private func inferredArguments(
        clientID: ClientID,
        lastTools: [String],
        lastPaths: [String],
        context: ToolInvocationContext? = nil,
        cancellation: ToolCallCancellation?
    ) throws -> [String: Any] {
        var args: [String: Any] = [:]
        if let binding = try sessions.binding(for: clientID, cancellation: cancellation),
           context.map({ selected in
               binding.cwd.map { cwd in
                   packetMatchesProject(HandoffPacket(cwd: cwd), context: selected)
               } ?? false
           }) ?? true {
            if !binding.goal.isEmpty { args["goal"] = binding.goal }
            if let cwd = binding.cwd, !cwd.isEmpty { args["cwd"] = cwd }
        }
        if args["cwd"] == nil,
           let first = try additionalRoots(
                for: clientID,
                cancellation: cancellation
           ).first {
            args["cwd"] = first.path
        }
        try cancellation?.checkCancellation()
        if !lastPaths.isEmpty {
            args["key_files"] = Array(Set(lastPaths)).sorted().suffix(12).map { $0 }
        }
        let uniqueTools = Array(NSOrderedSet(array: lastTools)) as? [String] ?? lastTools
        args["narrative"] = "Auto-saved after tools: \(uniqueTools.suffix(8).joined(separator: ", "))."
        args["next_actions"] = [
            "Call get_forge_status with resume=true in the successor chat",
            "Continue from the workspace in this packet",
        ]
        return args
    }

    private func directoryURL(
        for url: URL,
        cancellation: ToolCallCancellation?
    ) throws -> URL {
        try cancellation?.checkCancellation()
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            try cancellation?.checkCancellation()
            return url.standardizedFileURL
        }
        try cancellation?.checkCancellation()
        return url.deletingLastPathComponent().standardizedFileURL
    }

    private func uniqued(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var out: [URL] = []
        for url in urls {
            let path = url.standardizedFileURL.path
            if seen.insert(path).inserted {
                out.append(url.standardizedFileURL)
            }
        }
        return out
    }

    static let forcePersistTools: Set<String> = [
        "agent_run_start", "agent_run_complete",
    ]

    static let resumeTools: Set<String> = [
        "forge_status", "get_forge_status", "context_get", "context_list",
        "session_checkpoint", "session_handoff",
        "memory_get", "memory_list", "memory_search", "memory_set", "memory_delete",
        "agent_list", "agent_get", "agent_context", "agent_recommend",
        "agent_run_status", "agent_run_complete",
    ]

    static let progressTools: Set<String> = [
        "fs_read", "fs_write", "fs_edit", "fs_list", "fs_glob", "fs_mkdir", "fs_delete", "fs_delete_recovery", "fs_move",
        "shell_exec",
        "git_status", "git_diff", "git_log", "git_add", "git_commit",
        "memory_set",
        "agent_run_start", "agent_run_complete",
        "search_text",
        "web.fetch", "web.search", "web.render",
        "pdf_write", "pdf_from_file", "docx_write", "xlsx_write", "pptx_write", "ods_write", "image_write",
        "process.run", "shell.run", "bash.run", "python.run", "powershell.run",
        "job.status", "job.read_output", "job.list", "job.cancel",
        "xcode.discover", "xcode.run", "xcode.result", "xcode.debug", "xcode.simulator",
    ]
}
