// HandoffPacket.swift
// What: Versioned context + agent continuity payload for chat handoff/resume.
// How: Codable-ish dictionary wire form with stable keys for MCP/JSONL/SQLite.
// Why: New LM Studio chats must rehydrate task and open agent sessions without HTTP.

import Foundation
import CoreFoundation

/// Source that produced a handoff packet.
public enum HandoffSource: String, Sendable, Codable, Equatable {
    case model
    case budget
    case user
    case auto
}

/// Snapshot of an open (or recently open) specialist agent for resume.
public struct AgentContinuitySnapshot: Sendable, Equatable {
    public var sessionID: String
    public var agentID: String
    public var goal: String
    public var cwd: String?
    public var status: String
    public var updatedAt: String?
    public var resumeHint: String

    public init(
        sessionID: String,
        agentID: String,
        goal: String = "",
        cwd: String? = nil,
        status: String = "open",
        updatedAt: String? = nil,
        resumeHint: String = ""
    ) {
        self.sessionID = sessionID
        self.agentID = agentID
        self.goal = goal
        self.cwd = cwd
        self.status = status
        self.updatedAt = updatedAt
        self.resumeHint = resumeHint
    }

    public func asDictionary() -> [String: Any] {
        var d: [String: Any] = [
            "session_id": sessionID,
            "agent_id": agentID,
            "goal": goal,
            "status": status,
            "resume_hint": resumeHint,
        ]
        if let cwd { d["cwd"] = cwd }
        if let updatedAt { d["updated_at"] = updatedAt }
        return d
    }

    public static func fromDictionary(_ d: [String: Any]) -> AgentContinuitySnapshot? {
        for key in ["session_id", "agent_id", "goal", "cwd", "status", "updated_at", "resume_hint"] {
            if d[key] != nil, !(d[key] is String) { return nil }
        }
        guard let sessionID = d["session_id"] as? String,
              !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let agentID = d["agent_id"] as? String,
              !agentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return AgentContinuitySnapshot(
            sessionID: sessionID,
            agentID: agentID,
            goal: d["goal"] as? String ?? "",
            cwd: d["cwd"] as? String,
            status: d["status"] as? String ?? "open",
            updatedAt: d["updated_at"] as? String,
            resumeHint: d["resume_hint"] as? String ?? ""
        )
    }
}

struct RuntimeJobContinuationReference: Codable, Sendable, Equatable {
    let submissionID: UUID
    let jobID: UUID
    let tool: String

    static let tools: Set<String> = ["process.run", "shell.run", "bash.run", "python.run", "powershell.run"]

    enum CodingKeys: String, CodingKey {
        case submissionID = "submission_id"
        case jobID = "job_id"
        case tool
    }

    func asDictionary() -> [String: Any] {
        ["submission_id": submissionID.uuidString.lowercased(),
         "job_id": jobID.uuidString.lowercased(), "tool": tool]
    }
}

struct RuntimeJobContinuationSnapshot: Codable, Sendable, Equatable {
    static let maximumReferences = 32
    static let maximumBytes = 16_384

    let schemaVersion: Int
    let scopeKey: String
    let originEpoch: UUID
    let submissions: [RuntimeJobContinuationReference]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case scopeKey = "scope_key"
        case originEpoch = "origin_epoch"
        case submissions
    }

    func validated() throws -> Self {
        guard schemaVersion == 1, scopeKey.utf8.count == 64,
              scopeKey.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              !submissions.isEmpty, submissions.count <= Self.maximumReferences,
              Set(submissions.map(\.submissionID)).count == submissions.count,
              submissions.allSatisfy({ RuntimeJobContinuationReference.tools.contains($0.tool) }),
              try JSONSupport.data(from: asDictionary()).count <= Self.maximumBytes else {
            throw StoreError.execFailed("runtime job continuation is invalid or exceeds its bound")
        }
        return self
    }

    func asDictionary() -> [String: Any] {
        ["schema_version": schemaVersion, "scope_key": scopeKey,
         "origin_epoch": originEpoch.uuidString.lowercased(),
         "submissions": submissions.map { $0.asDictionary() }]
    }
}

/// Durable handoff packet (schema_version 1).
public struct HandoffPacket: Sendable, Equatable {
    public static let schemaVersion = 1
    public static let maxNarrativeChars = 4_000

    public var id: String
    public var schemaVersion: Int
    public var createdAt: String
    public var updatedAt: String
    public var source: HandoffSource
    public var resumeReady: Bool
    public var chatLabel: String?
    public var clientID: String?

    // Work item
    public var goal: String
    public var status: String
    public var projectSlug: String?
    public var cwd: String?
    public var blockers: [String]
    public var nextActions: [String]

    // Working set
    public var keyFiles: [String]
    public var decisions: [String]

    // Agents
    public var agents: [AgentContinuitySnapshot]

    // Narrative + resume seed
    public var narrative: String
    public var resumeSeed: String
    public var resumeSeedIsCustom: Bool
    // Only native continuity persistence grants authority to this optional field.
    var runtimeJobContinuation: RuntimeJobContinuationSnapshot?

    public init(
        id: String = UUID().uuidString.lowercased(),
        schemaVersion: Int = HandoffPacket.schemaVersion,
        createdAt: String = ISO8601.string(from: Date()),
        updatedAt: String = ISO8601.string(from: Date()),
        source: HandoffSource = .model,
        resumeReady: Bool = false,
        chatLabel: String? = nil,
        clientID: String? = nil,
        goal: String = "",
        status: String = "in_progress",
        projectSlug: String? = nil,
        cwd: String? = nil,
        blockers: [String] = [],
        nextActions: [String] = [],
        keyFiles: [String] = [],
        decisions: [String] = [],
        agents: [AgentContinuitySnapshot] = [],
        narrative: String = "",
        resumeSeed: String = "",
        resumeSeedIsCustom: Bool = false
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.source = source
        self.resumeReady = resumeReady
        self.chatLabel = chatLabel
        self.clientID = clientID
        self.goal = goal
        self.status = status
        self.projectSlug = projectSlug
        self.cwd = cwd
        self.blockers = blockers
        self.nextActions = nextActions
        self.keyFiles = keyFiles
        self.decisions = decisions
        self.agents = agents
        self.narrative = String(narrative.prefix(Self.maxNarrativeChars))
        self.resumeSeed = resumeSeed
        self.resumeSeedIsCustom = resumeSeedIsCustom
        runtimeJobContinuation = nil
    }

    public func asDictionary() -> [String: Any] {
        var meta: [String: Any] = [
            "id": id,
            "schema_version": schemaVersion,
            "created_at": createdAt,
            "updated_at": updatedAt,
            "source": source.rawValue,
            "resume_ready": resumeReady,
        ]
        if let chatLabel { meta["chat_label"] = chatLabel }
        if let clientID { meta["client_id"] = clientID }

        var task: [String: Any] = [
            "goal": goal,
            "status": status,
            "blockers": blockers,
            "next_actions": nextActions,
        ]
        if let projectSlug { task["project_slug"] = projectSlug }
        if let cwd { task["cwd"] = cwd }

        var instructions = [
            "Call get_forge_status with resume=true to reload the handoff",
            "Pass this handoff id to session_checkpoint/session_handoff when continuing it",
            "Reattach open agents with agent_run_status(session_id) or complete and restart",
            "Update memory/current-task.md via session_checkpoint as you progress",
        ]
        if runtimeJobContinuation != nil {
            instructions.append("Read each runtime_continuation submission with job.status, then job.read_output for stdout and stderr. Never resubmit a recorded command; a missing job is unresolved, not proof it did not run.")
        }
        var result: [String: Any] = [
            "schema_version": schemaVersion,
            "meta": meta,
            "task": task,
            "working_set": [
                "key_files": keyFiles,
                "decisions": decisions,
            ] as [String: Any],
            "agents": agents.map { $0.asDictionary() },
            "narrative": narrative,
            "resume": [
                "seed": resumeSeed.isEmpty ? defaultResumeSeed() : resumeSeed,
                "custom": resumeSeedIsCustom,
                "instructions": instructions,
            ] as [String: Any],
        ]
        if let runtimeJobContinuation {
            result["runtime_continuation"] = runtimeJobContinuation.asDictionary()
        }
        return result
    }

    public func defaultResumeSeed() -> String {
        var lines: [String] = [
            "Forge Continuity resume (handoff \(id)).",
            "Goal: \(goal.isEmpty ? "(none recorded)" : goal)",
            "Status: \(status)",
        ]
        if let cwd, !cwd.isEmpty { lines.append("cwd: \(cwd)") }
        if let projectSlug, !projectSlug.isEmpty { lines.append("project: \(projectSlug)") }
        if !nextActions.isEmpty {
            lines.append("Next actions:")
            for a in nextActions.prefix(8) { lines.append("- \(a)") }
        }
        if !agents.isEmpty {
            lines.append("Open agents:")
            for a in agents.prefix(8) {
                lines.append(
                    "- \(a.agentID) session=\(a.sessionID) status=\(a.status) goal=\(a.goal.prefix(80))"
                )
            }
            lines.append("Use agent_run_status / agent_run_complete then continue; do not invent session state.")
        }
        if !narrative.isEmpty {
            lines.append("Summary: \(narrative.prefix(500))")
        }
        if let runtimeJobContinuation {
            lines.append("Recorded runtime submissions (completion is not assumed):")
            for reference in runtimeJobContinuation.submissions {
                lines.append("- \(reference.tool) job_id=\(reference.jobID.uuidString.lowercased())")
            }
            lines.append("Read job.status and both job.read_output streams; do not rerun these commands. Missing retained jobs require attention.")
        }
        lines.append("Continue this packet with handoff_id: \(id) on later checkpoints or handoffs.")
        lines.append("Call get_forge_status with resume=true, then continue the task.")
        return lines.joined(separator: "\n")
    }

    public static func fromDictionary(_ root: [String: Any]) -> HandoffPacket? {
        if let runtime = root["runtime_continuation"], !(runtime is NSNull) {
            guard let object = runtime as? [String: Any],
                  let bytes = try? JSONSupport.data(from: object),
                  bytes.count <= RuntimeJobContinuationSnapshot.maximumBytes else { return nil }
        }
        let wire: HandoffPacketWire
        do {
            let data = try JSONSupport.data(from: root)
            wire = try JSONDecoder().decode(HandoffPacketWire.self, from: data)
        } catch {
            return nil
        }
        let rootVersion = wire.schemaVersion
        let metaVersion = wire.meta?.schemaVersion
        guard rootVersion == nil || rootVersion == schemaVersion,
              metaVersion == nil || metaVersion == schemaVersion,
              rootVersion == nil || metaVersion == nil || rootVersion == metaVersion else {
            return nil
        }
        guard let id = wire.meta?.id ?? wire.id,
              isSafeID(id) else {
            return nil
        }
        let sourceRaw = wire.meta?.source ?? HandoffSource.model.rawValue
        guard let source = HandoffSource(rawValue: sourceRaw) else { return nil }
        var agentList: [AgentContinuitySnapshot] = []
        for agent in wire.agents ?? [] {
            guard !agent.sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !agent.agentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            agentList.append(AgentContinuitySnapshot(
                sessionID: agent.sessionID,
                agentID: agent.agentID,
                goal: agent.goal ?? "",
                cwd: agent.cwd,
                status: agent.status ?? "open",
                updatedAt: agent.updatedAt,
                resumeHint: agent.resumeHint ?? ""
            ))
        }

        let resumeSeed = wire.resume?.seed ?? ""
        let customMarker = wire.resume?.custom
        let task = wire.task
        let working = wire.workingSet
        let meta = wire.meta
        var packet = HandoffPacket(
            id: id,
            schemaVersion: rootVersion ?? metaVersion ?? schemaVersion,
            createdAt: meta?.createdAt ?? ISO8601.string(from: Date()),
            updatedAt: meta?.updatedAt ?? ISO8601.string(from: Date()),
            source: source,
            resumeReady: meta?.resumeReady ?? false,
            chatLabel: meta?.chatLabel,
            clientID: meta?.clientID,
            goal: task?.goal ?? "",
            status: task?.status ?? "in_progress",
            projectSlug: task?.projectSlug,
            cwd: task?.cwd,
            blockers: task?.blockers ?? [],
            nextActions: task?.nextActions ?? [],
            keyFiles: working?.keyFiles ?? [],
            decisions: working?.decisions ?? [],
            agents: agentList,
            narrative: wire.narrative ?? "",
            resumeSeed: resumeSeed,
            resumeSeedIsCustom: customMarker ?? false
        )
        if customMarker == nil {
            let generatedPrefix = "Forge Continuity resume (handoff \(id))."
            packet.resumeSeedIsCustom = !resumeSeed.isEmpty && !resumeSeed.hasPrefix(generatedPrefix)
        }
        if let runtime = wire.runtimeJobContinuation {
            guard let validated = try? runtime.validated() else { return nil }
            packet.runtimeJobContinuation = validated
        }
        return packet
    }

    private static func isSafeID(_ id: String) -> Bool {
        guard !id.isEmpty, id.utf8.count <= 128, id != ".", id != ".." else { return false }
        return id.utf8.allSatisfy { byte in
            (byte >= 0x61 && byte <= 0x7a)
                || (byte >= 0x41 && byte <= 0x5a)
                || (byte >= 0x30 && byte <= 0x39)
                || byte == 0x2d || byte == 0x5f || byte == 0x2e
        }
    }
}

private struct HandoffPacketWire: Decodable {
    struct Meta: Decodable {
        let id: String?
        let schemaVersion: Int?
        let createdAt: String?
        let updatedAt: String?
        let source: String?
        let resumeReady: Bool?
        let chatLabel: String?
        let clientID: String?

        enum CodingKeys: String, CodingKey {
            case id, source
            case schemaVersion = "schema_version"
            case createdAt = "created_at"
            case updatedAt = "updated_at"
            case resumeReady = "resume_ready"
            case chatLabel = "chat_label"
            case clientID = "client_id"
        }
    }

    struct Task: Decodable {
        let goal: String?
        let status: String?
        let projectSlug: String?
        let cwd: String?
        let blockers: [String]?
        let nextActions: [String]?

        enum CodingKeys: String, CodingKey {
            case goal, status, cwd, blockers
            case projectSlug = "project_slug"
            case nextActions = "next_actions"
        }
    }

    struct WorkingSet: Decodable {
        let keyFiles: [String]?
        let decisions: [String]?

        enum CodingKeys: String, CodingKey {
            case keyFiles = "key_files"
            case decisions
        }
    }

    struct Resume: Decodable {
        let seed: String?
        let custom: Bool?
        let instructions: [String]?
    }

    struct Agent: Decodable {
        let sessionID: String
        let agentID: String
        let goal: String?
        let cwd: String?
        let status: String?
        let updatedAt: String?
        let resumeHint: String?

        enum CodingKeys: String, CodingKey {
            case goal, cwd, status
            case sessionID = "session_id"
            case agentID = "agent_id"
            case updatedAt = "updated_at"
            case resumeHint = "resume_hint"
        }
    }

    let id: String?
    let schemaVersion: Int?
    let meta: Meta?
    let task: Task?
    let workingSet: WorkingSet?
    let agents: [Agent]?
    let narrative: String?
    let resume: Resume?
    let runtimeJobContinuation: RuntimeJobContinuationSnapshot?

    enum CodingKeys: String, CodingKey {
        case id, meta, task, agents, narrative, resume
        case schemaVersion = "schema_version"
        case workingSet = "working_set"
        case runtimeJobContinuation = "runtime_continuation"
    }
}
