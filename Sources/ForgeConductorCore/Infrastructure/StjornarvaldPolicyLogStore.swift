// StjornarvaldPolicyLogStore.swift
// What: Persists immutable Development Policy violation history and its JSONL mirror.
// How: SQLite is authoritative; a digest-chained mirror is repaired from SQLite after faults.
// Why: Policy evidence must survive interruption without ever controlling Forge development.

import Foundation
import Darwin
import SQLite3

public enum StjornarvaldPolicyLogError: Error, LocalizedError, Equatable {
    case openFailed(String)
    case sqlite(String)
    case conflict(String)
    case invalidRecord(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let detail): "Stjornarvald log open failed: \(detail)"
        case .sqlite(let detail): "Stjornarvald SQLite error: \(detail)"
        case .conflict(let detail): "Stjornarvald log conflict: \(detail)"
        case .invalidRecord(let detail): "Invalid Stjornarvald record: \(detail)"
        }
    }
}

/// Serialized SQLite authority for policy violations. The events table rejects
/// UPDATE and DELETE at the database boundary; the projection table is mutable.
public final class StjornarvaldPolicyLogStore: @unchecked Sendable {
    private struct ExistingEvent {
        let projection: PolicyViolation
        let type: PolicyViolationEventType
        let candidate: PolicyViolationCandidate
    }

    public static let schemaVersion = 1
    private static let maximumRepairEvents = 100_000
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private let lock = NSLock()
    private var database: OpaquePointer?
    public let databaseURL: URL
    public let jsonlURL: URL

    public init(databaseURL: URL, jsonlURL: URL) throws {
        self.databaseURL = databaseURL.standardizedFileURL
        self.jsonlURL = jsonlURL.standardizedFileURL
        let manager = FileManager.default
        do {
            try manager.createDirectory(
                at: databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try manager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: databaseURL.deletingLastPathComponent().path
            )
        } catch {
            throw StjornarvaldPolicyLogError.openFailed(error.localizedDescription)
        }

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK,
              let handle else {
            let detail = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let handle { sqlite3_close(handle) }
            throw StjornarvaldPolicyLogError.openFailed(detail)
        }
        database = handle
        do {
            try execUnlocked("PRAGMA busy_timeout=3000;")
            try execUnlocked("PRAGMA foreign_keys=ON;")
            try validateSchemaBeforeWriteUnlocked()
            try execUnlocked("PRAGMA journal_mode=WAL;")
            try migrateUnlocked()
            try secureDatabaseFilesUnlocked()
            do {
                try repairJSONLMirrorUnlocked()
            } catch {
                try? setMirrorStateUnlocked(
                    sequence: mirroredSequenceUnlocked(),
                    digest: nil,
                    pending: true
                )
            }
        } catch {
            sqlite3_close(handle)
            database = nil
            throw error
        }
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    public func record(
        _ candidate: PolicyViolationCandidate,
        eventID: UUID = UUID(),
        occurredAt: Date = Date()
    ) throws -> PolicyViolation {
        lock.lock()
        defer { lock.unlock() }
        try Self.validateCandidate(candidate)
        let fingerprint = try Self.fingerprint(for: candidate)
        if let existing = try existingEventUnlocked(eventID: eventID) {
            guard existing.projection.fingerprint == fingerprint,
                  existing.candidate == candidate else {
                throw StjornarvaldPolicyLogError.conflict(
                    "event ID \(eventID.uuidString.lowercased()) has different content"
                )
            }
            return existing.projection
        }
        let current = try violationUnlocked(fingerprint: fingerprint)
        let type: PolicyViolationEventType
        if current?.state == .corrected {
            type = .reopened
        } else if current == nil {
            type = .opened
        } else {
            type = .repeated
        }
        return try appendUnlocked(
            candidate: candidate,
            violationID: current?.id ?? Self.violationID(for: fingerprint),
            fingerprint: fingerprint,
            type: type,
            eventID: eventID,
            occurredAt: occurredAt
        )
    }

    public func recordCorrection(
        violationID: PolicyViolationID,
        candidate: PolicyViolationCandidate,
        eventID: UUID = UUID(),
        occurredAt: Date = Date()
    ) throws -> PolicyViolation {
        try recordTransition(
            violationID: violationID,
            candidate: candidate,
            type: .corrected,
            eventID: eventID,
            occurredAt: occurredAt
        )
    }

    public func recordDispute(
        violationID: PolicyViolationID,
        candidate: PolicyViolationCandidate,
        eventID: UUID = UUID(),
        occurredAt: Date = Date()
    ) throws -> PolicyViolation {
        try recordTransition(
            violationID: violationID,
            candidate: candidate,
            type: .disputed,
            eventID: eventID,
            occurredAt: occurredAt
        )
    }

    public func events(after sequence: Int64 = 0, limit: Int = 100) throws -> [PolicyViolationEvent] {
        lock.lock()
        defer { lock.unlock() }
        return try eventsUnlocked(after: max(sequence, 0), limit: min(max(limit, 1), 1_000))
    }

    /// Returns the newest bounded event window in newest-first order. Cursor-based
    /// readers retain their existing chronological contract through `events(after:limit:)`.
    public func newestEvents(
        limit: Int = 100,
        projectID: String? = nil,
        projectGeneration: UInt64? = nil
    ) throws -> [PolicyViolationEvent] {
        lock.lock()
        defer { lock.unlock() }
        guard (projectID == nil) == (projectGeneration == nil),
              projectGeneration.map({ $0 <= UInt64(Int64.max) }) ?? true else {
            throw StjornarvaldPolicyLogError.invalidRecord(
                "newest event project filter requires a bounded project identity"
            )
        }
        return try newestEventsUnlocked(
            limit: min(max(limit, 1), 1_000),
            projectID: projectID,
            projectGeneration: projectGeneration
        )
    }

    public func event(id: UUID) throws -> PolicyViolationEvent? {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepareUnlocked(
            "SELECT sequence FROM stj_violation_events WHERE event_id=? LIMIT 1;"
        )
        defer { sqlite3_finalize(statement) }
        try bind([.text(id.uuidString.lowercased())], to: statement)
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW else { throw sqliteErrorUnlocked() }
        let sequence = sqlite3_column_int64(statement, 0)
        return try eventsUnlocked(after: sequence - 1, limit: 1).first
    }

    public func latestEventSequence() throws -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return Int64(try scalarIntUnlocked(
            "SELECT COALESCE(MAX(sequence),0) FROM stj_violation_events;"
        ))
    }

    public func violation(id: PolicyViolationID) throws -> PolicyViolation? {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepareUnlocked("""
        SELECT violation_id,fingerprint,rule_id,policy_revision,state,first_observed_at,
          last_observed_at,occurrence_count,latest_summary,latest_suggested_correction
        FROM stj_violations WHERE violation_id=? LIMIT 1;
        """)
        defer { sqlite3_finalize(statement) }
        try bind([.text(id.description)], to: statement)
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW else { throw sqliteErrorUnlocked() }
        return try projectionUnlocked(from: statement)
    }

    /// Returns stable, cursor-ordered violation projections without exposing
    /// source bodies or loading the complete history into memory.
    public func violations(
        afterEventSequence: Int64 = 0,
        projectID: String? = nil,
        state: PolicyViolationProjectionState? = nil,
        limit: Int = 100
    ) throws -> [(violation: PolicyViolation, latestEventSequence: Int64)] {
        lock.lock()
        defer { lock.unlock() }
        guard afterEventSequence >= 0,
              (1...1_000).contains(limit),
              projectID.map({ !$0.isEmpty && $0.utf8.count <= 1_024 }) ?? true else {
            throw StjornarvaldPolicyLogError.invalidRecord(
                "violation page cursor, filters, or limit are outside bounds"
            )
        }
        var predicates = ["latest_event_sequence>?"]
        var bindings: [SQLiteValue] = [.integer(afterEventSequence)]
        if let projectID {
            predicates.append("project_id=?")
            bindings.append(.text(projectID))
        }
        if let state {
            predicates.append("state=?")
            bindings.append(.text(state.rawValue))
        }
        bindings.append(.integer(Int64(limit)))
        let statement = try prepareUnlocked("""
        SELECT violation_id,fingerprint,rule_id,policy_revision,state,first_observed_at,
          last_observed_at,occurrence_count,latest_summary,latest_suggested_correction,
          latest_event_sequence
        FROM stj_violations WHERE \(predicates.joined(separator: " AND "))
        ORDER BY latest_event_sequence ASC LIMIT ?;
        """)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        var result: [(violation: PolicyViolation, latestEventSequence: Int64)] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw sqliteErrorUnlocked() }
            result.append((
                violation: try projectionUnlocked(from: statement),
                latestEventSequence: sqlite3_column_int64(statement, 10)
            ))
        }
        return result
    }

    public func violation(matching candidate: PolicyViolationCandidate) throws -> PolicyViolation? {
        lock.lock()
        defer { lock.unlock() }
        try Self.validateCandidate(candidate)
        return try violationUnlocked(fingerprint: Self.fingerprint(for: candidate))
    }

    /// Reconciles the complete bounded mirror with SQLite authority. Rebuilding
    /// atomically also handles a crash between append and cursor persistence.
    public func repairJSONLMirror() throws {
        lock.lock()
        defer { lock.unlock() }
        try repairJSONLMirrorUnlocked()
    }

    private func recordTransition(
        violationID: PolicyViolationID,
        candidate: PolicyViolationCandidate,
        type: PolicyViolationEventType,
        eventID: UUID,
        occurredAt: Date
    ) throws -> PolicyViolation {
        lock.lock()
        defer { lock.unlock() }
        try Self.validateCandidate(candidate)
        let candidateFingerprint = try Self.fingerprint(for: candidate)
        if let existing = try existingEventUnlocked(eventID: eventID) {
            guard existing.projection.fingerprint == candidateFingerprint,
                  existing.type == type,
                  existing.candidate == candidate else {
                throw StjornarvaldPolicyLogError.conflict(
                    "event ID \(eventID.uuidString.lowercased()) has different content"
                )
            }
            return existing.projection
        }
        guard let current = try violationUnlocked(id: violationID) else {
            throw StjornarvaldPolicyLogError.invalidRecord("unknown violation ID \(violationID)")
        }
        guard candidateFingerprint == current.fingerprint else {
            throw StjornarvaldPolicyLogError.conflict("transition changed violation identity")
        }
        return try appendUnlocked(
            candidate: candidate,
            violationID: violationID,
            fingerprint: current.fingerprint,
            type: type,
            eventID: eventID,
            occurredAt: occurredAt
        )
    }

    private func appendUnlocked(
        candidate: PolicyViolationCandidate,
        violationID: PolicyViolationID,
        fingerprint: String,
        type: PolicyViolationEventType,
        eventID: UUID,
        occurredAt: Date
    ) throws -> PolicyViolation {
        guard candidate.rule.controlsExecution == false else {
            throw StjornarvaldPolicyLogError.invalidRecord("policy rule requested execution control")
        }
        let prior = try lastEventDigestUnlocked()
        let sequence = try nextSequenceUnlocked()
        let event = try Self.makeEvent(
            sequence: sequence,
            eventID: eventID,
            type: type,
            occurredAt: occurredAt,
            violationID: violationID,
            fingerprint: fingerprint,
            candidate: candidate,
            priorEventSHA256: prior
        )
        let priorProjection = try violationUnlocked(id: violationID)
        let projection = Self.project(event: event, prior: priorProjection)

        try execUnlocked("BEGIN IMMEDIATE;")
        do {
            if priorProjection == nil {
                try insertProjectionUnlocked(projection, event: event)
            } else {
                try updateProjectionUnlocked(projection, event: event)
            }
            try insertEventUnlocked(event)
            try secureDatabaseFilesUnlocked()
            try execUnlocked("COMMIT;")
        } catch {
            try? execUnlocked("ROLLBACK;")
            throw error
        }

        do {
            try appendMirrorUnlocked(event)
            try setMirrorStateUnlocked(sequence: event.sequence, digest: event.eventSHA256, pending: false)
        } catch {
            try? setMirrorStateUnlocked(sequence: try mirroredSequenceUnlocked(), digest: nil, pending: true)
        }
        return projection
    }

    private func migrateUnlocked() throws {
        try execUnlocked("BEGIN IMMEDIATE;")
        do {
            try execUnlocked(
                """
                CREATE TABLE IF NOT EXISTS stj_schema_meta (
                  schema_version INTEGER NOT NULL,
                  created_at TEXT NOT NULL,
                  migrated_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS stj_violations (
                  violation_id TEXT PRIMARY KEY,
                  fingerprint TEXT NOT NULL UNIQUE,
                  rule_id TEXT NOT NULL,
                  policy_revision TEXT NOT NULL,
                  project_id TEXT,
                  project_generation INTEGER,
                  subject_identity TEXT NOT NULL,
                  state TEXT NOT NULL,
                  first_observed_at TEXT NOT NULL,
                  last_observed_at TEXT NOT NULL,
                  occurrence_count INTEGER NOT NULL CHECK(occurrence_count >= 1),
                  latest_event_sequence INTEGER NOT NULL,
                  latest_summary TEXT NOT NULL,
                  latest_confidence REAL NOT NULL CHECK(latest_confidence >= 0 AND latest_confidence <= 1),
                  latest_suggested_correction TEXT NOT NULL,
                  latest_notice_state TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS stj_violations_project_state
                  ON stj_violations(project_id, state, last_observed_at);
                CREATE TABLE IF NOT EXISTS stj_violation_events (
                  sequence INTEGER PRIMARY KEY,
                  event_id TEXT NOT NULL UNIQUE,
                  violation_id TEXT NOT NULL REFERENCES stj_violations(violation_id),
                  event_type TEXT NOT NULL,
                  occurred_at TEXT NOT NULL,
                  rule_id TEXT NOT NULL,
                  policy_revision TEXT NOT NULL,
                  source_path TEXT NOT NULL,
                  source_locator TEXT NOT NULL,
                  project_id TEXT,
                  project_generation INTEGER,
                  scope_json TEXT NOT NULL,
                  observation_json TEXT NOT NULL,
                  interpretation_json TEXT NOT NULL,
                  suggested_correction TEXT NOT NULL,
                  notice_state TEXT NOT NULL,
                  prior_event_sha256 TEXT,
                  event_sha256 TEXT NOT NULL UNIQUE,
                  development_continues INTEGER NOT NULL DEFAULT 1 CHECK(development_continues = 1)
                );
                CREATE INDEX IF NOT EXISTS stj_violation_events_violation
                  ON stj_violation_events(violation_id, sequence);
                CREATE TRIGGER IF NOT EXISTS stj_violation_events_no_update
                  BEFORE UPDATE ON stj_violation_events
                  BEGIN SELECT RAISE(ABORT, 'policy violation events are append-only'); END;
                CREATE TRIGGER IF NOT EXISTS stj_violation_events_no_delete
                  BEFORE DELETE ON stj_violation_events
                  BEGIN SELECT RAISE(ABORT, 'policy violation events are append-only'); END;
                CREATE TABLE IF NOT EXISTS stj_jsonl_mirror_state (
                  singleton_id INTEGER PRIMARY KEY CHECK(singleton_id = 1),
                  mirrored_sequence INTEGER NOT NULL DEFAULT 0,
                  last_event_sha256 TEXT,
                  repair_pending INTEGER NOT NULL DEFAULT 0 CHECK(repair_pending IN (0,1)),
                  updated_at TEXT NOT NULL
                );
                """
            )
            let hasEventProjectColumns = try scalarIntUnlocked(
                "SELECT COUNT(*) FROM pragma_table_info('stj_violation_events') "
                    + "WHERE name IN ('project_id','project_generation');"
            ) == 2
            if !hasEventProjectColumns {
                try execUnlocked("ALTER TABLE stj_violation_events ADD COLUMN project_id TEXT;")
                try execUnlocked(
                    "ALTER TABLE stj_violation_events ADD COLUMN project_generation INTEGER;"
                )
            }
            // Schema version 1 remains readable by older compatible binaries. Such
            // a writer can insert a scoped event without the additive columns. Only
            // repair rows whose canonical JSON contains a complete project scope;
            // truly global events remain NULL without being rewritten on every open.
            let scopeRepairCount = try scalarIntUnlocked("""
            SELECT COUNT(*) FROM stj_violation_events
            WHERE json_type(scope_json,'$.projectID')='text'
              AND json_type(scope_json,'$.projectGeneration')='integer'
              AND (
                project_id IS NULL OR project_generation IS NULL
                OR project_id<>json_extract(scope_json,'$.projectID')
                OR project_generation<>json_extract(scope_json,'$.projectGeneration')
              );
            """)
            if scopeRepairCount > 0 {
                try execUnlocked("DROP TRIGGER IF EXISTS stj_violation_events_no_update;")
                try execUnlocked("DROP TRIGGER IF EXISTS stj_violation_events_no_delete;")
                try execUnlocked("""
                UPDATE stj_violation_events
                SET project_id=json_extract(scope_json,'$.projectID'),
                    project_generation=json_extract(scope_json,'$.projectGeneration')
                WHERE json_type(scope_json,'$.projectID')='text'
                  AND json_type(scope_json,'$.projectGeneration')='integer'
                  AND (
                    project_id IS NULL OR project_generation IS NULL
                    OR project_id<>json_extract(scope_json,'$.projectID')
                    OR project_generation<>json_extract(scope_json,'$.projectGeneration')
                  );
                """)
                try execUnlocked("""
                CREATE TRIGGER stj_violation_events_no_update
                  BEFORE UPDATE ON stj_violation_events
                  BEGIN SELECT RAISE(ABORT, 'policy violation events are append-only'); END;
                CREATE TRIGGER stj_violation_events_no_delete
                  BEFORE DELETE ON stj_violation_events
                  BEGIN SELECT RAISE(ABORT, 'policy violation events are append-only'); END;
                """)
            }
            try execUnlocked("""
            CREATE INDEX IF NOT EXISTS stj_violation_events_project_sequence
              ON stj_violation_events(project_id, project_generation, sequence DESC);
            """)
            let now = ISO8601.string(from: Date())
            try executeUnlocked(
                "INSERT INTO stj_schema_meta(schema_version,created_at,migrated_at) " +
                "SELECT ?,?,? WHERE NOT EXISTS(SELECT 1 FROM stj_schema_meta);",
                [.integer(Int64(Self.schemaVersion)), .text(now), .text(now)]
            )
            guard try scalarIntUnlocked("SELECT COUNT(*) FROM stj_schema_meta;") == 1 else {
                throw StjornarvaldPolicyLogError.openFailed("unsupported schema")
            }
            let priorVersion = try scalarIntUnlocked(
                "SELECT schema_version FROM stj_schema_meta LIMIT 1;"
            )
            guard (1...Self.schemaVersion).contains(priorVersion) else {
                throw StjornarvaldPolicyLogError.openFailed("unsupported schema")
            }
            try executeUnlocked(
                "UPDATE stj_schema_meta SET schema_version=?,migrated_at=?;",
                [.integer(Int64(Self.schemaVersion)), .text(now)]
            )
            try executeUnlocked(
                "INSERT OR IGNORE INTO stj_jsonl_mirror_state" +
                "(singleton_id,mirrored_sequence,last_event_sha256,repair_pending,updated_at) VALUES(1,0,NULL,0,?);",
                [.text(now)]
            )
            try execUnlocked("COMMIT;")
        } catch {
            try? execUnlocked("ROLLBACK;")
            throw error
        }
    }

    private func validateSchemaBeforeWriteUnlocked() throws {
        let hasMetadata = try scalarIntUnlocked(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='stj_schema_meta';"
        ) == 1
        if hasMetadata {
            guard try scalarIntUnlocked("SELECT COUNT(*) FROM stj_schema_meta;") == 1 else {
                throw StjornarvaldPolicyLogError.openFailed("unsupported or malformed schema")
            }
            let version = try scalarIntUnlocked(
                "SELECT schema_version FROM stj_schema_meta LIMIT 1;"
            )
            guard (1...Self.schemaVersion).contains(version) else {
                throw StjornarvaldPolicyLogError.openFailed("unsupported or malformed schema")
            }
            return
        }
        let objectCount = try scalarIntUnlocked(
            "SELECT COUNT(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%';"
        )
        guard objectCount == 0 else {
            throw StjornarvaldPolicyLogError.openFailed("unversioned non-empty database")
        }
    }

    private func secureDatabaseFilesUnlocked() throws {
        let manager = FileManager.default
        for url in [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm"),
        ] where manager.fileExists(atPath: url.path) {
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    private func insertProjectionUnlocked(
        _ value: PolicyViolation,
        event: PolicyViolationEvent
    ) throws {
        try executeUnlocked("""
        INSERT INTO stj_violations(
          violation_id,fingerprint,rule_id,policy_revision,project_id,project_generation,
          subject_identity,state,first_observed_at,last_observed_at,occurrence_count,
          latest_event_sequence,latest_summary,latest_confidence,
          latest_suggested_correction,latest_notice_state
        ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
        """, projectionBindings(value, event: event))
    }

    private func updateProjectionUnlocked(
        _ value: PolicyViolation,
        event: PolicyViolationEvent
    ) throws {
        try executeUnlocked("""
        UPDATE stj_violations SET state=?,last_observed_at=?,occurrence_count=?,
          latest_event_sequence=?,latest_summary=?,latest_confidence=?,
          latest_suggested_correction=?,latest_notice_state=? WHERE violation_id=?;
        """, [
            .text(value.state.rawValue), .text(ISO8601.string(from: value.lastObservedAt)),
            .integer(Int64(value.occurrenceCount)), .integer(event.sequence),
            .text(value.latestSummary), .double(event.candidate.confidence),
            .text(value.latestSuggestedCorrection), .text(event.noticeState),
            .text(value.id.description),
        ])
    }

    private func projectionBindings(
        _ value: PolicyViolation,
        event: PolicyViolationEvent
    ) -> [SQLiteValue] {
        [
            .text(value.id.description), .text(value.fingerprint), .text(value.ruleID.rawValue),
            .text(value.policyRevision), event.candidate.scope.projectID.map(SQLiteValue.text) ?? .null,
            event.candidate.scope.projectGeneration.map { .integer(Int64($0)) } ?? .null,
            .text(event.candidate.subjectIdentity), .text(value.state.rawValue),
            .text(ISO8601.string(from: value.firstObservedAt)),
            .text(ISO8601.string(from: value.lastObservedAt)),
            .integer(Int64(value.occurrenceCount)), .integer(event.sequence), .text(value.latestSummary),
            .double(event.candidate.confidence), .text(value.latestSuggestedCorrection),
            .text(event.noticeState),
        ]
    }

    private func insertEventUnlocked(_ event: PolicyViolationEvent) throws {
        let candidateData = try Self.encode(event.candidate)
        let candidateJSON = String(data: candidateData, encoding: .utf8) ?? "{}"
        let scopeData = try Self.encode(event.candidate.scope)
        let scopeJSON = String(data: scopeData, encoding: .utf8) ?? "{}"
        let interpretation = try JSONSupport.string(from: [
            "explanation": event.candidate.explanation,
            "confidence": event.candidate.confidence,
            "assumptions": event.candidate.assumptions,
            "alternatives": event.candidate.alternatives,
        ])
        try executeUnlocked("""
        INSERT INTO stj_violation_events(
          sequence,event_id,violation_id,event_type,occurred_at,rule_id,policy_revision,
          source_path,source_locator,project_id,project_generation,scope_json,
          observation_json,interpretation_json,
          suggested_correction,notice_state,prior_event_sha256,event_sha256,development_continues
        ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,1);
        """, [
            .integer(event.sequence), .text(event.id.uuidString.lowercased()),
            .text(event.violationID.description), .text(event.type.rawValue),
            .text(ISO8601.string(from: event.occurredAt)), .text(event.candidate.rule.id.rawValue),
            .text(event.candidate.rule.source.revision), .text(event.candidate.rule.source.path),
            .text(event.candidate.rule.source.locator),
            event.candidate.scope.projectID.map(SQLiteValue.text) ?? .null,
            event.candidate.scope.projectGeneration.map { .integer(Int64($0)) } ?? .null,
            .text(scopeJSON), .text(candidateJSON),
            .text(interpretation), .text(event.candidate.suggestedCorrection),
            .text(event.noticeState), event.priorEventSHA256.map(SQLiteValue.text) ?? .null,
            .text(event.eventSHA256),
        ])
    }

    private func violationUnlocked(fingerprint: String) throws -> PolicyViolation? {
        try queryProjectionUnlocked(
            "SELECT violation_id,fingerprint,rule_id,policy_revision,state,first_observed_at," +
            "last_observed_at,occurrence_count,latest_summary,latest_suggested_correction " +
            "FROM stj_violations WHERE fingerprint=? LIMIT 1;",
            [.text(fingerprint)]
        )
    }

    private func violationUnlocked(id: PolicyViolationID) throws -> PolicyViolation? {
        try queryProjectionUnlocked(
            "SELECT violation_id,fingerprint,rule_id,policy_revision,state,first_observed_at," +
            "last_observed_at,occurrence_count,latest_summary,latest_suggested_correction " +
            "FROM stj_violations WHERE violation_id=? LIMIT 1;",
            [.text(id.description)]
        )
    }

    private func existingEventUnlocked(eventID: UUID) throws -> ExistingEvent? {
        let statement = try prepareUnlocked(
            "SELECT v.violation_id,v.fingerprint,v.rule_id,v.policy_revision,v.state," +
            "v.first_observed_at,v.last_observed_at,v.occurrence_count,v.latest_summary," +
            "v.latest_suggested_correction,e.event_type,e.observation_json " +
            "FROM stj_violations v JOIN stj_violation_events e ON e.violation_id=v.violation_id " +
            "WHERE e.event_id=? LIMIT 1;"
        )
        defer { sqlite3_finalize(statement) }
        try bind([.text(eventID.uuidString.lowercased())], to: statement)
        let step = sqlite3_step(statement)
        guard step == SQLITE_ROW else {
            if step == SQLITE_DONE { return nil }
            throw sqliteErrorUnlocked()
        }
        guard let violationID = UUID(uuidString: text(statement, 0)),
              let state = PolicyViolationProjectionState(rawValue: text(statement, 4)),
              let first = ISO8601.date(from: text(statement, 5)),
              let last = ISO8601.date(from: text(statement, 6)),
              let type = PolicyViolationEventType(rawValue: text(statement, 10)),
              let candidateData = text(statement, 11).data(using: .utf8),
              let candidate = try? Self.decode(PolicyViolationCandidate.self, from: candidateData) else {
            throw StjornarvaldPolicyLogError.invalidRecord("malformed idempotent event")
        }
        let projection = PolicyViolation(
            id: PolicyViolationID(violationID), fingerprint: text(statement, 1),
            ruleID: PolicyRuleID(text(statement, 2)), policyRevision: text(statement, 3),
            state: state, firstObservedAt: first, lastObservedAt: last,
            occurrenceCount: Int(sqlite3_column_int64(statement, 7)),
            latestSummary: text(statement, 8), latestSuggestedCorrection: text(statement, 9)
        )
        return ExistingEvent(projection: projection, type: type, candidate: candidate)
    }

    private func queryProjectionUnlocked(_ sql: String, _ bindings: [SQLiteValue]) throws -> PolicyViolation? {
        let statement = try prepareUnlocked(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        let step = sqlite3_step(statement)
        guard step == SQLITE_ROW else {
            if step == SQLITE_DONE { return nil }
            throw sqliteErrorUnlocked()
        }
        return try projectionUnlocked(from: statement)
    }

    private func projectionUnlocked(from statement: OpaquePointer) throws -> PolicyViolation {
        guard let id = UUID(uuidString: text(statement, 0)),
              let state = PolicyViolationProjectionState(rawValue: text(statement, 4)),
              let first = ISO8601.date(from: text(statement, 5)),
              let last = ISO8601.date(from: text(statement, 6)) else {
            throw StjornarvaldPolicyLogError.invalidRecord("malformed violation projection")
        }
        return PolicyViolation(
            id: PolicyViolationID(id), fingerprint: text(statement, 1),
            ruleID: PolicyRuleID(text(statement, 2)), policyRevision: text(statement, 3),
            state: state, firstObservedAt: first, lastObservedAt: last,
            occurrenceCount: Int(sqlite3_column_int64(statement, 7)),
            latestSummary: text(statement, 8), latestSuggestedCorrection: text(statement, 9)
        )
    }

    private func eventsUnlocked(after sequence: Int64, limit: Int) throws -> [PolicyViolationEvent] {
        let statement = try prepareUnlocked("""
        SELECT sequence,event_id,violation_id,event_type,occurred_at,observation_json,
          notice_state,prior_event_sha256,event_sha256
        FROM stj_violation_events WHERE sequence>? ORDER BY sequence ASC LIMIT ?;
        """)
        defer { sqlite3_finalize(statement) }
        try bind([.integer(sequence), .integer(Int64(limit))], to: statement)
        var result: [PolicyViolationEvent] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw sqliteErrorUnlocked() }
            result.append(try eventUnlocked(from: statement))
        }
        return result
    }

    private func newestEventsUnlocked(
        limit: Int,
        projectID: String?,
        projectGeneration: UInt64?
    ) throws -> [PolicyViolationEvent] {
        let filter: String
        let bindings: [SQLiteValue]
        if let projectID, let projectGeneration {
            filter = " WHERE project_id=? AND project_generation=?"
            bindings = [
                .text(projectID),
                .integer(Int64(projectGeneration)),
                .integer(Int64(limit)),
            ]
        } else {
            filter = ""
            bindings = [.integer(Int64(limit))]
        }
        let statement = try prepareUnlocked("""
        SELECT sequence,event_id,violation_id,event_type,occurred_at,observation_json,
          notice_state,prior_event_sha256,event_sha256
        FROM stj_violation_events\(filter) ORDER BY sequence DESC LIMIT ?;
        """)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        var result: [PolicyViolationEvent] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw sqliteErrorUnlocked() }
            result.append(try eventUnlocked(from: statement))
        }
        return result
    }

    private func eventUnlocked(from statement: OpaquePointer) throws -> PolicyViolationEvent {
        guard let eventID = UUID(uuidString: text(statement, 1)),
              let violationID = UUID(uuidString: text(statement, 2)),
              let type = PolicyViolationEventType(rawValue: text(statement, 3)),
              let occurredAt = ISO8601.date(from: text(statement, 4)),
              let data = text(statement, 5).data(using: .utf8),
              let candidate = try? Self.decode(PolicyViolationCandidate.self, from: data) else {
            throw StjornarvaldPolicyLogError.invalidRecord("malformed violation event")
        }
        let prior = sqlite3_column_type(statement, 7) == SQLITE_NULL ? nil : text(statement, 7)
        return PolicyViolationEvent(
            schemaVersion: "1.0.0", sequence: sqlite3_column_int64(statement, 0),
            id: eventID, type: type, occurredAt: occurredAt,
            violationID: PolicyViolationID(violationID),
            fingerprint: try Self.fingerprint(for: candidate), candidate: candidate,
            noticeState: text(statement, 6), priorEventSHA256: prior,
            eventSHA256: text(statement, 8), developmentContinues: true
        )
    }

    private func repairJSONLMirrorUnlocked() throws {
        let count = try scalarIntUnlocked("SELECT COUNT(*) FROM stj_violation_events;")
        guard count <= Self.maximumRepairEvents else {
            throw StjornarvaldPolicyLogError.invalidRecord("mirror repair exceeds event bound")
        }
        let parent = jsonlURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let temporary = parent.appendingPathComponent(
            ".policy-violations-\(UUID().uuidString.lowercased()).tmp"
        )
        let descriptor = Darwin.open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var shouldClose = true
        defer {
            if shouldClose { Darwin.close(descriptor) }
            try? FileManager.default.removeItem(at: temporary)
        }
        var cursor: Int64 = 0
        var last: PolicyViolationEvent?
        while true {
            let page = try eventsUnlocked(after: cursor, limit: 256)
            guard !page.isEmpty else { break }
            for event in page {
                var line = try Self.mirrorData(event)
                line.append(0x0A)
                try Self.writeAll(line, to: descriptor)
                cursor = event.sequence
                last = event
            }
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard Darwin.close(descriptor) == 0 else {
            shouldClose = false
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        shouldClose = false
        let manager = FileManager.default
        if manager.fileExists(atPath: jsonlURL.path) {
            _ = try manager.replaceItemAt(jsonlURL, withItemAt: temporary)
        } else {
            try manager.moveItem(at: temporary, to: jsonlURL)
        }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: jsonlURL.path)
        try setMirrorStateUnlocked(
            sequence: last?.sequence ?? 0,
            digest: last?.eventSHA256,
            pending: false
        )
    }

    private func appendMirrorUnlocked(_ event: PolicyViolationEvent) throws {
        let manager = FileManager.default
        let parent = jsonlURL.deletingLastPathComponent()
        try manager.createDirectory(
            at: parent, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let descriptor = Darwin.open(
            jsonlURL.path,
            O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var line = try Self.mirrorData(event)
        line.append(0x0A)
        try Self.writeAll(line, to: descriptor)
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func mirroredSequenceUnlocked() throws -> Int64 {
        Int64(try scalarIntUnlocked(
            "SELECT mirrored_sequence FROM stj_jsonl_mirror_state WHERE singleton_id=1;"
        ))
    }

    private func setMirrorStateUnlocked(sequence: Int64, digest: String?, pending: Bool) throws {
        try executeUnlocked("""
        UPDATE stj_jsonl_mirror_state SET mirrored_sequence=?,last_event_sha256=?,
          repair_pending=?,updated_at=? WHERE singleton_id=1;
        """, [
            .integer(sequence), digest.map(SQLiteValue.text) ?? .null,
            .integer(pending ? 1 : 0), .text(ISO8601.string(from: Date())),
        ])
    }

    private func nextSequenceUnlocked() throws -> Int64 {
        Int64(try scalarIntUnlocked("SELECT COALESCE(MAX(sequence),0)+1 FROM stj_violation_events;"))
    }

    private func lastEventDigestUnlocked() throws -> String? {
        let statement = try prepareUnlocked(
            "SELECT event_sha256 FROM stj_violation_events ORDER BY sequence DESC LIMIT 1;"
        )
        defer { sqlite3_finalize(statement) }
        let step = sqlite3_step(statement)
        if step == SQLITE_ROW { return text(statement, 0) }
        if step == SQLITE_DONE { return nil }
        throw sqliteErrorUnlocked()
    }

    private static func project(
        event: PolicyViolationEvent,
        prior: PolicyViolation?
    ) -> PolicyViolation {
        let state: PolicyViolationProjectionState = switch event.type {
        case .opened: .open
        case .repeated: .repeated
        case .evidenceUpdated: prior?.state ?? .open
        case .corrected: .corrected
        case .reopened: .reopened
        case .disputed: .disputed
        }
        let incrementsOccurrence = event.type == .opened || event.type == .repeated || event.type == .reopened
        return PolicyViolation(
            id: event.violationID,
            fingerprint: event.fingerprint,
            ruleID: event.candidate.rule.id,
            policyRevision: event.candidate.rule.source.revision,
            state: state,
            firstObservedAt: prior?.firstObservedAt ?? event.occurredAt,
            lastObservedAt: event.occurredAt,
            occurrenceCount: prior.map { $0.occurrenceCount + (incrementsOccurrence ? 1 : 0) } ?? 1,
            latestSummary: event.candidate.summary,
            latestSuggestedCorrection: event.candidate.suggestedCorrection
        )
    }

    private static func makeEvent(
        sequence: Int64,
        eventID: UUID,
        type: PolicyViolationEventType,
        occurredAt: Date,
        violationID: PolicyViolationID,
        fingerprint: String,
        candidate: PolicyViolationCandidate,
        priorEventSHA256: String?
    ) throws -> PolicyViolationEvent {
        let provisional = PolicyViolationEvent(
            schemaVersion: "1.0.0", sequence: sequence, id: eventID, type: type,
            occurredAt: occurredAt, violationID: violationID, fingerprint: fingerprint,
            candidate: candidate,
            noticeState: type == .corrected ? "not_required" : "pending",
            priorEventSHA256: priorEventSHA256, eventSHA256: "", developmentContinues: true
        )
        let digest = JSONSupport.sha256Hex(try digestData(provisional))
        return PolicyViolationEvent(
            schemaVersion: provisional.schemaVersion, sequence: sequence, id: eventID, type: type,
            occurredAt: occurredAt, violationID: violationID, fingerprint: fingerprint,
            candidate: candidate, noticeState: provisional.noticeState,
            priorEventSHA256: priorEventSHA256, eventSHA256: digest, developmentContinues: true
        )
    }

    private static func fingerprint(for candidate: PolicyViolationCandidate) throws -> String {
        var identity: [String: Any] = [
            "rule_id": candidate.rule.id.rawValue,
            "policy_revision": candidate.rule.source.revision,
            "project_id": candidate.scope.projectID ?? "",
            "project_generation": candidate.scope.projectGeneration ?? -1,
            "subject_identity": candidate.subjectIdentity,
        ]
        if let conditionIdentity = candidate.conditionIdentity {
            identity["condition_identity"] = conditionIdentity
        }
        return try JSONSupport.sha256Hex(JSONSupport.canonicalJSON(identity))
    }

    fileprivate static func validateCandidate(_ candidate: PolicyViolationCandidate) throws {
        let boundedStrings = [
            candidate.rule.id.rawValue, candidate.rule.source.revision,
            candidate.rule.source.path, candidate.rule.source.locator,
            candidate.rule.statement, candidate.rule.policyArea,
            candidate.rule.applicability, candidate.subjectIdentity,
            candidate.summary, candidate.explanation, candidate.suggestedCorrection,
            candidate.conditionIdentity ?? "",
        ]
        guard boundedStrings.allSatisfy({ $0.utf8.count <= 16_384 }),
              candidate.evidenceReferences.count <= 64,
              candidate.assumptions.count <= 32,
              candidate.alternatives.count <= 32,
              (candidate.evidenceReferences + candidate.assumptions + candidate.alternatives)
                .allSatisfy({ $0.utf8.count <= 4_096 }),
              try encode(candidate).count <= 262_144 else {
            throw StjornarvaldPolicyLogError.invalidRecord("candidate exceeds persistence bounds")
        }
    }

    private static func violationID(for fingerprint: String) -> PolicyViolationID {
        var characters = Array(fingerprint.prefix(32))
        characters[12] = "5"
        characters[16] = "8"
        let raw = String(characters)
        let formatted = "\(raw.prefix(8))-\(raw.dropFirst(8).prefix(4))-\(raw.dropFirst(12).prefix(4))-\(raw.dropFirst(16).prefix(4))-\(raw.dropFirst(20))"
        return PolicyViolationID(UUID(uuidString: formatted)!)
    }

    private static func digestData(_ event: PolicyViolationEvent) throws -> Data {
        try JSONSupport.data(from: try eventObject(event, includeDigest: false))
    }

    private static func mirrorData(_ event: PolicyViolationEvent) throws -> Data {
        try JSONSupport.data(from: try eventObject(event, includeDigest: true))
    }

    private static func eventObject(
        _ event: PolicyViolationEvent,
        includeDigest: Bool
    ) throws -> [String: Any] {
        var object: [String: Any] = [
            "schema_version": event.schemaVersion,
            "sequence": event.sequence,
            "event_id": event.id.uuidString.lowercased(),
            "event_type": event.type.rawValue,
            "occurred_at": ISO8601.string(from: event.occurredAt),
            "violation_id": event.violationID.description,
            "fingerprint": event.fingerprint,
            "scope": [
                "project_id": nullable(event.candidate.scope.projectID),
                "project_generation": nullable(event.candidate.scope.projectGeneration),
                "run_id": nullable(event.candidate.scope.runID),
                "session_id": nullable(event.candidate.scope.sessionID),
                "client_id": nullable(event.candidate.scope.clientID),
            ],
            "rule": [
                "rule_id": event.candidate.rule.id.rawValue,
                "policy_revision": event.candidate.rule.source.revision,
                "source_path": event.candidate.rule.source.path,
                "source_locator": event.candidate.rule.source.locator,
            ],
            "observation": [
                "observation_id": event.candidate.observationID.uuidString.lowercased(),
                "summary": event.candidate.summary,
                "evidence_references": event.candidate.evidenceReferences,
            ],
            "interpretation": [
                "explanation": event.candidate.explanation,
                "confidence": event.candidate.confidence,
                "assumptions": event.candidate.assumptions,
                "alternatives": event.candidate.alternatives,
            ],
            "suggested_correction": event.candidate.suggestedCorrection,
            "notice_state": event.noticeState,
            "prior_event_sha256": nullable(event.priorEventSHA256),
            "development_continues": true,
        ]
        if includeDigest { object["event_sha256"] = event.eventSHA256 }
        return object
    }

    private static func nullable<T>(_ value: T?) -> Any {
        if let value { return value }
        return NSNull()
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard var address = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, address, remaining)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                remaining -= written
                address = address.advanced(by: written)
            }
        }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    private enum SQLiteValue {
        case text(String), integer(Int64), double(Double), null
    }

    private func execUnlocked(_ sql: String) throws {
        guard let database else { throw StjornarvaldPolicyLogError.openFailed("closed") }
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(message)
            throw StjornarvaldPolicyLogError.sqlite(detail)
        }
    }

    private func executeUnlocked(_ sql: String, _ values: [SQLiteValue]) throws {
        let statement = try prepareUnlocked(sql)
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteErrorUnlocked() }
    }

    private func prepareUnlocked(_ sql: String) throws -> OpaquePointer {
        guard let database else { throw StjornarvaldPolicyLogError.openFailed("closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw sqliteErrorUnlocked() }
        return statement
    }

    private func bind(_ values: [SQLiteValue], to statement: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32 = switch value {
            case .text(let value): sqlite3_bind_text(statement, index, value, -1, Self.sqliteTransient)
            case .integer(let value): sqlite3_bind_int64(statement, index, value)
            case .double(let value): sqlite3_bind_double(statement, index, value)
            case .null: sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw sqliteErrorUnlocked() }
        }
    }

    private func scalarIntUnlocked(_ sql: String) throws -> Int {
        let statement = try prepareUnlocked(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw sqliteErrorUnlocked() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func sqliteErrorUnlocked() -> StjornarvaldPolicyLogError {
        guard let database else { return .openFailed("closed") }
        return .sqlite(String(cString: sqlite3_errmsg(database)))
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }
}

/// Non-throwing boundary used by later coordinators. Failed SQLite writes go to
/// an owner-only outbox; if that also fails, a bounded in-memory queue retains
/// the newest requests and diagnostics are emitted. Callers always continue.
public final class StjornarvaldPolicyLogService: FailForwardPolicyViolationLogging, @unchecked Sendable {
    private struct OutboxEnvelope: Codable, Equatable {
        let eventID: UUID
        let occurredAt: Date
        let candidate: PolicyViolationCandidate
    }

    private let lock = NSLock()
    private let store: StjornarvaldPolicyLogStore?
    private let outboxURL: URL
    private let diagnostics: @Sendable (String) -> Void
    private var emergency: [OutboxEnvelope] = []
    private static let emergencyLimit = 32

    public convenience init(
        paths: AppPaths,
        diagnostics: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.init(
            databaseURL: paths.stjornarvaldPolicyLogSQLite,
            jsonlURL: paths.stjornarvaldPolicyLogJSONL,
            outboxURL: paths.stjornarvaldOutboxDir,
            diagnostics: diagnostics
        )
    }

    public init(
        databaseURL: URL,
        jsonlURL: URL,
        outboxURL: URL,
        diagnostics: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.outboxURL = outboxURL
        self.diagnostics = diagnostics
        do {
            store = try StjornarvaldPolicyLogStore(databaseURL: databaseURL, jsonlURL: jsonlURL)
        } catch {
            store = nil
            diagnostics("stjornarvald policy log unavailable: \(error.localizedDescription)")
        }
        reconcileOutbox()
    }

    public func record(_ candidate: PolicyViolationCandidate) async -> PolicyLogWriteDisposition {
        record(candidate, eventID: UUID(), occurredAt: Date())
    }

    public func record(
        _ candidate: PolicyViolationCandidate,
        eventID: UUID,
        occurredAt: Date
    ) -> PolicyLogWriteDisposition {
        do {
            try StjornarvaldPolicyLogStore.validateCandidate(candidate)
        } catch {
            diagnostics("stjornarvald request rejected by storage bounds: \(error.localizedDescription)")
            return .deferred(eventID: eventID)
        }
        if let store {
            do { return .persisted(try store.record(candidate, eventID: eventID, occurredAt: occurredAt)) }
            catch { diagnostics("stjornarvald SQLite write deferred: \(error.localizedDescription)") }
        }
        let envelope = OutboxEnvelope(eventID: eventID, occurredAt: occurredAt, candidate: candidate)
        if persistOutbox(envelope) { return .deferred(eventID: eventID) }
        lock.lock()
        if emergency.count == Self.emergencyLimit { emergency.removeFirst() }
        emergency.append(envelope)
        lock.unlock()
        diagnostics("stjornarvald outbox unavailable; request retained in bounded memory")
        return .deferred(eventID: eventID)
    }

    public var emergencyCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return emergency.count
    }

    private func persistOutbox(_ envelope: OutboxEnvelope) -> Bool {
        do {
            let manager = FileManager.default
            try manager.createDirectory(
                at: outboxURL, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: outboxURL.path)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let destination = outboxURL.appendingPathComponent(
                envelope.eventID.uuidString.lowercased() + ".json"
            )
            if manager.fileExists(atPath: destination.path) {
                let data = try Data(contentsOf: destination, options: [.mappedIfSafe])
                guard data.count <= 262_144 else { return false }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                guard try decoder.decode(OutboxEnvelope.self, from: data) == envelope else {
                    diagnostics("stjornarvald outbox event ID conflicts with retained content")
                    return false
                }
                return true
            }
            let existingCount = boundedOutboxFiles(maximum: 10_000).count
            guard existingCount < 10_000 else {
                diagnostics("stjornarvald outbox reached its 10000-item bound")
                return false
            }
            try encoder.encode(envelope).write(to: destination, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            return true
        } catch {
            diagnostics("stjornarvald outbox write failed: \(error.localizedDescription)")
            return false
        }
    }

    private func reconcileOutbox() {
        guard let store else { return }
        let manager = FileManager.default
        let files = boundedOutboxFiles(maximum: 1_000)
        guard !files.isEmpty else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for file in files.sorted(by: { $0.path < $1.path }) {
            do {
                let data = try Data(contentsOf: file, options: [.mappedIfSafe])
                guard data.count <= 262_144 else {
                    diagnostics("stjornarvald outbox item exceeds its byte bound")
                    continue
                }
                let envelope = try decoder.decode(OutboxEnvelope.self, from: data)
                _ = try store.record(
                    envelope.candidate,
                    eventID: envelope.eventID,
                    occurredAt: envelope.occurredAt
                )
                try manager.removeItem(at: file)
            } catch {
                diagnostics("stjornarvald outbox reconciliation deferred: \(error.localizedDescription)")
            }
        }
    }

    private func boundedOutboxFiles(maximum: Int) -> [URL] {
        guard maximum > 0,
              let enumerator = FileManager.default.enumerator(
                at: outboxURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
              ) else { return [] }
        var result: [URL] = []
        for case let file as URL in enumerator where file.pathExtension == "json" {
            result.append(file)
            if result.count == maximum { break }
        }
        return result
    }
}
