// ProjectMemoryRepository.swift
// What: Owns one project-scoped SQLite database and its versioned durable schema.
// How: A serialized connection uses WAL, typed binds, short transactions, and bounded queries.
// Why: Separate databases make project isolation enforceable at the storage boundary.

import Foundation
import SQLite3

public final class ProjectMemoryRepository: @unchecked Sendable {
    public static let schemaVersion = 1
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public let projectID: String
    public let directory: URL
    public let databaseURL: URL
    public private(set) var supportsFTS5 = false
    private let clock: any Clock
    private let enableFTS5: Bool
    private let lock = NSLock()
    private var db: OpaquePointer?

    public init(
        projectID: String,
        directory: URL,
        clock: any Clock = SystemClock(),
        enableFTS5: Bool = true
    ) throws {
        guard UUID(uuidString: projectID) != nil else {
            throw ProjectMemoryError.invalidRequest("project_id must be a UUID")
        }
        self.projectID = projectID
        self.directory = directory.standardizedFileURL
        self.databaseURL = directory.appendingPathComponent("memory.sqlite3")
        self.clock = clock
        self.enableFTS5 = enableFTS5
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try openAndMigrate()
    }

    deinit { close() }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        if let db {
            sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_PASSIVE, nil, nil)
            sqlite3_close_v2(db)
            self.db = nil
        }
    }

    public func quickCheck() throws -> Bool {
        try queryOne("PRAGMA quick_check;") { statement in
            text(statement, 0) == "ok"
        } ?? false
    }

    public func remember(_ write: ProjectMemoryWrite) throws -> (ProjectMemoryRecord, String) {
        lock.lock()
        defer { lock.unlock() }
        return try transactionUnlocked {
            try rememberUnlocked(write)
        }
    }

    public func rememberBatch(_ writes: [ProjectMemoryWrite]) throws -> [(ProjectMemoryRecord, String)] {
        lock.lock()
        defer { lock.unlock() }
        return try transactionUnlocked {
            try writes.map(rememberUnlocked)
        }
    }

    public func get(id: String, includeTombstone: Bool = false) throws -> ProjectMemoryRecord? {
        let tombstone = includeTombstone ? "" : " AND is_tombstone=0"
        return try withStatement(
            Self.recordSelect + " WHERE id=? AND project_id=?\(tombstone) LIMIT 1"
        ) { statement in
            bind(statement, 1, id)
            bind(statement, 2, projectID)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return record(statement)
        }
    }

    public func get(ids: [String], includeBody: Bool, maximumCount: Int) throws -> [ProjectMemoryRecord] {
        var output: [ProjectMemoryRecord] = []
        for id in ids.prefix(maximumCount) {
            if let item = try get(id: id) {
                var value = item
                if !includeBody { value.body = nil }
                output.append(value)
            }
        }
        return output
    }

    public func update(
        id: String,
        expectedVersion: Int,
        title: String?,
        summary: String?,
        body: String?,
        tags: [String]?
    ) throws -> ProjectMemoryRecord {
        lock.lock()
        defer { lock.unlock() }
        return try transactionUnlocked {
            guard let current = try recordByIDUnlocked(id, includeTombstone: false) else {
                throw ProjectMemoryError.recordNotFound(id)
            }
            guard current.version == expectedVersion else {
                throw ProjectMemoryError.conflict("expected version \(expectedVersion), current version \(current.version)")
            }
            let nextTitle = title ?? current.title
            let nextSummary = summary ?? current.summary
            let nextBody = body ?? current.body
            let nextTags = tags ?? current.tags
            let hash = Self.contentHash(
                kind: current.kind,
                title: nextTitle,
                summary: nextSummary,
                body: nextBody,
                tags: nextTags
            )
            let timestamp = ISO8601.string(from: clock.now())
            try withStatementUnlocked(
                """
                UPDATE memory_records SET version=version+1, title=?, summary=?, body=?,
                    updated_at=?, last_accessed_at=?, content_hash=?
                WHERE id=? AND project_id=? AND version=? AND is_tombstone=0
                """
            ) { statement in
                bind(statement, 1, nextTitle)
                bind(statement, 2, nextSummary)
                bind(statement, 3, nextBody)
                bind(statement, 4, timestamp)
                bind(statement, 5, timestamp)
                bind(statement, 6, hash)
                bind(statement, 7, id)
                bind(statement, 8, projectID)
                sqlite3_bind_int(statement, 9, Int32(expectedVersion))
                try stepDone(statement)
            }
            try replaceTagsUnlocked(recordID: id, tags: nextTags)
            try appendEventUnlocked(action: "updated", recordID: id, detail: hash)
            guard let updated = try recordByIDUnlocked(id, includeTombstone: false) else {
                throw ProjectMemoryError.recordNotFound(id)
            }
            return updated
        }
    }

    public func forget(id: String) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return try transactionUnlocked {
            let timestamp = ISO8601.string(from: clock.now())
            try withStatementUnlocked(
                """
                UPDATE memory_records SET is_tombstone=1, version=version+1,
                    body=NULL, updated_at=?, last_accessed_at=?
                WHERE id=? AND project_id=? AND is_tombstone=0
                """
            ) { statement in
                bind(statement, 1, timestamp)
                bind(statement, 2, timestamp)
                bind(statement, 3, id)
                bind(statement, 4, projectID)
                try stepDone(statement)
            }
            let changed = sqlite3_changes(db) > 0
            if changed { try appendEventUnlocked(action: "tombstoned", recordID: id, detail: nil) }
            return changed
        }
    }

    public func link(sourceID: String, targetID: String, relation: String) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return try transactionUnlocked {
            guard try recordByIDUnlocked(sourceID, includeTombstone: false) != nil,
                  try recordByIDUnlocked(targetID, includeTombstone: false) != nil else {
                throw ProjectMemoryError.recordNotFound("source or target record")
            }
            try withStatementUnlocked(
                "INSERT OR IGNORE INTO memory_links(project_id,source_id,target_id,relation,created_at) VALUES(?,?,?,?,?)"
            ) { statement in
                bind(statement, 1, projectID)
                bind(statement, 2, sourceID)
                bind(statement, 3, targetID)
                bind(statement, 4, relation)
                bind(statement, 5, ISO8601.string(from: clock.now()))
                try stepDone(statement)
            }
            return sqlite3_changes(db) > 0
        }
    }

    public func recent(
        kinds: [String],
        sessionID: String?,
        limit: Int,
        offset: Int
    ) throws -> [ProjectMemoryRecord] {
        var sql = Self.recordSelect + " WHERE project_id=? AND is_tombstone=0"
        if !kinds.isEmpty {
            sql += " AND kind IN (\(Array(repeating: "?", count: kinds.count).joined(separator: ",")))"
        }
        if sessionID != nil { sql += " AND session_id=?" }
        sql += " ORDER BY updated_at DESC,id ASC LIMIT ? OFFSET ?"
        return try withStatement(sql) { statement in
            var index: Int32 = 1
            bind(statement, index, projectID); index += 1
            for kind in kinds { bind(statement, index, kind); index += 1 }
            if let sessionID { bind(statement, index, sessionID); index += 1 }
            sqlite3_bind_int(statement, index, Int32(limit)); index += 1
            sqlite3_bind_int(statement, index, Int32(offset))
            var output: [ProjectMemoryRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW { output.append(record(statement)) }
            return output
        }
    }

    public func search(
        query: String,
        kinds: [String],
        tags: [String],
        sessionID: String?,
        limit: Int,
        offset: Int
    ) throws -> [(ProjectMemoryRecord, Double)] {
        let escaped = Self.escapeLike(query)
        let pattern = "%\(escaped)%"
        var sql = """
        SELECT \(Self.recordColumns),
        (CASE WHEN lower(id)=lower(?) THEN 1000 ELSE 0 END +
         CASE WHEN lower(title)=lower(?) THEN 400 WHEN title LIKE ? ESCAPE '\\' THEN 200 ELSE 0 END +
         CASE WHEN summary LIKE ? ESCAPE '\\' THEN 80 ELSE 0 END +
         CASE WHEN body LIKE ? ESCAPE '\\' THEN 30 ELSE 0 END +
         importance * 10 + confidence * 5) AS rank_score
        FROM memory_records r
        WHERE project_id=? AND is_tombstone=0
          AND (id=? OR title LIKE ? ESCAPE '\\' OR summary LIKE ? ESCAPE '\\' OR body LIKE ? ESCAPE '\\')
        """
        if !kinds.isEmpty {
            sql += " AND kind IN (\(Array(repeating: "?", count: kinds.count).joined(separator: ",")))"
        }
        if sessionID != nil { sql += " AND session_id=?" }
        for _ in tags {
            sql += " AND EXISTS(SELECT 1 FROM memory_record_tags rt JOIN memory_tags t ON t.id=rt.tag_id WHERE rt.record_id=r.id AND t.name=?)"
        }
        sql += " ORDER BY rank_score DESC,updated_at DESC,id ASC LIMIT ? OFFSET ?"
        return try withStatement(sql) { statement in
            var index: Int32 = 1
            bind(statement, index, query); index += 1
            bind(statement, index, query); index += 1
            bind(statement, index, pattern); index += 1
            bind(statement, index, pattern); index += 1
            bind(statement, index, pattern); index += 1
            bind(statement, index, projectID); index += 1
            bind(statement, index, query); index += 1
            bind(statement, index, pattern); index += 1
            bind(statement, index, pattern); index += 1
            bind(statement, index, pattern); index += 1
            for kind in kinds { bind(statement, index, kind); index += 1 }
            if let sessionID { bind(statement, index, sessionID); index += 1 }
            for tag in tags { bind(statement, index, tag); index += 1 }
            sqlite3_bind_int(statement, index, Int32(limit)); index += 1
            sqlite3_bind_int(statement, index, Int32(offset))
            var output: [(ProjectMemoryRecord, Double)] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                output.append((record(statement), sqlite3_column_double(statement, 20)))
            }
            return output
        }
    }

    public func status() throws -> [String: Any] {
        let count = try scalarInt("SELECT COUNT(*) FROM memory_records WHERE project_id=? AND is_tombstone=0", value: projectID)
        let tombstones = try scalarInt("SELECT COUNT(*) FROM memory_records WHERE project_id=? AND is_tombstone=1", value: projectID)
        let events = try scalarInt("SELECT COUNT(*) FROM event_journal WHERE project_id=?", value: projectID)
        let databaseBytes = Self.fileSize(databaseURL)
        let walBytes = Self.fileSize(URL(fileURLWithPath: databaseURL.path + "-wal"))
        return [
            "project_id": projectID,
            "schema_version": Self.schemaVersion,
            "record_count": count,
            "tombstone_count": tombstones,
            "event_count": events,
            "database_bytes": databaseBytes,
            "wal_bytes": walBytes,
            "fts5": supportsFTS5,
            "integrity": try quickCheck() ? "ok" : "failed",
        ]
    }

    public func exportRecords() throws -> [[String: Any]] {
        let records = try recent(kinds: [], sessionID: nil, limit: 10_000, offset: 0)
        return records.map { $0.asDictionary(includeBody: true) }
    }

    // MARK: - Continuity ledger

    public func continuityCreateOperation(
        operationID: String,
        predecessorSessionID: String,
        handoffID: String,
        adapterID: String,
        idempotencyKey: String
    ) throws -> ContinuityOperation {
        lock.lock(); defer { lock.unlock() }
        return try transactionUnlocked {
            if let existing = try continuityOperationByIdempotencyUnlocked(idempotencyKey) {
                return existing
            }
            if let active = try continuityActiveOperationUnlocked() {
                throw ProjectMemoryError.conflict("rollover already active: \(active.operationID)")
            }
            let timestamp = ISO8601.string(from: clock.now())
            let checksum = Self.continuityChecksum(
                operationID: operationID, state: .active, successorSessionID: nil,
                handoffID: handoffID, attempt: 0
            )
            try withStatementUnlocked(
                """
                INSERT INTO rollover_operations(
                  operation_id,project_id,predecessor_session_id,successor_session_id,handoff_id,
                  state,attempt,adapter_id,idempotency_key,acknowledged_session_id,
                  acknowledged_handoff_id,created_at,updated_at,last_error,retry_at,state_checksum
                ) VALUES(?,?,?,NULL,?, ?,0,?,?,NULL,NULL,?,?,NULL,NULL,?)
                """
            ) { statement in
                bind(statement, 1, operationID); bind(statement, 2, projectID)
                bind(statement, 3, predecessorSessionID); bind(statement, 4, handoffID)
                bind(statement, 5, ContinuityState.active.rawValue); bind(statement, 6, adapterID)
                bind(statement, 7, idempotencyKey); bind(statement, 8, timestamp)
                bind(statement, 9, timestamp); bind(statement, 10, checksum)
                try stepDone(statement)
            }
            try appendTransitionUnlocked(
                operationID: operationID, from: nil, to: .active, attempt: 0,
                adapterID: adapterID, evidence: "operation_created", checksum: checksum
            )
            guard let created = try continuityOperationUnlocked(operationID) else {
                throw ProjectMemoryError.integrityFailure("created rollover operation is unreadable")
            }
            return created
        }
    }

    public func continuityStoreHandoff(_ handoff: ContinuityHandoff) throws {
        let validated = try handoff.validated()
        let payload = try JSONSupport.string(from: validated.asDictionary())
        lock.lock(); defer { lock.unlock() }
        try transactionUnlocked {
            guard let operation = try continuityOperationUnlocked(validated.operationID),
                  operation.projectID == projectID, operation.handoffID == validated.handoffID,
                  operation.state == .active || operation.state == .checkpointPreparing else {
                throw ProjectMemoryError.conflict("handoff does not match checkpoint preparation")
            }
            try withStatementUnlocked(
                """
                INSERT INTO continuity_handoffs(
                  handoff_id,project_id,operation_id,payload_json,content_sha256,created_at
                ) VALUES(?,?,?,?,?,?)
                ON CONFLICT(handoff_id) DO UPDATE SET
                  payload_json=excluded.payload_json,content_sha256=excluded.content_sha256
                """
            ) { statement in
                bind(statement, 1, validated.handoffID); bind(statement, 2, projectID)
                bind(statement, 3, validated.operationID); bind(statement, 4, payload)
                bind(statement, 5, validated.contentSHA256); bind(statement, 6, validated.createdAt)
                try stepDone(statement)
            }
        }
    }

    public func continuityHandoff(id: String) throws -> ContinuityHandoff? {
        try withStatement(
            "SELECT payload_json,content_sha256 FROM continuity_handoffs WHERE handoff_id=? AND project_id=? LIMIT 1"
        ) { statement in
            bind(statement, 1, id); bind(statement, 2, projectID)
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let payload = text(statement, 0), let data = payload.data(using: .utf8),
                  let object = try? JSONSupport.object(from: data),
                  let handoff = ContinuityHandoff.fromDictionary(object),
                  handoff.contentSHA256 == text(statement, 1),
                  handoff.calculatedSHA256() == handoff.contentSHA256 else { return nil }
            return handoff
        }
    }

    public func continuityTransition(
        operationID: String,
        expected: ContinuityState,
        to next: ContinuityState,
        successorSessionID: String? = nil,
        evidence: String? = nil
    ) throws -> ContinuityOperation {
        guard expected.next == next else {
            throw ProjectMemoryError.invalidRequest("invalid transition \(expected.rawValue) -> \(next.rawValue)")
        }
        lock.lock(); defer { lock.unlock() }
        return try transactionUnlocked {
            guard let operation = try continuityOperationUnlocked(operationID) else {
                throw ProjectMemoryError.recordNotFound(operationID)
            }
            if operation.state == next { return operation }
            guard operation.state == expected else {
                throw ProjectMemoryError.conflict("expected \(expected.rawValue), current \(operation.state.rawValue)")
            }
            let successor = successorSessionID ?? operation.successorSessionID
            if next == .successorCreated, successor == nil {
                throw ProjectMemoryError.invalidRequest("successor session is required")
            }
            if next == .checkpointPersisted {
                guard try continuityHandoffExistsUnlocked(id: operation.handoffID) else {
                    throw ProjectMemoryError.integrityFailure("checkpoint handoff is not durable")
                }
            }
            let attempt = operation.attempt + 1
            let checksum = Self.continuityChecksum(
                operationID: operationID, state: next, successorSessionID: successor,
                handoffID: operation.handoffID, attempt: attempt
            )
            let timestamp = ISO8601.string(from: clock.now())
            try withStatementUnlocked(
                """
                UPDATE rollover_operations SET state=?,attempt=?,successor_session_id=?,
                  updated_at=?,last_error=NULL,retry_at=NULL,state_checksum=?
                WHERE operation_id=? AND project_id=? AND state=?
                """
            ) { statement in
                bind(statement, 1, next.rawValue); sqlite3_bind_int(statement, 2, Int32(attempt))
                bind(statement, 3, successor); bind(statement, 4, timestamp); bind(statement, 5, checksum)
                bind(statement, 6, operationID); bind(statement, 7, projectID); bind(statement, 8, expected.rawValue)
                try stepDone(statement)
            }
            guard sqlite3_changes(db) == 1 else { throw ProjectMemoryError.conflict("transition compare-and-set failed") }
            try appendTransitionUnlocked(
                operationID: operationID, from: expected, to: next, attempt: attempt,
                adapterID: operation.adapterID, evidence: evidence, checksum: checksum
            )
            if next == .predecessorSealed, let successor {
                try withStatementUnlocked(
                    "INSERT INTO project_active_sessions(project_id,session_id,updated_at) VALUES(?,?,?) ON CONFLICT(project_id) DO UPDATE SET session_id=excluded.session_id,updated_at=excluded.updated_at"
                ) { statement in
                    bind(statement, 1, projectID); bind(statement, 2, successor); bind(statement, 3, timestamp)
                    try stepDone(statement)
                }
            }
            guard let updated = try continuityOperationUnlocked(operationID) else {
                throw ProjectMemoryError.integrityFailure("transition result is unreadable")
            }
            return updated
        }
    }

    public func continuityAcknowledge(
        operationID: String,
        handoffID: String,
        successorSessionID: String,
        adapterID: String
    ) throws -> ContinuityOperation {
        lock.lock(); defer { lock.unlock() }
        return try transactionUnlocked {
            guard let operation = try continuityOperationUnlocked(operationID) else {
                throw ProjectMemoryError.recordNotFound(operationID)
            }
            if operation.state == .successorAcknowledged || operation.state == .predecessorSealed {
                guard operation.acknowledgedHandoffID == handoffID,
                      operation.acknowledgedSessionID == successorSessionID else {
                    throw ProjectMemoryError.conflict("a different successor acknowledgment is already committed")
                }
                return operation
            }
            guard operation.state == .successorBootstrapping,
                  operation.handoffID == handoffID,
                  operation.successorSessionID == successorSessionID,
                  operation.adapterID == adapterID else {
                throw ProjectMemoryError.conflict("acknowledgment does not match exact handoff, successor, and adapter")
            }
            let next = ContinuityState.successorAcknowledged
            let attempt = operation.attempt + 1
            let checksum = Self.continuityChecksum(
                operationID: operationID, state: next, successorSessionID: successorSessionID,
                handoffID: handoffID, attempt: attempt
            )
            let timestamp = ISO8601.string(from: clock.now())
            try withStatementUnlocked(
                """
                UPDATE rollover_operations SET state=?,attempt=?,acknowledged_session_id=?,
                  acknowledged_handoff_id=?,updated_at=?,state_checksum=?,last_error=NULL,retry_at=NULL
                WHERE operation_id=? AND project_id=? AND state=?
                """
            ) { statement in
                bind(statement, 1, next.rawValue); sqlite3_bind_int(statement, 2, Int32(attempt))
                bind(statement, 3, successorSessionID); bind(statement, 4, handoffID)
                bind(statement, 5, timestamp); bind(statement, 6, checksum)
                bind(statement, 7, operationID); bind(statement, 8, projectID)
                bind(statement, 9, ContinuityState.successorBootstrapping.rawValue); try stepDone(statement)
            }
            guard sqlite3_changes(db) == 1 else { throw ProjectMemoryError.conflict("acknowledgment compare-and-set failed") }
            try withStatementUnlocked(
                "UPDATE continuity_handoffs SET acknowledged_session_id=?,acknowledged_at=? WHERE handoff_id=? AND project_id=?"
            ) { statement in
                bind(statement, 1, successorSessionID); bind(statement, 2, timestamp)
                bind(statement, 3, handoffID); bind(statement, 4, projectID); try stepDone(statement)
            }
            try appendTransitionUnlocked(
                operationID: operationID, from: .successorBootstrapping, to: next,
                attempt: attempt, adapterID: adapterID, evidence: "exact_acknowledgment", checksum: checksum
            )
            guard let updated = try continuityOperationUnlocked(operationID) else {
                throw ProjectMemoryError.integrityFailure("acknowledgment result is unreadable")
            }
            return updated
        }
    }

    public func continuityRecordRetry(operationID: String, error: String, retryAt: String?) throws {
        try withStatement(
            "UPDATE rollover_operations SET last_error=?,retry_at=?,updated_at=? WHERE operation_id=? AND project_id=?"
        ) { statement in
            bind(statement, 1, String(error.prefix(2048))); bind(statement, 2, retryAt)
            bind(statement, 3, ISO8601.string(from: clock.now())); bind(statement, 4, operationID)
            bind(statement, 5, projectID); try stepDone(statement)
        }
    }

    public func continuityOperation(id: String) throws -> ContinuityOperation? {
        try withStatement(Self.continuityOperationSelect + " WHERE operation_id=? AND project_id=? LIMIT 1") { statement in
            bind(statement, 1, id); bind(statement, 2, projectID)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return continuityOperation(statement)
        }
    }

    public func continuityActiveOperation() throws -> ContinuityOperation? {
        try withStatement(Self.continuityOperationSelect + " WHERE project_id=? AND state<>'predecessorSealed' ORDER BY updated_at DESC LIMIT 1") { statement in
            bind(statement, 1, projectID)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return continuityOperation(statement)
        }
    }

    public func continuityActiveSessionID() throws -> String? {
        try withStatement("SELECT session_id FROM project_active_sessions WHERE project_id=?") { statement in
            bind(statement, 1, projectID)
            return sqlite3_step(statement) == SQLITE_ROW ? text(statement, 0) : nil
        }
    }

    public func continuityTransitionCount(operationID: String) throws -> Int {
        try scalarInt("SELECT COUNT(*) FROM rollover_transitions WHERE operation_id=?", value: operationID)
    }

    private static let continuityOperationSelect = """
    SELECT operation_id,project_id,predecessor_session_id,successor_session_id,handoff_id,
      state,attempt,adapter_id,idempotency_key,acknowledged_session_id,acknowledged_handoff_id,
      created_at,updated_at,last_error,retry_at,state_checksum FROM rollover_operations
    """

    private func continuityOperationUnlocked(_ id: String) throws -> ContinuityOperation? {
        try withStatementUnlocked(Self.continuityOperationSelect + " WHERE operation_id=? AND project_id=? LIMIT 1") { statement in
            bind(statement, 1, id); bind(statement, 2, projectID)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return continuityOperation(statement)
        }
    }

    private func continuityOperationByIdempotencyUnlocked(_ key: String) throws -> ContinuityOperation? {
        try withStatementUnlocked(Self.continuityOperationSelect + " WHERE project_id=? AND idempotency_key=? LIMIT 1") { statement in
            bind(statement, 1, projectID); bind(statement, 2, key)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return continuityOperation(statement)
        }
    }

    private func continuityActiveOperationUnlocked() throws -> ContinuityOperation? {
        try withStatementUnlocked(Self.continuityOperationSelect + " WHERE project_id=? AND state<>'predecessorSealed' ORDER BY updated_at DESC LIMIT 1") { statement in
            bind(statement, 1, projectID)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return continuityOperation(statement)
        }
    }

    private func continuityHandoffExistsUnlocked(id: String) throws -> Bool {
        try withStatementUnlocked("SELECT 1 FROM continuity_handoffs WHERE handoff_id=? AND project_id=? LIMIT 1") { statement in
            bind(statement, 1, id); bind(statement, 2, projectID)
            return sqlite3_step(statement) == SQLITE_ROW
        }
    }

    private func continuityOperation(_ statement: OpaquePointer) -> ContinuityOperation {
        let state = ContinuityState(rawValue: text(statement, 5) ?? "active") ?? .active
        return ContinuityOperation(
            operationID: text(statement, 0) ?? "", projectID: text(statement, 1) ?? "",
            predecessorSessionID: text(statement, 2) ?? "", successorSessionID: text(statement, 3),
            handoffID: text(statement, 4) ?? "", state: state,
            attempt: Int(sqlite3_column_int(statement, 6)), adapterID: text(statement, 7) ?? "",
            idempotencyKey: text(statement, 8) ?? "", acknowledgedSessionID: text(statement, 9),
            acknowledgedHandoffID: text(statement, 10), createdAt: text(statement, 11) ?? "",
            updatedAt: text(statement, 12) ?? "", lastError: text(statement, 13),
            retryAt: text(statement, 14), stateChecksum: text(statement, 15) ?? ""
        )
    }

    private func appendTransitionUnlocked(
        operationID: String,
        from: ContinuityState?,
        to: ContinuityState,
        attempt: Int,
        adapterID: String,
        evidence: String?,
        checksum: String
    ) throws {
        try withStatementUnlocked(
            "INSERT INTO rollover_transitions(operation_id,project_id,from_state,to_state,attempt,created_at,adapter_id,evidence,state_checksum) VALUES(?,?,?,?,?,?,?,?,?)"
        ) { statement in
            bind(statement, 1, operationID); bind(statement, 2, projectID); bind(statement, 3, from?.rawValue)
            bind(statement, 4, to.rawValue); sqlite3_bind_int(statement, 5, Int32(attempt))
            bind(statement, 6, ISO8601.string(from: clock.now())); bind(statement, 7, adapterID)
            bind(statement, 8, evidence.map { String($0.prefix(2048)) }); bind(statement, 9, checksum)
            try stepDone(statement)
        }
    }

    private static func continuityChecksum(
        operationID: String,
        state: ContinuityState,
        successorSessionID: String?,
        handoffID: String,
        attempt: Int
    ) -> String {
        JSONSupport.sha256Hex([operationID, state.rawValue, successorSessionID ?? "", handoffID, String(attempt)].joined(separator: "|"))
    }

    // MARK: - Schema and writes

    private func openAndMigrate() throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let handle { sqlite3_close(handle) }
            throw StoreError.openFailed(message)
        }
        db = handle
        do {
            try execUnlocked("PRAGMA busy_timeout=3000; PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA synchronous=NORMAL;")
            try migrateUnlocked()
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)
        } catch {
            let sqliteCode = sqlite3_errcode(handle)
            let preserve = sqliteCode == SQLITE_CORRUPT || sqliteCode == SQLITE_NOTADB
                || (error as? ProjectMemoryError).map {
                    if case .integrityFailure = $0 { return true }
                    return false
                } == true
            sqlite3_close_v2(handle)
            db = nil
            if preserve, FileManager.default.fileExists(atPath: databaseURL.path) {
                let artifact = directory.appendingPathComponent("memory.corrupt-\(UUID().uuidString.lowercased()).sqlite3")
                try? FileManager.default.copyItem(at: databaseURL, to: artifact)
                throw ProjectMemoryError.integrityFailure("database preserved for recovery at \(artifact.lastPathComponent)")
            }
            throw error
        }
    }

    private func migrateUnlocked() throws {
        let prior = try pragmaUserVersionUnlocked()
        guard prior <= Self.schemaVersion else { throw ProjectMemoryError.unsupportedVersion(prior) }
        if prior > 0, FileManager.default.fileExists(atPath: databaseURL.path) {
            let backup = directory.appendingPathComponent("memory.pre-migration-v\(prior).sqlite3")
            if !FileManager.default.fileExists(atPath: backup.path) {
                try? FileManager.default.copyItem(at: databaseURL, to: backup)
            }
        }
        try transactionUnlocked {
            try execUnlocked("""
            CREATE TABLE IF NOT EXISTS memory_records(
                id TEXT PRIMARY KEY, project_id TEXT NOT NULL, version INTEGER NOT NULL,
                kind TEXT NOT NULL, title TEXT NOT NULL, summary TEXT NOT NULL, body TEXT,
                importance REAL NOT NULL, confidence REAL NOT NULL, source_kind TEXT NOT NULL,
                source_reference TEXT, session_id TEXT, created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL, last_accessed_at TEXT NOT NULL, expires_at TEXT,
                content_hash TEXT NOT NULL, is_tombstone INTEGER NOT NULL DEFAULT 0,
                schema_version INTEGER NOT NULL, idempotency_key TEXT,
                UNIQUE(project_id,kind,content_hash), UNIQUE(project_id,idempotency_key)
            );
            CREATE TABLE IF NOT EXISTS memory_tags(id INTEGER PRIMARY KEY AUTOINCREMENT,name TEXT UNIQUE NOT NULL);
            CREATE TABLE IF NOT EXISTS memory_record_tags(record_id TEXT NOT NULL REFERENCES memory_records(id) ON DELETE CASCADE,tag_id INTEGER NOT NULL REFERENCES memory_tags(id),PRIMARY KEY(record_id,tag_id));
            CREATE TABLE IF NOT EXISTS memory_links(project_id TEXT NOT NULL,source_id TEXT NOT NULL REFERENCES memory_records(id),target_id TEXT NOT NULL REFERENCES memory_records(id),relation TEXT NOT NULL,created_at TEXT NOT NULL,PRIMARY KEY(source_id,target_id,relation));
            CREATE TABLE IF NOT EXISTS sessions(id TEXT PRIMARY KEY,project_id TEXT NOT NULL,created_at TEXT NOT NULL,updated_at TEXT NOT NULL,state TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS handoffs(id TEXT PRIMARY KEY,project_id TEXT NOT NULL,record_id TEXT,created_at TEXT NOT NULL,acknowledged_at TEXT);
            CREATE TABLE IF NOT EXISTS artifacts(id TEXT PRIMARY KEY,project_id TEXT NOT NULL,path TEXT NOT NULL,checksum TEXT NOT NULL,created_at TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS project_aliases(project_id TEXT NOT NULL,alias TEXT NOT NULL,created_at TEXT NOT NULL,PRIMARY KEY(project_id,alias));
            CREATE TABLE IF NOT EXISTS maintenance_state(project_id TEXT PRIMARY KEY,last_run_at TEXT,state_json TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS event_journal(id INTEGER PRIMARY KEY AUTOINCREMENT,project_id TEXT NOT NULL,record_id TEXT,action TEXT NOT NULL,detail TEXT,created_at TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS continuity_handoffs(
              handoff_id TEXT PRIMARY KEY,project_id TEXT NOT NULL,operation_id TEXT NOT NULL UNIQUE,
              payload_json TEXT NOT NULL,content_sha256 TEXT NOT NULL,created_at TEXT NOT NULL,
              acknowledged_session_id TEXT,acknowledged_at TEXT
            );
            CREATE TABLE IF NOT EXISTS rollover_operations(
              operation_id TEXT PRIMARY KEY,project_id TEXT NOT NULL,predecessor_session_id TEXT NOT NULL,
              successor_session_id TEXT,handoff_id TEXT NOT NULL,state TEXT NOT NULL,attempt INTEGER NOT NULL,
              adapter_id TEXT NOT NULL,idempotency_key TEXT NOT NULL,acknowledged_session_id TEXT,
              acknowledged_handoff_id TEXT,created_at TEXT NOT NULL,updated_at TEXT NOT NULL,
              last_error TEXT,retry_at TEXT,state_checksum TEXT NOT NULL,
              UNIQUE(project_id,idempotency_key)
            );
            CREATE TABLE IF NOT EXISTS rollover_transitions(
              id INTEGER PRIMARY KEY AUTOINCREMENT,operation_id TEXT NOT NULL,project_id TEXT NOT NULL,
              from_state TEXT,to_state TEXT NOT NULL,attempt INTEGER NOT NULL,created_at TEXT NOT NULL,
              adapter_id TEXT NOT NULL,evidence TEXT,state_checksum TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS project_active_sessions(
              project_id TEXT PRIMARY KEY,session_id TEXT NOT NULL,updated_at TEXT NOT NULL
            );
            CREATE UNIQUE INDEX IF NOT EXISTS idx_rollover_active_project
              ON rollover_operations(project_id) WHERE state <> 'predecessorSealed';
            CREATE INDEX IF NOT EXISTS idx_rollover_project_updated
              ON rollover_operations(project_id,updated_at DESC);
            CREATE INDEX IF NOT EXISTS idx_memory_project_recent ON memory_records(project_id,is_tombstone,updated_at DESC);
            CREATE INDEX IF NOT EXISTS idx_memory_project_kind ON memory_records(project_id,kind,is_tombstone);
            CREATE INDEX IF NOT EXISTS idx_memory_project_session ON memory_records(project_id,session_id,is_tombstone);
            PRAGMA user_version=1;
            """)
        }
        if enableFTS5 {
          do {
            try execUnlocked("""
            CREATE VIRTUAL TABLE IF NOT EXISTS memory_records_fts USING fts5(id UNINDEXED,title,summary,body);
            CREATE TRIGGER IF NOT EXISTS memory_fts_insert AFTER INSERT ON memory_records WHEN new.is_tombstone=0 BEGIN
              INSERT INTO memory_records_fts(id,title,summary,body) VALUES(new.id,new.title,new.summary,COALESCE(new.body,''));
            END;
            CREATE TRIGGER IF NOT EXISTS memory_fts_update AFTER UPDATE ON memory_records BEGIN
              DELETE FROM memory_records_fts WHERE id=old.id;
              INSERT INTO memory_records_fts(id,title,summary,body) SELECT new.id,new.title,new.summary,COALESCE(new.body,'') WHERE new.is_tombstone=0;
            END;
            CREATE TRIGGER IF NOT EXISTS memory_fts_delete AFTER DELETE ON memory_records BEGIN
              DELETE FROM memory_records_fts WHERE id=old.id;
            END;
            """)
            supportsFTS5 = true
          } catch {
              supportsFTS5 = false
          }
        } else {
          supportsFTS5 = false
        }
        guard try quickCheckUnlocked() else {
            throw ProjectMemoryError.integrityFailure("quick_check failed after migration")
        }
    }

    private func rememberUnlocked(_ write: ProjectMemoryWrite) throws -> (ProjectMemoryRecord, String) {
        let hash = Self.contentHash(kind: write.kind, title: write.title, summary: write.summary, body: write.body, tags: write.tags)
        if let idempotencyKey = write.idempotencyKey,
           let existing = try recordByIdempotencyKeyUnlocked(idempotencyKey) {
            return (existing, "deduplicated")
        }
        if let existing = try recordByHashUnlocked(kind: write.kind, hash: hash) {
            return (existing, "deduplicated")
        }
        let id = UUID().uuidString.lowercased()
        let timestamp = ISO8601.string(from: clock.now())
        try withStatementUnlocked(
            """
            INSERT INTO memory_records(id,project_id,version,kind,title,summary,body,importance,
              confidence,source_kind,source_reference,session_id,created_at,updated_at,last_accessed_at,
              expires_at,content_hash,is_tombstone,schema_version,idempotency_key)
            VALUES(?,?,1,?,?,?,?,?,?,?,?,?,?,?,?,?,?,0,?,?)
            """
        ) { statement in
            bind(statement, 1, id)
            bind(statement, 2, projectID)
            bind(statement, 3, write.kind)
            bind(statement, 4, write.title)
            bind(statement, 5, write.summary)
            bind(statement, 6, write.body)
            sqlite3_bind_double(statement, 7, write.importance)
            sqlite3_bind_double(statement, 8, write.confidence)
            bind(statement, 9, write.sourceKind)
            bind(statement, 10, write.sourceReference)
            bind(statement, 11, write.sessionID)
            bind(statement, 12, timestamp)
            bind(statement, 13, timestamp)
            bind(statement, 14, timestamp)
            bind(statement, 15, write.expiresAt)
            bind(statement, 16, hash)
            sqlite3_bind_int(statement, 17, Int32(Self.schemaVersion))
            bind(statement, 18, write.idempotencyKey)
            try stepDone(statement)
        }
        try replaceTagsUnlocked(recordID: id, tags: write.tags)
        for relatedID in write.relatedIDs {
            if try recordByIDUnlocked(relatedID, includeTombstone: false) != nil {
                try withStatementUnlocked("INSERT OR IGNORE INTO memory_links(project_id,source_id,target_id,relation,created_at) VALUES(?,?,?,?,?)") { statement in
                    bind(statement, 1, projectID); bind(statement, 2, id); bind(statement, 3, relatedID)
                    bind(statement, 4, "related"); bind(statement, 5, timestamp); try stepDone(statement)
                }
            }
        }
        try appendEventUnlocked(action: "inserted", recordID: id, detail: hash)
        guard let value = try recordByIDUnlocked(id, includeTombstone: false) else {
            throw ProjectMemoryError.recordNotFound(id)
        }
        return (value, "inserted")
    }

    private func replaceTagsUnlocked(recordID: String, tags: [String]) throws {
        try withStatementUnlocked("DELETE FROM memory_record_tags WHERE record_id=?") { statement in
            bind(statement, 1, recordID); try stepDone(statement)
        }
        for tag in tags {
            try withStatementUnlocked("INSERT OR IGNORE INTO memory_tags(name) VALUES(?)") { statement in
                bind(statement, 1, tag); try stepDone(statement)
            }
            try withStatementUnlocked("INSERT OR IGNORE INTO memory_record_tags(record_id,tag_id) SELECT ?,id FROM memory_tags WHERE name=?") { statement in
                bind(statement, 1, recordID); bind(statement, 2, tag); try stepDone(statement)
            }
        }
    }

    private func appendEventUnlocked(action: String, recordID: String?, detail: String?) throws {
        try withStatementUnlocked("INSERT INTO event_journal(project_id,record_id,action,detail,created_at) VALUES(?,?,?,?,?)") { statement in
            bind(statement, 1, projectID); bind(statement, 2, recordID); bind(statement, 3, action)
            bind(statement, 4, detail); bind(statement, 5, ISO8601.string(from: clock.now())); try stepDone(statement)
        }
    }

    // MARK: - SQLite helpers

    private static let recordColumns = """
    r.id,r.project_id,r.version,r.kind,r.title,r.summary,r.body,r.importance,r.confidence,
      r.source_kind,r.source_reference,r.session_id,r.created_at,r.updated_at,r.last_accessed_at,
      r.expires_at,r.content_hash,r.is_tombstone,r.schema_version,
      COALESCE((SELECT json_group_array(t.name) FROM memory_record_tags rt JOIN memory_tags t ON t.id=rt.tag_id WHERE rt.record_id=r.id),'[]')
    """
    private static let recordSelect = "SELECT \(recordColumns) FROM memory_records r"

    private func record(_ statement: OpaquePointer) -> ProjectMemoryRecord {
        let tagsJSON = text(statement, 19) ?? "[]"
        let tags = ((try? JSONSerialization.jsonObject(with: Data(tagsJSON.utf8))) as? [String]) ?? []
        return ProjectMemoryRecord(
            id: text(statement, 0) ?? "", projectID: text(statement, 1) ?? "",
            version: Int(sqlite3_column_int(statement, 2)), kind: text(statement, 3) ?? "",
            title: text(statement, 4) ?? "", summary: text(statement, 5) ?? "", body: text(statement, 6),
            tags: tags.sorted(), importance: sqlite3_column_double(statement, 7),
            confidence: sqlite3_column_double(statement, 8), sourceKind: text(statement, 9) ?? "",
            sourceReference: text(statement, 10), sessionID: text(statement, 11),
            createdAt: text(statement, 12) ?? "", updatedAt: text(statement, 13) ?? "",
            lastAccessedAt: text(statement, 14) ?? "", expiresAt: text(statement, 15),
            contentHash: text(statement, 16) ?? "", isTombstone: sqlite3_column_int(statement, 17) != 0,
            schemaVersion: Int(sqlite3_column_int(statement, 18))
        )
    }

    private func recordByIDUnlocked(_ id: String, includeTombstone: Bool) throws -> ProjectMemoryRecord? {
        let suffix = includeTombstone ? "" : " AND is_tombstone=0"
        return try withStatementUnlocked(Self.recordSelect + " WHERE id=? AND project_id=?\(suffix) LIMIT 1") { statement in
            bind(statement, 1, id); bind(statement, 2, projectID)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return record(statement)
        }
    }

    private func recordByHashUnlocked(kind: String, hash: String) throws -> ProjectMemoryRecord? {
        try withStatementUnlocked(Self.recordSelect + " WHERE project_id=? AND kind=? AND content_hash=? AND is_tombstone=0 LIMIT 1") { statement in
            bind(statement, 1, projectID); bind(statement, 2, kind); bind(statement, 3, hash)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return record(statement)
        }
    }

    private func recordByIdempotencyKeyUnlocked(_ key: String) throws -> ProjectMemoryRecord? {
        try withStatementUnlocked(Self.recordSelect + " WHERE project_id=? AND idempotency_key=? LIMIT 1") { statement in
            bind(statement, 1, projectID); bind(statement, 2, key)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return record(statement)
        }
    }

    private func execUnlocked(_ sql: String) throws {
        guard let db else { throw StoreError.openFailed("closed project memory database") }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(error)
            if sqlite3_errcode(db) == SQLITE_BUSY { throw ProjectMemoryError.databaseBusy }
            if sqlite3_errcode(db) == SQLITE_FULL { throw ProjectMemoryError.storageFull }
            throw StoreError.execFailed(message)
        }
    }

    private func transactionUnlocked<T>(_ body: () throws -> T) throws -> T {
        try execUnlocked("BEGIN IMMEDIATE;")
        do {
            let value = try body()
            try execUnlocked("COMMIT;")
            return value
        } catch {
            try? execUnlocked("ROLLBACK;")
            throw error
        }
    }

    private func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        return try withStatementUnlocked(sql, body)
    }

    private func withStatementUnlocked<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        guard let db else { throw StoreError.openFailed("closed project memory database") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError.execFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func queryOne<T>(_ sql: String, _ body: (OpaquePointer) -> T) throws -> T? {
        try withStatement(sql) { statement in sqlite3_step(statement) == SQLITE_ROW ? body(statement) : nil }
    }

    private func scalarInt(_ sql: String, value: String) throws -> Int {
        try withStatement(sql) { statement in
            bind(statement, 1, value)
            return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
        }
    }

    private func pragmaUserVersionUnlocked() throws -> Int {
        try withStatementUnlocked("PRAGMA user_version;") { statement in
            sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int(statement, 0)) : 0
        }
    }

    private func quickCheckUnlocked() throws -> Bool {
        try withStatementUnlocked("PRAGMA quick_check;") { statement in
            sqlite3_step(statement) == SQLITE_ROW && text(statement, 0) == "ok"
        }
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            if result == SQLITE_BUSY { throw ProjectMemoryError.databaseBusy }
            if result == SQLITE_FULL { throw ProjectMemoryError.storageFull }
            throw StoreError.execFailed(db.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite step failed")
        }
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: String?) {
        guard let value else { sqlite3_bind_null(statement, index); return }
        _ = value.withCString { sqlite3_bind_text(statement, index, $0, -1, Self.transient) }
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        sqlite3_column_text(statement, index).map { String(cString: $0) }
    }

    private static func contentHash(kind: String, title: String, summary: String, body: String?, tags: [String]) -> String {
        let normalized = [kind, title, summary, body ?? "", tags.sorted().joined(separator: "\u{1f}")]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .joined(separator: "\u{1e}")
        return JSONSupport.sha256Hex(normalized)
    }

    private static func escapeLike(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static func fileSize(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue ?? 0
    }
}
