// StjornarvaldPolicyNoticeRepository.swift
// What: Persists bounded coding-agent notices, retry-stable context, and delivery receipts.
// How: A shared schema-versioned SQLite store scopes notices to managed runs or MCP clients.
// Why: Policy reporting must survive restart and remain additive when delivery is unavailable.

import Foundation
import SQLite3

public enum StjornarvaldPolicyNoticeError: Error, LocalizedError, Equatable {
    case unavailable(String)
    case invalid(String)
    case conflict(String)
    case sqlite(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let value): "Policy notice store unavailable: \(value)"
        case .invalid(let value): "Invalid policy notice: \(value)"
        case .conflict(let value): "Policy notice conflict: \(value)"
        case .sqlite(let value): "Policy notice SQLite error: \(value)"
        }
    }
}

public final class StjornarvaldPolicyNoticeRepository: @unchecked Sendable {
    public static let schemaVersion = 1
    public static let maximumPendingNotices = 64
    public static let maximumNoticeBytes = 8 * 1_024
    public static let maximumDeliverySnapshotBytes = 64 * 1_024
    public static let repeatQuietInterval: TimeInterval = 15 * 60

    private enum SQLiteValue { case text(String), integer(Int64), double(Double) }
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private let lock = NSLock()
    private var database: OpaquePointer?
    public let databaseURL: URL

    public init(databaseURL: URL) throws {
        self.databaseURL = databaseURL.standardizedFileURL
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK,
              let handle else {
            let detail = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let handle { sqlite3_close(handle) }
            throw StjornarvaldPolicyNoticeError.unavailable(detail)
        }
        database = handle
        do {
            try execUnlocked("PRAGMA busy_timeout=3000;")
            try execUnlocked("PRAGMA foreign_keys=ON;")
            try validateSchemaBeforeWriteUnlocked()
            try execUnlocked("PRAGMA journal_mode=WAL;")
            try migrateUnlocked()
            try secureFilesUnlocked()
        } catch {
            sqlite3_close(handle)
            database = nil
            throw error
        }
    }

    public convenience init(paths: AppPaths) throws {
        try self.init(databaseURL: paths.stjornarvaldPolicyLogSQLite)
    }

    deinit { if let database { sqlite3_close(database) } }

    @discardableResult
    public func queue(_ event: PolicyViolationEvent, now: Date = Date()) throws
        -> CodingAgentPolicyNotice? {
        guard event.developmentContinues else {
            throw StjornarvaldPolicyNoticeError.invalid("event requested execution control")
        }
        guard let target = Self.target(for: event.candidate.scope) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        try execUnlocked("BEGIN IMMEDIATE;")
        do {
            if event.type == .corrected {
                try executeUnlocked(
                    "UPDATE stj_policy_notices SET state=?,updated_at=? WHERE violation_id=? " +
                        "AND target_kind=? AND target_identity=? AND state IN (?,?);",
                    [.text(PolicyNoticeDeliveryState.supersededByCorrection.rawValue),
                     .text(ISO8601.string(from: now)), .text(event.violationID.description),
                     .text(target.kind.rawValue), .text(target.identity),
                     .text(PolicyNoticeDeliveryState.pending.rawValue),
                     .text(PolicyNoticeDeliveryState.deliveryDeferred.rawValue)]
                )
                try execUnlocked("COMMIT;")
                return nil
            }
            if event.type == .repeated,
               let latest = try latestCreatedAtUnlocked(
                violationID: event.violationID, target: target
               ), latest.addingTimeInterval(Self.repeatQuietInterval) > now {
                try execUnlocked("COMMIT;")
                return nil
            }
            let noticeID = Self.stableUUID("\(event.id.uuidString)\u{0}\(target.kind.rawValue)\u{0}\(target.identity)")
            if let existing = try noticeUnlocked(id: noticeID) {
                try execUnlocked("COMMIT;")
                return existing
            }
            let notice = CodingAgentPolicyNotice(
                id: noticeID,
                violationID: event.violationID,
                ruleReference: event.candidate.rule.source,
                summary: Self.bounded(Self.redacted(event.candidate.summary), bytes: 1_024),
                suggestedCorrection: Self.bounded(
                    Self.redacted(event.candidate.suggestedCorrection), bytes: 1_024
                ),
                confidence: event.candidate.confidence
            )
            let data = try Self.encode(notice)
            guard data.count <= Self.maximumNoticeBytes else {
                throw StjornarvaldPolicyNoticeError.invalid("encoded notice exceeds byte bound")
            }
            let revision = try noticeCountUnlocked(
                violationID: event.violationID, target: target
            ) + 1
            let timestamp = ISO8601.string(from: now)
            try executeUnlocked(
                "INSERT INTO stj_policy_notices(notice_id,violation_id,event_id,notice_revision," +
                    "target_kind,target_identity,notice_json,notice_sha256,state,attempt_count," +
                    "created_at,updated_at,controls_execution) VALUES(?,?,?,?,?,?,?,?,?,0,?,?,0);",
                [.text(notice.id.uuidString.lowercased()), .text(event.violationID.description),
                 .text(event.id.uuidString.lowercased()), .integer(Int64(revision)),
                 .text(target.kind.rawValue), .text(target.identity),
                 .text(String(decoding: data, as: UTF8.self)), .text(JSONSupport.sha256Hex(data)),
                 .text(PolicyNoticeDeliveryState.pending.rawValue), .text(timestamp), .text(timestamp)]
            )
            try execUnlocked("COMMIT;")
            return notice
        } catch {
            try? execUnlocked("ROLLBACK;")
            throw error
        }
    }

    public func pending(
        targetKind: PolicyNoticeTargetKind,
        targetIdentity: String,
        maximumCount: Int,
        maximumBytes: Int
    ) throws -> [CodingAgentPolicyNotice] {
        lock.lock()
        defer { lock.unlock() }
        return try pendingUnlocked(
            targetKind: targetKind,
            targetIdentity: targetIdentity,
            maximumCount: maximumCount,
            maximumBytes: maximumBytes
        )
    }

    public func reserveManagedContext(
        projectID: String,
        projectGeneration: Int,
        runID: String,
        sessionID: String?,
        deliveryID: String,
        maximumCount: Int,
        maximumBytes: Int,
        now: Date = Date()
    ) throws -> PolicyContextSnapshot {
        let target = Self.managedTarget(
            projectID: projectID, generation: projectGeneration, runID: runID, sessionID: sessionID
        )
        try Self.validateDeliveryID(deliveryID)
        lock.lock()
        defer { lock.unlock() }
        try execUnlocked("BEGIN IMMEDIATE;")
        do {
            if let existing = try deliverySnapshotUnlocked(id: deliveryID) {
                guard existing.targetKind == target.kind, existing.targetIdentity == target.identity else {
                    throw StjornarvaldPolicyNoticeError.conflict("delivery ID names another target")
                }
                try execUnlocked("COMMIT;")
                return existing.snapshot
            }
            let notices = try pendingUnlocked(
                targetKind: target.kind, targetIdentity: target.identity,
                maximumCount: maximumCount, maximumBytes: maximumBytes
            )
            let snapshot = PolicyContextSnapshot(
                policyIdentity: Self.policyIdentity,
                applicableRuleSummaries: notices.map {
                    "\($0.violationID): \($0.summary)"
                },
                pendingNotices: notices,
                limitations: ["Presented means supplied to the provider, not understood or followed."]
            )
            try insertDeliveryUnlocked(
                id: deliveryID, target: target, snapshot: snapshot,
                noticeIDs: notices.map(\.id), now: now
            )
            try execUnlocked("COMMIT;")
            return snapshot
        } catch {
            try? execUnlocked("ROLLBACK;")
            throw error
        }
    }

    public func reserveInteractivePresentation(
        deliveryID: String,
        projectID: String?,
        projectGeneration: Int?,
        clientID: String,
        maximumCount: Int,
        maximumBytes: Int,
        now: Date = Date()
    ) throws -> PolicyNoticePresentation? {
        try Self.validateDeliveryID(deliveryID)
        guard !clientID.isEmpty, clientID.utf8.count <= 1_024 else {
            throw StjornarvaldPolicyNoticeError.invalid("client identity is outside bounds")
        }
        let targetIdentity = Self.mcpTargetIdentity(
            projectID: projectID,
            generation: projectGeneration,
            clientID: clientID
        )
        lock.lock()
        defer { lock.unlock() }
        try execUnlocked("BEGIN IMMEDIATE;")
        do {
            let notices: [CodingAgentPolicyNotice]
            if let existing = try deliverySnapshotUnlocked(id: deliveryID) {
                guard existing.targetKind == .mcpClient,
                      existing.targetIdentity == targetIdentity else {
                    throw StjornarvaldPolicyNoticeError.conflict(
                        "delivery ID names another target"
                    )
                }
                notices = existing.snapshot.pendingNotices
            } else {
                notices = try pendingUnlocked(
                    targetKind: .mcpClient,
                    targetIdentity: targetIdentity,
                    maximumCount: maximumCount,
                    maximumBytes: maximumBytes
                )
                let snapshot = PolicyContextSnapshot(
                    policyIdentity: Self.policyIdentity,
                    applicableRuleSummaries: [],
                    pendingNotices: notices,
                    limitations: [
                        "Presented means serialized to the MCP host, not understood or followed."
                    ]
                )
                try insertDeliveryUnlocked(
                    id: deliveryID,
                    target: (.mcpClient, targetIdentity),
                    snapshot: snapshot,
                    noticeIDs: notices.map(\.id),
                    now: now
                )
            }
            let text = StjornarvaldPolicyNoticeFormatter.interactivePresentation(
                notices: notices,
                maximumBytes: maximumBytes
            ) ?? ""
            let presentation = PolicyNoticePresentation(
                id: deliveryID,
                targetKind: .mcpClient,
                targetIdentity: targetIdentity,
                notices: notices,
                text: text,
                digestSHA256: JSONSupport.sha256Hex(text)
            )
            try execUnlocked("COMMIT;")
            return presentation
        } catch {
            try? execUnlocked("ROLLBACK;")
            throw error
        }
    }

    public func markPresented(deliveryID: String, now: Date = Date()) throws {
        try updateDelivery(deliveryID: deliveryID, state: .presented, now: now)
    }

    public func markPresented(deliveryIDs: [String], now: Date = Date()) throws {
        guard !deliveryIDs.isEmpty,
              deliveryIDs.count <= 64,
              Set(deliveryIDs).count == deliveryIDs.count else {
            throw StjornarvaldPolicyNoticeError.invalid(
                "presentation receipt count is outside bounds"
            )
        }
        try deliveryIDs.forEach(Self.validateDeliveryID)
        lock.lock()
        defer { lock.unlock() }
        try execUnlocked("BEGIN IMMEDIATE;")
        do {
            for deliveryID in deliveryIDs {
                guard try deliverySnapshotUnlocked(id: deliveryID) != nil else {
                    throw StjornarvaldPolicyNoticeError.invalid("unknown delivery ID")
                }
            }
            for deliveryID in deliveryIDs {
                try updateDeliveryUnlocked(
                    deliveryID: deliveryID,
                    state: .presented,
                    now: now
                )
            }
            try execUnlocked("COMMIT;")
        } catch {
            try? execUnlocked("ROLLBACK;")
            throw error
        }
    }

    public func markDeferred(deliveryID: String, now: Date = Date()) throws {
        try updateDelivery(deliveryID: deliveryID, state: .deliveryDeferred, now: now)
    }

    public func recordInteractivePresentation(
        _ presentation: PolicyNoticePresentation,
        now: Date = Date()
    ) throws {
        try Self.validateDeliveryID(presentation.id)
        guard presentation.targetKind == .mcpClient,
              presentation.digestSHA256 == JSONSupport.sha256Hex(presentation.text) else {
            throw StjornarvaldPolicyNoticeError.invalid("interactive presentation identity is malformed")
        }
        lock.lock()
        defer { lock.unlock() }
        try execUnlocked("BEGIN IMMEDIATE;")
        do {
            if let existing = try deliverySnapshotUnlocked(id: presentation.id) {
                guard existing.targetKind == presentation.targetKind,
                      existing.targetIdentity == presentation.targetIdentity,
                      existing.noticeIDs == presentation.notices.map(\.id) else {
                    throw StjornarvaldPolicyNoticeError.conflict("delivery ID content changed")
                }
            } else {
                let snapshot = PolicyContextSnapshot(
                    policyIdentity: Self.policyIdentity,
                    applicableRuleSummaries: [], pendingNotices: presentation.notices,
                    limitations: ["Presented means serialized to the MCP host, not understood or followed."]
                )
                try insertDeliveryUnlocked(
                    id: presentation.id,
                    target: (presentation.targetKind, presentation.targetIdentity),
                    snapshot: snapshot,
                    noticeIDs: presentation.notices.map(\.id),
                    now: now
                )
            }
            try updateDeliveryUnlocked(deliveryID: presentation.id, state: .presented, now: now)
            try execUnlocked("COMMIT;")
        } catch {
            try? execUnlocked("ROLLBACK;")
            throw error
        }
    }

    public func deliveryState(_ deliveryID: String) throws -> PolicyNoticeDeliveryState? {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepareUnlocked(
            "SELECT state FROM stj_policy_notice_deliveries WHERE delivery_id=? LIMIT 1;"
        )
        defer { sqlite3_finalize(statement) }
        try bind([.text(deliveryID)], to: statement)
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW,
              let state = PolicyNoticeDeliveryState(rawValue: text(statement, 0)) else {
            throw StjornarvaldPolicyNoticeError.sqlite("malformed delivery state")
        }
        return state
    }

    public static func mcpTargetIdentity(
        projectID: String?, generation: Int?, clientID: String
    ) -> String {
        JSONSupport.sha256Hex(
            [projectID ?? "", generation.map(String.init) ?? "", clientID].joined(separator: "\u{0}")
        )
    }

    public static func managedTargetIdentity(
        projectID: String, generation: Int, runID: String, sessionID: String?
    ) -> String {
        JSONSupport.sha256Hex(
            [projectID, String(generation), runID, sessionID ?? ""].joined(separator: "\u{0}")
        )
    }

    private static let policyIdentity =
        "Raven Forge Development \(RavenForgeDevelopmentPolicyAdapter.identity.version) @ " +
        RavenForgeDevelopmentPolicyAdapter.identity.revision

    private typealias Target = (kind: PolicyNoticeTargetKind, identity: String)
    private struct DeliverySnapshot {
        let targetKind: PolicyNoticeTargetKind
        let targetIdentity: String
        let snapshot: PolicyContextSnapshot
        let noticeIDs: [UUID]
    }

    private static func target(for scope: DevelopmentObservationScope) -> Target? {
        if let projectID = scope.projectID, let generation = scope.projectGeneration,
           let runID = scope.runID {
            return managedTarget(
                projectID: projectID, generation: generation,
                runID: runID, sessionID: scope.sessionID
            )
        }
        if let clientID = scope.clientID {
            return (.mcpClient, mcpTargetIdentity(
                projectID: scope.projectID, generation: scope.projectGeneration, clientID: clientID
            ))
        }
        if let projectID = scope.projectID, let generation = scope.projectGeneration {
            return (.project, JSONSupport.sha256Hex(
                [projectID, String(generation)].joined(separator: "\u{0}")
            ))
        }
        return nil
    }

    private static func managedTarget(
        projectID: String, generation: Int, runID: String, sessionID: String?
    ) -> Target {
        (.managedProvider, managedTargetIdentity(
            projectID: projectID, generation: generation, runID: runID, sessionID: sessionID
        ))
    }

    private func updateDelivery(
        deliveryID: String,
        state: PolicyNoticeDeliveryState,
        now: Date
    ) throws {
        try Self.validateDeliveryID(deliveryID)
        lock.lock()
        defer { lock.unlock() }
        try execUnlocked("BEGIN IMMEDIATE;")
        do {
            try updateDeliveryUnlocked(deliveryID: deliveryID, state: state, now: now)
            try execUnlocked("COMMIT;")
        } catch {
            try? execUnlocked("ROLLBACK;")
            throw error
        }
    }

    private func updateDeliveryUnlocked(
        deliveryID: String,
        state: PolicyNoticeDeliveryState,
        now: Date
    ) throws {
        guard let delivery = try deliverySnapshotUnlocked(id: deliveryID) else { return }
        let timestamp = ISO8601.string(from: now)
        try executeUnlocked(
            "UPDATE stj_policy_notice_deliveries SET state=?,updated_at=? WHERE delivery_id=?;",
            [.text(state.rawValue), .text(timestamp), .text(deliveryID)]
        )
        for noticeID in delivery.noticeIDs {
            try executeUnlocked(
                "UPDATE stj_policy_notices SET state=?,attempt_count=attempt_count+1,updated_at=? " +
                    "WHERE notice_id=? AND state<>?;",
                [.text(state.rawValue), .text(timestamp),
                 .text(noticeID.uuidString.lowercased()),
                 .text(PolicyNoticeDeliveryState.supersededByCorrection.rawValue)]
            )
        }
    }

    private func pendingUnlocked(
        targetKind: PolicyNoticeTargetKind,
        targetIdentity: String,
        maximumCount: Int,
        maximumBytes: Int
    ) throws -> [CodingAgentPolicyNotice] {
        let countLimit = min(max(maximumCount, 1), Self.maximumPendingNotices)
        let byteLimit = min(max(maximumBytes, 512), StjornarvaldPolicyNoticeFormatter.maximumPresentationBytes)
        let statement = try prepareUnlocked(
            "SELECT notice_json FROM stj_policy_notices WHERE target_kind=? AND target_identity=? " +
                "AND state IN (?,?) ORDER BY created_at,notice_id LIMIT ?;"
        )
        defer { sqlite3_finalize(statement) }
        try bind([
            .text(targetKind.rawValue), .text(targetIdentity),
            .text(PolicyNoticeDeliveryState.pending.rawValue),
            .text(PolicyNoticeDeliveryState.deliveryDeferred.rawValue),
            .integer(Int64(countLimit)),
        ], to: statement)
        var result: [CodingAgentPolicyNotice] = []
        var bytes = 0
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW,
                  let data = text(statement, 0).data(using: .utf8),
                  data.count <= Self.maximumNoticeBytes,
                  let notice = try? Self.decoder().decode(CodingAgentPolicyNotice.self, from: data) else {
                throw StjornarvaldPolicyNoticeError.sqlite("malformed durable notice")
            }
            if bytes + data.count > byteLimit { break }
            result.append(notice)
            bytes += data.count
        }
        return result
    }

    private func insertDeliveryUnlocked(
        id: String,
        target: Target,
        snapshot: PolicyContextSnapshot,
        noticeIDs: [UUID],
        now: Date
    ) throws {
        let snapshotData = try Self.encode(snapshot)
        let noticeIDsData = try Self.encode(noticeIDs.map { $0.uuidString.lowercased() })
        guard snapshotData.count <= Self.maximumDeliverySnapshotBytes,
              noticeIDsData.count <= Self.maximumNoticeBytes else {
            throw StjornarvaldPolicyNoticeError.invalid("delivery snapshot exceeds bounds")
        }
        let timestamp = ISO8601.string(from: now)
        try executeUnlocked(
            "INSERT INTO stj_policy_notice_deliveries(delivery_id,target_kind,target_identity," +
                "snapshot_json,notice_ids_json,snapshot_sha256,state,created_at,updated_at," +
                "controls_execution) VALUES(?,?,?,?,?,?,?,?,?,0);",
            [.text(id), .text(target.kind.rawValue), .text(target.identity),
             .text(String(decoding: snapshotData, as: UTF8.self)),
             .text(String(decoding: noticeIDsData, as: UTF8.self)),
             .text(JSONSupport.sha256Hex(snapshotData)),
             .text(PolicyNoticeDeliveryState.pending.rawValue), .text(timestamp), .text(timestamp)]
        )
    }

    private func deliverySnapshotUnlocked(id: String) throws -> DeliverySnapshot? {
        let statement = try prepareUnlocked(
            "SELECT target_kind,target_identity,snapshot_json,notice_ids_json,snapshot_sha256 " +
                "FROM stj_policy_notice_deliveries WHERE delivery_id=? LIMIT 1;"
        )
        defer { sqlite3_finalize(statement) }
        try bind([.text(id)], to: statement)
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW,
              let kind = PolicyNoticeTargetKind(rawValue: text(statement, 0)),
              let snapshotData = text(statement, 2).data(using: .utf8),
              JSONSupport.sha256Hex(snapshotData) == text(statement, 4),
              let snapshot = try? Self.decoder().decode(PolicyContextSnapshot.self, from: snapshotData),
              let idsData = text(statement, 3).data(using: .utf8),
              let rawIDs = try? Self.decoder().decode([String].self, from: idsData),
              rawIDs.count <= Self.maximumPendingNotices else {
            throw StjornarvaldPolicyNoticeError.sqlite("malformed delivery snapshot")
        }
        let ids = rawIDs.compactMap(UUID.init(uuidString:))
        guard ids.count == rawIDs.count else {
            throw StjornarvaldPolicyNoticeError.sqlite("malformed delivery notice identity")
        }
        return DeliverySnapshot(
            targetKind: kind, targetIdentity: text(statement, 1), snapshot: snapshot, noticeIDs: ids
        )
    }

    private func noticeUnlocked(id: UUID) throws -> CodingAgentPolicyNotice? {
        let statement = try prepareUnlocked(
            "SELECT notice_json,notice_sha256 FROM stj_policy_notices WHERE notice_id=? LIMIT 1;"
        )
        defer { sqlite3_finalize(statement) }
        try bind([.text(id.uuidString.lowercased())], to: statement)
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW,
              let data = text(statement, 0).data(using: .utf8),
              JSONSupport.sha256Hex(data) == text(statement, 1),
              let notice = try? Self.decoder().decode(CodingAgentPolicyNotice.self, from: data) else {
            throw StjornarvaldPolicyNoticeError.sqlite("malformed durable notice")
        }
        return notice
    }

    private func latestCreatedAtUnlocked(
        violationID: PolicyViolationID,
        target: Target
    ) throws -> Date? {
        let statement = try prepareUnlocked(
            "SELECT created_at FROM stj_policy_notices WHERE violation_id=? AND target_kind=? " +
                "AND target_identity=? ORDER BY created_at DESC LIMIT 1;"
        )
        defer { sqlite3_finalize(statement) }
        try bind([
            .text(violationID.description), .text(target.kind.rawValue), .text(target.identity),
        ], to: statement)
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW, let date = ISO8601.date(from: text(statement, 0)) else {
            throw StjornarvaldPolicyNoticeError.sqlite("malformed notice timestamp")
        }
        return date
    }

    private func noticeCountUnlocked(
        violationID: PolicyViolationID,
        target: Target
    ) throws -> Int {
        let statement = try prepareUnlocked(
            "SELECT COUNT(*) FROM stj_policy_notices WHERE violation_id=? " +
                "AND target_kind=? AND target_identity=?;"
        )
        defer { sqlite3_finalize(statement) }
        try bind([
            .text(violationID.description), .text(target.kind.rawValue), .text(target.identity),
        ], to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw sqliteErrorUnlocked() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func migrateUnlocked() throws {
        try execUnlocked("BEGIN IMMEDIATE;")
        do {
            try execUnlocked(
                """
                CREATE TABLE IF NOT EXISTS stj_schema_meta (
                  schema_version INTEGER NOT NULL, created_at TEXT NOT NULL, migrated_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS stj_policy_notices (
                  notice_id TEXT PRIMARY KEY, violation_id TEXT NOT NULL, event_id TEXT NOT NULL,
                  notice_revision INTEGER NOT NULL, target_kind TEXT NOT NULL,
                  target_identity TEXT NOT NULL, notice_json TEXT NOT NULL,
                  notice_sha256 TEXT NOT NULL, state TEXT NOT NULL, attempt_count INTEGER NOT NULL,
                  created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
                  controls_execution INTEGER NOT NULL CHECK(controls_execution=0),
                  UNIQUE(event_id,target_kind,target_identity)
                );
                CREATE INDEX IF NOT EXISTS stj_policy_notices_pending
                  ON stj_policy_notices(target_kind,target_identity,state,created_at);
                CREATE TABLE IF NOT EXISTS stj_policy_notice_deliveries (
                  delivery_id TEXT PRIMARY KEY, target_kind TEXT NOT NULL,
                  target_identity TEXT NOT NULL, snapshot_json TEXT NOT NULL,
                  notice_ids_json TEXT NOT NULL, snapshot_sha256 TEXT NOT NULL,
                  state TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
                  controls_execution INTEGER NOT NULL CHECK(controls_execution=0)
                );
                """
            )
            let now = ISO8601.string(from: Date())
            try executeUnlocked(
                "INSERT INTO stj_schema_meta(schema_version,created_at,migrated_at) " +
                    "SELECT ?,?,? WHERE NOT EXISTS(SELECT 1 FROM stj_schema_meta);",
                [.integer(Int64(Self.schemaVersion)), .text(now), .text(now)]
            )
            guard try scalarIntUnlocked("SELECT COUNT(*) FROM stj_schema_meta;") == 1,
                  try scalarIntUnlocked("SELECT schema_version FROM stj_schema_meta LIMIT 1;") == Self.schemaVersion else {
                throw StjornarvaldPolicyNoticeError.unavailable("unsupported schema")
            }
            try execUnlocked("COMMIT;")
        } catch {
            try? execUnlocked("ROLLBACK;")
            throw error
        }
    }

    private func validateSchemaBeforeWriteUnlocked() throws {
        let metadata = try scalarIntUnlocked(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='stj_schema_meta';"
        ) == 1
        if metadata {
            guard try scalarIntUnlocked("SELECT COUNT(*) FROM stj_schema_meta;") == 1,
                  try scalarIntUnlocked("SELECT schema_version FROM stj_schema_meta LIMIT 1;") == Self.schemaVersion else {
                throw StjornarvaldPolicyNoticeError.unavailable("unsupported or malformed schema")
            }
            return
        }
        guard try scalarIntUnlocked(
            "SELECT COUNT(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%';"
        ) == 0 else {
            throw StjornarvaldPolicyNoticeError.unavailable("unversioned non-empty database")
        }
    }

    private func secureFilesUnlocked() throws {
        for url in [databaseURL, URL(fileURLWithPath: databaseURL.path + "-wal"),
                    URL(fileURLWithPath: databaseURL.path + "-shm")]
            where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    private static func validateDeliveryID(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 1_024 else {
            throw StjornarvaldPolicyNoticeError.invalid("delivery ID exceeds bounds")
        }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func stableUUID(_ value: String) -> UUID {
        var characters = Array(JSONSupport.sha256Hex(value).prefix(32))
        characters[12] = "5"
        characters[16] = "8"
        let raw = String(characters)
        return UUID(uuidString:
            "\(raw.prefix(8))-\(raw.dropFirst(8).prefix(4))-\(raw.dropFirst(12).prefix(4))-" +
                "\(raw.dropFirst(16).prefix(4))-\(raw.dropFirst(20))"
        )!
    }

    private static func bounded(_ value: String, bytes maximum: Int) -> String {
        StjornarvaldPolicyNoticeFormatter.bounded(value, bytes: maximum)
    }

    private static func redacted(_ value: String) -> String {
        (try? ProjectMemoryRedactor().redact(value)) ?? "<redacted>"
    }

    private func execUnlocked(_ sql: String) throws {
        guard let database else { throw StjornarvaldPolicyNoticeError.unavailable("closed") }
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(message)
            throw StjornarvaldPolicyNoticeError.sqlite(detail)
        }
    }

    private func executeUnlocked(_ sql: String, _ values: [SQLiteValue] = []) throws {
        let statement = try prepareUnlocked(sql)
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteErrorUnlocked() }
    }

    private func scalarIntUnlocked(_ sql: String) throws -> Int {
        let statement = try prepareUnlocked(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw sqliteErrorUnlocked() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func prepareUnlocked(_ sql: String) throws -> OpaquePointer {
        guard let database else { throw StjornarvaldPolicyNoticeError.unavailable("closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw sqliteErrorUnlocked() }
        return statement
    }

    private func bind(_ values: [SQLiteValue], to statement: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let value):
                result = sqlite3_bind_text(statement, index, value, -1, Self.sqliteTransient)
            case .integer(let value): result = sqlite3_bind_int64(statement, index, value)
            case .double(let value): result = sqlite3_bind_double(statement, index, value)
            }
            guard result == SQLITE_OK else { throw sqliteErrorUnlocked() }
        }
    }

    private func sqliteErrorUnlocked() -> StjornarvaldPolicyNoticeError {
        guard let database else { return .unavailable("closed") }
        return .sqlite(String(cString: sqlite3_errmsg(database)))
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }
}

public final class StjornarvaldCodingAgentPolicyReporter: CodingAgentPolicyReporting,
    PolicyContextProviding, @unchecked Sendable {
    private let repository: StjornarvaldPolicyNoticeRepository?
    private let diagnostics: @Sendable (String) -> Void

    public init(
        paths: AppPaths,
        diagnostics: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.diagnostics = diagnostics
        do { repository = try StjornarvaldPolicyNoticeRepository(paths: paths) }
        catch {
            repository = nil
            diagnostics("stjornarvald notice repository unavailable: \(error.localizedDescription)")
        }
    }

    public init(
        repository: StjornarvaldPolicyNoticeRepository,
        diagnostics: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.repository = repository
        self.diagnostics = diagnostics
    }

    public func queue(_ event: PolicyViolationEvent) async {
        do { _ = try repository?.queue(event) }
        catch { diagnostics("stjornarvald notice queue deferred: \(error.localizedDescription)") }
    }

    public func pendingNotices(
        projectID: String?,
        projectGeneration: Int?,
        runID: String?,
        sessionID: String?,
        clientID: String?,
        maximumCount: Int,
        maximumBytes: Int
    ) async -> [CodingAgentPolicyNotice] {
        guard let repository else { return [] }
        do {
            if let projectID, let projectGeneration, let runID {
                let target = StjornarvaldPolicyNoticeRepository.managedTargetIdentity(
                    projectID: projectID, generation: projectGeneration,
                    runID: runID, sessionID: sessionID
                )
                return try repository.pending(
                    targetKind: .managedProvider, targetIdentity: target,
                    maximumCount: maximumCount, maximumBytes: maximumBytes
                )
            }
            if let clientID {
                return try repository.pending(
                    targetKind: .mcpClient,
                    targetIdentity: StjornarvaldPolicyNoticeRepository.mcpTargetIdentity(
                        projectID: projectID, generation: projectGeneration, clientID: clientID
                    ),
                    maximumCount: maximumCount, maximumBytes: maximumBytes
                )
            }
        } catch { diagnostics("stjornarvald notice lookup deferred: \(error.localizedDescription)") }
        return []
    }

    public func interactivePresentation(
        deliveryID: String,
        projectID: String?,
        projectGeneration: Int?,
        clientID: String,
        maximumCount: Int,
        maximumBytes: Int
    ) async -> PolicyNoticePresentation? {
        guard let repository else { return nil }
        do {
            return try repository.reserveInteractivePresentation(
                deliveryID: deliveryID,
                projectID: projectID,
                projectGeneration: projectGeneration,
                clientID: clientID,
                maximumCount: maximumCount,
                maximumBytes: maximumBytes
            )
        } catch {
            diagnostics("stjornarvald interactive presentation deferred: \(error.localizedDescription)")
            return nil
        }
    }

    public func context(
        projectID: String,
        projectGeneration: Int,
        runID: String,
        sessionID: String?,
        deliveryID: String,
        maximumCount: Int,
        maximumBytes: Int
    ) async -> PolicyContextSnapshot {
        guard let repository else { return Self.emptyContext("notice repository unavailable") }
        do {
            return try repository.reserveManagedContext(
                projectID: projectID, projectGeneration: projectGeneration,
                runID: runID, sessionID: sessionID, deliveryID: deliveryID,
                maximumCount: maximumCount, maximumBytes: maximumBytes
            )
        } catch {
            diagnostics("stjornarvald managed context deferred: \(error.localizedDescription)")
            return Self.emptyContext("policy context delivery deferred")
        }
    }

    public func presented(deliveryID: String) async {
        do { try repository?.markPresented(deliveryID: deliveryID) }
        catch { diagnostics("stjornarvald notice presentation receipt deferred: \(error.localizedDescription)") }
    }

    public func confirmPresented(deliveryIDs: [String]) async throws {
        guard let repository else {
            throw StjornarvaldPolicyNoticeError.unavailable("notice repository unavailable")
        }
        try repository.markPresented(deliveryIDs: deliveryIDs)
    }

    public func deferred(deliveryID: String) async {
        do { try repository?.markDeferred(deliveryID: deliveryID) }
        catch { diagnostics("stjornarvald notice deferral receipt unavailable: \(error.localizedDescription)") }
    }

    private static func emptyContext(_ limitation: String) -> PolicyContextSnapshot {
        PolicyContextSnapshot(
            policyIdentity: RavenForgeDevelopmentPolicyAdapter.identity.bindingID,
            applicableRuleSummaries: [], pendingNotices: [], limitations: [limitation]
        )
    }
}

public final class StjornarvaldInteractivePolicyNoticeCache:
    InteractivePolicyNoticeProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "forge.stjornarvald.notice-cache", qos: .utility)
    private let databaseURL: URL
    private let initialProjectID: String?
    private let initialProjectGeneration: Int?
    private let clientID: String
    private let diagnostics: @Sendable (String) -> Void
    private var repository: StjornarvaldPolicyNoticeRepository?
    private var cached: [CodingAgentPolicyNotice] = []
    private var cachedTargetIdentity: String?

    public init(
        paths: AppPaths,
        projectID: String? = nil,
        projectGeneration: Int? = nil,
        clientID: String,
        diagnostics: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        databaseURL = paths.stjornarvaldPolicyLogSQLite
        initialProjectID = projectID
        initialProjectGeneration = projectGeneration
        self.clientID = clientID
        self.diagnostics = diagnostics
        refresh(
            projectID: projectID,
            projectGeneration: projectGeneration,
            clientID: clientID
        )
    }

    public init(
        repository: StjornarvaldPolicyNoticeRepository,
        projectID: String? = nil,
        projectGeneration: Int? = nil,
        clientID: String,
        diagnostics: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        databaseURL = repository.databaseURL
        initialProjectID = projectID
        initialProjectGeneration = projectGeneration
        self.clientID = clientID
        self.diagnostics = diagnostics
        self.repository = repository
        refresh(
            projectID: projectID,
            projectGeneration: projectGeneration,
            clientID: clientID
        )
    }

    public func presentation(
        deliveryID: String,
        projectID: String?,
        projectGeneration: Int?,
        clientID: String,
        maximumCount: Int,
        maximumBytes: Int
    ) -> PolicyNoticePresentation? {
        let targetIdentity = StjornarvaldPolicyNoticeRepository.mcpTargetIdentity(
            projectID: projectID, generation: projectGeneration, clientID: clientID
        )
        lock.lock()
        let targetChanged = cachedTargetIdentity != targetIdentity
        if targetChanged { cached = [] }
        let notices = Array(cached.prefix(min(max(maximumCount, 1), 8)))
        lock.unlock()
        if targetChanged {
            refresh(
                projectID: projectID,
                projectGeneration: projectGeneration,
                clientID: clientID
            )
        }
        guard let text = StjornarvaldPolicyNoticeFormatter.interactivePresentation(
            notices: notices, maximumBytes: maximumBytes
        ) else { return nil }
        return PolicyNoticePresentation(
            id: deliveryID,
            targetKind: .mcpClient,
            targetIdentity: targetIdentity,
            notices: notices,
            text: text,
            digestSHA256: JSONSupport.sha256Hex(text)
        )
    }

    public func didPresent(_ presentation: PolicyNoticePresentation) {
        let delivered = Set(presentation.notices.map(\.id))
        lock.lock()
        cached.removeAll { delivered.contains($0.id) }
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let repository = try self.repositoryOrOpen()
                try repository.recordInteractivePresentation(presentation)
                self.refreshNow(
                    repository: repository,
                    targetIdentity: presentation.targetIdentity
                )
            } catch {
                self.diagnostics("stjornarvald MCP presentation receipt deferred: \(error.localizedDescription)")
            }
        }
    }

    public func refresh() {
        refresh(
            projectID: initialProjectID,
            projectGeneration: initialProjectGeneration,
            clientID: clientID
        )
    }

    private func refresh(
        projectID: String?,
        projectGeneration: Int?,
        clientID: String
    ) {
        let targetIdentity = StjornarvaldPolicyNoticeRepository.mcpTargetIdentity(
            projectID: projectID,
            generation: projectGeneration,
            clientID: clientID
        )
        queue.async { [weak self] in
            guard let self else { return }
            do {
                self.refreshNow(
                    repository: try self.repositoryOrOpen(),
                    targetIdentity: targetIdentity
                )
            }
            catch {
                self.diagnostics("stjornarvald MCP notice cache refresh deferred: \(error.localizedDescription)")
            }
        }
    }

    private func repositoryOrOpen() throws -> StjornarvaldPolicyNoticeRepository {
        lock.lock()
        if let repository {
            lock.unlock()
            return repository
        }
        lock.unlock()
        let opened = try StjornarvaldPolicyNoticeRepository(databaseURL: databaseURL)
        lock.lock()
        if repository == nil { repository = opened }
        let selected = repository!
        lock.unlock()
        return selected
    }

    private func refreshNow(
        repository: StjornarvaldPolicyNoticeRepository,
        targetIdentity: String
    ) {
        do {
            let notices = try repository.pending(
                targetKind: .mcpClient,
                targetIdentity: targetIdentity,
                maximumCount: 8,
                maximumBytes: StjornarvaldPolicyNoticeFormatter.maximumPresentationBytes
            )
            lock.lock()
            cached = notices
            cachedTargetIdentity = targetIdentity
            lock.unlock()
        } catch {
            diagnostics("stjornarvald MCP notice cache read deferred: \(error.localizedDescription)")
        }
    }
}
