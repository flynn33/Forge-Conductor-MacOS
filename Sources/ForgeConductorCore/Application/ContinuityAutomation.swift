// ContinuityAutomation.swift
// What: Runtime continuity that does not wait for the model to call session_*.
// How: Tracks per-client progress, infers workspace from packets and tool paths,
// and persists checkpoint/handoff packets from the tool router.
// Why: Long LM Studio turns never invoked session_handoff; the server must.

import Foundation

/// Extra filesystem roots granted without a live agent binding.
public protocol WorkspaceRootProviding: AnyObject {
    func additionalRoots(for clientID: ClientID) -> [URL]
}

/// Observed result of a progress tool that may annotate the MCP payload.
public struct ContinuityObservation: Sendable {
    public var packet: HandoffPacket
    public var finalize: Bool
    public var reason: String
}

/// Server-side continuity: checkpoint and handoff without a model tool call.
public final class ContinuityAutomation: WorkspaceRootProviding, @unchecked Sendable {
    public static let checkpointEveryTools = 5
    public static let handoffEveryTools = 20
    public static let checkpointIntervalSec: TimeInterval = 180
    public static let handoffIntervalSec: TimeInterval = 720

    private let store: SQLiteStore
    private let sessions: AgentSessionService
    private let continuity: ContextContinuityService
    private let diagnostics: DiagnosticLog
    private let clock: any Clock
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
        clock: any Clock
    ) {
        self.store = store
        self.sessions = sessions
        self.continuity = continuity
        self.diagnostics = diagnostics
        self.clock = clock
    }

    public func additionalRoots(for clientID: ClientID) -> [URL] {
        lock.lock()
        let implicit = state[clientID.rawValue]?.implicitRoots ?? []
        lock.unlock()

        var roots = implicit
        if let binding = sessions.binding(for: clientID), let cwd = binding.cwd, !cwd.isEmpty {
            roots.append(ToolArgHelpers.resolvePath(cwd))
        }
        if let packet = try? store.handoffLatest(clientID: clientID.rawValue)
            ?? store.handoffLatest(resumeReadyOnly: false),
           let cwd = packet.cwd, !cwd.isEmpty {
            roots.append(ToolArgHelpers.resolvePath(cwd))
        }
        if let packet = try? store.handoffLatest(resumeReadyOnly: false) {
            for file in packet.keyFiles {
                let url = ToolArgHelpers.resolvePath(file)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                    roots.append(isDir.boolValue ? url : url.deletingLastPathComponent())
                }
            }
        }
        return uniqued(roots)
    }

    /// Remember a workspace from a loaded handoff packet or an adopted path.
    public func adopt(clientID: ClientID, paths: [String]) {
        let urls = paths.compactMap { raw -> URL? in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return directoryURL(for: ToolArgHelpers.resolvePath(trimmed))
        }
        guard !urls.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        var current = state[clientID.rawValue] ?? ClientState()
        current.implicitRoots = uniqued(current.implicitRoots + urls)
        state[clientID.rawValue] = current
    }

    public func adopt(clientID: ClientID, packet: HandoffPacket) {
        var paths: [String] = packet.keyFiles
        if let cwd = packet.cwd { paths.insert(cwd, at: 0) }
        adopt(clientID: clientID, paths: paths)
    }

    /// Record a dispatched tool. Returns a packet when the runtime persisted continuity.
    public func observe(
        tool: String,
        arguments: [String: Any],
        clientID: ClientID,
        succeeded: Bool
    ) -> ContinuityObservation? {
        if let path = ToolArgHelpers.string(arguments, "path") ?? ToolArgHelpers.string(arguments, "cwd") {
            adopt(clientID: clientID, paths: [path])
        }

        guard succeeded, Self.progressTools.contains(tool) else { return nil }

        let now = clock.now()
        lock.lock()
        var current = state[clientID.rawValue] ?? ClientState()
        current.progressCount += 1
        current.lastTools.append(tool)
        if current.lastTools.count > 12 {
            current.lastTools.removeFirst(current.lastTools.count - 12)
        }
        if let path = ToolArgHelpers.string(arguments, "path") ?? ToolArgHelpers.string(arguments, "cwd") {
            current.lastPaths.append(path)
            if current.lastPaths.count > 16 {
                current.lastPaths.removeFirst(current.lastPaths.count - 16)
            }
        }
        let progress = current.progressCount
        let sinceCheckpoint = progress - current.lastCheckpointCount
        let sinceHandoff = progress - current.lastHandoffCount
        let forcePersist = Self.forcePersistTools.contains(tool)
        let checkpointDue = forcePersist
            || sinceCheckpoint >= Self.checkpointEveryTools
            || current.lastCheckpointAt.map({ now.timeIntervalSince($0) >= Self.checkpointIntervalSec }) == true
        let handoffDue = sinceHandoff >= Self.handoffEveryTools
            || current.lastHandoffAt.map({ now.timeIntervalSince($0) >= Self.handoffIntervalSec }) == true
        state[clientID.rawValue] = current
        lock.unlock()

        guard checkpointDue || handoffDue else { return nil }

        let inferred = inferredArguments(clientID: clientID, lastTools: current.lastTools, lastPaths: current.lastPaths)
        let finalize = handoffDue
        let reason = finalize
            ? "auto_handoff progress=\(progress)"
            : "auto_checkpoint progress=\(progress)"
        do {
            let packet = try continuity.autoPersist(
                clientID: clientID,
                reason: reason,
                finalize: finalize,
                inferred: inferred
            )
            lock.lock()
            if var next = state[clientID.rawValue] {
                next.lastCheckpointCount = progress
                next.lastCheckpointAt = now
                if finalize {
                    next.lastHandoffCount = progress
                    next.lastHandoffAt = now
                    next.blocked = true
                    next.lastHandoffID = packet.id
                    next.lastResumeSeed = packet.resumeSeed.isEmpty
                        ? packet.defaultResumeSeed()
                        : packet.resumeSeed
                }
                state[clientID.rawValue] = next
            }
            lock.unlock()
            diagnostics.info(finalize ? "auto_handoff" : "auto_checkpoint", [
                "handoff_id": packet.id,
                "client_id": clientID.rawValue,
                "progress": "\(progress)",
                "reason": reason,
            ], category: .general)
            return ContinuityObservation(packet: packet, finalize: finalize, reason: reason)
        } catch {
            diagnostics.warn("auto_continuity_failed", [
                "client_id": clientID.rawValue,
                "reason": reason,
                "error": "\(error)",
            ], category: .general)
            return nil
        }
    }

    public func isBlocked(_ clientID: ClientID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return state[clientID.rawValue]?.blocked == true
    }

    public func blockState(_ clientID: ClientID) -> (handoffID: String?, resumeSeed: String?) {
        lock.lock()
        defer { lock.unlock() }
        let current = state[clientID.rawValue]
        return (current?.lastHandoffID, current?.lastResumeSeed)
    }

    public func markBlocked(clientID: ClientID, packet: HandoffPacket) {
        lock.lock()
        defer { lock.unlock() }
        var current = state[clientID.rawValue] ?? ClientState()
        current.blocked = true
        current.lastHandoffID = packet.id
        current.lastResumeSeed = packet.resumeSeed.isEmpty ? packet.defaultResumeSeed() : packet.resumeSeed
        state[clientID.rawValue] = current
    }

    public func clearBlock(clientID: ClientID) {
        lock.lock()
        defer { lock.unlock() }
        if var current = state[clientID.rawValue] {
            current.blocked = false
            current.progressCount = 0
            current.lastCheckpointCount = 0
            current.lastHandoffCount = 0
            state[clientID.rawValue] = current
        }
    }

    public func snapshot(for clientID: ClientID) -> [String: Any] {
        lock.lock()
        let current = state[clientID.rawValue]
        lock.unlock()
        return [
            "enabled": true,
            "checkpoint_every_tools": Self.checkpointEveryTools,
            "handoff_every_tools": Self.handoffEveryTools,
            "progress_count": current?.progressCount ?? 0,
            "blocked": current?.blocked ?? false,
            "handoff_id": current?.lastHandoffID as Any,
            "implicit_roots": (current?.implicitRoots ?? []).map(\.path),
        ]
    }

    private func inferredArguments(
        clientID: ClientID,
        lastTools: [String],
        lastPaths: [String]
    ) -> [String: Any] {
        var args: [String: Any] = [:]
        if let binding = sessions.binding(for: clientID) {
            if !binding.goal.isEmpty { args["goal"] = binding.goal }
            if let cwd = binding.cwd, !cwd.isEmpty { args["cwd"] = cwd }
        }
        if args["cwd"] == nil, let first = additionalRoots(for: clientID).first {
            args["cwd"] = first.path
        }
        if !lastPaths.isEmpty {
            args["key_files"] = Array(Set(lastPaths)).sorted().suffix(12).map { $0 }
        }
        let uniqueTools = Array(NSOrderedSet(array: lastTools)) as? [String] ?? lastTools
        args["narrative"] = "Auto-saved after tools: \(uniqueTools.suffix(8).joined(separator: ", "))."
        args["next_actions"] = [
            "Call context_get if this is a new chat",
            "Continue from the workspace in this packet",
        ]
        return args
    }

    private func directoryURL(for url: URL) -> URL {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return url.standardizedFileURL
        }
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
        "forge_status", "context_get", "context_list",
        "session_checkpoint", "session_handoff",
        "memory_get", "memory_list", "memory_search", "memory_set", "memory_delete",
        "agent_list", "agent_get", "agent_context", "agent_recommend",
        "agent_run_status", "agent_run_complete",
    ]

    static let progressTools: Set<String> = [
        "fs_read", "fs_write", "fs_edit", "fs_list", "fs_glob", "fs_mkdir", "fs_delete", "fs_move",
        "shell_exec",
        "git_status", "git_diff", "git_log", "git_add", "git_commit",
        "memory_set",
        "agent_run_start", "agent_run_complete",
        "search_text",
        "pdf_write", "pdf_from_file",
    ]
}
