// ProjectMemoryRepository.swift
// What: Owns one project-scoped SQLite database and its versioned durable schema.
// How: A serialized connection uses WAL, typed binds, short transactions, and bounded queries.
// Why: Separate databases make project isolation enforceable at the storage boundary.

import Foundation
import SQLite3

struct LegacyContinuityCandidateIdentity: Sendable {
    var pathSHA256: String
    var contentState: String
    var sourceSHA256: String?

    func asDictionary() -> [String: Any] {
        var value: [String: Any] = [
            "path_sha256": pathSHA256,
            "content_state": contentState,
        ]
        if let sourceSHA256 {
            value["source_sha256"] = sourceSHA256
        }
        return value
    }
}

struct LegacyContinuityQuarantineWrite: Sendable {
    let payloadData: Data
    let sourcePath: String?
    let reason: String
    let receiptSourceSHA256: String?

    init(
        payload: [String: Any],
        sourcePath: String?,
        reason: String,
        receiptSourceSHA256: String?
    ) throws {
        let data = try JSONSupport.data(from: payload)
        guard data.count <= ContinuityHandoffV2.maximumEncodedBytes else {
            throw ProjectMemoryError.payloadTooLarge(
                "legacy continuity payload exceeds the quarantine limit"
            )
        }
        let boundedReason = String(reason.prefix(2_048))
        guard !boundedReason.isEmpty else {
            throw ProjectMemoryError.invalidRequest("legacy quarantine reason is required")
        }
        self.payloadData = data
        self.sourcePath = sourcePath
        self.reason = boundedReason
        self.receiptSourceSHA256 = receiptSourceSHA256
    }

    var payloadSHA256: String { JSONSupport.sha256Hex(payloadData) }
}

struct LegacyContinuityImportWrite: Sendable {
    let payloadJSON: String
    let handoffID: String
    let operationID: String
    let schemaVersion: String
    let contentSHA256: String
    let createdAt: String
    let projectGeneration: UInt64?
    let runID: String?
    let predecessorProviderResponseID: String?
    let bootstrapNonce: String?
    let sourceRecordID: String
    let sourcePath: String?
    let receiptSourceSHA256: String

    init(
        payload: [String: Any],
        handoffID: String,
        operationID: String,
        schemaVersion: String,
        contentSHA256: String,
        createdAt: String,
        projectGeneration: UInt64?,
        runID: String?,
        predecessorProviderResponseID: String?,
        bootstrapNonce: String?,
        sourceRecordID: String,
        sourcePath: String?,
        receiptSourceSHA256: String
    ) throws {
        guard UUID(uuidString: handoffID) != nil, UUID(uuidString: operationID) != nil,
              ["1.0", ContinuityHandoffV2.schemaVersion].contains(schemaVersion),
              ISO8601.date(from: createdAt) != nil,
              !sourceRecordID.isEmpty, sourceRecordID.utf8.count <= 1_024 else {
            throw ProjectMemoryError.invalidRequest("legacy continuity identity is invalid")
        }
        guard Self.isLowercaseSHA256(contentSHA256),
              Self.isLowercaseSHA256(receiptSourceSHA256) else {
            throw ProjectMemoryError.invalidRequest("legacy continuity SHA-256 is invalid")
        }
        if schemaVersion == ContinuityHandoffV2.schemaVersion {
            guard let projectGeneration, projectGeneration > 0,
                  let runID, UUID(uuidString: runID) != nil,
                  let bootstrapNonce, !bootstrapNonce.isEmpty else {
                throw ProjectMemoryError.invalidRequest(
                    "legacy V2 record lacks exact generation or run identity"
                )
            }
        }
        let payloadJSON = try JSONSupport.string(from: payload)
        guard payloadJSON.utf8.count <= ContinuityHandoffV2.maximumEncodedBytes else {
            throw ProjectMemoryError.payloadTooLarge("legacy continuity record is oversized")
        }
        self.payloadJSON = payloadJSON
        self.handoffID = handoffID
        self.operationID = operationID
        self.schemaVersion = schemaVersion
        self.contentSHA256 = contentSHA256
        self.createdAt = createdAt
        self.projectGeneration = projectGeneration
        self.runID = runID
        self.predecessorProviderResponseID = predecessorProviderResponseID
        self.bootstrapNonce = bootstrapNonce
        self.sourceRecordID = sourceRecordID
        self.sourcePath = sourcePath
        self.receiptSourceSHA256 = receiptSourceSHA256
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64
            && value == value.lowercased()
            && value.allSatisfy { $0.isHexDigit }
    }
}

enum LegacyContinuityMigrationAction: Sendable {
    case importReadOnly(LegacyContinuityImportWrite)
    case quarantine(LegacyContinuityQuarantineWrite)
    case skip

    var encodedBytes: Int {
        switch self {
        case .importReadOnly(let write): write.payloadJSON.utf8.count
        case .quarantine(let write): write.payloadData.count
        case .skip: 0
        }
    }
}

fileprivate enum LegacyContinuityMigrationOutcome: String, Sendable {
    case imported
    case skipped
    case quarantined
}

struct LegacyContinuityMigrationBatch: Sendable {
    static let maximumCandidateCount = 128
    static let maximumEncodedBytes = maximumCandidateCount
        * ContinuityHandoffV2.maximumEncodedBytes

    let startedAt: String
    let submittedCandidateCount: Int
    let expectedProjectGeneration: UInt64
    let boundRunID: String?
    let identities: [LegacyContinuityCandidateIdentity]
    let actions: [LegacyContinuityMigrationAction]

    init(
        startedAt: String,
        submittedCandidateCount: Int,
        expectedProjectGeneration: UInt64,
        boundRunID: String?,
        identities: [LegacyContinuityCandidateIdentity],
        actions: [LegacyContinuityMigrationAction]
    ) throws {
        guard ISO8601.date(from: startedAt) != nil,
              submittedCandidateCount >= identities.count,
              identities.count == actions.count,
              identities.count <= Self.maximumCandidateCount,
              expectedProjectGeneration > 0,
              expectedProjectGeneration <= UInt64(Int64.max),
              boundRunID.map({ UUID(uuidString: $0) != nil }) ?? true else {
            throw ProjectMemoryError.invalidRequest("legacy migration batch identity is invalid")
        }
        let contentStates = Set([
            "unreadable_or_invalid", "not_regular", "empty_or_oversized", "read",
        ])
        for identity in identities {
            guard Self.isLowercaseSHA256(identity.pathSHA256),
                  contentStates.contains(identity.contentState),
                  identity.sourceSHA256.map(Self.isLowercaseSHA256) ?? true,
                  (identity.contentState == "read") == (identity.sourceSHA256 != nil) else {
                throw ProjectMemoryError.invalidRequest(
                    "legacy migration candidate identity is invalid"
                )
            }
        }
        var encodedBytes = 0
        for action in actions {
            let (sum, overflow) = encodedBytes.addingReportingOverflow(action.encodedBytes)
            guard !overflow, sum <= Self.maximumEncodedBytes else {
                throw ProjectMemoryError.payloadTooLarge(
                    "legacy migration batch exceeds the aggregate payload limit"
                )
            }
            encodedBytes = sum
        }
        self.startedAt = startedAt
        self.submittedCandidateCount = submittedCandidateCount
        self.expectedProjectGeneration = expectedProjectGeneration
        self.boundRunID = boundRunID
        self.identities = identities
        self.actions = actions
    }

    func fingerprint(projectID: String) throws -> String {
        JSONSupport.sha256Hex(
            try JSONSupport.canonicalJSON([
                "schema_version": 1,
                "project_id": projectID,
                "expected_project_generation": Int64(expectedProjectGeneration),
                "bound_run_id": boundRunID ?? NSNull(),
                "submitted_candidate_count": submittedCandidateCount,
                "selected_candidates": identities.map { $0.asDictionary() },
            ])
        )
    }

    fileprivate func outcomeLedgerSHA256(
        _ outcomes: [LegacyContinuityMigrationOutcome]
    ) throws -> String {
        guard outcomes.count == identities.count else {
            throw ProjectMemoryError.integrityFailure(
                "legacy migration outcome count does not match its candidate batch"
            )
        }
        let candidates: [[String: Any]] = zip(identities, outcomes).map { pair in
            var candidate = pair.0.asDictionary()
            candidate["outcome"] = pair.1.rawValue
            return candidate
        }
        return JSONSupport.sha256Hex(
            try JSONSupport.canonicalJSON([
                "schema_version": 1,
                "candidates": candidates,
            ])
        )
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64
            && value == value.lowercased()
            && value.allSatisfy { $0.isHexDigit }
    }
}

public final class ProjectMemoryRepository: @unchecked Sendable {
    public static let schemaVersion = 2
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public let projectID: String
    public let directory: URL
    public let databaseURL: URL
    public private(set) var supportsFTS5 = false
    private let clock: any Clock
    private let enableFTS5: Bool
    private let lock = NSLock()
    private var db: OpaquePointer?
    private var openRegistration: SQLiteOpenRegistration?

    public init(
        projectID: String,
        directory: URL,
        clock: any Clock = SystemClock(),
        enableFTS5: Bool = true
    ) throws {
        guard UUID(uuidString: projectID) != nil else {
            throw ProjectMemoryError.invalidRequest("project_id must be a UUID")
        }
        let standardizedDirectory = directory.standardizedFileURL
        self.projectID = projectID
        self.directory = standardizedDirectory
        self.databaseURL = standardizedDirectory.appendingPathComponent("memory.sqlite3")
        self.clock = clock
        self.enableFTS5 = enableFTS5
        try FileManager.default.createDirectory(
            at: standardizedDirectory,
            withIntermediateDirectories: true
        )
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: standardizedDirectory.path
        )
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
            VerifiedMigrationBackup.unregisterOpenDatabase(openRegistration)
            openRegistration = nil
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
                  acknowledged_handoff_id,created_at,updated_at,last_error,retry_at,state_checksum,
                  schema_version,quarantine_state,migration_source
                ) VALUES(?,?,?,NULL,?, ?,0,?,?,NULL,NULL,?,?,NULL,NULL,?,1,NULL,'compatibility_v1')
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
                  handoff_id,project_id,operation_id,payload_json,content_sha256,created_at,
                  schema_version,quarantine_state,migration_source
                ) VALUES(?,?,?,?,?,?,'1.0',NULL,'compatibility_v1')
                ON CONFLICT(handoff_id) DO UPDATE SET
                  payload_json=excluded.payload_json,content_sha256=excluded.content_sha256,
                  schema_version='1.0',quarantine_state=NULL,
                  migration_source='compatibility_v1'
                WHERE continuity_handoffs.operation_id=excluded.operation_id
                  AND continuity_handoffs.project_id=excluded.project_id
                """
            ) { statement in
                bind(statement, 1, validated.handoffID); bind(statement, 2, projectID)
                bind(statement, 3, validated.operationID); bind(statement, 4, payload)
                bind(statement, 5, validated.contentSHA256); bind(statement, 6, validated.createdAt)
                try stepDone(statement)
            }
            guard sqlite3_changes(db) == 1 else {
                throw ProjectMemoryError.conflict("handoff identifier is already bound to a different operation")
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
            "UPDATE rollover_operations SET last_error=?,retry_at=?,updated_at=? WHERE operation_id=? AND project_id=? AND quarantine_state IS NULL"
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

    public func continuityOperation(idempotencyKey: String) throws -> ContinuityOperation? {
        try withStatement(
            Self.continuityOperationSelect
                + " WHERE project_id=? AND idempotency_key=? AND schema_version=1"
                + " AND quarantine_state IS NULL LIMIT 1"
        ) { statement in
            bind(statement, 1, projectID)
            bind(statement, 2, idempotencyKey)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return continuityOperation(statement)
        }
    }

    public func continuityActiveOperation() throws -> ContinuityOperation? {
        try withStatement(
            Self.continuityOperationSelect
                + " WHERE project_id=? AND state<>'predecessorSealed'"
                + " AND quarantine_state IS NULL ORDER BY updated_at DESC LIMIT 1"
        ) { statement in
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

    // MARK: - Project continuity V2

    public func continuityCreateOperationV2(
        handoff: ContinuityHandoffV2,
        predecessorSessionID: String,
        predecessorProviderResponseID: String?,
        adapterID: String,
        idempotencyKey: String,
        budgetObservationID: String? = nil
    ) throws -> ContinuityOperationV2 {
        let validated = try handoff.validated()
        guard validated.projectID == projectID,
              let generation = validated.projectGeneration,
              let runID = validated.runID,
              let nonce = validated.bootstrapNonce else {
            throw ProjectMemoryError.projectScopeMismatch
        }
        let handoffPredecessorResponse: String?
        if validated.predecessorSession["provider_response_id"] is NSNull {
            handoffPredecessorResponse = nil
        } else if let value = validated.predecessorSession["provider_response_id"] as? String {
            handoffPredecessorResponse = value
        } else {
            throw ProjectMemoryError.invalidRequest("provider_response_id must be a string or null")
        }
        guard !predecessorSessionID.isEmpty, !adapterID.isEmpty, !idempotencyKey.isEmpty else {
            throw ProjectMemoryError.invalidRequest("V2 operation identity is incomplete")
        }
        guard validated.predecessorSession["session_id"] as? String == predecessorSessionID,
              validated.predecessorSession["adapter_id"] as? String == adapterID,
              handoffPredecessorResponse == predecessorProviderResponseID else {
            throw ProjectMemoryError.conflict(
                "V2 operation predecessor identity does not match its handoff"
            )
        }
        let payload = try JSONSupport.string(from: validated.asDictionary())
        lock.lock()
        let operation: ContinuityOperationV2
        do {
            operation = try transactionUnlocked {
                if let existing = try continuityOperationV2ByIdempotencyUnlocked(idempotencyKey) {
                    guard existing.operationID == validated.operationID,
                          existing.handoffID == validated.handoffID,
                          existing.projectGeneration == generation,
                          existing.runID == runID,
                          existing.predecessorSessionID == predecessorSessionID,
                          existing.predecessorProviderResponseID == predecessorProviderResponseID,
                          existing.adapterID == adapterID,
                          existing.bootstrapNonce == nonce else {
                        throw ProjectMemoryError.conflict("V2 idempotency key is already bound")
                    }
                    try continuityPersistHandoffV2Unlocked(
                        validated,
                        payload: payload,
                        generation: generation,
                        runID: runID,
                        predecessorResponseID: handoffPredecessorResponse
                    )
                    return existing
                }
                if let active = try continuityActiveOperationUnlocked() {
                    throw ProjectMemoryError.conflict("rollover already active: \(active.operationID)")
                }
                let timestamp = ISO8601.string(from: clock.now())
                let checksum = Self.continuityChecksumV2(
                    operationID: validated.operationID,
                    projectGeneration: generation,
                    runID: runID,
                    state: .active,
                    successorSessionID: nil,
                    successorProviderResponseID: nil,
                    handoffID: validated.handoffID,
                    attempt: 0
                )
                try withStatementUnlocked(
                    """
                    INSERT INTO rollover_operations(
                      operation_id,project_id,predecessor_session_id,successor_session_id,handoff_id,
                      state,attempt,adapter_id,idempotency_key,acknowledged_session_id,
                      acknowledged_handoff_id,created_at,updated_at,last_error,retry_at,state_checksum,
                      schema_version,project_generation,run_id,predecessor_provider_response_id,
                      successor_provider_response_id,bootstrap_nonce,acknowledgement_sha256,
                      budget_observation_id,continuation_issued,quarantine_state,migration_source,
                      legacy_record_id
                    ) VALUES(?,?,?,NULL,?, 'active',0,?,?,NULL,NULL,?,?,NULL,NULL,?,
                             2,?,?,?,NULL,?,NULL,?,0,NULL,NULL,NULL)
                    """
                ) { statement in
                    bind(statement, 1, validated.operationID)
                    bind(statement, 2, projectID)
                    bind(statement, 3, predecessorSessionID)
                    bind(statement, 4, validated.handoffID)
                    bind(statement, 5, adapterID)
                    bind(statement, 6, idempotencyKey)
                    bind(statement, 7, timestamp)
                    bind(statement, 8, timestamp)
                    bind(statement, 9, checksum)
                    sqlite3_bind_int64(statement, 10, Int64(generation))
                    bind(statement, 11, runID)
                    bind(statement, 12, predecessorProviderResponseID)
                    bind(statement, 13, nonce)
                    bind(statement, 14, budgetObservationID)
                    try stepDone(statement)
                }
                try appendTransitionV2Unlocked(
                    operationID: validated.operationID,
                    projectGeneration: generation,
                    runID: runID,
                    from: nil,
                    to: .active,
                    attempt: 0,
                    adapterID: adapterID,
                    successorProviderResponseID: nil,
                    evidence: "v2_operation_created",
                    checksum: checksum
                )
                try continuityPersistHandoffV2Unlocked(
                    validated,
                    payload: payload,
                    generation: generation,
                    runID: runID,
                    predecessorResponseID: handoffPredecessorResponse
                )
                guard let created = try continuityOperationV2Unlocked(validated.operationID) else {
                    throw ProjectMemoryError.integrityFailure("created V2 rollover operation is unreadable")
                }
                return created
            }
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }
        try writeHandoffProjection(validated)
        try writeOperationProjection(operation)
        return operation
    }

    public func continuityStoreHandoffV2(_ handoff: ContinuityHandoffV2) throws {
        let validated = try handoff.validated()
        guard validated.projectID == projectID,
              let generation = validated.projectGeneration,
              let runID = validated.runID,
              validated.bootstrapNonce != nil else {
            throw ProjectMemoryError.projectScopeMismatch
        }
        let predecessorResponseID: String?
        if validated.predecessorSession["provider_response_id"] is NSNull {
            predecessorResponseID = nil
        } else if let value = validated.predecessorSession["provider_response_id"] as? String {
            predecessorResponseID = value
        } else {
            throw ProjectMemoryError.invalidRequest("provider_response_id must be a string or null")
        }
        let payload = try JSONSupport.string(from: validated.asDictionary())
        lock.lock()
        do {
            try transactionUnlocked {
                try continuityPersistHandoffV2Unlocked(
                    validated,
                    payload: payload,
                    generation: generation,
                    runID: runID,
                    predecessorResponseID: predecessorResponseID
                )
            }
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }
        try writeHandoffProjection(validated)
    }

    public func continuityHandoffV2(id: String) throws -> ContinuityHandoffV2? {
        try withStatement(
            """
            SELECT payload_json,content_sha256 FROM continuity_handoffs
            WHERE handoff_id=? AND project_id=? AND schema_version='2.0'
              AND quarantine_state IS NULL LIMIT 1
            """
        ) { statement in
            bind(statement, 1, id)
            bind(statement, 2, projectID)
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let payload = text(statement, 0),
                  let data = payload.data(using: .utf8),
                  let object = try? JSONSupport.object(from: data),
                  let handoff = ContinuityHandoffV2.fromDictionary(object),
                  handoff.contentSHA256 == text(statement, 1),
                  handoff.calculatedSHA256() == handoff.contentSHA256,
                  (try? handoff.validated()) != nil else {
                return nil
            }
            return handoff
        }
    }

    public func continuityOperationV2(id: String) throws -> ContinuityOperationV2? {
        try withStatement(
            Self.continuityOperationV2Select
                + " WHERE operation_id=? AND project_id=? AND schema_version=2 LIMIT 1"
        ) { statement in
            bind(statement, 1, id)
            bind(statement, 2, projectID)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return try continuityOperationV2(statement)
        }
    }

    public func continuityOperationV2(
        idempotencyKey: String
    ) throws -> ContinuityOperationV2? {
        try withStatement(
            Self.continuityOperationV2Select
                + " WHERE project_id=? AND idempotency_key=? AND schema_version=2"
                + " AND quarantine_state IS NULL LIMIT 1"
        ) { statement in
            bind(statement, 1, projectID)
            bind(statement, 2, idempotencyKey)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return try continuityOperationV2(statement)
        }
    }

    public func continuityActiveOperationV2() throws -> ContinuityOperationV2? {
        try withStatement(
            Self.continuityOperationV2Select
                + " WHERE project_id=? AND schema_version=2 AND quarantine_state IS NULL"
                + " AND state<>'predecessorSealed' ORDER BY updated_at DESC LIMIT 1"
        ) { statement in
            bind(statement, 1, projectID)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return try continuityOperationV2(statement)
        }
    }

    public func continuityTransitionV2(
        operationID: String,
        expected: ContinuityState,
        to next: ContinuityState,
        successorSessionID: String? = nil,
        successorProviderResponseID: String? = nil,
        evidence: String? = nil
    ) throws -> ContinuityOperationV2 {
        guard expected.next == next else {
            throw ProjectMemoryError.invalidRequest("invalid V2 transition \(expected.rawValue) -> \(next.rawValue)")
        }
        lock.lock()
        let operation: ContinuityOperationV2
        do {
            operation = try transactionUnlocked {
                guard let current = try continuityOperationV2Unlocked(operationID) else {
                    throw ProjectMemoryError.recordNotFound(operationID)
                }
                if current.state == next {
                    if let successorSessionID,
                       current.successorSessionID != successorSessionID {
                        throw ProjectMemoryError.conflict(
                            "V2 transition replay names a different successor"
                        )
                    }
                    if let successorProviderResponseID,
                       current.successorProviderResponseID != successorProviderResponseID {
                        throw ProjectMemoryError.conflict(
                            "V2 transition replay names a different provider response"
                        )
                    }
                    return current
                }
                guard current.state == expected else {
                    throw ProjectMemoryError.conflict(
                        "expected \(expected.rawValue), current \(current.state.rawValue)"
                    )
                }
                let successor = successorSessionID ?? current.successorSessionID
                let providerResponse = successorProviderResponseID ?? current.successorProviderResponseID
                if next == .successorCreated, (successor == nil || providerResponse == nil) {
                    throw ProjectMemoryError.invalidRequest(
                        "V2 successor and provider response identifiers are required"
                    )
                }
                if next == .checkpointPersisted,
                   !(try continuityV2HandoffExistsUnlocked(id: current.handoffID)) {
                    throw ProjectMemoryError.integrityFailure("V2 checkpoint handoff is not durable")
                }
                let attempt = current.attempt + 1
                let checksum = Self.continuityChecksumV2(
                    operationID: current.operationID,
                    projectGeneration: current.projectGeneration,
                    runID: current.runID,
                    state: next,
                    successorSessionID: successor,
                    successorProviderResponseID: providerResponse,
                    handoffID: current.handoffID,
                    attempt: attempt
                )
                let timestamp = ISO8601.string(from: clock.now())
                try withStatementUnlocked(
                    """
                    UPDATE rollover_operations SET state=?,attempt=?,successor_session_id=?,
                      successor_provider_response_id=?,updated_at=?,last_error=NULL,retry_at=NULL,
                      state_checksum=? WHERE operation_id=? AND project_id=?
                      AND schema_version=2 AND state=? AND quarantine_state IS NULL
                    """
                ) { statement in
                    bind(statement, 1, next.rawValue)
                    sqlite3_bind_int(statement, 2, Int32(attempt))
                    bind(statement, 3, successor)
                    bind(statement, 4, providerResponse)
                    bind(statement, 5, timestamp)
                    bind(statement, 6, checksum)
                    bind(statement, 7, operationID)
                    bind(statement, 8, projectID)
                    bind(statement, 9, expected.rawValue)
                    try stepDone(statement)
                }
                guard sqlite3_changes(db) == 1 else {
                    throw ProjectMemoryError.conflict("V2 transition compare-and-set failed")
                }
                try appendTransitionV2Unlocked(
                    operationID: operationID,
                    projectGeneration: current.projectGeneration,
                    runID: current.runID,
                    from: expected,
                    to: next,
                    attempt: attempt,
                    adapterID: current.adapterID,
                    successorProviderResponseID: providerResponse,
                    evidence: evidence,
                    checksum: checksum
                )
                if next == .predecessorSealed, let successor {
                    try withStatementUnlocked(
                        """
                        INSERT INTO project_active_sessions(project_id,session_id,updated_at)
                        VALUES(?,?,?) ON CONFLICT(project_id) DO UPDATE SET
                          session_id=excluded.session_id,updated_at=excluded.updated_at
                        """
                    ) { statement in
                        bind(statement, 1, projectID)
                        bind(statement, 2, successor)
                        bind(statement, 3, timestamp)
                        try stepDone(statement)
                    }
                }
                guard let updated = try continuityOperationV2Unlocked(operationID) else {
                    throw ProjectMemoryError.integrityFailure("V2 transition result is unreadable")
                }
                return updated
            }
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }
        try writeOperationProjection(operation)
        return operation
    }

    public func continuityAcknowledgeV2(
        operationID: String,
        receipt: BootstrapReceipt
    ) throws -> ContinuityOperationV2 {
        guard let preflight = try continuityOperationV2(id: operationID),
              receipt.acknowledgement.operationID.uuidString.caseInsensitiveCompare(operationID) == .orderedSame,
              let handoff = try continuityHandoffV2(id: preflight.handoffID) else {
            throw ProjectMemoryError.integrityFailure("V2 handoff is missing or invalid")
        }
        try receipt.acknowledgement.validate(handoff: handoff)
        let acknowledgementSHA256 = Self.bootstrapAcknowledgementSHA256(receipt.acknowledgement)
        lock.lock()
        let operation: ContinuityOperationV2
        do {
            operation = try transactionUnlocked {
                guard let current = try continuityOperationV2Unlocked(operationID) else {
                    throw ProjectMemoryError.recordNotFound(operationID)
                }
                if current.state == .successorAcknowledged || current.state == .predecessorSealed {
                    guard current.acknowledgedHandoffID == handoff.handoffID,
                          current.acknowledgedSessionID == receipt.internalSessionID,
                          current.acknowledgementSHA256 == acknowledgementSHA256 else {
                        throw ProjectMemoryError.conflict("a different V2 acknowledgement is committed")
                    }
                    return current
                }
                guard current.state == .successorBootstrapping,
                      current.projectGeneration == handoff.projectGeneration,
                      current.runID == handoff.runID,
                      current.handoffID == handoff.handoffID,
                      current.bootstrapNonce == handoff.bootstrapNonce,
                      current.adapterID == receipt.adapterID,
                      current.successorSessionID == receipt.internalSessionID,
                      current.successorProviderResponseID == receipt.providerResponseID else {
                    throw ProjectMemoryError.conflict("V2 acknowledgement does not match the durable operation")
                }
                let attempt = current.attempt + 1
                let next = ContinuityState.successorAcknowledged
                let checksum = Self.continuityChecksumV2(
                    operationID: current.operationID,
                    projectGeneration: current.projectGeneration,
                    runID: current.runID,
                    state: next,
                    successorSessionID: receipt.internalSessionID,
                    successorProviderResponseID: receipt.providerResponseID,
                    handoffID: current.handoffID,
                    attempt: attempt
                )
                let timestamp = ISO8601.string(from: clock.now())
                try withStatementUnlocked(
                    """
                    UPDATE rollover_operations SET state=?,attempt=?,acknowledged_session_id=?,
                      acknowledged_handoff_id=?,acknowledgement_sha256=?,updated_at=?,
                      state_checksum=?,last_error=NULL,retry_at=NULL
                    WHERE operation_id=? AND project_id=? AND schema_version=2
                      AND state='successorBootstrapping' AND quarantine_state IS NULL
                    """
                ) { statement in
                    bind(statement, 1, next.rawValue)
                    sqlite3_bind_int(statement, 2, Int32(attempt))
                    bind(statement, 3, receipt.internalSessionID)
                    bind(statement, 4, handoff.handoffID)
                    bind(statement, 5, acknowledgementSHA256)
                    bind(statement, 6, timestamp)
                    bind(statement, 7, checksum)
                    bind(statement, 8, operationID)
                    bind(statement, 9, projectID)
                    try stepDone(statement)
                }
                guard sqlite3_changes(db) == 1 else {
                    throw ProjectMemoryError.conflict("V2 acknowledgement compare-and-set failed")
                }
                try withStatementUnlocked(
                    """
                    UPDATE continuity_handoffs SET acknowledged_session_id=?,acknowledged_at=?,
                      acknowledgement_sha256=? WHERE handoff_id=? AND project_id=?
                      AND schema_version='2.0' AND quarantine_state IS NULL
                    """
                ) { statement in
                    bind(statement, 1, receipt.internalSessionID)
                    bind(statement, 2, timestamp)
                    bind(statement, 3, acknowledgementSHA256)
                    bind(statement, 4, handoff.handoffID)
                    bind(statement, 5, projectID)
                    try stepDone(statement)
                }
                try appendTransitionV2Unlocked(
                    operationID: operationID,
                    projectGeneration: current.projectGeneration,
                    runID: current.runID,
                    from: .successorBootstrapping,
                    to: next,
                    attempt: attempt,
                    adapterID: receipt.adapterID,
                    successorProviderResponseID: receipt.providerResponseID,
                    evidence: acknowledgementSHA256,
                    checksum: checksum
                )
                guard let updated = try continuityOperationV2Unlocked(operationID) else {
                    throw ProjectMemoryError.integrityFailure("V2 acknowledgement result is unreadable")
                }
                return updated
            }
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }
        try writeOperationProjection(operation)
        return operation
    }

    @discardableResult
    public func continuityMarkContinuationIssuedV2(operationID: String) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return try transactionUnlocked {
            guard let operation = try continuityOperationV2Unlocked(operationID) else {
                throw ProjectMemoryError.recordNotFound(operationID)
            }
            guard operation.state == .predecessorSealed else {
                throw ProjectMemoryError.conflict("automatic continuation requires a sealed predecessor")
            }
            if operation.continuationIssued { return false }
            let timestamp = ISO8601.string(from: clock.now())
            try withStatementUnlocked(
                """
                UPDATE rollover_operations SET continuation_issued=1,updated_at=?
                WHERE operation_id=? AND project_id=? AND schema_version=2
                  AND continuation_issued=0 AND state='predecessorSealed'
                """
            ) { statement in
                bind(statement, 1, timestamp)
                bind(statement, 2, operationID)
                bind(statement, 3, projectID)
                try stepDone(statement)
            }
            guard sqlite3_changes(db) == 1 else {
                throw ProjectMemoryError.conflict("automatic continuation compare-and-set failed")
            }
            try withStatementUnlocked(
                """
                UPDATE continuity_handoffs SET continuation_issued=1
                WHERE handoff_id=? AND project_id=? AND schema_version='2.0'
                """
            ) { statement in
                bind(statement, 1, operation.handoffID)
                bind(statement, 2, projectID)
                try stepDone(statement)
            }
            return true
        }
    }

    private struct LegacyQuarantineProjection {
        let identifier: String
        let data: Data
    }

    private struct LegacyMigrationCommit {
        let receipt: LegacyContinuityMigrationReceipt
        let projections: [LegacyQuarantineProjection]
    }

    private struct LegacyMigrationReceiptReadback {
        let receipt: LegacyContinuityMigrationReceipt
        let projections: [LegacyQuarantineProjection]
    }

    private enum LegacyImportDisposition: Equatable {
        case missing
        case exact
        case collision
    }

    @discardableResult
    public func continuityQuarantineLegacy(
        payload: [String: Any],
        sourcePath: String?,
        reason: String
    ) throws -> String {
        let write = try LegacyContinuityQuarantineWrite(
            payload: payload,
            sourcePath: sourcePath,
            reason: reason,
            receiptSourceSHA256: nil
        )
        lock.lock()
        let projection: LegacyQuarantineProjection
        do {
            projection = try transactionUnlocked {
                try quarantineLegacyUnlocked(write, insertIfMissing: true)
            }
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }
        try materializeLegacyQuarantineProjections([projection])
        return projection.identifier
    }

    /// Imports an unambiguously project-scoped legacy record for read-only diagnostics.
    /// Imported rows are always quarantined from managed selection, even when their
    /// payload already uses the V2 envelope.
    @discardableResult
    public func continuityImportLegacyReadOnly(
        payload: [String: Any],
        handoffID: String,
        operationID: String,
        schemaVersion: String,
        contentSHA256: String,
        createdAt: String,
        projectGeneration: UInt64?,
        runID: String?,
        predecessorProviderResponseID: String?,
        bootstrapNonce: String?,
        sourceRecordID: String
    ) throws -> Bool {
        let payloadSourceSHA256 = JSONSupport.sha256Hex(try JSONSupport.data(from: payload))
        let write = try LegacyContinuityImportWrite(
            payload: payload,
            handoffID: handoffID,
            operationID: operationID,
            schemaVersion: schemaVersion,
            contentSHA256: contentSHA256,
            createdAt: createdAt,
            projectGeneration: projectGeneration,
            runID: runID,
            predecessorProviderResponseID: predecessorProviderResponseID,
            bootstrapNonce: bootstrapNonce,
            sourceRecordID: sourceRecordID,
            sourcePath: nil,
            receiptSourceSHA256: payloadSourceSHA256
        )
        lock.lock()
        defer { lock.unlock() }
        return try transactionUnlocked { try importLegacyUnlocked(write) }
    }

    func continuityApplyLegacyMigration(
        _ batch: LegacyContinuityMigrationBatch
    ) throws -> LegacyContinuityMigrationReceipt {
        let fingerprint = try batch.fingerprint(projectID: projectID)
        let receiptID = legacyMigrationReceiptID(fingerprint: fingerprint)
        let commit: LegacyMigrationCommit
        lock.lock()
        var changedSynchronousMode = false
        do {
            try execUnlocked("PRAGMA synchronous=FULL;")
            changedSynchronousMode = true
            commit = try transactionUnlocked {
                if let readback = try legacyMigrationReceiptUnlocked(
                    receiptID: receiptID,
                    fingerprint: fingerprint,
                    expectedBatch: batch
                ) {
                    return LegacyMigrationCommit(
                        receipt: readback.receipt,
                        projections: readback.projections
                    )
                }

                var importedCount = 0
                var skippedCount = batch.submittedCandidateCount - batch.actions.count
                var quarantinedCount = 0
                var importedHashes: [String] = []
                var quarantineHashes: [String] = []
                var outcomes: [LegacyContinuityMigrationOutcome] = []
                outcomes.reserveCapacity(batch.actions.count)

                for action in batch.actions {
                    switch action {
                    case .skip:
                        skippedCount += 1
                        outcomes.append(.skipped)
                    case .quarantine(let write):
                        _ = try quarantineLegacyUnlocked(write, insertIfMissing: true)
                        quarantinedCount += 1
                        outcomes.append(.quarantined)
                        if let sourceSHA256 = write.receiptSourceSHA256 {
                            quarantineHashes.append(sourceSHA256)
                        }
                    case .importReadOnly(let write):
                        do {
                            if try importLegacyUnlocked(write) {
                                importedCount += 1
                                importedHashes.append(write.receiptSourceSHA256)
                                outcomes.append(.imported)
                            } else {
                                try verifyCommittedLegacyImportUnlocked(
                                    write,
                                    allowSourceAlias: true
                                )
                                skippedCount += 1
                                outcomes.append(.skipped)
                            }
                        } catch let error as ProjectMemoryError {
                            guard case .conflict(let reason) = error,
                                  reason == "legacy continuity identifier collision" else {
                                throw error
                            }
                            let fallback = try importFailureQuarantine(
                                write,
                                error: error
                            )
                            _ = try quarantineLegacyUnlocked(fallback, insertIfMissing: true)
                            quarantinedCount += 1
                            outcomes.append(.quarantined)
                            quarantineHashes.append(write.receiptSourceSHA256)
                        }
                    }
                }

                let details = try legacyMigrationOutcomeDetails(
                    batch: batch,
                    outcomes: outcomes,
                    fingerprint: fingerprint
                )
                guard details["imported_source_sha256"] as? [String] == importedHashes,
                      details["quarantined_source_sha256"] as? [String] == quarantineHashes else {
                    throw ProjectMemoryError.integrityFailure(
                        "legacy migration staged hashes do not match its outcomes"
                    )
                }
                let detailsJSON = try legacyMigrationDetailsJSON(details)
                try insertLegacyMigrationReceiptUnlocked(
                    receiptID: receiptID,
                    importedCount: importedCount,
                    skippedCount: skippedCount,
                    quarantinedCount: quarantinedCount,
                    detailsJSON: detailsJSON,
                    startedAt: batch.startedAt,
                    completedAt: ISO8601.string(from: clock.now())
                )
                guard let readback = try legacyMigrationReceiptUnlocked(
                    receiptID: receiptID,
                    fingerprint: fingerprint,
                    expectedBatch: batch
                ) else {
                    throw ProjectMemoryError.integrityFailure(
                        "legacy migration receipt could not be read back"
                    )
                }
                return LegacyMigrationCommit(
                    receipt: readback.receipt,
                    projections: readback.projections
                )
            }
            if changedSynchronousMode { try? execUnlocked("PRAGMA synchronous=NORMAL;") }
            lock.unlock()
        } catch {
            if changedSynchronousMode { try? execUnlocked("PRAGMA synchronous=NORMAL;") }
            lock.unlock()
            throw error
        }
        try materializeLegacyQuarantineProjections(commit.projections)
        return commit.receipt
    }

    public func continuityRecordLegacyMigration(
        importedCount: Int,
        skippedCount: Int,
        quarantinedCount: Int,
        startedAt: String,
        migrationFingerprintSHA256: String,
        details: [String: Any]
    ) throws -> LegacyContinuityMigrationReceipt {
        guard importedCount >= 0, skippedCount >= 0, quarantinedCount >= 0,
              ISO8601.date(from: startedAt) != nil,
              migrationFingerprintSHA256.count == 64,
              migrationFingerprintSHA256.allSatisfy({ $0.isHexDigit }),
              migrationFingerprintSHA256 == migrationFingerprintSHA256.lowercased() else {
            throw ProjectMemoryError.invalidRequest(
                "legacy migration counts, timestamp, or fingerprint are invalid"
            )
        }
        let detailsJSON = try legacyMigrationDetailsJSON(details)
        let receiptID = legacyMigrationReceiptID(fingerprint: migrationFingerprintSHA256)
        lock.lock()
        defer { lock.unlock() }
        return try transactionUnlocked {
            if let existing = try legacyMigrationReceiptUnlocked(
                receiptID: receiptID,
                fingerprint: migrationFingerprintSHA256
            ) {
                return existing.receipt
            }
            try insertLegacyMigrationReceiptUnlocked(
                receiptID: receiptID,
                importedCount: importedCount,
                skippedCount: skippedCount,
                quarantinedCount: quarantinedCount,
                detailsJSON: detailsJSON,
                startedAt: startedAt,
                completedAt: ISO8601.string(from: clock.now())
            )
            guard let readback = try legacyMigrationReceiptUnlocked(
                receiptID: receiptID,
                fingerprint: migrationFingerprintSHA256
            ) else {
                throw ProjectMemoryError.integrityFailure(
                    "legacy migration receipt could not be read back"
                )
            }
            return readback.receipt
        }
    }

    private func quarantineLegacyUnlocked(
        _ write: LegacyContinuityQuarantineWrite,
        insertIfMissing: Bool
    ) throws -> LegacyQuarantineProjection {
        let existing = try withStatementUnlocked(
            """
            SELECT quarantine_id,payload_json FROM legacy_continuity_quarantine
            WHERE project_id=? AND source_sha256=? LIMIT 1
            """
        ) { statement -> (String, String)? in
            bind(statement, 1, projectID)
            bind(statement, 2, write.payloadSHA256)
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let identifier = text(statement, 0),
                  let payloadJSON = text(statement, 1) else { return nil }
            return (identifier, payloadJSON)
        }
        if let existing {
            guard UUID(uuidString: existing.0) != nil,
                  Data(existing.1.utf8) == write.payloadData else {
                throw ProjectMemoryError.integrityFailure(
                    "legacy quarantine row does not match its payload identity"
                )
            }
            return LegacyQuarantineProjection(identifier: existing.0, data: write.payloadData)
        }
        guard insertIfMissing else {
            throw ProjectMemoryError.integrityFailure(
                "legacy migration receipt is missing a quarantined side effect"
            )
        }
        let identifier = UUID().uuidString.lowercased()
        try withStatementUnlocked(
            """
            INSERT INTO legacy_continuity_quarantine(
              quarantine_id,project_id,source_path,source_sha256,reason,payload_json,created_at
            ) VALUES(?,?,?,?,?,?,?)
            """
        ) { statement in
            bind(statement, 1, identifier)
            bind(statement, 2, projectID)
            bind(statement, 3, write.sourcePath.map { String($0.prefix(4_096)) })
            bind(statement, 4, write.payloadSHA256)
            bind(statement, 5, write.reason)
            bind(statement, 6, String(decoding: write.payloadData, as: UTF8.self))
            bind(statement, 7, ISO8601.string(from: clock.now()))
            try stepDone(statement)
        }
        return LegacyQuarantineProjection(identifier: identifier, data: write.payloadData)
    }

    private func importDispositionUnlocked(
        _ write: LegacyContinuityImportWrite
    ) throws -> LegacyImportDisposition {
        let existing = try withStatementUnlocked(
            """
            SELECT handoff_id,operation_id,content_sha256 FROM continuity_handoffs
            WHERE (handoff_id=? OR operation_id=?) AND project_id=? LIMIT 1
            """
        ) { statement -> (String, String, String)? in
            bind(statement, 1, write.handoffID)
            bind(statement, 2, write.operationID)
            bind(statement, 3, projectID)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return (
                text(statement, 0) ?? "",
                text(statement, 1) ?? "",
                text(statement, 2) ?? ""
            )
        }
        guard let existing else { return .missing }
        return existing.0 == write.handoffID
            && existing.1 == write.operationID
            && existing.2 == write.contentSHA256 ? .exact : .collision
    }

    private func importLegacyUnlocked(_ write: LegacyContinuityImportWrite) throws -> Bool {
        switch try importDispositionUnlocked(write) {
        case .exact:
            return false
        case .collision:
            throw ProjectMemoryError.conflict("legacy continuity identifier collision")
        case .missing:
            break
        }
        try withStatementUnlocked(
            """
            INSERT INTO continuity_handoffs(
              handoff_id,project_id,operation_id,payload_json,content_sha256,created_at,
              schema_version,project_generation,run_id,predecessor_provider_response_id,
              bootstrap_nonce,continuation_issued,quarantine_state,migration_source,
              legacy_record_id
            ) VALUES(?,?,?,?,?,?,?,?,?,?,?,0,'legacy_read_only','legacy_global',?)
            """
        ) { statement in
            bind(statement, 1, write.handoffID)
            bind(statement, 2, projectID)
            bind(statement, 3, write.operationID)
            bind(statement, 4, write.payloadJSON)
            bind(statement, 5, write.contentSHA256)
            bind(statement, 6, write.createdAt)
            bind(statement, 7, write.schemaVersion)
            if let projectGeneration = write.projectGeneration {
                sqlite3_bind_int64(statement, 8, Int64(projectGeneration))
            } else {
                sqlite3_bind_null(statement, 8)
            }
            bind(statement, 9, write.runID)
            bind(statement, 10, write.predecessorProviderResponseID)
            bind(statement, 11, write.bootstrapNonce)
            bind(statement, 12, write.sourceRecordID)
            try stepDone(statement)
        }
        return true
    }

    private func importFailureQuarantine(
        _ write: LegacyContinuityImportWrite,
        error: Error
    ) throws -> LegacyContinuityQuarantineWrite {
        try LegacyContinuityQuarantineWrite(
            payload: [
                "schema_version": "legacy-quarantine-1",
                "source_name": write.sourceRecordID,
                "reason": String(error.localizedDescription.prefix(1_024)),
            ],
            sourcePath: write.sourcePath,
            reason: "legacy candidate could not be validated",
            receiptSourceSHA256: write.receiptSourceSHA256
        )
    }

    private func committedLegacyProjectionsUnlocked(
        _ actions: [LegacyContinuityMigrationAction],
        outcomes: [LegacyContinuityMigrationOutcome]
    ) throws -> [LegacyQuarantineProjection] {
        guard actions.count == outcomes.count else {
            throw ProjectMemoryError.integrityFailure(
                "legacy migration outcome count does not match its candidate batch"
            )
        }
        var projections: [LegacyQuarantineProjection] = []
        for (action, outcome) in zip(actions, outcomes) {
            switch (action, outcome) {
            case (.skip, .skipped):
                continue
            case (.quarantine(let write), .quarantined):
                projections.append(try quarantineLegacyUnlocked(write, insertIfMissing: false))
            case (.importReadOnly(let write), .imported):
                guard try importDispositionUnlocked(write) == .exact else {
                    throw ProjectMemoryError.integrityFailure(
                        "legacy migration receipt is missing an imported side effect"
                    )
                }
                try verifyCommittedLegacyImportUnlocked(write, allowSourceAlias: false)
            case (.importReadOnly(let write), .skipped):
                guard try importDispositionUnlocked(write) == .exact else {
                    throw ProjectMemoryError.integrityFailure(
                        "legacy migration receipt is missing its shared imported side effect"
                    )
                }
                try verifyCommittedLegacyImportUnlocked(write, allowSourceAlias: true)
            case (.importReadOnly(let write), .quarantined):
                guard try importDispositionUnlocked(write) == .collision else {
                    throw ProjectMemoryError.integrityFailure(
                        "legacy migration receipt no longer matches its collision quarantine"
                    )
                }
                let error = ProjectMemoryError.conflict(
                    "legacy continuity identifier collision"
                )
                let fallback = try importFailureQuarantine(write, error: error)
                projections.append(
                    try quarantineLegacyUnlocked(fallback, insertIfMissing: false)
                )
            default:
                throw ProjectMemoryError.integrityFailure(
                    "legacy migration receipt outcome does not match its candidate action"
                )
            }
        }
        return projections
    }

    private func verifyCommittedLegacyImportUnlocked(
        _ write: LegacyContinuityImportWrite,
        allowSourceAlias: Bool
    ) throws {
        guard try committedLegacyImportMatchesUnlocked(
            write,
            allowSourceAlias: allowSourceAlias
        ) else {
            throw ProjectMemoryError.integrityFailure(
                "legacy migration receipt does not match its imported side effect"
            )
        }
    }

    private func committedLegacyImportMatchesUnlocked(
        _ write: LegacyContinuityImportWrite,
        allowSourceAlias: Bool
    ) throws -> Bool {
        try withStatementUnlocked(
            """
            SELECT payload_json,created_at,acknowledged_session_id,acknowledged_at,
                   schema_version,project_generation,run_id,predecessor_provider_response_id,
                   bootstrap_nonce,budget_observation_id,acknowledgement_sha256,
                   continuation_issued,quarantine_state,migration_source,legacy_record_id
            FROM continuity_handoffs
            WHERE handoff_id=? AND operation_id=? AND project_id=? AND content_sha256=? LIMIT 1
            """
        ) { statement -> Bool in
            bind(statement, 1, write.handoffID)
            bind(statement, 2, write.operationID)
            bind(statement, 3, projectID)
            bind(statement, 4, write.contentSHA256)
            guard sqlite3_step(statement) == SQLITE_ROW else { return false }
            let storedGeneration: UInt64?
            if sqlite3_column_type(statement, 5) == SQLITE_NULL {
                storedGeneration = nil
            } else {
                let value = sqlite3_column_int64(statement, 5)
                guard value >= 0 else { return false }
                storedGeneration = UInt64(value)
            }
            guard let storedSourceRecordID = text(statement, 14),
                  !storedSourceRecordID.isEmpty,
                  storedSourceRecordID.utf8.count <= 1_024 else {
                return false
            }
            return text(statement, 0) == write.payloadJSON
                && text(statement, 1) == write.createdAt
                && text(statement, 2) == nil
                && text(statement, 3) == nil
                && text(statement, 4) == write.schemaVersion
                && storedGeneration == write.projectGeneration
                && text(statement, 6) == write.runID
                && text(statement, 7) == write.predecessorProviderResponseID
                && text(statement, 8) == write.bootstrapNonce
                && text(statement, 9) == nil
                && text(statement, 10) == nil
                && sqlite3_column_int(statement, 11) == 0
                && text(statement, 12) == "legacy_read_only"
                && text(statement, 13) == "legacy_global"
                && (allowSourceAlias || storedSourceRecordID == write.sourceRecordID)
        }
    }

    private func materializeLegacyQuarantineProjections(
        _ projections: [LegacyQuarantineProjection]
    ) throws {
        guard !projections.isEmpty else { return }
        var unique: [String: Data] = [:]
        for projection in projections {
            guard UUID(uuidString: projection.identifier) != nil else {
                throw ProjectMemoryError.integrityFailure(
                    "legacy quarantine projection identity is invalid"
                )
            }
            if let existing = unique[projection.identifier], existing != projection.data {
                throw ProjectMemoryError.integrityFailure(
                    "legacy quarantine projection identity is ambiguous"
                )
            }
            unique[projection.identifier] = projection.data
        }
        let directory = continuityDirectory
            .appendingPathComponent("LegacyContinuityQuarantine", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for identifier in unique.keys.sorted() {
            guard let data = unique[identifier] else { continue }
            let projection = directory.appendingPathComponent("\(identifier).json")
            try data.write(to: projection, options: [.atomic, .completeFileProtectionUnlessOpen])
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: projection.path
            )
        }
    }

    private func legacyMigrationReceiptID(fingerprint: String) -> String {
        "legacy-global-" + JSONSupport.sha256Hex("\(projectID)|\(fingerprint)")
    }

    private func legacyMigrationDetailsJSON(_ details: [String: Any]) throws -> String {
        let detailsJSON = try JSONSupport.string(from: details)
        guard detailsJSON.utf8.count <= 16 * 1_024 else {
            throw ProjectMemoryError.payloadTooLarge("legacy migration details are oversized")
        }
        return detailsJSON
    }

    private func insertLegacyMigrationReceiptUnlocked(
        receiptID: String,
        importedCount: Int,
        skippedCount: Int,
        quarantinedCount: Int,
        detailsJSON: String,
        startedAt: String,
        completedAt: String
    ) throws {
        try withStatementUnlocked(
            """
            INSERT INTO continuity_migration_receipts(
              receipt_id,project_id,source_version,target_version,imported_count,
              skipped_count,quarantined_count,integrity_result,details_json,
              started_at,completed_at
            ) VALUES(?,?,'legacy_global','2.0',?,?,?,'ok',?,?,?)
            """
        ) { statement in
            bind(statement, 1, receiptID)
            bind(statement, 2, projectID)
            sqlite3_bind_int64(statement, 3, Int64(importedCount))
            sqlite3_bind_int64(statement, 4, Int64(skippedCount))
            sqlite3_bind_int64(statement, 5, Int64(quarantinedCount))
            bind(statement, 6, detailsJSON)
            bind(statement, 7, startedAt)
            bind(statement, 8, completedAt)
            try stepDone(statement)
        }
    }

    private func legacyMigrationReceiptUnlocked(
        receiptID: String,
        fingerprint: String,
        expectedBatch: LegacyContinuityMigrationBatch? = nil
    ) throws -> LegacyMigrationReceiptReadback? {
        try withStatementUnlocked(
            """
            SELECT project_id,source_version,target_version,imported_count,skipped_count,
                   quarantined_count,integrity_result,details_json,started_at,completed_at
            FROM continuity_migration_receipts WHERE receipt_id=? LIMIT 1
            """
        ) { statement -> LegacyMigrationReceiptReadback? in
            bind(statement, 1, receiptID)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            guard let storedProjectID = text(statement, 0),
                  text(statement, 1) == "legacy_global",
                  text(statement, 2) == ContinuityHandoffV2.schemaVersion,
                  text(statement, 6) == "ok",
                  let storedDetailsJSON = text(statement, 7),
                  let storedStartedAt = text(statement, 8),
                  let storedCompletedAt = text(statement, 9),
                  storedProjectID == projectID,
                  ISO8601.date(from: storedStartedAt) != nil,
                  ISO8601.date(from: storedCompletedAt) != nil else {
                throw ProjectMemoryError.integrityFailure(
                    "legacy migration receipt could not be read back"
                )
            }
            var storedDetails = try JSONSupport.object(from: Data(storedDetailsJSON.utf8))
            guard storedDetails["migration_fingerprint_sha256"] as? String == fingerprint else {
                throw ProjectMemoryError.integrityFailure(
                    "legacy migration receipt fingerprint does not match"
                )
            }
            let storedImportedCount = Int(sqlite3_column_int64(statement, 3))
            let storedSkippedCount = Int(sqlite3_column_int64(statement, 4))
            let storedQuarantinedCount = Int(sqlite3_column_int64(statement, 5))
            guard storedImportedCount >= 0,
                  storedSkippedCount >= 0,
                  storedQuarantinedCount >= 0 else {
                throw ProjectMemoryError.integrityFailure(
                    "legacy migration receipt details or counts are invalid"
                )
            }
            let receipt = LegacyContinuityMigrationReceipt(
                receiptID: receiptID,
                projectID: storedProjectID,
                importedCount: storedImportedCount,
                skippedCount: storedSkippedCount,
                quarantinedCount: storedQuarantinedCount,
                startedAt: storedStartedAt,
                completedAt: storedCompletedAt
            )
            guard let expectedBatch else {
                return LegacyMigrationReceiptReadback(receipt: receipt, projections: [])
            }
            let legacyDetailKeys: Set<String> = [
                "candidate_count", "imported_source_sha256",
                "quarantined_source_sha256", "migration_fingerprint_sha256",
                "global_latest_used_as_authority",
            ]
            if Set(storedDetails.keys) == legacyDetailKeys {
                let outcomes = try reconcileLegacyMigrationOutcomesV1Unlocked(
                    batch: expectedBatch,
                    details: storedDetails,
                    importedCount: storedImportedCount,
                    skippedCount: storedSkippedCount,
                    quarantinedCount: storedQuarantinedCount
                )
                storedDetails = try legacyMigrationOutcomeDetails(
                    batch: expectedBatch,
                    outcomes: outcomes,
                    fingerprint: fingerprint
                )
                let upgradedDetailsJSON = try legacyMigrationDetailsJSON(storedDetails)
                try withStatementUnlocked(
                    """
                    UPDATE continuity_migration_receipts SET details_json=?
                    WHERE receipt_id=? AND project_id=? AND details_json=?
                    """
                ) { update in
                    bind(update, 1, upgradedDetailsJSON)
                    bind(update, 2, receiptID)
                    bind(update, 3, projectID)
                    bind(update, 4, storedDetailsJSON)
                    try stepDone(update)
                }
                guard sqlite3_changes(db) == 1 else {
                    throw ProjectMemoryError.conflict(
                        "legacy migration receipt details changed during reconciliation"
                    )
                }
            }
            let expectedDetailKeys: Set<String> = [
                "receipt_details_schema_version",
                "candidate_count", "candidate_outcomes", "imported_source_sha256",
                "quarantined_source_sha256", "migration_fingerprint_sha256",
                "outcome_ledger_sha256", "global_latest_used_as_authority",
            ]
            guard Set(storedDetails.keys) == expectedDetailKeys,
                  storedDetails["receipt_details_schema_version"] as? Int == 2,
                  let candidateCount = storedDetails["candidate_count"] as? Int,
                  let rawOutcomes = storedDetails["candidate_outcomes"] as? [String],
                  let importedHashes = storedDetails[
                    "imported_source_sha256"
                  ] as? [String],
                  let quarantineHashes = storedDetails[
                    "quarantined_source_sha256"
                  ] as? [String],
                  let outcomeLedgerSHA256 = storedDetails[
                    "outcome_ledger_sha256"
                  ] as? String,
                  storedDetails["global_latest_used_as_authority"] as? Bool == false,
                  candidateCount == expectedBatch.actions.count,
                  candidateCount <= LegacyContinuityMigrationBatch.maximumCandidateCount,
                  rawOutcomes.count == candidateCount,
                  importedHashes.allSatisfy(Self.isLowercaseSHA256),
                  quarantineHashes.allSatisfy(Self.isLowercaseSHA256),
                  Self.isLowercaseSHA256(outcomeLedgerSHA256) else {
                throw ProjectMemoryError.integrityFailure(
                    "legacy migration receipt details or counts are invalid"
                )
            }
            let outcomes = rawOutcomes.compactMap(LegacyContinuityMigrationOutcome.init(rawValue:))
            guard outcomes.count == rawOutcomes.count else {
                throw ProjectMemoryError.integrityFailure(
                    "legacy migration receipt contains an invalid candidate outcome"
                )
            }
            var expectedImportedHashes: [String] = []
            var expectedQuarantineHashes: [String] = []
            for (action, outcome) in zip(expectedBatch.actions, outcomes) {
                switch (action, outcome) {
                case (.importReadOnly(let write), .imported):
                    expectedImportedHashes.append(write.receiptSourceSHA256)
                case (.importReadOnly(let write), .quarantined):
                    expectedQuarantineHashes.append(write.receiptSourceSHA256)
                case (.quarantine(let write), .quarantined):
                    if let sourceSHA256 = write.receiptSourceSHA256 {
                        expectedQuarantineHashes.append(sourceSHA256)
                    }
                case (.skip, .skipped), (.importReadOnly(_), .skipped):
                    break
                default:
                    throw ProjectMemoryError.integrityFailure(
                        "legacy migration receipt outcome does not match its candidate action"
                    )
                }
            }
            let expectedImportedCount = outcomes.reduce(0) {
                $0 + ($1 == .imported ? 1 : 0)
            }
            let expectedQuarantinedCount = outcomes.reduce(0) {
                $0 + ($1 == .quarantined ? 1 : 0)
            }
            let selectedSkippedCount = outcomes.reduce(0) {
                $0 + ($1 == .skipped ? 1 : 0)
            }
            let unselectedCount = expectedBatch.submittedCandidateCount
                - expectedBatch.actions.count
            let (expectedSkippedCount, skippedOverflow) = selectedSkippedCount
                .addingReportingOverflow(unselectedCount)
            guard !skippedOverflow,
                  storedImportedCount == expectedImportedCount,
                  storedSkippedCount == expectedSkippedCount,
                  storedQuarantinedCount == expectedQuarantinedCount,
                  importedHashes == expectedImportedHashes,
                  quarantineHashes == expectedQuarantineHashes,
                  outcomeLedgerSHA256 == (try expectedBatch.outcomeLedgerSHA256(outcomes)) else {
                throw ProjectMemoryError.integrityFailure(
                    "legacy migration receipt does not match its committed outcomes"
                )
            }
            return LegacyMigrationReceiptReadback(
                receipt: receipt,
                projections: try committedLegacyProjectionsUnlocked(
                    expectedBatch.actions,
                    outcomes: outcomes
                )
            )
        }
    }

    private func legacyMigrationOutcomeDetails(
        batch: LegacyContinuityMigrationBatch,
        outcomes: [LegacyContinuityMigrationOutcome],
        fingerprint: String
    ) throws -> [String: Any] {
        guard outcomes.count == batch.actions.count else {
            throw ProjectMemoryError.integrityFailure(
                "legacy migration outcome count does not match its candidate batch"
            )
        }
        var importedHashes: [String] = []
        var quarantineHashes: [String] = []
        for (action, outcome) in zip(batch.actions, outcomes) {
            switch (action, outcome) {
            case (.importReadOnly(let write), .imported):
                importedHashes.append(write.receiptSourceSHA256)
            case (.importReadOnly(let write), .quarantined):
                quarantineHashes.append(write.receiptSourceSHA256)
            case (.quarantine(let write), .quarantined):
                if let sourceSHA256 = write.receiptSourceSHA256 {
                    quarantineHashes.append(sourceSHA256)
                }
            case (.skip, .skipped), (.importReadOnly(_), .skipped):
                break
            default:
                throw ProjectMemoryError.integrityFailure(
                    "legacy migration receipt outcome does not match its candidate action"
                )
            }
        }
        return [
            "receipt_details_schema_version": 2,
            "candidate_count": batch.actions.count,
            "candidate_outcomes": outcomes.map(\.rawValue),
            "imported_source_sha256": importedHashes,
            "quarantined_source_sha256": quarantineHashes,
            "migration_fingerprint_sha256": fingerprint,
            "outcome_ledger_sha256": try batch.outcomeLedgerSHA256(outcomes),
            "global_latest_used_as_authority": false,
        ]
    }

    private func reconcileLegacyMigrationOutcomesV1Unlocked(
        batch: LegacyContinuityMigrationBatch,
        details: [String: Any],
        importedCount: Int,
        skippedCount: Int,
        quarantinedCount: Int
    ) throws -> [LegacyContinuityMigrationOutcome] {
        guard let candidateCount = details["candidate_count"] as? Int,
              let importedHashes = details["imported_source_sha256"] as? [String],
              let quarantineHashes = details["quarantined_source_sha256"] as? [String],
              details["global_latest_used_as_authority"] as? Bool == false,
              candidateCount == batch.actions.count,
              importedHashes.count == importedCount,
              importedHashes.allSatisfy(Self.isLowercaseSHA256),
              quarantineHashes.allSatisfy(Self.isLowercaseSHA256) else {
            throw ProjectMemoryError.integrityFailure(
                "legacy migration v1 receipt details or counts are invalid"
            )
        }
        var outcomes: [LegacyContinuityMigrationOutcome] = []
        var importedIndex = 0
        var quarantineIndex = 0
        outcomes.reserveCapacity(batch.actions.count)
        for action in batch.actions {
            switch action {
            case .skip:
                outcomes.append(.skipped)
            case .quarantine(let write):
                outcomes.append(.quarantined)
                if let sourceSHA256 = write.receiptSourceSHA256 {
                    guard quarantineIndex < quarantineHashes.count,
                          quarantineHashes[quarantineIndex] == sourceSHA256 else {
                        throw ProjectMemoryError.integrityFailure(
                            "legacy migration v1 quarantine hashes do not match"
                        )
                    }
                    quarantineIndex += 1
                }
            case .importReadOnly(let write):
                switch try importDispositionUnlocked(write) {
                case .missing:
                    throw ProjectMemoryError.integrityFailure(
                        "legacy migration v1 receipt is missing an imported side effect"
                    )
                case .collision:
                    outcomes.append(.quarantined)
                case .exact:
                    guard try committedLegacyImportMatchesUnlocked(
                        write,
                        allowSourceAlias: true
                    ) else {
                        throw ProjectMemoryError.integrityFailure(
                            "legacy migration v1 receipt matches a malformed imported row"
                        )
                    }
                    if importedIndex < importedHashes.count,
                       importedHashes[importedIndex] == write.receiptSourceSHA256,
                       try committedLegacyImportMatchesUnlocked(
                        write,
                        allowSourceAlias: false
                       ) {
                        outcomes.append(.imported)
                        importedIndex += 1
                    } else {
                        outcomes.append(.skipped)
                    }
                }
            }
        }
        let expectedImportedCount = outcomes.reduce(0) {
            $0 + ($1 == .imported ? 1 : 0)
        }
        let expectedQuarantinedCount = outcomes.reduce(0) {
            $0 + ($1 == .quarantined ? 1 : 0)
        }
        let selectedSkippedCount = outcomes.reduce(0) {
            $0 + ($1 == .skipped ? 1 : 0)
        }
        let unselectedCount = batch.submittedCandidateCount - batch.actions.count
        let (expectedSkippedCount, skippedOverflow) = selectedSkippedCount
            .addingReportingOverflow(unselectedCount)
        guard !skippedOverflow,
              importedIndex == importedHashes.count,
              quarantineIndex == quarantineHashes.count,
              importedCount == expectedImportedCount,
              skippedCount == expectedSkippedCount,
              quarantinedCount == expectedQuarantinedCount else {
            throw ProjectMemoryError.integrityFailure(
                "legacy migration v1 receipt does not match committed outcomes"
            )
        }
        return outcomes
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64
            && value == value.lowercased()
            && value.allSatisfy { $0.isHexDigit }
    }

    public func continuityLegacyQuarantineCount() throws -> Int {
        try scalarInt(
            "SELECT COUNT(*) FROM legacy_continuity_quarantine WHERE project_id=?",
            value: projectID
        )
    }

    public func continuityMigrationReceiptCount() throws -> Int {
        try scalarInt(
            "SELECT COUNT(*) FROM continuity_migration_receipts WHERE project_id=?",
            value: projectID
        )
    }

    private static let continuityOperationSelect = """
    SELECT operation_id,project_id,predecessor_session_id,successor_session_id,handoff_id,
      state,attempt,adapter_id,idempotency_key,acknowledged_session_id,acknowledged_handoff_id,
      created_at,updated_at,last_error,retry_at,state_checksum FROM rollover_operations
    """

    private func continuityOperationUnlocked(_ id: String) throws -> ContinuityOperation? {
        try withStatementUnlocked(
            Self.continuityOperationSelect
                + " WHERE operation_id=? AND project_id=? AND quarantine_state IS NULL LIMIT 1"
        ) { statement in
            bind(statement, 1, id); bind(statement, 2, projectID)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return continuityOperation(statement)
        }
    }

    private func continuityOperationByIdempotencyUnlocked(_ key: String) throws -> ContinuityOperation? {
        try withStatementUnlocked(
            Self.continuityOperationSelect
                + " WHERE project_id=? AND idempotency_key=? AND quarantine_state IS NULL LIMIT 1"
        ) { statement in
            bind(statement, 1, projectID); bind(statement, 2, key)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return continuityOperation(statement)
        }
    }

    private func continuityActiveOperationUnlocked() throws -> ContinuityOperation? {
        try withStatementUnlocked(
            Self.continuityOperationSelect
                + " WHERE project_id=? AND state<>'predecessorSealed'"
                + " AND quarantine_state IS NULL ORDER BY updated_at DESC LIMIT 1"
        ) { statement in
            bind(statement, 1, projectID)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return continuityOperation(statement)
        }
    }

    private func continuityHandoffExistsUnlocked(id: String) throws -> Bool {
        try withStatementUnlocked(
            "SELECT 1 FROM continuity_handoffs WHERE handoff_id=? AND project_id=? AND quarantine_state IS NULL LIMIT 1"
        ) { statement in
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

    private static let continuityOperationV2Select = """
    SELECT operation_id,project_id,project_generation,run_id,predecessor_session_id,
      predecessor_provider_response_id,successor_session_id,successor_provider_response_id,
      handoff_id,state,attempt,adapter_id,idempotency_key,bootstrap_nonce,
      acknowledgement_sha256,budget_observation_id,continuation_issued,quarantine_state,
      migration_source,legacy_record_id,acknowledged_session_id,acknowledged_handoff_id,
      created_at,updated_at,last_error,retry_at,state_checksum FROM rollover_operations
    """

    private func continuityPersistHandoffV2Unlocked(
        _ handoff: ContinuityHandoffV2,
        payload: String,
        generation: UInt64,
        runID: String,
        predecessorResponseID: String?
    ) throws {
        guard let nonce = handoff.bootstrapNonce,
              let operation = try continuityOperationV2Unlocked(handoff.operationID),
              operation.projectID == projectID,
              operation.projectGeneration == generation,
              operation.runID == runID,
              operation.handoffID == handoff.handoffID,
              operation.bootstrapNonce == nonce else {
            throw ProjectMemoryError.conflict(
                "V2 handoff does not match its durable operation"
            )
        }
        let existing = try withStatementUnlocked(
            """
            SELECT operation_id,payload_json,content_sha256,project_generation,run_id,
                   predecessor_provider_response_id,bootstrap_nonce
            FROM continuity_handoffs
            WHERE handoff_id=? AND project_id=? AND schema_version='2.0' LIMIT 1
            """
        ) { statement -> (
            operationID: String,
            payload: String,
            checksum: String,
            generation: UInt64,
            runID: String,
            predecessorResponseID: String?,
            nonce: String
        )? in
            bind(statement, 1, handoff.handoffID)
            bind(statement, 2, projectID)
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let storedOperationID = text(statement, 0),
                  let storedPayload = text(statement, 1),
                  let storedChecksum = text(statement, 2),
                  sqlite3_column_int64(statement, 3) > 0,
                  let storedRunID = text(statement, 4),
                  let storedNonce = text(statement, 6) else {
                return nil
            }
            return (
                storedOperationID,
                storedPayload,
                storedChecksum,
                UInt64(sqlite3_column_int64(statement, 3)),
                storedRunID,
                text(statement, 5),
                storedNonce
            )
        }
        if let existing {
            guard existing.operationID == handoff.operationID,
                  existing.payload == payload,
                  existing.checksum == handoff.contentSHA256,
                  existing.generation == generation,
                  existing.runID == runID,
                  existing.predecessorResponseID == predecessorResponseID,
                  existing.nonce == nonce else {
                throw ProjectMemoryError.conflict(
                    "V2 handoff identifier is already bound to different content"
                )
            }
            return
        }
        guard operation.state == .active || operation.state == .checkpointPreparing else {
            throw ProjectMemoryError.integrityFailure(
                "advanced V2 operation is missing its durable handoff"
            )
        }
        try withStatementUnlocked(
            """
            INSERT INTO continuity_handoffs(
              handoff_id,project_id,operation_id,payload_json,content_sha256,created_at,
              schema_version,project_generation,run_id,predecessor_provider_response_id,
              bootstrap_nonce,budget_observation_id,acknowledgement_sha256,
              continuation_issued,quarantine_state,migration_source,legacy_record_id
            ) VALUES(?,?,?,?,?,?,'2.0',?,?,?,?,NULL,NULL,0,NULL,NULL,NULL)
            """
        ) { statement in
            bind(statement, 1, handoff.handoffID)
            bind(statement, 2, projectID)
            bind(statement, 3, handoff.operationID)
            bind(statement, 4, payload)
            bind(statement, 5, handoff.contentSHA256)
            bind(statement, 6, handoff.createdAt)
            sqlite3_bind_int64(statement, 7, Int64(generation))
            bind(statement, 8, runID)
            bind(statement, 9, predecessorResponseID)
            bind(statement, 10, nonce)
            try stepDone(statement)
        }
    }

    private func continuityOperationV2Unlocked(_ id: String) throws -> ContinuityOperationV2? {
        try withStatementUnlocked(
            Self.continuityOperationV2Select
                + " WHERE operation_id=? AND project_id=? AND schema_version=2"
                + " AND quarantine_state IS NULL LIMIT 1"
        ) { statement in
            bind(statement, 1, id)
            bind(statement, 2, projectID)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return try continuityOperationV2(statement)
        }
    }

    private func continuityOperationV2ByIdempotencyUnlocked(
        _ key: String
    ) throws -> ContinuityOperationV2? {
        try withStatementUnlocked(
            Self.continuityOperationV2Select
                + " WHERE project_id=? AND idempotency_key=? AND schema_version=2"
                + " AND quarantine_state IS NULL LIMIT 1"
        ) { statement in
            bind(statement, 1, projectID)
            bind(statement, 2, key)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return try continuityOperationV2(statement)
        }
    }

    private func continuityV2HandoffExistsUnlocked(id: String) throws -> Bool {
        try withStatementUnlocked(
            """
            SELECT 1 FROM continuity_handoffs WHERE handoff_id=? AND project_id=?
              AND schema_version='2.0' AND quarantine_state IS NULL LIMIT 1
            """
        ) { statement in
            bind(statement, 1, id)
            bind(statement, 2, projectID)
            return sqlite3_step(statement) == SQLITE_ROW
        }
    }

    private func continuityOperationV2(_ statement: OpaquePointer) throws -> ContinuityOperationV2 {
        guard let operationID = text(statement, 0),
              let storedProjectID = text(statement, 1),
              sqlite3_column_int64(statement, 2) > 0,
              let runID = text(statement, 3), UUID(uuidString: runID) != nil,
              let predecessorSessionID = text(statement, 4),
              let handoffID = text(statement, 8),
              let stateValue = text(statement, 9),
              let state = ContinuityState(rawValue: stateValue),
              let adapterID = text(statement, 11),
              let idempotencyKey = text(statement, 12),
              let bootstrapNonce = text(statement, 13),
              let createdAt = text(statement, 22),
              let updatedAt = text(statement, 23),
              let stateChecksum = text(statement, 26) else {
            throw ProjectMemoryError.integrityFailure("invalid V2 continuity operation row")
        }
        return ContinuityOperationV2(
            operationID: operationID,
            projectID: storedProjectID,
            projectGeneration: UInt64(sqlite3_column_int64(statement, 2)),
            runID: runID,
            predecessorSessionID: predecessorSessionID,
            predecessorProviderResponseID: text(statement, 5),
            successorSessionID: text(statement, 6),
            successorProviderResponseID: text(statement, 7),
            handoffID: handoffID,
            state: state,
            attempt: Int(sqlite3_column_int(statement, 10)),
            adapterID: adapterID,
            idempotencyKey: idempotencyKey,
            bootstrapNonce: bootstrapNonce,
            acknowledgementSHA256: text(statement, 14),
            budgetObservationID: text(statement, 15),
            continuationIssued: sqlite3_column_int(statement, 16) == 1,
            quarantineState: text(statement, 17),
            migrationSource: text(statement, 18),
            legacyRecordID: text(statement, 19),
            acknowledgedSessionID: text(statement, 20),
            acknowledgedHandoffID: text(statement, 21),
            createdAt: createdAt,
            updatedAt: updatedAt,
            lastError: text(statement, 24),
            retryAt: text(statement, 25),
            stateChecksum: stateChecksum
        )
    }

    private static func continuityChecksumV2(
        operationID: String,
        projectGeneration: UInt64,
        runID: String,
        state: ContinuityState,
        successorSessionID: String?,
        successorProviderResponseID: String?,
        handoffID: String,
        attempt: Int
    ) -> String {
        JSONSupport.sha256Hex([
            "2", operationID, String(projectGeneration), runID, state.rawValue,
            successorSessionID ?? "", successorProviderResponseID ?? "", handoffID,
            String(attempt),
        ].joined(separator: "|"))
    }

    private static func bootstrapAcknowledgementSHA256(
        _ acknowledgement: BootstrapAcknowledgementV2
    ) -> String {
        let payload: [String: Any] = [
            "acknowledgement_contract_version": acknowledgement.acknowledgementContractVersion,
            "project_id": acknowledgement.projectID.description,
            "project_generation": acknowledgement.projectGeneration.rawValue,
            "run_id": acknowledgement.runID.description,
            "operation_id": acknowledgement.operationID.uuidString.lowercased(),
            "handoff_id": acknowledgement.handoffID.uuidString.lowercased(),
            "handoff_sha256": acknowledgement.handoffSHA256,
            "nonce": acknowledgement.nonce,
            "accepted": acknowledgement.accepted,
        ]
        return JSONSupport.sha256Hex((try? JSONSupport.canonicalJSON(payload)) ?? "")
    }

    private var continuityDirectory: URL {
        directory.appendingPathComponent("continuity", isDirectory: true)
    }

    private func writeHandoffProjection(_ handoff: ContinuityHandoffV2) throws {
        guard UUID(uuidString: handoff.handoffID) != nil else {
            throw ProjectMemoryError.invalidRequest("handoff_id must be a UUID")
        }
        let root = continuityDirectory
        let handoffs = root.appendingPathComponent("handoffs", isDirectory: true)
        try FileManager.default.createDirectory(at: handoffs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("operations", isDirectory: true),
            withIntermediateDirectories: true
        )
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let data = try handoff.encodedJSON()
        let handoffURL = handoffs.appendingPathComponent("\(handoff.handoffID.lowercased()).json")
        try data.write(to: handoffURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: handoffURL.path)
        let latest = Data("\(handoff.handoffID.lowercased())\n".utf8)
        let latestURL = root.appendingPathComponent("LATEST")
        try latest.write(to: latestURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: latestURL.path)
    }

    private func writeOperationProjection(_ operation: ContinuityOperationV2) throws {
        guard UUID(uuidString: operation.operationID) != nil else {
            throw ProjectMemoryError.invalidRequest("operation_id must be a UUID")
        }
        let root = continuityDirectory
        let operations = root.appendingPathComponent("operations", isDirectory: true)
        try FileManager.default.createDirectory(at: operations, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let data = try JSONSupport.data(from: operation.asDictionary())
        let operationURL = operations.appendingPathComponent("\(operation.operationID.lowercased()).json")
        try data.write(to: operationURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: operationURL.path)
        let currentURL = root.appendingPathComponent("CURRENT.json")
        try data.write(to: currentURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: currentURL.path)
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

    private func appendTransitionV2Unlocked(
        operationID: String,
        projectGeneration: UInt64,
        runID: String,
        from: ContinuityState?,
        to: ContinuityState,
        attempt: Int,
        adapterID: String,
        successorProviderResponseID: String?,
        evidence: String?,
        checksum: String
    ) throws {
        guard projectGeneration > 0, projectGeneration <= UInt64(Int64.max),
              UUID(uuidString: runID) != nil else {
            throw ProjectMemoryError.integrityFailure("invalid V2 transition identity")
        }
        try withStatementUnlocked(
            """
            INSERT INTO rollover_transitions(
              operation_id,project_id,from_state,to_state,attempt,created_at,adapter_id,
              evidence,state_checksum,schema_version,project_generation,run_id,
              successor_provider_response_id
            ) VALUES(?,?,?,?,?,?,?,?,?,2,?,?,?)
            """
        ) { statement in
            bind(statement, 1, operationID)
            bind(statement, 2, projectID)
            bind(statement, 3, from?.rawValue)
            bind(statement, 4, to.rawValue)
            sqlite3_bind_int(statement, 5, Int32(attempt))
            bind(statement, 6, ISO8601.string(from: clock.now()))
            bind(statement, 7, adapterID)
            bind(statement, 8, evidence.map { String($0.prefix(2_048)) })
            bind(statement, 9, checksum)
            sqlite3_bind_int64(statement, 10, Int64(projectGeneration))
            bind(statement, 11, runID)
            bind(statement, 12, successorProviderResponseID)
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
        var migrationManifest: VerifiedMigrationBackupManifest?
        try VerifiedMigrationBackup.withMigrationLock(
            databaseURL: databaseURL,
            timeoutSeconds: 60
        ) {
            do {
                try VerifiedMigrationBackup.withNonMutatingSQLitePreflight(
                    databaseURL: databaseURL
                ) { candidate in
                    guard let candidate else {
                        _ = try VerifiedMigrationBackup.reconcileMigrationManifest(
                            sourceURL: databaseURL,
                            observedVersion: 0
                        )
                        return
                    }
                    let version = try candidate.integer("PRAGMA user_version;") ?? 0
                    guard version <= Self.schemaVersion else {
                        throw ProjectMemoryError.unsupportedVersion(version)
                    }
                    try candidate.requireEmptySchemaWhenUnversioned(
                        reportedVersion: version
                    )
                    migrationManifest = try VerifiedMigrationBackup
                        .reconcileMigrationManifest(
                            sourceURL: databaseURL,
                            observedVersion: version
                        )
                }
            } catch let error as ProjectMemoryError {
                throw error
            } catch let error as VerifiedMigrationBackupError {
                if case .corruptSource = error {
                    throw corruptDatabaseRecoveryError()
                }
                throw ProjectMemoryError.invalidRequest(error.localizedDescription)
            } catch {
                throw ProjectMemoryError.invalidRequest(error.localizedDescription)
            }
            try openAndMigrateLocked(migrationManifest: migrationManifest)
        }
    }

    private func openAndMigrateLocked(
        migrationManifest initialManifest: VerifiedMigrationBackupManifest?
    ) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let handle { sqlite3_close(handle) }
            throw StoreError.openFailed(message)
        }
        db = handle
        do {
            let initialVersion = try pragmaUserVersionUnlocked()
            guard initialVersion <= Self.schemaVersion else {
                throw ProjectMemoryError.unsupportedVersion(initialVersion)
            }
            do {
                try VerifiedMigrationBackup.requireEmptySQLiteSchemaWhenUnversioned(
                    database: handle,
                    reportedVersion: initialVersion
                )
            } catch {
                throw ProjectMemoryError.invalidRequest(error.localizedDescription)
            }
            var migrationManifest = try initialManifest
                ?? VerifiedMigrationBackup.reconcileMigrationManifest(
                    sourceURL: databaseURL,
                    observedVersion: initialVersion
                )
            if initialVersion == Self.schemaVersion,
               let currentManifest = migrationManifest {
                migrationManifest = try VerifiedMigrationBackup.requireSQLiteMigrationReceipt(
                    database: handle,
                    sourceURL: databaseURL,
                    manifest: currentManifest
                )
            }
            try execUnlocked("PRAGMA busy_timeout=3000; PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA synchronous=NORMAL;")
            try migrateUnlocked(migrationManifest: migrationManifest)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)
            openRegistration = try VerifiedMigrationBackup.registerOpenDatabase(at: databaseURL)
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
                throw corruptDatabaseRecoveryError()
            }
            throw error
        }
    }

    private func corruptDatabaseRecoveryError() -> ProjectMemoryError {
        let artifact = directory.appendingPathComponent(
            "memory.corrupt-recovery.sqlite3"
        )
        do {
            _ = try VerifiedMigrationBackup.preserveStableFile(
                from: databaseURL,
                to: artifact
            )
            let writeAheadLog = URL(fileURLWithPath: databaseURL.path + "-wal")
            if FileManager.default.fileExists(atPath: writeAheadLog.path) {
                _ = try VerifiedMigrationBackup.preserveStableFile(
                    from: writeAheadLog,
                    to: URL(fileURLWithPath: artifact.path + "-wal")
                )
            }
            return .integrityFailure(
                "database family preserved for recovery at \(artifact.lastPathComponent)"
            )
        } catch {
            return .integrityFailure(
                "database corruption detected; recovery copy failed: \(error.localizedDescription)"
            )
        }
    }

    private func migrateUnlocked(
        migrationManifest initialManifest: VerifiedMigrationBackupManifest?
    ) throws {
        let prior = try pragmaUserVersionUnlocked()
        guard prior <= Self.schemaVersion else { throw ProjectMemoryError.unsupportedVersion(prior) }
        var migrationManifest = initialManifest
        let isSchemaMigration = prior > 0 && prior < Self.schemaVersion
        let needsDurableCompletion = isSchemaMigration
            || migrationManifest?.state == .prepared
        if needsDurableCompletion {
            try execUnlocked("PRAGMA synchronous=FULL;")
        }
        defer {
            if needsDurableCompletion {
                try? execUnlocked("PRAGMA synchronous=NORMAL;")
            }
        }
        try transactionUnlocked {
            guard let db else { throw StoreError.openFailed("nil project memory database") }
            if isSchemaMigration {
                migrationManifest = try VerifiedMigrationBackup
                    .prepareSQLiteMigrationAtWriteBoundary(
                        database: db,
                        sourceURL: databaseURL,
                        backupURL: migrationBackupURL(sourceVersion: prior),
                        sourceVersion: prior,
                        targetVersion: Self.schemaVersion,
                        versionQuery: "PRAGMA user_version;"
                    )
            } else if prior == Self.schemaVersion,
                      let currentManifest = migrationManifest {
                migrationManifest = try VerifiedMigrationBackup.requireSQLiteMigrationReceipt(
                    database: db,
                    sourceURL: databaseURL,
                    manifest: currentManifest
                )
            }
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
              acknowledged_session_id TEXT,acknowledged_at TEXT,
              schema_version TEXT NOT NULL DEFAULT '1.0',project_generation INTEGER,run_id TEXT,
              predecessor_provider_response_id TEXT,bootstrap_nonce TEXT,budget_observation_id TEXT,
              acknowledgement_sha256 TEXT,continuation_issued INTEGER NOT NULL DEFAULT 0,
              quarantine_state TEXT,migration_source TEXT,legacy_record_id TEXT
            );
            CREATE TABLE IF NOT EXISTS rollover_operations(
              operation_id TEXT PRIMARY KEY,project_id TEXT NOT NULL,predecessor_session_id TEXT NOT NULL,
              successor_session_id TEXT,handoff_id TEXT NOT NULL,state TEXT NOT NULL,attempt INTEGER NOT NULL,
              adapter_id TEXT NOT NULL,idempotency_key TEXT NOT NULL,acknowledged_session_id TEXT,
              acknowledged_handoff_id TEXT,created_at TEXT NOT NULL,updated_at TEXT NOT NULL,
              last_error TEXT,retry_at TEXT,state_checksum TEXT NOT NULL,
              schema_version INTEGER NOT NULL DEFAULT 1,project_generation INTEGER,run_id TEXT,
              predecessor_provider_response_id TEXT,successor_provider_response_id TEXT,
              bootstrap_nonce TEXT,acknowledgement_sha256 TEXT,budget_observation_id TEXT,
              continuation_issued INTEGER NOT NULL DEFAULT 0,quarantine_state TEXT,
              migration_source TEXT,legacy_record_id TEXT,
              UNIQUE(project_id,idempotency_key)
            );
            CREATE TABLE IF NOT EXISTS rollover_transitions(
              id INTEGER PRIMARY KEY AUTOINCREMENT,operation_id TEXT NOT NULL,project_id TEXT NOT NULL,
              from_state TEXT,to_state TEXT NOT NULL,attempt INTEGER NOT NULL,created_at TEXT NOT NULL,
              adapter_id TEXT NOT NULL,evidence TEXT,state_checksum TEXT NOT NULL,
              schema_version INTEGER NOT NULL DEFAULT 1,project_generation INTEGER,run_id TEXT,
              successor_provider_response_id TEXT
            );
            CREATE TABLE IF NOT EXISTS project_active_sessions(
              project_id TEXT PRIMARY KEY,session_id TEXT NOT NULL,updated_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS legacy_continuity_quarantine(
              quarantine_id TEXT PRIMARY KEY,project_id TEXT NOT NULL,source_path TEXT,
              source_sha256 TEXT NOT NULL,reason TEXT NOT NULL,payload_json TEXT NOT NULL,
              created_at TEXT NOT NULL,UNIQUE(project_id,source_sha256)
            );
            CREATE TABLE IF NOT EXISTS continuity_migration_receipts(
              receipt_id TEXT PRIMARY KEY,project_id TEXT NOT NULL,source_version TEXT NOT NULL,
              target_version TEXT NOT NULL,imported_count INTEGER NOT NULL DEFAULT 0,
              skipped_count INTEGER NOT NULL DEFAULT 0,quarantined_count INTEGER NOT NULL DEFAULT 0,
              integrity_result TEXT NOT NULL,details_json TEXT NOT NULL DEFAULT '{}',
              started_at TEXT NOT NULL,completed_at TEXT NOT NULL
            );
            CREATE UNIQUE INDEX IF NOT EXISTS idx_rollover_active_project
              ON rollover_operations(project_id)
              WHERE state <> 'predecessorSealed' AND quarantine_state IS NULL;
            CREATE INDEX IF NOT EXISTS idx_rollover_project_updated
              ON rollover_operations(project_id,updated_at DESC);
            CREATE INDEX IF NOT EXISTS idx_memory_project_recent ON memory_records(project_id,is_tombstone,updated_at DESC);
            CREATE INDEX IF NOT EXISTS idx_memory_project_kind ON memory_records(project_id,kind,is_tombstone);
            CREATE INDEX IF NOT EXISTS idx_memory_project_session ON memory_records(project_id,session_id,is_tombstone);
            """)
            if prior == 1 {
                try execUnlocked("""
                ALTER TABLE continuity_handoffs ADD COLUMN schema_version TEXT NOT NULL DEFAULT '1.0';
                ALTER TABLE continuity_handoffs ADD COLUMN project_generation INTEGER;
                ALTER TABLE continuity_handoffs ADD COLUMN run_id TEXT;
                ALTER TABLE continuity_handoffs ADD COLUMN predecessor_provider_response_id TEXT;
                ALTER TABLE continuity_handoffs ADD COLUMN bootstrap_nonce TEXT;
                ALTER TABLE continuity_handoffs ADD COLUMN budget_observation_id TEXT;
                ALTER TABLE continuity_handoffs ADD COLUMN acknowledgement_sha256 TEXT;
                ALTER TABLE continuity_handoffs ADD COLUMN continuation_issued INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE continuity_handoffs ADD COLUMN quarantine_state TEXT;
                ALTER TABLE continuity_handoffs ADD COLUMN migration_source TEXT;
                ALTER TABLE continuity_handoffs ADD COLUMN legacy_record_id TEXT;
                ALTER TABLE rollover_operations ADD COLUMN schema_version INTEGER NOT NULL DEFAULT 1;
                ALTER TABLE rollover_operations ADD COLUMN project_generation INTEGER;
                ALTER TABLE rollover_operations ADD COLUMN run_id TEXT;
                ALTER TABLE rollover_operations ADD COLUMN predecessor_provider_response_id TEXT;
                ALTER TABLE rollover_operations ADD COLUMN successor_provider_response_id TEXT;
                ALTER TABLE rollover_operations ADD COLUMN bootstrap_nonce TEXT;
                ALTER TABLE rollover_operations ADD COLUMN acknowledgement_sha256 TEXT;
                ALTER TABLE rollover_operations ADD COLUMN budget_observation_id TEXT;
                ALTER TABLE rollover_operations ADD COLUMN continuation_issued INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE rollover_operations ADD COLUMN quarantine_state TEXT;
                ALTER TABLE rollover_operations ADD COLUMN migration_source TEXT;
                ALTER TABLE rollover_operations ADD COLUMN legacy_record_id TEXT;
                ALTER TABLE rollover_transitions ADD COLUMN schema_version INTEGER NOT NULL DEFAULT 1;
                ALTER TABLE rollover_transitions ADD COLUMN project_generation INTEGER;
                ALTER TABLE rollover_transitions ADD COLUMN run_id TEXT;
                ALTER TABLE rollover_transitions ADD COLUMN successor_provider_response_id TEXT;
                UPDATE continuity_handoffs SET
                  quarantine_state='legacy_read_only',migration_source='project_memory_v1'
                  WHERE schema_version='1.0';
                UPDATE rollover_operations SET
                  quarantine_state='legacy_read_only',migration_source='project_memory_v1'
                  WHERE schema_version=1;
                """)
            }
            try execUnlocked("""
            DROP INDEX IF EXISTS idx_rollover_active_project;
            CREATE UNIQUE INDEX idx_rollover_active_project
              ON rollover_operations(project_id)
              WHERE state <> 'predecessorSealed' AND quarantine_state IS NULL;
            """)
            try execUnlocked("PRAGMA user_version=2;")
            if prior < 2 {
                try withStatementUnlocked(
                    """
                    INSERT OR IGNORE INTO continuity_migration_receipts(
                      receipt_id,project_id,source_version,target_version,imported_count,
                      skipped_count,quarantined_count,integrity_result,details_json,started_at,completed_at
                    ) VALUES(?,?,?,?,0,0,0,'ok','{}',?,?)
                    """
                ) { statement in
                    bind(statement, 1, "continuity-schema-v2")
                    bind(statement, 2, projectID)
                    bind(statement, 3, String(prior))
                    bind(statement, 4, "2")
                    let timestamp = migrationManifest?.preparedAt
                        ?? ISO8601.string(from: clock.now())
                    bind(statement, 5, timestamp)
                    bind(statement, 6, timestamp)
                    try stepDone(statement)
                }
            }
            if isSchemaMigration, let migrationManifest {
                try VerifiedMigrationBackup.recordSQLiteMigrationReceipt(
                    database: db,
                    sourceURL: databaseURL,
                    manifest: migrationManifest
                )
            }
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
        if let migrationManifest, migrationManifest.state == .prepared {
            let observedVersion = try pragmaUserVersionUnlocked()
            guard let db else { throw StoreError.openFailed("nil project memory database") }
            try VerifiedMigrationBackup.checkpointSQLiteMigration(
                database: db,
                sourceURL: databaseURL
            )
            let target = try VerifiedMigrationBackup.logicalSQLiteMetadata(
                database: db,
                sourceURL: databaseURL,
                expectedVersion: Self.schemaVersion,
                versionQuery: "PRAGMA user_version;"
            )
            _ = try VerifiedMigrationBackup.completeMigrationManifest(
                sourceURL: databaseURL,
                preparedManifest: migrationManifest,
                observedVersion: observedVersion,
                targetMetadata: target
            )
        }
    }

    private func migrationBackupURL(sourceVersion: Int) -> URL {
        directory.appendingPathComponent(
            "memory.pre-migration-v\(sourceVersion).sqlite3",
            isDirectory: false
        )
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
